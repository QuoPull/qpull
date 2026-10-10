// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { QpullSwapRouter } from "../../src/periphery/QpullSwapRouter.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../../src/QpullLiquidityLock.sol";
import { PackRegistry } from "../../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../../src/LeaderboardRegistry.sol";
import { Treasury } from "../../src/Treasury.sol";
import { LaunchGuards } from "../../script/LaunchGuards.sol";
import { GoLiveHarness } from "../regression/GoLiveLpEthUnchecked.t.sol";

/// @notice QpullSwapRouter (the site's swap goes through this small router of our own), against RH MAINNET STATE
///         (read-only fork of 4663; nothing is broadcast).
///
///         The protocol is built on the fork against the LIVE WETH (a proxied WETH), the LIVE v4 PoolManager, the live
///         QUOTRON and Quotron's canonical ETH router, with the real QPULLToken, QpullTaxHook (0x1ACC), QpullLiquidityLock,
///         Treasury, vaults, adapters, PackRegistry, RaffleEngine, LeaderboardRegistry and a real NFTCollection raise
///         (test/regression LaunchWorld in fork mode). The pool is then seeded by the REAL GoLiveMainnet body: preflight,
///         caps, withdrawProceeds, funding, lock.seed, the on-chain asserts, both convert rehearsals through the live Quotron
///         router, and lockRouting. QpullSwapRouter is constructed exactly as Deploy.s.sol constructs it.
///
///         Then, through the router, in both token orders: inside the 1-hour gate a pass holder buys (packs minted to
///         tx.origin, the 4% tax arriving at the Treasury in WETH) and sells (the launch sell tax in WETH, ETH unwrapped
///         by the live WETH into the router's receive()), and a non-holder reverts Gated inside v4's WrappedError; after
///         the gate the non-holder buys and sells. The router holds no ETH, WETH or QPULL after any of it.
///         Deadlines read vm.getBlockTimestamp(): under via_ir a test function's `block.timestamp` can be a value cached
///         from before a vm.warp.
contract QpullSwapRouterForkTest is GoLiveHarness {
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    QpullSwapRouter router;
    PackRegistry packsR;
    LeaderboardRegistry boardR;

    function _launchOnFork(address qpullAt) internal {
        vm.createSelectFork(RPC);
        assertEq(block.chainid, 4663, "RH mainnet fork");
        Opts memory o = _opts(qpullAt);
        o.realExternals = true;
        _deploy(o);
        assertEq(pm, LaunchGuards.RH_POOL_MANAGER, "premise: the live PoolManager");
        assertEq(wethT, LaunchGuards.RH_WETH, "premise: the live WETH");
        _setEnv(BUCKET);
        _runGoLive(); // the GoLiveMainnet body, as the broadcaster
        assertTrue(QpullLiquidityLock(lockT).seeded(), "seeded by GoLiveMainnet");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "routing locked by GoLiveMainnet");
        assertEq(QpullTaxHook(hookT).launchTime(), block.timestamp, "the gate opened at the seed");

        // exactly the Deploy.s.sol construction
        router = new QpullSwapRouter(pm, wethT, qpullT, hookT, 3000, 60);
        packsR = PackRegistry(address(QpullTaxHook(hookT).packRegistry()));
        boardR = LeaderboardRegistry(address(QpullTaxHook(hookT).leaderboardRegistry()));
        assertTrue(QpullTaxHook(hookT).exemptSender() != address(router), "the router is taxed");
        assertEq(router.wethIsCurrency0(), wethT < qpullT, "currency order");
    }

    function _assertRouterEmpty(string memory tag) internal view {
        assertEq(address(router).balance, 0, string.concat(tag, ": router ETH"));
        assertEq(IERC20(wethT).balanceOf(address(router)), 0, string.concat(tag, ": router WETH"));
        assertEq(IERC20(qpullT).balanceOf(address(router)), 0, string.concat(tag, ": router QPULL"));
    }

    function _wrappedGated() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hookT,
            IV4Hooks.afterSwap.selector,
            abi.encodeWithSelector(QpullTaxHook.Gated.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _buy(address who, uint256 value) internal returns (uint256 out, uint256 fee, uint256 firstPack) {
        uint256 t0 = IERC20(wethT).balanceOf(treasuryT);
        uint256 q0 = IERC20(qpullT).balanceOf(who);
        firstPack = packsR.nextPackId();
        vm.deal(who, who.balance + value);
        vm.prank(who, who);
        out = router.buy{ value: value }(1, vm.getBlockTimestamp() + 10 minutes);
        console2.log("  fork buy gas (lastCallGas, not isolated)", vm.lastCallGas().gasTotalUsed);
        fee = IERC20(wethT).balanceOf(treasuryT) - t0;
        assertEq(IERC20(qpullT).balanceOf(who) - q0, out, "the caller received exactly the returned QPULL");
        assertEq(fee, (value * 400 + 9999) / 10_000, "TAX IN WETH: 4% of the ETH in reached the Treasury as WETH");
        assertEq(packsR.nextPackId() - firstPack, value / 3e15, "packs for the ETH spent");
        (address owner,,,) = packsR.packs(firstPack);
        assertEq(owner, who, "packs minted to tx.origin");
        _assertRouterEmpty("fork buy");
    }

    function _sell(address who, uint256 amt, uint256 bps) internal returns (uint256 ethOut) {
        uint256 t0 = IERC20(wethT).balanceOf(treasuryT);
        uint256 e0 = who.balance;
        vm.prank(who);
        IERC20(qpullT).approve(address(router), amt);
        vm.prank(who, who);
        ethOut = router.sell(amt, 1, vm.getBlockTimestamp() + 10 minutes);
        uint256 fee = IERC20(wethT).balanceOf(treasuryT) - t0;
        assertEq(who.balance - e0, ethOut, "ETH (unwrapped by the live WETH) reached the caller");
        assertGt(fee, 0, "sell taxed");
        assertEq(fee, ((ethOut + fee) * bps) / 10_000, "TAX IN WETH: the sell rate of the pool's WETH out");
        assertEq(IERC20(qpullT).allowance(who, address(router)), 0, "the exact approval was consumed");
        _assertRouterEmpty("fork sell");
    }

    function _exercise() internal {
        address holder = address(uint160(0xB0B0000)); // a paid minter from the raise: holds a pass
        address nonHolder = makeAddr("forkNonHolder");
        assertGt(IERC721(nftT).balanceOf(holder), 0, "premise: a pass holder");
        assertEq(IERC721(nftT).balanceOf(nonHolder), 0, "premise: a non-holder");
        uint256 gateEnd = QpullTaxHook(hookT).launchTime() + QpullTaxHook(hookT).GATE_DURATION();
        assertEq(QpullTaxHook(hookT).GATE_DURATION(), 1 hours, "the mainnet 1-hour gate");
        assertLt(block.timestamp, gateEnd, "inside the gate");

        // inside the gate
        (uint256 out,,) = _buy(holder, 0.03 ether);
        assertEq(boardR.points(boardR.currentWeek(), holder), 0.03 ether, "points to tx.origin");
        vm.deal(nonHolder, 1 ether);
        vm.prank(nonHolder, nonHolder);
        vm.expectRevert(_wrappedGated());
        router.buy{ value: 0.01 ether }(1, vm.getBlockTimestamp() + 10 minutes);
        _sell(holder, out / 2, 2000); // launch sell tax, step 0: 20%

        // after the gate
        vm.warp(gateEnd);
        (uint256 out2,,) = _buy(nonHolder, 0.012 ether);
        _sell(nonHolder, out2, 2000); // still inside the first 12h step
    }

    /// WETH (0x0Bd7...) sorts below this QPULL: WETH is currency0, the likely mainnet order.
    function test_fork_router_wethIsCurrency0_gateTaxPacksAndSells() public {
        _launchOnFork(QPULL_HI);
        assertTrue(router.wethIsCurrency0(), "premise: WETH is currency0");
        _exercise();
    }

    /// The other order: QPULL is currency0.
    function test_fork_router_qpullIsCurrency0_gateTaxPacksAndSells() public {
        _launchOnFork(QPULL_LO);
        assertFalse(router.wethIsCurrency0(), "premise: QPULL is currency0");
        _exercise();
    }
}
