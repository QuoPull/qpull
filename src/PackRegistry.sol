// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IPackRegistry, ILeaderboardRegistry } from "./interfaces/IRegistries.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @dev Minimal read view of the write-once RaffleEngine, without a circular import: previewDraw reads the
///      same daily beacon round and winner count the draw uses, and isRipXpClaimable reads whether the one-time
///      opening has settled. The live `winnersPerDay()` getter is deliberately NOT declared here: the preview
///      must read winnersPerDayAt(day), the count the draw itself uses.
interface IEngineRound {
    function drawRound(uint32 day) external view returns (uint64);
    /// The winner count IN FORCE for `day`. runDraw uses this, so previewDraw must too, or the preview would
    /// disagree with the draw it replays.
    function winnersPerDayAt(uint256 day) external view returns (uint256);
    /// True once runOpeningDraw has settled the opening, paid or forgone. Never goes back to false.
    function openingDone() external view returns (bool);
}

/// @title  PackRegistry
/// @notice Mints raffle tickets on buys (fixed whole-ticket schedule), seals each to a
///         future drand round for its tier, and maintains the live-ticket set as daily
///         cohorts so the RaffleEngine can draw a fixed K winners in O(K) regardless of how many
///         tickets exist (fully on-chain).
///
/// @dev    Cadence: DAILY. Ticket life: 7 days. A cohort minted on day D is eligible for the
///         draws on days D+1 .. D+7 (7 shots), then falls out of the sliding window. Expiry is
///         therefore free, an aged cohort is simply never in-window again; no per-ticket cleanup.
contract PackRegistry is IPackRegistry, NonRenounceableOwnable2Step {
    // ─── tiers ───────────────────────────────────────────────────────────────
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;

    // ─── config (immutable) ──────────────────────────────────────────────────
    IDrandOracle public immutable drand;
    uint256 public immutable genesis; // launch timestamp; day 0 begins here
    uint256 public immutable revealDelay; // seconds ahead to seal the tier round (sealed-then-revealed)
    uint32 public constant LIFE_DAYS = 7; // ticket lifetime in daily draws
    // Cohort/day cadence. `virtual` so the TESTNET-ONLY subclass shortens it; MAINNET uses the real 1 day.
    // MUST equal RaffleEngine.DAY() (both default 1 day), enforced on-chain: RaffleEngine's constructor
    // reverts (CadenceMismatch) unless dayLength() below equals its own DAY().
    function DAY() internal view virtual returns (uint256) { return 1 days; }

    /// @notice The cohort/day cadence in seconds. Exposed so RaffleEngine can assert at construction that the
    ///         paired cadences match, exactly as genesis is cross-checked, so a mis-paired deploy (mainnet engine
    ///         on a short-clock registry, or vice versa) cannot desync the reveal-before-cutoff windows. DAY()
    ///         itself stays `internal`: the testnet subclass overrides it as `internal pure`, so widening its
    ///         visibility would break that pair.
    function dayLength() external view returns (uint256) {
        return DAY();
    }

    // ─── ticket price ────────────────────────────────────────────────────────
    // WETH per ticket: the ETH-in VALUE of a buy, in wei (1e18 = 1 ETH). Seeded to ~$10 of ETH at
    // launch (e.g. 0.003 ETH). Tickets are priced off the hook's `credit`: the WETH the buyer actually paid,
    // capped at fee * BPS / TAX_BPS of the WETH fee the same swap took to the Treasury. NOT the QPULL
    // received, so pool depth / slippage never change how many tickets a given spend earns, and no pool
    // price is read: every credited wei paid the 4% tax in WETH inside the same swap. Example spend →
    // tickets: $10→1, $100→10, $1,000→100. $1,000 is also where `maxTicketsPerBuy` (100) caps a SINGLE
    // buy; above the cap the excess does not mint at once, it banks in `bankedRemainder` and mints 100 at a
    // time on the buyer's later buys. No value is lost, but the spend/ticket table is per-BUY, not per-wallet
    // and not per-day. The owner may re-peg to hold ~$10 as ETH's USD price drifts, but ONLY within tight
    // bounds (≤ ±25% per change, ≤ once/day), so the price can never jump to zero or to an extreme, and
    // every move is slow + observable.
    uint256 public ticketPrice;
    uint256 public constant MAX_ADJ_BPS = 2500; // max ±25% per re-peg
    /// @notice Minimum gap between ticket-price re-pegs: ONE DAY ON THIS CONTRACT'S OWN CLOCK.
    ///
    /// @dev Derived from DAY(), like RaffleEngine's adjust cooldowns (setCapBps / setWinnersPerDay / setMinPot /
    ///      setPotCap), so it is exactly 1 day on mainnet and one compressed day on a short-clock testnet, where
    ///      the recurring re-peg can be rehearsed at its real cadence. NOT `virtual`: nothing overrides it, and
    ///      it compresses through DAY() already.
    function ADJUST_COOLDOWN() public view returns (uint256) {
        return DAY();
    }

    /// @notice Floor on the constructor's `revealDelay`. `virtual` for the SAME reason REVEAL_LAG() is
    ///         virtual on the engines: drawRound/revealRound are roundAt(<boundary> + delay), while the window
    ///         that needs the round is one DAY() wide. With DAY() compressed to 5 minutes, a 1-hour floor would
    ///         put a pack's tier round ~55 minutes past the end of the window that needs it, so a short-clock
    ///         subclass must shorten this floor too.
    ///
    ///         NOT derived from DAY(): the floor's job is to stay >= the engines' REVEAL_LAG, and DAY()/24
    ///         would give 12.5s against a 1-minute testnet REVEAL_LAG. A subclass that shortens this floor MUST
    ///         keep MIN_REVEAL_DELAY() >= its engines' REVEAL_LAG(); the ceiling is MAX_REVEAL_DELAY() == DAY()
    ///         and follows a compressed DAY() by itself.
    function MIN_REVEAL_DELAY() public view virtual returns (uint256) {
        return 1 hours;
    }

    /// @notice Ceiling on `revealDelay`. DERIVED, unlike the floor, because the requirement is exact:
    ///         a cohort's tier round is roundAt(genesis + (c+1)*DAY() + revealDelay) and the cohort's FIRST
    ///         draw runs from genesis + (c+2)*DAY(), so the round is readable in time iff
    ///         revealDelay < DAY(). Deriving it makes the invariant structural instead of two numbers to keep
    ///         in step, and it compresses with any subclass clock. NOT `virtual`: nothing overrides it, and the
    ///         liveness argument of the reveal guard in _drawCore relies on revealDelay < DAY().
    function MAX_REVEAL_DELAY() public view returns (uint256) {
        return DAY();
    }
    uint64 public lastTicketAdjust; // last re-peg timestamp (0 = never)

    // ─── wiring ──────────────────────────────────────────────────────────────
    address public recorder; // QpullTaxHook, only caller of recordBuy
    address public engine; // RaffleEngine, only caller of drawFrom
    ILeaderboardRegistry public leaderboard; // rip-XP sink (claimRipXp -> recordXp); write-once
    mapping(uint256 => bool) public ripXpGranted; // pack id => rip XP already banked (once per pack)
    // Art Pass entries are VIRTUAL: a free winner is a synthetic id, never a Pack in cohortLive, so every Pack
    // is a paid pack and there is no free pack to rip.

    /// @notice Rip XP per unit of rarity weight, in bps of the cohort's ticket price. A final non-winning rip of
    ///         tier t banks
    ///             cohortMinTicketPrice[cohortDay] * ripXpWeight(t) * RIP_XP_BPS / 10_000
    ///         leaderboard points: Common 1.8% / Uncommon 3.6% / Rare 7.2% / Super rare 18% of that price.
    /// @dev    WHY 180. Leaderboard points are WETH wei: a buy banks the hook credit, i.e. the WETH it paid
    ///         (QpullTaxHook), and that credit pays the 4% tax (TAX_BPS = 400). Rip XP lands in the SAME
    ///         pool. Every pack's tier is an independent 80/15/4/1 roll and paid winners are drawn uniformly by
    ///         index, never by tier, so a non-winner's expected weight is 0.8*1 + 0.15*2 + 0.04*4 + 0.01*10 =
    ///         1.36, and its expected rip XP is 1.36 * 1.80% = 2.448% of the ticket price. In expectation a
    ///         ticket's worth of buying therefore yields 1.02448 points per 0.04 of tax, so a point costs
    ///         400 / 1.02448 = 390.4 bps of tax (3.90%), against 400 bps with no rip XP at all. That is an
    ///         expectation over tier luck, and an upper bound on XP because a pack never scales off more than
    ///         the price it paid (cohortMinTicketPrice) and a winner earns no rip XP; the single luckiest pack,
    ///         a Super rare non-winner, banks 18% of its price (400 / 1.18 = 339 bps per point for that pack
    ///         alone), purely by tier luck. Keeping the weight in bps of the price paid, rather than in absolute
    ///         wei, keeps this ratio fixed across re-pegs.
    uint256 public constant RIP_XP_BPS = 180;
    // rip XP is claimable only within this many days AFTER a pack settles as a final non-winner. A 7-day window
    // over 7-day Sunday-aligned weeks straddles exactly one week boundary, so the XP lands in the settlement
    // week or the one immediately after, never a later week. XP is credited to the week of the claim, not of
    // the settlement: a claim made after the settlement week's distribute() would otherwise credit an
    // already-paid week and the XP would be lost.
    uint32 public constant RIP_XP_WINDOW = 7;
    // Gas bound on per-buy minting, NOT an economic throttle. Value above the cap is banked and mints on the
    // buyer's next trade.
    //
    // MEASURED (test/GasBenchmark.t.sol: test_gas_recordBuy_acrossCap, and BuyGasBenchmarkTest running
    // QpullSwapRouter.buy through the real hook and registries, with --isolate so each buy is its own
    // transaction):
    //   marginal cost      71,990 gas/pack
    //   a real buy         execution ~329,000 gas inside the 1-hour gate (holder check + throttle record), ~300,000
    //                      after it, PLUS 71,990/pack, for a fresh wallet on a day and week that already have buys.
    //                      The day's first minting buy adds ~17,000 (this cohort's slots). The worst case one buy can
    //                      reach, the launch's first buy (first mint of the day, first board entry of the week, the
    //                      Treasury's first WETH, a new throttle record and a banked remainder), is ~434,000 + 71,990
    //                      per pack; a full-board eviction on a later day's first mint is ~374,000. A receipt adds
    //                      21,000 intrinsic + calldata and, on RH, the L1 data component.
    //   at cap 100          ~7.5M gas total =  24% of the measured 32M ArbOS clamp
    //   at cap 200         ~14.7M gas total =  46% of it, so MAX_TICKETS_CEILING is REACHABLE
    //   physical wall     ~439 packs in one tx
    // Raising the ceiling to cover a 1,000-pack buy would need ~72M and is simply not possible here;
    // banking is what makes a large buy succeed at all, rather than revert. Do not remove this cap.
    // PER-BUY ONLY. The draw's own k clamp is MAX_DRAW_K below: lowering this for buy gas must
    // never silently cap draws under RaffleEngine.MAX_K.
    uint256 public constant MAX_TICKETS_CEILING = 200;
    uint256 public maxTicketsPerBuy = 100;

    /// @notice Clamp on `k` inside every draw, independent of the caller. MUST equal
    ///         RaffleEngine.MAX_K; RaffleEngine's constructor reverts DrawKMismatch otherwise.
    uint256 public constant MAX_DRAW_K = 200;

    /// @notice The cohorts the one-time opening sweeps, [0, OPENING_COHORTS-1]. MUST equal RaffleEngine's
    ///         ACCUM_DAYS; RaffleEngine's constructor reverts OpeningCohortsMismatch otherwise. Read only by the
    ///         opening gate in isRipXpClaimable.
    uint32 public constant OPENING_COHORTS = 2;

    // ─── ticket state ────────────────────────────────────────────────────────
    struct Pack {
        address owner;
        uint64 revealRound; // drand round the tier is sealed against
        uint32 cohortDay; // day minted
        bool spent; // drawn (won), burned
    }

    /// @dev In-memory config for the virtual free-entry block, bundled so drawFrom/previewDraw stay under
    ///      the stack limit. Built once per draw by _buildFreeCfg.
    struct FreeCfg {
        uint256[] srList; // eligible Super Rare token ids (bounded by MAX_SR_SCAN)
        uint256 srCount; // number of valid entries in srList
        uint256 wb; // base weight of the eligible pool = srCount*SR_WEIGHT + pledge copies (incl. transferred-away ones)
        uint256 freeze; // the day's freeze instant (a pass must be held at or before this)
        uint256 vPool; // weight added to the draw total (= cap when any pass is eligible, else 0)
    }

    uint256 public nextPackId = 1;
    mapping(uint256 => Pack) public packs;
    mapping(uint32 => uint256[]) internal cohortLive; // cohortDay => live pack ids
    mapping(uint256 => uint256) internal packLiveIndex; // pack id => index within its cohort array
    mapping(address => uint256) public bankedRemainder; // sub-ticket WETH credit carried forward
    /// @notice The LOWEST ticketPrice any pack of cohort `day` was minted at: the base rip XP scales off
    ///         (RIP_XP_BPS). One slot per cohort DAY, not per pack, so a capped buy of 100 packs pays no extra
    ///         write: only the first minting buy of a day (zero to nonzero) and a buy right after a downward
    ///         re-peg ever write it. MIN, not first or last: every pack in the cohort paid at least this, so no
    ///         pack's rip XP can exceed RIP_XP_BPS of the price that pack actually paid, whatever the order of
    ///         buys and re-pegs within the day. Only the owner moves ticketPrice (at most +/-25% once a day), so
    ///         the only drift is the owner's, and it can only lower a cohort's XP.
    mapping(uint32 => uint256) public cohortMinTicketPrice;

    // ─── virtual free daily entries for NFT holders ──────────────────────────
    // Art Passes enter the daily raffle DIRECTLY and VIRTUALLY: nothing is minted, nothing is stored per
    // entry. The whole free-eligible block enters drawFrom as ONE integer weight (`vPool`) added to the
    // sampling total, and at most K winners are resolved lazily at draw time as self-describing synthetic
    // ids. Super Rare = passive auto-entry (first claim on the cap); Common/Uncommon/Rare = opt-in pledge
    // (weight 1/2/4). Cap = 10% of the LIVE PAID window, linear, no clamp.
    INFTCollection public nft;
    uint256 public constant FREE_CAP_BPS = 1000; // free entries ≤ 10% of the LIVE PAID window; no hard clamp
    // Daily mint counts come from PackMinted events, or cohortSize(day) for the still-live count.

    // Top bit tags a synthetic virtual-winner id; real pack ids (sequential from 1) never set it.
    uint256 internal constant VIRTUAL_FLAG = 1 << 255;
    uint256 internal constant MAX_SR_SCAN = 128; // bounded SR-index scan per draw (never the 3k token space)
    // FREE-ENTRY SAMPLING LAW (one roll per seat, every outcome terminal).
    // pledgeList is append-only and a copy is validated only when it is rolled, so a pledged pass that changes
    // hands (with no re-pledge) leaves INVALID weight F in the sampling region
    // wb = 8*S_all + Pv + F, where S_all is the Super Rares REGISTERED at or before the freeze (membership is
    // frozen, so wb cannot move after the freeze), S_bad of them have changed hands since the freeze, Pv is
    // valid pledge weight and F invalid. Per SEAT there is exactly one roll, with four outcomes:
    //   P(seated SR)           = 8*(S_all - S_bad) / wb
    //   P(seated valid pledge) = Pv / wb
    //   P(void, SR forfeit)    = 8*S_bad / wb          <- only that pass's own owner can cause it
    //   P(void, invalid copy)  = F / wb
    // The 8 : 4/2/1 ladder is EXACT among seated seats (it is 8*(S_all-S_bad) : Pv and contains no void term).
    // A voided seat does not "roll forward to the vault": RaffleEngine._payWinners divides each tier bucket by
    // its REALIZED winner count, so a void redistributes to that bucket's surviving winners and only reaches
    // the vault when a bucket empties. A void never raises the share of the voided pass's owner: holding a of
    // a bucket's c winners, losing one moves them from a/c to (a-1)/(c-1), and (a-1)/(c-1) <= a/c for a <= c.
    // Every void is terminal, never a re-roll, so no transfer after the beacon is public can move a seat from
    // one token to another.
    // SEATS ARE INDEPENDENT: the per-seat figures above are ALSO the expected shares over the whole free block,
    // because every virtual slot rolls its own fresh values: _pickVirtual keys each roll on (beacon, day, 1,
    // seat) and `seat` advances on a VOID as well as on a fill (identically in _drawCore and _replayVirtual),
    // so a void never repeats at a later slot.
    // SR-band rolls are resolved before the pledge region, so no number of invalid pledge copies can void or
    // pre-empt a seat that rolled Super Rare; such a seat voids only if that pass itself changed hands after
    // the freeze.
    // A draw is bounded by MAX_DRAW_K == MAX_K = 200, and test/GasBenchmark.t.sol measures a full runDraw at
    // k = 200 with the free block active.
    /// @dev Largest ticket price for which `cur * (10_000 + MAX_ADJ_BPS)` in setTicketPrice cannot overflow.
    ///      ~9.27e72, astronomically above any real WETH-denominated ticket price.
    uint256 internal constant MAX_BANDABLE_PRICE = type(uint256).max / (10_000 + MAX_ADJ_BPS);
    uint256 public constant SR_WEIGHT = 8; // Super Rare draw weight (ladder Common 1 / Uncommon 2 / Rare 4 / SR 8)
    uint256 internal constant NOT_SEATED = type(uint256).max; // _pickVirtual sentinel (never a real token id)

    // Super Rare index: trustless, append-only, verified on submit. The ONLY set iterated for SR autos.
    uint256[] public superRareIds;
    mapping(uint256 => bool) public srIndexed;
    // The SR draw SET is frozen per draw exactly like ownerSince. An id is eligible for a draw only if it was
    // registered at or before that draw's freeze, so a registration made after the day's settling beacon is
    // public counts from the next day onward. 0 = never registered.
    mapping(uint256 => uint64) public srRegisteredAt;

    // Per-day pledge pool for Common/Uncommon/Rare. pledgeList holds weight-expanded copies (1/2/4), and the
    // draw picks uniformly over it (SR copies weighted alongside) so selection is tier-weighted. The pool's
    // realized WEIGHT into the draw is bounded by vPool=cap (10% of the paid window), NOT by pledgeList.length,
    // so pledges never enlarge the free SHARE; pledgerOf voids a pledge at draw time if the pass has changed
    // hands. The list is append-only (a transferred-away pass's copies stay in it); how such copies affect
    // seating is set by the sampling law above. pledgeDistinct counts distinct first-pledges per day and is
    // read ONLY through its public getter (an UPPER bound: not decremented on transfer; previewDraw gives
    // realized winners).
    mapping(uint32 => uint256[]) internal pledgeList;
    mapping(uint256 => mapping(uint32 => address)) public pledgerOf;
    mapping(uint32 => uint256) public pledgeDistinct;

    // ─── events / errors ─────────────────────────────────────────────────────
    event RecorderSet(address recorder);
    event EngineSet(address engine);
    event NftSet(address nft);
    event PackMinted(uint256 indexed id, address indexed owner, uint32 cohortDay, uint64 revealRound);
    event LeaderboardSet(address leaderboard);
    event RipXpClaimed(address indexed owner, uint256 packCount, uint256 xp);
    event Drawn(uint32 indexed drawDay, uint256 count);
    event FreeEntryDrawn(uint32 indexed day, uint256 indexed passTokenId, address owner, uint8 tier, uint256 seat);
    event Pledged(uint256 indexed tokenId, uint32 indexed day, address pledger);
    event SuperRareRegistered(uint256 indexed tokenId);
    event TicketPriceSet(uint256 oldPrice, uint256 newPrice);
    event MaxTicketsPerBuySet(uint256 m);

    error NotRecorder();
    error NotEngine();
    error NotStarted();
    error NoNft();
    error NotNftOwner();
    error TicketPriceZero();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error ZeroDrand();
    error BadMaxTickets();
    error BadRevealDelay();
    /// @dev MIN_REVEAL_DELAY() >= MAX_REVEAL_DELAY(): the bounds leave no legal value. Only reachable from a
    ///      subclass that overrode one side of the pair (or DAY(), which the ceiling derives from) and not
    ///      the other.
    error RevealDelayWindowEmpty();
    error BadGenesis(); // day 0 at the epoch would open every window before launch
    error AlreadySet(); // reward-gating bindings are write-once
    error VirtualId(); // rollOf/tierAndRollOf called on a synthetic virtual-winner id (no on-chain roll)
    error BadPledge(); // pledging a Super Rare (they auto-enter) or a non-owned pass
    /// @notice A draw's sweep window holds live packs of `cohortDay`, whose shared tier round `revealRound`
    ///         is not on the oracle yet. Nothing was popped, spent, latched or consumed: post that round
    ///         (submitBeacon) and retry. A DAILY draw never waits on a reveal: every cohort it sweeps has its round
    ///         published before the draw's window opens (revealDelay < DAY()), so on a daily draw this only means
    ///         the round was not posted yet. The one-time OPENING can genuinely wait: it is callable from
    ///         genesis + OPENING_COHORTS * DAY(), and when revealDelay > the engine's REVEAL_LAG its newest
    ///         cohort's round publishes up to revealDelay after that instant, so it reverts here until the round
    ///         exists (a wait, not a void: the opening has no deadline). See _drawCore.
    error RevealPending(uint32 cohortDay, uint64 revealRound);

    modifier onlyRecorder() {
        if (msg.sender != recorder) revert NotRecorder();
        _;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    constructor(
        address drand_,
        uint256 ticketPrice_,
        uint256 genesis_,
        uint256 revealDelay_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (ticketPrice_ == 0 || ticketPrice_ > MAX_BANDABLE_PRICE) revert TicketPriceZero(); // re-peg band bound
        if (drand_ == address(0)) revert ZeroDrand(); // oracle sits on the taxed-buy hot path
        // Seal margin must be >= the engines' REVEAL_LAG so a cohort's tier round isn't
        // near-public before the buy window closes, and < one day so it reveals within the cohort's draw window.
        // A subclass that compresses DAY() but not MIN_REVEAL_DELAY() inherits a mainnet floor under a
        // compressed ceiling: an EMPTY window where every possible revealDelay reverts BadRevealDelay, so that
        // case gets its own error. SUBCLASS-SEAM GUARD: unreachable on this base (1 hour < 1 day) and on
        // PackRegistryTestnet (1 minute < 5 minutes); kept for a future short-clock subclass.
        if (MIN_REVEAL_DELAY() >= MAX_REVEAL_DELAY()) revert RevealDelayWindowEmpty();
        if (revealDelay_ < MIN_REVEAL_DELAY() || revealDelay_ >= MAX_REVEAL_DELAY()) revert BadRevealDelay();
        // Day 0 begins at `genesis`, and every draw round, freeze instant and cohort boundary is derived
        // from it. Zero would put day 0 at the epoch, so `currentDay()` is astronomically large from the
        // first block and every window in the protocol is already closed at launch. It is immutable, so the
        // only remedy would be redeploying the whole protocol.
        if (genesis_ == 0) revert BadGenesis();
        drand = IDrandOracle(drand_);
        ticketPrice = ticketPrice_;
        genesis = genesis_;
        revealDelay = revealDelay_;
    }

    // Write-once: the recorder gates recordBuy (mints tickets + points), so it is fixed once set.
    function setRecorder(address t) external onlyOwner {
        if (t == address(0) || recorder != address(0)) revert AlreadySet();
        recorder = t;
        emit RecorderSet(t);
    }

    // Write-once: the engine is the only caller of the draws that pop live tickets, so it is fixed once set.
    // The draw also clamps k internally.
    function setEngine(address e) external onlyOwner {
        if (e == address(0) || engine != address(0)) revert AlreadySet();
        engine = e;
        emit EngineSet(e);
    }

    // Write-once (mirrors setEngine): the leaderboard is the only sink claimRipXp mints XP into. PackRegistry
    // must be set as that leaderboard's xpRecorder (write-once there) for claimRipXp to succeed.
    function setLeaderboard(address lb) external onlyOwner {
        if (lb == address(0) || address(leaderboard) != address(0)) revert AlreadySet();
        leaderboard = ILeaderboardRegistry(lb);
        emit LeaderboardSet(lb);
    }

    // Write-once: the NFT decides free-entry eligibility, so it is fixed once set.
    function setNft(address n) external onlyOwner {
        if (n == address(0) || address(nft) != address(0)) revert AlreadySet();
        nft = INFTCollection(n);
        emit NftSet(n);
    }

    function setMaxTicketsPerBuy(uint256 m) external onlyOwner {
        if (m == 0 || m > MAX_TICKETS_CEILING) revert BadMaxTickets(); // bounded + event
        maxTicketsPerBuy = m;
        emit MaxTicketsPerBuySet(m);
    }

    /// @notice Re-peg the ticket price to hold ~$10 of ETH-in VALUE per ticket as ETH's USD price drifts.
    ///         `newPrice` is WETH wei (the same denomination as `ticketPrice`, see its storage comment), NOT
    ///         QPULL. Deliberately constrained (at most ±25% per change and at most once per day), so the price
    ///         can never jump to zero or to an extreme, and every move is slow and
    ///         observable. The owner (the launch Safe after the handover) computes the WETH amount currently worth
    ///         ~$10 off-chain and sets it within these bounds. No price is read on-chain. A re-peg also moves the
    ///         rip-XP scale of packs minted after it (RIP_XP_BPS, cohortMinTicketPrice); packs already minted
    ///         keep the price their cohort was recorded at, and a mid-day re-peg can only lower that.
    function setTicketPrice(uint256 newPrice) external onlyOwner {
        // Same band expression as the three engines: above type(uint256).max/12500 the `hi` computation would
        // overflow, so the price is capped at MAX_BANDABLE_PRICE here and in the constructor, which sets
        // ticketPrice directly.
        if (newPrice == 0 || newPrice > MAX_BANDABLE_PRICE) revert TicketPriceZero();
        if (block.timestamp < uint256(lastTicketAdjust) + ADJUST_COOLDOWN()) revert AdjustTooSoon();
        uint256 cur = ticketPrice;
        // CEIL, matching all six sibling band setters in the three engines, so a step can never land
        // fractionally BELOW the stated -25% bound.
        uint256 lo = ((cur * (10_000 - MAX_ADJ_BPS)) + 10_000 - 1) / 10_000; // −25%, rounded toward the band
        uint256 hi = (cur * (10_000 + MAX_ADJ_BPS)) / 10_000; // +25%
        if (hi <= cur) hi = cur + 1; // band never collapses to a point
        if (newPrice < lo || newPrice > hi) revert AdjustOutOfBounds();
        lastTicketAdjust = uint64(block.timestamp);
        ticketPrice = newPrice;
        emit TicketPriceSet(cur, newPrice);
    }

    // ─── minting (buys only) ─────────────────────────────────────────────────

    /// @inheritdoc IPackRegistry
    function recordBuy(address buyer, uint256 grossValue) external override onlyRecorder {
        uint256 price = ticketPrice;
        uint256 avail = bankedRemainder[buyer] + grossValue;
        uint256 n = avail / price;
        if (n > maxTicketsPerBuy) n = maxTicketsPerBuy; // cap gas; the excess value stays banked for later buys
        bankedRemainder[buyer] = avail - n * price;
        if (n == 0) return;

        _mintPacks(buyer, n, _today(), price); // taxed buy: every minted pack is rip-XP eligible
    }

    // ─── virtual free entries: register (Super Rare) + pledge (Common/Uncommon/Rare) ─────────

    /// @notice Add verified Super Rare token ids to the auto-entry index. Permissionless and trustless:
    ///         each id is checked on-chain (rarityOf == SUPER_RARE); non-SR / unrevealed / duplicate ids are
    ///         skipped, so anyone can complete or repair the index. One mandatory bulk call at reveal; after
    ///         that the set is fixed (post-reveal rarities are immutable).
    function registerSuperRare(uint256[] calldata ids) external {
        if (address(nft) == address(0)) revert NoNft();
        if (!nft.launched()) revert NotStarted();
        for (uint256 i; i < ids.length; ++i) {
            uint256 tid = ids[i];
            if (srIndexed[tid]) continue;
            try nft.rarityOf(tid) returns (uint8 r) {
                if (r == SUPER_RARE) {
                    srIndexed[tid] = true;
                    srRegisteredAt[tid] = uint64(block.timestamp); // freeze-cutoff anchor
                    superRareIds.push(tid);
                    emit SuperRareRegistered(tid);
                }
            } catch { /* unrevealed / nonexistent, skip, retry after reveal */ }
        }
    }

    /// @notice Opt Common/Uncommon/Rare passes into TODAY's virtual daily raffle (Super Rare is automatic).
    ///         Weight-expanded 1/2/4 by tier so the draw is tier-weighted. Default is NOT entered (the pool
    ///         stays thin), and a pledge is voided at draw time if the pass has since changed hands.
    function pledge(uint256[] calldata tokenIds) external {
        if (address(nft) == address(0)) revert NoNft();
        if (!nft.launched()) revert NotStarted();
        uint32 day = _today();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tid = tokenIds[i];
            if (nft.ownerOf(tid) != msg.sender) revert NotNftOwner();
            uint8 r = nft.rarityOf(tid); // reverts if not yet revealed
            if (r == SUPER_RARE) revert BadPledge(); // Super Rare auto-enters; never pledged
            address cur = pledgerOf[tid][day];
            if (cur == address(0)) {
                uint256 w = _entryWeight(r);
                uint256[] storage pl = pledgeList[day];
                for (uint256 j; j < w; ++j) pl.push(tid);
                pledgerOf[tid][day] = msg.sender;
                unchecked { ++pledgeDistinct[day]; }
                emit Pledged(tid, day, msg.sender);
            } else if (cur != msg.sender) {
                pledgerOf[tid][day] = msg.sender; // re-pledge by the new owner: reuse copies, no over-weight
                emit Pledged(tid, day, msg.sender);
            }
            // else same pledger this day: no-op
        }
    }

    /// @dev Pledge weight by tier (Common 1 / Uncommon 2 / Rare 4). Super Rare is auto with SR_WEIGHT, not here.
    function _entryWeight(uint8 rarity) internal pure returns (uint256) {
        if (rarity == RARE) return 4;
        if (rarity == UNCOMMON) return 2;
        return 1; // Common
    }

    /// @param price the ticketPrice these `n` packs were minted at (rip-XP scale, see cohortMinTicketPrice)
    function _mintPacks(address to, uint256 n, uint32 cday, uint256 price) internal {
        // Quantized reveal round (BLS keeper efficiency): ALL packs minted on day `cday` share ONE reveal
        // round: the round at (start of the next day + revealDelay). Still a FUTURE, time-locked round
        // (unknowable at mint), but ONE per day instead of one per beacon, so the keeper posts ~1 tier
        // beacon/day. Revealed before the cohort's first draw.
        // The reveal guard in _drawCore relies on this: every pack of a cohort carries the SAME round, because
        // `drand`, `genesis`, `revealDelay` and DAY() are all fixed for the life of this contract and roundAt is
        // a pure function of the oracle's immutable genesis and period.
        uint64 rr = drand.roundAt(genesis + (uint256(cday) + 1) * DAY() + revealDelay);
        // Rip-XP scale: one slot per cohort day, written only when it moves (first minting buy of the day, or
        // the first buy after a downward re-peg). A later buy of the day pays one SLOAD here, not an SSTORE.
        uint256 floor = cohortMinTicketPrice[cday];
        if (floor == 0 || price < floor) cohortMinTicketPrice[cday] = price;
        uint256[] storage arr = cohortLive[cday];
        uint256 id = nextPackId;
        for (uint256 i; i < n; ++i) {
            packs[id] = Pack({ owner: to, revealRound: rr, cohortDay: cday, spent: false });
            packLiveIndex[id] = arr.length;
            arr.push(id);
            emit PackMinted(id, to, cday, rr);
            unchecked {
                ++id;
            }
        }
        nextPackId = id;
    }

    // ─── drawing (engine only) ───────────────────────────────────────────────

    /// @notice Draw up to `k` winners for `drawDay` from the live PAID window PLUS the virtual free-entry
    ///         block. Paid winners are popped (marked spent) and returned as their real pack ids; free
    ///         winners are returned as self-describing synthetic ids (top bit set; owner+tier packed in:
    ///         see ownerOf/tierOf), so RaffleEngine._payWinners handles both verbatim. The free block is
    ///         weighted into the sampling total as ONE integer (`vPool`); nothing is materialized.
    /// @dev    Paid window for day d = cohorts [d-7 .. d-1]. Free entries (Super Rare autos at SR_WEIGHT +
    ///         pledged C/U/R at 1/2/4, MULTI-SHOT: fill the full 10% cap by weighted repeats) begin only
    ///         AFTER the day's freeze instant, so the one-time opening sweep is paid-only. Reverts
    ///         RevealPending while any in-window cohort's tier round is unposted (see _drawCore).
    function drawFrom(bytes32 beacon, uint32 drawDay, uint256 k)
        external
        onlyEngine
        returns (uint256[] memory winners)
    {
        return _drawCore(beacon, drawDay, k, true); // daily draw: the virtual free-entry block is active
    }

    /// @notice PAID-ONLY draw for the one-time opening sweep. Structurally excludes the virtual free block:
    ///         the opening's settling beacon reveals ~1h after day (ACCUM_DAYS-1) closes, but a free block
    ///         folded at drawDay=ACCUM_DAYS would freeze a full cadence LATER, i.e. after that beacon is public.
    ///         Making paid-only a code property (not a matter of call timing) means a late opening call can
    ///         never activate free entries. A later daily runDraw(ACCUM_DAYS) still uses drawFrom and keeps its
    ///         free block, so this is a distinct entrypoint, not a drawDay special-case. Shares _drawCore's
    ///         reveal guard, so the opening can never pop a cohort whose tier is unrevealed.
    function drawFromPaidOnly(bytes32 beacon, uint32 drawDay, uint256 k)
        external
        onlyEngine
        returns (uint256[] memory winners)
    {
        return _drawCore(beacon, drawDay, k, false);
    }

    /// @dev The single chokepoint for BOTH draws: RaffleEngine.runOpeningDraw (via drawFromPaidOnly) and
    ///      RaffleEngine.runDraw (via drawFrom).
    ///
    ///      REVEAL GUARD (REVEAL BEFORE POP). Before anything is popped, every NON-EMPTY cohort in the sweep
    ///      window [from, to] must have its tier round on the oracle, or the whole draw reverts
    ///      RevealPending(cohort, round), so every popped winner has a readable tier when RaffleEngine._payWinners
    ///      pays it. Reverting here is fail-closed and retryable: runOpeningDraw has not latched openingDone and
    ///      runDraw has not marked the day drawn, because both write those flags only after this call returns,
    ///      and the oracle never forgets a round. Liveness holds. Cohort c's round is roundAt(genesis + (c+1)*DAY() +
    ///      revealDelay). A daily draw of day d opens at genesis + (d+1)*DAY() and sweeps c <= d-1, whose rounds
    ///      are all at or before genesis + d*DAY() + revealDelay, strictly earlier because revealDelay < DAY():
    ///      a daily draw never waits on a reveal, only on its own settling round. The opening is callable from
    ///      genesis + OPENING_COHORTS*DAY() and its newest cohort's round lands revealDelay after that instant, while
    ///      its own beacon lands REVEAL_LAG after it; with the shipped revealDelay == REVEAL_LAG == 1 hour they
    ///      coincide, and with a longer revealDelay the opening reverts RevealPending until the round publishes.
    ///      That is a wait, not a void, because runOpeningDraw has no upper time bound.
    ///      Empty cohorts are skipped: they pop nothing, so their reveal is irrelevant.
    ///      Cost: one packs[] and one cohort-array read plus one isAvailable staticcall per non-empty cohort,
    ///      at most LIFE_DAYS = 7 per draw; the payout's tierOf calls then read those same oracle slots warm.
    function _drawCore(bytes32 beacon, uint32 drawDay, uint256 k, bool allowFree)
        internal
        returns (uint256[] memory winners)
    {
        if (drawDay == 0) revert NotStarted();
        if (k > MAX_DRAW_K) k = MAX_DRAW_K; // clamp independent of the caller
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        uint32 to = drawDay - 1;

        uint256 paidRemaining;
        for (uint32 c = from; c <= to; ++c) {
            uint256[] storage live = cohortLive[c];
            uint256 len = live.length;
            if (len == 0) continue;
            uint64 rr = packs[live[0]].revealRound; // every pack of cohort c shares this round (_mintPacks)
            if (!drand.isAvailable(rr)) revert RevealPending(c, rr); // nothing popped yet
            paidRemaining += len;
        }

        // virtual free-entry block: ONE integer weight (cfg.vPool) into the draw, never materialized
        FreeCfg memory cfg = _buildFreeCfg(drawDay, paidRemaining, allowFree);
        uint256 total = paidRemaining + cfg.vPool;
        winners = new uint256[](k);
        uint256[] memory wonTids = new uint256[](k); // per-draw tids of virtual winners, in win order (VTIER entropy)
        uint256 got;
        // virtual SLOT counter: advances on every virtual slot, filled OR voided (see the sampling law). It is
        // the per-slot roll nonce in _pickVirtual, which is what makes the seats independent, and the uniqueness
        // nonce in each synthetic id. MUST move in lockstep with _replayVirtual.
        uint256 seat;

        for (uint256 j; j < k && total > 0; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, drawDay, j))) % total;
            if (r < paidRemaining) {
                for (uint32 c = from; c <= to; ++c) {
                    uint256 len = cohortLive[c].length;
                    if (r < len) { winners[got++] = _popAt(c, r); break; }
                    r -= len;
                }
                unchecked { --paidRemaining; }
            } else {
                // virtual free draw (multi-shot): weighted pick over Super Rare + pledge copies, repeats
                // allowed; one roll per seat, and an invalid pass voids that seat.
                uint256 tid = _pickVirtual(beacon, drawDay, cfg, seat);
                if (tid != NOT_SEATED) {
                    address passOwner = _safeOwnerOf(tid);
                    if (passOwner != address(0)) {
                        uint256 winIdx = _tidWinIndex(wonTids, seat, tid); // this tid's k-th win in THIS draw
                        uint256 vid = _encodeVirtual(beacon, drawDay, seat, tid, winIdx, passOwner);
                        winners[got++] = vid;
                        wonTids[seat] = tid;
                        emit FreeEntryDrawn(drawDay, tid, passOwner, uint8((vid >> 160) & 3), seat);
                    }
                }
                // a voided slot leaves wonTids[seat] == 0 (never a token id) and still consumes its nonce, so
                // the NEXT virtual slot rolls fresh values instead of replaying this slot's void
                unchecked { ++seat; }
            }
            unchecked { --total; }
        }

        assembly { mstore(winners, got) }
        emit Drawn(drawDay, got);
    }

    /// @dev Build the in-memory list of Super Rare passes ENTERED in a draw: every indexed id REGISTERED at or
    ///      before `freeze`. Iterates ONLY the SR index (bounded by MAX_SR_SCAN), never the full token space,
    ///      and never calls rarityOf (SR-ness is the index), so the draw is reveal-independent and no single
    ///      token can make it revert. Makes no external call at all.
    ///
    ///      MEMBERSHIP IS FROZEN, AND THAT IS THE POINT. `srRegisteredAt` is written once per id
    ///      (registerSuperRare skips an id already in `srIndexed`), `superRareIds` is append-only (its only
    ///      writer is registerSuperRare's push), and
    ///      `srRegisteredAt` is therefore non-decreasing along it, so this filter selects a PREFIX and the
    ///      compaction is the identity map. After the freeze neither the contents, nor the order, nor srCount
    ///      can change. That is what holds `cfg.wb` and the `srList` index mapping still, and therefore every
    ///      seat, against any post-beacon transfer.
    ///
    ///      OWNERSHIP IS DELIBERATELY NOT TESTED HERE. It is live-mutable (`ownerSince` is re-stamped on every
    ///      transfer), so filtering on it here would let a transfer re-compact the list, change srCount and wb,
    ///      and re-roll EVERY seat. Eligibility is tested PER SEAT in _pickVirtual instead, as a terminal void.
    ///
    ///      INVARIANT: code that reorders, inserts into, or removes from `superRareIds`, or that adds a
    ///      live-state filter here, breaks the frozen membership above.
    ///      Ids past index MAX_SR_SCAN are never scanned, so they are excluded from every draw (~60 Super
    ///      Rares are expected at a 3k mint, well under the bound).
    function _buildSrList(uint256 freeze) internal view returns (uint256[] memory srList, uint256 srCount) {
        uint256 n = superRareIds.length;
        if (n > MAX_SR_SCAN) n = MAX_SR_SCAN;
        srList = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 tid = superRareIds[i];
            uint64 ra = srRegisteredAt[tid];
            if (ra == 0 || uint256(ra) > freeze) continue; // registered after this draw's freeze (beacon already public): not this draw
            srList[srCount++] = tid;
        }
    }

    /// @dev ownerOf that never reverts (a burned/nonexistent ERC721 id can revert); returns 0 instead.
    function _safeOwnerOf(uint256 tid) internal view returns (address) {
        try nft.ownerOf(tid) returns (address o) { return o; } catch { return address(0); }
    }

    /// @dev Build the virtual free-entry config for a draw (freeze, eligible SR list, base weight, vPool).
    ///      vPool = cap (10% of the paid window) whenever any pass is eligible, MULTI-SHOT holds the 10% at
    ///      every volume by weighted repeats. Empty (vPool 0) before the freeze, on a zero-buy day, or with
    ///      no eligible passes, in which case drawFrom degenerates to today's paid-only behavior.
    function _buildFreeCfg(uint32 drawDay, uint256 paidRemaining, bool allowFree) internal view returns (FreeCfg memory cfg) {
        cfg.freeze = genesis + (uint256(drawDay) + 1) * DAY();
        if (!allowFree) return cfg; // opening sweep: paid-only by construction, independent of call timing
        if (address(nft) == address(0) || block.timestamp <= cfg.freeze) return cfg;
        uint256 cap = (paidRemaining * FREE_CAP_BPS) / 10_000;
        if (cap == 0) return cfg;
        (cfg.srList, cfg.srCount) = _buildSrList(cfg.freeze);
        cfg.wb = cfg.srCount * SR_WEIGHT + pledgeList[drawDay].length;
        if (cfg.wb > 0) cfg.vPool = cap;
    }

    /// @dev Resolve one virtual free seat: weighted pick over Super Rare (weight SR_WEIGHT each) + the
    ///      weight-expanded pledge copies, repeats allowed. Shared by drawFrom (commit) and previewDraw (view);
    ///      a pure function of (beacon, day, seat, frozen state), so preview == draw WITHIN THE DRAW WINDOW and
    ///      up to forfeiture (see the guarantee note below). Returns tid == NOT_SEATED (type(uint256).max, never
    ///      a real token id) when the seat voids. A seat voids for exactly two reasons: it rolled a Super Rare
    ///      whose pass changed hands after the freeze, or it rolled a pledge copy whose pass is no longer held by
    ///      its pledger or changed hands after the freeze. `seat` is the caller's virtual SLOT index, advanced
    ///      by the caller on a void as well as on a fill, so no two slots of a draw ever share a roll key and a
    ///      void never repeats at the next slot (see the sampling law).
    ///
    ///      THE GUARANTEE, stated exactly: a post-freeze transfer of a pass (Super Rare or pledged) can void that
    ///      pass's own seats and can do nothing else. It cannot move a win to a different pass, cannot change any
    ///      other seat's occupant or its single roll. A pass acquired after the freeze can never be paid. NOT
    ///      claimed: unqualified "preview == draw" (a preview taken before a pass moves differs from a draw run
    ///      after it by exactly that pass's seats).
    ///
    ///      Pick order (SR FIRST): on EVERY roll the Super Rare band [0, srWeightTotal) is resolved BEFORE
    ///      pledgeList is read. An SR-band roll resolves from FROZEN membership; it seats if that pass has not
    ///      changed hands since the freeze, and otherwise voids that seat TERMINALLY. No number of invalid
    ///      pledge copies can void or pre-empt it; only that pass's own owner can, by moving it. EVERY void is
    ///      terminal rather than a re-roll because a re-roll re-samples the whole region and would move the
    ///      seat onto a different token. The 8 : 4/2/1 ladder stays exact among seated seats because the void
    ///      term is not a band and redistributes nothing between bands.
    ///      (A voided seat is not paid to the vault: _payWinners divides each bucket by its realized winners,
    ///      so value only reaches the vault when a bucket ends up empty. See the sampling law.)
    function _pickVirtual(bytes32 beacon, uint32 day, FreeCfg memory cfg, uint256 seat)
        internal
        view
        returns (uint256 tid)
    {
        uint256 srWeightTotal = cfg.srCount * SR_WEIGHT;
        // ONE ROLL, TERMINAL IN EVERY OUTCOME. Both bands answer the same live-ownership question the same way:
        // seat the rolled pass, or VOID this seat. Nothing re-rolls, so no post-beacon act by any holder can move
        // a seat from one token to another: a seat has exactly one roll, keyed on (beacon, day, 1, seat).
        //   WHY TERMINAL, NOT A RE-ROLL: a re-roll re-samples the WHOLE region, so a transfer of the rolled pass
        //   would move the seat onto a DIFFERENT token and change that token's winIdx (_tidWinIndex) and the
        //   VTIER of its later wins, after the beacon is public. Keep both bands terminal.
        uint256 x = uint256(keccak256(abi.encode(beacon, day, uint256(1), seat))) % cfg.wb;
        // 1. Super Rare band: membership FROZEN at the freeze, so invalid pledge copies cannot reach this band.
        //    The `sos == 0` clause keeps an unstamped id ineligible: `<= freeze` alone would treat it as eligible.
        if (x < srWeightTotal) {
            uint256 srTid = cfg.srList[x % cfg.srCount];
            uint64 sos = nft.ownerSince(srTid);
            if (sos == 0 || uint256(sos) > cfg.freeze) return NOT_SEATED;
            return srTid;
        }
        // 2. Pledge region: same question, same terminal answer. A pledged copy whose pass changed hands after
        //    the freeze (or was never the pledger's) voids ITS OWN seat and nothing else.
        uint256 cand = pledgeList[day][x - srWeightTotal];
        if (pledgerOf[cand][day] != _safeOwnerOf(cand) || nft.ownerSince(cand) > cfg.freeze) return NOT_SEATED;
        return cand;
    }

    /// @dev Encode a virtual free winner as a self-describing synthetic id: top bit set, seat + a fresh
    ///      beacon-rolled tier (VTIER, on the pack bands) + the passholder address packed in. Decoded by
    ///      ownerOf/tierOf so RaffleEngine._payWinners pays the passholder in the right tier bucket verbatim.
    function _encodeVirtual(bytes32 beacon, uint32 day, uint256 seat, uint256 tid, uint256 winIdx, address passOwner)
        internal
        pure
        returns (uint256)
    {
        // VTIER is keyed on the FROZEN winning-pass identity (tid) plus this token's own win-index within the
        // draw (winIdx), NOT the live-mutable global seat counter. Two independent properties:
        //   * Fixed per win: a token's k-th win ALWAYS rolls keccak(beacon,day,2,tid,k). A post-beacon
        //     transfer / pledge-void / seat reshuffle cannot reassign which roll a win gets, and every win is paid.
        //   * Variance-correct: under multi-shot a token can win many seats; winIdx makes each of those wins an
        //     INDEPENDENT roll over the 1/4/15/80 bands instead of all sharing one tier, so a lone pass in a thin
        //     market does not take the whole SR bucket, and realized free value-share converges to ~9.09%.
        //     `seat` stays ONLY as the synthetic-id uniqueness nonce (the virtual slot index, which also advances
        //     over voided slots; gaps in it are voids, not reuse).
        uint8 vtier = _tierFromRoll(uint256(keccak256(abi.encode(beacon, day, uint256(2), tid, winIdx))) % 10_000);
        return VIRTUAL_FLAG | (seat << 168) | (uint256(vtier) << 160) | uint256(uint160(passOwner));
    }

    /// @dev How many of the first `count` virtual SLOTS (memory list, in slot order) were won by `tid`. This
    ///      is that token's win-index for its NEXT win. A voided slot holds 0, which is never a token id (the
    ///      collection mints 1..totalMinted), so voids never count. O(count) memory scan, count <= K <= 200;
    ///      identical in the commit (_drawCore) and view (_replayVirtual) paths so preview == draw holds.
    function _tidWinIndex(uint256[] memory wonTids, uint256 count, uint256 tid) internal pure returns (uint256 idx) {
        for (uint256 i; i < count; ++i) {
            if (wonTids[i] == tid) { unchecked { ++idx; } }
        }
    }

    function _popAt(uint32 c, uint256 li) internal returns (uint256 pickedId) {
        uint256[] storage arr = cohortLive[c];
        uint256 last = arr.length - 1;
        pickedId = arr[li];
        if (li != last) {
            uint256 lastId = arr[last];
            arr[li] = lastId;
            packLiveIndex[lastId] = li;
        }
        arr.pop();
        packs[pickedId].spent = true;
    }

    /// @dev Remove a pack from its cohort's live draw pool (swap-pop, mirrors _popAt) WITHOUT marking it
    ///      spent: a ripped non-winner leaves the pool but was never "won". Only called for
    ///      packs still live (isRipXpClaimable requires !spent), so packLiveIndex[id] is valid.
    function _removeLiveById(uint256 id) internal {
        uint256[] storage arr = cohortLive[packs[id].cohortDay];
        uint256 li = packLiveIndex[id];
        uint256 last = arr.length - 1;
        if (li != last) {
            uint256 lastId = arr[last];
            arr[li] = lastId;
            packLiveIndex[lastId] = li;
        }
        arr.pop();
    }

    // ─── tier derivation (verifiable) ────────────────────────────────────────

    /// @notice The tier of a pack, derived from its sealed beacon. Reverts until the round reveals.
    ///         Anyone can recompute this, the "verify this rip" affordance.
    function tierOf(uint256 packId) public view returns (uint8) {
        if (packId & VIRTUAL_FLAG != 0) return uint8((packId >> 160) & 3); // synthetic free-winner id: tier packed in
        return _tierFromRoll(rollOf(packId));
    }

    /// @notice The raw 0..9999 roll a pack revealed, keccak256(beacon, packId) % 10000. Reverts until
    ///         the round reveals. Anyone can recompute it off-chain, the "verify this rip" affordance,
    ///         and what the website's draw log / cards display next to the tier.
    function rollOf(uint256 packId) public view returns (uint256) {
        if (packId & VIRTUAL_FLAG != 0) revert VirtualId(); // synthetic free-winner id has no on-chain roll
        Pack storage p = packs[packId];
        require(p.owner != address(0), "no pack");
        bytes32 beacon = drand.randomness(p.revealRound); // reverts if not yet revealed
        return uint256(keccak256(abi.encodePacked(beacon, packId))) % 10_000;
    }

    /// @notice Tier + roll in one call (saves the consumer a second read).
    function tierAndRollOf(uint256 packId) external view returns (uint8 tier, uint256 roll) {
        roll = rollOf(packId);
        tier = _tierFromRoll(roll);
    }

    /// @dev The fixed, published rarity bands. SUPER_RARE 1% / RARE 4% / UNCOMMON 15% / COMMON 80%.
    function _tierFromRoll(uint256 roll) internal pure returns (uint8) {
        if (roll < 100) return SUPER_RARE; // 1%
        if (roll < 500) return RARE; // 4%
        if (roll < 2000) return UNCOMMON; // 15%
        return COMMON; // 80%
    }

    // ─── rip XP (non-winning packs) ──────────────────────────────────────────

    /// @notice Rarity weight of a non-winning rip: Common 1 / Uncommon 2 / Rare 4 / Super rare 10. Unitless: the
    ///         points a rip banks are this weight times RIP_XP_BPS of its cohort's ticket price (_ripXp).
    ///         NOTE for off-chain readers: this returns only the weight, not XP. claimRipXp's return value and
    ///         the RipXpClaimed event carry the points actually banked.
    function ripXpWeight(uint8 tier) public pure returns (uint256) {
        if (tier == SUPER_RARE) return 10;
        if (tier == RARE) return 4;
        if (tier == UNCOMMON) return 2;
        return 1; // COMMON
    }

    /// @dev Leaderboard points (WETH wei, the same unit as a buy's hook credit) that a final non-winning rip of
    ///      `tier` from cohort `cohortDay` banks. cohortMinTicketPrice is nonzero for every cohort that holds a
    ///      pack (_mintPacks writes it before the first push), and it is bounded by MAX_BANDABLE_PRICE (~9.3e72),
    ///      so the product stays below 1.7e76 and cannot overflow.
    function _ripXp(uint32 cohortDay, uint8 tier) internal view returns (uint256) {
        return (cohortMinTicketPrice[cohortDay] * ripXpWeight(tier) * RIP_XP_BPS) / 10_000;
    }

    /// @notice A pack is a FINAL non-winner once it is revealed, never drawn (not spent), and past the last
    ///         draw that could ever include it (cohortDay + LIFE_DAYS, drawn the following day). Only then
    ///         is its outcome settled, so rip XP can't double-count a pack that still might win.
    /// @dev    A pack of an OPENING cohort ([0, OPENING_COHORTS-1]) is additionally NOT claimable until
    ///         the engine reports openingDone(). The rule above is about the 7 daily windows, but the opening
    ///         sweeps those cohorts once, with no upper time bound, against a beacon that is public from about
    ///         genesis + 2 days + 1 hour. A rip swap-pops the pack out of its cohort (_removeLiveById), changing
    ///         the candidate count and index order, so gating the rip on the engine's own latch freezes the
    ///         opening's candidate set until it has settled (paid or forgone). If the opening settles only after
    ///         those cohorts' rip-XP window (day 15/16), their rip XP is not claimable; prizes are unaffected.
    ///         An unwired engine reads as "not settled", so the gate fails closed.
    function isRipXpClaimable(uint256 id) public view returns (bool) {
        Pack storage p = packs[id];
        if (p.owner == address(0) || p.spent || ripXpGranted[id]) return false;
        uint32 cohortDay = p.cohortDay;
        uint32 settled = cohortDay + LIFE_DAYS + 1; // last day it could be drawn has passed
        uint32 t = _today();
        if (t <= settled || t > settled + RIP_XP_WINDOW) return false; // one-week window: bounds the bankable week to two adjacent weeks
        if (cohortDay < OPENING_COHORTS && !_openingSettled()) return false; // opening candidates frozen
        return drand.isAvailable(p.revealRound); // revealed (tier is known)
    }

    /// @dev Opening latch read. `engine` is write-once; before it is wired nothing can have settled the opening.
    function _openingSettled() internal view returns (bool) {
        address e = engine;
        return e != address(0) && IEngineRound(e).openingDone();
    }

    /// @notice Bank rarity-weighted XP for your final non-winning ripped packs. Skips anything not yours /
    ///         already banked / still drawable / unrevealed / held back by the opening gate, so a mixed
    ///         batch never reverts. This is the on-chain "rip" the site fires; it credits the weekly leaderboard
    ///         and returns the XP gained so the UI can show it. Each pack banks _ripXp(cohortDay, tier), i.e.
    ///         RIP_XP_BPS of its cohort's ticket price per unit of rarity weight. Checks-effects-interactions:
    ///         ripXpGranted is set before the external calls (the leaderboard sink, and the engine's openingDone
    ///         view on the next iteration), and neither has a callback into this contract.
    function claimRipXp(uint256[] calldata packIds) external returns (uint256 total) {
        uint256 cnt;
        for (uint256 i; i < packIds.length; ++i) {
            uint256 id = packIds[i];
            Pack storage p = packs[id];
            if (p.owner != msg.sender || !isRipXpClaimable(id)) continue;
            ripXpGranted[id] = true; // effect before interaction
            _removeLiveById(id); // leave the live draw pool so no draw can also pay this pack
            total += _ripXp(p.cohortDay, tierOf(id));
            unchecked {
                ++cnt;
            }
        }
        if (total > 0) leaderboard.recordXp(msg.sender, total);
        emit RipXpClaimed(msg.sender, cnt, total);
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function _today() internal view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY());
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function ownerOf(uint256 packId) external view returns (address) {
        if (packId & VIRTUAL_FLAG != 0) return address(uint160(packId)); // synthetic free-winner id: owner packed in
        return packs[packId].owner;
    }

    /// @notice Is any non-empty cohort in `drawDay`'s sweep window still missing its tier round on the oracle?
    /// @dev    The read-only twin of the reveal guard inside `_drawCore`: same window, same per-cohort round, same
    ///         `isAvailable` question, so `pending == true` is exactly the condition under which a draw for
    ///         `drawDay` reverts `RevealPending(cohort, round)`. A tier round is bound once at mint and can never
    ///         be re-bound, so `RaffleEngine.runOpeningDraw` uses this, without reverting, to detect an opening
    ///         blocked by a tier round that was never produced; the keeper and the site use it to explain a
    ///         waiting draw instead of surfacing a raw revert.
    function revealPending(uint32 drawDay) external view returns (bool pending, uint32 cohort, uint64 round) {
        if (drawDay == 0) return (false, 0, 0);
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        for (uint32 c = from; c <= drawDay - 1; ++c) {
            uint256[] storage live = cohortLive[c];
            if (live.length == 0) continue; // empty cohorts pop nothing, so their reveal is irrelevant
            uint64 rr = packs[live[0]].revealRound; // every pack of cohort c shares this round (_mintPacks)
            if (!drand.isAvailable(rr)) return (true, c, rr);
        }
        return (false, 0, 0);
    }

    function cohortSize(uint32 cohortDay) external view returns (uint256) {
        return cohortLive[cohortDay].length;
    }

    /// @notice Total live PAID tickets eligible for the draw on `drawDay`.
    function liveCount(uint32 drawDay) external view returns (uint256) {
        return _liveCount(drawDay);
    }

    function _liveCount(uint32 drawDay) internal view returns (uint256 total) {
        if (drawDay == 0) return 0;
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        for (uint32 c = from; c <= drawDay - 1; ++c) {
            total += cohortLive[c].length;
        }
    }

    /// @notice The virtual free-entry cap for `day` = 10% of that day's live PAID window. In the multi-shot
    ///         model the realized free weight equals this whenever any pass is eligible, so it is also the
    ///         honest "spots today" figure for the UI.
    function capOf(uint32 day) external view returns (uint256) {
        return (_liveCount(day) * FREE_CAP_BPS) / 10_000;
    }

    function superRareCount() external view returns (uint256) {
        return superRareIds.length;
    }

    /// @notice Read-only replay of a day's virtual free winners (synthetic ids), for the UI. Uses the SAME
    ///         beacon and logic as drawFrom, so its output equals drawFrom's virtual subset. Reverts until the
    ///         day's beacon reveals. Paid winners are not identified here (only their count drives routing).
    function previewDraw(uint32 day) external view returns (uint256[] memory) {
        if (day == 0 || engine == address(0) || address(nft) == address(0)) return new uint256[](0);
        // The winner count in force for `day`, exactly as runDraw reads it, not the live winnersPerDay(): after a
        // scheduled change the two differ for a full period, and the preview must equal drawFrom's virtual subset.
        uint256 k = IEngineRound(engine).winnersPerDayAt(day);
        if (k > MAX_DRAW_K) k = MAX_DRAW_K; // same clamp as _drawCore
        bytes32 beacon = drand.randomness(IEngineRound(engine).drawRound(day)); // reverts until revealed
        uint256 paidRemaining = _liveCount(day);
        FreeCfg memory cfg = _buildFreeCfg(day, paidRemaining, true); // previewDraw mirrors the daily (free-enabled) path
        return _replayVirtual(beacon, day, k, paidRemaining, cfg);
    }

    /// @dev View-only replay of a day's virtual winners (paid hits only decrement the counter, since only
    ///      their count affects routing). Kept as its own function to stay under the stack limit.
    function _replayVirtual(bytes32 beacon, uint32 day, uint256 k, uint256 paidRemaining, FreeCfg memory cfg)
        internal
        view
        returns (uint256[] memory vwinners)
    {
        uint256 total = paidRemaining + cfg.vPool;
        vwinners = new uint256[](k);
        uint256[] memory wonTids = new uint256[](k); // mirrors _drawCore so preview == draw (VTIER winIdx)
        uint256 got;
        uint256 seat; // virtual SLOT counter, advanced on fill AND void exactly as in _drawCore (lockstep)
        for (uint256 j; j < k && total > 0; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, day, j))) % total;
            if (r < paidRemaining) {
                unchecked { --paidRemaining; }
            } else {
                uint256 tid = _pickVirtual(beacon, day, cfg, seat);
                if (tid != NOT_SEATED) {
                    address passOwner = _safeOwnerOf(tid);
                    if (passOwner != address(0)) {
                        uint256 winIdx = _tidWinIndex(wonTids, seat, tid);
                        vwinners[got++] = _encodeVirtual(beacon, day, seat, tid, winIdx, passOwner);
                        wonTids[seat] = tid;
                    }
                }
                unchecked { ++seat; } // void or fill: same nonce advance as _drawCore
            }
            unchecked { --total; }
        }
        assembly { mstore(vwinners, got) }
    }
}
