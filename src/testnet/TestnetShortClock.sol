// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
//  TESTNET-ONLY short-clock subclasses.  MAIN-ONLY: never pushed to the public
//  contracts repo, never deployed to mainnet.  They exist purely so the RH
//  testnet demo can run the holder-draw / weekly-leaderboard / daily-raffle games on
//  a minutes-long clock instead of the real daily / weekly cadence, WITHOUT touching
//  the base contracts or the mainnet-valued test suite's proofs (reveal-lag >
//  sequencer bound, Sunday-aligned payouts). Each subclass overrides the cadence
//  getter(s), plus any lag that is measured against a cadence it shortened. The
//  MockDrandOracle serves any round's beacon on demand (the keeper posts the
//  needed round early), so a shortened lag still resolves on testnet.
//
//  RULE: if a subclass shrinks a period, it MUST also shrink every lag the base
//  measures FROM that period's boundary. A lag left at its mainnet value points
//  past the far end of the shortened window, and the game becomes unplayable
//  rather than merely slow.
//
//  Mainnet deploy uses the plain base contracts (real 1d/7d periods). This file
//  is referenced ONLY by script/DeployTestnet.s.sol.
// ─────────────────────────────────────────────────────────────────────────────

import { HolderDrawEngine } from "../HolderDrawEngine.sol";
import { LeaderboardEngine } from "../LeaderboardEngine.sol";
import { LeaderboardRegistry } from "../LeaderboardRegistry.sol";
import { RaffleEngine } from "../RaffleEngine.sol";
import { PackRegistry } from "../PackRegistry.sol";
import { NFTCollection } from "../NFTCollection.sol";
import { QpullTaxHook } from "../hooks/QpullTaxHook.sol";

/// @dev Holder draw: 7-day week -> 10 minutes, AND reveal-lag 4.5 days -> 2 minutes.
///
///      REVEAL_LAG MUST SHRINK WITH WEEK(). drawRound(w) is drand.roundAt(snapDeadline(w) + REVEAL_LAG()),
///      and the draw window (currentPeriod() == w + 1) is only 10 minutes wide, so the mainnet 4.5-day lag
///      would put the settling round far past the window and no holder draw could execute on a real oracle.
///
///      2 minutes keeps the ordering the mainnet value exists to enforce (beacon reveals strictly AFTER the
///      freeze instant, so eligibility for week w has stopped moving before the seed exists) and leaves
///      roughly 8 of the 10 minutes for the keeper to call runDraw. It does NOT reproduce the mainnet
///      sequencer-clock bound (2 minutes is far under RH's 4-day maxTimeVariation.delaySeconds), so a testnet
///      run exercises cadence, gas and payout plumbing only.
contract HolderDrawEngineTestnet is HolderDrawEngine {
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
    ) HolderDrawEngine(drand_, nft_, vault_, claim_, genesis_, potCap_, potCapCeiling_, minPot_, initialOwner) {}

    function WEEK() public pure override returns (uint256) { return 10 minutes; }
    /// @dev MUST stay strictly below WEEK(), or drawRound(w) points past the end of week w+1 and the draw
    ///      window closes before the settling beacon exists.
    function REVEAL_LAG() internal pure override returns (uint256) { return 2 minutes; }
}

/// @dev Weekly leaderboard: 7-day week -> 10 minutes, anchored to genesis (clean week 0,1,2 on testnet).
///      MUST mirror LeaderboardRegistryTestnet so accrual-week and distribute-week numbering stay in sync.
contract LeaderboardEngineTestnet is LeaderboardEngine {
    constructor(
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 minPot_,
        uint256 potCap_,
        address o
    ) LeaderboardEngine(registry_, vault_, claim_, genesis_, minPot_, potCap_, o) {}

    function WEEK() public pure override returns (uint256) { return 10 minutes; }
    function _deriveWeekAnchor(uint256 genesis_) internal pure override returns (uint256) { return genesis_; }
}

/// @dev Leaderboard entries registry: mirrors LeaderboardEngineTestnet exactly (10-min week, genesis anchor).
contract LeaderboardRegistryTestnet is LeaderboardRegistry {
    constructor(uint256 genesis_, address initialOwner) LeaderboardRegistry(genesis_, initialOwner) {}

    function WEEK() public pure override returns (uint256) { return 10 minutes; }
    function _deriveWeekAnchor(uint256 genesis_) internal pure override returns (uint256) { return genesis_; }
}

/// @dev Daily raffle: 1-day cadence -> 5 minutes. MUST match PackRegistryTestnet.DAY().
contract RaffleEngineTestnet is RaffleEngine {
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
    ) RaffleEngine(drand_, packs_, vault_, claim_, genesis_, k_, minPot_, potCap_, capBps_, initialOwner) {}

    function DAY() internal pure override returns (uint256) { return 5 minutes; }
    /// @dev REVEAL_LAG MUST SHRINK WITH DAY() (same rule as HolderDrawEngineTestnet above).
    ///      drawRound(d) is drand.roundAt(genesis + (d+1)*DAY() + REVEAL_LAG()), while runDraw only accepts
    ///      currentDay() == d + 1, a window one DAY() wide. With DAY() at 5 minutes, the mainnet 1-hour lag
    ///      would put the settling round ~55 minutes PAST the end of the window that needs it. Must stay well
    ///      under DAY().
    function REVEAL_LAG() internal pure override returns (uint256) { return 1 minutes; }
}

