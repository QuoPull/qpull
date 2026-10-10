// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

// Real vendored Uniswap v4 core (tag v4.0.0) — fuzz against actual PoolManager semantics, not a mock.
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { V4LpBase } from "./utils/V4LpBase.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice Shared launch-shape setUp: canonical QPULL/WETH pool created WITH QpullTaxHook on the REAL
///         PoolManager, deep liquidity seeded, gate warped past. Reused by the fuzz and invariant suites.
abstract contract HookFuzzBase is Test, V4LpBase {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // add+remove LP gate (0x1ACC)
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220;
    int24 constant FULL_HI = 887_220;
    uint256 constant TAX_BPS = 400;
    uint256 constant BPS = 10_000;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder rec; // pack registry
    MockRecorder board; // leaderboard registry (separate, so rec.totalGross() is exactly the credit sum)
    QpullTaxHook hook;
    QpullWethAdapter adapter;
    address hookAddr = address(uint160((0xADD << 16) | FLAGS));
    address feeSink = makeAddr("feeSink"); // the hook's treasury (fee recipient)
    bool qpullIs0;
    V4PoolKey key;

    function _baseSetUp() internal {
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager))); // this contract IS the hook's initializer, so it is the LP
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        if (_flipTokenOrder()) (qpull, weth) = (weth, qpull);
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        rec = new MockRecorder();
        board = new MockRecorder();

        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(address(this));

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: address(manager),
            qpull: address(qpull),
            weth: address(weth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            treasury: feeSink,
            packRegistry: address(rec),
            leaderboardRegistry: address(board),
            nft: address(nft),
            exemptSender: address(adapter),
            initializer: address(this),
            // throttle not under test here: an uncapped first-hour buy size keeps this fixture's
            // pre-existing swap sizes valid (the fixture warps past the gate window anyway)
            earlyBuyCapWei: type(uint256).max
        });
        deployCodeTo("src/hooks/QpullTaxHook.sol:QpullTaxHook", abi.encode(hc), hookAddr);
        hook = QpullTaxHook(hookAddr);

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });

        qpull.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);

        _initializePool(key, SQRT_1_1);
        _addLiquidity(key, FULL_LO, FULL_HI, 1e24);
        // Past BOTH the first-hour gate (fuzz actors need not hold an NFT) AND the 48h sell-tax decay
        // window, so sells settle at the flat 4% floor and the 4%-of-gross assertions hold on both sides.
        vm.warp(block.timestamp + hook.SELL_DECAY() + 1);
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0; // buy = QPULL flows out to the swapper
    }

    /// Overridden to true by QpullTaxHookInvariantFlippedTest: v4's specified/unspecified mapping depends on it.
    function _flipTokenOrder() internal pure virtual returns (bool) {
        return false;
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

/// @notice Stateless fuzz: the 4% fee is exact across the full input space, the exempt path never pays,
///         swaps always settle, and a round trip never profits.
contract QpullTaxHookFuzzTest is HookFuzzBase {
    address trader = makeAddr("trader");

    function setUp() public {
        _baseSetUp();
        qpull.mint(trader, 1e30);
        weth.mint(trader, 1e30);
        vm.startPrank(trader);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (V4BalanceDelta) {
        vm.prank(trader, trader);
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// An exact-input buy is taxed ceil(4%) of the WETH spent, in WETH; no QPULL fee, spend == amountIn.
    function testFuzz_buyExactIn_feeIsExactly4Percent(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22); // dust..big, within the 1e24-liquidity pool
        uint256 wBefore = weth.balanceOf(trader);
        _swap(_buyZeroForOne(), -int256(amountIn));
        assertEq(wBefore - weth.balanceOf(trader), amountIn, "spend == amountIn");
        assertEq(weth.balanceOf(feeSink), (amountIn * TAX_BPS + BPS - 1) / BPS, "fee != ceil(4% of WETH spent)");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee on a buy");
    }

    /// The output on an exact-input sell is taxed exactly 4% of the pool's pre-fee WETH output.
    function testFuzz_sellExactIn_feeIsExactly4Percent(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        uint256 wBefore = weth.balanceOf(trader);
        _swap(!_buyZeroForOne(), -int256(amountIn));
        uint256 received = weth.balanceOf(trader) - wBefore;
        uint256 fee = weth.balanceOf(feeSink);
        uint256 gross = received + fee;
        assertEq(fee, (gross * TAX_BPS) / BPS, "fee != 4% of gross WETH output");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee on an exact-in sell");
    }

    /// Exact-output buy: the WETH input is taxed exactly 4% of the pool's pre-fee WETH input (paid on top).
    function testFuzz_buyExactOut_feeIsExactly4Percent(uint256 wantOut) public {
        wantOut = bound(wantOut, 1e12, 1e22);
        uint256 wBefore = weth.balanceOf(trader);
        _swap(_buyZeroForOne(), int256(wantOut));
        uint256 paid = wBefore - weth.balanceOf(trader);
        uint256 fee = weth.balanceOf(feeSink);
        uint256 poolInput = paid - fee; // the unspecified input the pool actually consumed
        // grossed up so the fee is >= 4% of what the buyer pays
        assertEq(fee, (poolInput * TAX_BPS + (BPS - TAX_BPS) - 1) / (BPS - TAX_BPS), "fee != ceil(P*4%/96%)");
        assertGe(fee * BPS, TAX_BPS * paid, "fee >= 4% of WETH paid");
    }

    /// Any fuzzed swap through the hooked pool SETTLES — the take()+returned-delta never leaves an
    /// unsettled balance (no CurrencyNotSettled). If it reverted, this test would fail.
    function testFuzz_swapAlwaysSettles(uint256 amountIn, bool zeroForOne, bool exactIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        int256 spec = exactIn ? -int256(amountIn) : int256(bound(amountIn, 1e12, 1e22));
        _swap(zeroForOne, spec);
        // reaching here means the unlock settled cleanly for an arbitrary swap shape
        assertTrue(true);
    }

    /// A buy-then-sell round trip can NEVER return more than was put in — no value is created from the
    /// accounting alone (it loses the 4% x2, the LP fee x2, and slippage).
    function testFuzz_roundTripNeverProfits(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1e22);
        uint256 wStart = weth.balanceOf(trader);

        // buy: spend `amountIn` WETH for QPULL
        uint256 qBefore = qpull.balanceOf(trader);
        _swap(_buyZeroForOne(), -int256(amountIn));
        uint256 qGot = qpull.balanceOf(trader) - qBefore;

        // sell all the QPULL received back for WETH
        _swap(!_buyZeroForOne(), -int256(qGot));

        assertLe(weth.balanceOf(trader), wStart, "round trip created value from accounting");
    }

    /// The exempt conversion path (the Treasury's adapter) pays ZERO fee for any fuzzed size.
    function testFuzz_exemptSenderNeverPaysFee(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        adapter.setPoolKey(_ourKey());
        address sink = makeAddr("sink");
        qpull.mint(address(this), amountIn);
        qpull.approve(address(adapter), amountIn);
        uint256 out = adapter.swapExactIn(address(qpull), address(weth), amountIn, 1, sink);
        assertGt(out, 0, "exempt swap executed");
        assertEq(weth.balanceOf(sink), out, "full output delivered, no skim");
        assertEq(weth.balanceOf(feeSink), 0, "exempt path pays no fee");
        assertEq(qpull.balanceOf(feeSink), 0, "exempt path pays no fee");
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
}

/// @notice WETH-tax stateful handler. Four swap handlers, one per kind (A exact-in buy, B exact-out buy, C exact-in
///         sell, D exact-out sell), each with a random size (dust included) and a random price limit (MIN/MAX
///         sentinel, or binding: 0.01% past the CURRENT price), plus the exempt adapter and a warp/roll handler
///         that walks the clock through the 20/16/12/8 -> 4% sell-decay steps. Every swap is checked against its
///         kind's exact fee formula; the only accepted revert is PartialFill on A or D with a binding limit.
/// @dev    Ghosts: sumCredit (recorded buy credit), sumBuyFeeWeth, sumFeeWeth (all kinds).
contract HookInvariantHandler is Test {
    using StateLibrary for IV4PoolManager;
    using TransientStateLibrary for IV4PoolManager;
    using PoolIdLibrary for V4PoolKey;

    IV4PoolManager pm;
    PoolSwapTest swapRouter;
    QpullTaxHook hook;
    QpullWethAdapter adapter;
    MockRecorder rec;
    MockERC20 qpull;
    MockERC20 weth;
    address feeSink;
    address adapterCaller;
    V4PoolKey key;
    bool qpullIs0;

    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 constant TAX_BPS = 400;
    uint256 constant BPS = 10_000;

    // ghosts
    uint256 public sumCredit;
    uint256 public sumBuyFeeWeth;
    uint256 public sumFeeWeth;
    // failure counters (the invariants require all of them to stay 0)
    uint256 public formulaMismatches;
    uint256 public unexpectedReverts;
    uint256 public hookLeaks; // hook held a token or an open delta after a swap
    uint256 public exemptLeaks; // an exempt swap moved the treasury or the recorder
    bytes public lastUnexpected;
    // coverage
    uint256[4] public filled; // successful swaps per kind
    uint256 public partialFills;
    uint256 public exemptSwaps;
    uint256 public warps;
    uint256 public maxSellBpsSeen;
    uint256 public minSellBpsSeen = type(uint256).max;

    struct Pre {
        uint256 w;
        uint256 q;
        uint256 sinkW;
        uint256 sinkQ;
        uint256 gross;
    }

    constructor(
        IV4PoolManager pm_,
        PoolSwapTest swapRouter_,
        QpullTaxHook hook_,
        QpullWethAdapter adapter_,
        MockRecorder rec_,
        MockERC20 qpull_,
        MockERC20 weth_,
        address feeSink_,
        address adapterCaller_,
        V4PoolKey memory key_,
        bool qpullIs0_
    ) {
        pm = pm_;
        swapRouter = swapRouter_;
        hook = hook_;
        adapter = adapter_;
        rec = rec_;
        qpull = qpull_;
        weth = weth_;
        feeSink = feeSink_;
        adapterCaller = adapterCaller_;
        key = key_;
        qpullIs0 = qpullIs0_;
        qpull.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
    }

    function exactInBuy(uint256 amount, bool binding) external {
        _swapKind(0, bound(amount, 1, 2e22), binding);
    }

    function exactOutBuy(uint256 amount, bool binding) external {
        _swapKind(1, bound(amount, 1, 2e22), binding);
    }

    function exactInSell(uint256 amount, bool binding) external {
        _swapKind(2, bound(amount, 1, 2e22), binding);
    }

    function exactOutSell(uint256 amount, bool binding) external {
        _swapKind(3, bound(amount, 1, 2e22), binding);
    }

    /// The Treasury's conversion path: untaxed, unrecorded, whatever the clock says.
    function exemptSell(uint256 amount) external {
        amount = bound(amount, 1e12, 2e22);
        uint256 sinkW = weth.balanceOf(feeSink);
        uint256 sinkQ = qpull.balanceOf(feeSink);
        uint256 gross = rec.totalGross();
        vm.prank(adapterCaller);
        try adapter.swapExactIn(address(qpull), address(weth), amount, 1, adapterCaller) {
            ++exemptSwaps;
            if (weth.balanceOf(feeSink) != sinkW || qpull.balanceOf(feeSink) != sinkQ || rec.totalGross() != gross) {
                ++exemptLeaks;
            }
        } catch (bytes memory err) {
            ++unexpectedReverts;
            lastUnexpected = err;
        }
        _checkHookFlat();
    }

    /// Walk the clock (and the block) forward, up to two hours at a time: ~80 warps per 500-call run carry the
    /// clock from sell step 0 through steps 1-3 and into the flat 4%.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 hours));
        vm.roll(block.number + 1);
        ++warps;
    }

    function _swapKind(uint8 kind, uint256 amt, bool binding) internal {
        bool buy = kind < 2;
        bool exactIn = kind == 0 || kind == 2;
        bool zfo = buy ? !qpullIs0 : qpullIs0;
        uint160 limit = zfo ? MIN_PRICE_P1 : MAX_PRICE_M1;
        if (binding) {
            (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
            uint160 step = sqrtP / 10_000;
            limit = zfo ? sqrtP - step : sqrtP + step;
        }
        uint256 t = _sellBps();
        Pre memory p = Pre(
            weth.balanceOf(address(this)),
            qpull.balanceOf(address(this)),
            weth.balanceOf(feeSink),
            qpull.balanceOf(feeSink),
            rec.totalGross()
        );
        try swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zfo, exactIn ? -int256(amt) : int256(amt), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            _afterSwap(kind, amt, binding, t, p);
        } catch (bytes memory err) {
            bool allowed = (kind == 0 || kind == 3) && binding
                && keccak256(err) == keccak256(_wrappedPartialFill());
            if (allowed) {
                ++partialFills;
            } else {
                ++unexpectedReverts;
                lastUnexpected = err;
            }
        }
        _checkHookFlat();
    }

    function _afterSwap(uint8 kind, uint256 amt, bool binding, uint256 t, Pre memory p) internal {
        ++filled[kind];
        uint256 fee = weth.balanceOf(feeSink) - p.sinkW;
        uint256 credit = rec.totalGross() - p.gross;
        sumFeeWeth += fee;
        bool ok = qpull.balanceOf(feeSink) == p.sinkQ; // no QPULL fee, on every kind
        if (kind == 0) {
            // A: spend == G exactly, fee == ceil(G * 4%), credit == G
            ok = ok && p.w - weth.balanceOf(address(this)) == amt && fee == (amt * TAX_BPS + BPS - 1) / BPS
                && credit == amt;
        } else if (kind == 1) {
            // B: fee == ceil(P * 400 / 9600) on the pool input P actually consumed, credit == P + fee
            uint256 paid = p.w - weth.balanceOf(address(this));
            uint256 got = qpull.balanceOf(address(this)) - p.q;
            ok = ok && paid >= fee && fee == ((paid - fee) * TAX_BPS + (BPS - TAX_BPS) - 1) / (BPS - TAX_BPS)
                && credit == paid && (binding ? got <= amt : got == amt);
        } else if (kind == 2) {
            // C: fee == floor(gross WETH out * t / 1e4) at the current decay step, no credit
            uint256 out = weth.balanceOf(address(this)) - p.w;
            ok = ok && fee == ((out + fee) * t) / BPS && credit == 0;
        } else {
            // D: receives exactly N, fee == ceil(N * t / (1e4 - t)), no credit
            uint256 out = weth.balanceOf(address(this)) - p.w;
            ok = ok && out == amt && fee == (amt * t + (BPS - t) - 1) / (BPS - t) && credit == 0;
        }
        if (kind < 2) {
            sumBuyFeeWeth += fee;
            sumCredit += credit;
        } else {
            if (t > maxSellBpsSeen) maxSellBpsSeen = t;
            if (t < minSellBpsSeen) minSellBpsSeen = t;
        }
        if (!ok) ++formulaMismatches;
    }

    /// Mirror of QpullTaxHook._taxBps(false): 20/16/12/8% per SELL_STEP() from launch, then the flat 4%.
    function _sellBps() internal view returns (uint256) {
        uint256 l = hook.launchTime();
        if (block.timestamp >= l + hook.SELL_DECAY()) return TAX_BPS;
        uint256 decay = ((block.timestamp - l) / hook.SELL_STEP()) * 400;
        return decay >= 1600 ? TAX_BPS : 2000 - decay;
    }

    function _checkHookFlat() internal {
        address h = address(hook);
        if (
            weth.balanceOf(h) != 0 || qpull.balanceOf(h) != 0 || pm.currencyDelta(h, V4Currency.wrap(address(weth))) != 0
                || pm.currencyDelta(h, V4Currency.wrap(address(qpull))) != 0
        ) ++hookLeaks;
    }

    function _wrappedPartialFill() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IV4Hooks.afterSwap.selector,
            abi.encodeWithSelector(QpullTaxHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}

contract QpullTaxHookInvariantTest is HookFuzzBase {
    HookInvariantHandler handler;

    function setUp() public {
        _baseSetUp();
        adapter.setPoolKey(
            PoolKey({
                currency0: Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
                currency1: Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: hookAddr
            })
        );
        qpull.approve(address(adapter), type(uint256).max); // this contract is the adapter's treasury
        handler = new HookInvariantHandler(
            IV4PoolManager(address(manager)),
            swapRouter,
            hook,
            adapter,
            rec,
            qpull,
            weth,
            feeSink,
            address(this),
            key,
            qpullIs0
        );
        // Start at the end of the 1h holder gate: sell step 0 (20%), so the warp handler walks every decay step.
        vm.warp(hook.launchTime() + hook.GATE_DURATION());

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = HookInvariantHandler.exactInBuy.selector;
        selectors[1] = HookInvariantHandler.exactOutBuy.selector;
        selectors[2] = HookInvariantHandler.exactInSell.selector;
        selectors[3] = HookInvariantHandler.exactOutSell.selector;
        selectors[4] = HookInvariantHandler.exemptSell.selector;
        selectors[5] = HookInvariantHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Credit invariant over any random sequence: sumBuyFeeWeth * 1e4 >= 400 * sumCredit; the treasury holds
    /// exactly the WETH fees the handler measured and never any QPULL; the recorder's credit equals the ghost; the
    /// hook never holds a token or leaves a delta open; the exempt path never pays or records.
    function invariant_creditBackedByWethFee_treasuryWethOnly_hookFlat() public view {
        assertGe(handler.sumBuyFeeWeth() * 10_000, 400 * handler.sumCredit(), "credit not backed by 4% WETH fee");
        assertEq(qpull.balanceOf(feeSink), 0, "treasury received QPULL");
        assertEq(weth.balanceOf(feeSink), handler.sumFeeWeth(), "treasury WETH != sum of measured fees");
        assertEq(rec.totalGross(), handler.sumCredit(), "recorder credit != ghost");
        assertEq(weth.balanceOf(hookAddr), 0, "hook holds WETH");
        assertEq(qpull.balanceOf(hookAddr), 0, "hook holds QPULL");
        assertEq(handler.hookLeaks(), 0, "hook held a token or an open delta after a swap");
        assertEq(handler.exemptLeaks(), 0, "exempt swap paid or recorded");
    }

    /// Every swap's measured fee equals its kind's formula exactly (A ceil 4% of G; B ceil(P*400/9600); C floor
    /// t of gross; D ceil(N*t/(1e4-t))), credit equals WETH paid on buys and 0 on sells, and nothing reverted
    /// except PartialFill on an A or D with a binding limit.
    function invariant_everySwapMatchesItsKindFormula() public view {
        assertEq(handler.formulaMismatches(), 0, "a swap's fee or credit did not match its kind's formula");
        assertEq(handler.unexpectedReverts(), 0, "a swap reverted with something other than an allowed PartialFill");
    }

    function afterInvariant() public view {
        console2.log("filled A/B/C/D:", handler.filled(0), handler.filled(1), handler.filled(2));
        console2.log("filled D, partialFills, exempt:", handler.filled(3), handler.partialFills(), handler.exemptSwaps());
        console2.log("warps, sell bps min/max seen:", handler.warps(), handler.minSellBpsSeen(), handler.maxSellBpsSeen());
    }
}

/// @dev The stateful suite with QPULL and WETH in the opposite address order.
contract QpullTaxHookInvariantFlippedTest is QpullTaxHookInvariantTest {
    function _flipTokenOrder() internal pure override returns (bool) {
        return true;
    }
}
