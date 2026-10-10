// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { PackRegistry } from "./PackRegistry.sol";

/// @title  RaffleEngine
/// @notice Runs the DAILY draw. Snapshots capBps of the PrizeVault's free QUOTRON, capped at potCap, as
///         the pot, splits it into fixed tier buckets, draws a fixed K winners from the live set, and
///         writes a claim to each winner for its tier's share. Fully on-chain, O(K).
///
/// @dev    Tier buckets (of the pot): SuperRare 45% / Rare 25% / Uncommon 20% / Common 10%.
///         A tier with no winner this day isn't paid: its share stays in the vault and swells the
///         next snapshot (the Super-Rare rollover/climb). A lone SR winner takes at most the 45%
///         bucket; the other 55% is guaranteed to the lower tiers (the per-tier bucket IS the cap).
///         Void-on-miss: a day is drawable ONLY during the following day; miss it and its pot
///         simply stays in the vault. There is no catch-up, so draw timing gives the keeper no advantage.
contract RaffleEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand;
    PackRegistry public immutable packs;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    // Daily-draw cadence. `virtual` so the TESTNET-ONLY subclass shortens it; MAINNET uses the real 1 day.
    // Mirrors the holder-draw and leaderboard cadence getters. MUST equal PackRegistry.DAY() (both default
    // 1 day), enforced at construction against PackRegistry.dayLength() (mirrors the genesis cross-check).
    function DAY() internal view virtual returns (uint256) { return 1 days; }
    uint256 public constant CLAIM_WINDOW = 30 days;
    /// @dev A caught registerClaim failure that left less than 1/CLAIM_OOG_DIVISOR of the gas it started with is
    ///      treated as the caller supplying too little gas, and reverts the draw instead of skipping a winner.
    ///      Same heuristic and divisor as QpullTaxHook's RecordOutOfGas.
    uint256 internal constant CLAIM_OOG_DIVISOR = 8;
    // Settling beacon reveals REVEAL_LAG after the day closes, so it is unknowable while any in-day ticket
    // is still buyable (mirrors PackRegistry's revealDelay). A DAILY cadence keeps REVEAL_LAG under one day,
    // since it must leave a same-following-day draw window.
    // `virtual` so a TESTNET-ONLY subclass can shorten it alongside DAY(). ANY SUBCLASS THAT SHORTENS DAY()
    // MUST ALSO SHORTEN THIS, or drawRound() binds the settling beacon further out than the draw window
    // (`currentDay() == day + 1`, one DAY() wide) ever reaches, and runDraw can never find its beacon.
    function REVEAL_LAG() internal view virtual returns (uint256) { return 1 hours; }

    /// @notice How long after a day closes its settling beacon publishes.
    /// @dev    A cohort's TIER round is roundAt(genesis + (c+1)*DAY() + PackRegistry.revealDelay()) and a day's
    ///         DRAW round is roundAt(genesis + (day+1)*DAY() + REVEAL_LAG()). EQUAL values make the two coincide,
    ///         so one beacon a day suffices (the mainnet configuration). Unequal values are also valid: the two
    ///         rounds are then distinct and the keeper posts both (the short-clock testnet pair runs 1 minute
    ///         against a 2-minute registry delay). There is therefore no constructor equality check;
    ///         `script/Deploy.s.sol` asserts the equality for MAINNET by reading this getter.
    function revealLag() external view returns (uint256) {
        return REVEAL_LAG();
    }
    /// @dev Sentinel for a winner whose tier could not be resolved. Never a valid tier (0..3) and never an
    ///      index into `counts`, so an unresolvable seat is excluded from the split rather than voiding it.
    uint8 internal constant TIER_UNRESOLVED = type(uint8).max;

    // Sized to fit one transaction: a K = 200 runDraw measured as its own transaction on cold storage needs
    // 30,538,485 gas before refunds in the worst shape tested (7 cohorts, 128 Super Rares, 90 pledged Rares;
    // 29,320,421 paid-only), against Robinhood Chain's 32M per-transaction limit;
    // test/RunDrawIsolatedGas.t.sol gates it at 32M - 1M.
    uint256 public constant MAX_K = 200;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ADJ_BPS = 2500; // re-peg band: each knob moves at most +/-25% per cooldown

    /// @dev Largest potCap the +/-25% band can compute: the band evaluates `cur * (BPS + MAX_ADJ_BPS)`,
    ///      which overflows in Solidity 0.8 above this bound and would leave the re-peg knob unusable. The
    ///      limit is ~9.27e72, far above any real QUOTRON amount (QUOTRON's whole supply is ~1.4e21 base
    ///      units; even QPULL's 1e27 is far below it), so this refuses only values the band cannot handle,
    ///      such as `type(uint256).max` as an "uncapped" sentinel.
    uint256 internal constant MAX_BANDABLE_CAP = type(uint256).max / (BPS + MAX_ADJ_BPS);
    // ── launch accumulation window: NO draws for the first 48h while packs + pool build, then the
    // one-time opening draw runs, then normal daily draws. ACCUM_DAYS * DAY = 48h on mainnet (DAY=1d) and
    // 10 min on the short-day testnet (DAY=5m), so it scales automatically with DAY. ──
    uint256 internal constant ACCUM_DAYS = 2; // accumulation window length, in days
    /// @dev Whole days AFTER the accumulation window closes before an underfunded opening may be forgone.
    ///      In day units, so it compresses with DAY() on the testnet short clock exactly like ACCUM_DAYS.
    uint256 internal constant FORGO_GRACE_DAYS = 1;
    /// @dev Whole days AFTER the accumulation window closes before a FUNDED opening whose needed beacon was
    ///      never posted may be forgone. Long on purpose: submitBeacon is permissionless and drand keeps
    ///      every round it produces, so any round someone posts in time takes the paid path; only a round nobody
    ///      posted for this long is abandoned. Day units, so it compresses with DAY() on the testnet short clock.
    uint256 internal constant OPENING_BEACON_GRACE_DAYS = 7;
    uint256 public constant OPENING_WINNERS = 5; // the opening draw splits the built-up pool 5 ways

    // Scheduled knobs. winnersPerDay, minPot and potCap (and capBps below) each take effect from
    // currentDay()+1 and are read through *At(day) helpers, so a value written after a day's beacon is public
    // never applies to that day. The +/-25% band and the per-day cooldown bound MAGNITUDE and RATE; the
    // schedule removes REACTIVITY. Same pattern as HolderDrawEngine's exclusion schedule (_excludedAt).
    // K matters as much as the pot: drawFrom's selection for K is a strict PREFIX of K+1, so K decides WHO
    // wins, not just how much.
    // runDraw enforces currentDay() == day + 1, so the only day ever queried is currentDay()-1;
    // older days are unreachable (drawn[day] + the window guard), so one "previous value" slot suffices.
    uint256 public winnersPerDay; // K
    uint256 public prevWinnersPerDay;
    uint64 public winnersEffectiveDay; // 0 = never scheduled
    // Owner-set MINIMUM pot below which a draw voids WITHOUT consuming the day or burning tickets, so live
    // tickets are never spent on dust-sized prizes. REQUIRED (> 0, and <= potCap) at construction; there is
    // no 0 default.
    uint256 public minPot;
    uint256 public prevMinPot;
    uint64 public minPotEffectiveDay;
    // potCap (below): owner-set bound on a single day's payout. The tier-bucket split caps a winner's
    // FRACTION, and potCap caps the pot's absolute size. REQUIRED (> 0) at construction, matching minPot and
    // HolderDrawEngine. Excess over the cap rolls forward.
    // Opening snapshots: the one-shot opening needs values frozen BEFORE its beacon can exist, not merely
    // scheduled. runDraw's guard is TWO-SIDED (currentDay() == day + 1), which locks the sized day and the
    // call time one apart, so scheduling is enough there. runOpeningDraw's guard is ONE-SIDED
    // (currentDay() >= ACCUM_DAYS) and its beacon is pinned to drawRound(ACCUM_DAYS - 1), which goes public
    // at ~day 2 and stays public while the call time is unbounded.
    // These snapshots are settable ONLY while currentDay() < ACCUM_DAYS, which is provably before the
    // reveal, so pre-launch tuning stays possible and post-reveal reactivity is zero.
    uint256 public openingPotCap;
    uint256 public openingMinPot;
    uint256 public openingCapBps; // the daily FRACTION, frozen for the one-shot opening (same reasoning)

    /// @notice Fraction of the vault a single day may pay, in bps. THE PRIMARY CEILING; `potCap` is an
    ///         absolute backstop behind it.
    /// @dev    A fixed absolute cap needs owner upkeep as volume moves: too small and the vault accumulates
    ///         while prizes stay flat, too large and it empties, then days void until tax refills.
    ///         A FRACTION self-regulates in both directions with zero owner input: the pot grows with the
    ///         vault, shrinks with it, and can never empty it. Each day takes a share of what remains, so
    ///         the decay is geometric (3.9%/day at 10% with ~39% payout efficiency) rather than linear.
    ///         Steady state falls out on its own: the vault settles at ~25.6x daily inflow and payouts equal
    ///         inflow, returning to that equilibrium by itself when volume changes.
    ///         SCHEDULED like every other knob, so settlement never reads a value set after that day's beacon
    ///         is public.
    uint256 public capBps;
    uint256 public prevCapBps;
    uint64 public capBpsEffectiveDay;
    /// @dev Hard ceiling on capBps: a single day can never pay more than half the vault.
    uint256 internal constant MAX_CAP_BPS = 5000;

    uint256 public potCap;
    uint256 public prevPotCap;
    uint64 public potCapEffectiveDay;
    uint64 public lastPotAdjust; // timestamp of the last setPotCap (cooldown anchor)
    uint64 public lastCapBpsAdjust; // timestamp of the last setCapBps (cooldown anchor)
    uint64 public lastMinPotAdjust; // cooldown anchor for setMinPot
    uint64 public lastWinnersAdjust; // cooldown anchor for setWinnersPerDay
    mapping(uint32 => bool) public drawn;
    bool public openingDone; // set by runOpeningDraw(); daily runDraw() unlocks only after it, and
    // PackRegistry.isRipXpClaimable holds rip XP back on the opening cohorts until it is set

    /// @param effectivePeriod the day from which the new value applies (always currentDay()+1).
    ///        Emitted so a value-preserving "promote" write is visible to monitoring.
    event WinnersPerDaySet(uint256 k, uint64 effectivePeriod);
    event CapBpsSet(uint256 capBps, uint64 effectivePeriod);
    event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners);
    /// @dev the one-time opening was settled WITHOUT paying anyone, on the caller's explicit instruction
    event OpeningForgone(uint256 pot, uint256 floor);
    /// @dev a FUNDED opening was settled without paying anyone because a round it needs was still unposted
    ///      OPENING_BEACON_GRACE_DAYS after the window closed, on the caller's explicit instruction
    event OpeningBeaconMissing(uint64 round, uint256 pot);
    /// @dev the opening was forgone because a SWEPT COHORT's tier round was still unposted, not its own
    ///      settling round. Emitted alongside OpeningBeaconMissing, which carries that cohort's round.
    event OpeningCohortRevealMissing(uint32 cohortDay, uint64 round);
    /// @dev an owner tuned a knob AFTER the opening window closed, so the OPENING half of that write was
    ///      silently discarded. The ordinary knob still moved; the opening value did not. Emitted because
    ///      the alternative -- succeeding in total silence -- is how a stale GENESIS turns the operator's
    ///      pre-launch tuning into a no-op that reports success.
    event OpeningTuningIgnored(bytes32 indexed knob, uint256 requested, uint256 keptOpeningValue);
    /// @notice A seat that could not be paid was SKIPPED rather than reverting the whole draw. `stage` says
    ///         which external call failed: 0 = tierOf, 1 = ownerOf, 2 = registerClaim. What happens to the
    ///         money depends on the stage (see _payWinners): a stage-0 seat has no tier, so it is left out of
    ///         every bucket's winner count and its bucket is split among that bucket's resolved winners; a
    ///         stage-1/2 seat was counted, so its share is not registered and stays in the vault. An unposted
    ///         cohort reveal does not cause a stage-0 skip: the draw reverts PackRegistry.RevealPending before
    ///         popping anything. This event is the ONLY signal that a winner was dropped, so monitor it.
    event WinnerSkipped(uint32 indexed day, uint256 indexed packId, uint8 stage);

    /// @notice One per winning pack. Lets the website's draw log show the ticket, its tier, and the prize
    ///         per win (DrawExecuted only carries the count). day 0 = the one-time opening sweep.
    event WinnerPaid(uint32 indexed day, uint256 indexed packId, address owner, uint8 tier, uint256 prize, uint256 claimId);
    /// @param effectivePeriod the day from which the new value applies (always currentDay()+1).
    ///        Emitted so a value-preserving "promote" write is visible to monitoring.
    event MinPotSet(uint256 minPot, uint64 effectivePeriod);
    /// @param effectivePeriod the day from which the new value applies (always currentDay()+1).
    ///        Emitted so a value-preserving "promote" write is visible to monitoring.
    event PotCapSet(uint256 potCap, uint64 effectivePeriod);

    error AlreadyDrawn();
    error BadDay();
    error OutsideWindow();
    error BadK();
    error GenesisMismatch();
    error CadenceMismatch(); // PackRegistry.dayLength() != this DAY() (mis-paired mainnet/testnet deploy)
    error BadPotCap();
    error BadCapBps();
    error BadMinPot(); // minPot is 0 or above the pot cap
    error AdjustTooSoon(); // the knob's cooldown or pending schedule has not elapsed
    error AdjustOutOfBounds(); // outside the +/-25% re-peg band
    error OpeningPending(); // runDraw() called before the opening draw
    error OpeningAlreadyDone();
    error Accumulating(); // opening called before the 48h window closed
    /// @dev the opening pot is under the floor RIGHT NOW; retry when the vault is funded, or forgo on purpose
    error PotBelowOpeningFloor(uint256 pot, uint256 floor);
    error TooSoonToForgo(); // an underfunded opening cannot be thrown away in the window's first day
    error ClaimOutOfGas(); // a gas-starved registerClaim reverts the draw rather than skip a winner
    error DrawKMismatch(); // PackRegistry.MAX_DRAW_K() != MAX_K (the registry would clamp draws)
    error OpeningCohortsMismatch(); // PackRegistry.OPENING_COHORTS() != ACCUM_DAYS (rip gate on wrong cohorts)


    constructor(
        address drand_,
        address packs_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 k_,
        uint256 minPot_,
        uint256 potCap_,
        uint256 capBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        // potCap is REQUIRED (> 0) at construction, with no uncapped default. minPot is REQUIRED (> 0) and
        // cross-checked <= potCap at construction too (the config-independent pot guard alone only floors at
        // ~10*winnersPerDay wei). Fail-closed on-chain exactly like HolderDrawEngine.
        if (potCap_ == 0 || potCap_ > MAX_BANDABLE_CAP) revert BadPotCap(); // band must not overflow
        // REQUIRED, no default, so a wrong value can never hide behind a silent fallback. 1000 = 10%/day is
        // the launch value.
        if (capBps_ == 0 || capBps_ > MAX_CAP_BPS) revert BadCapBps();
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot();
        drand = IDrandOracle(drand_);
        packs = PackRegistry(packs_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        if (PackRegistry(packs_).genesis() != genesis_) revert GenesisMismatch(); // same genesis as the registry
        // Cadence cross-check: drawRound/currentDay here and _today/revealRound in the registry all assume ONE
        // day length, so a mainnet engine cannot be paired with a short-clock registry (or vice versa).
        // DAY() dispatches to the most-derived override, so the testnet pair (5m/5m) passes exactly like 1d/1d.
        if (PackRegistry(packs_).dayLength() != DAY()) revert CadenceMismatch();
        // Two more halves of the pair that must agree. The registry clamps every draw's k to MAX_DRAW_K (so a
        // smaller value would silently cap draws below the K this engine accepts), and it holds rip XP back on
        // cohorts [0, OPENING_COHORTS-1] until openingDone, which must be exactly the cohorts the opening
        // sweeps.
        if (PackRegistry(packs_).MAX_DRAW_K() != MAX_K) revert DrawKMismatch();
        if (PackRegistry(packs_).OPENING_COHORTS() != ACCUM_DAYS) revert OpeningCohortsMismatch();

        genesis = genesis_;
        if (k_ == 0 || k_ > MAX_K) revert BadK();
        winnersPerDay = k_;
        minPot = minPot_;
        potCap = potCap_;
        openingPotCap = potCap_; // frozen for the one-shot opening unless retuned pre-ACCUM_DAYS
        openingMinPot = minPot_;
        capBps = capBps_;
        openingCapBps = capBps_;
    }

    /// @notice The winner count in force AS OF `day`. A write at day P lands at P+1, and runDraw only
    ///         ever queries D = currentDay()-1 = P-1 < P+1, so no write can re-target a still-drawable day.
    function winnersPerDayAt(uint256 day) public view returns (uint256) {
        uint64 e = winnersEffectiveDay;
        return (e == 0 || day >= uint256(e)) ? winnersPerDay : prevWinnersPerDay;
    }

    /// @notice The minPot floor in force AS OF `day`. Same scheduling guarantee.
    function minPotAt(uint256 day) public view returns (uint256) {
        uint64 e = minPotEffectiveDay;
        return (e == 0 || day >= uint256(e)) ? minPot : prevMinPot;
    }

    /// @notice The vault FRACTION in force AS OF `day`, in bps. Same scheduling guarantee as the others.
    function capBpsAt(uint256 day) public view returns (uint256) {
        uint64 e = capBpsEffectiveDay;
        return (e == 0 || day >= uint256(e)) ? capBps : prevCapBps;
    }

    /// @notice The pot cap in force AS OF `day`. Same scheduling guarantee.
    function potCapAt(uint256 day) public view returns (uint256) {
        uint64 e = potCapEffectiveDay;
        return (e == 0 || day >= uint256(e)) ? potCap : prevPotCap;
    }

    /// @notice Re-peg the daily vault fraction. Same scheduling and banding as the sibling knobs.
    function setCapBps(uint256 b) external onlyOwner {
        uint256 d = currentDay();
        uint256 cur = capBpsAt(d);
        if (b == 0 || b > MAX_CAP_BPS) revert BadCapBps();
        // Period guard: a prior scheduled change must have aged past its effective period.
        if (capBpsEffectiveDay != 0 && d <= uint256(capBpsEffectiveDay)) revert AdjustTooSoon();
        if (block.timestamp < uint256(lastCapBpsAdjust) + DAY()) revert AdjustTooSoon();
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS; // ceil
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1;
        if (b < lo || b > hi) revert AdjustOutOfBounds();
        lastCapBpsAdjust = uint64(block.timestamp);
        if (d < ACCUM_DAYS) openingCapBps = b; // pre-reveal tuning only
        else emit OpeningTuningIgnored("capBps", b, openingCapBps);
        prevCapBps = cur;
        capBps = b;
        capBpsEffectiveDay = uint64(d + 1);
        emit CapBpsSet(b, capBpsEffectiveDay);
    }

    function setWinnersPerDay(uint256 k) external onlyOwner {
        if (k == 0 || k > MAX_K) revert BadK();
        // Cooldown + the same +/-25% band as setPotCap, so K moves at most ~25% per draw-day (matching the
        // sibling knobs). The band never collapses to a point.
        if (block.timestamp < uint256(lastWinnersAdjust) + DAY()) revert AdjustTooSoon();
        // PERIOD-based guard (the timestamp cooldown alone allows writes on two consecutive periods). The
        // schedule keeps one `prev` slot, so a prior scheduled change must be in force AND aged past its
        // effective period before another may be scheduled: `prev` is only ever overwritten once no drawable
        // period still needs it.
        if (winnersEffectiveDay != 0 && currentDay() <= uint256(winnersEffectiveDay)) revert AdjustTooSoon();
        // `lo` is rounded UP so small values cannot step down past the +/-25% band, symmetric with the
        // collapse guard on `hi`.
        uint256 cur = winnersPerDayAt(currentDay()); // band off what is in force NOW (promotes a due pending)
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS;
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1;
        if (k < lo || k > hi) revert AdjustOutOfBounds();
        lastWinnersAdjust = uint64(block.timestamp);
        prevWinnersPerDay = cur; // freeze what the still-drawable day sees
        winnersPerDay = k;
        winnersEffectiveDay = uint64(currentDay() + 1); // cannot re-target a day whose beacon is public
        emit WinnersPerDaySet(k, winnersEffectiveDay);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the day.
    ///         Cross-checked against potCap: minPot > potCap would silently void every draw.
    function setMinPot(uint256 m) external onlyOwner {
        uint256 cur = minPotAt(currentDay());
        // Cross-knob validation covers the period where BOTH scheduled values are in force, not just the one
        // in force NOW: bounding against both the currently-effective and the live (future) sibling keeps
        // minPotAt(p) <= potCapAt(p) even when minPot and potCap are both written in the same period.
        uint256 capNow = potCapAt(currentDay());
        uint256 capBound = capNow < potCap ? capNow : potCap; // tightest of {effective now, scheduled}
        if (m == 0 || m > capBound) revert BadMinPot(); // never 0, never above potCap
        // Cooldown plus setPotCap's +/-25% band, so minPot moves gradually. hi is floored at minPot+1 so the
        // band never collapses to a point (minPot <= 3).
        if (block.timestamp < uint256(lastMinPotAdjust) + DAY()) revert AdjustTooSoon();
        // PERIOD-based guard, same as setWinnersPerDay: `prev` is only ever overwritten once no drawable
        // period still needs it.
        if (minPotEffectiveDay != 0 && currentDay() <= uint256(minPotEffectiveDay)) revert AdjustTooSoon();
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS; // ceil, see setWinnersPerDay
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        if (currentDay() < ACCUM_DAYS) openingMinPot = m; // pre-reveal tuning only
        else emit OpeningTuningIgnored("minPot", m, openingMinPot);
        prevMinPot = cur;
        minPot = m;
        minPotEffectiveDay = uint64(currentDay() + 1);
        emit MinPotSet(m, minPotEffectiveDay);
    }

    /// @notice Bound a single day's payout. Excess over the cap rolls forward.
    /// @dev    Rate-limited to +/-25% per draw-day and one change per day (matching HolderDrawEngine).
    ///         Larger moves take several days.
    function setPotCap(uint256 c) external onlyOwner {
        uint256 cur = potCapAt(currentDay());
        // Cross-knob validation covers the period where BOTH scheduled values are in force, not just the one
        // in force NOW: bounding against both the currently-effective and the live (future) sibling keeps
        // minPotAt(p) <= potCapAt(p) even when minPot and potCap are both written in the same period.
        if (c == 0 || c > MAX_BANDABLE_CAP) revert BadPotCap(); // keep the band computable
        uint256 floorNow = minPotAt(currentDay());
        uint256 floorBound = floorNow > minPot ? floorNow : minPot; // strictest of {effective now, scheduled}
        if (c < floorBound) revert BadPotCap(); // never below the minPot floor
        if (block.timestamp < uint256(lastPotAdjust) + DAY()) revert AdjustTooSoon();
        // PERIOD-based guard, same as setWinnersPerDay: `prev` is only ever overwritten once no drawable
        // period still needs it.
        if (potCapEffectiveDay != 0 && currentDay() <= uint256(potCapEffectiveDay)) revert AdjustTooSoon();
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS; // ceil
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1; // band never collapses to a point
        if (c < lo || c > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        // The opening's snapshot tracks the knob ONLY while the accumulation window is still open, which
        // is provably before drawRound(ACCUM_DAYS-1) reveals, so this can never be reactive.
        if (currentDay() < ACCUM_DAYS) openingPotCap = c;
        else emit OpeningTuningIgnored("potCap", c, openingPotCap);
        prevPotCap = cur;
        potCap = c;
        potCapEffectiveDay = uint64(currentDay() + 1);
        emit PotCapSet(c, potCapEffectiveDay);
    }

    /// @notice The drand round whose beacon settles day `day`. It publishes REVEAL_LAG after day+1 opens,
    ///         so it is unknowable while any in-window ticket is still being bought.
    function drawRound(uint32 day) public view returns (uint64) {
        return drand.roundAt(genesis + (uint256(day) + 1) * DAY() + REVEAL_LAG());
    }

    /// @notice Whether the one-time opening's knobs can still be tuned. They are frozen the instant the
    ///         accumulation window closes, and the setters that write them SUCCEED past that point while
    ///         discarding the opening half (see OpeningTuningIgnored), so ask this before assuming a
    ///         pre-launch tune landed. A GENESIS pinned days before the real go-live makes this false in the
    ///         very first block of trading, which is the case worth checking for. No on-chain consumer;
    ///         script/GoLiveMainnet.s.sol's preflight calls it.
    function openingWindowOpen() public view returns (bool) {
        return currentDay() < ACCUM_DAYS;
    }

    function currentDay() public view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY());
    }

    /// @notice Tier bucket share in bps. 0=Common,1=Uncommon,2=Rare,3=SuperRare.
    function bucketBps(uint8 tier) public pure returns (uint256) {
        if (tier == 3) return 4500; // Super Rare 45%
        if (tier == 2) return 2500; // Rare 25%
        if (tier == 1) return 2000; // Uncommon 20%
        return 1000; // Common 10%
    }

    /// @notice The one-time OPENING draw. After the 48h accumulation window (ACCUM_DAYS), split the built-up
    ///         pool among OPENING_WINNERS winners drawn from ALL packs bought during the window (the rolling
    ///         draw window for drawDay ACCUM_DAYS already spans cohorts [0, ACCUM_DAYS-1], so no cohort voids).
    ///         Daily draws (runDraw) unlock only after this settles. Same pot/tier logic as a normal draw.
    ///         Permissionless, callable any time from currentDay() >= ACCUM_DAYS with no upper bound; the
    ///         production keeper (keeper.js) calls it once openingWillPay() is true.
    ///         FOUR OUTCOMES, and three of them settle (openingDone = true):
    ///         1. PAID. The pot (openingCapBps of the vault, capped at openingPotCap) clears openingMinPot and
    ///            can pay every opening winner at least 1 wei: OPENING_WINNERS packs are popped and paid.
    ///            REVERTS, latching nothing, while the opening beacon drawRound(ACCUM_DAYS-1) is unposted
    ///            (drand.randomness) or while any live cohort in [0, ACCUM_DAYS-1] has an unposted tier round
    ///            (PackRegistry.RevealPending). Post the round and retry. (See outcome 4 for a round that is
    ///            never posted.)
    ///         2. UNDERFUNDED, NOT DECLARED. `forgoIfUnderfunded == false`: REVERTS PotBelowOpeningFloor and
    ///            latches nothing. Fund the vault (Treasury.convert) and retry.
    ///         3. FORGONE, DECLARED. `forgoIfUnderfunded == true` AND currentDay() >= ACCUM_DAYS +
    ///            FORGO_GRACE_DAYS: settles with no payout, no popped ticket and no beacon read, and the pot rolls
    ///            forward into the daily draws, which cover the same cohorts and self-void under minPot until
    ///            the vault is funded. Before the grace day it reverts TooSoonToForgo.
    ///         4. A NEEDED ROUND NEVER POSTED, DECLARED. The pot is funded, but either the opening beacon or a
    ///            swept cohort's TIER round is still unposted, `forgoIfUnderfunded == true` AND
    ///            currentDay() >= ACCUM_DAYS + OPENING_BEACON_GRACE_DAYS:
    ///            settles like outcome 3 (no payout, no popped ticket, the pot rolls forward), so a round drand
    ///            never produced cannot hold every daily draw behind OpeningPending forever. With every needed
    ///            round posted the call always takes the paid path instead, however late it lands.
    ///         Runbook: fund the vault so openingCapBps of it clears openingMinPot before the window closes.
    /// @dev    Cohorts [0, ACCUM_DAYS-1] are NOT consumed whole here: the opening pops only OPENING_WINNERS
    ///         packs, and those cohorts stay eligible for the normal 7-day window (including a later
    ///         runDraw(ACCUM_DAYS)). A forgone opening pops nothing at all, so those cohorts keep every ticket
    ///         for that window. `potCap` bounds EACH draw independently; it is a per-draw cap plus rollover,
    ///         not a per-cohort-lifetime cap. No pack or wei is ever paid twice: popped packs are marked spent,
    ///         and each draw reserves its own snapshotted pot.
    /// @param forgoIfUnderfunded  the caller's EXPLICIT consent to throw the opening away if the vault is
    ///        below the floor, or if its own beacon or a swept cohort's tier round is still unposted
    ///        OPENING_BEACON_GRACE_DAYS after the window closed. Pass FALSE unless you mean it.
    function runOpeningDraw(bool forgoIfUnderfunded) external nonReentrant {
        if (openingDone) revert OpeningAlreadyDone();
        if (currentDay() < ACCUM_DAYS) revert Accumulating(); // pool still building: no draw during the window

        uint256 pot = (vault.freeBalance() * openingCapBps) / BPS; // frozen fraction, same reasoning as below
        // The opening reads the pre-reveal snapshot below (see the openingPotCap storage comment), not a
        // scheduled value. The call window is deliberately unbounded: a narrow window would turn any keeper,
        // relay or funding delay into a permanently lost opening.
        uint256 capForOpen = openingPotCap; // frozen pre-reveal; see the storage comment above
        if (pot > capForOpen) pot = capForOpen; // bound the payout; excess rolls forward
        if (pot < openingMinPot || (pot * bucketBps(0)) / BPS < OPENING_WINNERS) {
            // THE FORGO MUST BE DECLARED. This branch reads an INSTANTANEOUS snapshot ("is the vault below the
            // floor right now"), which is not the same as "this opening must never pay": "not funded YET" is the
            // normal state at window close, since the vault fills through Treasury.convert(), which is
            // keeper-gated and threshold-gated.
            //
            // So the underfunded case is a LOUD, RETRYABLE REVERT that latches nothing, and only a caller that
            // explicitly passes `true` may settle it empty, and not before the grace day. It stays
            // permissionless, so anyone can unblock the daily draws once the grace has passed and the vault
            // genuinely never funded.
            if (!forgoIfUnderfunded) revert PotBelowOpeningFloor(pot, openingMinPot);
            if (currentDay() < ACCUM_DAYS + FORGO_GRACE_DAYS) revert TooSoonToForgo();
            // Too small to pay every opening winner >= 1 wei, and the caller has DECLARED the forgo after the
            // grace day. The opening is FORGONE: settle it so the daily draws unlock, pay nobody, burn no
            // tickets (no sweep, so cohorts [0, ACCUM_DAYS-1] keep every ticket for the daily rolling window
            // that already spans them), read no beacon (a forgone opening must not depend on drand being on
            // time), and let the pot roll forward: the daily draws self-void under minPot until funded.
            // This branch is reachable only once currentDay() >= ACCUM_DAYS (the Accumulating guard above) AND
            // the pot is unpayable at this instant, so a payable opening can never be skipped through it: any
            // pot >= openingMinPot (and >= OPENING_WINNERS wei in the Common bucket) takes the paid path below.
            openingDone = true;
            emit OpeningForgone(pot, openingMinPot); // the irreversible act, observable in logs
            emit DrawExecuted(0, pot, 0);
            return;
        }
        // beacon settles right after the window closes: round at genesis + ACCUM_DAYS*DAY + REVEAL_LAG
        uint64 openingRound = drawRound(uint32(ACCUM_DAYS - 1));
        // Escape for a FUNDED opening whose needed round was never PRODUCED, so it cannot hold every daily draw
        // behind OpeningPending indefinitely. Two rounds can strand it: its own settling round (drand.randomness
        // below), and any swept cohort's TIER round, which PackRegistry binds once at mint and never re-binds,
        // so _drawCore would keep reverting RevealPending.
        // Long after the window, and only on the caller's explicit consent, such an opening settles like the
        // declared forgo: no payout, no popped ticket, the pot rolls forward into the daily draws, which sweep
        // the same cohorts and self-void until the stuck cohort ages out of their 7-day window.
        // The check is AVAILABILITY, not time alone: with every needed round posted the call always takes the
        // paid path, however late it lands, and in every other case it reaches drand.randomness and reverts.
        // `isAvailable` is false both for a round drand never produced AND for one that exists in drand's
        // archive but has not been relayed here yet (submitBeacon is permissionless, so anyone can relay it).
        // Two positive conditions therefore gate the escape:
        //   `roundAt(now) > missing`: drand's schedule is a pure function of genesis + period, so the round's
        //   own publish instant is in the PAST. With the OPENING_BEACON_GRACE_DAYS wait, it was due days ago.
        //   `highestRound() > missing`: a LATER beacon has been relayed, so drand did not halt at the missing
        //   round and it was genuinely skipped, not merely unrelayed. If drand halted outright there is no
        //   later beacon and no daily draw can settle either, so forgoing the opening would repair nothing.
        if (forgoIfUnderfunded && currentDay() >= ACCUM_DAYS + OPENING_BEACON_GRACE_DAYS) {
            (bool cohortPending, uint32 stuckCohort, uint64 stuckRound) = packs.revealPending(uint32(ACCUM_DAYS));
            // the round actually being discarded: the cohort tier round takes precedence, as the event does
            uint64 missing = cohortPending ? stuckRound : openingRound;
            if (
                drand.roundAt(block.timestamp) > missing && drand.highestRound() > missing
                    && (!drand.isAvailable(openingRound) || cohortPending)
            ) {
                openingDone = true;
                // name the round that could not be read: the opening's own, or the cohort tier round
                emit OpeningBeaconMissing(cohortPending ? stuckRound : openingRound, pot);
                if (cohortPending) emit OpeningCohortRevealMissing(stuckCohort, stuckRound);
                emit DrawExecuted(0, pot, 0);
                return;
            }
        }
        bytes32 beacon = drand.randomness(openingRound);
        // PAID-ONLY: the opening beacon is already public relative to a day-ACCUM_DAYS free freeze, so the
        // free block must be structurally excluded here regardless of when this permissionless call lands.
        // drawFromPaidOnly REVERTS RevealPending, before popping anything, while any live cohort in the
        // sweep has an unposted tier round, so the latch below is never reached with an unpayable winner in hand.
        uint256[] memory winners = packs.drawFromPaidOnly(beacon, uint32(ACCUM_DAYS), OPENING_WINNERS); // sweeps [0, ACCUM_DAYS-1]
        // Mark the opening settled the moment the sweep runs, REGARDLESS of whether the accumulation window
        // held any tickets: the window [0, ACCUM_DAYS-1] can never be back-filled once it has passed, and the
        // daily draws must unlock even if nobody bought in the first ACCUM_DAYS. Like the declared-forgo
        // branches above, every non-reverting exit leaves openingDone=true and the daily draws unlocked.
        openingDone = true;
        if (winners.length == 0) {
            emit DrawExecuted(0, pot, 0);
            return; // opening settled with no early tickets; daily draws then sweep later cohorts
        }
        _payWinners(0, pot, winners, false); // day 0 = the one-time opening sweep. openingDone already latched above:
        // the opening MUST settle even if no prize registers, or every daily draw stays behind OpeningPending.
        // A daily draw instead consumes its day only once a prize registers; the pot is untouched by a failed
        // registration either way.
        emit DrawExecuted(0, pot, winners.length);
    }

    function runDraw(uint32 day) external nonReentrant {
        if (!openingDone) revert OpeningPending(); // daily draws start only after the opening sweep
        if (drawn[day]) revert AlreadyDrawn();
        if (day < ACCUM_DAYS) revert BadDay(); // the window's days were settled by the opening draw
        if (currentDay() != day + 1) revert OutsideWindow(); // the day after only, else void

        // Snapshot the pot BEFORE touching tickets. If nothing is payable, do NOT run the draw: drawFrom
        // marks tickets spent, so drawing on a zero pot would burn ticket eligibility for no payout. The day
        // is not marked drawn either, so a retry can still pay out if the vault is funded later within this
        // window; missing the whole window voids the day and the pot rolls forward.
        // Fraction of the vault first (the primary ceiling), then the absolute backstop.
        uint256 pot = (vault.freeBalance() * capBpsAt(day)) / BPS;
        uint256 capForDay = potCapAt(day); // scheduled, not live
        uint256 kForDay = winnersPerDayAt(day); // the winner SET is frozen against a public beacon
        if (pot > capForDay) pot = capForDay; // bound the single-day payout; excess rolls forward
        // Skip (WITHOUT burning tickets or marking the day drawn) when the pot is too small to pay even a full
        // field of winners in the SMALLEST tier bucket. Guarantees every drawn winner receives >=1 wei.
        if (pot < minPotAt(day) || (pot * bucketBps(0)) / BPS < kForDay) {
            emit DrawExecuted(day, pot, 0);
            return; // retry when funded (sub-minPot dust never consumes the day or burns tickets)
        }

        bytes32 beacon = drand.randomness(drawRound(day)); // reverts if beacon missing (retry within window)
        // Reverts RevealPending (retry within window) while any live in-window cohort's tier round is
        // unposted, before a single pack is popped and before `drawn[day]` below is written.
        uint256[] memory winners = packs.drawFrom(beacon, day, kForDay);
        if (winners.length == 0) {
            // An empty ticket window pops nothing: do NOT consume the day, so a later retry can draw.
            emit DrawExecuted(day, pot, 0);
            return;
        }
        // _payWinners consumes the day itself, but ONLY once a prize actually registered, and emits
        // DrawExecuted either way. It owns both so runDraw stays within the via_ir stack limit.
        _payWinners(day, pot, winners, true);
    }

    /// @dev Resolve each winner's tier, then write a claim for its equal share of its tier bucket. Single
    ///      combined division: (pot·bps)/(BPS·count). Unpaid buckets stay in the vault.
    /// @dev PER-WINNER FAULT ISOLATION. This loop makes three external calls per winner (tierOf, ownerOf,
    ///      registerClaim), each wrapped in try/catch, so one failing winner is skipped (WinnerSkipped)
    ///      instead of reverting the whole draw and leaving its co-winners unpaid. Same pattern as
    ///      `Treasury._trySendQuotron` (each vault send) and `NFTCollection.withdrawProceeds` (each launch
    ///      bucket).
    ///
    ///      WHERE A SKIPPED SEAT'S MONEY GOES, by stage:
    ///        * stage 0 (tierOf): the seat has no tier, so it is excluded from `counts` and each bucket is
    ///          split among its RESOLVED winners only. The seat's would-be share is REDISTRIBUTED to its
    ///          same-tier co-winners (it reaches the vault only if its whole bucket ends up empty).
    ///        * stage 1/2 (ownerOf, registerClaim): the seat was counted, so its share is computed but never
    ///          registered, and stays in the vault for later draws, like an empty tier bucket.
    ///      Either way a skipped PACK is already popped and spent: it earns no claim and no rip XP.
    ///
    ///      registerClaim reverts only on NotEngine, WrongVault, ZeroRecipient, BadDeadline, or an
    ///      insufficient vault reserve. A cohort whose reveal beacon is unposted never reaches `tierOf` here:
    ///      PackRegistry._drawCore reverts RevealPending for the whole draw before popping. The catches cover
    ///      every other cause (an oracle that reports isAvailable but reverts randomness, a zero owner, a
    ///      reserve shortfall).
    /// @param consumeDay true for a daily draw: mark the day drawn and emit DrawExecuted here, but only if a
    ///        prize actually registered. False for the opening sweep, which latches and emits on its own
    ///        because it MUST settle even when nothing registers.
    function _payWinners(uint32 day, uint256 pot, uint256[] memory winners, bool consumeDay) internal {
        uint256 n = winners.length;
        uint8[] memory tiers = new uint8[](n);
        uint256[4] memory counts;
        for (uint256 i; i < n; ++i) {
            // Stage 0. tierOf -> rollOf -> drand.randomness would revert while a cohort's reveal beacon is
            // unposted, but PackRegistry._drawCore reverts RevealPending before popping such a pack, so that
            // cause cannot reach here. The catch covers any other tierOf fault (see @dev above).
            try packs.tierOf(winners[i]) returns (uint8 t) {
                tiers[i] = t;
                unchecked {
                    counts[t] += 1;
                }
            } catch {
                tiers[i] = TIER_UNRESOLVED; // excluded from counts, so the split is over payable seats only
                emit WinnerSkipped(day, winners[i], 0);
            }
        }
        uint256 paid = _registerWins(day, pot, winners, tiers, counts);
        if (!consumeDay) return; // the opening draw latches openingDone itself and emits its own DrawExecuted
        // Consume the day only once a prize is actually REGISTERED, so a sweep where every registerClaim
        // failed leaves the day retryable. A gas-starved call reverts the whole draw (ClaimOutOfGas), so
        // paid == 0 means every seat failed for a reason other than gas, and leaving the day unconsumed
        // costs nothing: the pot is re-snapshotted on the retry. Same rule as LeaderboardEngine.distribute.
        if (paid == 0) {
            emit DrawExecuted(day, pot, 0);
            return;
        }
        drawn[day] = true;
        emit DrawExecuted(day, pot, winners.length);
    }

    /// @dev Second half of _payWinners, in its own frame so each function stays within the via_ir stack limit.
    /// @return paid how many claims were registered (the day is consumed only on a non-zero count)
    function _registerWins(
        uint32 day,
        uint256 pot,
        uint256[] memory winners,
        uint8[] memory tiers,
        uint256[4] memory counts
    ) internal returns (uint256 paid) {
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        uint256 n = winners.length;
        for (uint256 i; i < n; ++i) {
            uint8 t = tiers[i];
            if (t == TIER_UNRESOLVED) continue; // never index counts[] with the sentinel
            uint256 prize = (pot * bucketBps(t)) / (BPS * counts[t]);
            // Unreachable given the callers' pot guards, kept as a one-comparison defence against a future edit
            // to them: both runOpeningDraw and runDraw return before a draw unless
            // (pot * bucketBps(0)) / BPS >= K, and counts[t] <= n <= K with bucketBps(t) >= bucketBps(0), so
            // pot * bucketBps(t) >= K * BPS >= BPS * counts[t] and prize >= 1.
            if (prize == 0) continue;
            // Stage 1.
            try packs.ownerOf(winners[i]) returns (address owner) {
                // registerClaim reverts ZeroRecipient on a zero address. Cheaper to skip here than to pay for
                // the revert and catch it.
                if (owner == address(0)) {
                    emit WinnerSkipped(day, winners[i], 1);
                    continue;
                }
                // Stage 2.
                uint256 g = gasleft();
                try claimManager.registerClaim(address(vault), owner, prize, deadline) returns (uint256 claimId) {
                    unchecked { ++paid; }
                    emit WinnerPaid(day, winners[i], owner, t, prize, claimId); // per-win draw-log record
                } catch {
                    // A permissionless caller controls the gas. Never read a starved call as a
                    // faulty winner: revert the whole draw so it can be retried with enough gas.
                    if (gasleft() < g / CLAIM_OOG_DIVISOR) revert ClaimOutOfGas();
                    emit WinnerSkipped(day, winners[i], 2);
                }
            } catch {
                emit WinnerSkipped(day, winners[i], 1);
            }
        }
    }
}
