// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { V4LpBase } from "./utils/V4LpBase.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// Dedicated launch-window (1 hour on mainnet, chosen by the owner) anti-sniper THROTTLE probe (cap / spend budget /
/// cooldown) — the code path the shipped suite leaves untested (its fixture pins earlyBuyCapWei = type(uint256).max).
contract AdvHookThrottle is Test, V4LpBase {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220;
    int24 constant FULL_HI = 887_220;

    uint256 constant CAP = 0.15 ether;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    QpullTaxHook hook;
    QpullWethAdapter adapter;
    address hookAddr = address(uint160((0xBB << 16) | FLAGS));
    address feeSink = makeAddr("feeSink");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // second holder (sybil)
    bool qpullIs0;
    V4PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager))); // this contract IS the hook's initializer, so it is the LP
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        nft.set(1, alice, 0);
        nft.set(2, bob, 0);

        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(makeAddr("t"));

        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: feeSink,
                    packRegistry: address(new MockRecorder()),
                    leaderboardRegistry: address(new MockRecorder()),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });

        qpull.mint(address(this), 1e27);
        weth.mint(address(this), 1e27);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            qpull.mint(who, 1e24);
            weth.mint(who, 1e24);
            vm.startPrank(who);
            qpull.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        _initializePool(key, SQRT_1_1);
        _addLiquidity(key, FULL_LO, FULL_HI, 1e24);
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0;
    }

    function _swap(address who, bool zeroForOne, int256 amt) internal returns (V4BalanceDelta) {
        vm.prank(who, who);
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amt, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // small under-cap buy (exact input of WETH)
    function _smallBuy(address who) internal {
        _swap(who, _buyZeroForOne(), -int256(0.01 ether));
    }

    // ── CAP: an exact-INPUT buy over the WETH cap reverts ──
    function test_cap_exactInput_overCap_reverts() public {
        vm.expectRevert(); // wraps QpullTaxHook.EarlyBuyTooLarge via PoolManager custom-revert
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // 1 ETH WETH-in >> 0.15 cap
    }

    // ── CAP: an exact-OUTPUT buy that would spend > cap of WETH is ALSO blocked (no dodge) ──
    function test_cap_exactOutput_overCap_reverts() public {
        // request ~1e18 QPULL out (needs ~>=1e18 WETH in at 1:1) -> WETH-in+fee >> cap
        vm.expectRevert();
        _swap(alice, _buyZeroForOne(), int256(1 ether));
    }

    // ── CAP: a just-under-cap exact-input buy succeeds ──
    function test_cap_underCap_ok() public {
        _smallBuy(alice); // 0.01 ETH < 0.15 cap
        assertGt(qpull.balanceOf(alice), 1e24, "alice received QPULL");
    }

    // ── COOLDOWN: two gated buys in the same block by one wallet -> 2nd reverts ──
    function test_cooldown_sameBlock_reverts() public {
        _smallBuy(alice);
        vm.expectRevert();
        _smallBuy(alice); // < BUY_COOLDOWN (2 min) later
    }

    // ── CAP SCOPE: the size cap binds while a wallet's gated spend is below EARLY_BUY_COUNT * cap (the spend budget) ──
    /// An earlier version keyed the cap on a buy COUNT, and this test asserted the consequence: ten 0.01 ETH
    /// dust buys retired the count, and the eleventh buy was allowed over the cap. It is now inverted.
    /// By design the size cap lifts once a wallet has spent its gated budget, so an uncapped tail exists
    /// inside the window, but reaching it is meant to take real money. The cap now keys on CUMULATIVE SPEND,
    /// so dust buys no longer advance anyone toward it. Against the count-based cap this test fails at the
    /// first assertion below.
    function test_dustBuysCannotRetireTheSizeCap() public {
        uint256 n = hook.EARLY_BUY_COUNT();
        for (uint256 i; i < n; ++i) {
            _smallBuy(alice); // 0.01 ETH each: n * 0.01 = 0.1 ETH, far under the n * CAP budget
            vm.warp(block.timestamp + hook.BUY_COOLDOWN() + 1);
            require(block.timestamp < hook.launchTime() + hook.GATE_DURATION(), "fixture gate too short");
        }
        // THE DISCRIMINATING ASSERTION. Pre-fix this buy succeeded; now the budget is barely touched, so
        // the size cap still binds. Bare expectRevert per this file's convention — PoolManager wraps hook
        // custom errors, so the inner selector is not directly matchable.
        vm.expectRevert();
        _swap(alice, _buyZeroForOne(), -int256(0.2 ether)); // 0.2 ETH > 0.15 cap

        // POSITIVE CONTROL. A bare expectRevert passes on ANY revert, so prove the revert above was about
        // SIZE and not the cooldown or the gate: an at-cap buy at the same instant must still succeed.
        vm.warp(block.timestamp + hook.BUY_COOLDOWN() + 1);
        uint256 before = qpull.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -int256(CAP));
        assertGt(qpull.balanceOf(alice), before, "an AT-cap buy still works: the revert was about size");
    }

    /// The tail is still reachable, as designed, but only by spending the real budget
    /// (EARLY_BUY_COUNT * CAP), not by retiring a counter with dust.
    function test_tailStillReachableWithRealVolume() public {
        uint256 n = hook.EARLY_BUY_COUNT();
        for (uint256 i; i < n; ++i) {
            _swap(alice, _buyZeroForOne(), -int256(CAP)); // spend AT the cap, n times = the whole budget
            vm.warp(block.timestamp + hook.BUY_COOLDOWN() + 1);
            require(block.timestamp < hook.launchTime() + hook.GATE_DURATION(), "fixture gate too short");
        }
        // budget spent -> the size cap lifts, as designed
        uint256 before = qpull.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -int256(0.2 ether));
        assertGt(qpull.balanceOf(alice), before, "over-cap buy allowed once the real budget is spent");
    }

    // ── SYBIL is per-wallet by design: bob (a second NFT holder) is unthrottled by alice's buys ──
    function test_sybil_perWalletKeyed() public {
        _smallBuy(alice);
        _smallBuy(bob); // same block, different tx.origin: NOT subject to alice's cooldown
        assertGt(qpull.balanceOf(bob), 1e24, "bob's independent wallet buys freely (documented sybil cost)");
    }

    // ── the cap measures the WETH the buyer actually parts with, fee included, to the wei ──

    function _wrappedHook(bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hookAddr,
            IV4Hooks.afterSwap.selector,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// Exact-in: the buyer spends exactly G (the WETH fee rides inside it), so G == cap passes and cap + 1 reverts
    /// EarlyBuyTooLarge. The recorded spend is exactly the cap.
    function test_capBoundary_exactIn_atCapPasses_capPlusOneReverts() public {
        vm.expectRevert(_wrappedHook(QpullTaxHook.EarlyBuyTooLarge.selector));
        _swap(alice, _buyZeroForOne(), -int256(CAP + 1));

        uint256 w = weth.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -int256(CAP));
        assertEq(w - weth.balanceOf(alice), CAP, "spent exactly the cap");
        (,, uint128 spent) = hook.earlyBuyer(alice);
        assertEq(uint256(spent), CAP, "throttle recorded exactly the cap");
    }

    /// Exact-out: the buyer pays P + ceil(P/24). CAP = 25 * 6e15, and the only P with P + ceil(P/24) == CAP is
    /// P = 24 * 6e15. Find the QPULL output whose pool input is exactly that P (probed on a snapshot past the gate,
    /// where the pool math is identical and nothing is throttled), then inside the gate: that output passes and
    /// pays exactly CAP; one more QPULL wei raises P by at least 1, so the payment is at least CAP + 2 (CAP + 1 is
    /// not reachable: f(24k) = 25k, f(24k + 1) = 25k + 2) and it reverts EarlyBuyTooLarge.
    function test_capBoundary_exactOut_paidEqualsCapPasses_oneWeiMoreReverts() public {
        uint256 targetP = (CAP * 24) / 25;
        assertEq(targetP + (targetP + 23) / 24, CAP, "P + ceil(P/24) == CAP");
        uint256 q;
        for (uint256 attempt;; ++attempt) {
            q = _largestOutputWithInputAtMost(targetP);
            if (_poolInputForExactOut(q) == targetP) break;
            // this price skips targetP (P steps by more than 1 per QPULL wei ~0.3% of the time): nudge the price
            // with a small untaxed-by-the-throttle SELL from bob and search again
            require(attempt < 8, "no output with pool input exactly targetP");
            _swap(bob, !_buyZeroForOne(), -int256(1e15 + attempt));
        }

        vm.expectRevert(_wrappedHook(QpullTaxHook.EarlyBuyTooLarge.selector));
        _swap(alice, _buyZeroForOne(), int256(q + 1));

        uint256 w = weth.balanceOf(alice);
        uint256 sink = weth.balanceOf(feeSink);
        _swap(alice, _buyZeroForOne(), int256(q));
        uint256 paid = w - weth.balanceOf(alice);
        assertEq(paid, CAP, "paid P + ceil(P/24) == cap exactly");
        assertEq(weth.balanceOf(feeSink) - sink, (targetP + 23) / 24, "fee == ceil(P/24)");
        (,, uint128 spent) = hook.earlyBuyer(alice);
        assertEq(uint256(spent), CAP, "throttle recorded exactly the cap");
    }

    /// Largest QPULL output whose raw pool WETH input is <= p.
    function _largestOutputWithInputAtMost(uint256 p) internal returns (uint256 lo) {
        uint256 hi = p; // near 1:1 with a 0.3% LP fee, the output is below the input
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_poolInputForExactOut(mid) <= p) lo = mid;
            else hi = mid - 1;
        }
    }

    /// The pool's WETH input P for an exact-out buy of q, measured past the gate on a snapshot (paid - fee).
    function _poolInputForExactOut(uint256 q) internal returns (uint256 p) {
        uint256 snap = vm.snapshotState();
        vm.warp(hook.launchTime() + hook.GATE_DURATION());
        uint256 w = weth.balanceOf(bob);
        uint256 sink = weth.balanceOf(feeSink);
        _swap(bob, _buyZeroForOne(), int256(q));
        p = (w - weth.balanceOf(bob)) - (weth.balanceOf(feeSink) - sink);
        vm.revertToState(snap);
    }

    /// A non-holder's exact-in buy inside the gate reverts with the typed Gated error and the treasury is unchanged.
    function test_gate_nonHolderExactInBuyRevertsGated_treasuryUnchanged() public {
        address carol = makeAddr("carol");
        weth.mint(carol, 1e24);
        vm.prank(carol);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert(_wrappedHook(QpullTaxHook.Gated.selector));
        _swap(carol, _buyZeroForOne(), -int256(0.01 ether));
        assertEq(weth.balanceOf(feeSink), 0, "treasury WETH unchanged");
        assertEq(qpull.balanceOf(feeSink), 0, "treasury QPULL unchanged");
    }

    /// Both buy kinds write the gated-buy record that NFTCollection's launch transfer-lock reads
    /// (`earlyBuyer(from).buys`, NFTCollection.sol:871). The lock logic is covered against a mock hook in
    /// LaunchTransferLock.t.sol, and end to end (real NFTCollection + this real 0x1ACC hook, both buy kinds, both
    /// token orders) in LaunchTransferLockRealHook.t.sol.
    function test_bothBuyKindsArmTheLaunchTransferLockRecord() public {
        _swap(alice, _buyZeroForOne(), -int256(0.01 ether)); // exact-in
        (uint64 atA, uint32 buysA, uint128 spentA) = hook.earlyBuyer(alice);
        assertEq(buysA, 1, "exact-in buy counted");
        assertEq(uint256(atA), block.timestamp, "exact-in buy stamped");
        assertEq(uint256(spentA), 0.01 ether, "exact-in spend == G");

        _swap(bob, _buyZeroForOne(), int256(0.01 ether)); // exact-out
        (uint64 atB, uint32 buysB, uint128 spentB) = hook.earlyBuyer(bob);
        assertEq(buysB, 1, "exact-out buy counted");
        assertEq(uint256(atB), block.timestamp, "exact-out buy stamped");
        assertGt(uint256(spentB), 0.01 ether, "exact-out spend == P + fee");
    }

    // ── the owner's choice: the mainnet holder gate is ONE hour, and the whole capped budget still fits inside it ──

    /// The shipped constants, and the only ordering the throttle needs: EARLY_BUY_COUNT at-cap buys, spaced by exactly
    /// BUY_COOLDOWN (the cooldown boundary is inclusive), all land inside GATE_DURATION, and the uncapped tail is
    /// reachable in the same window. The 48h/12h sell-tax schedule is measured from launchTime separately and is
    /// unchanged. The window is exact to the second: a non-holder is still Gated at launchTime + 1h - 1 and buys at
    /// launchTime + 1h. Timestamps are explicit (never block.timestamp after vm.warp: via_ir may CSE TIMESTAMP).
    function test_oneHourGate_fullBudgetFitsAtMinimumSpacing() public {
        assertEq(hook.GATE_DURATION(), 1 hours, "mainnet holder gate is 1 hour");
        assertEq(hook.BUY_COOLDOWN(), 2 minutes, "mainnet buy cooldown unchanged");
        assertEq(hook.EARLY_BUY_COUNT(), 10, "budget multiplier unchanged");
        assertEq(hook.SELL_DECAY(), 48 hours, "sell-tax decay unchanged");
        assertEq(hook.SELL_STEP(), 12 hours, "sell-tax step unchanged");
        uint256 n = hook.EARLY_BUY_COUNT();
        uint256 cd = hook.BUY_COOLDOWN();
        uint256 t0 = hook.launchTime();
        assertLt((n - 1) * cd, hook.GATE_DURATION(), "n at-cap buys fit the window (18 of 60 minutes)");
        assertLt(n * cd, hook.GATE_DURATION(), "and so does the first uncapped buy after them");

        for (uint256 i; i < n; ++i) {
            vm.warp(t0 + i * cd); // exactly one cooldown apart
            _swap(alice, _buyZeroForOne(), -int256(CAP));
        }
        (, uint32 buys, uint128 spent) = hook.earlyBuyer(alice);
        assertEq(uint256(buys), n, "every at-cap buy landed");
        assertEq(uint256(spent), n * CAP, "the whole capped budget is spent inside the gate");

        vm.warp(t0 + n * cd); // still inside the 1-hour gate
        uint256 before = qpull.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -int256(4 * CAP));
        assertGt(qpull.balanceOf(alice), before, "the uncapped tail is reachable inside the 1-hour gate");

        address carol = makeAddr("carol");
        weth.mint(carol, 1e24);
        vm.prank(carol);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.warp(t0 + 1 hours - 1);
        vm.expectRevert(_wrappedHook(QpullTaxHook.Gated.selector));
        _swap(carol, _buyZeroForOne(), -int256(0.01 ether));
        vm.warp(t0 + 1 hours);
        _swap(carol, _buyZeroForOne(), -int256(1 ether)); // gate and throttle both closed at exactly +1h
        assertGt(qpull.balanceOf(carol), 0, "a non-holder buys, uncapped, from launchTime + 1 hour");
    }

    /// The testnet subclass keeps its compressed 15-minute gate (the 1-hour choice is mainnet only) and the same ordering holds:
    /// (EARLY_BUY_COUNT - 1) * 20s = 3 of 15 minutes.
    function test_testnetSubclassKeeps15mGate_budgetFits() public {
        address tAddr = address(uint160((0xBC << 16) | FLAGS));
        deployCodeTo(
            "src/testnet/TestnetShortClock.sol:QpullTaxHookTestnet",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: feeSink,
                    packRegistry: address(new MockRecorder()),
                    leaderboardRegistry: address(new MockRecorder()),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
            tAddr
        );
        QpullTaxHook t = QpullTaxHook(tAddr);
        assertEq(t.GATE_DURATION(), 15 minutes, "testnet gate stays 15 minutes");
        assertEq(t.BUY_COOLDOWN(), 20 seconds, "testnet cooldown");
        assertLt((t.EARLY_BUY_COUNT() - 1) * t.BUY_COOLDOWN(), t.GATE_DURATION(), "budget fits the testnet gate");
        assertLt(t.GATE_DURATION(), hook.GATE_DURATION(), "testnet window is shorter than mainnet's");
    }

    // ── after the gate closes, the throttle is inert (large buy, rapid repeats all OK) ──
    function test_postGate_throttleInert() public {
        vm.warp(hook.launchTime() + hook.GATE_DURATION() + 1);
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // over "cap" but gate closed
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // rapid repeat, no cooldown
        assertTrue(true);
    }
}
