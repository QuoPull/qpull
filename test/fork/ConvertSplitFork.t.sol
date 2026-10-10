// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Treasury } from "../../src/Treasury.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { QuotronRouterAdapter } from "../../src/adapters/QuotronRouterAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

interface IRouterView {
    function weth() external view returns (address);
    function quotron() external view returns (address);
}

interface IWETHDeposit {
    function deposit() external payable;
}

/// DEMO (fork): forks Robinhood Chain mainnet and runs the REAL `Treasury.convert()` through Quotron's
/// REAL Canonical ETH router, so you can watch the trade tax turn into REAL QUOTRON (with QUOTRON's real
/// dynamic fee applied) and split to the three prize vaults. Uses the WETH-only path (a real production
/// case: exact-in SELLS pay their 4% tax straight to the Treasury as WETH), which skips the QPULL->WETH
/// leg whose pool does not exist on mainnet yet.
contract ConvertSplitForkTest is Test {
    address constant ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    function test_feeBuysRealQuotronAndSplitsToVaults() public {
        vm.createSelectFork(RPC);

        address weth = IRouterView(ROUTER).weth();
        address quotron = IRouterView(ROUTER).quotron();

        // ── deploy the real production pieces on the fork ──
        MockERC20 qpull = new MockERC20(); // fee-currency stub; the QPULL leg is skipped here
        Treasury treasury = new Treasury(address(qpull), weth, quotron, address(this));
        QuotronRouterAdapter wethQuotron = new QuotronRouterAdapter(ROUTER, weth, quotron, address(this));
        wethQuotron.setTreasury(address(treasury));

        BaseVault raffleVault = new BaseVault(quotron, address(this)); // daily raffle, 61.25%
        BaseVault holderVault = new BaseVault(quotron, address(this)); // 6.25%
        BaseVault leaderVault = new BaseVault(quotron, address(this)); // leaderboard, 12.5%
        address team = makeAddr("team+ops");

        // qpullWeth must be non-zero (NotConfigured guard) but is never called (no QPULL balance).
        treasury.setAdapters(address(wethQuotron), address(wethQuotron));
        treasury.setRouting(address(raffleVault), address(holderVault), address(leaderVault), team);
        // The per-call caps ship fail-CLOSED (0 = NotConfigured); arm them (go-live step 1).
        // max is rejected onchain; a large finite value keeps "uncapped" intent.
        treasury.setMaxConvertPerCall(type(uint256).max / 2);
        treasury.setMaxWethConvertPerCall(type(uint256).max / 2);
        treasury.setKeeper(address(this), true);

        // ── the "tax": fund the Treasury with WETH (a real sell would deliver this via the hook) ──
        uint256 feeWeth = 0.1 ether;
        vm.deal(address(this), feeWeth);
        IWETHDeposit(weth).deposit{ value: feeWeth }();
        IERC20(weth).transfer(address(treasury), feeWeth);

        // ── run the REAL convert(): 20% team WETH, buy REAL QUOTRON with 80%, split to the vaults ──
        treasury.convert(0, 1); // minWethOut=0 (no QPULL leg); minQuotronOut=1 (router requires > 0)

        uint256 qRaffle = IERC20(quotron).balanceOf(address(raffleVault));
        uint256 qHolder = IERC20(quotron).balanceOf(address(holderVault));
        uint256 qLead = IERC20(quotron).balanceOf(address(leaderVault));
        uint256 teamW = IERC20(weth).balanceOf(team);
        uint256 totalQuotron = qRaffle + qHolder + qLead;

        emit log_string("--- fee -> convert -> REAL QUOTRON -> split ---");
        emit log_named_uint("fee WETH in (wei)          ", feeWeth);
        emit log_named_uint("team+ops WETH out (20%)    ", teamW);
        emit log_named_uint("REAL QUOTRON bought (net)  ", totalQuotron);
        emit log_named_uint("  -> daily raffle (61.25%) ", qRaffle);
        emit log_named_uint("  -> leaderboard  (12.5%)  ", qLead);
        emit log_named_uint("  -> holder      (6.25%)  ", qHolder);

        // team gets exactly 20% of the WETH
        assertEq(teamW, (feeWeth * 2000) / 10_000, "team+ops = 20% of the WETH");
        // a real QUOTRON buy happened
        assertGt(totalQuotron, 0, "bought real QUOTRON through the real router");
        // the split proportions hold (raffle : leaderboard : holder = 6125 : 1250 : 625 of the prize QUOTRON)
        assertApproxEqAbs(qHolder, (totalQuotron * 625) / 8000, 2, "holder ~6.25%");
        assertApproxEqAbs(qLead, (totalQuotron * 1250) / 8000, 2, "leaderboard ~12.5%");
        assertEq(totalQuotron, qRaffle + qLead + qHolder, "every QUOTRON routed to a prize vault");
    }
}
