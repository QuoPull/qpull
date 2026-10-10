// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";

// ─── the REAL Uniswap V4 core (vendored, tag v4.0.0) — the hook is tested against actual
//     PoolManager semantics, not a mock ────────────────────────────────────────────────────
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
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { Pool } from "v4-core/libraries/Pool.sol";

// ─── ours ────────────────────────────────────────────────────────────────────────────────
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import {
    IPoolManager as ourIPM,
    PoolKey,
    Currency,
    BalanceDelta as OurBalanceDelta
} from "../src/interfaces/IPoolManager.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { IPackRegistry, ILeaderboardRegistry } from "../src/interfaces/IRegistries.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { V4LpBase } from "./utils/V4LpBase.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// @notice Shared fixture: the canonical QPULL/WETH pool WITH QpullTaxHook on the REAL v4-core PoolManager,
///         full-range 1e24 liquidity at 1:1, mock registries, the exempt adapter, and the helpers every hook
///         suite uses. Holds no tests, so a suite that inherits it (FS2WashCredit) does not re-run this file's.
abstract contract QpullTaxHookFixture is Test, V4LpBase {
    using TransientStateLibrary for IV4PoolManager;
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // add+remove LP gate (0x1ACC)
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220; // full range at spacing 60
    int24 constant FULL_HI = 887_220;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;

    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder packRec;
    MockRecorder boardRec;

    QpullTaxHook hook;
    address hookAddr = address(uint160((0xAA << 16) | FLAGS));
    QpullWethAdapter adapter;

    address feeSink = makeAddr("feeSink"); // the hook's treasury (fee recipient)
    address treasury = makeAddr("treasury"); // the adapter's authorized swap caller
    address alice; // NFT holder
    address sniper; // not a holder

    bool qpullIs0;
    V4PoolKey key; // v4-core-typed key (routers/manager)

    function setUp() public {
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager))); // this contract IS the hook's initializer, so it is the LP
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));

        qpull = new MockERC20();
        weth = new MockERC20();
        // v4's specified/unspecified mapping depends on token order, so every test also runs flipped.
        if (_flipTokenOrder()) (qpull, weth) = (weth, qpull);
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        packRec = new MockRecorder();
        boardRec = new MockRecorder();

        alice = makeAddr("alice");
        sniper = makeAddr("sniper");
        nft.set(1, alice, 0); // alice holds an NFT; sniper does not

        // production order: adapter first, then the hook naming it exemptSender (an immutable)
        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(treasury);

        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
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

        // liquidity + trader funding
        qpull.mint(address(this), 1e27);
        weth.mint(address(this), 1e27);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? alice : sniper;
            qpull.mint(who, 1e24);
            weth.mint(who, 1e24);
            vm.startPrank(who);
            qpull.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        _initializePool(key, SQRT_1_1); // sender = this = the hook's initializer
        // LP is gated to sender == initializer; V4LpBase adds from this contract, which is the initializer
        _addLiquidity(key, FULL_LO, FULL_HI, 1e24);
    }

    /// Overridden to true by QpullTaxHookFlippedTest / WashCreditFlippedTest.
    function _flipTokenOrder() internal pure virtual returns (bool) {
        return false;
    }

    function _cfg(address p, address b, address exempt)
        internal
        view
        returns (QpullTaxHook.HookConfig memory)
    {
        return QpullTaxHook.HookConfig({
            poolManager: address(manager),
            qpull: address(qpull),
            weth: address(weth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            treasury: feeSink,
            packRegistry: p,
            leaderboardRegistry: b,
            nft: address(nft),
            exemptSender: exempt,
            initializer: address(this),
            // First-hour buy-size cap left effectively off in this fixture: the existing gate tests buy
            // 1e21 inside the window, and the throttle deserves its own dedicated suite.
            earlyBuyCapWei: type(uint256).max
        });
    }

    function _swap(address as_, bool zeroForOne, int256 amountSpecified) internal returns (V4BalanceDelta) {
        if (as_ != address(this)) vm.prank(as_, as_); // msg.sender AND tx.origin = the trader
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0; // buy = QPULL flows out
    }

    function _pastGate() internal {
        vm.warp(block.timestamp + hook.GATE_DURATION() + 1);
    }

    // Warp past the 48h sell-tax decay window so sells settle at the flat 4% floor (and past the gate).
    function _pastSellDecay() internal {
        vm.warp(hook.launchTime() + hook.SELL_DECAY() + 1);
    }

    /// Direct negative-delta modifyLiquidity from the initializer itself — the strongest form of the claim:
    /// not "the router is refused", but "the identity the gate used to trust is refused".
    function _addLiquidityRemove(V4PoolKey memory k, int24 lo, int24 hi, int256 delta) internal {
        _lpManager.unlock(abi.encode(k, lo, hi, delta));
    }

    function _assertExactOutSell(uint256 t, string memory why) internal {
        uint256 n = 1e21;
        uint256 wBefore = weth.balanceOf(alice);
        uint256 sinkBefore = weth.balanceOf(feeSink);
        uint256 recBefore = packRec.calls();
        _swap(alice, !_buyZeroForOne(), int256(n)); // receive exactly 1e21 WETH
        uint256 fee = weth.balanceOf(feeSink) - sinkBefore;

        assertEq(weth.balanceOf(alice) - wBefore, n, "seller receives exactly N");
        assertEq(fee, (n * t + (10_000 - t) - 1) / (10_000 - t), why);
        assertLe(t * (n + fee), fee * 10_000, "fee >= t of gross");
        assertLt(fee * 10_000, t * (n + fee) + 10_000, "and not more than 1 wei over");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
        assertEq(packRec.calls(), recBefore, "sells record nothing");
        _assertHookFlat();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    /// Deploys the hook artifact `what` (base or a subclass) at a fresh flag-carrying address, opens its
    /// canonical pool as the initializer (stamping launchTime = now) and seeds full-range LP.
    function _openPoolWith(string memory what, uint8 tag)
        internal
        returns (QpullTaxHook h, V4PoolKey memory k)
    {
        address hAddr = address((uint160(tag) << 16) | FLAGS);
        deployCodeTo(what, abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))), hAddr);
        h = QpullTaxHook(hAddr);
        k = key;
        k.hooks = IV4Hooks(hAddr);
        _initializePool(k, SQRT_1_1); // sender = this = the initializer
        _addLiquidity(k, FULL_LO, FULL_HI, 1e24);
    }

    /// Exact-in sell of 1e21 QPULL by alice through pool `k`; asserts the WETH fee equals `expectedBps` of
    /// the pool's pre-fee WETH output TO THE WEI. fee = floor(U * bps / 10000) and userOut = U - fee, so
    /// userOut + fee reconstructs U exactly and the comparison has no rounding slack.
    function _assertSellTaxBps(V4PoolKey memory k, uint256 expectedBps, string memory why) internal {
        uint256 sinkBefore = weth.balanceOf(feeSink);
        uint256 userBefore = weth.balanceOf(alice);
        bool zeroForOne = !_buyZeroForOne(); // sell = QPULL flows in
        vm.prank(alice, alice);
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(zeroForOne, -1e21, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = weth.balanceOf(feeSink) - sinkBefore;
        uint256 preFeeOut = (weth.balanceOf(alice) - userBefore) + fee;
        assertGt(fee, 0, "sell taxed");
        assertEq(fee, (preFeeOut * expectedBps) / 10_000, why);
    }

    /// Same as _openPoolWith, with caller-chosen registries (out-of-gas burners).
    function _openPoolWithRegistries(string memory what, uint8 tag, address p, address b)
        internal
        returns (QpullTaxHook h, V4PoolKey memory k)
    {
        address hAddr = address((uint160(tag) << 16) | FLAGS);
        deployCodeTo(what, abi.encode(_cfg(p, b, address(adapter))), hAddr);
        h = QpullTaxHook(hAddr);
        k = key;
        k.hooks = IV4Hooks(hAddr);
        _initializePool(k, SQRT_1_1);
        _addLiquidity(k, FULL_LO, FULL_HI, 1e24);
    }

    /// A hookless QPULL/WETH pool on the same manager with the same shape and depth as the canonical one.
    function _openHookless() internal returns (V4PoolKey memory k) {
        k = key;
        k.hooks = IV4Hooks(address(0));
        _initializePool(k, SQRT_1_1);
        _addLiquidity(k, FULL_LO, FULL_HI, 1e24);
    }

    /// Exact-in buy of `amt` WETH on a hookless pool from this contract: the raw pool's QPULL output.
    function _rawExactInBuyOut(V4PoolKey memory k, uint256 amt) internal returns (uint256) {
        bool zfo = _buyZeroForOne();
        V4BalanceDelta d = swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(zfo, -int256(amt), zfo ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        int128 q = qpullIs0 ? _a0(d) : _a1(d);
        return uint256(uint128(q));
    }

    function _swapLimit(address as_, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (V4BalanceDelta)
    {
        vm.prank(as_, as_);
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amountSpecified, limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// A price limit 0.01% away from 1:1 in the swap's direction: binds for any 1e21+ swap on 1e24 liquidity.
    function _bindingLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? SQRT_1_1 - SQRT_1_1 / 10_000 : SQRT_1_1 + SQRT_1_1 / 10_000;
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hookAddr,
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// The hook never holds tokens and never leaves a delta open.
    function _assertHookFlat() internal view {
        assertEq(weth.balanceOf(hookAddr), 0, "hook holds no WETH");
        assertEq(qpull.balanceOf(hookAddr), 0, "hook holds no QPULL");
        IV4PoolManager pm = IV4PoolManager(address(manager));
        assertEq(pm.currencyDelta(hookAddr, V4Currency.wrap(address(weth))), 0, "hook WETH delta 0");
        assertEq(pm.currencyDelta(hookAddr, V4Currency.wrap(address(qpull))), 0, "hook QPULL delta 0");
    }

    function _ourKey() internal view returns (PoolKey memory k) {
        k = PoolKey({
            currency0: Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hookAddr
        });
    }

    function _a0(V4BalanceDelta d) internal pure returns (int128 a) {
        assembly {
            a := sar(128, d)
        }
    }

    function _a1(V4BalanceDelta d) internal pure returns (int128 a) {
        assembly {
            a := signextend(15, d)
        }
    }
}

/// @notice QpullTaxHook against the REAL v4-core PoolManager: fee mechanics in all four
///         swap shapes, first-hour gate, exemption, registry fan-out + try/catch, pool-creation
///         control, and the adapter's hooked-pool binding.
contract QpullTaxHookTest is QpullTaxHookFixture {
    function test_tokenOrderIsWhatTheSuiteClaims() public view {
        // the two deploys land in a fixed CREATE order; flipping must actually flip qpullIs0
        assertEq(qpullIs0, (address(qpull) < address(weth)), "qpullIs0 consistent");
    }

    // ─── wiring sanity ───────────────────────────────────────────────────────

    /// The hook's hand-written callback signatures MUST hash to v4-core's IHooks selectors — this is
    /// what makes the PoolManager's calls land. Cross-checked against the vendored interface.
    function test_selectorsMatchV4Core() public pure {
        assertEq(QpullTaxHook.afterSwap.selector, IV4Hooks.afterSwap.selector, "afterSwap selector");
        assertEq(QpullTaxHook.beforeSwap.selector, IV4Hooks.beforeSwap.selector, "beforeSwap selector");
        assertEq(
            QpullTaxHook.afterInitialize.selector,
            IV4Hooks.afterInitialize.selector,
            "afterInitialize selector"
        );
    }

    function test_initializeStampsLaunchTime() public view {
        assertEq(hook.launchTime(), block.timestamp, "launchTime = pool creation");
    }

    function test_callbacksRejectNonPoolManager() public {
        vm.expectRevert(QpullTaxHook.NotPoolManager.selector);
        // a fake "buy" — if this were accepted, anyone could mint themselves tickets/points
        hook.afterSwap(
            address(this),
            _ourKey(),
            ourIPM.SwapParams(_buyZeroForOne(), -1e18, 0),
            OurBalanceDelta.wrap(0),
            ""
        );
        vm.expectRevert(QpullTaxHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), _ourKey(), SQRT_1_1, 0);
        vm.expectRevert(QpullTaxHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), _ourKey(), ourIPM.SwapParams(_buyZeroForOne(), -1e18, 0), "");
    }

    /// Flags: 0x1ACC, a valid v4 hook address, and a hook deployed at the old 0x1A44 bits refuses to exist.
    function test_flags0x1ACC_andOldBitsRefused() public {
        assertEq(uint256(hook.REQUIRED_FLAGS()), 0x1ACC, "REQUIRED_FLAGS");
        assertEq(uint256(FLAGS), 0x1ACC, "harness FLAGS");
        assertTrue(Hooks.isValidHookAddress(IV4Hooks(hookAddr), FEE), "valid v4 hook address");
        address old = address(uint160((0x57 << 16) | 0x1A44));
        vm.etch(
            old,
            abi.encodePacked(
                vm.getCode("src/hooks/QpullTaxHook.sol:QpullTaxHook"),
                abi.encode(_cfg(address(packRec), address(boardRec), address(adapter)))
            )
        );
        (bool ok, bytes memory ret) = old.call("");
        assertFalse(ok, "0x1A44 address must not deploy");
        assertEq(ret, abi.encodeWithSelector(QpullTaxHook.BadFlags.selector), "typed BadFlags");
    }

    // ─── pool-creation control ───────────────────────────────────────────────

    function test_nonCanonicalPoolCannotAttachHook() public {
        V4PoolKey memory bad = key;
        bad.fee = 500; // wrong fee => not the canonical pool
        vm.expectRevert(); // NotCanonicalPool, wrapped by v4-core's hook-revert bubbling
        _initializePool(bad, SQRT_1_1);
    }

    // Liquidity provision is restricted to the protocol (the pool's initializer),
    // closing the untaxed LP side-door for acquiring/disposing QPULL.
    function test_nonInitializerCannotAddLiquidity() public {
        address stranger = makeAddr("lpStranger");
        qpull.mint(stranger, 1e24);
        weth.mint(stranger, 1e24);
        vm.startPrank(stranger, stranger); // msg.sender AND tx.origin = stranger (not the initializer)
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        vm.expectRevert(); // LiquidityRestricted, wrapped by v4-core's hook-revert bubbling
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
        vm.stopPrank();
    }

    /// The gate has no `tx.origin == initializer` branch, so a ROUTER can never
    /// add on the initializer's behalf, not even when the initializer signs the transaction. This is the
    /// case an earlier version of the gate admitted: `sender` is the router, `tx.origin` is
    /// the initializer, and the old code said yes.
    function test_routerCannotAddEvenWhenTheInitializerSignsIt() public {
        qpull.mint(address(this), 1e24);
        weth.mint(address(this), 1e24);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        vm.prank(address(this), address(this)); // tx.origin IS the initializer — and it no longer matters
        vm.expectRevert();
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e23, 0), "");
    }

    function test_initializerCanAddLiquidity() public {
        // the protocol (initializer == this contract) provides liquidity by calling modifyLiquidity itself,
        // from its own address, inside its own unlock — exactly what QpullLiquidityLock does in production.
        qpull.mint(address(this), 1e24);
        weth.mint(address(this), 1e24);
        _addLiquidity(key, FULL_LO, FULL_HI, 1e23);
    }

    // ── REMOVAL DOES NOT EXIST ON THE CANONICAL POOL ──────────────────────────

    function test_nonInitializerCannotRemoveLiquidity() public {
        address stranger = makeAddr("lpRemover");
        vm.startPrank(stranger, stranger);
        vm.expectRevert(); // LiquidityRemovalDisabled, wrapped by v4-core's hook-revert bubbling
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, -1e23, 0), "");
        vm.stopPrank();
    }

    /// THIS TEST USED TO ASSERT THE OPPOSITE.
    ///
    /// An earlier version asserted, and passed, that the protocol could
    /// withdraw liquidity from the canonical pool without paying the 4% that funds the prize games. That is
    /// an untaxed side-door, and because the old gate also admitted
    /// `tx.origin == initializer`, ANY contract the initializer EOA signed a transaction with could walk
    /// through it. The side-door is a ROUND TRIP: add untaxed, remove untaxed. Killing the return
    /// leg collapses it, so `beforeRemoveLiquidity` now reverts for everyone, with no exception for the
    /// initializer and none for the lock (which never had removal code to begin with).
    function test_evenTheInitializerCannotRemoveLiquidity() public {
        vm.expectRevert(); // LiquidityRemovalDisabled
        _addLiquidityRemove(key, FULL_LO, FULL_HI, -1e23);
    }

    function test_initializeFrontRunBlocked() public {
        // a second canonical-shaped pool cannot exist (same id), so demonstrate on a fresh hook:
        // an attacker initializing before the deployer would burn the gate window — refused.
        address hook2Addr = address(uint160((0xBB << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hook2Addr
        );
        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hook2Addr);
        vm.prank(sniper, sniper);
        vm.expectRevert(); // NotInitializer, wrapped
        _initializePool(k2, SQRT_1_1);
    }

    // ─── the tax, all four swap kinds: ALWAYS WETH, exact-out grossed up to nominal ────────────────────

    /// Kind A. WETH specified: beforeSwap puts ceil(G * 4%) on the specified leg, the pool swaps G - fee, the
    /// buyer spends exactly G, and credit == G. The QPULL output is exactly the raw pool output for G - fee
    /// (measured on an identical hookless pool) and at least 96% of the old hook's output for G.
    function test_buyExactIn_taxedInWeth() public {
        _pastGate();
        uint256 g = 1e21;
        uint256 fee = (g * 400 + 9999) / 10_000;
        V4PoolKey memory raw = _openHookless();

        uint256 s = vm.snapshotState();
        uint256 rawOutNet = _rawExactInBuyOut(raw, g - fee); // the pool's output for G - fee, no hook
        vm.revertToState(s);
        s = vm.snapshotState();
        uint256 rawOutGross = _rawExactInBuyOut(raw, g); // what the old hook skimmed 4% of
        vm.revertToState(s);

        uint256 qBefore = qpull.balanceOf(alice);
        uint256 wBefore = weth.balanceOf(alice);
        V4BalanceDelta d = _swap(alice, _buyZeroForOne(), -int256(g));
        uint256 userOut = qpull.balanceOf(alice) - qBefore;

        assertEq(wBefore - weth.balanceOf(alice), g, "buyer spends exactly G");
        assertEq(weth.balanceOf(feeSink), fee, "fee == ceil(G * 400 / 1e4) WETH");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee, ever");
        assertEq(userOut, rawOutNet, "QPULL out == raw pool output for G - fee");
        assertGe(userOut * 100, rawOutGross * 96, "QPULL out >= 0.96 x the untaxed output for G");
        assertEq(packRec.lastGross(), g, "credit == G");
        assertEq(boardRec.lastGross(), g, "leaderboard credit == G");
        int128 qd = qpullIs0 ? _a0(d) : _a1(d);
        assertEq(uint256(uint128(qd)), userOut, "router delta = delivered amount");
        _assertHookFlat();
    }

    /// Kind C. UNCHANGED: floor(G * t / 1e4) of the WETH output (keeper grossUpForExemptSell mirrors this).
    function test_sellExactIn_taxedInWeth() public {
        _pastSellDecay(); // sells decay 20%->4% over 48h; assert the 4% floor past the window
        uint256 amountIn = 1e21;
        uint256 before = weth.balanceOf(alice);
        _swap(alice, !_buyZeroForOne(), -int256(amountIn)); // sell exactly 1e21 QPULL
        uint256 userOut = weth.balanceOf(alice) - before;
        uint256 fee = weth.balanceOf(feeSink);

        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((userOut + fee) * 400) / 10_000, "fee = 4% of pre-fee WETH output");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee on an exact-in sell");
        _assertHookFlat();
    }

    /// Kind B. QPULL specified: the WETH fee rides the unspecified leg, grossed up so it is at least 4% of
    /// what the buyer actually pays, and credit == that payment.
    function test_buyExactOut_taxedInWeth() public {
        _pastGate();
        uint256 wantOut = 1e21;
        uint256 qBefore = qpull.balanceOf(alice);
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), int256(wantOut)); // receive exactly 1e21 QPULL
        uint256 paid = wBefore - weth.balanceOf(alice);
        uint256 fee = weth.balanceOf(feeSink);
        uint256 poolIn = paid - fee;

        assertEq(qpull.balanceOf(alice) - qBefore, wantOut, "exact output delivered in full");
        assertEq(fee, (poolIn * 400 + 9599) / 9600, "fee == ceil(P * 400 / 9600)");
        assertGe(fee * 10_000, 400 * paid, "fee >= 4% of what the buyer paid");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
        assertEq(packRec.lastGross(), paid, "credit == WETH paid");
        _assertHookFlat();
    }

    /// Kind D. WETH specified: the seller receives exactly N, the pool pays N + fee, fee = ceil(N*t/(1e4-t)),
    /// so t * (N + fee) <= fee * 1e4 < t * (N + fee) + 1e4. Checked at the flat 4% and at the 20% launch rate.
    function test_sellExactOut_taxedInWeth() public {
        _assertExactOutSell(2000, "step 0: 20% of gross"); // launch window
        _pastSellDecay();
        _assertExactOutSell(400, "flat 4% of gross");
    }

    // ─── WETH-tax edges: PartialFill, dust, bounds ───────────────────────────

    /// Kind A with a binding sqrtPriceLimit: reverts PartialFill (never overcharged on a partial fill).
    function test_partialFill_exactInBuyWithBindingLimitReverts() public {
        _pastGate();
        vm.expectRevert(_wrapped(IV4Hooks.afterSwap.selector, abi.encodeWithSelector(QpullTaxHook.PartialFill.selector)));
        _swapLimit(alice, _buyZeroForOne(), -1e21, _bindingLimit(_buyZeroForOne()));
    }

    /// Kind D with a binding sqrtPriceLimit: reverts PartialFill.
    function test_partialFill_exactOutSellWithBindingLimitReverts() public {
        _pastSellDecay();
        vm.expectRevert(_wrapped(IV4Hooks.afterSwap.selector, abi.encodeWithSelector(QpullTaxHook.PartialFill.selector)));
        _swapLimit(alice, !_buyZeroForOne(), 1e21, _bindingLimit(!_buyZeroForOne()));
    }

    /// Kinds B and C with a binding limit succeed, taxed on the actual fill.
    function test_partialFill_exactOutBuyAndExactInSellTaxedOnActualFill() public {
        _pastSellDecay();
        uint256 wBefore = weth.balanceOf(alice);
        uint256 qBefore = qpull.balanceOf(alice);
        _swapLimit(alice, _buyZeroForOne(), 1e21, _bindingLimit(_buyZeroForOne()));
        uint256 got = qpull.balanceOf(alice) - qBefore;
        uint256 paid = wBefore - weth.balanceOf(alice);
        uint256 fee = weth.balanceOf(feeSink);
        assertLt(got, 1e21, "B: partial fill");
        assertGt(got, 0, "B: something filled");
        assertEq(fee, ((paid - fee) * 400 + 9599) / 9600, "B: fee on the actual fill");
        assertEq(packRec.lastGross(), paid, "B: credit == WETH actually paid");

        uint256 sink2 = weth.balanceOf(feeSink);
        wBefore = weth.balanceOf(alice);
        qBefore = qpull.balanceOf(alice);
        _swapLimit(alice, !_buyZeroForOne(), -1e22, _bindingLimit(!_buyZeroForOne()));
        uint256 fee2 = weth.balanceOf(feeSink) - sink2;
        uint256 out2 = weth.balanceOf(alice) - wBefore;
        assertLt(qBefore - qpull.balanceOf(alice), 1e22, "C: partial fill");
        assertEq(fee2, ((out2 + fee2) * 400) / 10_000, "C: floor fee on the actual fill");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
    }

    /// Dust. G = 1: fee 1, pool delta 0, credit 1. G = 2: fee 1, the pool consumes G - 1, credit 2.
    /// G = 25: fee 1, credit 25. G = 26: fee 2, credit 26.
    function test_dust_exactInBuyRoundsUpAndCreditsSpend() public {
        _pastGate();
        uint256[4] memory gs = [uint256(1), 2, 25, 26];
        uint256[4] memory fees = [uint256(1), 1, 1, 2];
        for (uint256 i; i < 4; ++i) {
            uint256 sink = weth.balanceOf(feeSink);
            uint256 wBefore = weth.balanceOf(alice);
            V4BalanceDelta d = _swap(alice, _buyZeroForOne(), -int256(gs[i]));
            assertEq(weth.balanceOf(feeSink) - sink, fees[i], "dust fee");
            assertEq(wBefore - weth.balanceOf(alice), gs[i], "spend == G");
            assertEq(packRec.lastGross(), gs[i], "credit == G");
            int128 wd = qpullIs0 ? _a1(d) : _a0(d);
            assertEq(uint256(uint128(-wd)), gs[i], "router WETH delta == G");
        }
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
    }

    /// Bounds: an exact-in buy of 2**127 and an exact-out sell whose N + fee exceeds int128.max revert SwapTooLarge.
    function test_bounds_swapTooLarge() public {
        _pastSellDecay();
        bytes memory tooLarge = abi.encodeWithSelector(QpullTaxHook.SwapTooLarge.selector);
        vm.expectRevert(_wrapped(IV4Hooks.beforeSwap.selector, tooLarge));
        _swap(alice, _buyZeroForOne(), -int256(uint256(1) << 127));
        vm.expectRevert(_wrapped(IV4Hooks.beforeSwap.selector, tooLarge));
        _swap(alice, !_buyZeroForOne(), int256(uint256(uint128(type(int128).max))));
    }

    // ─── an out-of-gas registry reverts the buy; a logic fault still fails soft ──────────────────

    function test_outOfGasRegistryRevertsBuy_depth1And2() public {
        for (uint256 depth = 1; depth <= 2; ++depth) {
            uint256 s = vm.snapshotState();
            GasBurnRecorder burner = new GasBurnRecorder(address(0));
            if (depth == 2) burner = new GasBurnRecorder(address(burner));
            (, V4PoolKey memory k) = _openPoolWithRegistries(
                "src/hooks/QpullTaxHook.sol:QpullTaxHook", uint8(0x60 + depth), address(burner), address(boardRec)
            );
            _pastSellDecay();
            vm.prank(alice, alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(k.hooks),
                    IV4Hooks.afterSwap.selector,
                    abi.encodeWithSelector(QpullTaxHook.RecordOutOfGas.selector, bytes32("pack")),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            swapRouter.swap(
                k,
                IV4PoolManager.SwapParams(_buyZeroForOne(), -1e21, _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            // a SELL never calls a registry, so the burner cannot block it
            vm.prank(alice, alice);
            swapRouter.swap(
                k,
                IV4PoolManager.SwapParams(!_buyZeroForOne(), -1e21, !_buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            vm.revertToState(s);
        }
    }

    function test_leaderboardOutOfGasAfterPackRecordReverts() public {
        GasBurnRecorder burner = new GasBurnRecorder(address(0));
        (, V4PoolKey memory k) = _openPoolWithRegistries(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook", 0x63, address(packRec), address(burner)
        );
        _pastSellDecay();
        vm.prank(alice, alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(k.hooks),
                IV4Hooks.afterSwap.selector,
                abi.encodeWithSelector(QpullTaxHook.RecordOutOfGas.selector, bytes32("leaderboard")),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(_buyZeroForOne(), -1e21, _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // ─── first-hour holder gate ──────────────────────────────────────────────

    function test_gate_blocksNonHolderBuysFirstHour() public {
        vm.expectRevert(); // Gated, wrapped by v4-core's hook-revert bubbling
        _swap(sniper, _buyZeroForOne(), -1e21);
    }

    function test_gate_allowsHolderBuysFirstHour() public {
        _swap(alice, _buyZeroForOne(), -1e21);
        assertEq(weth.balanceOf(feeSink), (uint256(1e21) * 400 + 9999) / 10_000, "holder buy went through, taxed in WETH");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
    }

    function test_gate_sellsUnaffectedFirstHour() public {
        _swap(sniper, !_buyZeroForOne(), -1e21); // non-holder SELL during the gate: allowed
        assertGt(weth.balanceOf(feeSink), 0, "sell taxed as usual");
    }

    function test_gate_expiresAfterOneHour() public {
        _pastGate();
        _swap(sniper, _buyZeroForOne(), -1e21);
        assertEq(weth.balanceOf(feeSink), (uint256(1e21) * 400 + 9999) / 10_000, "post-gate buy by non-holder OK, WETH fee");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
    }

    // ─── registry fan-out ────────────────────────────────────────────────────

    function test_buyNotifiesPackAndBoard_creditedToSigner() public {
        _pastGate();
        // Game credit is the WETH the buyer paid, not the QPULL amount. On an exact-in buy of G = 1e21
        // WETH the pool swaps G - fee and the WETH fee rides the specified leg, so the buyer spends exactly G
        // and credit == G. The standalone jackpot registry is gone: buys notify exactly the pack and
        // leaderboard registries.
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -1e21);
        uint256 grossWeth = wBefore - weth.balanceOf(alice);

        assertEq(packRec.calls(), 1, "pack notified");
        assertEq(packRec.lastTrader(), alice, "credited to tx.origin");
        assertEq(packRec.lastGross(), grossWeth, "gross = WETH-in volume");
        assertEq(boardRec.calls(), 1, "leaderboard notified");
        assertEq(boardRec.lastTrader(), alice, "leaderboard trader");
        assertEq(boardRec.lastGross(), grossWeth, "leaderboard gross = WETH-in volume");
    }

    function test_sellRecordsNothingGameSide() public {
        _pastGate();
        // Sells are taxed (the fee arrives in WETH) but record NOTHING game-side: the standalone
        // jackpot game that used to take sell entries is deleted, and the hook only ever credits the
        // pack + leaderboard registries on BUYS. The sell tax funds the games purely via Treasury.convert().
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, !_buyZeroForOne(), -1e21);
        assertGt(weth.balanceOf(feeSink) + (weth.balanceOf(alice) - wBefore), 0, "sell executed"); // sanity
        assertGt(weth.balanceOf(feeSink), 0, "sell still taxed in WETH");
        assertEq(packRec.calls(), 0, "no pack tickets on sells");
        assertEq(boardRec.calls(), 0, "no leaderboard points on sells");
    }

    /// The hook is immutable: a faulting registry must cost only that trade's rewards — the swap and
    /// the fee must still succeed, or a registry bug would brick the protocol's only liquid pool.
    function test_registryRevertNeverBlocksTrading() public {
        _pastGate();
        packRec.setRevert(true);
        boardRec.setRevert(true);

        uint256 before = qpull.balanceOf(alice);
        // a registry LOGIC fault still fails soft (only out-of-gas reverts the buy); the event carries the credit
        vm.expectEmit(true, true, false, true, hookAddr);
        emit QpullTaxHook.RecordFailed("pack", alice, 1e21);
        vm.expectEmit(true, true, false, true, hookAddr);
        emit QpullTaxHook.RecordFailed("leaderboard", alice, 1e21);
        _swap(alice, _buyZeroForOne(), -1e21); // must NOT revert
        assertGt(qpull.balanceOf(alice) - before, 0, "trade delivered");
        assertEq(weth.balanceOf(feeSink), (uint256(1e21) * 400 + 9999) / 10_000, "fee still taken, in WETH");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee");
        assertEq(packRec.calls(), 0, "record dropped, not retried");
    }

    // ─── exemption: the Treasury's conversion path ───────────────────────────

    function test_adapterSwapsExemptFromFeeGateAndRecords() public {
        // convert() sells during the FIRST HOUR with a keeper EOA that holds no NFT — the exemption
        // must bypass fee, gate, and records entirely.
        adapter.setPoolKey(_ourKey());
        address sink = makeAddr("sink");
        qpull.mint(treasury, 1e21);
        vm.startPrank(treasury, treasury);
        qpull.approve(address(adapter), 1e21);
        uint256 out = adapter.swapExactIn(address(qpull), address(weth), 1e21, 1, sink);
        vm.stopPrank();

        assertGt(out, 0, "swap executed through the hooked pool");
        assertEq(weth.balanceOf(sink), out, "full output delivered - no 4% skim");
        assertEq(weth.balanceOf(feeSink), 0, "no fee");
        assertEq(qpull.balanceOf(feeSink), 0, "no fee");
        assertEq(packRec.calls(), 0, "no records for protocol conversions");
        assertEq(boardRec.calls(), 0, "no records for protocol conversions");
    }

    // ─── adapter poolKey binding ─────────────────────────────────────────────

    function test_adapterRejectsHooklessKey() public {
        PoolKey memory k = _ourKey();
        k.hooks = address(0);
        vm.expectRevert(QpullWethAdapter.BadPoolKey.selector);
        adapter.setPoolKey(k);
    }

    function test_adapterRejectsHookThatDoesNotExemptIt() public {
        // a canonical-shaped hook whose exemptSender is someone else — binding it would let the pool
        // skim every convert(); the self-referential check refuses.
        address hook3Addr = address(uint160((0xCC << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), makeAddr("other"))),
            hook3Addr
        );
        PoolKey memory k = _ourKey();
        k.hooks = hook3Addr;
        vm.expectRevert(QpullWethAdapter.BadPoolKey.selector);
        adapter.setPoolKey(k);
    }

    // ─── pool-init gate: mint must be closed first (MintStillOpen) ─────────────

    /// afterInitialize refuses to open the canonical pool until the NFT collection is launched()
    /// (finalizeLaunch). Asserts the TYPED MintStillOpen selector through v4-core's ERC-7751 wrapping,
    /// not a bare expectRevert().
    function test_MintStillOpen_poolInitRevertsUntilNftLaunched() public {
        address hAddr = address(uint160((0xEE << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hAddr
        );
        nft.setLaunched(false); // mint still open -> the pool cannot be created yet

        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hAddr);
        // sender == initializer (this) and the key is canonical, so afterInitialize reaches the launched() gate
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hAddr,
                IV4Hooks.afterInitialize.selector,
                abi.encodeWithSelector(QpullTaxHook.MintStillOpen.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _initializePool(k2, SQRT_1_1);
    }

    /// Once the mint is closed the same pool initializes cleanly (the gate is launch-only).
    function test_MintStillOpen_poolInitSucceedsOnceLaunched() public {
        address hAddr = address(uint160((0xEF << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hAddr
        );
        nft.setLaunched(true);
        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hAddr);
        _initializePool(k2, SQRT_1_1); // no revert
        assertEq(QpullTaxHook(hAddr).launchTime(), block.timestamp, "launchTime stamped on a launched pool");
    }

    /// Tightened twin of test_gate_blocksNonHolderBuysFirstHour: assert the TYPED Gated selector
    /// through v4-core's ERC-7751 wrapping (the swap dispatches afterSwap, which reverts Gated).
    function test_gate_blocksNonHolderBuysFirstHour_typedSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IV4Hooks.afterSwap.selector,
                abi.encodeWithSelector(QpullTaxHook.Gated.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(sniper, _buyZeroForOne(), -1e21);
    }

    // ─── real registries end-to-end ──────────────────────────────────────────

    /// One full-path check with the REAL registries (not mocks): swap -> hook -> tickets/points.
    function test_realRegistriesRecordThroughHook() public {
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        PackRegistry packs = new PackRegistry(address(oracle), 1e20, block.timestamp, 1 hours, address(this));
        LeaderboardRegistry board = new LeaderboardRegistry(block.timestamp, address(this));

        address hook4Addr = address(uint160((0xDD << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packs), address(board), address(adapter))),
            hook4Addr
        );
        packs.setRecorder(hook4Addr);
        board.setRecorder(hook4Addr);

        V4PoolKey memory k4 = key;
        k4.hooks = IV4Hooks(hook4Addr);
        _initializePool(k4, SQRT_1_1);
        _addLiquidity(k4, FULL_LO, FULL_HI, 1e24);
        vm.warp(block.timestamp + QpullTaxHook(hook4Addr).GATE_DURATION() + 1); // past the gate

        vm.prank(alice, alice);
        swapRouter.swap(
            k4,
            IV4PoolManager.SwapParams(
                _buyZeroForOne(), -1e21, _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertGt(packs.cohortSize(packs.today()), 0, "raffle tickets minted");
        assertGt(board.totalPoints(board.currentWeek()), 0, "leaderboard points accrued");
    }

    /// Spec section 4 WEB MIRROR. The site predicts a buy's packs as
    /// (bankedRemainder + G) / ticketPrice. Nothing ran that composed property end to end: credit == G was asserted
    /// in the hook suites and the banking arithmetic in PackRegistry.t.sol, separately. Here a buy of G = k *
    /// ticketPrice, k under maxTicketsPerBuy, goes through the REAL hook into the REAL PackRegistry with a non-zero
    /// banked remainder already on the buyer, twice: once with a sub-ticket remainder (from a dust tail) and once with
    /// a remainder worth more than a ticket (from a capped buy). This contract runs in both token orders
    /// (QpullTaxHookFlippedTest).
    function test_webMirror_bankedPlusExactMultiple_mintsExactly() public {
        uint256 tp = 1e20; // ticketPrice, WETH wei
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        PackRegistry packs = new PackRegistry(address(oracle), tp, block.timestamp, 1 hours, address(this));
        LeaderboardRegistry board = new LeaderboardRegistry(block.timestamp, address(this));
        address hAddr = address(uint160((0xDE << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packs), address(board), address(adapter))),
            hAddr
        );
        packs.setRecorder(hAddr);
        board.setRecorder(hAddr);
        V4PoolKey memory k5 = key;
        k5.hooks = IV4Hooks(hAddr);
        _initializePool(k5, SQRT_1_1);
        _addLiquidity(k5, FULL_LO, FULL_HI, 1e24);
        vm.warp(block.timestamp + QpullTaxHook(hAddr).GATE_DURATION() + 1); // past the gate: no throttle spacing

        // (a) sub-ticket banked remainder: 2 tickets + 37 wei banks 37 wei
        _exactInBuyOn(k5, 2 * tp + 37);
        _assertWebMirror(packs, board, k5, tp, 3);

        // (b) banked remainder above one ticket: a buy capped at 5 packs banks the rest (2 tickets + 11 wei on top of
        //     the 37 wei still banked from (a))
        packs.setMaxTicketsPerBuy(5);
        uint256 prior = packs.bankedRemainder(alice);
        _exactInBuyOn(k5, 7 * tp + 11);
        assertEq(packs.bankedRemainder(alice), prior + 2 * tp + 11, "the capped buy banked 2 tickets + 11 wei more");
        _assertWebMirror(packs, board, k5, tp, 2); // (2tp + 11 + 2tp) / tp = 4 packs, under the cap of 5
    }

    function _assertWebMirror(PackRegistry packs, LeaderboardRegistry board, V4PoolKey memory k, uint256 tp, uint256 kk)
        internal
    {
        uint256 banked = packs.bankedRemainder(alice);
        assertGt(banked, 0, "premise: a non-zero banked remainder");
        uint256 g = kk * tp;
        assertLe((banked + g) / tp, packs.maxTicketsPerBuy(), "premise: k under the cap");
        uint256 id0 = packs.nextPackId();
        uint256 pts0 = board.points(board.currentWeek(), alice);
        _exactInBuyOn(k, g);
        assertEq(board.points(board.currentWeek(), alice) - pts0, g, "credit == G (the leaderboard sees the same G)");
        assertEq(packs.nextPackId() - id0, (banked + g) / tp, "packs minted == (banked + G) / ticketPrice");
        assertEq(packs.bankedRemainder(alice), (banked + g) % tp, "banked after == (banked + G) % ticketPrice");
    }

    /// Kind A (exact-in buy) of `g` WETH by alice through pool `k`; alice spends exactly g.
    function _exactInBuyOn(V4PoolKey memory k, uint256 g) internal {
        uint256 w = weth.balanceOf(alice);
        vm.prank(alice, alice);
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(_buyZeroForOne(), -int256(g), _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(w - weth.balanceOf(alice), g, "exact-in buy spent exactly G");
    }

    /// Tick spacing bounds: v4 refuses to initialize a pool whose tickSpacing is
    /// outside [1, 32767], and this hook admits exactly one key, so an out-of-range value would make the canonical
    /// pool uncreatable forever. The constructor refuses it with the typed error; both bounds construct.
    function test_ctor_tickSpacingOutsideV4Range_refused() public {
        int24[3] memory bad = [int24(0), int24(-60), int24(32_768)];
        for (uint256 i; i < 3; ++i) {
            QpullTaxHook.HookConfig memory c = _cfg(address(packRec), address(boardRec), address(adapter));
            c.tickSpacing = bad[i];
            (bool ok, bytes memory ret) = _runHookInitCode(c, uint8(0x60 + i));
            assertFalse(ok, "an out-of-range tickSpacing must not deploy");
            assertEq(ret, abi.encodeWithSelector(QpullTaxHook.BadTickSpacing.selector), "typed BadTickSpacing");
        }
        int24[2] memory good = [int24(1), int24(32_767)];
        for (uint256 i; i < 2; ++i) {
            QpullTaxHook.HookConfig memory c = _cfg(address(packRec), address(boardRec), address(adapter));
            c.tickSpacing = good[i];
            (bool ok,) = _runHookInitCode(c, uint8(0x68 + i));
            assertTrue(ok, "both v4 bounds construct");
        }
    }

    /// deployCodeTo hides the constructor's revert data, so run the init code by hand (same as the zero-step test).
    function _runHookInitCode(QpullTaxHook.HookConfig memory c, uint8 tag) internal returns (bool ok, bytes memory ret) {
        address hAddr = address((uint160(tag) << 16) | FLAGS);
        vm.etch(hAddr, abi.encodePacked(vm.getCode("src/hooks/QpullTaxHook.sol:QpullTaxHook"), abi.encode(c)));
        (ok, ret) = hAddr.call("");
    }

    // ─── launch sell-tax schedule: shipped ladder unchanged + saturation at TAX_BPS ─────────────────

    /// The SHIPPED mainnet schedule (48h decay, 12h step) is exactly what it was before the saturating
    /// rewrite of afterSwap: 2000 / 1600 / 1200 / 800 bps at steps 0..3 (the last second of the window
    /// is still step 3), then the flat 400 once the window closes. Saturation never engages here.
    function test_sellSchedule_shippedMainnetLadderUnchanged() public {
        assertEq(hook.SELL_DECAY(), 48 hours, "mainnet decay");
        assertEq(hook.SELL_STEP(), 12 hours, "mainnet step");
        uint256 t0 = hook.launchTime();
        _assertSellTaxBps(key, 2000, "step 0: 20%");
        vm.warp(t0 + 12 hours);
        _assertSellTaxBps(key, 1600, "step 1: 16%");
        vm.warp(t0 + 24 hours);
        _assertSellTaxBps(key, 1200, "step 2: 12%");
        vm.warp(t0 + 36 hours);
        _assertSellTaxBps(key, 800, "step 3: 8%");
        vm.warp(t0 + 48 hours - 1);
        _assertSellTaxBps(key, 800, "last second of the window is still step 3: 8%");
        vm.warp(t0 + 48 hours);
        _assertSellTaxBps(key, 400, "window closed: flat 4%");
    }

    /// The SHIPPED testnet subclass (20m decay, 5m step; src/testnet/TestnetShortClock.sol) walks the same
    /// four rates: its max step is also 3, so the compressed ladder is unchanged too.
    function test_sellSchedule_shippedTestnetLadderUnchanged() public {
        (QpullTaxHook h, V4PoolKey memory k) =
            _openPoolWith("src/testnet/TestnetShortClock.sol:QpullTaxHookTestnet", 0x51);
        assertEq(h.SELL_DECAY(), 20 minutes, "testnet decay");
        assertEq(h.SELL_STEP(), 5 minutes, "testnet step");
        uint256 t0 = h.launchTime();
        _assertSellTaxBps(k, 2000, "step 0: 20%");
        vm.warp(t0 + 5 minutes);
        _assertSellTaxBps(k, 1600, "step 1: 16%");
        vm.warp(t0 + 10 minutes);
        _assertSellTaxBps(k, 1200, "step 2: 12%");
        vm.warp(t0 + 15 minutes);
        _assertSellTaxBps(k, 800, "step 3: 8%");
        vm.warp(t0 + 20 minutes - 1);
        _assertSellTaxBps(k, 800, "last second of the window is still step 3: 8%");
        vm.warp(t0 + 20 minutes);
        _assertSellTaxBps(k, 400, "window closed: flat 4%");
    }

    /// SATURATION. A subclass whose decay/step ratio pushes `step` past 3 (60m / 5m -> steps 0..11). With the
    /// pre-fix formula `SELL_TAX_START_BPS - step * SELL_STEP_BPS` step 5 was a 0% (free) sell and step 6+
    /// underflow-REVERTED, DoS-ing every sell in the window tail. The schedule now floors at TAX_BPS: the
    /// shipped part of the ladder is identical, and every later step clears at the flat 4%.
    function test_sellSchedule_saturatesAtTaxBpsForLargeStep() public {
        (QpullTaxHook h, V4PoolKey memory k) =
            _openPoolWith("test/QpullTaxHook.t.sol:LongDecaySellHook", 0x52);
        uint256 t0 = h.launchTime();
        _assertSellTaxBps(k, 2000, "step 0: 20%");
        vm.warp(t0 + 15 minutes);
        _assertSellTaxBps(k, 800, "step 3: 8% (shipped part of the ladder unchanged)");
        vm.warp(t0 + 20 minutes); // step 4: 2000 - 1600 = 400 exactly; subtraction and floor agree
        _assertSellTaxBps(k, 400, "step 4: floors at 4%");
        vm.warp(t0 + 25 minutes); // step 5: the old formula gave 0%
        _assertSellTaxBps(k, 400, "step 5: still 4%, never a free sell");
        vm.warp(t0 + 30 minutes); // step 6: the old formula underflow-reverted
        _assertSellTaxBps(k, 400, "step 6: sells still clear at 4%");
        vm.warp(t0 + 60 minutes - 1); // step 11: last second of the window
        _assertSellTaxBps(k, 400, "step 11: sells still clear at 4%");
        vm.warp(t0 + 60 minutes);
        _assertSellTaxBps(k, 400, "window closed: flat 4%");
    }

    /// Constructor invariant. A subclass with SELL_STEP() == 0 would divide by zero on every launch-window
    /// sell, a DoS the saturating schedule cannot absorb, so the constructor refuses it with the TYPED error.
    /// (The virtual getter is dispatched to the subclass even from the base constructor, which is what makes
    /// the check meaningful.)
    function test_sellSchedule_zeroStepRefusedAtDeploy() public {
        address hAddr = address(uint160((0x53 << 16) | FLAGS));
        // deployCodeTo hides the constructor's revert data behind its own require, so run the init code by
        // hand exactly the way it does: etch creationCode ++ args at the flag-carrying address and call it.
        vm.etch(
            hAddr,
            abi.encodePacked(
                vm.getCode("test/QpullTaxHook.t.sol:ZeroStepSellHook"),
                abi.encode(_cfg(address(packRec), address(boardRec), address(adapter)))
            )
        );
        (bool ok, bytes memory ret) = hAddr.call("");
        assertFalse(ok, "a zero SELL_STEP must not deploy");
        assertEq(ret, abi.encodeWithSelector(QpullTaxHook.BadSellSchedule.selector), "typed BadSellSchedule");
    }

    // ─── true-rate ladder: both exact-output kinds pay the TRUE rate at every launch-window step ─────

    /// Mainnet timing (48h decay, 12h step): steps 0 / 12 / 24 / 36 / 48h. Kind D pays 20/16/12/8/4% of gross
    /// (at step 0 that is 25% of the WETH received); kind B pays the flat 4% of gross at every step, including
    /// step 0, which is inside the 1h holder gate. fee / gross equals t to within 1 wei, both kinds.
    function test_exactOutputLadder_mainnetTiming() public {
        assertEq(hook.SELL_STEP(), 12 hours, "mainnet step");
        _fs14Ladder(hook, key);
    }

    /// The same ladder on QpullTaxHookTestnet timing (20m decay, 5m step): steps 0 / 5 / 10 / 15 / 20m, the
    /// first three inside its 15m holder gate.
    function test_exactOutputLadder_testnetTiming() public {
        (QpullTaxHook h, V4PoolKey memory k) =
            _openPoolWith("src/testnet/TestnetShortClock.sol:QpullTaxHookTestnet", 0x54);
        assertEq(h.SELL_STEP(), 5 minutes, "testnet step");
        _fs14Ladder(h, k);
    }

    function _fs14Ladder(QpullTaxHook h, V4PoolKey memory k) internal {
        uint256 step = h.SELL_STEP();
        assertEq(h.SELL_DECAY(), 4 * step, "four decay steps");
        uint256 t0 = h.launchTime();
        uint256[5] memory sellBps = [uint256(2000), 1600, 1200, 800, 400];
        for (uint256 i; i < 5; ++i) {
            vm.warp(t0 + i * step);
            assertEq(h.launchTime() + h.GATE_DURATION() > block.timestamp, i * step < h.GATE_DURATION(), "gate");
            _exactOutSellOn(k, 1e21, sellBps[i]);
            _exactOutSellOn(k, 7, sellBps[i]); // dust: fee rounds up to at least 1 wei
            _exactOutBuyOn(k, 1e21);
            vm.warp(block.timestamp + h.BUY_COOLDOWN()); // inside the gate the throttle spaces one wallet's buys
            _exactOutBuyOn(k, 3); // dust; still the same decay step
        }
    }

    /// Kind D on pool `k`: receives exactly N, fee == ceil(N*t/(1e4-t)), and t*(N+fee) <= fee*1e4 < t*(N+fee)+1e4.
    function _exactOutSellOn(V4PoolKey memory k, uint256 n, uint256 t) internal {
        bool zfo = !_buyZeroForOne();
        uint256 wBefore = weth.balanceOf(alice);
        uint256 sinkW = weth.balanceOf(feeSink);
        uint256 sinkQ = qpull.balanceOf(feeSink);
        uint256 calls = packRec.calls();
        vm.prank(alice, alice);
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(zfo, int256(n), zfo ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = weth.balanceOf(feeSink) - sinkW;
        assertEq(weth.balanceOf(alice) - wBefore, n, "D: seller receives exactly N");
        assertEq(fee, (n * t + (10_000 - t) - 1) / (10_000 - t), "D: fee == ceil(N*t/(1e4-t))");
        assertLe(t * (n + fee), fee * 10_000, "D: fee >= t of gross");
        assertLt(fee * 10_000, t * (n + fee) + 10_000, "D: fee < t of gross + 1 wei");
        assertEq(qpull.balanceOf(feeSink), sinkQ, "D: no QPULL fee");
        assertEq(packRec.calls(), calls, "D: sells record nothing");
    }

    /// Kind B on pool `k`: receives exactly Q, fee == ceil(P*400/9600), 400*paid <= fee*1e4 < 400*paid + 1e4,
    /// credit == paid.
    function _exactOutBuyOn(V4PoolKey memory k, uint256 q) internal {
        bool zfo = _buyZeroForOne();
        uint256 wBefore = weth.balanceOf(alice);
        uint256 qBefore = qpull.balanceOf(alice);
        uint256 sinkW = weth.balanceOf(feeSink);
        uint256 sinkQ = qpull.balanceOf(feeSink);
        vm.prank(alice, alice);
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(zfo, int256(q), zfo ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 paid = wBefore - weth.balanceOf(alice);
        uint256 fee = weth.balanceOf(feeSink) - sinkW;
        assertEq(qpull.balanceOf(alice) - qBefore, q, "B: exact output delivered");
        assertEq(fee, ((paid - fee) * 400 + 9599) / 9600, "B: fee == ceil(P*400/9600)");
        assertLe(400 * paid, fee * 10_000, "B: fee >= 4% of gross");
        assertLt(fee * 10_000, 400 * paid + 10_000, "B: fee < 4% of gross + 1 wei");
        assertEq(qpull.balanceOf(feeSink), sinkQ, "B: no QPULL fee");
        assertEq(packRec.lastGross(), paid, "B: credit == WETH paid");
    }

    // ─── price limits: a limit that is ALREADY reached ────────────────────────────────────────────

    /// A limit already reached reverts PriceLimitAlreadyExceeded inside Pool.swap (Pool.sol:322-336) before any
    /// fee is charged, for every kind, including an exact-in buy of G = 2 (amountToSwap = -1, not zero).
    function test_partialFill_limitAlreadyReachedRevertsBeforeAnyFee() public {
        _pastGate();
        bytes memory already = abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, SQRT_1_1, SQRT_1_1);
        bool buy = _buyZeroForOne();
        int256[5] memory amounts = [int256(-2), -1e21, 1e21, -1e21, 1e21]; // A(2), A, B, C, D
        bool[5] memory dirs = [buy, buy, buy, !buy, !buy];
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(already);
            _swapLimit(alice, dirs[i], amounts[i], SQRT_1_1);
        }
        assertEq(weth.balanceOf(feeSink), 0, "treasury WETH unchanged");
        assertEq(qpull.balanceOf(feeSink), 0, "treasury QPULL unchanged");
        assertEq(packRec.calls(), 0, "nothing credited");
    }

    /// The one exception: G = 1. Its whole spend is the 1-wei fee, amountToSwap is 0, and Pool.swap returns a
    /// zero delta (Pool.sol:320) BEFORE the limit check, so that swap pays 1 wei and is credited 1 wei.
    function test_partialFill_limitAlreadyReached_oneWeiBuyStillPaysAndCredits() public {
        _pastGate();
        uint256 wBefore = weth.balanceOf(alice);
        uint256 qBefore = qpull.balanceOf(alice);
        V4BalanceDelta d = _swapLimit(alice, _buyZeroForOne(), -1, SQRT_1_1);
        assertEq(weth.balanceOf(feeSink), 1, "pays 1 wei");
        assertEq(wBefore - weth.balanceOf(alice), 1, "spends exactly 1 wei");
        assertEq(qpull.balanceOf(alice), qBefore, "receives nothing");
        assertEq(qpullIs0 ? _a0(d) : _a1(d), 0, "zero QPULL delta");
        assertEq(packRec.calls(), 1, "credited once");
        assertEq(packRec.lastGross(), 1, "credit == 1 wei");
        _assertHookFlat();
    }

    // ─── bounds: int256.min, SwapTooLarge edges ───────────────────────────────────────────────────

    /// type(int256).min on an exact-in buy: the checked negation in _specifiedWethFee panics (0x11) inside
    /// beforeSwap, surfaced through v4's hook-error wrapper. Exact-out sells: 2**127 fails the first bound, and
    /// an N just under int128.max whose N + fee overflows int128 fails the second. The largest exact-in buy the
    /// first bound admits (|amountSpecified| == int128.max) is NOT refused by it.
    function test_bounds_int256MinPanicsAndBothSwapTooLargeBounds() public {
        _pastSellDecay();
        bytes memory tooLarge = abi.encodeWithSelector(QpullTaxHook.SwapTooLarge.selector);
        uint256 max = uint256(uint128(type(int128).max));

        vm.expectRevert(_wrapped(IV4Hooks.beforeSwap.selector, abi.encodeWithSignature("Panic(uint256)", 0x11)));
        _swap(alice, _buyZeroForOne(), type(int256).min);

        vm.expectRevert(_wrapped(IV4Hooks.beforeSwap.selector, tooLarge));
        _swap(alice, !_buyZeroForOne(), int256(uint256(1) << 127)); // amt > int128.max

        uint256 n = max - max / 50; // < int128.max, but the 4% gross-up (~n/24) pushes n + fee past it
        assertLe(n, max, "first bound passes");
        vm.expectRevert(_wrapped(IV4Hooks.beforeSwap.selector, tooLarge));
        _swap(alice, !_buyZeroForOne(), int256(n));

        // |amountSpecified| == int128.max passes both bounds; it fails later (the manager cannot fund the fee
        // take), never with SwapTooLarge.
        vm.prank(alice, alice);
        (bool ok, bytes memory ret) = address(swapRouter).call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    key,
                    IV4PoolManager.SwapParams(_buyZeroForOne(), -int256(max), _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1),
                    PoolSwapTest.TestSettings(false, false),
                    bytes("")
                )
            )
        );
        assertFalse(ok, "int128.max exact-in buy cannot be funded");
        assertTrue(keccak256(ret) != keccak256(_wrapped(IV4Hooks.beforeSwap.selector, tooLarge)), "not SwapTooLarge");
    }

    // ─── out-of-gas registries at depth 1 / 2 / 8, the depth-9 bound, the real PackRegistry ─────────────

    /// Depth 1, 2 and 8 under router.call{gas: X}: at EVERY X swept from 40k to 30M (x1.25 steps) the buy
    /// reverts; it is never a success that carries a RecordFailed log and credits nothing. Once X is large enough
    /// for the swap to reach the record at all, the revert is exactly RecordOutOfGas("pack") in the wrapped
    /// returndata, and it stays that for every larger X.
    function test_outOfGasRecordRevertsAtEveryGasLimit_depth1_2_8() public {
        _pastSellDecay();
        uint256[3] memory depths = [uint256(1), 2, 8];
        for (uint256 i; i < 3; ++i) {
            (, V4PoolKey memory k) = _openPoolWithRegistries(
                "src/hooks/QpullTaxHook.sol:QpullTaxHook", uint8(0x70 + i), _burnerChain(depths[i]), address(boardRec)
            );
            bytes memory typed = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(k.hooks),
                IV4Hooks.afterSwap.selector,
                abi.encodeWithSelector(QpullTaxHook.RecordOutOfGas.selector, bytes32("pack")),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            uint256 firstTyped;
            for (uint256 x = 40_000; x <= 30_000_000; x = (x * 5) / 4) {
                (bool ok, bytes memory ret) = _buyWithGas(k, -1e21, x);
                assertFalse(ok, "an out-of-gas record never lets the buy succeed");
                assertEq(weth.balanceOf(feeSink), 0, "no tax kept");
                bool isTyped = keccak256(ret) == keccak256(typed);
                if (isTyped && firstTyped == 0) firstTyped = x;
                if (firstTyped != 0) assertTrue(isTyped, "once the record is reached, always RecordOutOfGas");
            }
            assertGt(firstTyped, 0, "RecordOutOfGas surfaced");
            emit log_named_uint("depth", depths[i]);
            emit log_named_uint("  smallest swept gas limit returning RecordOutOfGas", firstTyped);
        }
        assertEq(boardRec.calls(), 0, "nothing credited anywhere");
    }

    /// THE BOUND. The registry path MUST stay at depth <= 8. EIP-150 hands this frame back at most
    /// g * (1 - (63/64)^d) of an out-of-gas chain: 11.8% at d = 8, under the 1/8 threshold, but 13.2% at d = 9,
    /// over it. So at depth 9 an out-of-gas record at a large gas limit is misread as a logic fault: the buy
    /// SUCCEEDS, emits RecordFailed("pack") and mints nothing. This test pins that behaviour so a registry change
    /// that deepens the call path cannot slip past the out-of-gas guard unnoticed. Today's deepest path is d = 2.
    function test_depth9_documentsTheBound() public {
        _pastSellDecay();
        (, V4PoolKey memory k) = _openPoolWithRegistries(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook", 0x79, _burnerChain(9), address(boardRec)
        );
        vm.recordLogs();
        (bool ok,) = _buyWithGas(k, -1e21, 30_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool softFailed;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter == address(k.hooks) && logs[j].topics[0] == QpullTaxHook.RecordFailed.selector) {
                softFailed = logs[j].topics[1] == bytes32("pack");
            }
        }
        assertTrue(ok, "depth 9 at 30M gas: the out-of-gas record soft-fails (the documented bound)");
        assertTrue(softFailed, "RecordFailed(pack) emitted");
        assertEq(boardRec.calls(), 1, "the leaderboard still records; only the pack credit is lost");
    }

    /// Real PackRegistry + LeaderboardRegistry at maxTicketsPerBuy 100 and 200. Find the smallest router gas limit
    /// at which the buy succeeds (doubling from 1M, then an exact binary search), then check both sides: every
    /// limit below it reverts (a 100-gas scan of the 500 gas just under it, plus 1M and 1/4, 1/2, 3/4 of it), every
    /// limit at or above it (a 100-gas scan of the 500 gas above it, plus 1.5x) mints the full n packs with no
    /// RecordFailed log. Monotone, with no soft-fail window. A failing probe burns its whole limit, so the two
    /// sizes are separate tests to stay inside forge's per-test gas budget.
    function test_realPackRegistry_gasBoundaryIsMonotone_max100() public {
        _realRegistryBoundary(100, 0x7A);
    }

    function test_realPackRegistry_gasBoundaryIsMonotone_max200() public {
        _realRegistryBoundary(200, 0x7B);
    }

    function _realRegistryBoundary(uint256 n, uint8 tag) internal {
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        PackRegistry packs = new PackRegistry(address(oracle), 1e18, block.timestamp, 1 hours, address(this));
        LeaderboardRegistry board = new LeaderboardRegistry(block.timestamp, address(this));
        packs.setMaxTicketsPerBuy(n); // G = 1e21 at 1e18 per ticket asks for 1000: capped at n
        (, V4PoolKey memory k) =
            _openPoolWithRegistries("src/hooks/QpullTaxHook.sol:QpullTaxHook", tag, address(packs), address(board));
        packs.setRecorder(address(k.hooks));
        board.setRecorder(address(k.hooks));
        _pastGate();

        uint256 hi = 1_000_000;
        while (!_probeRealBuy(k, packs, n, hi)) {
            hi *= 2;
            require(hi <= 64_000_000, "no success below 64M");
        }
        uint256 lo = hi / 2;
        assertFalse(_probeRealBuy(k, packs, n, lo), "bracket");
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_probeRealBuy(k, packs, n, mid)) hi = mid;
            else lo = mid;
        }
        uint256 boundary = hi;
        for (uint256 x = boundary - 500; x < boundary; x += 100) {
            assertFalse(_probeRealBuy(k, packs, n, x), "just below the boundary: reverts");
        }
        assertFalse(_probeRealBuy(k, packs, n, 1_000_000), "1M: reverts");
        for (uint256 q = 1; q < 4; ++q) {
            assertFalse(_probeRealBuy(k, packs, n, (boundary * q) / 4), "below the boundary: reverts");
        }
        for (uint256 x = boundary; x <= boundary + 500; x += 100) {
            assertTrue(_probeRealBuy(k, packs, n, x), "at/above the boundary: n packs minted");
        }
        assertTrue(_probeRealBuy(k, packs, n, (boundary * 3) / 2), "1.5x the boundary: n packs minted");
        emit log_named_uint("maxTicketsPerBuy", n);
        emit log_named_uint("  smallest succeeding router gas limit", boundary);
    }

    /// One buy at `gasLimit`, rolled back. On success it must have minted exactly n packs and emitted no
    /// RecordFailed: a success that dropped the credit is exactly what the out-of-gas guard prevents.
    function _probeRealBuy(V4PoolKey memory k, PackRegistry packs, uint256 n, uint256 gasLimit)
        internal
        returns (bool ok)
    {
        uint256 snap = vm.snapshotState();
        uint256 id0 = packs.nextPackId();
        vm.recordLogs();
        (ok,) = _buyWithGas(k, -1e21, gasLimit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) {
            assertEq(packs.nextPackId() - id0, n, "a successful buy mints the full n packs");
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(logs[j].topics[0] != QpullTaxHook.RecordFailed.selector, "no RecordFailed on success");
            }
        }
        vm.revertToState(snap);
    }

    /// Sells never call a registry: with out-of-gas burners installed as BOTH registries, a sell succeeds at the
    /// smallest gas limit that clears it, and that limit is the same as for the identical sell on the canonical
    /// mock-registry pool. A buy on the burner pool reverts even at 30M.
    function test_sellNeverCallsRegistry_minimalGas() public {
        (, V4PoolKey memory kb) = _openPoolWithRegistries(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook", 0x7C, _burnerChain(1), _burnerChain(1)
        );
        _pastSellDecay();
        // One identical committed sell on each pool first, so both searches start from the same pool state and
        // the same warm storage (the canonical pool was last touched in setUp).
        _sellWithGas(kb, 2_000_000);
        _sellWithGas(key, 2_000_000);
        uint256 minBurner = _minSellGas(kb);
        uint256 minCanonical = _minSellGas(key);
        emit log_named_uint("min sell gas, burner registries   ", minBurner);
        emit log_named_uint("min sell gas, mock registries     ", minCanonical);
        assertEq(minBurner, minCanonical, "a sell costs the same whatever the registries do: none is called");

        uint256 sink = weth.balanceOf(feeSink);
        (bool ok,) = _sellWithGas(kb, minBurner);
        assertTrue(ok, "sell at its minimal gas limit succeeds with burners installed");
        assertGt(weth.balanceOf(feeSink), sink, "and is taxed");
        (ok,) = _buyWithGas(kb, -1e21, 30_000_000);
        assertFalse(ok, "a buy on the same pool cannot succeed");
    }

    function _minSellGas(V4PoolKey memory k) internal returns (uint256 hi) {
        uint256 lo = 20_000;
        hi = 2_000_000;
        assertTrue(_sellProbe(k, hi), "2M gas sells");
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_sellProbe(k, mid)) hi = mid;
            else lo = mid;
        }
        assertFalse(_sellProbe(k, hi - 1), "one gas less fails");
    }

    function _sellProbe(V4PoolKey memory k, uint256 gasLimit) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        (ok,) = _sellWithGas(k, gasLimit);
        vm.revertToState(snap);
    }

    function _sellWithGas(V4PoolKey memory k, uint256 gasLimit) internal returns (bool ok, bytes memory ret) {
        bool zfo = !_buyZeroForOne();
        vm.prank(alice, alice);
        (ok, ret) = address(swapRouter).call{ gas: gasLimit }(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    k,
                    IV4PoolManager.SwapParams(zfo, -1e21, zfo ? MIN_PRICE_P1 : MAX_PRICE_M1),
                    PoolSwapTest.TestSettings(false, false),
                    bytes("")
                )
            )
        );
    }

    function _buyWithGas(V4PoolKey memory k, int256 amt, uint256 gasLimit) internal returns (bool ok, bytes memory ret) {
        bool zfo = _buyZeroForOne();
        vm.prank(alice, alice);
        (ok, ret) = address(swapRouter).call{ gas: gasLimit }(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    k,
                    IV4PoolManager.SwapParams(zfo, amt, zfo ? MIN_PRICE_P1 : MAX_PRICE_M1),
                    PoolSwapTest.TestSettings(false, false),
                    bytes("")
                )
            )
        );
    }

    /// A chain of `depth` GasBurnRecorders: the hook calls the head, each calls the next, the last burns all.
    function _burnerChain(uint256 depth) internal returns (address) {
        GasBurnRecorder b = new GasBurnRecorder(address(0));
        for (uint256 i = 1; i < depth; ++i) {
            b = new GasBurnRecorder(address(b));
        }
        return address(b);
    }
}

