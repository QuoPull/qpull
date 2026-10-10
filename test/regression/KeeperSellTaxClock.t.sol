// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../../src/interfaces/IPoolManager.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";

interface ITestMintable {
    function mint(address to, uint256 amt) external;
}

interface ITestAdapter {
    function setPoolKey(PoolKey calldata k) external;
    function setTreasury(address t) external;
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256);
}

interface ITestQuoter {
    function quoteExactInputSingle(PoolKey memory key, bool zeroForOne, uint128 exactAmount, bytes calldata hookData)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice The keeper once grossed up the taxed quote on the wrong clock; this file is now a REGRESSION SPEC OF THE
///         CORRECT CLOCK.
///
///         The original bug: keeper.js stepped the launch sell tax from PackRegistry.genesis on the HOST clock, while the hook
///         steps it from its own launchTime on the BLOCK clock. A go-live that slipped from GENESIS, or a keeper host a
///         few seconds off, made convert()'s leg-1 floor either loose (up to 17.5% at a 48h slip) or impossible (a
///         revert on every convert). This file used to demonstrate each failure. The keeper now reads every input of the
///         schedule from the pool's hook (launchTime, SELL_STEP(), SELL_DECAY(), SELL_TAX_START_BPS, SELL_STEP_BPS,
///         TAX_BPS) and evaluates it at the timestamp of the block the quote was simulated at (keeper.js
///         sellTaxBpsAt / quoteLeg1), and inverts the taxed quote to the SMALLEST exempt gross (grossUpForExemptSell).
///         There is no genesis input left to be wrong, so the old scenarios are kept only as the times they probed.
///
///         What is pinned, against the real vendored PoolManager, the real QpullTaxHook (mainnet and the testnet
///         subclass), the real QpullWethAdapter (the hook's exemptSender) and the real QpullV4Quoter:
///           1. the transliterated keeper recovers the exempt leg-1 output from the taxed quote to within 1 wei, never
///              above it, at every step boundary (-1s, 0, +1s) of the schedule and long after it;
///           2. so the floor is exactly the designed 1% (CONVERT_SLIPPAGE_BPS default 100) and the real convert swap
///              clears it;
///           3. a quote taken just before a step boundary and executed just after it (or the reverse) still clears:
///              the exempt output does not depend on the tax, only the quote does, and it is priced at its own block;
///           4. the same holds on the compressed testnet schedule, because nothing about the schedule is hardcoded.
///         keeper.js is transliterated by FUNCTION NAME (its line numbers move); the hook's rate is never mirrored in
///         the assertions, only in the keeper transliteration under test.
contract KeeperSellTaxClockTest is Test, IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;

    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 constant AMOUNT_IN = 500 ether; // the convert slice being quoted
    uint256 constant BPS = 10_000;
    uint256 constant CONVERT_SLIPPAGE_BPS = 100; // keeper.js default

