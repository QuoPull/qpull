// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QuotronRouterAdapter } from "../../src/adapters/QuotronRouterAdapter.sol";

interface IRouterView {
    function weth() external view returns (address);
    function quotron() external view returns (address);
}

interface IWETHDeposit {
    function deposit() external payable;
}

/// Forks Robinhood Chain mainnet and runs the PRODUCTION adapter end-to-end through Quotron's real
/// Canonical ETH router — the strongest integration check short of deploying. (Router requires
/// minQuotronOut > 0; in production the Treasury supplies an off-chain-computed floor.)
contract QuotronSwapForkTest is Test {
    address constant ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    function test_adapterSwapThroughRealRouter() public {
        vm.createSelectFork(RPC);

        address weth = IRouterView(ROUTER).weth();
        address quotron = IRouterView(ROUTER).quotron();
        QuotronRouterAdapter adapter = new QuotronRouterAdapter(ROUTER, weth, quotron, address(this));
        adapter.setTreasury(address(this)); // this test acts as the Treasury caller

        address rcpt = makeAddr("recipient");
        uint256 amountIn = 0.05 ether;
        vm.deal(address(this), amountIn);
        IWETHDeposit(weth).deposit{ value: amountIn }();
        IERC20(weth).approve(address(adapter), amountIn);

        uint256 out = adapter.swapExactIn(weth, quotron, amountIn, 1, rcpt); // minOut=1 (floor)

        emit log_named_uint("QUOTRON out for 0.05 WETH", out);
        assertGt(out, 0, "received QUOTRON from the real router via the adapter");
        assertEq(IERC20(quotron).balanceOf(rcpt), out, "delivered to recipient");
    }
}
