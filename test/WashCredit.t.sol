// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { QpullTaxHookFixture } from "./QpullTaxHook.t.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { IERC20Minimal } from "v4-core/interfaces/external/IERC20Minimal.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";

interface ICreditTotal {
    function totalGross() external view returns (uint256);
}

/// Runs a scripted sequence of swaps against the canonical pool (or, per step, an alternate pool) inside one
/// or more pm.unlock calls, settling only the net at the end of each unlock. Kinds:
///   A exact-in buy (amount = WETH in)       B exact-out buy (amount = QPULL out)
///   C exact-in sell (amount = QPULL in; type(uint256).max = every QPULL acquired since setBase())
///   D exact-out sell (amount = WETH out)    BRK = settle and open a new unlock (same external call)
/// After EVERY swap it requires the hook's PoolManager delta to be 0 in both currencies (H5).
/// Optional, for the any-sequence fuzz: `binding` steps use a price limit 0.01% past the CURRENT price (read from
/// slot0 at the step, so it is never already exceeded); `clipExactOut` caps an exact-out step at half the pool's
/// current reserve of the output token (a realisable trade: past that the pool's own int128 input bound, not the
/// hook, decides); `setObservers` makes every step log its credit, WETH paid and WETH fee for per-swap H2/H4.
contract SeqAttacker is IUnlockCallback {
    using TransientStateLibrary for IV4PoolManager;
    using StateLibrary for IV4PoolManager;
    using PoolIdLibrary for V4PoolKey;

    uint8 public constant A = 0;
    uint8 public constant B = 1;
    uint8 public constant C = 2;
    uint8 public constant D = 3;
    uint8 public constant BRK = 4;

    struct Step {
        uint8 kind;
        uint256 amount;
        bool alt; // route this step to altKey (e.g. a hookless pool) instead of the canonical key
        bool binding; // price limit 0.01% past the current price instead of the MIN/MAX sentinel
    }

    /// Per-step observation (only when observers are set).
    struct Obs {
        uint8 kind;
        uint256 credit; // recorder totalGross delta
        uint256 paid; // WETH the attacker owes for this swap (buys)
        uint256 fee; // treasury WETH delta
        uint256 feeQpull; // treasury QPULL delta
    }

    IV4PoolManager public immutable pm;
    address public immutable qpull;
    address public immutable weth;
    address public immutable hook;
    bool public immutable qpullIs0;
    V4PoolKey public key;
    V4PoolKey public altKey;
    uint256 public qBase;
    bool public clipExactOut;
    address public recorder;
    address public sink;
    Obs[] internal _obs;
    uint160 constant MIN_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    constructor(IV4PoolManager pm_, V4PoolKey memory key_, V4PoolKey memory alt_, address qpull_, address weth_) {
        pm = pm_;
        key = key_;
        altKey = alt_;
        qpull = qpull_;
        weth = weth_;
        hook = address(key_.hooks);
        qpullIs0 = qpull_ < weth_;
        qBase = IERC20(qpull_).balanceOf(address(this));
    }

    function setBase() external {
        qBase = IERC20(qpull).balanceOf(address(this));
    }

    function setClipExactOut(bool v) external {
        clipExactOut = v;
    }

    function setObservers(address recorder_, address sink_) external {
        recorder = recorder_;
        sink = sink_;
    }

    function obsCount() external view returns (uint256) {
        return _obs.length;
    }

    function obs(uint256 i) external view returns (Obs memory) {
        return _obs[i];
    }

    /// `preSettleWeth`: WETH paid into the manager (sync/transfer/settle) at the start of every unlock, so the
    /// manager physically holds enough WETH for the hook's take() before this caller's net settle.
    function run(Step[] calldata steps, uint256 preSettleWeth) external {
        uint256 i;
        while (i < steps.length) {
            i = abi.decode(pm.unlock(abi.encode(steps, i, preSettleWeth)), (uint256));
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (Step[] memory steps, uint256 i, uint256 pre) = abi.decode(data, (Step[], uint256, uint256));
        if (pre != 0) {
            pm.sync(V4Currency.wrap(weth));
            IERC20(weth).transfer(address(pm), pre);
            pm.settle();
        }
        for (; i < steps.length; ++i) {
            if (steps[i].kind == BRK) {
                ++i;
                break;
            }
            _step(steps[i]);
            require(pm.currencyDelta(hook, V4Currency.wrap(weth)) == 0, "H5: hook WETH delta");
            require(pm.currencyDelta(hook, V4Currency.wrap(qpull)) == 0, "H5: hook QPULL delta");
        }
        _settle(V4Currency.wrap(weth));
        _settle(V4Currency.wrap(qpull));
        return abi.encode(i);
    }

    function _step(Step memory s) internal {
        V4PoolKey memory k = s.alt ? altKey : key;
        bool buy = s.kind == A || s.kind == B;
        bool zfo = buy ? !qpullIs0 : qpullIs0;
        uint256 amt = s.amount;
        if (s.kind == C && amt == type(uint256).max) {
            int256 held = int256(IERC20(qpull).balanceOf(address(this))) - int256(qBase)
                + pm.currencyDelta(address(this), V4Currency.wrap(qpull));
            require(held > 0, "nothing to sell");
            amt = uint256(held);
        }
        uint160 limit = zfo ? MIN_P1 : MAX_M1;
        if (s.binding || (clipExactOut && (s.kind == B || s.kind == D))) {
            PoolId id = k.toId();
            (uint160 sqrtP,,,) = pm.getSlot0(id);
            if (s.binding) {
                uint160 step = sqrtP / 10_000;
                limit = zfo ? (sqrtP - step > MIN_P1 ? sqrtP - step : MIN_P1) : (sqrtP + step < MAX_M1 ? sqrtP + step : MAX_M1);
            }
            if (clipExactOut && (s.kind == B || s.kind == D)) {
                uint256 liq = pm.getLiquidity(id);
                // full-range reserves: currency0 = L * 2^96 / sqrtP, currency1 = L * sqrtP / 2^96; a oneForZero swap
                // pays out currency0
                uint256 reserveOut = zfo ? (liq * sqrtP) >> 96 : (liq << 96) / sqrtP;
                if (amt > reserveOut / 2) amt = reserveOut / 2;
                if (amt == 0) amt = 1;
            }
        }
        int256 spec = (s.kind == A || s.kind == C) ? -int256(amt) : int256(amt);
        if (recorder == address(0)) {
            pm.swap(k, IV4PoolManager.SwapParams(zfo, spec, limit), "");
            return;
        }
        Obs memory o;
        o.kind = s.kind;
        uint256 g0 = ICreditTotal(recorder).totalGross();
        uint256 w0 = IERC20(weth).balanceOf(sink);
        uint256 q0 = IERC20(qpull).balanceOf(sink);
        int256 d0 = pm.currencyDelta(address(this), V4Currency.wrap(weth));
        pm.swap(k, IV4PoolManager.SwapParams(zfo, spec, limit), "");
        o.credit = ICreditTotal(recorder).totalGross() - g0;
        o.fee = IERC20(weth).balanceOf(sink) - w0;
        o.feeQpull = IERC20(qpull).balanceOf(sink) - q0;
        int256 d1 = pm.currencyDelta(address(this), V4Currency.wrap(weth));
        if (d1 < d0) o.paid = uint256(d0 - d1);
        _obs.push(o);
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

/// Game credit must cost at least the 4% tax in WETH, whatever the swapper does to the QPULL price.
/// In an earlier hook version an atomic exact-in-buy / exact-out-sell wash cost
/// 757 / 444 / 108 / 38 bps of credit at 0.1x / 1x / 10x / 100x pool depth. Every test here asserts the
/// hard properties of the WETH-tax design:
///   H1 cost * 1e4 >= 400 * credit           H2 feeSinkWeth * 1e4 >= 400 * credit     H3 feeSinkQpull == 0
///   H4 credit == the WETH the payer parted with (A: exactly G)                    H5 hook deltas/balances 0
/// and, for wash round trips, the regression band cost * 1e4 >= 780 * credit (two WETH taxes >= 7.82%).
contract WashCreditTest is QpullTaxHookFixture {
    using StateLibrary for IV4PoolManager;
    using PoolIdLibrary for V4PoolKey;

    struct Before {
        uint256 w;
        uint256 q;
        uint256 gross;
        uint256 calls;
        uint256 sinkW;
        uint256 sinkQ;
    }

    struct Res {
        int256 wethPnl; // attacker WETH after - before (negative = cost)
        int256 qNet; // attacker QPULL after - before (>= 0: not short)
        uint256 credit; // sum of pack-registry credit
        uint256 calls;
        uint256 sinkW;
        uint256 sinkQ;
        uint256 costBps; // cost * 1e4 / credit
    }

    uint256 constant BUF = 1e30; // attacker search buffer (both tokens), not capital the attack keeps

    function _depth() internal view returns (uint256) {
        return weth.balanceOf(address(manager)); // the only pool on this manager holds all of it
    }

    function _setAfterGateAndDecay() internal {
        vm.warp(hook.launchTime() + hook.SELL_DECAY() + hook.GATE_DURATION() + 1); // flat 4%, no gate/throttle
    }

    function _attacker(V4PoolKey memory alt) internal returns (SeqAttacker a) {
        a = new SeqAttacker(IV4PoolManager(address(manager)), key, alt, address(qpull), address(weth));
        weth.mint(address(a), BUF);
        qpull.mint(address(a), BUF);
        a.setBase();
    }

    function _attacker() internal returns (SeqAttacker a) {
        return _attacker(key);
    }

    function _steps1(uint8 k0, uint256 a0) internal pure returns (SeqAttacker.Step[] memory s) {
        s = new SeqAttacker.Step[](1);
        s[0] = SeqAttacker.Step(k0, a0, false, false);
    }

    function _steps2(uint8 k0, uint256 a0, uint8 k1, uint256 a1) internal pure returns (SeqAttacker.Step[] memory s) {
        s = new SeqAttacker.Step[](2);
        s[0] = SeqAttacker.Step(k0, a0, false, false);
        s[1] = SeqAttacker.Step(k1, a1, false, false);
    }

    function _snap(SeqAttacker a) internal view returns (Before memory b) {
        b = Before(
            weth.balanceOf(address(a)),
            qpull.balanceOf(address(a)),
            packRec.totalGross(),
            packRec.calls(),
            weth.balanceOf(feeSink),
            qpull.balanceOf(feeSink)
        );
    }

    function _diff(SeqAttacker a, Before memory b) internal view returns (Res memory r) {
        r.wethPnl = int256(weth.balanceOf(address(a))) - int256(b.w);
        r.qNet = int256(qpull.balanceOf(address(a))) - int256(b.q);
        r.credit = packRec.totalGross() - b.gross;
        r.calls = packRec.calls() - b.calls;
        r.sinkW = weth.balanceOf(feeSink) - b.sinkW;
        r.sinkQ = qpull.balanceOf(feeSink) - b.sinkQ;
        if (r.wethPnl <= 0 && r.credit != 0) r.costBps = uint256(-r.wethPnl) * 10_000 / r.credit;
    }

    function _exec(SeqAttacker a, SeqAttacker.Step[] memory s, uint256 pre) internal returns (Res memory r) {
        Before memory b = _snap(a);
        a.run(s, pre);
        r = _diff(a, b);
    }

    /// Would running `s` with s[idx].amount = x succeed and leave the attacker not short QPULL?
    function _good(SeqAttacker a, SeqAttacker.Step[] memory s, uint256 idx, uint256 x, uint256 pre)
        internal
        returns (bool)
    {
        uint256 qb = qpull.balanceOf(address(a));
        uint256 snap = vm.snapshotState();
        s[idx].amount = x;
        (bool ok,) = address(a).call(abi.encodeCall(SeqAttacker.run, (s, pre)));
        bool flat = ok && qpull.balanceOf(address(a)) >= qb;
        vm.revertToState(snap);
        return flat;
    }

    /// Largest x in [0, hi] (a D-type step: more x spends more QPULL) that keeps the attacker QPULL-flat.
    function _maxFlat(SeqAttacker a, SeqAttacker.Step[] memory s, uint256 idx, uint256 hi, uint256 pre)
        internal
        returns (uint256 lo)
    {
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_good(a, s, idx, mid, pre)) lo = mid;
            else hi = mid - 1;
        }
        s[idx].amount = lo;
    }

    /// Smallest x in [1, hi] (an A-type step: more x buys more QPULL) that keeps the attacker QPULL-flat.
    function _minFlat(SeqAttacker a, SeqAttacker.Step[] memory s, uint256 idx, uint256 hi, uint256 pre)
        internal
        returns (uint256 lo)
    {
        require(_good(a, s, idx, hi, pre), "hi not flat");
        lo = 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_good(a, s, idx, mid, pre)) hi = mid;
            else lo = mid + 1;
        }
        s[idx].amount = lo;
    }

    function _log(string memory tag, Res memory r) internal {
        emit log_named_string("case", tag);
        emit log_named_uint("  credit (wei)          ", r.credit);
        emit log_named_int("  attacker WETH pnl     ", r.wethPnl);
        emit log_named_int("  attacker QPULL net    ", r.qNet);
        emit log_named_uint("  treasury WETH fee     ", r.sinkW);
        emit log_named_uint("  treasury QPULL fee    ", r.sinkQ);
        emit log_named_uint("  cost / credit (bps)   ", r.costBps);
        if (r.credit != 0) emit log_named_uint("  fee / credit (bps)    ", r.sinkW * 10_000 / r.credit);
    }

    /// H1-H3 + H5 (+ H4 when expectedCredit != max) and, if `wash`, the 780 bps band.
    function _assertHard(Res memory r, uint256 expectedCredit, bool wash) internal view {
        assertGe(r.qNet, 0, "attacker is not short QPULL");
        assertLe(r.wethPnl, 0, "attacker did not profit in WETH");
        uint256 cost = uint256(-r.wethPnl);
        assertGt(r.credit, 0, "something was credited");
        assertGe(cost * 10_000, 400 * r.credit, "H1: cost >= 4% of credit");
        assertGe(r.sinkW * 10_000, 400 * r.credit, "H2: treasury WETH >= 4% of credit");
        assertEq(r.sinkQ, 0, "H3: no QPULL ever reaches the treasury");
        if (expectedCredit != type(uint256).max) assertEq(r.credit, expectedCredit, "H4: credit == WETH paid");
        if (wash) assertGe(cost * 10_000, 780 * r.credit, "wash band: cost >= 7.80% of credit");
        _assertHookFlat();
    }

    // ─── 1. atomic wash (A then D, QPULL-flat) at 0.1x / 1x / 10x / 100x depth ─────────────────────

    function test_atomicWash_depthLadder() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        emit log_named_uint("pool WETH depth (wei)", depth);
        uint256[4] memory tenths = [uint256(1), 10, 100, 1000]; // notional in tenths of depth
        for (uint256 i; i < 4; ++i) {
            uint256 s0 = vm.snapshotState();
            uint256 w = depth * tenths[i] / 10;
            // 100x: the buy's 4% fee alone is 4x the manager's WETH, so the float must be pre-settled (see below)
            uint256 pre = tenths[i] >= 1000 ? w : 0;
            SeqAttacker a = _attacker();
            SeqAttacker.Step[] memory s = _steps2(0, w, 3, 0);
            uint256 wOut = _maxFlat(a, s, 1, w, pre);
            assertGt(wOut, 0, "a flat exact-out sell exists");
            Res memory r = _exec(a, s, pre);
            _log(string.concat("atomic A+D wash, notional x0.1 depth = ", vm.toString(tenths[i])), r);
            assertEq(r.calls, 1, "exactly one credited buy");
            _assertHard(r, w, true);
            vm.revertToState(s0);
        }
    }

    /// At 100x depth the wash now needs real float: without it the WETH take
    /// fails; a 4.2x-depth pre-settle covers the buy fee but not the sell fee; pre-settling the notional
    /// works and still costs >= 7.8% of credit.
    function test_100xWashNeedsFloat() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256 w = depth * 100;
        SeqAttacker a = _attacker();
        SeqAttacker.Step[] memory s = _steps2(0, w, 3, 0);
        uint256 wOut = _maxFlat(a, s, 1, w, w); // flat size with enough float
        emit log_named_uint("flat exact-out sell at 100x (wei)", wOut);

        // (i) no float: the hook's take() of the 4x-depth buy fee cannot be paid
        (bool ok, bytes memory ret) = address(a).call(abi.encodeCall(SeqAttacker.run, (s, 0)));
        assertFalse(ok, "no float: reverts");
        _assertTakeShortfall(ret);
        // (ii) 4.2x depth: the buy fee is covered, the exact-out sell's WETH fee is not
        (ok, ret) = address(a).call(abi.encodeCall(SeqAttacker.run, (s, depth * 42 / 10)));
        assertFalse(ok, "4.2x depth float: reverts");
        _assertTakeShortfall(ret);
        // buy alone with 4.2x depth float succeeds
        uint256 snap = vm.snapshotState();
        a.run(_steps1(0, w), depth * 42 / 10);
        vm.revertToState(snap);

        Res memory r = _exec(a, s, w); // (iii) float == notional
        _log("100x A+D wash with float == notional", r);
        emit log_named_uint("  float pre-settled (wei)", w);
        _assertHard(r, w, true);
    }

    /// The revert is exactly: hook afterSwap -> PoolManager.take -> WETH.transfer -> ERC20InsufficientBalance
    /// (the manager does not physically hold the fee). Nothing settles short.
    function _assertTakeShortfall(bytes memory ret) internal view {
        assertEq(bytes4(ret), CustomRevert.WrappedError.selector, "outer: v4 hook wrap");
        (address target, bytes4 fn, bytes memory reason,) = abi.decode(_strip4(ret), (address, bytes4, bytes, bytes));
        assertEq(target, hookAddr, "outer target: the hook");
        assertEq(fn, IV4Hooks.afterSwap.selector, "outer fn: afterSwap");
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "inner: currency transfer wrap");
        (address t2, bytes4 fn2, bytes memory reason2, bytes memory ctx2) =
            abi.decode(_strip4(reason), (address, bytes4, bytes, bytes));
        assertEq(t2, address(weth), "inner target: WETH");
        assertEq(fn2, IERC20Minimal.transfer.selector, "inner fn: transfer");
        assertEq(bytes4(reason2), IERC20Errors.ERC20InsufficientBalance.selector, "cause: manager WETH shortfall");
        assertEq(bytes4(ctx2), bytes4(keccak256("ERC20TransferFailed()")), "context: ERC20TransferFailed");
    }

    function _strip4(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + 4];
        }
    }

    // ─── 2a. N buy/sell cycles in ONE unlock ───────────────────────────────────────────────────────

    function test_multiCycle_oneUnlock() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256[4] memory ns = [uint256(1), 5, 10, 50];
        for (uint256 variant; variant < 3; ++variant) {
            uint256 prevBps;
            for (uint256 j; j < 4; ++j) {
                uint256 n = ns[j];
                uint256 s0 = vm.snapshotState();
                SeqAttacker a = _attacker();
                SeqAttacker.Step[] memory s = new SeqAttacker.Step[](2 * n);
                uint256 expected;
                string memory tag;
                if (variant == 0) {
                    // A+C, 1x depth split N ways
                    for (uint256 c; c < n; ++c) {
                        s[2 * c] = SeqAttacker.Step(0, depth / n, false, false);
                        s[2 * c + 1] = SeqAttacker.Step(2, type(uint256).max, false, false);
                    }
                    expected = (depth / n) * n;
                    tag = "A+C cycles, 1x depth split N ways, N = ";
                } else if (variant == 1) {
                    // A+C, 1x depth PER cycle
                    for (uint256 c; c < n; ++c) {
                        s[2 * c] = SeqAttacker.Step(0, depth, false, false);
                        s[2 * c + 1] = SeqAttacker.Step(2, type(uint256).max, false, false);
                    }
                    expected = depth * n;
                    tag = "A+C cycles, 1x depth per cycle, N = ";
                } else {
                    // B+C, half-depth QPULL bought per cycle (exact-out buys), sold straight back
                    for (uint256 c; c < n; ++c) {
                        s[2 * c] = SeqAttacker.Step(1, depth / 2, false, false);
                        s[2 * c + 1] = SeqAttacker.Step(2, type(uint256).max, false, false);
                    }
                    expected = type(uint256).max; // B credit == paid is asserted per swap in the hook suite
                    tag = "B+C cycles, 0.5x depth QPULL per cycle, N = ";
                }
                // float for the per-swap takes: ~8.5% of total notional, plus a margin
                uint256 pre = variant == 0 ? 0 : (depth * n) / 8 + depth;
                Res memory r = _exec(a, s, pre);
                _log(string.concat(tag, vm.toString(n)), r);
                assertEq(r.calls, n, "one credit per buy");
                assertEq(r.qNet, 0, "exactly QPULL-flat");
                _assertHard(r, expected, true);
                // cost/credit must not fall as N grows by more than rounding (1 bps)
                if (j > 0) assertGe(r.costBps + 1, prevBps, "more cycles never make credit cheaper");
                prevBps = r.costBps;
                vm.revertToState(s0);
            }
        }
    }

    // ─── 2b/2c. pump, then buy, then dump: one unlock, and split across 3 unlocks in one call ──────

    function test_pumpThenBuyThenDump() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256[3] memory ks = [uint256(1), 10, 100];
        for (uint256 split; split < 2; ++split) {
            for (uint256 i; i < 3; ++i) {
                uint256 s0 = vm.snapshotState();
                uint256 g1 = depth * ks[i];
                uint256 g2 = depth;
                SeqAttacker a = _attacker();
                SeqAttacker.Step[] memory s;
                if (split == 0) {
                    s = new SeqAttacker.Step[](3);
                    s[0] = SeqAttacker.Step(0, g1, false, false);
                    s[1] = SeqAttacker.Step(0, g2, false, false);
                    s[2] = SeqAttacker.Step(2, type(uint256).max, false, false);
                } else {
                    s = new SeqAttacker.Step[](5);
                    s[0] = SeqAttacker.Step(0, g1, false, false);
                    s[1] = SeqAttacker.Step(4, 0, false, false);
                    s[2] = SeqAttacker.Step(0, g2, false, false);
                    s[3] = SeqAttacker.Step(4, 0, false, false);
                    s[4] = SeqAttacker.Step(2, type(uint256).max, false, false);
                }
                uint256 pre = ks[i] >= 100 ? g1 + g2 : 0; // 100x pump: pre-settle the notional
                Res memory r = _exec(a, s, pre);
                _log(
                    string.concat(
                        split == 0 ? "pump/buy/dump ONE unlock, pump k = " : "pump/buy/dump 3 unlocks, pump k = ",
                        vm.toString(ks[i])
                    ),
                    r
                );
                assertEq(r.calls, 2, "two credited buys");
                assertEq(packRec.lastGross(), g2, "second buy credited exactly G2: independent of the pumped price");
                assertEq(r.qNet, 0, "exactly QPULL-flat");
                _assertHard(r, g1 + g2, true);
                vm.revertToState(s0);
            }
        }
    }

    // ─── 2d. all four pairings at 1x depth, plus sell-first ────────────────────────────────────────

    function test_pairingsAt1xDepth() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256 s0;
        SeqAttacker a;
        SeqAttacker.Step[] memory s;
        Res memory r;

        s0 = vm.snapshotState();
        a = _attacker();
        r = _exec(a, _steps2(0, depth, 2, type(uint256).max), 0);
        _log("pairing A+C", r);
        _assertHard(r, depth, true);
        vm.revertToState(s0);

        s0 = vm.snapshotState();
        a = _attacker();
        s = _steps2(0, depth, 3, 0);
        _maxFlat(a, s, 1, depth, 0);
        r = _exec(a, s, 0);
        _log("pairing A+D", r);
        _assertHard(r, depth, true);
        vm.revertToState(s0);

        s0 = vm.snapshotState();
        a = _attacker();
        r = _exec(a, _steps2(1, depth / 2, 2, type(uint256).max), 0);
        _log("pairing B+C (0.5x depth QPULL)", r);
        _assertHard(r, type(uint256).max, true);
        vm.revertToState(s0);

        s0 = vm.snapshotState();
        a = _attacker();
        s = _steps2(1, depth / 2, 3, 0);
        _maxFlat(a, s, 1, depth, 0);
        r = _exec(a, s, 0);
        _log("pairing B+D (0.5x depth QPULL)", r);
        _assertHard(r, type(uint256).max, true);
        vm.revertToState(s0);

        // sell-first: exact-in sell of 0.5x depth QPULL the attacker already holds, then the smallest exact-in
        // buy that restores its QPULL
        s0 = vm.snapshotState();
        a = _attacker();
        s = _steps2(2, depth / 2, 0, 0);
        uint256 g = _minFlat(a, s, 1, depth * 2, 0);
        r = _exec(a, s, 0);
        _log("sell-first C then A", r);
        _assertHard(r, g, true);
        vm.revertToState(s0);
    }

    // ─── 3. split transactions ─────────────────────────────────────────────────────────────────────

    /// tx1 exact-in buy W; tx2 (next block, +60s) exact-out sell to QPULL-flat. 0.1x / 1x / 10x.
    function test_splitTx_buyThenSellNextBlock() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256[3] memory tenths = [uint256(1), 10, 100];
        for (uint256 i; i < 3; ++i) {
            uint256 s0 = vm.snapshotState();
            uint256 w = depth * tenths[i] / 10;
            SeqAttacker a = _attacker();
            Before memory b = _snap(a);
            a.run(_steps1(0, w), 0); // tx1
            uint256 qAfterBuy = qpull.balanceOf(address(a));
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60);
            // tx2: largest exact-out sell that does not take the attacker below its pre-tx1 QPULL
            SeqAttacker.Step[] memory s2 = _steps1(3, 0);
            uint256 hi = w;
            uint256 lo;
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                uint256 snap = vm.snapshotState();
                s2[0].amount = mid;
                (bool ok,) = address(a).call(abi.encodeCall(SeqAttacker.run, (s2, 0)));
                bool flat = ok && qpull.balanceOf(address(a)) >= b.q;
                vm.revertToState(snap);
                if (flat) lo = mid;
                else hi = mid - 1;
            }
            s2[0].amount = lo;
            assertGt(qAfterBuy, b.q, "tx1 bought QPULL");
            a.run(s2, 0); // tx2
            Res memory r = _diff(a, b);
            _log(string.concat("split-tx A then D (next block), notional x0.1 depth = ", vm.toString(tenths[i])), r);
            _assertHard(r, w, true);
            vm.revertToState(s0);
        }
    }

    /// Whale buy and hold: exactly 4.00% of credit, to the wei (ceil).
    function test_splitTx_whaleBuyAndHold() public {
        _setAfterGateAndDecay();
        uint256 w = _depth();
        SeqAttacker a = _attacker();
        Res memory r = _exec(a, _steps1(0, w), 0);
        _log("whale exact-in buy of 1x depth, held", r);
        assertEq(r.sinkW, (w * 400 + 9999) / 10_000, "fee == ceil(4% of W)");
        assertEq(r.credit, w, "credit == W");
        assertEq(uint256(-r.wethPnl), w, "spent exactly W");
        assertEq(r.sinkQ, 0, "no QPULL fee");
        _assertHookFlat();
    }

    /// Buy on the canonical pool, exit UNTAXED on a hookless pool of equal depth (next block). Only the buy tax
    /// is paid, and it is still >= 4% of credit.
    function test_splitTx_untaxedExitOnHooklessPool() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth(); // one pool's depth, read before the second pool exists
        V4PoolKey memory raw = _openHookless();
        uint256[3] memory perMille = [uint256(1), 100, 1000]; // 0.001x, 0.1x, 1x depth
        for (uint256 i; i < 3; ++i) {
            uint256 s0 = vm.snapshotState();
            uint256 w = depth * perMille[i] / 1000;
            SeqAttacker a = _attacker(raw);
            Before memory b = _snap(a);
            a.run(_steps1(0, w), 0); // tx1, canonical
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60);
            SeqAttacker.Step[] memory s = new SeqAttacker.Step[](1);
            s[0] = SeqAttacker.Step(2, type(uint256).max, true, false); // tx2: sell everything on the hookless pool
            a.run(s, 0);
            Res memory r = _diff(a, b);
            _log(string.concat("buy canonical, sell hookless (untaxed exit), per-mille depth = ", vm.toString(perMille[i])), r);
            assertEq(r.qNet, 0, "exactly QPULL-flat");
            _assertHard(r, w, false);
            vm.revertToState(s0);
        }
    }

    /// 3(d) Backrun. tx1: an honest actor sells 0.5x depth of QPULL. tx2: the attacker buys W. tx3: the attacker
    /// sells everything back. The attacker's PnL may be POSITIVE (it is exogenous flow, not the hook), so the
    /// assertion is on tax per credit: the credited swap pays >= 4% of its credit in WETH (H2), is credited
    /// exactly its spend (H4), nothing ever pays QPULL (H3), and the sell credits nothing.
    function test_splitTx_backrun() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256[3] memory tenths = [uint256(1), 5, 10]; // W = 0.1x / 0.5x / 1x depth
        for (uint256 i; i < 3; ++i) {
            uint256 s0 = vm.snapshotState();
            uint256 w = depth * tenths[i] / 10;
            // tx1: honest exact-in sell of 0.5x depth QPULL
            vm.prank(alice, alice);
            swapRouter.swap(
                key,
                IV4PoolManager.SwapParams(qpullIs0, -int256(depth / 2), qpullIs0 ? MIN_PRICE_P1 : MAX_PRICE_M1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60);

            SeqAttacker a = _attacker();
            Before memory b = _snap(a);
            a.run(_steps1(0, w), 0); // tx2: backrun buy
            uint256 fee2 = weth.balanceOf(feeSink) - b.sinkW;
            uint256 credit2 = packRec.totalGross() - b.gross;
            assertEq(credit2, w, "H4: backrun buy credited exactly its spend");
            assertGe(fee2 * 10_000, 400 * credit2, "H2: the credited swap paid >= 4% of its credit");
            assertEq(qpull.balanceOf(feeSink), b.sinkQ, "H3: no QPULL fee");
            _assertHookFlat();

            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60);
            SeqAttacker.Step[] memory sell = _steps1(2, type(uint256).max);
            a.run(sell, 0); // tx3: sell it all back
            Res memory r = _diff(a, b);
            _log(string.concat("backrun: honest 0.5x sell, attacker buys then sells, W x0.1 depth = ", vm.toString(tenths[i])), r);
            assertEq(r.qNet, 0, "attacker ends QPULL-flat");
            assertEq(r.credit, w, "the sell credits nothing");
            assertEq(r.calls, 1, "one credited swap");
            assertGe(r.sinkW * 10_000, 400 * r.credit, "H2 over the whole backrun");
            assertEq(r.sinkQ, 0, "H3");
            _assertHookFlat();
            vm.revertToState(s0);
        }
    }

    /// 1. The atomic wash sized by PRICE IMPACT instead of depth multiples: an exact-in buy that takes fraction i of
    /// the pool's QPULL (W = D * i / (1 - i), ignoring fees) for i = 0.5 / 0.9 / 0.99, then an exact-out sell to
    /// QPULL-flat. Same H1-H5 and 780 bps band. The 0.99 row's fees exceed the manager's WETH, so its float is
    /// pre-settled at the notional (as in the 100x depth row).
    function test_atomicWash_priceImpactSizing() public {
        _setAfterGateAndDecay();
        uint256 depth = _depth();
        uint256[3] memory permille = [uint256(500), 900, 990];
        for (uint256 i; i < 3; ++i) {
            uint256 s0 = vm.snapshotState();
            uint256 w = depth * permille[i] / (1000 - permille[i]);
            uint256 pre = permille[i] >= 990 ? w : 0;
            SeqAttacker a = _attacker();
            SeqAttacker.Step[] memory s = _steps2(0, w, 3, 0);
            assertGt(_maxFlat(a, s, 1, w, pre), 0, "a flat exact-out sell exists");
            Res memory r = _exec(a, s, pre);
            _log(string.concat("atomic A+D wash, price impact per-mille = ", vm.toString(permille[i])), r);
            assertEq(r.calls, 1, "exactly one credited buy");
            _assertHard(r, w, true);
            vm.revertToState(s0);
        }
    }

    // ─── 2(e). any sequence, one transaction ───────────────────────────────────────────────────────

    /// 1-8 steps drawn from {A, B, C, D} x size in [1e15, 50 * D] (log-uniform) x limit in {sentinel, binding},
    /// split over 1-3 unlocks inside ONE external call, at a random launch-window time (sell step 0..3 or flat),
    /// with a random pre-settled WETH float. One A step in four is EXTREME instead: 2**127 (must revert SwapTooLarge),
    /// 2000 * D (its 4% fee exceeds the manager's WETH under any float) or 30 * D (float-dependent). Both token orders
    /// (WashCreditFlippedTest).
    /// - A run that reverts must revert with exactly: PartialFill (only if an A or D step had a binding limit),
    ///   SwapTooLarge, or the take-balance shortfall. Nothing else, and nothing is kept.
    /// - A run that settles NET LONG is liquidated UNTAXED through the exempt adapter and the proceeds counted.
    /// - A run that settles NET SHORT is closed, not discarded: the attacker buys the shortfall back UNTAXED with an
    ///   exact-out buy on a hookless MIRROR of the canonical pool's post-run state (same sqrtPrice, same liquidity,
    ///   full range), which is exactly what an untaxed buy-back on the canonical curve would cost, and that cost is
    ///   counted. Only if the mirror cannot pay the shortfall out (the curve's QPULL reserve is below it, which needs
    ///   ~333 * D of sell volume) is the run left unassessed.
    /// Then H1 with slack (cost * 1e4 + swaps >= 400 * credit), H2, H3, H4 per credited swap (credit == WETH that
    /// swap paid), H5 after every swap (in the attacker) and at the end.
    /// forge-config: ci.fuzz.runs = 5000
    function testFuzz_anySequenceOneTx(uint256 seed) public virtual {
        vm.assume(_anySequence(seed) != SEQ_NET_SHORT); // only the unclosable-short case is skipped
    }

    uint8 constant SEQ_ASSERTED = 0; // settled flat or net long, H1-H5 asserted
    uint8 constant SEQ_PARTIAL_FILL = 1; // reverted PartialFill (allowed)
    uint8 constant SEQ_SWAP_TOO_LARGE = 2; // reverted SwapTooLarge (allowed)
    uint8 constant SEQ_TAKE_SHORTFALL = 3; // reverted: manager could not fund the fee take (allowed)
    uint8 constant SEQ_SHORT_CLOSED = 4; // settled net short, closed on the hookless mirror, H1-H5 asserted
    uint8 constant SEQ_NET_SHORT = 5; // settled net short and the mirror could not close it: not assessed

    /// The fuzz's generator is only as good as what it reaches. Run it over 64 fixed seeds and require that it
    /// reaches EVERY outcome the fuzz accepts, in this token order, that at least half the runs are asserted, and that
    /// no run goes unassessed.
    function test_anySequence_generatorReachesEveryOutcome() public {
        uint256[6] memory seen;
        for (uint256 seed; seed < 64; ++seed) {
            uint256 snap = vm.snapshotState();
            ++seen[_anySequence(seed)];
            vm.revertToState(snap);
        }
        emit log_named_uint("settled + asserted  ", seen[SEQ_ASSERTED]);
        emit log_named_uint("short closed+asserted", seen[SEQ_SHORT_CLOSED]);
        emit log_named_uint("reverted PartialFill", seen[SEQ_PARTIAL_FILL]);
        emit log_named_uint("reverted SwapTooLarge", seen[SEQ_SWAP_TOO_LARGE]);
        emit log_named_uint("reverted take short ", seen[SEQ_TAKE_SHORTFALL]);
        emit log_named_uint("net short (skipped) ", seen[SEQ_NET_SHORT]);
        assertGe(seen[SEQ_ASSERTED] + seen[SEQ_SHORT_CLOSED], 32, "at least half the runs reach the H1-H5 asserts");
        assertGt(seen[SEQ_ASSERTED], 0, "the generator reaches a flat/long settled run");
        assertGt(seen[SEQ_SHORT_CLOSED], 0, "the generator reaches a closed net-short run");
        assertGt(seen[SEQ_PARTIAL_FILL], 0, "the generator reaches an allowed PartialFill");
        assertGt(seen[SEQ_SWAP_TOO_LARGE], 0, "the generator reaches an allowed SwapTooLarge");
        assertGt(seen[SEQ_TAKE_SHORTFALL], 0, "the generator reaches an allowed take shortfall");
        assertEq(seen[SEQ_NET_SHORT], 0, "no run is left unassessed");
    }

    function _anySequence(uint256 seed) internal returns (uint8 outcome) {
        uint256 depth = _depth();
        uint256 r = uint256(keccak256(abi.encode(seed)));
        vm.warp(hook.launchTime() + hook.GATE_DURATION() + 1 + (r % 5) * hook.SELL_STEP());

        r = uint256(keccak256(abi.encode(r)));
        uint256 nSteps = 1 + r % 8;
        uint256 breaks = (r >> 8) % 3; // 0..2 BRKs -> 1..3 unlocks
        uint256[3] memory floats = [uint256(0), depth, 60 * depth];
        uint256 pre = floats[(r >> 16) % 3];
        bool[8] memory brkAfter;
        for (uint256 j; j < breaks; ++j) {
            brkAfter[(r >> (24 + 8 * j)) % nSteps] = true;
        }
        uint256 len = nSteps;
        for (uint256 j; j < nSteps; ++j) {
            if (brkAfter[j]) ++len;
        }
        SeqAttacker.Step[] memory s = new SeqAttacker.Step[](len);
        bool bindingAD;
        uint256 at;
        for (uint256 j; j < nSteps; ++j) {
            r = uint256(keccak256(abi.encode(r, j)));
            uint8 kind = uint8(r % 4);
            uint256 unit = uint256(1e15) << ((r >> 8) % 36);
            uint256 size = unit + (r >> 64) % unit;
            if (size > 50 * depth) size = 50 * depth;
            // extreme exact-in buys, so the allowed reverts are reachable: 2**127 -> SwapTooLarge in beforeSwap;
            // 2000 * D -> an 80 * D fee, more WETH than the manager holds under any float drawn above; 30 * D -> a
            // 1.2 * D fee, which settles or falls short depending on that float
            if (kind == 0 && (r >> 32) % 4 == 0) {
                uint256 e = (r >> 40) % 3;
                size = e == 0 ? uint256(1) << 127 : (e == 1 ? 2000 * depth : 30 * depth);
            }
            bool binding = (r >> 16) % 2 == 1;
            if (binding && (kind == 0 || kind == 3)) bindingAD = true;
            s[at++] = SeqAttacker.Step(kind, size, false, binding);
            if (brkAfter[j]) s[at++] = SeqAttacker.Step(4, 0, false, false);
        }

        V4PoolKey memory mirror = key;
        mirror.hooks = IV4Hooks(address(0)); // created only if the run ends net short (_closeShortOnMirror)
        SeqAttacker a = _attacker(mirror);
        a.setClipExactOut(true);
        a.setObservers(address(packRec), feeSink);
        Before memory b = _snap(a);
        (bool ok, bytes memory ret) = address(a).call(abi.encodeCall(SeqAttacker.run, (s, pre)));
        if (!ok) {
            outcome = _assertAllowedSequenceRevert(ret, bindingAD);
            assertEq(weth.balanceOf(feeSink), b.sinkW, "reverted run keeps no WETH fee");
            assertEq(packRec.calls(), b.calls, "reverted run credits nothing");
            return outcome;
        }

        int256 qNet = int256(qpull.balanceOf(address(a))) - int256(b.q);
        outcome = SEQ_ASSERTED;
        uint256 slack = nSteps;
        if (qNet < 0) {
            uint256 obsBefore = a.obsCount();
            if (!_closeShortOnMirror(a, uint256(-qNet))) return SEQ_NET_SHORT;
            assertEq(a.obsCount(), obsBefore, "the untaxed close is not a taxed step");
            outcome = SEQ_SHORT_CLOSED;
            slack = nSteps + 1;
        } else if (qNet > 0) {
            _liquidateExempt(a, uint256(qNet));
        }

        Res memory res = _diff(a, b);
        assertEq(res.qNet, 0, "flat after exempt liquidation or mirror close");
        assertGe(
            -res.wethPnl * 10_000 + int256(slack), int256(400 * res.credit), "H1: cost >= 4% of credit (slack: swaps)"
        );
        assertGe(res.sinkW * 10_000, 400 * res.credit, "H2: treasury WETH >= 4% of credit");
        assertEq(res.sinkQ, 0, "H3: no QPULL ever reaches the treasury");
        uint256 feeSum;
        uint256 creditSum;
        for (uint256 j; j < a.obsCount(); ++j) {
            SeqAttacker.Obs memory o = a.obs(j);
            feeSum += o.fee;
            creditSum += o.credit;
            assertEq(o.feeQpull, 0, "H3 per swap");
            assertGe(o.fee * 10_000, 400 * o.credit, "H2 per swap");
            if (o.kind == 0 || o.kind == 1) {
                assertLe(o.credit, o.paid, "H4: credit <= WETH that swap paid");
                assertEq(o.credit, o.paid, "H4 (tight): ceil fees never let the min bind");
            } else {
                assertEq(o.credit, 0, "sells credit nothing");
            }
        }
        assertEq(a.obsCount(), nSteps, "every step observed");
        assertEq(feeSum, res.sinkW, "every wei of treasury WETH is attributable to a swap");
        assertEq(creditSum, res.credit, "every wei of credit is attributable to a buy");
        _assertHookFlat();
        return outcome;
    }

    /// Closes a net-short run: opens a hookless pool mirroring the canonical pool's post-run state (same sqrtPrice,
    /// same full-range liquidity) and has the attacker buy exactly `short` QPULL back on it, exact-out, untaxed, paying
    /// WETH it keeps on its books. Returns false only if that buy-back cannot settle.
    function _closeShortOnMirror(SeqAttacker a, uint256 short) internal returns (bool closed) {
        IV4PoolManager pm = IV4PoolManager(address(manager));
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        uint128 liq = pm.getLiquidity(key.toId());
        V4PoolKey memory mirror = key;
        mirror.hooks = IV4Hooks(address(0));
        qpull.mint(address(this), BUF);
        weth.mint(address(this), BUF);
        _initializePool(mirror, sqrtP);
        _addLiquidity(mirror, FULL_LO, FULL_HI, liq);
        a.setObservers(address(0), address(0)); // the close is not a taxed step: keep it out of the per-swap H2/H4
        a.setClipExactOut(false);
        uint256 creditBefore = packRec.totalGross();
        uint256 sinkBefore = weth.balanceOf(feeSink);
        SeqAttacker.Step[] memory s = new SeqAttacker.Step[](1);
        s[0] = SeqAttacker.Step(1, short, true, false); // exact-out buy of the shortfall on the mirror (alt) pool
        (closed,) = address(a).call(abi.encodeCall(SeqAttacker.run, (s, 0)));
        if (closed) {
            assertEq(packRec.totalGross(), creditBefore, "the mirror close credits nothing");
            assertEq(weth.balanceOf(feeSink), sinkBefore, "the mirror close pays no tax");
        }
    }

    /// The only reverts the any-sequence fuzz accepts, each wrapped by v4 at the hook callback that raised it.
    function _assertAllowedSequenceRevert(bytes memory ret, bool bindingAD) internal returns (uint8) {
        if (bytes4(ret) != CustomRevert.WrappedError.selector) {
            emit log_named_bytes("unexpected revert", ret);
            revert("any-sequence: a revert that is not PartialFill, SwapTooLarge or the take shortfall");
        }
        (address target, bytes4 fn, bytes memory reason,) = abi.decode(_strip4(ret), (address, bytes4, bytes, bytes));
        assertEq(target, hookAddr, "raised by the hook");
        if (keccak256(reason) == keccak256(abi.encodeWithSelector(QpullTaxHook.PartialFill.selector))) {
            assertEq(fn, IV4Hooks.afterSwap.selector, "PartialFill comes from afterSwap");
            assertTrue(bindingAD, "PartialFill only when an A or D step had a binding limit");
            return SEQ_PARTIAL_FILL;
        }
        if (keccak256(reason) == keccak256(abi.encodeWithSelector(QpullTaxHook.SwapTooLarge.selector))) {
            assertEq(fn, IV4Hooks.beforeSwap.selector, "SwapTooLarge comes from beforeSwap");
            return SEQ_SWAP_TOO_LARGE;
        }
        _assertTakeShortfall(ret);
        return SEQ_TAKE_SHORTFALL;
    }

    /// Sell `q` QPULL of the attacker's through the Treasury's EXEMPT adapter (no tax, no records) back to it.
    function _liquidateExempt(SeqAttacker a, uint256 q) internal {
        if (!adapter.poolKeySet()) adapter.setPoolKey(_ourKey());
        vm.prank(address(a));
        qpull.transfer(treasury, q);
        uint256 sink = weth.balanceOf(feeSink);
        uint256 calls = packRec.calls();
        vm.startPrank(treasury, treasury);
        qpull.approve(address(adapter), q);
        adapter.swapExactIn(address(qpull), address(weth), q, 1, address(a));
        vm.stopPrank();
        assertEq(weth.balanceOf(feeSink), sink, "exempt liquidation pays no fee");
        assertEq(packRec.calls(), calls, "exempt liquidation records nothing");
    }

    // ─── 4. honest trade ──────────────────────────────────────────────────────────────────────────

    /// An honest small buy pays exactly ceil(4%) of its credit, in WETH, and its credit is exactly its spend.
    function test_honestBuyPaysFourPercent() public {
        _setAfterGateAndDecay();
        uint256 w = _depth() / 1000;
        uint256 sinkW = weth.balanceOf(feeSink);
        uint256 sinkQ = qpull.balanceOf(feeSink);
        uint256 wBefore = weth.balanceOf(alice);
        vm.prank(alice, alice);
        swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(!qpullIs0, -int256(w), !qpullIs0 ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 feeW = weth.balanceOf(feeSink) - sinkW;
        emit log_named_uint("honest spend (wei)   ", wBefore - weth.balanceOf(alice));
        emit log_named_uint("honest credit (wei)  ", packRec.lastGross());
        emit log_named_uint("honest tax, WETH wei ", feeW);
        emit log_named_uint("tax / credit (bps)   ", feeW * 10_000 / packRec.lastGross());
        assertEq(wBefore - weth.balanceOf(alice), w, "spent exactly w");
        assertEq(packRec.lastGross(), w, "credit == ETH spent, to the wei");
        assertEq(feeW, (w * 400 + 9999) / 10_000, "fee == ceil(4% of w)");
        assertEq(qpull.balanceOf(feeSink) - sinkQ, 0, "no QPULL fee");
        _assertHookFlat();
    }
}

/// @dev The whole wash-credit suite with QPULL and WETH in the opposite address order.
contract WashCreditFlippedTest is WashCreditTest {
    function _flipTokenOrder() internal pure override returns (bool) {
        return true;
    }

    /// Re-declared only so the ci run count applies here too (inline config does not follow inheritance).
    /// forge-config: ci.fuzz.runs = 5000
    function testFuzz_anySequenceOneTx(uint256 seed) public override {
        super.testFuzz_anySequenceOneTx(seed);
    }
}
