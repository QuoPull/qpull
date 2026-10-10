// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { NonceAwareDeploy } from "./utils/NonceAwareDeploy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { PoolKey } from "../src/interfaces/IPoolManager.sol";
import { V4LpBase } from "./utils/V4LpBase.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

interface IWethT {
    function deposit() external payable;
}

/// A QPULL stand-in that can charge a 1% fee on every transfer (off while the pool is seeded).
contract FeeOnTransferToken is ERC20 {
    bool public feeOn;

    constructor(uint256 supply, address to) ERC20("FoT", "FOT") {
        _mint(to, supply);
    }

    function setFeeOn(bool v) external {
        feeOn = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0)) {
            uint256 f = value / 100;
            super._update(from, address(0xFEE), f);
            value -= f;
        }
        super._update(from, to, value);
    }
}

/// Answers the router's constructor reads with chosen values (a hook that is not QpullTaxHook).
contract FakeHookBinding {
    address public poolManager;
    address public qpull;
    address public weth;
    uint24 public canonicalFee;
    int24 public canonicalTickSpacing;
    address public exemptSender;
    uint160 public REQUIRED_FLAGS;
    bool internal canonical;

    constructor(address pm, address q, address w, uint24 f, int24 ts, address ex, uint160 flags, bool can) {
        (poolManager, qpull, weth, canonicalFee, canonicalTickSpacing, exemptSender, REQUIRED_FLAGS, canonical) =
            (pm, q, w, f, ts, ex, flags, can);
    }

    function isCanonical(PoolKey calldata) external view returns (bool) {
        return canonical;
    }
}

