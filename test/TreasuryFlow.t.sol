// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Treasury } from "../src/Treasury.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockRevertZeroERC20 } from "./mocks/MockRevertZeroERC20.sol";
import { MockBlacklistERC20 } from "./mocks/MockBlacklistERC20.sol";
import { MockLyingERC20 } from "./mocks/MockLyingERC20.sol";

contract TreasuryFlowTest is Test {
    Treasury treasury;
    MockERC20 qpull;
    MockERC20 weth;
    MockERC20 quotron;
    MockSwapAdapter qpullWeth;
    MockSwapAdapter wethQuotron;

    address prizeVault = makeAddr("prizeVault");
    address holderVault = makeAddr("holderVault");
    address leaderboardVault = makeAddr("leaderboardVault");
    address team = makeAddr("team");

    // The per-call caps ship FAIL-CLOSED (0 = NotConfigured). Tests that do not exercise the
    // caps arm them wide open so the rest of the convert() behaviour is unchanged; cap tests set their own.
    // setMax*PerCall rejects type(uint256).max onchain (the bound used to live
    // only in script/GoLiveMainnet.s.sol, which has already run by the time a compromised owner would
    // use it). These fixtures used max as shorthand for "uncapped for this test", not as an assertion
    // about max itself, so a large finite sentinel preserves the intent.
    uint256 constant UNCAPPED = type(uint256).max / 2;

    function setUp() public {
        qpull = new MockERC20();
        weth = new MockERC20();
        quotron = new MockERC20();
        qpullWeth = new MockSwapAdapter(1e18, 1e18);
        wethQuotron = new MockSwapAdapter(1e18, 1e18);

        treasury = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
        treasury.setRouting(prizeVault, holderVault, leaderboardVault, team);
        treasury.setConvertThreshold(0);
        treasury.setMaxConvertPerCall(UNCAPPED); // caps must be armed before convert() runs (fail-closed)
        treasury.setMaxWethConvertPerCall(UNCAPPED);
        treasury.setKeeper(address(this), true); // convert() is keeper-gated
    }

    // ─── treasury-convert: both per-call caps ship fail-CLOSED ────────────────

    /// Both caps default to 0 = "not configured". A fully wired Treasury (adapters + routing + keeper) must
    /// still refuse to convert until BOTH pool-sized ceilings are armed, so the donation-brick and
    /// keeper-MEV bounds can never be silently left off at launch (they used to default to type(uint256).max
    /// and no deploy/go-live script set them).
    function test_capsUnsetConvertRevertsNotConfigured() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setKeeper(address(this), true);
        assertEq(t.maxConvertPerCall(), 0, "QPULL cap defaults to 0 (not configured)");
        assertEq(t.maxWethConvertPerCall(), 0, "WETH cap defaults to 0 (not configured)");
        qpull.mint(address(t), 10_000e18);

        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);

        // arming only ONE cap is still not configured: both legs must be bounded
        t.setMaxConvertPerCall(1_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);
        t.setMaxConvertPerCall(UNCAPPED); // reset, then try the other one alone
        // (setter cannot return a cap to 0, so build a fresh Treasury for the WETH-only case)
        Treasury t2 = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t2.setAdapters(address(qpullWeth), address(wethQuotron));
        t2.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t2.setKeeper(address(this), true);
        t2.setMaxWethConvertPerCall(1_000e18);
        qpull.mint(address(t2), 10_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t2.convert(0, 0);

        // arming both opens the pipeline, and the first slice honours the QPULL cap
        t.setMaxConvertPerCall(1_000e18);
        t.setMaxWethConvertPerCall(1_000e18);
        t.convert(0, 0);
        assertEq(qpull.balanceOf(address(t)), 9_000e18, "one 1000-slice converted once both caps are armed");
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the capped slice");
    }

    /// The 0 sentinel is only meaningful because the setter refuses it (mirror of the WETH test below).
    /// The same fix as on BaseVault: both had an
    /// unconditional onERC721Received and neither has ANY ERC-721 egress, so a misdirected safeTransferFrom
    /// to a published deploy address destroyed the token instead of reverting.
    function test_treasuryRejectsNftFromAnyoneButQuotron() public {
        address stranger = makeAddr("nftStranger");
        vm.prank(stranger);
        vm.expectRevert(Treasury.UnexpectedNft.selector);
        treasury.onERC721Received(stranger, stranger, 1, "");
        // QUOTRON's own terminal mint is still accepted, which is the documented purpose
        vm.prank(address(quotron));
        bytes4 sel = treasury.onERC721Received(address(quotron), address(treasury), 7, "");
        assertEq(sel, Treasury.onERC721Received.selector, "QUOTRON auto-mint still accepted");
    }

    // ── Regression tests: each of these FAILS against the earlier code ──────────────────────

    /// The only bound on the convert caps used to live in script/GoLiveMainnet.s.sol, which has
    /// already run by the time a compromised owner would raise them. Post-lock: cap -> max, self-grant keeper,
    /// convert(0,0) sandwiches an uncapped slice through the shallow QUOTRON pool. Destinations hold; value
    /// leaves as slippage. The bound has to survive the script, so it lives in the setter now.
    function test_caps_rejectMaxUint() public {
        vm.expectRevert(Treasury.CapTooLarge.selector);
        treasury.setMaxConvertPerCall(type(uint256).max);
        vm.expectRevert(Treasury.CapTooLarge.selector);
        treasury.setMaxWethConvertPerCall(type(uint256).max);
        // one below max is still allowed: ordinary re-tuning must keep working, since the caps have to track
        // pool depth as the permanently-locked LP accrues fees.
        treasury.setMaxConvertPerCall(type(uint256).max - 1);
        assertEq(treasury.maxConvertPerCall(), type(uint256).max - 1, "finite caps still settable");
    }

    /// owedTotal sums quotronOwed at the three CURRENT role addresses, so two roles
    /// sharing an address double-counts it and permanently under-computes `splittable`.
    function test_setRouting_rejectsAliasedVaults() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, prizeVault, leaderboardVault, team);
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, holderVault, holderVault, team);
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, holderVault, prizeVault, team);
        // team may still equal a vault: it takes WETH, never QUOTRON, so it is not part of owedTotal.
        t.setRouting(prizeVault, holderVault, leaderboardVault, prizeVault);
        assertEq(t.team(), prizeVault, "team is not constrained by the distinctness rule");
    }

    /// The three token bindings are immutable with no re-deploy path, so a zero token is refused at construction.
    function test_constructor_rejectsZeroTokens() public {
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(0), address(weth), address(quotron), address(this));
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(qpull), address(0), address(quotron), address(this));
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(qpull), address(weth), address(0), address(this));
    }

    /// convert() requires both caps, so a lock that verified only the six addresses
    /// promised a completeness it did not check.
    function test_lockRouting_requiresCapsArmed() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team); // caps unarmed
        t.setMaxConvertPerCall(1_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team); // only one armed
        t.setMaxWethConvertPerCall(1_000e18);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        assertTrue(t.routingLocked(), "locks once both caps are armed");
    }

    function test_setMaxConvertPerCall_rejectsZero() public {
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.setMaxConvertPerCall(0);
    }

    /// lockRouting() originally did NOT require the caps (they are pool-sized, tuned at go-live, and stay
    /// owner-mutable after the lock), but a locked Treasury with unset caps still failed closed.
    /// SUPERSEDED IN PART: this used to lock routing with the caps UNSET
    /// and assert convert() then reverted NotConfigured. lockRouting() now refuses that state outright
    /// (see test_lockRouting_requiresCapsArmed), so that half of the old assertion is unreachable by
    /// construction, which is strictly stronger. The OTHER half is still load-bearing and is what this test
    /// now pins: the caps are deliberately NOT frozen by the routing lock. That matters because the caps
    /// must keep tracking pool depth as the permanently-locked LP accrues fees, and the max-uint guard
    /// (rejecting type(uint256).max) must NOT have turned ordinary post-lock re-tuning into a revert.
    /// SUPERSEDED IN PART again: the caps stay tunable after the lock, but no longer in
    /// EITHER direction without limit. The lock latches the caps it saw as permanent ceilings, because refusing
    /// only the literal max let max - 1 re-open an uncapped slice. Lowering, and raising back up to the ceiling,
    /// still work; a deeper pool needs more convert() calls, not a higher cap.
    function test_capsRemainMutableAfterLockRouting() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setKeeper(address(this), true);
        t.setMaxConvertPerCall(1_000e18); // both caps must be armed BEFORE the lock
        t.setMaxWethConvertPerCall(1_000e18);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        assertEq(t.lockedMaxConvertPerCall(), 1_000e18, "the lock latched the QPULL cap as its ceiling");
        assertEq(t.lockedMaxWethConvertPerCall(), 1_000e18, "the lock latched the WETH cap as its ceiling");

        // routing itself is frozen forever
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);

        // the caps can be lowered for a thinner pool, and raised back up to the ceiling
        t.setMaxConvertPerCall(500e18);
        assertEq(t.maxConvertPerCall(), 500e18, "cap lowered post-lock");
        t.setMaxConvertPerCall(1_000e18);
        t.setMaxWethConvertPerCall(400e18);
        t.setMaxWethConvertPerCall(1_000e18);
        assertEq(t.maxWethConvertPerCall(), 1_000e18, "cap raised back to the ceiling post-lock");

        // but never above it: not the max - 1 that slipped past the max-uint guard, not one wei over
        vm.expectRevert(Treasury.CapTooLarge.selector);
        t.setMaxWethConvertPerCall(type(uint256).max - 1);
        vm.expectRevert(Treasury.CapTooLarge.selector);
        t.setMaxWethConvertPerCall(1_000e18 + 1);
        vm.expectRevert(Treasury.CapTooLarge.selector);
        t.setMaxConvertPerCall(UNCAPPED);

        // and the pipeline works with the re-tuned caps
        t.setMaxConvertPerCall(500e18);
        qpull.mint(address(t), 1e18);
        t.convert(0, 0);
        assertEq(qpull.balanceOf(address(t)), 0, "converts with post-lock re-tuned caps");
    }

    /// The uncap attempt end to end. After the lock a compromised owner raises the
    /// WETH cap to max - 1 (refused), self-grants keeper (allowed: setKeeper is the incident lever and is never
    /// lock-gated) and calls convert(0, 0). The slice it gets is the go-live ceiling, not the whole balance.
    function test_compromisedOwnerCannotUncapAfterLock() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setMaxConvertPerCall(1_000e18);
        t.setMaxWethConvertPerCall(1_000e18);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        weth.mint(address(t), 5_000e18); // accumulated WETH tax

        vm.expectRevert(Treasury.CapTooLarge.selector);
        t.setMaxWethConvertPerCall(type(uint256).max - 1);
        address attacker = makeAddr("attacker");
        t.setKeeper(attacker, true);

        vm.prank(attacker);
        t.convert(0, 0);
        assertEq(weth.balanceOf(team), 200e18, "team took 20% of ONE capped slice");
        assertEq(weth.balanceOf(address(t)), 4_000e18, "everything above the go-live cap stayed in the Treasury");
    }

    function test_convertSplitsCorrectly() public {
        qpull.mint(address(treasury), 10_000e18);

        treasury.convert(0, 0);

        // team = 20% in WETH
        assertEq(weth.balanceOf(team), 2_000e18, "team 20% WETH");
        // prize = 8000 QUOTRON, split 6125/625/1250
        assertEq(quotron.balanceOf(prizeVault), 6_125e18, "raffle 61.25%");
        assertEq(quotron.balanceOf(holderVault), 625e18, "holder 6.25%");
        assertEq(quotron.balanceOf(leaderboardVault), 1_250e18, "leaderboard 12.5%");
        assertEq(qpull.balanceOf(address(treasury)), 0, "all QPULL consumed");
    }

    function test_onlyKeeperCanConvert() public {
        qpull.mint(address(treasury), 10_000e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Treasury.NotKeeper.selector);
        treasury.convert(0, 0);
    }

    // ─── lockRouting() freezes convert()'s destinations; keeper stays rotatable ──

    function test_lockRoutingFreezesSetRouting() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        assertTrue(treasury.routingLocked(), "locked");
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        treasury.setRouting(makeAddr("a"), makeAddr("b"), makeAddr("c"), makeAddr("attackerTeam"));
    }

    function test_keeperStillRotatableAfterRoutingLock() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        // the keeper (a hot key) is deliberately NOT locked — it can still be rotated
        address newKeeper = makeAddr("newKeeper");
        treasury.setKeeper(newKeeper, true);
        assertTrue(treasury.isKeeper(newKeeper), "keeper still settable after routing lock");
        // and convert still routes to the frozen destinations
        qpull.mint(address(treasury), 10_000e18);
        treasury.convert(0, 0);
        assertEq(quotron.balanceOf(prizeVault), 6_125e18, "still routes to the locked prizeVault");
    }

    function test_lockRoutingOnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
    }

    function test_belowThresholdReverts() public {
        treasury.setConvertThreshold(1_000e18);
        qpull.mint(address(treasury), 500e18);
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.convert(0, 0);
    }

    function test_notConfiguredReverts() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setKeeper(address(this), true); // pass the keeper gate so we reach the NotConfigured check
        qpull.mint(address(t), 1e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);
    }

    function test_offChainSlippageFloorEnforced() public {
        // WETH→QUOTRON adapter fills only 0.9:1 → demanding the full amount trips the floor
        MockSwapAdapter shortFill = new MockSwapAdapter(1e18, 0.9e18);
        treasury.setAdapters(address(qpullWeth), address(shortFill));
        qpull.mint(address(treasury), 1_000e18);
        // 1000 QPULL → 1000 WETH; team 250; prize 750 WETH; shortFill delivers 675 < demanded 750
        vm.expectRevert("slippage");
        treasury.convert(0, 750e18);
    }

    // ─── the hook delivers sell-tax as WETH directly to the Treasury ─────────────────

    function test_wethOnlyTaxIsSweptWithNoQpull() public {
        // A batch of pure sell-tax: WETH sits in the Treasury, zero QPULL. convert() must still run
        // (team 20% + prize 80% -> QUOTRON), not revert.
        weth.mint(address(treasury), 1_000e18);
        treasury.convert(0, 0);
        // team 20% -> 200 WETH; prize 800 WETH -> 800 QUOTRON split over PRIZE_BPS(8000):
        // holder 800*625/8000=62.5, leaderboard 800*1250/8000=125, raffle = remainder 612.5
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the WETH-only batch");
        assertEq(quotron.balanceOf(prizeVault), 612.5e18, "raffle 76.5625% of the 800 prize");
        assertEq(quotron.balanceOf(holderVault), 62.5e18, "holder 7.8125% of the prize");
        assertEq(quotron.balanceOf(leaderboardVault), 125e18, "leaderboard 15.625% of the prize");
    }

    function test_bothCurrencySweep_teamTakes20pctOfAll() public {
        // buys paid 400 QPULL, sells paid 600 WETH: after leg 1 (400 QPULL -> 400 WETH) the Treasury
        // holds 1000 WETH; team gets 20% of the whole 1000, not just the swapped 400.
        qpull.mint(address(treasury), 400e18);
        weth.mint(address(treasury), 600e18);
        treasury.convert(0, 0);
        assertEq(weth.balanceOf(team), 200e18, "team 20% of BOTH tax currencies combined");
        assertEq(qpull.balanceOf(address(treasury)), 0, "QPULL leg ran");
    }

    /// A min-batch threshold ABOVE the per-call slice cap must NOT strand
    /// the QPULL leg. Gate is on the raw balance; the cap only sizes the slice.
    function test_thresholdAboveSliceCapStillConverts() public {
        treasury.setConvertThreshold(1_000e18); // min batch
        treasury.setMaxConvertPerCall(500e18); // smaller per-call slice (pool-sized)
        qpull.mint(address(treasury), 5_000e18); // well above threshold

        treasury.convert(0, 0); // must NOT revert BelowThreshold, must swap a 500 slice
        assertEq(qpull.balanceOf(address(treasury)), 4_500e18, "one 500 slice converted, remainder waits");
        assertEq(weth.balanceOf(team), 100e18, "team 20% of the 500 slice");
    }

    function test_belowRawThresholdStillWaits() public {
        // guard the other direction: a raw balance under the threshold still waits (no WETH held)
        treasury.setConvertThreshold(1_000e18);
        treasury.setMaxConvertPerCall(500e18);
        qpull.mint(address(treasury), 800e18); // under the 1000 threshold
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.convert(0, 0);
    }

    // ─── the WETH leg is capped per call, symmetric to maxConvertPerCall ─────────────

    function test_wethDonationDrainsInSlicesNotBrick() public {
        // A large WETH donation (as a sell-tax batch, or an outright donation) must not force the whole
        // balance through the shallow QUOTRON pool in one swap. With a per-call cap, only a slice is
        // processed and the remainder waits for the next convert().
        treasury.setMaxWethConvertPerCall(1_000e18);
        weth.mint(address(treasury), 5_000e18);

        treasury.convert(0, 0);

        // one 1000-WETH slice processed: team 200, prize 800 -> QUOTRON; remaining 4000 WETH stays.
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the CAPPED slice only");
        assertEq(weth.balanceOf(address(treasury)), 4_000e18, "excess WETH waits for the next slice");
        assertEq(
            quotron.balanceOf(prizeVault) + quotron.balanceOf(holderVault)
                + quotron.balanceOf(leaderboardVault),
            800e18,
            "prize QUOTRON = the 800 from this slice"
        );
    }

    function test_setMaxWethConvertPerCall_rejectsZero() public {
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.setMaxWethConvertPerCall(0);
    }

    // ─── zero-value split-transfer legs are skipped (adversarial 0-revert QUOTRON) ────

    function test_thinBatchDoesNotBrickOnZeroTransferQuotron() public {
        // QUOTRON reverts on any zero-value transfer. A thin batch floors toHolder/toLeaderboard to 0;
        // convert() must SKIP those legs (their value rides in toRaffle) instead of reverting.
        MockRevertZeroERC20 rz = new MockRevertZeroERC20();
        Treasury t = new Treasury(address(qpull), address(weth), address(rz), address(this));
        MockSwapAdapter qw = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter wq = new MockSwapAdapter(1e18, 1e18);
        t.setAdapters(address(qw), address(wq));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setMaxConvertPerCall(UNCAPPED); // caps are fail-closed; arm them
        t.setMaxWethConvertPerCall(UNCAPPED);
        t.setKeeper(address(this), true);

        qpull.mint(address(t), 7); // qOut ends at 6: both holder (6*625/8000=0) and leaderboard (=0) floor to 0
        t.convert(0, 0); // must NOT revert on the two zero-value QUOTRON transfers
        assertEq(rz.balanceOf(prizeVault), 6, "all prize QUOTRON rode into the hourly leg");
        assertEq(rz.balanceOf(holderVault), 0, "zero holder leg skipped, not reverted");
        assertEq(rz.balanceOf(leaderboardVault), 0, "zero leaderboard leg skipped, not reverted");
    }

    // ─── setAdapters rejects zero addresses (matching setRouting) ─────────────────────

    function test_setAdaptersRejectsZero() public {
        vm.expectRevert(Treasury.NotConfigured.selector);
        treasury.setAdapters(address(0), address(wethQuotron));
        vm.expectRevert(Treasury.NotConfigured.selector);
        treasury.setAdapters(address(qpullWeth), address(0));
    }

    // ─── one blacklisted prize vault must NOT brick the whole convert() ──────

    /// QUOTRON can blacklist an address. If the holder vault were blacklisted, a naive `safeTransfer`
    /// split would revert and strand ALL prize routing. The fix routes each leg through `_trySendQuotron`
    /// (a low-level call that swallows a failed transfer) and splits the FULL balance, so a stuck slice
    /// stays in the Treasury and is retried on the next convert() rather than being lost.
    function test_blacklistedVaultDoesNotBrickConvert() public {
        MockBlacklistERC20 q = new MockBlacklistERC20();
        MockSwapAdapter qw = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter wq = new MockSwapAdapter(1e18, 1e18);
        Treasury t = new Treasury(address(qpull), address(weth), address(q), address(this));
        t.setAdapters(address(qw), address(wq));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setConvertThreshold(0);
        t.setMaxConvertPerCall(UNCAPPED); // caps are fail-closed; arm them
        t.setMaxWethConvertPerCall(UNCAPPED);
        t.setKeeper(address(this), true);

        q.setBlacklisted(holderVault, true); // QUOTRON refuses any transfer to this vault

        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0); // (a) must NOT revert despite the blacklisted destination

        // (b) every OTHER destination is funded correctly...
        assertEq(weth.balanceOf(team), 2_000e18, "team WETH still paid");
        assertEq(q.balanceOf(prizeVault), 6_125e18, "raffle slice paid");
        assertEq(q.balanceOf(leaderboardVault), 1_250e18, "leaderboard slice paid");
        // (c) ...the blacklisted vault got nothing, and its slice is retained (not lost)
        assertEq(q.balanceOf(holderVault), 0, "blacklisted holder vault received nothing");
        assertEq(q.balanceOf(address(t)), 625e18, "stuck holder slice stays in the Treasury");

        // (d) the stuck slice is credited to quotronOwed[holder] and retried to holder ITSELF,
        //     never redistributed to its sibling games.
        assertEq(t.quotronOwed(holderVault), 625e18, "stuck slice owed to the holder vault");
        q.setBlacklisted(holderVault, false);
        qpull.mint(address(t), 10_000e18);
        vm.roll(block.number + 1); // one convert per block
        t.convert(0, 0);
        assertEq(q.balanceOf(holderVault), 1_250e18, "holder recovers its FULL owed 625 + the new 625");
        assertEq(t.quotronOwed(holderVault), 0, "owed cleared");
        // siblings got ONLY their two normal shares: the stuck 625 did NOT leak to them (an earlier bug)
        assertEq(q.balanceOf(prizeVault), 12_250e18, "raffle: exactly 2x its normal share, no leaked slice");
        assertEq(q.balanceOf(leaderboardVault), 2_500e18, "leaderboard: exactly 2x its normal share");
        assertEq(q.balanceOf(address(t)), 0, "no QUOTRON left stranded in the Treasury");
    }

    // ─── the per-call caps bound ONE call; the aggregate needs its own limit ──────

    /// @dev Builds a Treasury whose adapters and caps are armed, keeper = this test, threshold 0.
    function _armedTreasury(address quotron_) internal returns (Treasury t) {
        MockSwapAdapter qw = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter wq = new MockSwapAdapter(1e18, 1e18);
        t = new Treasury(address(qpull), address(weth), quotron_, address(this));
        t.setAdapters(address(qw), address(wq));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setConvertThreshold(0);
        t.setMaxConvertPerCall(UNCAPPED);
        t.setMaxWethConvertPerCall(UNCAPPED);
        t.setKeeper(address(this), true);
    }

    /// The scenario: a compromised keeper loops convert() inside ONE transaction, each call
    /// slicing at the latched per-call cap against a self-manipulated shallow pool. The cap is per CALL, so
    /// before this fix N calls drained N slices with no price recovery between them. One per block ends it.
    function test_convertIsOncePerBlock() public {
        MockERC20 q = new MockERC20();
        Treasury t = _armedTreasury(address(q));
        q.mint(address(t), 100_000e18); // inventory for the mock adapters to hand back

        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0); // first slice of the block: fine

        qpull.mint(address(t), 10_000e18);
        vm.expectRevert(Treasury.ConvertRateLimited.selector);
        t.convert(0, 0); // the loop described above, in the same transaction

        vm.roll(block.number + 1);
        t.convert(0, 0); // a new block: allowed again, so the honest keeper is never blocked
    }

    /// The optional second limit: a bleed-rate bound ACROSS blocks, for the window in which the owner is
    /// still rotating a compromised keeper. 0 (the deploy default) leaves only the block rule.
    function test_cooldownHoldsAcrossBlocks() public {
        MockERC20 q = new MockERC20();
        Treasury t = _armedTreasury(address(q));
        q.mint(address(t), 100_000e18);
        t.setConvertCooldown(10 minutes);

        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 9 minutes); // a new block, but inside the cooldown
        qpull.mint(address(t), 10_000e18);
        vm.expectRevert(Treasury.ConvertRateLimited.selector);
        t.convert(0, 0);

        vm.warp(block.timestamp + 61); // cooldown elapsed
        t.convert(0, 0);
    }

    /// The cooldown must never become a shutdown switch: an owner can slow conversion, never stop it.
    function test_cooldownIsBounded() public {
        MockERC20 q = new MockERC20();
        Treasury t = _armedTreasury(address(q));
        uint256 maxCooldown = t.MAX_CONVERT_COOLDOWN(); // read it BEFORE arming expectRevert: it is a CALL,
        t.setConvertCooldown(maxCooldown); // and expectRevert would otherwise bind to the getter, not the setter
        vm.expectRevert(Treasury.CooldownTooLong.selector);
        t.setConvertCooldown(maxCooldown + 1);
    }

    // ─── judge a QUOTRON send by the measured balance delta, not by what it says ──

    /// A token that returns a clean `true` while moving nothing used to clear the owed slice: the vault was
    /// never funded and the accounting said it was. Now the slice survives and the next convert retries it.
    function test_aLyingTransferIsNotTreatedAsPaid() public {
        MockLyingERC20 q = new MockLyingERC20();
        Treasury t = _armedTreasury(address(q));
        q.mint(address(t), 100_000e18);

        q.setLie(true);
        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0);

        assertEq(q.balanceOf(prizeVault), 0, "the token moved nothing, whatever it returned");
        assertGt(t.quotronOwed(prizeVault), 0, "so the slice is still OWED, not silently written off");
        assertGt(t.quotronOwed(holderVault), 0, "every vault, not just one");
        assertGt(t.quotronOwed(leaderboardVault), 0, "every vault, not just one");

        // and once the token behaves, the retained slices are paid out in full
        uint256 owedPrize = t.quotronOwed(prizeVault);
        q.setLie(false);
        vm.roll(block.number + 1); // one convert per block
        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0);
        assertEq(t.quotronOwed(prizeVault), 0, "owed cleared once the transfer really happened");
        assertGt(q.balanceOf(prizeVault), owedPrize, "the retained slice plus the new one, both delivered");
    }

    /// The codeless-address shape: `call` into an address with no code returns ok == true and NO data, which
    /// the old returndata rule read as "a non-standard token that returns nothing on success".
    function test_silentSuccessShapeIsNotTreatedAsPaid() public {
        MockLyingERC20 q = new MockLyingERC20();
        Treasury t = _armedTreasury(address(q));
        q.mint(address(t), 100_000e18);

        q.setLie(true);
        q.setSilent(true); // returns no data at all
        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0);

        assertEq(q.balanceOf(prizeVault), 0, "nothing moved");
        assertGt(t.quotronOwed(prizeVault), 0, "empty returndata is not evidence of a transfer");
    }

    // ─── a dead QUOTRON router must not trap all revenue forever ──────────────────

    function test_adapterSwapNeedsAProposalAndTheFullTimelock() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        MockSwapAdapter fresh = new MockSwapAdapter(1e18, 1e18);

        // the frozen path is still frozen: no instant swap, before or after the lock
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        treasury.setAdapters(address(qpullWeth), address(fresh));

        // committing with nothing proposed does nothing
        vm.expectRevert(Treasury.NoAdapterProposal.selector);
        treasury.commitAdapterSwap();

        treasury.proposeAdapterSwap(address(fresh));
        assertEq(treasury.pendingWethQuotron(), address(fresh));
        assertEq(address(treasury.wethQuotron()), address(wethQuotron), "the live adapter has NOT changed yet");

        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() - 1);
        vm.expectRevert(Treasury.TimelockNotElapsed.selector);
        treasury.commitAdapterSwap(); // one second early is still early

        vm.warp(block.timestamp + 1);
        treasury.commitAdapterSwap();
        assertEq(address(treasury.wethQuotron()), address(fresh), "swapped only after the full public delay");
        assertEq(treasury.pendingWethQuotron(), address(0), "proposal cleared");
        assertEq(treasury.adapterProposedAt(), 0, "and its clock with it");
    }

    /// Re-proposing restarts the clock, so an owner cannot pre-arm a harmless proposal and substitute the
    /// real target at the last moment.
    function test_reproposingRestartsTheClock() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        MockSwapAdapter decoy = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter real = new MockSwapAdapter(1e18, 1e18);

        treasury.proposeAdapterSwap(address(decoy));
        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() - 10);
        treasury.proposeAdapterSwap(address(real)); // the substitution

        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() - 1);
        vm.expectRevert(Treasury.TimelockNotElapsed.selector);
        treasury.commitAdapterSwap(); // the decoy's elapsed time bought nothing
    }

    /// Cancelling is the point of a timelock: a proposal nobody wants can be withdrawn, and cancelling
    /// leaves nothing armed.
    function test_proposalCanBeCancelled() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        MockSwapAdapter fresh = new MockSwapAdapter(1e18, 1e18);
        treasury.proposeAdapterSwap(address(fresh));
        treasury.cancelAdapterSwap();
        assertEq(treasury.adapterProposedAt(), 0);

        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() + 1);
        vm.expectRevert(Treasury.NoAdapterProposal.selector);
        treasury.commitAdapterSwap(); // a cancelled proposal never becomes executable by waiting
        assertEq(address(treasury.wethQuotron()), address(wethQuotron), "adapter untouched");
    }

    /// The escape is for the QUOTRON leg only. The QPULL->WETH adapter is named by the tax hook's IMMUTABLE
    /// exemptSender, so replacing it would silently pay the sell tax on every conversion forever.
    function test_theQpullWethAdapterHasNoEscape() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        MockSwapAdapter fresh = new MockSwapAdapter(1e18, 1e18);
        treasury.proposeAdapterSwap(address(fresh));
        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() + 1);
        treasury.commitAdapterSwap();
        assertEq(address(treasury.qpullWeth()), address(qpullWeth), "the QPULL->WETH adapter is never swapped");
    }

    function test_onlyTheOwnerCanProposeOrCommit() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        MockSwapAdapter fresh = new MockSwapAdapter(1e18, 1e18);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert();
        treasury.proposeAdapterSwap(address(fresh));

        treasury.proposeAdapterSwap(address(fresh));
        vm.warp(block.timestamp + treasury.ADAPTER_TIMELOCK() + 1);
        vm.prank(stranger);
        vm.expectRevert();
        treasury.commitAdapterSwap();
    }

    /// A codeless address is refused at proposal time, not discovered at commit time.
    function test_codelessAdapterIsRefusedUpFront() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        vm.expectRevert(Treasury.AdapterNotContract.selector);
        treasury.proposeAdapterSwap(makeAddr("no code here"));
        vm.expectRevert(Treasury.NotConfigured.selector);
        treasury.proposeAdapterSwap(address(0));
    }

    // ─── setAdapters is frozen by lockRouting, same as setRouting ────────────

    function test_setAdaptersFrozenByLockRouting() public {
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
    }

    // ─── the freeze must state its subject (RoutingMismatch) ────────────────────

    /// @dev A helper Treasury wired exactly as launch wires one, with the caps armed so lockRouting's own
    ///      completeness checks pass and only the declaration is under test.
    function _armed() internal returns (Treasury t) {
        t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setMaxConvertPerCall(UNCAPPED);
        t.setMaxWethConvertPerCall(UNCAPPED);
    }

    /// THE ATTACK THIS EXISTS FOR, end to end.
    ///
    /// `setRouting` stays open for the whole gap between Deploy.s.sol and go-live, and GoLiveMainnet never
    /// read the four destinations at all -- not once, in the entire script. So a deployer key compromised
    /// inside that gap reroutes every future QUOTRON payout and the whole team cut to itself, passing every
    /// guard in setRouting (non-zero, distinct, no owed slices), and then the OPERATOR'S OWN go-live run
    /// freezes it -- permanently, on the attacker's behalf, with no owner able to undo it, that being the
    /// entire point of the lock.
    ///
    /// The freeze now names its subject, so the operator's declaration (derived from the Deploy output) and
    /// the rerouted state disagree, and the launch aborts loudly instead of committing.
    function test_lockRouting_refusesToFreezeAnAttackersReroute() public {
        Treasury t = _armed();
        address evil1 = makeAddr("evilPrize");
        address evil2 = makeAddr("evilHolder");
        address evil3 = makeAddr("evilLeaderboard");
        address evilTeam = makeAddr("evilTeam");

        t.setRouting(evil1, evil2, evil3, evilTeam); // the compromised key, inside the launch gap

        // the operator locks what it BELIEVES it verified: the real destinations from the Deploy output
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.RoutingMismatch.selector, evil1, evil2, evil3, evilTeam)
        );
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);

        assertFalse(t.routingLocked(), "an aborted launch must NOT leave the attacker's routing frozen");
        // and the damage is still reversible, which is the whole difference
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        assertTrue(t.routingLocked(), "the correct routing still locks");
    }

    /// One wrong leg is enough; the revert names what is actually stored, so the operator sees the diff.
    function test_lockRouting_refusesOnAnySingleMismatchedLeg() public {
        address other = makeAddr("other");
        Treasury t = _armed();
        vm.expectRevert(); // prize leg
        t.lockRouting(address(qpullWeth), address(wethQuotron), other, holderVault, leaderboardVault, team);
        vm.expectRevert(); // holder leg
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, other, leaderboardVault, team);
        vm.expectRevert(); // leaderboard leg
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, other, team);
        vm.expectRevert(); // team leg -- the 20% cut, and the one nobody thinks of
        t.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, other);
        assertFalse(t.routingLocked(), "none of those may latch");
    }

    /// An entirely unconfigured Treasury "matches" four zeros. NotConfigured must still win, or the
    /// declaration check would hand back the very brick the completeness check exists to prevent.
    function test_lockRouting_zeroDeclarationCannotFreezeAnUnconfiguredTreasury() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.lockRouting(address(qpullWeth), address(wethQuotron), address(0), address(0), address(0), address(0));
        assertFalse(t.routingLocked());
    }

    // ─── setKeeper: the role that survives the lock ─────────────────────────────

    /// The role is keyed by raw address, and a truncated or unset env var produces address(0). Granting it
    /// authorises nothing while looking done: convert() would then revert NotKeeper on every keeper tick,
    /// the prize vault would never fund, and every draw would void under minPot with healthy-looking logs.
    function test_setKeeper_rejectsTheZeroAddressInBothDirections() public {
        vm.expectRevert(Treasury.ZeroKeeper.selector);
        treasury.setKeeper(address(0), true);
        vm.expectRevert(Treasury.ZeroKeeper.selector);
        treasury.setKeeper(address(0), false);
    }

    /// `isKeeper` is a bare mapping with no enumeration, so before `keeperCount` there was no way to ask how
    /// many keepers exist -- and a keeper granted at any point in the deployer-key window was invisible to
    /// every check that only asked about addresses it already suspected. The go-live preflight now requires
    /// EXACTLY ONE, which is what makes a planted second keeper detectable at all.
    function test_keeperCount_makesAPlantedKeeperVisible() public {
        assertEq(treasury.keeperCount(), 1, "setUp granted exactly one");

        address planted = makeAddr("plantedByACompromisedKey");
        treasury.setKeeper(planted, true);
        assertEq(treasury.keeperCount(), 2, "the go-live gate's == 1 now fails, which is the point");
        assertTrue(treasury.isKeeper(planted));

        treasury.setKeeper(planted, false);
        assertEq(treasury.keeperCount(), 1, "revoked");
    }

    /// Redundant writes must not drift the count, or the gate above becomes noise.
    function test_setKeeper_redundantWritesDoNotDriftTheCount() public {
        address k = makeAddr("keeper2");
        treasury.setKeeper(k, true);
        treasury.setKeeper(k, true); // no-op
        treasury.setKeeper(k, true); // no-op
        assertEq(treasury.keeperCount(), 2, "granting twice grants once");
        treasury.setKeeper(k, false);
        treasury.setKeeper(k, false); // no-op
        assertEq(treasury.keeperCount(), 1, "revoking twice revokes once");
        address never = makeAddr("neverAKeeper");
        treasury.setKeeper(never, false); // revoking a non-keeper
        assertEq(treasury.keeperCount(), 1, "and cannot underflow");
    }

    /// THE DELIBERATE NON-GUARD. It is tempting to require that at least one keeper always survives, and it
    /// would be wrong: this setter is the protocol's only same-block incident lever, and the first thing to
    /// do about a compromised keeper key is revoke it -- possibly before a replacement is ready. A floor
    /// here would block exactly the emergency it appears to protect. Zero keepers pauses convert(); it
    /// breaks nothing permanently.
    function test_setKeeper_revokingTheLastKeeperIsAllowed() public {
        treasury.setKeeper(address(this), false);
        assertEq(treasury.keeperCount(), 0, "the incident lever must never be blocked");
        treasury.setKeeper(makeAddr("freshKeeper"), true);
        assertEq(treasury.keeperCount(), 1, "and a replacement can always be granted");
    }

    // ─── the freeze covers SIX bindings, not four ───────────────────────────────

    /// THE OTHER HALF. `lockRouting` also latches `setAdapters` (Treasury.setAdapters reverts
    /// RoutingAlreadyLocked forever after), so it freezes SIX bindings. The first version of this fix
    /// declared only the four payout destinations.
    ///
    /// The adapters are the more dangerous half. The destinations merely RECEIVE; the adapters are
    /// arbitrary-code contracts that convert() approves QPULL and WETH to and then calls. And freezing a
    /// wrong one is unrecoverable in a way the destinations are not: QpullTaxHook.exemptSender is IMMUTABLE
    /// and names this exact QpullWethAdapter, so a replacement adapter would pay the 4% tax on every
    /// conversion forever.
    function test_lockRouting_refusesToFreezeAdaptersTheCallerDidNotDeclare() public {
        Treasury t = _armed();
        MockSwapAdapter evil = new MockSwapAdapter(1e18, 1e18);
        t.setAdapters(address(evil), address(wethQuotron)); // a compromised key, or a mis-pasted address

        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.AdapterMismatch.selector, address(evil), address(wethQuotron)
            )
        );
        t.lockRouting(
            address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team
        );
        assertFalse(t.routingLocked(), "an aborted launch must not freeze the wrong adapter");

        t.setAdapters(address(qpullWeth), address(wethQuotron)); // still fixable, which is the whole point
        t.lockRouting(
            address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team
        );
        assertTrue(t.routingLocked());
    }

    /// Either leg alone is enough.
    function test_lockRouting_refusesOnEitherAdapterLeg() public {
        Treasury t = _armed();
        MockSwapAdapter other = new MockSwapAdapter(1e18, 1e18);
        vm.expectRevert();
        t.lockRouting(address(other), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team);
        vm.expectRevert();
        t.lockRouting(address(qpullWeth), address(other), prizeVault, holderVault, leaderboardVault, team);
        assertFalse(t.routingLocked());
    }

    /// A codeless adapter is not a correctable mistake, it is a permanent brick: convert() CALLS these, and
    /// a plain call to an address with no code returns success with empty returndata, which then fails to
    /// decode. Refuse it where it is set, not where it is frozen.
    function test_setAdapters_rejectsACodelessAddress() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        address eoa = makeAddr("mispastedAddress");
        vm.expectRevert(Treasury.AdapterNotContract.selector);
        t.setAdapters(eoa, address(wethQuotron));
        vm.expectRevert(Treasury.AdapterNotContract.selector);
        t.setAdapters(address(qpullWeth), eoa);
    }
}