/// @dev Raffle-ticket registry: 1-day cadence -> 5 minutes. MUST match RaffleEngineTestnet.DAY().
contract PackRegistryTestnet is PackRegistry {
    constructor(
        address drand_,
        uint256 ticketPrice_,
        uint256 genesis_,
        uint256 revealDelay_,
        address initialOwner
    ) PackRegistry(drand_, ticketPrice_, genesis_, revealDelay_, initialOwner) {}

    function DAY() internal pure override returns (uint256) { return 5 minutes; }

    /// @dev Same rule as the REVEAL_LAG overrides above, applied to the reveal-delay floor. 1 minute mirrors
    ///      RaffleEngineTestnet.REVEAL_LAG() exactly: the floor exists to hold revealDelay >= the engines' lag,
    ///      so these two MUST move together. The ceiling is DAY(), matching the mainnet rule that the tier
    ///      round reveals inside the cohort's own draw window.
    function MIN_REVEAL_DELAY() public pure override returns (uint256) { return 1 minutes; }
    // No MAX override: the base derives it from DAY(), which this subclass already compresses.
}


/// @dev Tiered mint on the short clock so the full GTD -> overflow -> public -> closed flow (and the 4-pass
///      holder-draw threshold, which needs the overflow window to clear) can be walked in minutes, not the
///      mainnet 48h. Caps are UNCHANGED (3/8/20): only the durations shrink. NEVER deployed to mainnet.
///      GTD 3m, overflow 8m, public 6m (closes at start+17m), backstop 1h; soft-close trigger 30s / step 15s / cap 1m.
///      REVEAL_FALLBACK_STEP is NOT overridden here (7 days, see MIN_REVEAL_DELAY below).
///      FAST TEST CLOCK: intentionally short so we reach GoLive quickly to exercise the launch gate +
///      transfer-lock. (For a relaxed mint run-through, widen these back to ~15/15/20.)
contract NFTCollectionTestnet is NFTCollection {
    constructor(
        uint256 mintPrice_,
        address drand_,
        uint256 revealDelay_,
        address renderer_,
        address initialOwner
    ) NFTCollection(mintPrice_, drand_, revealDelay_, renderer_, initialOwner) {}

    // Test clock for the holder-draw + rip run: roomy overflow so 8 passes (>= MIN_HOLD 4) mint in one tx. ~17m.
    function GTD_WINDOW() public pure override returns (uint256) { return 3 minutes; }
    function OVERFLOW_WINDOW() public pure override returns (uint256) { return 8 minutes; }
    function PUBLIC_MINT_WINDOW() public pure override returns (uint256) { return 6 minutes; }
    function LAUNCH_BACKSTOP() public pure override returns (uint256) { return 1 hours; }
    // soft-close kept tiny so it never interferes with the fast mint (you mint early, not in the overflow tail).
    function EXTENSION_TRIGGER() public pure override returns (uint256) { return 30 seconds; }
    function EXTENSION_STEP() public pure override returns (uint256) { return 15 seconds; }
    function MAX_EXTENSION() public pure override returns (uint256) { return 1 minutes; }
    /// @dev Lets the pass reveal be sealed inside a short-clock run. Still far under REVEAL_FALLBACK_STEP
    ///      (7 days, not overridden here), so fallback rung 1 can never be due before the round exists.
    function MIN_REVEAL_DELAY() public pure override returns (uint256) { return 1 minutes; }
}

/// @dev TESTNET-ONLY: compresses the launch buy-gate + anti-dump sell-tax windows so the demo can exercise
///      the gate expiry, the transfer-lock lift, and the 20%->4% sell-tax decay in minutes instead of
///      hours/days. Gate + transfer-lock 15m (real: 1h); buy cooldown 20s (real: 2m). Either way a wallet can
///      spend its whole capped budget inside the window: (EARLY_BUY_COUNT - 1) cooldowns is 3m of 15m here and
///      18m of 60m on mainnet (test/AdvHookThrottle.t.sol pins both); sell tax decays 20%->4% over 20m in 5m steps (real: 48h/12h).
///      The per-buy size cap (earlyBuyCapWei), the capped spend budget (EARLY_BUY_COUNT * earlyBuyCapWei), and
///      all flag/security logic are inherited unchanged from the base hook. Its address needs the base
///      REQUIRED_FLAGS (0x1ACC), so the subclass salt must be RE-MINED (DeployTestnet.s.sol
///      does this on every run).
contract QpullTaxHookTestnet is QpullTaxHook {
    constructor(QpullTaxHook.HookConfig memory c) QpullTaxHook(c) { }

    function GATE_DURATION() public pure override returns (uint256) { return 15 minutes; }
    function BUY_COOLDOWN() public pure override returns (uint256) { return 20 seconds; }
    function SELL_STEP() public pure override returns (uint256) { return 5 minutes; }
    function SELL_DECAY() public pure override returns (uint256) { return 20 minutes; }
}