/// A seller contract whose receive() tries to re-enter the router, records what stopped it, and keeps the ETH.
contract ReenteringSeller {
    QpullSwapRouter public immutable router;
    IERC20 public immutable qpull;
    uint8 public mode; // 1 re-enter buy, 2 re-enter sell, 3 call unlockCallback, 4 refuse ETH
    bytes4 public caught;
    uint256 public received;

    constructor(QpullSwapRouter r, IERC20 q) {
        router = r;
        qpull = q;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function sell(uint256 amt) external returns (uint256) {
        qpull.approve(address(router), amt);
        return router.sell(amt, 1, block.timestamp);
    }

    receive() external payable {
        if (mode == 4) revert("no ETH");
        received += msg.value;
        bytes memory err;
        if (mode == 1) {
            try router.buy{ value: msg.value }(1, block.timestamp) { } catch (bytes memory e) { err = e; }
        } else if (mode == 2) {
            try router.sell(1, 1, block.timestamp) { } catch (bytes memory e) { err = e; }
        } else if (mode == 3) {
            try router.unlockCallback(abi.encode(true, address(this), uint256(1))) { } catch (bytes memory e) { err = e; }
        }
        if (err.length >= 4) caught = bytes4(err);
    }
}

/// @notice QpullSwapRouter (the site's own swap router) against the real vendored v4 PoolManager, the real QpullTaxHook
///         (0x1ACC), the real PackRegistry and LeaderboardRegistry, the real QPULLToken and a WETH9-shaped MockWETH.
///         Every requirement is asserted in BOTH token orders (the two concrete contracts at the bottom).
abstract contract QpullSwapRouterFixture is NonceAwareDeploy, V4LpBase {
    uint160 constant FLAGS = 0x1ACC;
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 constant TP = 0.003 ether; // mainnet ticket price
    uint256 constant CAP = 0.25 ether; // mainnet EARLY_BUY_CAP_WEI
    uint256 constant SUPPLY = 1_000_000_000e18;
    address constant LOW = 0xA0000000000000000000000000000000000000a1;
    address constant HIGH = 0xB0000000000000000000000000000000000000B2;

    PoolManager manager;
    IERC20 qpull;
    MockWETH weth;
    MockNFT passes;
    PackRegistry packs;
    LeaderboardRegistry board;
    QpullSwapRouter router;
    address hookAddr;
    V4PoolKey key;

    address treasury = makeAddr("treasury");
    address exempt = makeAddr("exemptAdapter");
    address alice = makeAddr("alice"); // pass holder
    address bob = makeAddr("bob"); // no pass
    address stranger = makeAddr("stranger");

    function _qpullIsCurrency0() internal pure virtual returns (bool);

    /// The QPULL implementation (overridden by the fee-on-transfer suite).
    function _deployQpull(address at) internal virtual {
        deployCodeTo("QPULLToken.sol:QPULLToken", abi.encode(SUPPLY, address(this)), at);
    }

    /// Liquidity range (overridden by the partial-fill suite).
    function _range() internal pure virtual returns (int24 lo, int24 hi, uint256 liq) {
        return (-887_220, 887_220, 1e24);
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager)));
        (address qAt, address wAt) = _qpullIsCurrency0() ? (LOW, HIGH) : (HIGH, LOW);
        _deployQpull(qAt);
        qpull = IERC20(qAt);
        deployCodeTo("MockWETH.sol:MockWETH", wAt);
        weth = MockWETH(payable(wAt));
        passes = new MockNFT();
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        packs = new PackRegistry(address(oracle), TP, block.timestamp, 1 hours, address(this));
        board = new LeaderboardRegistry(block.timestamp, address(this));
        hookAddr = address(uint160((0x5A1E << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: qAt,
                    weth: wAt,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: treasury,
                    packRegistry: address(packs),
                    leaderboardRegistry: address(board),
                    nft: address(passes),
                    exemptSender: exempt,
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
            hookAddr
        );
        packs.setRecorder(hookAddr);
        board.setRecorder(hookAddr);
        key = V4PoolKey({
            currency0: V4Currency.wrap(_qpullIsCurrency0() ? qAt : wAt),
            currency1: V4Currency.wrap(_qpullIsCurrency0() ? wAt : qAt),
            fee: 3000,
            tickSpacing: 60,
            hooks: IV4Hooks(hookAddr)
        });
        vm.deal(address(this), 1e25);
        weth.deposit{ value: 1e25 }();
        _initializePool(key, SQRT_1_1); // launchTime: the 1-hour gate opens now
        (int24 lo, int24 hi, uint256 liq) = _range();
        _addLiquidity(key, lo, hi, liq);
        router = new QpullSwapRouter(address(manager), wAt, qAt, hookAddr, 3000, 60);
        passes.set(1, alice, 0);
        assertEq(router.wethIsCurrency0(), !_qpullIsCurrency0(), "premise: the order under test");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────────────────────

    function _pastGate() internal {
        vm.warp(QpullTaxHook(hookAddr).launchTime() + QpullTaxHook(hookAddr).GATE_DURATION());
    }

    function _buy(address who, uint256 value, uint256 minOut) internal returns (uint256) {
        vm.deal(who, who.balance + value);
        vm.prank(who, who);
        return router.buy{ value: value }(minOut, block.timestamp);
    }

    function _giveQpull(address who, uint256 amt) internal {
        qpull.transfer(who, amt);
        vm.prank(who);
        qpull.approve(address(router), amt);
    }

    function _sell(address who, uint256 amt, uint256 minOut) internal returns (uint256) {
        vm.prank(who, who);
        return router.sell(amt, minOut, block.timestamp);
    }

    function _assertRouterEmpty(string memory tag) internal view {
        assertEq(address(router).balance, 0, string.concat(tag, ": router ETH"));
        assertEq(weth.balanceOf(address(router)), 0, string.concat(tag, ": router WETH"));
        assertEq(qpull.balanceOf(address(router)), 0, string.concat(tag, ": router QPULL"));
        assertEq(weth.allowance(address(router), address(manager)), 0, string.concat(tag, ": router WETH approval"));
        assertEq(qpull.allowance(address(router), address(manager)), 0, string.concat(tag, ": router QPULL approval"));
    }

    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hookAddr,
            IV4Hooks.afterSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _ceilBps(uint256 x, uint256 bps) internal pure returns (uint256) {
        return (x * bps + 9999) / 10_000;
    }

}

/// @notice The requirement tests, run once per token order.
abstract contract QpullSwapRouterBase is QpullSwapRouterFixture {
    // ── buy ──────────────────────────────────────────────────────────────────────────────────────────────────

    /// ETH in, QPULL to the caller, the 4% fee to the Treasury as WETH, packs and points to tx.origin, nothing left.
    function test_buy_ethIn_qpullOut_taxedInWeth_packsToTxOrigin_routerEmpty() public {
        _pastGate();
        uint256 id0 = packs.nextPackId();
        uint256 t0 = weth.balanceOf(treasury);
        uint256 out = _buy(bob, 0.01 ether, 1);

        assertGt(out, 0, "QPULL out");
        assertEq(qpull.balanceOf(bob), out, "the return value is what the caller received");
        assertEq(bob.balance, 0, "all the ETH was spent");
        assertEq(weth.balanceOf(treasury) - t0, _ceilBps(0.01 ether, 400), "TAXED: 4% of the ETH in, as WETH");
        assertEq(packs.nextPackId() - id0, 3, "0.01 ETH at 0.003 ETH: 3 packs");
        (address owner,,,) = packs.packs(id0);
        assertEq(owner, bob, "packs minted to tx.origin");
        assertEq(packs.bankedRemainder(bob), 0.001 ether, "remainder banked to tx.origin");
        assertEq(board.points(0, bob), 0.01 ether, "points credited to tx.origin, equal to the ETH spent");
        _assertRouterEmpty("buy");
    }

    /// A contract caller receives the QPULL; the credit goes to the signer (tx.origin), exactly as the hook defines it.
    function test_buy_fromContractWallet_outputToMsgSender_creditToTxOrigin() public {
        _pastGate();
        address wallet = makeAddr("smartWallet");
        vm.etch(wallet, hex"00"); // has code: not the signer
        vm.deal(wallet, 0.01 ether);
        uint256 id0 = packs.nextPackId();
        vm.prank(wallet, alice);
        uint256 out = router.buy{ value: 0.01 ether }(1, block.timestamp);
        assertEq(qpull.balanceOf(wallet), out, "QPULL to msg.sender");
        assertEq(qpull.balanceOf(alice), 0, "not to the signer");
        (address owner,,,) = packs.packs(id0);
        assertEq(owner, alice, "packs to tx.origin");
        assertEq(board.points(0, alice), 0.01 ether, "points to tx.origin");
        assertEq(board.points(0, wallet), 0, "none to the wallet");
        _assertRouterEmpty("contract buy");
    }

    // ── sell ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// QPULL in, ETH to the caller, the launch sell fee (20% in step 0) to the Treasury as WETH, allowance consumed.
    function test_sell_qpullIn_ethOut_taxedInWeth_allowanceConsumed_routerEmpty() public {
        _pastGate(); // 1h after launch: still sell-tax step 0 (20%)
        _giveQpull(bob, 1000e18);
        uint256 t0 = weth.balanceOf(treasury);
        uint256 ethOut = _sell(bob, 1000e18, 1);
        uint256 fee = weth.balanceOf(treasury) - t0;

        assertGt(ethOut, 0, "ETH out");
        assertEq(bob.balance, ethOut, "the return value is the ETH the caller received");
        assertEq(qpull.balanceOf(bob), 0, "exactly qpullIn left the caller");
        assertEq(qpull.allowance(bob, address(router)), 0, "an exact approval is fully consumed");
        assertGt(fee, 0, "TAXED");
        assertEq(fee, ((ethOut + fee) * 2000) / 10_000, "fee = floor(20% of the pool's WETH out)");
        _assertRouterEmpty("sell");
    }

    // ── deadline and slippage ────────────────────────────────────────────────────────────────────────────────

    function test_deadline_enforced_inclusive() public {
        _pastGate();
        vm.deal(bob, 1 ether);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.Expired.selector);
        router.buy{ value: 0.01 ether }(1, block.timestamp - 1);
        _giveQpull(bob, 10e18);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.Expired.selector);
        router.sell(10e18, 1, block.timestamp - 1);
        // deadline == now executes
        vm.prank(bob, bob);
        router.buy{ value: 0.01 ether }(1, block.timestamp);
        vm.prank(bob, bob);
        router.sell(10e18, 1, block.timestamp);
    }

    function test_slippage_buy_onTheAmountReceived() public {
        _pastGate();
        uint256 snap = vm.snapshotState();
        uint256 q = _buy(bob, 0.05 ether, 1);
        vm.revertToState(snap);
        vm.deal(bob, 0.05 ether);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.Slippage.selector);
        router.buy{ value: 0.05 ether }(q + 1, block.timestamp);
        assertEq(_buy(bob, 0.05 ether, q), q, "a floor of exactly the output passes");
        assertEq(qpull.balanceOf(bob), q, "and the caller holds it");
    }

    function test_slippage_sell_onTheEthReceived() public {
        _pastGate();
        _giveQpull(bob, 500e18);
        uint256 snap = vm.snapshotState();
        uint256 q = _sell(bob, 500e18, 1);
        vm.revertToState(snap);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.Slippage.selector);
        router.sell(500e18, q + 1, block.timestamp);
        assertEq(_sell(bob, 500e18, q), q, "a floor of exactly the output passes");
        assertEq(bob.balance, q, "and the caller holds it");
    }

    function test_zeroAmounts_zeroFloors_andOversize_refused() public {
        _pastGate();
        vm.deal(bob, 1 ether);
        vm.startPrank(bob, bob);
        vm.expectRevert(QpullSwapRouter.ZeroAmount.selector);
        router.buy{ value: 0 }(1, block.timestamp);
        vm.expectRevert(QpullSwapRouter.ZeroMinOut.selector);
        router.buy{ value: 0.01 ether }(0, block.timestamp);
        vm.expectRevert(QpullSwapRouter.ZeroAmount.selector);
        router.sell(0, 1, block.timestamp);
        vm.expectRevert(QpullSwapRouter.ZeroMinOut.selector);
        router.sell(1e18, 0, block.timestamp);
        vm.expectRevert(QpullSwapRouter.SwapTooLarge.selector);
        router.sell(uint256(uint128(type(int128).max)) + 1, 1, block.timestamp);
        vm.stopPrank();
        assertEq(bytes4(keccak256("SwapTooLarge()")), QpullTaxHook.SwapTooLarge.selector, "shares the hook's selector");
        assertEq(bytes4(keccak256("PartialFill()")), QpullTaxHook.PartialFill.selector, "shares the hook's selector");
    }

    // ── the gate and the hook's errors ───────────────────────────────────────────────────────────────────────

    /// Inside the 1-hour gate a pass holder buys through the router; a non-holder reverts Gated, surfaced as the
    /// PoolManager's WrappedError byte-for-byte; the throttle errors surface the same way; after the gate anyone buys.
    function test_gate_holderBuys_nonHolderGated_throttleWrapped_thenOpen() public {
        uint256 id0 = packs.nextPackId();
        _buy(alice, 0.01 ether, 1);
        (address owner,,,) = packs.packs(id0);
        assertEq(owner, alice, "holder's packs to tx.origin inside the gate");
        (, uint32 buys,) = QpullTaxHook(hookAddr).earlyBuyer(alice);
        assertEq(buys, 1, "the throttle keys on tx.origin");

        vm.deal(bob, 0.01 ether);
        vm.prank(bob, bob);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(QpullTaxHook.Gated.selector)));
        router.buy{ value: 0.01 ether }(1, block.timestamp);

        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(QpullTaxHook.BuyCooldown.selector)));
        router.buy{ value: 0.01 ether }(1, block.timestamp);

        address carol = makeAddr("carol");
        passes.set(2, carol, 0);
        vm.deal(carol, 1 ether);
        vm.prank(carol, carol);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(QpullTaxHook.EarlyBuyTooLarge.selector)));
        router.buy{ value: CAP + 1 }(1, block.timestamp);

        // A non-holder's EOA-signed buy through a holder's contract wallet is still gated on the signer.
        address holderWallet = makeAddr("holderWallet");
        passes.set(3, holderWallet, 0);
        vm.deal(holderWallet, 0.01 ether);
        vm.prank(holderWallet, bob);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(QpullTaxHook.Gated.selector)));
        router.buy{ value: 0.01 ether }(1, block.timestamp);

        _pastGate();
        assertGt(_buy(bob, 0.01 ether, 1), 0, "after the gate a non-holder buys");
        _assertRouterEmpty("gate");
    }

    // ── callback, receive, reentrancy ────────────────────────────────────────────────────────────────────────

    function test_unlockCallback_onlyPoolManager_onlyDuringOwnSwap() public {
        bytes memory data = abi.encode(true, bob, uint256(1e18));
        vm.prank(bob);
        vm.expectRevert(QpullSwapRouter.NotPoolManager.selector);
        router.unlockCallback(data);
        vm.prank(address(manager));
        vm.expectRevert(QpullSwapRouter.NotInSwap.selector);
        router.unlockCallback(data);
    }

    function test_receive_refusesEthFromAnythingButWeth() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(router).call{ value: 1 }("");
        assertFalse(ok, "a plain ETH send is refused");
        assertEq(bytes4(ret), QpullSwapRouter.NotWeth.selector, "NotWeth");
        assertEq(address(router).balance, 0, "nothing arrived");
    }

    /// The sell's ETH recipient re-entering buy, sell or the callback is stopped by the router; the outer sell still
    /// completes and pays out. A recipient that refuses ETH reverts its own sell, and nothing is stranded.
    function test_reentrancy_ethRecipient_blocked_andRefusalReverts() public {
        _pastGate();
        ReenteringSeller s = new ReenteringSeller(router, qpull);
        qpull.transfer(address(s), 3000e18);
        bytes4[3] memory want =
            [QpullSwapRouter.Reentrancy.selector, QpullSwapRouter.Reentrancy.selector, QpullSwapRouter.NotPoolManager.selector];
        for (uint8 m = 1; m <= 3; ++m) {
            s.setMode(m);
            uint256 bal0 = address(s).balance;
            vm.prank(address(s), address(s));
            uint256 out = s.sell(1000e18);
            assertEq(s.caught(), want[m - 1], "the reentrant call was refused by the router");
            assertEq(address(s).balance - bal0, out, "the outer sell still paid the recipient");
            _assertRouterEmpty("reentrancy");
        }
        s.setMode(4);
        qpull.transfer(address(s), 1000e18);
        uint256 q0 = qpull.balanceOf(address(s));
        vm.expectRevert(QpullSwapRouter.EthTransferFailed.selector);
        s.sell(1000e18);
        assertEq(qpull.balanceOf(address(s)), q0, "the refused sell moved no QPULL");
        _assertRouterEmpty("refusal");
    }

    // ── strays ───────────────────────────────────────────────────────────────────────────────────────────────

    function _dustRouter(uint256 eth, uint256 wethAmt, uint256 qpullAmt) internal {
        vm.deal(address(router), address(router).balance + eth); // ETH forced in (self-destruct / block reward shape)
        vm.deal(stranger, wethAmt);
        vm.prank(stranger);
        IWethT(address(weth)).deposit{ value: wethAmt }();
        vm.prank(stranger);
        weth.transfer(address(router), wethAmt);
        qpull.transfer(address(router), qpullAmt);
    }

    /// Force-sent ETH, WETH and QPULL never touch the swap (same output, same credit) and leave with the next buy,
    /// to that caller: QPULL as QPULL, ETH and WETH as WETH.
    function test_strays_buy_forwardedToCaller_swapAndCreditUnchanged() public {
        _pastGate();
        uint256 snap = vm.snapshotState();
        uint256 id0 = packs.nextPackId();
        uint256 base = _buy(bob, 0.02 ether, 1);
        uint256 basePacks = packs.nextPackId() - id0;
        vm.revertToState(snap);

        _dustRouter(5, 7, 11e18);
        vm.expectEmit(address(router));
        emit QpullSwapRouter.StraySwept(bob, 12, 11e18);
        uint256 out = _buy(bob, 0.02 ether, 1);
        assertEq(out, base, "the strays did not change the swap");
        assertEq(packs.nextPackId() - id0, basePacks, "nor the credit");
        assertEq(board.points(0, bob), 0.02 ether, "points are the ETH the caller spent, not the strays");
        assertEq(qpull.balanceOf(bob), out + 11e18, "stray QPULL forwarded");
        assertEq(weth.balanceOf(bob), 12, "stray ETH and WETH forwarded as WETH");
        _assertRouterEmpty("stray buy");
    }

    /// ...and with the next sell, as ETH (plus QPULL as QPULL).
    function test_strays_sell_forwardedToCaller_swapUnchanged() public {
        _pastGate();
        _giveQpull(bob, 800e18);
        uint256 snap = vm.snapshotState();
        uint256 base = _sell(bob, 800e18, 1);
        vm.revertToState(snap);

        _dustRouter(5, 7, 11e18);
        vm.expectEmit(address(router));
        emit QpullSwapRouter.StraySwept(bob, 12, 11e18);
        uint256 out = _sell(bob, 800e18, 1);
        assertEq(out, base, "the strays did not change the swap");
        assertEq(bob.balance, out + 12, "stray ETH and WETH forwarded as ETH");
        assertEq(qpull.balanceOf(bob), 11e18, "stray QPULL forwarded");
        _assertRouterEmpty("stray sell");
    }

    /// Fuzzed strays and amounts, both directions: the router always ends empty and the caller gets every stray.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_strays_routerAlwaysEndsEmpty(uint96 ethRaw, uint96 wethRaw, uint96 qpullRaw, uint64 buyWei) public {
        _pastGate();
        uint256 v = bound(uint256(buyWei), 1e15, 1 ether);
        uint256 eth = bound(uint256(ethRaw), 0, 1e24);
        uint256 wethAmt = bound(uint256(wethRaw), 0, 1e24);
        uint256 qpullAmt = bound(uint256(qpullRaw), 0, 1e23);
        _dustRouter(eth, wethAmt, qpullAmt);
        uint256 out = _buy(bob, v, 1);
        assertEq(qpull.balanceOf(bob), out + qpullAmt, "buy: QPULL out plus stray QPULL");
        assertEq(weth.balanceOf(bob), eth + wethAmt, "buy: stray ETH + WETH as WETH");
        _assertRouterEmpty("fuzz buy");

        _dustRouter(eth, wethAmt, qpullAmt);
        vm.prank(bob);
        qpull.approve(address(router), out);
        uint256 ethOut = _sell(bob, out, 1);
        assertEq(bob.balance, ethOut + eth + wethAmt, "sell: ETH out plus stray ETH + WETH as ETH");
        assertEq(qpull.balanceOf(bob), qpullAmt * 2, "sell: both stray QPULL amounts");
        _assertRouterEmpty("fuzz sell");
    }

    // ── construction ─────────────────────────────────────────────────────────────────────────────────────────

    function test_constructor_bindsOnlyTheCanonicalPool() public {
        address w = address(weth);
        address q = address(qpull);
        address pm = address(manager);
        vm.expectRevert(QpullSwapRouter.ZeroAddress.selector);
        new QpullSwapRouter(address(0), w, q, hookAddr, 3000, 60);
        vm.expectRevert(QpullSwapRouter.ZeroAddress.selector);
        new QpullSwapRouter(pm, w, q, address(0), 3000, 60);
        vm.expectRevert(QpullSwapRouter.NoCode.selector);
        new QpullSwapRouter(pm, w, q, makeAddr("codelessHook"), 3000, 60);
        vm.expectRevert(QpullSwapRouter.NoCode.selector);
        new QpullSwapRouter(makeAddr("codelessPm"), w, q, hookAddr, 3000, 60);

        address otherPm = address(new PoolManager(address(this)));
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(otherPm, w, q, hookAddr, 3000, 60);
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(pm, q, w, hookAddr, 3000, 60); // WETH and QPULL swapped
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(pm, w, address(passes), hookAddr, 3000, 60); // a different token
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(pm, w, q, hookAddr, 500, 60); // fee
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(pm, w, q, hookAddr, 3000, 10); // tick spacing

        // a binding that answers every read correctly but sits at an address without the hook's flags
        FakeHookBinding plain = new FakeHookBinding(pm, q, w, 3000, 60, exempt, FLAGS, true);
        vm.expectRevert(QpullSwapRouter.HookMismatch.selector);
        new QpullSwapRouter(pm, w, q, address(plain), 3000, 60);
        // ...at a flagged address, but refusing the key
        address flagged = address(uint160((0xBADD << 16) | FLAGS));
        deployCodeTo(
            "QpullSwapRouter.t.sol:FakeHookBinding", abi.encode(pm, q, w, uint24(3000), int24(60), exempt, FLAGS, false), flagged
        );
        vm.expectRevert(QpullSwapRouter.NotCanonicalPool.selector);
        new QpullSwapRouter(pm, w, q, flagged, 3000, 60);

        // the canonical one binds, and exposes the hook's own key
        QpullSwapRouter ok = new QpullSwapRouter(pm, w, q, hookAddr, 3000, 60);
        assertTrue(QpullTaxHook(hookAddr).isCanonical(ok.poolKey()), "the router's key is the hook's canonical key");
        // no owner and no admin surface: none of the usual selectors answers
        string[4] memory admin = ["owner()", "pendingOwner()", "transferOwnership(address)", "renounceOwnership()"];
        for (uint256 i; i < admin.length; ++i) {
            (bool answered,) = address(ok).call(abi.encodeWithSignature(admin[i], address(this)));
            assertFalse(answered, string.concat("no admin function: ", admin[i]));
        }
    }

    /// The router can never be the hook's untaxed exemptSender. A second hook for the same key names, as its exemptSender,
    /// the exact address the next router CREATE lands on; that router's constructor refuses.
    function test_constructor_refusesToBeTheExemptSender() public {
        address predicted = _predictCreateAfterDeployCodeTo(1);
        address hook2 = address(uint160((0x5A1F << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: treasury,
                    packRegistry: address(packs),
                    leaderboardRegistry: address(board),
                    nft: address(passes),
                    exemptSender: predicted,
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
            hook2
        );
        assertEq(QpullTaxHook(hook2).exemptSender(), predicted, "premise: the hook exempts the next CREATE");
        vm.expectRevert(QpullSwapRouter.RouterIsExempt.selector);
        new QpullSwapRouter(address(manager), address(weth), address(qpull), hook2, 3000, 60);
        // and the live router is not the live hook's exemptSender
        assertTrue(QpullTaxHook(hookAddr).exemptSender() != address(router), "the deployed router is taxed");
    }
}

contract QpullSwapRouterQpullIs0Test is QpullSwapRouterBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract QpullSwapRouterWethIs0Test is QpullSwapRouterBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice No partial fills: liquidity only in [-600, 600], so a large swap runs out of range before its input is used.
abstract contract QpullSwapRouterPartialFillBase is QpullSwapRouterFixture {
    function _range() internal pure override returns (int24, int24, uint256) {
        return (-600, 600, 1e21);
    }

    function test_partialFill_sell_revertsInTheRouter() public {
        _pastGate();
        _giveQpull(bob, 1_000_000e18);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.PartialFill.selector);
        router.sell(1_000_000e18, 1, block.timestamp);
        assertEq(qpull.balanceOf(bob), 1_000_000e18, "nothing moved");
        _assertRouterEmpty("partial sell");
    }

    function test_partialFill_buy_revertsInTheHook_wrapped() public {
        _pastGate();
        vm.deal(bob, 1_000_000 ether);
        vm.prank(bob, bob);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(QpullTaxHook.PartialFill.selector)));
        router.buy{ value: 1_000_000 ether }(1, block.timestamp);
        assertEq(bob.balance, 1_000_000 ether, "nothing moved");
        _assertRouterEmpty("partial buy");
    }
}

