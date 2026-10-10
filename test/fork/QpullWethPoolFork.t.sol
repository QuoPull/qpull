// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullV4Quoter } from "../../src/periphery/QpullV4Quoter.sol";
import { QpullWethAdapter } from "../../src/adapters/QpullWethAdapter.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockNFT } from "../mocks/MockNFT.sol";
import { MockRecorder } from "../mocks/MockRecorder.sol";

// v4-core types for the swap-router test double (same ABI as our hand-written ones)
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback as IV4UnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

/// @notice Minimal V4 liquidity provider: initializes + seeds a QPULL/WETH pool on the real PoolManager
///         so the adapter has something to swap against. Settles both currencies inside unlock.
contract V4LiquidityHelper is IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;

    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    /// The hook's gates are `sender == initializer` with no tx.origin branch, so the
    /// address that creates the pool must be the same CONTRACT that provides its liquidity — which is
    /// exactly the production shape (QpullLiquidityLock does both, in one transaction).
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        pm.initialize(key, sqrtPriceX96);
    }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liq) external {
        pm.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liq))));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, int24 tl, int24 tu, int256 liq) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) =
            pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(tl, tu, liq, bytes32(0)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

/// @notice One swap on the REAL PoolManager, paid from this contract's own balances inside its own unlock.
///         Straight after `swap` (before this caller settles anything) it requires the hook's PoolManager
///         delta to be ZERO in both currencies: whichever callback carried the fee, the hook's take() and
///         the PoolManager's hook-delta accounting must already have netted out. The trader EOA
///         calls `swap` with tx.origin == itself, so the hook credits that EOA.
contract ForkSwapper is IV4UnlockCallback {
    using TransientStateLibrary for IV4PoolManager;

    IV4PoolManager public immutable pm;

    constructor(IV4PoolManager pm_) {
        pm = pm_;
    }

    function swap(V4PoolKey calldata key, IV4PoolManager.SwapParams calldata p) external {
        pm.unlock(abi.encode(key, p));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (V4PoolKey memory key, IV4PoolManager.SwapParams memory p) =
            abi.decode(data, (V4PoolKey, IV4PoolManager.SwapParams));
        pm.swap(key, p, "");
        address hook = address(key.hooks);
        require(pm.currencyDelta(hook, key.currency0) == 0, "hook currency0 delta not zero");
        require(pm.currencyDelta(hook, key.currency1) == 0, "hook currency1 delta not zero");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(V4Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            pm.sync(c);
            IERC20(V4Currency.unwrap(c)).transfer(address(pm), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}

/// @notice Forks Robinhood Chain and drives the LAUNCH SHAPE end-to-end on the REAL Uniswap-V4
///         PoolManager: canonical pool created WITH QpullTaxHook, adapter bound to it,
///         public swaps paying the tax, and the Treasury conversion path swapping fee-exempt.
/// @dev    The WETH-tax design moved the fee onto the SPECIFIED currency for exact-in buys and exact-out sells, which
///         only a beforeSwap delta can do. That needs flag bits 7 (BEFORE_SWAP) and 3 (BEFORE_SWAP_RETURNS_DELTA)
///         to be honoured by the PoolManager actually deployed on Robinhood, and nothing had ever shown that.
///         `test_fourKindsOnRealPoolManager_step0AndFlat` does: all four swap kinds through the 0x1ACC hook on
///         0x8366a3…40951, at the 20% launch sell rate and at the flat 4%, asserting the exact WETH fee, the
///         exact buyer spend / seller receipt, credit == WETH paid, zero QPULL fee and zero hook deltas.
///         `test_bindingLimitsOnRealPoolManager` shows the PartialFill fail-closed path (the check that would
///         also fire if that PoolManager ignored bits 7/3) raises the exact wrapped error there. Both run in
///         both token orders (the `_qpullIsCurrency0` variants), since v4's specified-currency mapping flips.
///         Read-only: the fork is discarded when the test ends; nothing is signed or broadcast. No env var is
///         required, the public RPC below is the default.
contract QpullWethPoolForkTest is Test {
    using StateLibrary for IV4PoolManager;
    using PoolIdLibrary for V4PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2**96 -> price 1:1
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 constant AMT = 100 ether; // per-kind trade size, against 20_000e18 full-range liquidity

    MockERC20 qpull;
    MockRecorder packRec;
    MockRecorder boardRec;
    QpullWethAdapter adapter;
    QpullTaxHook hook;
    address feeSink;
    address hookAddr;
    address c0;
    address c1;
    bool qpullIs0;
    PoolKey key; // our ABI twin, for the adapter + quoter
    V4PoolKey v4Key; // v4-core typed, for routers + state reads

    /// Deploys the launch shape on the fork and seeds the canonical pool. Returns with launchTime == now.
    /// `qpullBelowWeth` places the QPULL stand-in at an address below RH's WETH (0x0Bd7…), so QPULL is currency0;
    /// otherwise it lands wherever CREATE puts it (above WETH). v4's specified/unspecified mapping depends on the
    /// order, so the four-kind and limit tests run in both.
    function _launch(bool qpullBelowWeth) internal {
        vm.createSelectFork(RPC);
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        // "QPULL" stand-in: a plain ERC20, exactly what the real (stripped) QPULLToken is.
        if (qpullBelowWeth) {
            address low = address(uint160(0x0100000000000000000000000000000000000a11));
            deployCodeTo("test/mocks/MockERC20.sol:MockERC20", low);
            qpull = MockERC20(low);
        } else {
            qpull = new MockERC20();
        }
        MockNFT nft = new MockNFT();
        packRec = new MockRecorder();
        boardRec = new MockRecorder();
        feeSink = makeAddr("feeSink");

        // Production order: the LP contract and the adapter first, then the hook naming both (immutables).
        V4LiquidityHelper lp = new V4LiquidityHelper(pm);
        adapter = new QpullWethAdapter(POOL_MANAGER, address(qpull), WETH, address(this));
        hookAddr = address(uint160((0xF0 << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: POOL_MANAGER,
                    qpull: address(qpull),
                    weth: WETH,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: feeSink,
                    packRegistry: address(packRec),
                    leaderboardRegistry: address(boardRec),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: address(lp), // the LP contract, not a key (no EOA in the gate)
                    earlyBuyCapWei: type(uint256).max // throttle not under test here
                })
            ),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);
        assertEq(hook.REQUIRED_FLAGS(), 0x1ACC, "hook carries the design-D flags");

        // V4 requires currency0 < currency1.
        qpullIs0 = address(qpull) < WETH;
        assertEq(qpullIs0, qpullBelowWeth, "token order is what the test claims");
        (c0, c1) = qpullIs0 ? (address(qpull), WETH) : (WETH, address(qpull));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000, // 0.3% static
            tickSpacing: 60,
            hooks: hookAddr
        });
        v4Key = V4PoolKey(V4Currency.wrap(c0), V4Currency.wrap(c1), 3000, 60, IV4Hooks(hookAddr));
        lp.initializePool(key, SQRT_1_1); // sender = lp = initializer; stamps launchTime on the REAL chain
        assertEq(hook.launchTime(), block.timestamp, "launch stamped");

        // Seed deep, full-range liquidity from the SAME contract that created the pool. The gate is
        // `sender == initializer` now, with no tx.origin branch, so no prank can substitute for identity.
        vm.deal(address(this), 60_000 ether);
        IWETHDeposit(WETH).deposit{ value: 60_000 ether }();
        IERC20(WETH).transfer(address(lp), 60_000 ether);
        qpull.mint(address(lp), 200_000 ether);
        lp.addLiquidity(key, -887_220, 887_220, uint128(20_000 ether)); // full range (multiples of 60)
    }

    function test_createHookedPoolAndSwapThroughAdapter() public {
        _launch(false);
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        // Bind the adapter — setPoolKey verifies the hook exempts it, on-chain.
        adapter.setPoolKey(key);
        adapter.setTreasury(address(this)); // this test acts as the Treasury caller

        // 1. The Treasury conversion path: QPULL -> WETH through the HOOKED pool, fee-exempt.
        address dest = makeAddr("dest");
        uint256 amountIn = 500 ether;
        qpull.mint(address(this), amountIn);
        IERC20(qpull).approve(address(adapter), amountIn);
        // ── QpullV4Quoter: does the quote the keeper will rely on match what the pool actually pays? ──
        // Quote FIRST (the quoter reverts internally, so it cannot move the price), then swap from the same
        // state and compare.
        //
        // The quoter is NOT the fee-exempt adapter, so its swap is TAXED while the adapter's is not. That is
        // not a flaw to correct here -- it is precisely why keeper.js grosses the quote up
        // (grossUpForExemptSell). At launch `step == 0`, so the sell tax sits at its start value of 20%, and the
        // gross-up must reproduce the adapter's real output exactly. An exact-in sell is swap kind C, whose
        // floor fee the WETH-tax design left byte-for-byte unchanged, so the gross-up is still exact.
        QpullV4Quoter quoter = new QpullV4Quoter(pm);
        bool q0for1 = Currency.unwrap(key.currency0) == address(qpull);
        (uint256 quoted, uint256 gasEst) = quoter.quoteExactInputSingle(key, q0for1, uint128(amountIn), "");
        emit log_named_uint("quoted WETH out (taxed, 20% at launch)", quoted);
        emit log_named_uint("quote gas", gasEst);
        assertGt(quoted, 0, "quoter returned a live quote from the real v4 pool");

        uint256 out = adapter.swapExactIn(address(qpull), WETH, amountIn, 1, dest);

        assertLt(quoted, out, "the quoter path is taxed, so it must quote BELOW the exempt adapter's output");
        uint256 grossedUp = (quoted * 10_000) / (10_000 - 2000); // keeper.js grossUpForExemptSell at 20%
        assertApproxEqRel(grossedUp, out, 1e15, "grossed-up quote must reproduce the exempt output (0.1%)");

        emit log_named_uint("WETH out for 500 QPULL (exempt)", out);
        assertGt(out, 0, "received WETH through the real V4 pool");
        assertEq(IERC20(WETH).balanceOf(dest), out, "delivered in full - no fee on the exempt path");
        assertEq(IERC20(WETH).balanceOf(feeSink), 0, "no fee for the conversion swap");
        assertEq(packRec.calls(), 0, "no records for the conversion swap");

        // 2. A PUBLIC exact-in buy through the v4-core router: pays the 4% to the treasury, in WETH.
        _publicTaxedBuy();
    }

    /// Swap kind A (exact-in buy) through PoolSwapTest (a real third-party router shape): the buyer spends exactly G of WETH,
    /// the treasury receives ceil(G * 400 / 1e4) WETH and no QPULL, and both registries credit the signer G.
    function _publicTaxedBuy() internal {
        vm.warp(vm.getBlockTimestamp() + hook.GATE_DURATION() + 1); // past the 1-hour gate
        PoolSwapTest router = new PoolSwapTest(IV4PoolManager(POOL_MANAGER));
        address buyer = makeAddr("buyer");
        uint256 g = AMT;
        vm.deal(buyer, g);
        vm.startPrank(buyer, buyer);
        IWETHDeposit(WETH).deposit{ value: g }();
        IERC20(WETH).approve(address(router), type(uint256).max);
        bool buyZeroForOne = c0 == WETH; // WETH in, QPULL out
        uint256 sinkW = IERC20(WETH).balanceOf(feeSink);
        uint256 sinkQ = qpull.balanceOf(feeSink);
        router.swap(
            v4Key,
            IV4PoolManager.SwapParams(buyZeroForOne, -int256(g), buyZeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        uint256 fee = IERC20(WETH).balanceOf(feeSink) - sinkW;
        uint256 got = qpull.balanceOf(buyer);
        emit log_named_uint("buyer QPULL out (taxed)", got);
        emit log_named_uint("treasury WETH fee", fee);
        assertEq(IERC20(WETH).balanceOf(buyer), 0, "buyer spent exactly G of WETH");
        assertGt(got, 0, "buyer received QPULL");
        assertEq(fee, (g * 400 + 9999) / 10_000, "treasury WETH fee == ceil(G * 400 / 1e4)");
        assertEq(qpull.balanceOf(feeSink) - sinkQ, 0, "treasury receives no QPULL");
        assertEq(packRec.lastTrader(), buyer, "pack registry credited to the signer");
        assertEq(packRec.lastGross(), g, "pack credit == G");
        assertEq(boardRec.lastTrader(), buyer, "leaderboard credited to the signer");
        assertEq(boardRec.lastGross(), g, "leaderboard credit == G");
        _assertHookHoldsNothing();
    }

    /// All four swap kinds on Robinhood's deployed PoolManager, at the 20% launch sell rate (step 0, just
    /// past the 1-hour gate) and at the flat 4% (past the 48h decay). The first on-chain-code evidence that bits
    /// 7 and 3 are honoured there.
    function test_fourKindsOnRealPoolManager_step0AndFlat() public {
        _fourKindsLadder(false);
    }

    function test_fourKindsOnRealPoolManager_step0AndFlat_qpullIsCurrency0() public {
        _fourKindsLadder(true);
    }

    function _fourKindsLadder(bool qpullBelowWeth) internal {
        _launch(qpullBelowWeth);
        uint256 t0 = hook.launchTime();
        (ForkSwapper sw, address trader) = _swapper();

        vm.warp(t0 + hook.GATE_DURATION() + 1); // gate closed, sell schedule still at step 0
        assertLt(vm.getBlockTimestamp(), t0 + hook.SELL_STEP(), "still sell step 0");
        _fourKinds(sw, trader, 2000);

        vm.warp(t0 + hook.SELL_DECAY() + 1);
        _fourKinds(sw, trader, 400);
    }

    /// PartialFill on the real PoolManager: kinds A and D with a binding sqrtPriceLimit revert with exactly the
    /// wrapped PartialFill (never an overcharge on a partial fill), and kinds B and C with a binding limit fill
    /// partially and are taxed on the actual fill.
    function test_bindingLimitsOnRealPoolManager() public {
        _bindingLimits(false);
    }

    function test_bindingLimitsOnRealPoolManager_qpullIsCurrency0() public {
        _bindingLimits(true);
    }

    function _bindingLimits(bool qpullBelowWeth) internal {
        _launch(qpullBelowWeth);
        (ForkSwapper sw, address trader) = _swapper();
        vm.warp(hook.launchTime() + hook.SELL_DECAY() + 1); // flat 4% for C's formula below
        bool buyZfo = c0 == WETH;
        bytes memory partialFill = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hookAddr,
            IV4Hooks.afterSwap.selector,
            abi.encodeWithSelector(QpullTaxHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        uint256 sinkW = IERC20(WETH).balanceOf(feeSink);
        // read the limits BEFORE expectRevert: the slot0 read is itself an external call
        uint160 buyLimit = _bindingLimit(buyZfo);
        uint160 sellLimit = _bindingLimit(!buyZfo);

        vm.expectRevert(partialFill);
        _swap(sw, trader, buyZfo, -int256(AMT), buyLimit); // A
        vm.expectRevert(partialFill);
        _swap(sw, trader, !buyZfo, int256(AMT), sellLimit); // D
        assertEq(IERC20(WETH).balanceOf(feeSink), sinkW, "reverted A/D charged nothing");
        assertEq(packRec.calls(), 0, "reverted A credited nothing");

        // B: exact-out buy stops at the limit, taxed on what actually filled
        S memory b = _snap(sw);
        _swap(sw, trader, buyZfo, int256(AMT), _bindingLimit(buyZfo));
        S memory a = _snap(sw);
        uint256 paid = b.w - a.w;
        uint256 fee = a.sinkW - b.sinkW;
        assertLt(a.q - b.q, AMT, "B: partial fill");
        assertGt(a.q - b.q, 0, "B: something filled");
        assertEq(fee, ((paid - fee) * 400 + 9599) / 9600, "B: ceil fee on the actual fill");
        assertEq(a.credit - b.credit, paid, "B: credit == WETH actually paid");

        // C: exact-in sell stops at the limit, floor fee on the actual fill
        b = _snap(sw);
        _swap(sw, trader, !buyZfo, -int256(AMT), _bindingLimit(!buyZfo));
        a = _snap(sw);
        fee = a.sinkW - b.sinkW;
        uint256 out = a.w - b.w;
        assertLt(b.q - a.q, AMT, "C: partial fill");
        assertEq(fee, ((out + fee) * 400) / 10_000, "C: floor fee on the actual fill");
        assertEq(a.credit, b.credit, "C: sells credit nothing");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee, ever");
        _assertHookHoldsNothing();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    struct S {
        uint256 w; // swapper WETH
        uint256 q; // swapper QPULL
        uint256 sinkW;
        uint256 sinkQ;
        uint256 credit; // pack registry totalGross
    }

    function _snap(ForkSwapper sw) internal view returns (S memory s) {
        s = S(
            IERC20(WETH).balanceOf(address(sw)),
            qpull.balanceOf(address(sw)),
            IERC20(WETH).balanceOf(feeSink),
            qpull.balanceOf(feeSink),
            packRec.totalGross()
        );
    }

    function _swapper() internal returns (ForkSwapper sw, address trader) {
        trader = makeAddr("trader");
        sw = new ForkSwapper(IV4PoolManager(POOL_MANAGER));
        vm.deal(address(this), 2_000 ether);
        IWETHDeposit(WETH).deposit{ value: 2_000 ether }();
        IERC20(WETH).transfer(address(sw), 2_000 ether);
        qpull.mint(address(sw), 2_000 ether);
    }

    function _swap(ForkSwapper sw, address trader, bool zfo, int256 amountSpecified, uint160 limit) internal {
        vm.prank(trader, trader); // tx.origin == trader: the identity the hook credits
        sw.swap(v4Key, IV4PoolManager.SwapParams(zfo, amountSpecified, limit));
    }

    function _sentinel(bool zfo) internal pure returns (uint160) {
        return zfo ? MIN_PRICE_P1 : MAX_PRICE_M1;
    }

    /// 0.01% past the pool's CURRENT price in the swap's direction: binds for a 100e18 swap on 20_000e18 liquidity.
    function _bindingLimit(bool zfo) internal view returns (uint160) {
        (uint160 sqrtP,,,) = IV4PoolManager(POOL_MANAGER).getSlot0(v4Key.toId());
        return zfo ? sqrtP - sqrtP / 10_000 : sqrtP + sqrtP / 10_000;
    }

    function _fourKinds(ForkSwapper sw, address trader, uint256 t) internal {
        bool buyZfo = c0 == WETH;
        uint256 creditCalls = packRec.calls();

        // A. exact-in buy: spend exactly G, fee ceil(G * 4%) WETH, credit G
        S memory b = _snap(sw);
        _swap(sw, trader, buyZfo, -int256(AMT), _sentinel(buyZfo));
        S memory a = _snap(sw);
        assertEq(b.w - a.w, AMT, "A: spend == G");
        assertGt(a.q - b.q, 0, "A: QPULL received");
        assertEq(a.sinkW - b.sinkW, (AMT * 400 + 9999) / 10_000, "A: fee == ceil(G * 400 / 1e4)");
        assertEq(a.sinkQ, b.sinkQ, "A: no QPULL fee");
        assertEq(a.credit - b.credit, AMT, "A: credit == G");
        assertEq(packRec.lastTrader(), trader, "A: credited to the signer");

        // B. exact-out buy: receive exactly Q, fee ceil(P * 400 / 9600), credit == WETH paid
        b = _snap(sw);
        _swap(sw, trader, buyZfo, int256(AMT), _sentinel(buyZfo));
        a = _snap(sw);
        uint256 paid = b.w - a.w;
        uint256 fee = a.sinkW - b.sinkW;
        assertEq(a.q - b.q, AMT, "B: QPULL received == Q");
        assertEq(fee, ((paid - fee) * 400 + 9599) / 9600, "B: fee == ceil(P * 400 / 9600)");
        assertGe(fee * 10_000, 400 * paid, "B: fee >= 4% of what the buyer paid");
        assertEq(a.sinkQ, b.sinkQ, "B: no QPULL fee");
        assertEq(a.credit - b.credit, paid, "B: credit == WETH paid");

        // C. exact-in sell: spend exactly the QPULL, fee floor(G * t / 1e4) of the pool's WETH output, no credit
        b = _snap(sw);
        _swap(sw, trader, !buyZfo, -int256(AMT), _sentinel(!buyZfo));
        a = _snap(sw);
        fee = a.sinkW - b.sinkW;
        uint256 out = a.w - b.w;
        assertEq(b.q - a.q, AMT, "C: QPULL sold == amount");
        assertEq(fee, ((out + fee) * t) / 10_000, "C: fee == floor(G * t / 1e4)");
        assertEq(a.sinkQ, b.sinkQ, "C: no QPULL fee");
        assertEq(a.credit, b.credit, "C: no credit");

        // D. exact-out sell: receive exactly N, fee ceil(N * t / (1e4 - t)), no credit
        b = _snap(sw);
        _swap(sw, trader, !buyZfo, int256(AMT), _sentinel(!buyZfo));
        a = _snap(sw);
        fee = a.sinkW - b.sinkW;
        assertEq(a.w - b.w, AMT, "D: WETH received == N");
        assertGt(b.q - a.q, 0, "D: QPULL paid");
        assertEq(fee, (AMT * t + (10_000 - t) - 1) / (10_000 - t), "D: fee == ceil(N * t / (1e4 - t))");
        assertLe(t * (AMT + fee), fee * 10_000, "D: fee >= t of gross");
        assertEq(a.sinkQ, b.sinkQ, "D: no QPULL fee");
        assertEq(a.credit, b.credit, "D: no credit");

        assertEq(packRec.calls(), creditCalls + 2, "exactly the two buys were credited");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL ever reaches the treasury");
        _assertHookHoldsNothing();
        emit log_named_uint("four kinds verified on the RH PoolManager at sell bps", t);
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(IERC20(WETH).balanceOf(hookAddr), 0, "hook holds no WETH");
        assertEq(qpull.balanceOf(hookAddr), 0, "hook holds no QPULL");
    }
}
