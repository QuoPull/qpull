// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Treasury } from "../../src/Treasury.sol";
import { GoLiveMainnet } from "../../script/GoLiveMainnet.s.sol";
import { LaunchGuards } from "../../script/LaunchGuards.sol";

/// @notice The go-live's QUOTRON binding checks and the Drand oracle guard against the LIVE chain (read-only fork of
///         RH mainnet, nothing broadcast).
///
///         The go-live's binding checks and its convert rehearsal were unit-tested against a stand-in router. This
///         file runs the same code against Robinhood's real QUOTRON, WETH, PoolManager and Quotron canonical ETH
///         router at chainid 4663, so the pins, the router's pool key and getters, and the rehearsal's end-to-end
///         QUOTRON delivery into three vault contracts are proven on the chain the launch uses. The drand check
///         runs against a real BlsDrandOracle built on the fork.
contract GoLiveRehearsalForkTest is Test, GoLiveMainnet {
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    function externalsExt(address q, address r, address w, address pm) external view {
        LaunchGuards.requireExternals(q, r, w, pm);
    }

    function oracleExt(address o) external view {
        LaunchGuards.requireQuicknetOracle(o);
    }

    function test_fork_pinnedExternalsPass_andStaleOnesFail() public {
        vm.createSelectFork(RPC);
        assertEq(block.chainid, 4663, "RH mainnet");
        this.externalsExt(
            LaunchGuards.RH_QUOTRON, LaunchGuards.RH_QUOTRON_ROUTER, LaunchGuards.RH_WETH, LaunchGuards.RH_POOL_MANAGER
        );

        address stale = deployCode("MockERC20.sol:MockERC20"); // a MockERC20 QUOTRON, the shape a testnet deploy uses
        vm.expectRevert(bytes("launch: QUOTRON is not the pinned RH mainnet QUOTRON"));
        this.externalsExt(stale, LaunchGuards.RH_QUOTRON_ROUTER, LaunchGuards.RH_WETH, LaunchGuards.RH_POOL_MANAGER);
        vm.expectRevert(bytes("launch: QUOTRON_ROUTER is not the pinned RH mainnet router"));
        this.externalsExt(LaunchGuards.RH_QUOTRON, stale, LaunchGuards.RH_WETH, LaunchGuards.RH_POOL_MANAGER);
    }

    function test_fork_quicknetOracleGuard() public {
        vm.createSelectFork(RPC);
        address bls = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        this.oracleExt(bls); // the real oracle passes
        address mock = deployCode("MockDrandOracle.sol:MockDrandOracle", abi.encode(block.timestamp, uint256(3)));
        vm.expectRevert(bytes("launch: DRAND_ORACLE is not a quicknet BlsDrandOracle (drandGenesis)"));
        this.oracleExt(mock);
        vm.expectRevert(bytes("launch: DRAND_ORACLE has no code"));
        this.oracleExt(makeAddr("codeless"));
    }

    /// The exact `_rehearseConvert` GoLiveMainnet runs before lockRouting, through the REAL QuotronRouterAdapter and
    /// the REAL Quotron router: QUOTRON reaches all three vaults and the team gets WETH, and then every effect is
    /// reverted.
    function test_fork_convertRehearsal_throughTheRealRouter() public {
        vm.createSelectFork(RPC);
        address weth = LaunchGuards.RH_WETH;
        address quotron = LaunchGuards.RH_QUOTRON;
        address qpull = deployCode("MockERC20.sol:MockERC20");
        address me = address(this);

        GL memory g;
        g.weth = weth;
        g.quotron = quotron;
        g.quotronRouter = LaunchGuards.RH_QUOTRON_ROUTER;
        g.treasury = deployCode("Treasury.sol:Treasury", abi.encode(qpull, weth, quotron, me));
        g.prizeVault = deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, me));
        g.holderVault = deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, me));
        g.leaderboardVault = deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, me));
        g.team = makeAddr("team+ops");
        g.keeper = makeAddr("convertKeeper");
        g.wethQuotronAdapter = deployCode(
            "QuotronRouterAdapter.sol:QuotronRouterAdapter", abi.encode(g.quotronRouter, weth, quotron, me)
        );
        (bool ok,) = g.wethQuotronAdapter.call(abi.encodeWithSignature("setTreasury(address)", g.treasury));
        require(ok, "setTreasury");

        Treasury t = Treasury(payable(g.treasury));
        t.setAdapters(g.wethQuotronAdapter, g.wethQuotronAdapter); // leg 1 unused: the Treasury holds no QPULL
        t.setRouting(g.prizeVault, g.holderVault, g.leaderboardVault, g.team);
        t.setMaxConvertPerCall(1_000_000e18);
        t.setMaxWethConvertPerCall(1 ether);
        t.setKeeper(g.keeper, true);

        vm.recordLogs();
        _rehearseConvert(g); // reverts unless QUOTRON lands in all three vaults and WETH at team
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Converted(uint256,uint256,uint256,uint256)");
        uint256 quotronOut;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == g.treasury && logs[i].topics[0] == sig) {
                (,, quotronOut,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        emit log_named_uint("rehearsal: real QUOTRON bought for 0.008 WETH", quotronOut);
        assertGt(quotronOut, 0, "the rehearsal ran a real convert() through the live router");

        assertEq(IERC20(weth).balanceOf(g.treasury), 0, "rehearsal reverted: no WETH left in the Treasury");
        assertEq(IERC20(quotron).balanceOf(g.prizeVault), 0, "rehearsal reverted: prize vault untouched");
        assertEq(IERC20(weth).balanceOf(g.team), 0, "rehearsal reverted: team untouched");
    }
}