contract QpullSwapRouterPartialFillQpullIs0Test is QpullSwapRouterPartialFillBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract QpullSwapRouterPartialFillWethIs0Test is QpullSwapRouterPartialFillBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Fee-on-transfer: the router does not assume one. A buy's floor is checked against what actually reached the
///         caller, and a sell whose transfer into the PoolManager comes up short fails v4's settlement.
abstract contract QpullSwapRouterFeeOnTransferBase is QpullSwapRouterFixture {
    function _deployQpull(address at) internal override {
        deployCodeTo("QpullSwapRouter.t.sol:FeeOnTransferToken", abi.encode(SUPPLY, address(this)), at);
    }

    function test_feeOnTransfer_buyFloorIsWhatArrived_sellCannotSettleShort() public {
        _pastGate();
        uint256 snap = vm.snapshotState();
        uint256 gross = _buy(bob, 0.05 ether, 1); // fee off: what the pool pays
        vm.revertToState(snap);

        FeeOnTransferToken(address(qpull)).setFeeOn(true);
        vm.deal(bob, 0.05 ether);
        vm.prank(bob, bob);
        vm.expectRevert(QpullSwapRouter.Slippage.selector);
        router.buy{ value: 0.05 ether }(gross, block.timestamp); // the pool's figure is not what arrives
        uint256 got = _buy(bob, 0.05 ether, gross - gross / 100);
        assertEq(got, gross - gross / 100, "returns the amount that reached the caller");
        assertEq(qpull.balanceOf(bob), got, "and the caller holds exactly that");
        _assertRouterEmpty("fot buy");

        FeeOnTransferToken(address(qpull)).setFeeOn(false);
        _giveQpull(bob, 100e18);
        FeeOnTransferToken(address(qpull)).setFeeOn(true);
        vm.prank(bob, bob);
        vm.expectRevert(IV4PoolManager.CurrencyNotSettled.selector);
        router.sell(100e18, 1, block.timestamp);
        _assertRouterEmpty("fot sell");
    }
}

contract QpullSwapRouterFeeOnTransferQpullIs0Test is QpullSwapRouterFeeOnTransferBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract QpullSwapRouterFeeOnTransferWethIs0Test is QpullSwapRouterFeeOnTransferBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
