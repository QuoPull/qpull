// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { QpullTaxHookFixture } from "./QpullTaxHook.t.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import {
    IPoolManager as OurIPM,
    PoolKey,
    Currency,
    BalanceDelta as OurBalanceDelta
} from "../src/interfaces/IPoolManager.sol";

/// @notice The exemptSender early return comes FIRST in BOTH callbacks.
///         The production exempt caller (QpullWethAdapter) only ever does exact-in SELLS, whose WETH leg is
///         unspecified, so beforeSwap returns 0 for it either way and nothing in the adapter suite would fail if
///         the beforeSwap exempt check were deleted. These tests make that check load-bearing: a hook whose
///         exemptSender is a plain v4 router, driven through all four kinds (including the two WETH-specified
///         ones, A and D, where only the exempt check keeps beforeSwap from declaring a fee that afterSwap then
///         never take()s), inside the 1-hour gate, by a wallet that holds no pass. And the adapter's
///         partial-fill refund, run on a HOOKED pool.
///         Runs in both token orders (HookExemptSenderFlippedTest).
contract HookExemptSenderTest is QpullTaxHookFixture {
    /// Deploys a canonical-shaped hook at a fresh flag-carrying address with `exempt` as its exemptSender, opens its
    /// pool as the initializer (launchTime = now, so the gate is OPEN) and seeds liquidity over [lo, hi].
    function _openHookFor(address exempt, uint8 tag, int24 lo, int24 hi, uint256 liq)
        internal
        returns (QpullTaxHook h, V4PoolKey memory k)
    {
        address hAddr = address((uint160(tag) << 16) | FLAGS);
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), exempt)),
            hAddr
        );
        h = QpullTaxHook(hAddr);
        k = key;
        k.hooks = IV4Hooks(hAddr);
        _initializePool(k, SQRT_1_1);
        _addLiquidity(k, lo, hi, liq);
    }

    function _routerSwap(PoolSwapTest r, address who, V4PoolKey memory k, bool zfo, int256 amt, uint160 limit)
        internal
        returns (V4BalanceDelta)
    {
        vm.prank(who, who);
        return r.swap(k, IV4PoolManager.SwapParams(zfo, amt, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _sentinel(bool zfo) internal pure returns (uint160) {
        return zfo ? MIN_PRICE_P1 : MAX_PRICE_M1;
    }

    function _asOurKey(V4PoolKey memory k) internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(V4Currency.unwrap(k.currency0)),
            Currency.wrap(V4Currency.unwrap(k.currency1)),
            k.fee,
            k.tickSpacing,
            address(k.hooks)
        );
    }

    function _assertFlat(address h) internal view {
        assertEq(weth.balanceOf(h), 0, "hook holds no WETH");
        assertEq(qpull.balanceOf(h), 0, "hook holds no QPULL");
    }

    /// An exempt router, inside the gate, from a wallet with no pass: all four kinds (and a binding-limit exact-in
    /// buy) settle with EXACTLY the raw output of an identical hookless pool, move nothing to the treasury, record
    /// nothing, and leave the throttle record untouched. A and D are the load-bearing rows: with the beforeSwap exempt
    /// check deleted, beforeSwap declares a WETH fee, afterSwap's exempt return never take()s it, the hook's delta
    /// stays open and the unlock reverts (CurrencyNotSettled), so these swaps would fail.
    function test_exemptRouter_allFourKindsInsideGate_equalHooklessOutput_noFeeNoRecords() public {
        PoolSwapTest exemptRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        (QpullTaxHook h, V4PoolKey memory k) = _openHookFor(address(exemptRouter), 0x5E, FULL_LO, FULL_HI, 1e24);
        V4PoolKey memory raw = _openHookless();
        assertLt(block.timestamp, h.launchTime() + h.GATE_DURATION(), "inside the gate window");
        assertEq(nft.balanceOf(sniper), 0, "sniper holds no pass");
        vm.startPrank(sniper);
        weth.approve(address(exemptRouter), type(uint256).max);
        qpull.approve(address(exemptRouter), type(uint256).max);
        vm.stopPrank();

        bool buy = _buyZeroForOne();

        // POSITIVE CONTROL: the same buy through a NON-exempt router is gated on this very pool.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(h),
                IV4Hooks.afterSwap.selector,
                abi.encodeWithSelector(QpullTaxHook.Gated.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _routerSwap(swapRouter, sniper, k, buy, -1e21, _sentinel(buy));

        // binding-limit exact-in buy first (both pools at 1:1): an exempt caller never reaches PartialFill
        uint160 lim = _bindingLimit(buy);
        V4BalanceDelta dh = _routerSwap(exemptRouter, sniper, k, buy, -1e21, lim);
        V4BalanceDelta dr = _routerSwap(exemptRouter, sniper, raw, buy, -1e21, lim);
        assertEq(V4BalanceDelta.unwrap(dh), V4BalanceDelta.unwrap(dr), "A (binding limit): == hookless partial fill");
        int128 wIn = qpullIs0 ? _a1(dh) : _a0(dh);
        assertLt(uint256(uint128(-wIn)), 1e21, "the binding limit really did stop the fill short");

        int256[4] memory amts = [int256(-1e21), int256(5e20), int256(-5e20), int256(3e20)];
        bool[4] memory zfos = [buy, buy, !buy, !buy]; // A exact-in buy, B exact-out buy, C exact-in sell, D exact-out sell
        for (uint256 i; i < 4; ++i) {
            dh = _routerSwap(exemptRouter, sniper, k, zfos[i], amts[i], _sentinel(zfos[i]));
            dr = _routerSwap(exemptRouter, sniper, raw, zfos[i], amts[i], _sentinel(zfos[i]));
            assertEq(V4BalanceDelta.unwrap(dh), V4BalanceDelta.unwrap(dr), "exempt swap == raw hookless pool output");
        }

        assertEq(weth.balanceOf(feeSink), 0, "no WETH to the treasury");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL to the treasury");
        assertEq(packRec.calls(), 0, "no pack records");
        assertEq(boardRec.calls(), 0, "no leaderboard records");
        (uint64 at, uint32 buys, uint128 spent) = h.earlyBuyer(sniper);
        assertEq(uint256(at) + buys + spent, 0, "no throttle record: the gate and throttle never ran");
        _assertFlat(address(h));
    }

    /// The callbacks themselves, called as the PoolManager: for an exempt sender BOTH return a zero delta on a
    /// WETH-specified swap (A and D) and on an unspecified one (B and C); the same params from any other sender
    /// carry the exact fee. The positive control is what makes the zero meaningful.
    function test_exemptSender_bothCallbacksReturnZeroDelta_nonExemptCarriesFee() public {
        PoolSwapTest exemptRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        (QpullTaxHook h, V4PoolKey memory k) = _openHookFor(address(exemptRouter), 0x5D, FULL_LO, FULL_HI, 1e24);
        PoolKey memory ok_ = _asOurKey(k);
        bool buy = _buyZeroForOne();
        uint256 t = 2000; // pool opened now: sell step 0

        OurIPM.SwapParams memory a = OurIPM.SwapParams(buy, -1e21, _sentinel(buy));
        OurIPM.SwapParams memory b = OurIPM.SwapParams(buy, 1e21, _sentinel(buy));
        OurIPM.SwapParams memory c = OurIPM.SwapParams(!buy, -1e21, _sentinel(!buy));
        OurIPM.SwapParams memory d = OurIPM.SwapParams(!buy, 1e21, _sentinel(!buy));
        uint256 feeA = (uint256(1e21) * 400 + 9999) / 10_000;
        uint256 feeD = (uint256(1e21) * t + (10_000 - t) - 1) / (10_000 - t);

        vm.startPrank(address(manager));
        (bytes4 sel, int256 bsd, uint24 lpOverride) = h.beforeSwap(address(exemptRouter), ok_, a, "");
        assertEq(sel, QpullTaxHook.beforeSwap.selector, "selector");
        assertEq(bsd, 0, "exempt A: zero beforeSwap delta");
        assertEq(lpOverride, 0, "no LP fee override");
        (, bsd,) = h.beforeSwap(address(exemptRouter), ok_, d, "");
        assertEq(bsd, 0, "exempt D: zero beforeSwap delta");
        (, bsd,) = h.beforeSwap(address(exemptRouter), ok_, b, "");
        assertEq(bsd, 0, "exempt B: zero beforeSwap delta");
        (, bsd,) = h.beforeSwap(address(exemptRouter), ok_, c, "");
        assertEq(bsd, 0, "exempt C: zero beforeSwap delta");

        // positive control: any other sender's A and D carry the fee on the specified leg
        (, bsd,) = h.beforeSwap(address(swapRouter), ok_, a, "");
        assertEq(bsd, int256(feeA) << 128, "non-exempt A: ceil(4%) on the specified leg");
        (, bsd,) = h.beforeSwap(address(swapRouter), ok_, d, "");
        assertEq(bsd, int256(feeD) << 128, "non-exempt D: ceil(N * t / (1e4 - t)) on the specified leg");

        // afterSwap: exempt returns a zero unspecified delta for every kind, without touching any state
        OurIPM.SwapParams[4] memory ps = [a, b, c, d];
        for (uint256 i; i < 4; ++i) {
            (bytes4 s2, int128 hd) = h.afterSwap(address(exemptRouter), ok_, ps[i], OurBalanceDelta.wrap(0), "");
            assertEq(s2, QpullTaxHook.afterSwap.selector, "afterSwap selector");
            assertEq(hd, 0, "exempt: zero afterSwap delta");
        }
        vm.stopPrank();
        assertEq(weth.balanceOf(feeSink), 0, "nothing taken");
        assertEq(packRec.calls(), 0, "nothing recorded");
    }

    /// Partial-fill refund on the HOOKED pool: the Treasury's adapter sells into a pool whose liquidity runs out before
    /// amountIn is consumed. The swap stops at the sentinel price, the adapter settles exactly what v4 consumed and
    /// refunds the rest, and every number equals the same sell on an identical hookless pool. No PartialFill, no fee,
    /// no records, nothing stranded in the adapter or the hook.
    function test_adapterPartialFillRefund_onHookedPool() public {
        (QpullTaxHook h, V4PoolKey memory k) = _openHookFor(address(adapter), 0x5F, -600, 600, 1e21);
        V4PoolKey memory raw = key;
        raw.hooks = IV4Hooks(address(0));
        _initializePool(raw, SQRT_1_1);
        _addLiquidity(raw, -600, 600, 1e21);

        uint256 amountIn = 1e21; // ~30x what the [-600, 600] range can absorb
        bool sellZfo = !_buyZeroForOne();
        V4BalanceDelta dr = swapRouter.swap(
            raw,
            IV4PoolManager.SwapParams(sellZfo, -int256(amountIn), _sentinel(sellZfo)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 rawConsumed = uint256(uint128(-(qpullIs0 ? _a0(dr) : _a1(dr))));
        uint256 rawOut = uint256(uint128(qpullIs0 ? _a1(dr) : _a0(dr)));
        assertLt(rawConsumed, amountIn, "the hookless reference really is a partial fill");

        adapter.setPoolKey(_asOurKey(k));
        address sink = makeAddr("sink");
        qpull.mint(treasury, amountIn);
        vm.startPrank(treasury, treasury);
        qpull.approve(address(adapter), amountIn);
        uint256 out = adapter.swapExactIn(address(qpull), address(weth), amountIn, 1, sink);
        vm.stopPrank();

        assertEq(out, rawOut, "adapter output == hookless output for the same partial fill");
        assertEq(weth.balanceOf(sink), out, "WETH delivered in full");
        assertEq(qpull.balanceOf(sink), amountIn - rawConsumed, "unconsumed QPULL refunded");
        assertGt(qpull.balanceOf(sink), 0, "refund is non-zero");
        assertEq(qpull.balanceOf(address(adapter)), 0, "nothing stranded in the adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "no WETH stranded in the adapter");
        assertEq(weth.balanceOf(feeSink), 0, "no fee");
        assertEq(qpull.balanceOf(feeSink), 0, "no fee");
        assertEq(packRec.calls(), 0, "no records");
        _assertFlat(address(h));
    }
}

contract HookExemptSenderFlippedTest is HookExemptSenderTest {
    function _flipTokenOrder() internal pure override returns (bool) {
        return true;
    }
}
