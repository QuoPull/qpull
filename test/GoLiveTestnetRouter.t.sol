// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { Treasury } from "../src/Treasury.sol";
import { GoLiveTestnet } from "../script/GoLiveTestnet.s.sol";
import { LaunchWorld } from "./regression/GoLiveLpEthUnchecked.t.sol";

/// @notice The site router on the testnet path: GoLiveTestnet deploys the SAME QpullSwapRouter as mainnet (the
///         TestnetSwapRouter is gone), bound to the seeded canonical pool, and it trades taxed. Also:
///         GoLiveTestnet now refuses a convertThreshold that quotes under the 1e12-wei floor GoLiveMainnet enforces.
///         Runs the REAL GoLiveTestnet `_goLive` body on the in-process LaunchWorld, as the broadcaster.
contract GoLiveTestnetRouterTest is LaunchWorld, GoLiveTestnet {
    function _envAddress(string memory key) internal view override returns (address) {
        return _worldEnvAddress(key);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view override returns (uint256) {
        return _worldEnvOrUint(key, dflt);
    }

    function goLiveExt() external returns (address, address) {
        return _goLive(_env());
    }

    function _testnetEnv() internal {
        _setA("POOL_MANAGER", pm);
        _setA("QPULL_TOKEN", qpullT);
        _setA("WETH", wethT);
        _setA("HOOK", hookT);
        _setA("LOCK", lockT);
        _setA("TREASURY", treasuryT);
    }

    function _run(address qpullAt) internal returns (QpullSwapRouter router) {
        _deploy(_opts(qpullAt));
        _testnetEnv();
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(10_000e18); // DeployTestnet's new default
        assertEq(msg.sender, deployer, "premise: the test caller is the broadcaster");
        (address lock, address r) = _goLive(_env());
        router = QpullSwapRouter(payable(r));

        assertTrue(QpullLiquidityLock(lock).seeded(), "seeded");
        assertEq(router.hook(), hookT, "router bound to the hook");
        assertEq(address(router.poolManager()), pm, "and the PoolManager");
        assertEq(router.qpull(), qpullT, "and QPULL");
        assertEq(router.weth(), wethT, "and WETH");
        assertTrue(QpullTaxHook(hookT).isCanonical(router.poolKey()), "on the canonical key");
        assertTrue(QpullTaxHook(hookT).exemptSender() != r, "taxed");
        // The same contract mainnet deploys: identical bindings give byte-identical runtime code.
        assertEq(r.codehash, address(new QpullSwapRouter(pm, wethT, qpullT, hookT, 3000, 60)).codehash, "same bytecode");
    }

    function _tradeThroughIt(QpullSwapRouter router) internal {
        PackRegistry packs = PackRegistry(address(QpullTaxHook(hookT).packRegistry()));
        uint256 id0 = packs.nextPackId();
        uint256 t0 = IERC20(wethT).balanceOf(treasuryT);
        vm.deal(deployer, deployer.balance + 0.03 ether);
        vm.prank(deployer, deployer); // holds the 25-pass reserve: passes the gate
        uint256 out = router.buy{ value: 0.03 ether }(1, block.timestamp);
        assertEq(IERC20(qpullT).balanceOf(deployer), out, "QPULL to the caller");
        assertEq(IERC20(wethT).balanceOf(treasuryT) - t0, 0.0012 ether, "4% in WETH");
        (address owner,,,) = packs.packs(id0);
        assertEq(owner, deployer, "packs to tx.origin");

        address stranger = makeAddr("noPass");
        vm.deal(stranger, 0.01 ether);
        vm.prank(stranger, stranger);
        vm.expectRevert(); // Gated, wrapped by the PoolManager (asserted byte-for-byte in test/QpullSwapRouter.t.sol)
        router.buy{ value: 0.01 ether }(1, block.timestamp);

        vm.prank(deployer);
        IERC20(qpullT).approve(address(router), out);
        uint256 e0 = deployer.balance;
        vm.prank(deployer, deployer);
        uint256 ethOut = router.sell(out, 1, block.timestamp);
        assertEq(deployer.balance - e0, ethOut, "ETH back");
        assertEq(address(router).balance + IERC20(wethT).balanceOf(address(router)) + IERC20(qpullT).balanceOf(address(router)), 0, "router empty");
    }

    function test_goLiveTestnet_deploysQpullSwapRouter_wethIsCurrency0() public {
        QpullSwapRouter router = _run(QPULL_HI);
        assertTrue(router.wethIsCurrency0(), "premise");
        _tradeThroughIt(router);
    }

    function test_goLiveTestnet_deploysQpullSwapRouter_qpullIsCurrency0() public {
        QpullSwapRouter router = _run(QPULL_LO);
        assertFalse(router.wethIsCurrency0(), "premise");
        _tradeThroughIt(router);
    }

    /// The old testnet default (1,000 QPULL) quotes 5e11 wei against the 0.5 ETH default LP: refused before any send.
    function test_goLiveTestnet_refusesAThresholdUnderTheQuoteFloor() public {
        _deploy(_opts(QPULL_HI));
        _testnetEnv();
        assertEq(Treasury(payable(treasuryT)).convertThreshold(), 1000e18, "premise: 1,000 QPULL");
        vm.prank(deployer, deployer);
        vm.expectRevert(bytes("go-live: convertThreshold quotes < 1e12 wei at the seed price (raise it with setConvertThreshold)"));
        this.goLiveExt();
        // 1,999 QPULL quotes 9.995e11 wei: still refused
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(1999e18);
        vm.prank(deployer, deployer);
        vm.expectRevert(bytes("go-live: convertThreshold quotes < 1e12 wei at the seed price (raise it with setConvertThreshold)"));
        this.goLiveExt();
        // 2,000 QPULL quotes exactly 1e12 wei at 0.5 ETH over 1e27: the floor is inclusive, so the run reaches the next
        // check (a slice cap below the threshold, set here to stop the run before its broadcast)
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(2000e18);
        _setU("MAX_CONVERT_PER_CALL", 1999e18);
        vm.prank(deployer, deployer);
        vm.expectRevert(bytes("go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold"));
        this.goLiveExt();
        assertFalse(QpullLiquidityLock(lockT).seeded(), "nothing was seeded");
    }
}
