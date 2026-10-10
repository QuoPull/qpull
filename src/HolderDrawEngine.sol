// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  HolderDrawEngine, the weekly NFT-holder jackpot: 5 distinct winners, even split
/// @notice A weekly draw over the pass collection. Each week the engine picks 5 distinct winning tokenId
///         SLOTS out of the minted id space and pays each slot's owner pot/5 in QUOTRON from a dedicated
///         vault. Only tokens whose owner held >= MIN_HOLD passes continuously since the week's freeze instant
///         are eligible (frozen via the NFT's qualifiedSince stamp, not a live balanceOf). Selection is
///         per-token (sybil-neutral, G1), so a wallet's expected slots scale with the eligible passes it
///         holds. This is the funded holder jackpot: the vault is topped up on an ongoing basis
///         by the 6.25% holder share of the trade tax (Treasury's HOLDER_BPS), routed in on every
///         convert(), plus any optional mint-time seed. Each weekly pot is still min(freeBalance, potCap)
///         under POT_CAP_CEILING, and every unpaid share simply rolls forward inside the vault (void-on-miss).
///
/// @dev    DESIGN: BOUNDED REJECTION SAMPLING. COST IS O(1) IN SUPPLY.
///         There is no ownership snapshot, and nothing in this file reads, stores or assumes a supply number.
///         Bounded cost matters because Robinhood Chain caps a transaction at 32,000,000 gas
///         (ArbGasInfo.getMaxTxGasLimit).
///
///         The draw rests on two facts about the collection:
///           1. NFTCollection stamps `ownerSince[tokenId]` on every REAL change of hands (mint included, a
///              self transfer excluded), so continuous holding since an instant is a single SLOAD to prove.
///           2. Ids are minted SEQUENTIALLY from 1, so the minted set is exactly 1..nft.totalMinted(), and
///              `launched()` is one way and closes every mint path, so that bound is frozen before any
///              beacon for a drawable week exists.
///         The draw therefore walks a beacon-derived candidate sequence over 1..n, silently discards a
///         duplicate or ineligible candidate and re-rolls, up to a hard compile-time budget of MAX_REROLLS
///         candidates SHARED across all five slots, with an early exit once five are seated. Worst-case cost
///         is a compile-time constant: independent of MAX_SUPPLY, of turnover, and of holder behaviour.
///         Moving MAX_SUPPLY does not touch this contract, and no number here has to be kept in step with it.
///
///         Design guardrails:
///         G1 (proportional 5 slots, SYBIL-NEUTRAL): the draw picks 5 distinct tokenId SLOTS uniformly over
///           the eligible set, so a wallet's expected slots are LINEAR in the eligible passes it holds. Dedup
///           is per-TOKEN, NOT per-wallet, which keeps splitting neutral (8 passes are 8 eligible ids whether
///           in one wallet or two), and a wallet holding several winning tokenIds simply wins several shares.
///           The MIN_HOLD gate only filters WHICH ids are eligible; it does not change this linearity.
///         G2 (unpredictable): the seed is a TIME-LOCKED drand BLS round that publishes REVEAL_LAG after
///           the freeze instant snapDeadline(W), so it cannot be known while eligibility is still movable.
///           MUST be a BlsDrandOracle; an on-demand randomness source does not provide this.
///         G3 (frozen eligibility): eligibility is BOTH `ownerSince[tokenId] <= snapDeadline(W)` (the token
///           was held across the freeze) AND `qualifiedSince[owner] <= snapDeadline(W)` (the owner held
///           >= MIN_HOLD across the freeze), and the beacon publishes REVEAL_LAG after that instant. So a
///           pass bought, or a holding topped up to MIN_HOLD, after the freeze instant does not count for
///           W: both gates are frozen. The SELLER of a pass moved after the freeze instant is not paid
///           either: both sides of a post-freeze trade are ineligible and the slot re-rolls to a third
///           party (paying the seller would need stored ownership history).
///         G4 (bounded pot): the pot is min(freeBalance, potCap) under an immutable POT_CAP_CEILING, so each
///           week's payout stays bounded however much has rolled forward.
///         Reuses the protocol's void-on-miss rollover, pull-claims (ClaimManager) and a vault with no owner
///         withdrawal path.
contract HolderDrawEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand; // MUST be the time-locked BlsDrandOracle
    INFTCollection public immutable nft;
    IVault public immutable vault; // dedicated HolderDraw vault (its own QUOTRON inventory)
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;
    uint256 public immutable POT_CAP_CEILING; // hard, immutable upper bound on any weekly pot

    // `virtual` so a TESTNET-ONLY subclass can shorten these; mainnet + the full test suite keep the real
    // values (so the reveal-lag > sequencer-bound proof and the 7-day cadence stay exercised).
    function WEEK() public view virtual returns (uint256) { return 7 days; }
    // The settling beacon reveals REVEAL_LAG AFTER the freeze instant (snapDeadline), so no transfer that
    // still counts for the week can ever have seen it. SIZED TO ROBINHOOD CHAIN'S SEQUENCER CLOCK: RH's
    // SequencerInbox reports maxTimeVariation.delaySeconds = 345_600 (4 days, confirmed on-chain), the
    // maximum by which the sequencer may back-date block.timestamp. REVEAL_LAG exceeds it, 4.5 days > 4 days,
    // so the ordering is code-enforced rather than a trusted-sequencer assumption. The 7-day draw window
    // absorbs this and still leaves roughly 2.5 days to call runDraw after the beacon reveals.
    // ANY SUBCLASS THAT SHORTENS WEEK() MUST ALSO SHORTEN THIS, or drawRound binds to a beacon further out
    // than the draw window is wide and the week can never be drawn. See src/testnet/TestnetShortClock.sol.
    function REVEAL_LAG() internal view virtual returns (uint256) { return 4 days + 12 hours; }

    uint256 internal constant WINNERS = 5;
    /// @dev Hard ceiling on beacon re-rolls in ONE draw, shared across all five slots. NOT a tuning knob:
    ///      it is the only thing making runDraw's cost independent of supply, of turnover, and of holder
    ///      behaviour. Sized so the exhaustion branch stays unreachable while >= 10% of passes
    ///      are eligible (P ~ 2.5e-7 per week at E/n = 0.10; ~3e-49 at 0.50).
    uint256 internal constant MAX_REROLLS = 256;
    /// @notice The holder draw is holder-only: a winning tokenId's owner must have held at least this many
    ///         passes CONTINUOUSLY SINCE the week's freeze instant, proven by the NFT's qualifiedSince stamp
    ///         (not a live balanceOf, so a later top-up does not count for the week). It is a per-token
    ///         eligibility FILTER, not a per-wallet cap, so selection stays sybil-neutral (G1): 8 passes are 8
    ///         eligible ids whether held in one wallet or split across two. MUST equal NFTCollection.MIN_HOLD
    ///         (cross-checked in the constructor), since the NFT stamps qualifiedSince off its own copy.
    uint256 public constant MIN_HOLD = 4;

    uint256 public constant CLAIM_WINDOW = 30 days;
    /// @dev A caught registerClaim failure that left less than 1/CLAIM_OOG_DIVISOR of the gas it started with
    ///      is treated as an out-of-gas caused by the caller's gas limit, and reverts the draw instead of
    ///      skipping a winner. Same heuristic and divisor as QpullTaxHook's RecordOutOfGas.
    uint256 internal constant CLAIM_OOG_DIVISOR = 8;
    uint256 internal constant MAX_ADJ_BPS = 2500; // potCap re-peg: at most +/-25% per change

    /// @dev Largest value the +/-25% band can compute: it evaluates `cur * (BPS + MAX_ADJ_BPS)`, which must
    ///      not overflow, so POT_CAP_CEILING (and with it every potCap) is never allowed above this bound.
    ///      The limit is ~9.27e72, far above any real QUOTRON amount.
    uint256 internal constant MAX_BANDABLE_CAP = type(uint256).max / (BPS + MAX_ADJ_BPS);
    uint256 internal constant BPS = 10_000;

    // potCap and minPot are SCHEDULED, like exclusion (see _excludedAt / setExcluded): a write lands at
    // currentPeriod()+1 and is read through potCapAt / minPotAt, so a change never applies to the current
    // period or any earlier one. `potCap`/`minPot` hold the LIVE value the owner set; `prev*` holds
    // what the still-drawable period sees until the change becomes effective.
    // One "previous value" slot suffices because runDraw enforces currentPeriod() == week + 1, so the ONLY
    // week ever queried for pot sizing is currentPeriod()-1; older weeks are unreachable (drawn[week] + the
    // window guard).
    uint256 public potCap; // owner re-pegs within bounds; clamped by POT_CAP_CEILING
    uint256 public prevPotCap;
    uint64 public potCapEffectiveWeek; // 0 = never scheduled
    uint64 public lastPotAdjust;
    uint64 public lastMinPotAdjust; // cooldown anchor for setMinPot
    // MINIMUM pot below which a draw voids WITHOUT consuming the week, so a week is never spent on a
    // dust-sized payout. REQUIRED (> 0) at construction; the only config-independent guard is
    // pot/WINNERS == 0 (voids below 5 wei). Owner re-tunes via setMinPot.
    uint256 public minPot;
    uint256 public prevMinPot;
    uint64 public minPotEffectiveWeek; // 0 = never scheduled

    mapping(uint256 => bool) public drawn; // week => drawn
    // EXCLUSION, read as ONE SCHEDULED TOGGLE. `excluded[a]` is the value in force FROM
    // `exclEffectiveWeek[a]` onward and `!excluded[a]` is the value before it, so a write can only ever
    // change the answer for weeks strictly after the week it lands in (see _excludedAt and setExcluded).
    // Exclusion is read at draw time, after the beacon reveals, so both directions are scheduled.
    mapping(address => bool) public excluded; // optional: protocol/escrow addresses barred from winning
    mapping(address => uint64) public exclEffectiveWeek; // the week from which `excluded[a]` is in force

    event Drawn(uint256 indexed week, uint256 pot, uint256 winners);
    event SlotWon(uint256 indexed week, uint256 slot, uint256 tokenId, address winner);
    /// @dev This seated winner's registerClaim reverted, so its share was never reserved and rolls forward
    event SlotSkipped(uint256 indexed week, uint256 slot, uint256 tokenId, address winner);
    event Voided(uint256 indexed week, uint256 pot);
    /// @param effectivePeriod the period from which the new value applies (always currentPeriod()+1).
    ///        Emitted on every write, including a value-preserving one, so each scheduled change is
    ///        visible to monitoring.
    event PotCapSet(uint256 oldCap, uint256 newCap, uint64 effectivePeriod);
    /// @param effectivePeriod the period from which the new value applies (always currentPeriod()+1).
    ///        Emitted on every write, including a value-preserving one, so each scheduled change is
    ///        visible to monitoring.
    event MinPotSet(uint256 minPot, uint64 effectivePeriod);
    event ExcludedSet(address indexed account, bool excluded);

    error BadPotCap();
    error PotCapZero();
    error AbovePotCeiling();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error AlreadyDrawn();
    error OutsideWindow();
    error BadMinPot();
    error NoExclusionChange();
    error ExclusionChangePending();
    error NotExcluded();
    error MinHoldMismatch(); // the NFT stamps qualifiedSince off its own MIN_HOLD; the two must agree
    error ClaimOutOfGas(); // a gas-starved registerClaim reverts the draw rather than skip a winner

    constructor(
        address drand_,
        address nft_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 potCap_,
        uint256 potCapCeiling_,
        uint256 minPot_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (potCap_ == 0 || potCapCeiling_ == 0 || potCap_ > potCapCeiling_) {
            revert BadPotCap();
        }
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot(); // never 0, never above potCap
        // The frozen holder-count gate reads nft.qualifiedSince, which the NFT stamps off ITS MIN_HOLD. If the
        // two thresholds disagree, the engine's MIN_HOLD (and isEligible's contract) would be a lie. Pin them.
        if (INFTCollection(nft_).MIN_HOLD() != MIN_HOLD) revert MinHoldMismatch();
        drand = IDrandOracle(drand_);
        nft = INFTCollection(nft_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        genesis = genesis_;
        potCap = potCap_;
        if (potCapCeiling_ > MAX_BANDABLE_CAP) revert AbovePotCeiling(); // band must not overflow
        POT_CAP_CEILING = potCapCeiling_;
        minPot = minPot_;
    }

    // ─── views (mirror the sibling engines) ──────────────────────────────────

    function currentPeriod() public view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / WEEK();
    }

    /// @notice THE FREEZE INSTANT for `week`: the end of week W, which is also the start of week W+1.
    ///         A pass counts for week W's draw only if it last changed hands at or before this instant, so
    ///         eligibility for W stops moving here even though the draw itself runs during W+1. The settling
    ///         beacon is bound REVEAL_LAG PAST this instant, so it provably cannot publish while eligibility
    ///         is still movable.
    function snapDeadline(uint256 week) public view returns (uint256) {
        return genesis + (week + 1) * WEEK();
    }

    /// @notice The drand round settling `week`. It reveals REVEAL_LAG after the freeze instant, i.e. strictly
    ///         after eligibility for `week` has stopped moving (the G2/G3 invariant).
    function drawRound(uint256 week) public view returns (uint64) {
        return drand.roundAt(snapDeadline(week) + REVEAL_LAG());
    }

    /// @notice Is `tokenId` in `week`'s draw? The public eligibility check: a prospective buyer can see
    ///         whether a pass is already frozen out of a week BEFORE purchasing. It answers for ANY week,
    ///         including future ones, and it applies the exact same four tests the draw itself applies.
    function isEligible(uint256 week, uint256 tokenId) public view returns (bool) {
        if (!nft.launched()) return false;
        if (tokenId == 0 || tokenId > nft.totalMinted()) return false;
        uint64 os = nft.ownerSince(tokenId);
        if (os == 0 || uint256(os) > snapDeadline(week)) return false;
        address o;
        try nft.ownerOf(tokenId) returns (address o_) { o = o_; } catch { return false; }
        if (o == address(0) || _excludedAt(o, week)) return false;
        // holder-only draw, FROZEN at the freeze instant: the owner must have held >= MIN_HOLD continuously
        // since at or before snapDeadline(week). Reads the NFT's qualifiedSince stamp, NOT a live balanceOf,
        // so a top-up to MIN_HOLD after the freeze instant does not count for the week.
        uint64 qs = nft.qualifiedSince(o);
        return qs != 0 && uint256(qs) <= snapDeadline(week);
    }

    /// @notice Simulate `week`'s draw exactly. It calls the SAME selector runDraw calls, so the two can
    ///         never disagree. Reverts with the oracle until drawRound(week) reveals.
    function previewDraw(uint256 week)
        external
        view
        returns (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled)
    {
        if (!nft.launched()) return (won, winner, filled);
        uint256 n = nft.totalMinted();
        if (n < WINNERS) return (won, winner, filled);
        return _selectWinners(week, drand.randomness(drawRound(week)), n);
    }

    // ─── selection (shared by runDraw and previewDraw) ───────────────────────

    /// @dev The complete candidate sequence and eligibility filter for `week`. A pure function of
    ///      (beacon, week, n) and chain state. Writes nothing.
    ///
    ///      REJECTION CAUSES, ALL HANDLED BY `continue`, NEVER BY REVERT AND NEVER BY VOIDING THE WEEK, so a
    ///      single ineligible tokenId can never block the draw.
    ///        a. DUPLICATE: this id is already seated in this draw, so the "5 distinct winning tokenIds" promise
    ///           (G1) holds even at a tiny minted count. Deliberately per-TOKEN, not per-wallet. See G1.
    ///        b. TOO LATE: never minted, or the token changed hands after the freeze instant.
    ///        c. INELIGIBLE OWNER: ownerOf reverts, or returns address(0), or the owner is excluded.
    ///        d. NOT QUALIFIED: the owner's qualifiedSince is 0 or later than the freeze instant, i.e. it did
    ///           NOT hold >= MIN_HOLD continuously since the freeze (holder-only draw, FROZEN not live).
    ///      Checked cheapest-reject-first: memory scan, then one SLOAD, then the ownerOf/qualifiedSince staticcalls.
    ///
    ///      TERMINATION: `j` is bounded by a compile-time constant and `continue` still runs the for-update
    ///      expression, so this executes at most MAX_REROLLS iterations in EVERY state. If anyone ever
    ///      rewrites it as a `while`, the increment must sit where no `continue` can skip it.
    ///      `nft` is immutable, so both staticcalls hit a fixed address with fixed selectors and 32-byte
    ///      returndata.
    function _selectWinners(uint256 week, bytes32 beacon, uint256 n)
        internal
        view
        returns (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled)
    {
        uint256 freeze = snapDeadline(week);
        for (uint256 j; j < MAX_REROLLS; ++j) {
            // PINNED: abi.encode (NOT encodePacked) of (bytes32 beacon, uint256 week, uint256 j). All three
            // are fixed-width, so the encoding is unambiguous, and the sequence is reproducible
            // off-chain by anyone.
            uint256 tid = (uint256(keccak256(abi.encode(beacon, week, j))) % n) + 1;

            bool dup; // (a) 5 DISTINCT TOKENS. Memory only, so it is the cheapest reject.
            for (uint256 k; k < filled; ++k) {
                if (won[k] == tid) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            uint64 os = nft.ownerSince(tid); // (b) one staticcall, one cold SLOAD
            if (os == 0 || uint256(os) > freeze) continue;

            address o; // (c) ownerOf may revert on a burned or non-existent id
            try nft.ownerOf(tid) returns (address o_) {
                o = o_;
            } catch {
                continue;
            }
            // try/catch does NOT cover a ZERO RETURN, and an ERC721 that answers address(0) instead of
            // reverting is legal. A zero owner must never reach ClaimManager.registerClaim, which reverts
            // ZeroRecipient, so it is rejected like any ineligible candidate. MANDATORY, not decoration.
            if (o == address(0)) continue;
            if (_excludedAt(o, week)) continue; // `week`, NEVER currentPeriod()
            // (d) HOLDER-ONLY, FROZEN: the owner must have held >= MIN_HOLD continuously since the freeze
            //     instant. qualifiedSince is stamped by the NFT off ITS MIN_HOLD (cross-checked at
            //     construction). It is read instead of a live balanceOf so a top-up after the freeze instant
            //     does not count, which is what the freeze-before-beacon design requires.
            uint64 qs = nft.qualifiedSince(o);
            if (qs == 0 || uint256(qs) > freeze) continue;

            won[filled] = tid;
            winner[filled] = o;
            unchecked {
                ++filled;
            }
            if (filled == WINNERS) break;
        }
    }

    // ─── draw (following week only; void-on-miss) ────────────────────────────

    /// @notice Draw `week`, permissionless, callable only during week+1. Ineligible or duplicate candidates
    ///         are re-rolled, never reverted on. Each seated slot is paid a flat pot/WINNERS; the share of
    ///         any slot the re-roll budget failed to seat is simply never reserved, so it stays in
    ///         vault.freeBalance() and rolls into next week's pot.
    function runDraw(uint256 week) external nonReentrant {
        if (drawn[week]) revert AlreadyDrawn();
        if (currentPeriod() != week + 1) revert OutsideWindow(); // the following week only, else void

        // The domain 1..n MUST be frozen before the beacon exists. `launched` is one-way and closes every
        // mint path, so totalMinted is constant from that instant forever. The gate keeps n fixed, since any
        // change to n would reshuffle the WHOLE candidate sequence through `% n`.
        if (!nft.launched()) {
            emit Voided(week, 0);
            return; // do NOT mark drawn
        }
        uint256 n = nft.totalMinted();
        if (n < WINNERS) {
            emit Voided(week, 0);
            return; // do NOT mark drawn; this also guards the `% n` below against n == 0
        }

        // Read the pot BEFORE anything else; a zero pot does not consume the draw (retry if funded in-window).
        uint256 pot = vault.freeBalance();
        uint256 capForWeek = potCapAt(week); // scheduled, not live (see potCapAt)
        if (pot > capForWeek) pot = capForWeek;
        if (pot < minPotAt(week) || pot / WINNERS == 0) {
            emit Drawn(week, pot, 0);
            return; // do NOT mark drawn (sub-minPot or per-winner-zero dust never burns the week)
        }

        bytes32 beacon = drand.randomness(drawRound(week)); // reverts until the time-locked round reveals

        (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled) =
            _selectWinners(week, beacon, n);

        if (filled == 0) {
            emit Voided(week, pot);
            return; // do NOT mark drawn (consistent with every other miss branch)
        }

        // FLAT SHARE. The dust (pot % WINNERS) and any unseated slot's share stay unreserved and roll
        // forward via freeBalance. NEVER pot/filled: a flat pot/WINNERS keeps every slot's payout the same
        // however many slots are seated, so no single tokenId can ever take the whole weekly pot.
        // The payout loop lives in its own frame, like RaffleEngine._payWinners, to keep runDraw within
        // the via_ir stack limit.
        _payHolders(week, pot, pot / WINNERS, filled, won, winner);
    }

    /// @dev Register one flat share per seated winner, each isolated: one reverting registerClaim must not
    ///      unpay the others. A skipped share is never reserved, so it rolls forward exactly like an unseated
    ///      slot's. A caught failure that left less than 1/CLAIM_OOG_DIVISOR of the gas it started with is
    ///      treated as an out-of-gas caused by the caller's gas limit and reverts the whole draw, so a skip
    ///      always reflects a genuine registerClaim revert.
    ///      It also consumes the week, and only if at least one claim registered, so a week where every
    ///      registration reverted stays retryable. The beacon is unchanged, so a retry inside the window
    ///      re-runs the SAME winner set, never a re-roll. Consuming here rather than in runDraw keeps that
    ///      frame inside the via_ir stack.
    function _payHolders(
        uint256 week,
        uint256 pot,
        uint256 share,
        uint256 filled,
        uint256[WINNERS] memory won,
        address[WINNERS] memory winner
    ) internal {
        uint256 paid;
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        for (uint256 i; i < filled; ++i) {
            uint256 g = gasleft();
            try claimManager.registerClaim(address(vault), winner[i], share, deadline) {
                unchecked { ++paid; }
                emit SlotWon(week, i, won[i], winner[i]);
            } catch {
                if (gasleft() < g / CLAIM_OOG_DIVISOR) revert ClaimOutOfGas();
                emit SlotSkipped(week, i, won[i], winner[i]);
            }
        }
        if (paid == 0) {
            emit Drawn(week, pot, 0);
            return;
        }
        drawn[week] = true;
        emit Drawn(week, pot, filled);
    }

    // ─── admin (owner = the launch Safe, after script/TransferOwnership.s.sol) ─

    /// @notice Re-peg the per-week pot cap, bounded like the ticket price: at most +/-25% per change, at
    ///         most once a week, and never above the immutable POT_CAP_CEILING.
    function setPotCap(uint256 newCap) external onlyOwner {
        uint256 p = currentPeriod();
        uint256 cur = potCapAt(p); // the value in force NOW; promotes any already-effective pending value
        if (newCap == 0) revert PotCapZero();
        // Cross-knob validation: bound against BOTH the minPot in force now and the scheduled (live) minPot,
        // so minPotAt(p) <= potCapAt(p) holds in every period, including the one where both scheduled
        // values take effect.
        uint256 floorNow = minPotAt(p);
        uint256 floorBound = floorNow > minPot ? floorNow : minPot; // strictest of {effective now, scheduled}
        if (newCap < floorBound) revert BadMinPot(); // cap can never sit below the minPot floor
        // The band below computes cur * (BPS + MAX_ADJ_BPS), so every value potCap can ever hold must stay
        // <= MAX_BANDABLE_CAP. This one check is enough: POT_CAP_CEILING is immutable, the constructor
        // reverts unless potCap_ <= potCapCeiling_ <= MAX_BANDABLE_CAP, and this is the only other potCap
        // writer.
        if (newCap > POT_CAP_CEILING) revert AbovePotCeiling();
        if (block.timestamp < uint256(lastPotAdjust) + WEEK()) revert AdjustTooSoon();
        // PERIOD-based guard, in addition to the timestamp cooldown (which alone would allow writes in two
        // consecutive periods), as in setExcluded: a prior scheduled change must be in force AND aged past
        // its effective period before another may be scheduled, so `prev` is only ever overwritten once no
        // drawable period still needs it.
        if (potCapEffectiveWeek != 0 && currentPeriod() <= uint256(potCapEffectiveWeek)) revert AdjustTooSoon();
        // Ceil the lower bound so the band cannot widen past +/-25% at small values.
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS;
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1; // band never collapses to a point
        if (newCap < lo || newCap > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        prevPotCap = cur; // freeze what the still-payable week sees
        potCap = newCap;
        potCapEffectiveWeek = uint64(p + 1); // never affects a week that can still be drawn
        emit PotCapSet(cur, newCap, potCapEffectiveWeek);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the week.
    ///         Must stay > 0 and <= potCap.
    function setMinPot(uint256 m) external onlyOwner {
        uint256 p = currentPeriod();
        uint256 cur = minPotAt(p);
        // Cross-knob validation: bound against BOTH the potCap in force now and the scheduled (live) potCap,
        // so minPotAt(p) <= potCapAt(p) holds in every period, including the one where both scheduled
        // values take effect.
        uint256 capNow = potCapAt(p);
        uint256 capBound = capNow < potCap ? capNow : potCap; // tightest of {effective now, scheduled}
        if (m == 0 || m > capBound) revert BadMinPot();
        // One change per week, within a +/-25% band (as setPotCap) that never collapses to a point. The band
        // and cooldown bound size and rate; scheduling to p+1 keeps a change off any week that can still be
        // drawn.
        if (block.timestamp < uint256(lastMinPotAdjust) + WEEK()) revert AdjustTooSoon();
        // PERIOD-based guard, in addition to the timestamp cooldown (which alone would allow writes in two
        // consecutive periods), as in setExcluded: a prior scheduled change must be in force AND aged past
        // its effective period before another may be scheduled, so `prev` is only ever overwritten once no
        // drawable period still needs it.
        if (minPotEffectiveWeek != 0 && currentPeriod() <= uint256(minPotEffectiveWeek)) revert AdjustTooSoon();
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS; // ceil, see setPotCap
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        prevMinPot = cur; // freeze what the still-payable week sees
        minPot = m;
        minPotEffectiveWeek = uint64(p + 1);
        emit MinPotSet(m, minPotEffectiveWeek);
    }

    /// @notice The pot cap in force AS OF `week`. Mirrors _excludedAt: a write at period P lands at P+1,
    ///         and a draw only ever queries W = currentPeriod()-1 = P-1 < P+1, so no write can alter the
    ///         answer for any week that is still drawable.
    function potCapAt(uint256 week) public view returns (uint256) {
        uint64 e = potCapEffectiveWeek;
        return (e == 0 || week >= uint256(e)) ? potCap : prevPotCap;
    }

    /// @notice The minPot floor in force AS OF `week`. Same scheduling guarantee as potCapAt.
    function minPotAt(uint256 week) public view returns (uint256) {
        uint64 e = minPotEffectiveWeek;
        return (e == 0 || week >= uint256(e)) ? minPot : prevMinPot;
    }

    /// @notice Was `a` excluded AS OF `week`. Immune to owner writes in BOTH directions: every write lands at
    ///         currentPeriod()+1, and setExcluded's cooldown guarantees no write can alter the answer for any
    ///         week <= currentPeriod().
    function _excludedAt(address a, uint256 week) internal view returns (bool) {
        uint64 e = exclEffectiveWeek[a];
        if (e == 0) return false; // never configured
        return week >= uint256(e) ? excluded[a] : !excluded[a];
    }

    /// @notice Bar an address (protocol/escrow) from winning, or lift the bar. Either way the change takes
    ///         effect the FOLLOWING week, and because a week is drawn during the week after it, the effective
    ///         public notice is two weeks.
    /// @dev    BOTH DIRECTIONS NEED NOTICE, because exclusion is read at draw time, after the beacon reveals.
    ///         The pair of mappings is therefore read as ONE SCHEDULED TOGGLE by _excludedAt, and this
    ///         function enforces that a pending change has been in force a full week before another can be
    ///         scheduled.
    ///
    ///         PROOF that a write at week P can only change the answer for weeks >= P+1. The write sets
    ///         e_new = P+1, and a draw only ever queries W = currentPeriod()-1, so W <= P.
    ///           - After the write, the answer for any w <= P is `!v_new`, since w < e_new.
    ///           - NoExclusionChange forces v_new != v_old. The cooldown forces P > e_old, hence P-1 >= e_old,
    ///             so the pre-write answer for every w in [e_old, P] was v_old == !v_new. IDENTICAL.
    ///           - First-ever write: the pre-write answer is false (e == 0), v_new must be true, and the
    ///             post-write answer `!v_new` is false. IDENTICAL.
    ///         A no-op repeat of the same value reverts, as does a toggle inside the cooldown. The practical
    ///         cost is one exclusion change per address per two weeks, so burn and dead addresses must be
    ///         barred EARLY rather than reactively.
    function setExcluded(address account, bool v) external onlyOwner {
        uint64 e = exclEffectiveWeek[account];
        if (e == 0) {
            // A first write of `false` is meaningless, and it would make the `!excluded[a]` branch of
            // _excludedAt answer TRUE for every past week. Reject it.
            if (!v) revert NotExcluded();
        } else {
            if (excluded[account] == v) revert NoExclusionChange(); // must be a real toggle
            // the prior change must have been in force a FULL week before another is scheduled
            if (currentPeriod() <= uint256(e)) revert ExclusionChangePending();
        }
        excluded[account] = v;
        exclEffectiveWeek[account] = uint64(currentPeriod() + 1);
        emit ExcludedSet(account, v);
    }
}