/// @dev Deliberately MIS-SET sell schedule (60m decay, 5m step -> steps 0..11). With the pre-fix formula
///      `SELL_TAX_START_BPS - step * SELL_STEP_BPS` this reached 0% at step 5 and underflow-reverted from
///      step 6 on. Exists only to prove the schedule saturates at TAX_BPS. NOT a deployable configuration.
contract LongDecaySellHook is QpullTaxHook {
    constructor(QpullTaxHook.HookConfig memory c) QpullTaxHook(c) { }

    function SELL_STEP() public pure override returns (uint256) {
        return 5 minutes;
    }

    function SELL_DECAY() public pure override returns (uint256) {
        return 60 minutes;
    }
}

/// @dev A zero step length: `(now - launchTime) / SELL_STEP()` would panic (division by zero) on every sell
///      inside the window. The constructor invariant must refuse it at deploy.
///      The zero is read from a never-written storage slot rather than written as a literal on purpose: a
///      constant 0 makes the base constructor's BadSellSchedule revert unconditional, and solc (via_ir) then
///      refuses to compile such a subclass at all, since its immutables would be "read from but never
///      assigned" (error 1284). That is an even stronger form of the guard (a literal-zero subclass cannot
///      even be built), but a storage read keeps this one compilable so the runtime revert is testable.
contract ZeroStepSellHook is QpullTaxHook {
    uint256 internal stepLen; // never written: stays 0

    constructor(QpullTaxHook.HookConfig memory c) QpullTaxHook(c) { }

    function SELL_STEP() public view override returns (uint256) {
        return stepLen;
    }
}

/// @dev Out-of-gas test double: a registry that runs OUT OF GAS. depth 1 burns every unit of gas it is given
///      (INVALID consumes the frame's whole allowance, exactly like an out-of-gas loop); a burner built on a
///      child calls it and bubbles its failure, which models an out-of-gas one frame further below the hook.
contract GasBurnRecorder is IPackRegistry, ILeaderboardRegistry {
    GasBurnRecorder public immutable child;

    /// child == 0: a depth-1 burner. Otherwise this frame calls `child` and bubbles its out-of-gas failure.
    constructor(address child_) {
        child = GasBurnRecorder(child_);
    }

    function recordBuy(address buyer, uint256 grossValue) external override(IPackRegistry, ILeaderboardRegistry) {
        if (address(child) != address(0)) {
            child.recordBuy(buyer, grossValue);
            return;
        }
        assembly {
            invalid()
        }
    }

    function recordXp(address, uint256) external pure override {
        assembly {
            invalid()
        }
    }
}

/// @dev Runs the entire hook suite with QPULL and WETH in the opposite address order.
contract QpullTaxHookFlippedTest is QpullTaxHookTest {
    function _flipTokenOrder() internal pure override returns (bool) {
        return true;
    }
}
