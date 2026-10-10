// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { LeaderboardRegistry } from "./LeaderboardRegistry.sol";

/// @title  LeaderboardEngine
/// @notice Distributes the weekly leaderboard pot to the top-25 buyers PRO-RATA by points. Each
///         board member's share is its points over ALL of the week's points (registry.totalPoints, buyers
///         and rip XP alike), so the top 25 collectively receive their fraction of the week's points and the
///         rest of the pot stays in the vault (see distribute).
///         Linear weighting is sybil-NEUTRAL: splitting one wallet's points across many wallets yields
///         the same total share, so there is no incentive to split. A whale still earns proportional to its
///         volume, which is the nature of a volume board; concentration is limited only by the top-25 cap,
///         not by the weighting curve.
/// @dev    Deterministic, no beacon. Drawable ONLY during the immediately following week (void-on-miss,
///         like the sibling engines), since the pot is a live freeBalance snapshot. A missed week's accrual
///         simply rolls forward into the next distributed week's pot.
contract LeaderboardEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    LeaderboardRegistry public immutable registry;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;
    uint256 public immutable weekAnchor; // Sunday 00:00 UTC anchor, derived from genesis (matches registry)

    // `virtual` so a TESTNET-ONLY subclass can shorten the week; mainnet + tests keep 7 days (Sunday-aligned).
    // MUST equal LeaderboardRegistry.WEEK(), enforced at construction (cadence cross-check).
    function WEEK() public view virtual returns (uint256) { return 7 days; }
    uint256 public constant CLAIM_WINDOW = 30 days;
    /// @dev A caught registerClaim failure that left less than 1/CLAIM_OOG_DIVISOR of the gas it started with
    ///      is treated as an out-of-gas caused by the caller's gas limit, and reverts the payout instead of
    ///      skipping a member. Same heuristic and divisor as QpullTaxHook's RecordOutOfGas.
    uint256 internal constant CLAIM_OOG_DIVISOR = 8;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ADJ_BPS = 2500; // potCap/minPot re-peg bounded to +/-25% per change

    /// @dev Largest value the +/-25% band can compute: it evaluates `cur * (BPS + MAX_ADJ_BPS)`, which must
    ///      not overflow, so potCap is never allowed above this bound. The limit is ~9.27e72, far above any
    ///      real QUOTRON amount.
    uint256 internal constant MAX_BANDABLE_CAP = type(uint256).max / (BPS + MAX_ADJ_BPS);

    // potCap bounds a single week's payout; the excess rolls forward. REQUIRED (> 0) at construction, since
    // a sole board member in a quiet week holds 100% of totalPoints.
    // potCap and minPot are SCHEDULED: a write lands at currentWeek()+1 and is read through *At(week), so a
    // change never applies to the current week or any earlier one. One previous-value slot suffices because
    // distribute enforces currentWeek() == week + 1, so the only week ever queried is currentWeek()-1; older
    // weeks are unreachable (distributed[week] + guard).
    uint256 public potCap;
    uint256 public prevPotCap;
    uint64 public potCapEffectiveWeek; // 0 = never scheduled
    uint256 public minPot; // floor below which distribute voids WITHOUT consuming the week
    uint256 public prevMinPot;
    uint64 public minPotEffectiveWeek;
    uint64 public lastPotAdjust; // timestamp of the last setPotCap (cooldown anchor)
    uint64 public lastMinPotAdjust; // cooldown anchor for setMinPot
    mapping(uint256 => bool) public distributed;

    event Distributed(uint256 indexed week, uint256 pot, uint256 winners);
    /// @dev This member's registerClaim reverted, so its share was never reserved and rolls forward
    event ShareSkipped(uint256 indexed week, address indexed member, uint256 share);
    /// @param effectivePeriod the week from which the new value applies (always currentWeek()+1).
    ///        Emitted on every write, including a value-preserving one, so each scheduled change is
    ///        visible to monitoring.
    event PotCapSet(uint256 potCap, uint64 effectivePeriod);
    /// @param effectivePeriod the week from which the new value applies (always currentWeek()+1).
    ///        Emitted on every write, including a value-preserving one, so each scheduled change is
    ///        visible to monitoring.
    event MinPotSet(uint256 minPot, uint64 effectivePeriod);

    error AlreadyDistributed();
    error OutsideWindow();
    error BadPotCap();
    error BadMinPot();
    error GenesisMismatch();
    error CadenceMismatch(); // registry WEEK()/weekAnchor differ from this engine's (mis-paired deploy)
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error ClaimOutOfGas(); // a gas-starved registerClaim reverts the payout rather than skip a member

    constructor(
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 minPot_,
        uint256 potCap_,
        address o
    ) Ownable(o) {
        // potCap and minPot are both REQUIRED (> 0) at construction, with minPot <= potCap, so a dust-sized
        // pot never consumes a week. Fail-closed on-chain like HolderDrawEngine.
        if (potCap_ == 0 || potCap_ > MAX_BANDABLE_CAP) revert BadPotCap(); // band must not overflow
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot();
        registry = LeaderboardRegistry(registry_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        // Cross-check the registry's genesis (as RaffleEngine does): a divergence would desync the
        // distribute() window from the registry's accrual-week numbering.
        if (LeaderboardRegistry(registry_).genesis() != genesis_) revert GenesisMismatch();
        // Cadence cross-check: genesis alone does not pin the week numbering, because WEEK() and the anchor
        // derivation are both `virtual`. Assert both halves against the registry, exactly as genesis is
        // asserted, so a mis-paired deploy (or a subclass that overrides only one half) reverts. WEEK()
        // dispatches to the most-derived override, so the testnet pair (10m/10m, genesis-anchored) passes
        // exactly like 7d/7d.
        if (LeaderboardRegistry(registry_).WEEK() != WEEK()) revert CadenceMismatch();
        genesis = genesis_;
        // Same Sunday derivation as the registry: identical genesis (checked above) => identical weekAnchor,
        // so currentWeek() here and in the registry stay in sync. Derivation is `virtual` so the TESTNET-ONLY
        // subclass can anchor to genesis with a short week; the registry subclass overrides it identically,
        // which the check below enforces.
        uint256 wa = _deriveWeekAnchor(genesis_);
        if (LeaderboardRegistry(registry_).weekAnchor() != wa) revert CadenceMismatch();
        weekAnchor = wa;
        minPot = minPot_;
        potCap = potCap_;
    }

    /// @notice The pot cap in force AS OF `week`. A write at week P lands at P+1, and distribute only
    ///         ever queries W = currentWeek()-1 = P-1 < P+1, so no write can alter a still-payable week.
    function potCapAt(uint256 week) public view returns (uint256) {
        uint64 e = potCapEffectiveWeek;
        return (e == 0 || week >= uint256(e)) ? potCap : prevPotCap;
    }

    /// @notice The minPot floor in force AS OF `week`. Same scheduling guarantee.
    function minPotAt(uint256 week) public view returns (uint256) {
        uint64 e = minPotEffectiveWeek;
        return (e == 0 || week >= uint256(e)) ? minPot : prevMinPot;
    }

    /// @notice Bound a single week's payout. Never below the minPot floor.
    /// @dev    Rate-limited to +/-25% per change and one change per week, and scheduled to the following
    ///         week, so a change never alters the payout of a week that is still distributable.
    function setPotCap(uint256 c) external onlyOwner {
        uint256 w = currentWeek();
        uint256 cur = potCapAt(w); // band off what is in force NOW (promotes an already-due pending value)
        // Cross-knob validation: bound against BOTH the minPot in force now and the scheduled (live) minPot,
        // so minPotAt(p) <= potCapAt(p) holds in every period, including the one where both scheduled
        // values take effect.
        if (c == 0 || c > MAX_BANDABLE_CAP) revert BadPotCap(); // keep the band computable
        uint256 floorNow = minPotAt(w);
        uint256 floorBound = floorNow > minPot ? floorNow : minPot; // strictest of {effective now, scheduled}
        if (c < floorBound) revert BadPotCap();
        if (block.timestamp < uint256(lastPotAdjust) + WEEK()) revert AdjustTooSoon();
        // PERIOD-based guard, in addition to the timestamp cooldown (which alone would allow writes in two
        // consecutive periods): a prior scheduled change must be in force AND aged past its effective period
        // before another may be scheduled, so `prev` is only ever overwritten once no drawable period still
        // needs it.
        if (potCapEffectiveWeek != 0 && currentWeek() <= uint256(potCapEffectiveWeek)) revert AdjustTooSoon();
        // Ceil `lo` so the band cannot widen past +/-25% at small values.
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS;
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1; // band never collapses to a point
        if (c < lo || c > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        prevPotCap = cur; // freeze what the still-payable week sees
        potCap = c; // LIVE value is what the owner set; potCapAt(week) resolves the value in force
        potCapEffectiveWeek = uint64(w + 1);
        emit PotCapSet(c, potCapEffectiveWeek);
    }

    /// @notice Set the minimum pot below which distribute voids without consuming the week.
    ///         Cross-checked against potCap, since minPot > potCap would void every week.
    function setMinPot(uint256 m) external onlyOwner {
        uint256 w = currentWeek();
        uint256 cur = minPotAt(w);
        // Cross-knob validation: bound against BOTH the potCap in force now and the scheduled (live) potCap,
        // so minPotAt(p) <= potCapAt(p) holds in every period, including the one where both scheduled
        // values take effect.
        uint256 capNow = potCapAt(w);
        uint256 capBound = capNow < potCap ? capNow : potCap; // tightest of {effective now, scheduled}
        if (m == 0 || m > capBound) revert BadMinPot(); // never 0, never above potCap
        // One change per week, within a +/-25% band (as setPotCap) that never collapses to a point. The band
        // and cooldown bound size and rate; scheduling to the following week keeps a change off the current
        // and earlier weeks.
        if (block.timestamp < uint256(lastMinPotAdjust) + WEEK()) revert AdjustTooSoon();
        // PERIOD-based guard, in addition to the timestamp cooldown (which alone would allow writes in two
        // consecutive periods): a prior scheduled change must be in force AND aged past its effective period
        // before another may be scheduled, so `prev` is only ever overwritten once no drawable period still
        // needs it.
        if (minPotEffectiveWeek != 0 && currentWeek() <= uint256(minPotEffectiveWeek)) revert AdjustTooSoon();
        uint256 lo = ((cur * (BPS - MAX_ADJ_BPS)) + BPS - 1) / BPS; // ceil, as in setPotCap
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        prevMinPot = cur;
        minPot = m;
        minPotEffectiveWeek = uint64(w + 1);
        emit MinPotSet(m, minPotEffectiveWeek);
    }

    /// @notice Most-recent Sunday 00:00 UTC at/before genesis (payouts land on Sundays). `virtual` so the
    ///         TESTNET-ONLY subclass can anchor to genesis with a short week; MUST mirror the registry's.
    function _deriveWeekAnchor(uint256 genesis_) internal view virtual returns (uint256) {
        return genesis_ >= 3 days ? genesis_ - ((genesis_ - 3 days) % 7 days) : 0;
    }

    function currentWeek() public view returns (uint256) {
        if (block.timestamp < weekAnchor) return 0;
        return (block.timestamp - weekAnchor) / WEEK(); // Sunday-aligned, matches registry._week()
    }

    function distribute(uint256 week) external nonReentrant {
        if (distributed[week]) revert AlreadyDistributed();
        if (currentWeek() != week + 1) revert OutsideWindow(); // the following week only, else void

        // Snapshot the pot and guards BEFORE marking distributed, so an empty/zero-weight week is NOT
        // consumed (matches RaffleEngine/HolderDrawEngine: a funded retry can still pay within the window).
        uint256 cnt = registry.boardCount(week);
        uint256 pot = vault.freeBalance();
        uint256 capForWeek = potCapAt(week); // scheduled, not live
        if (pot > capForWeek) pot = capForWeek; // bound the single-week payout; excess rolls forward
        // Divide by ALL buyers' points this week, NOT the 25-member board sum, so a member's share depends
        // only on its own points and splitting a stake across wallets gains nothing. Non-board buyers' weight
        // simply stays in the vault and rolls forward. So the top-25 collectively receive (their points / all
        // points) of the pot.
        uint256 totalW = registry.totalPoints(week);
        // `pot == 0` and `totalW == 0` are implied by their siblings and are kept as one-comparison
        // defences. pot == 0 implies pot < minPotAt(week), because every minPot this engine can hold is > 0
        // (constructor and setMinPot both reject 0). totalW == 0 implies cnt == 0, because the registry's
        // only board writer, _addPoints, returns on a zero amount and adds `amount` to totalPoints before
        // seating anyone. totalW is a cross-contract read, so its check also guards the division below.
        if (cnt == 0 || pot == 0 || pot < minPotAt(week) || totalW == 0) {
            emit Distributed(week, pot, 0);
            return; // do NOT mark distributed (a sub-minPot dust pot never consumes the week)
        }

        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        uint256 paid;
        for (uint256 i; i < cnt; ++i) {
            (address a, uint256 p) = registry.boardAt(week, i);
            uint256 share = (pot * p) / totalW;
            if (share == 0) continue;
            // Isolate each member, as RaffleEngine._payWinners does. No revert is expected (board
            // members are non-zero and the shares sum to at most the snapshotted pot <= freeBalance), but
            // one reverting registerClaim must not void the week for every other member. A skipped share
            // is never reserved, so it stays in freeBalance and rolls forward, and it does not count
            // toward `paid`, so a week where every registration failed is not consumed.
            uint256 g = gasleft();
            try claimManager.registerClaim(address(vault), a, share, deadline) {
                unchecked {
                    ++paid;
                }
            } catch {
                if (gasleft() < g / CLAIM_OOG_DIVISOR) revert ClaimOutOfGas();
                emit ShareSkipped(week, a, share);
            }
        }
        if (paid == 0) {
            emit Distributed(week, pot, 0);
            return; // do NOT consume the week if no share was registered
        }
        distributed[week] = true; // flag only AFTER >=1 nonzero claim is registered
        emit Distributed(week, pot, paid);
    }
}