    IPoolManager pm;
    address qpull;
    address weth;
    address nft;
    address rec;
    address adapter;
    address quoter;
    address hookAddr;
    PoolKey key;
    bool qIs0;

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        qpull = deployCode("MockERC20.sol:MockERC20");
        weth = deployCode("MockERC20.sol:MockERC20");
        nft = deployCode("MockNFT.sol:MockNFT"); // launched() == true
        rec = deployCode("MockRecorder.sol:MockRecorder");
        quoter = deployCode("QpullV4Quoter.sol:QpullV4Quoter", abi.encode(address(pm)));
        qIs0 = qpull < weth;
        ITestMintable(qpull).mint(address(this), 400_000 ether);
        ITestMintable(weth).mint(address(this), 400_000 ether);
        _launch("src/hooks/QpullTaxHook.sol:QpullTaxHook", 0x7A11);
    }

    /// A fresh exempt adapter, a hook naming it (constructor immutable), and a deep full-range pool created now.
    function _launch(string memory hookArtifact, uint256 tag) internal {
        adapter = deployCode("QpullWethAdapter.sol:QpullWethAdapter", abi.encode(address(pm), qpull, weth, address(this)));
        hookAddr = address(uint160((tag << 16) | FLAGS));
        deployCodeTo(
            hookArtifact,
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(pm),
                    qpull: qpull,
                    weth: weth,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: makeAddr("treasuryFeeSink"),
                    packRegistry: rec,
                    leaderboardRegistry: rec,
                    nft: nft,
                    exemptSender: adapter, // convert()'s leg-1 adapter: untaxed
                    initializer: address(this), // this test plays QpullLiquidityLock (init + one add)
                    earlyBuyCapWei: type(uint256).max
                })
            ),
            hookAddr
        );
        key = PoolKey({
            currency0: Currency.wrap(qIs0 ? qpull : weth),
            currency1: Currency.wrap(qIs0 ? weth : qpull),
            fee: 3000,
            tickSpacing: 60,
            hooks: hookAddr
        });
        pm.initialize(key, SQRT_1_1); // afterInitialize stamps launchTime = block.timestamp
        pm.unlock(abi.encode(uint8(0), uint256(20_000 ether))); // deep full-range seed
        ITestAdapter(adapter).setPoolKey(key);
        ITestAdapter(adapter).setTreasury(address(this)); // this test is the Treasury caller
        IERC20(qpull).approve(adapter, type(uint256).max);
    }

    // mode 0: full-range add. mode 1: a PUBLIC (taxed) exact-in QPULL->WETH sell from this contract.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 mode, uint256 amt) = abi.decode(data, (uint8, uint256));
        BalanceDelta d;
        if (mode == 0) {
            (d,) = pm.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams(-887_220, 887_220, int256(amt), bytes32(0)), ""
            );
        } else {
            d = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: qIs0,
                    amountSpecified: -int256(amt),
                    sqrtPriceLimitX96: qIs0 ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
                }),
                ""
            );
        }
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 a) internal {
        if (a < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-int256(a)));
            pm.settle();
        } else if (a > 0) {
            pm.take(c, address(this), uint256(uint128(a)));
        }
    }

    // ── keeper.js, transliterated by function name ─────────────────────────────────────────────────────────

    /// keeper.js sellTaxBpsAt: every input read from the HOOK, `nowTs` = the quote block's timestamp.
    function keeperSellTaxBpsAt(QpullTaxHook h, uint256 nowTs) internal view returns (uint256) {
        uint256 lt = h.launchTime();
        uint256 floor = h.TAX_BPS();
        if (lt == 0 || nowTs >= lt + h.SELL_DECAY()) return floor;
        require(nowTs >= lt, "keeper: block timestamp before the hook's launchTime"); // keeper throws RangeError
        require(h.SELL_STEP() != 0, "keeper: SELL_STEP() is 0");
        uint256 decay = ((nowTs - lt) / h.SELL_STEP()) * h.SELL_STEP_BPS();
        uint256 start = h.SELL_TAX_START_BPS();
        return decay >= start - floor ? floor : start - decay;
    }

    /// keeper.js exemptSellNet: what a TAXED exact-in sell of gross G pays the seller (floor fee, design D).
    function exemptSellNet(uint256 g, uint256 t) internal pure returns (uint256) {
        return g - (g * t) / BPS;
    }

    /// keeper.js grossUpForExemptSell: the SMALLEST G whose taxed net equals the quote.
    function grossUpForExemptSell(uint256 q, uint256 t) internal pure returns (uint256 g) {
        require(t < BPS, "keeper: tax outside [0, BPS)");
        if (q == 0) return 0;
        g = (q * BPS) / (BPS - t);
        for (uint256 i; exemptSellNet(g, t) > q; ++i) {
            require(i <= 20_000, "no convergence");
            --g;
        }
        for (uint256 i; exemptSellNet(g, t) < q; ++i) {
            require(i <= 20_000, "no convergence");
            ++g;
        }
        while (g > 0 && exemptSellNet(g - 1, t) == q) --g;
    }

    /// keeper.js quoteLeg1 -> withSlippage(untaxed, CONVERT_SLIPPAGE).
    function keeperMinWeth(uint256 taxedQuote, uint256 taxBps) internal pure returns (uint256) {
        return (grossUpForExemptSell(taxedQuote, taxBps) * (BPS - CONVERT_SLIPPAGE_BPS)) / BPS;
    }

    // ── live chain facts ───────────────────────────────────────────────────────────────────────────────────

    function _quote() internal returns (uint256 q) {
        (q,) = ITestQuoter(quoter).quoteExactInputSingle(key, qIs0, uint128(AMOUNT_IN), "");
    }

    /// What convert()'s real leg-1 swap delivers right now (the exempt adapter), measured and rolled back.
    function _exemptOut() internal returns (uint256 out) {
        uint256 s = vm.snapshotState();
        out = ITestAdapter(adapter).swapExactIn(qpull, weth, AMOUNT_IN, 1, address(this));
        vm.revertToState(s);
    }

    /// At `at`: the keeper's recovery is exact (within 1 wei, never above the real exempt output), its floor is the
    /// designed 99% of that output, and the real convert swap clears the floor. `at` is passed explicitly: under
    /// via_ir the optimizer may CSE TIMESTAMP across a cheatcode call, so block.timestamp is never re-read.
    function _assertExactAt(QpullTaxHook h, uint256 at, string memory label) internal {
        vm.warp(at);
        uint256 t = keeperSellTaxBpsAt(h, at);
        uint256 q = _quote();
        uint256 out = _exemptOut();
        uint256 g = grossUpForExemptSell(q, t);
        uint256 minW = keeperMinWeth(q, t);
        emit log_named_uint(string.concat(label, ": keeper tax bps"), t);
        assertLe(g, out, string.concat(label, ": recovered gross never exceeds the exempt output"));
        assertLe(out - g, 1, string.concat(label, ": recovered gross is exact to 1 wei"));
        assertApproxEqAbs((minW * 1_000_000) / out, 990_000, 1, string.concat(label, ": floor is the designed 1%"));
        uint256 s = vm.snapshotState();
        uint256 got = ITestAdapter(adapter).swapExactIn(qpull, weth, AMOUNT_IN, minW, address(this));
        assertGe(got, minW, string.concat(label, ": the real convert swap clears the keeper floor"));
        vm.revertToState(s);
    }

    /// Every step boundary of a schedule, -1s / 0 / +1s, plus launch and far past the decay.
    function _sweep(QpullTaxHook h) internal {
        uint256 lt = h.launchTime();
        uint256 step = h.SELL_STEP();
        uint256 decay = h.SELL_DECAY();
        _assertExactAt(h, lt, "launch instant");
        _assertExactAt(h, lt + 1, "launch +1s");
        for (uint256 b = step; b <= decay; b += step) {
            _assertExactAt(h, lt + b - 1, "boundary -1s");
            _assertExactAt(h, lt + b, "boundary");
            _assertExactAt(h, lt + b + 1, "boundary +1s");
        }
        _assertExactAt(h, lt + decay + 30 days, "long after the decay");
    }

    // ── 1 + 2. exact recovery and the designed floor across the whole mainnet schedule ─────────────────────────

    function test_mainnetSchedule_exactRecoveryAndDesignedFloor_atEveryStepBoundary() public {
        QpullTaxHook h = QpullTaxHook(hookAddr);
        assertEq(h.SELL_STEP(), 12 hours, "mainnet step");
        assertEq(h.SELL_DECAY(), 48 hours, "mainnet decay");
        _sweep(h);
    }

    /// The times the old tests probed (a go-live 12h or 48h after GENESIS, one 12h or 48h before it) are just
    /// offsets from launchTime to the keeper now: GENESIS is not an input, so each lands on the designed floor. The
    /// old genesis clock gave 82.5% / 94.3% (loose) and 103.95% / 118.8% (a convert that always reverted) here.
    function test_formerGenesisSlipScenarios_nowOnTheDesignedFloor() public {
        QpullTaxHook h = QpullTaxHook(hookAddr);
        uint256 lt = h.launchTime();
        _assertExactAt(h, lt + 1 hours, "former (a) 48h slip, +1h");
        _assertExactAt(h, lt + 11 hours, "former (a'') 12h slip, +11h");
        _assertExactAt(h, lt + 13 hours, "former (b) seeded 12h before GENESIS, +13h");
        _assertExactAt(h, lt + 49 hours, "former (b) seeded 48h before GENESIS, +49h");
    }

    // ── 3. quote block vs execution block across a step boundary ─────────────────────────────────────────────

    /// The former clock-skew case (c): the quote is priced at its own block, and the exempt output it recovers does
    /// not move when the tax steps, so a convert that lands a few seconds later on the other side of a boundary
    /// still clears, in both directions.
    function test_quoteBeforeBoundary_executeAfter_stillClears_andReverse() public {
        QpullTaxHook h = QpullTaxHook(hookAddr);
        uint256 lt = h.launchTime();
        uint256 b = lt + h.SELL_STEP();

        vm.warp(b - 1); // quote at 20%
        uint256 minW = keeperMinWeth(_quote(), keeperSellTaxBpsAt(h, b - 1));
        vm.warp(b + 30); // execute at 16%
        uint256 s = vm.snapshotState();
        assertGe(ITestAdapter(adapter).swapExactIn(qpull, weth, AMOUNT_IN, minW, address(this)), minW, "20% quote, 16% fill");
        vm.revertToState(s);

        uint256 minW2 = keeperMinWeth(_quote(), keeperSellTaxBpsAt(h, b + 30)); // quote at 16%
        vm.warp(b + 2 * h.SELL_STEP() + 5); // execute two steps later, at 8%
        assertGe(ITestAdapter(adapter).swapExactIn(qpull, weth, AMOUNT_IN, minW2, address(this)), minW2, "16% quote, 8% fill");
    }

    /// The floor still does its job: a public taxed sell landing between the quote and the convert moves the price,
    /// and the keeper's floor (from the pre-sell quote) refuses the worse fill.
    function test_floorStillRefusesAFrontRun() public {
        QpullTaxHook h = QpullTaxHook(hookAddr);
        uint256 at = h.launchTime() + 1 hours;
        vm.warp(at);
        uint256 minW = keeperMinWeth(_quote(), keeperSellTaxBpsAt(h, at));
        ITestMintable(qpull).mint(address(this), 1_000 ether);
        pm.unlock(abi.encode(uint8(1), uint256(1_000 ether))); // the front-run: a public taxed sell
        vm.expectRevert(bytes4(keccak256("Slippage()")));
        ITestAdapter(adapter).swapExactIn(qpull, weth, AMOUNT_IN, minW, address(this));
    }

    // ── 4. the compressed testnet schedule, read from the subclass ───────────────────────────────────────────

    function test_testnetSubclassSchedule_exactRecoveryAtEveryStepBoundary() public {
        _launch("src/testnet/TestnetShortClock.sol:QpullTaxHookTestnet", 0x7A12);
        QpullTaxHook h = QpullTaxHook(hookAddr);
        assertEq(h.SELL_STEP(), 5 minutes, "testnet step");
        assertEq(h.SELL_DECAY(), 20 minutes, "testnet decay");
        _sweep(h);
    }
}
