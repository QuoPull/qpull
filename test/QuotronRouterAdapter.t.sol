// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { QuotronRouterAdapter } from "../src/adapters/QuotronRouterAdapter.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockQuotronRouter } from "./mocks/MockQuotronRouter.sol";

contract QuotronRouterAdapterTest is Test {
    QuotronRouterAdapter adapter;
    MockWETH weth;
    MockERC20 quotron;
    MockQuotronRouter router;

    address treasury = makeAddr("treasury");
    address prizeVault = makeAddr("prizeVault");

    function setUp() public {
        weth = new MockWETH();
        quotron = new MockERC20();
        router = new MockQuotronRouter(address(quotron), 1e18); // 1 QUOTRON per ETH
        adapter = new QuotronRouterAdapter(address(router), address(weth), address(quotron), address(this));
        adapter.setTreasury(treasury); // only the Treasury may call swapExactIn
    }

    function _fundTreasuryWeth(uint256 amt) internal {
        vm.deal(treasury, amt);
        vm.prank(treasury);
        weth.deposit{ value: amt }();
    }

    function test_swapWethForQuotron_unwrapsAndBuys() public {
        _fundTreasuryWeth(10 ether);
        vm.startPrank(treasury);
        weth.approve(address(adapter), 10 ether);
        uint256 out = adapter.swapExactIn(address(weth), address(quotron), 10 ether, 1, prizeVault);
        vm.stopPrank();

        assertEq(out, 10 ether, "1:1 out");
        assertEq(quotron.balanceOf(prizeVault), 10 ether, "QUOTRON delivered to recipient");
        assertEq(weth.balanceOf(treasury), 0, "WETH pulled");
    }

    function test_slippageFloorReverts() public {
        MockQuotronRouter shortRouter = new MockQuotronRouter(address(quotron), 0.9e18); // 10% short
        QuotronRouterAdapter a2 =
            new QuotronRouterAdapter(address(shortRouter), address(weth), address(quotron), address(this));
        a2.setTreasury(treasury);

        _fundTreasuryWeth(10 ether);
        vm.startPrank(treasury);
        weth.approve(address(a2), 10 ether);
        vm.expectRevert("slippage");
        a2.swapExactIn(address(weth), address(quotron), 10 ether, 10 ether, prizeVault); // demand 10, get 9
        vm.stopPrank();
    }

    function test_unsupportedPathReverts() public {
        vm.prank(treasury);
        vm.expectRevert(QuotronRouterAdapter.UnsupportedPath.selector);
        adapter.swapExactIn(address(quotron), address(weth), 1, 0, prizeVault);
    }

    function test_onlyTreasuryCanSwap() public {
        _fundTreasuryWeth(1 ether);
        vm.prank(treasury);
        weth.approve(address(adapter), 1 ether);
        vm.expectRevert(QuotronRouterAdapter.NotTreasury.selector);
        adapter.swapExactIn(address(weth), address(quotron), 1 ether, 1, prizeVault); // caller != treasury
    }

    // ─── pass-5: setTreasury is WRITE-ONCE ─────────────────────────────────────────────────────

    function test_setTreasuryWriteOnce() public {
        // setUp already set it once; a second call reverts (no permanent tax-free route / convert DoS lever)
        vm.expectRevert(QuotronRouterAdapter.TreasuryAlreadySet.selector);
        adapter.setTreasury(makeAddr("attacker"));
    }

    function test_setTreasuryRejectsZero() public {
        QuotronRouterAdapter fresh =
            new QuotronRouterAdapter(address(router), address(weth), address(quotron), address(this));
        vm.expectRevert(QuotronRouterAdapter.ZeroAddress.selector);
        fresh.setTreasury(address(0));
    }

    // ─── pass-5: owner-only ETH rescue ─────────────────────────────────────────────────────────

    function test_sweepETH() public {
        vm.deal(address(adapter), 3 ether); // force-sent / router refund
        address to = makeAddr("rescue");
        adapter.sweepETH(to);
        assertEq(to.balance, 3 ether, "stranded ETH rescued");
        assertEq(address(adapter).balance, 0, "adapter drained");
    }

    function test_sweepETHOnlyOwner() public {
        vm.deal(address(adapter), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        adapter.sweepETH(makeAddr("rescue"));
    }

    function test_sweepETHRejectsZero() public {
        vm.expectRevert(QuotronRouterAdapter.ZeroAddress.selector);
        adapter.sweepETH(address(0));
    }

    // ─── router ETH refund is recaptured, not stranded ────────────────────────────────────────

    /// A router that sends part of the ETH back must not leave it in the adapter (where it would escape
    /// convert()'s QUOTRON-only shortfall check): it is re-wrapped and forwarded to the caller (Treasury).
    function test_routerRefundForwardedToTreasuryAsWeth() public {
        router.setRefundBps(500); // misbehaving router: refunds 5%, converts 95%
        _fundTreasuryWeth(10 ether);
        vm.startPrank(treasury);
        weth.approve(address(adapter), 10 ether);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit QuotronRouterAdapter.RefundForwarded(treasury, 0.5 ether);
        uint256 out = adapter.swapExactIn(address(weth), address(quotron), 10 ether, 1, prizeVault);
        vm.stopPrank();

        assertEq(out, 9.5 ether, "only the non-refunded ETH converts");
        assertEq(quotron.balanceOf(prizeVault), 9.5 ether, "QUOTRON delivered to recipient");
        assertEq(address(adapter).balance, 0, "no ETH stranded in the adapter");
        assertEq(weth.balanceOf(address(adapter)), 0, "no WETH stranded in the adapter");
        assertEq(weth.balanceOf(treasury), 0.5 ether, "refund back to the Treasury as WETH, same call");
        assertEq(weth.balanceOf(prizeVault), 0, "refund goes to the payer, never to `to`");
    }

    /// The floor still keys on QUOTRON delivered: a refund large enough to breach minOut cannot be masked
    /// by the recapture — the swap reverts and nothing moves.
    function test_routerRefundBelowFloorStillReverts() public {
        router.setRefundBps(1000); // refunds 10% -> 9 out
        _fundTreasuryWeth(10 ether);
        vm.startPrank(treasury);
        weth.approve(address(adapter), 10 ether);
        vm.expectRevert(bytes("slippage"));
        adapter.swapExactIn(address(weth), address(quotron), 10 ether, 10 ether, prizeVault); // demand 10, get 9
        vm.stopPrank();
        assertEq(weth.balanceOf(treasury), 10 ether, "atomic: WETH untouched on revert");
    }

    /// Pre-existing force-sent ETH is sweepETH's domain and must NOT be confused with a refund:
    /// the recapture measures only the balance delta across the router call.
    function test_forceSentEthNotForwardedAsRefund() public {
        vm.deal(address(adapter), 1 ether); // force-sent before the swap
        _fundTreasuryWeth(10 ether);
        vm.startPrank(treasury);
        weth.approve(address(adapter), 10 ether);
        uint256 out = adapter.swapExactIn(address(weth), address(quotron), 10 ether, 1, prizeVault);
        vm.stopPrank();

        assertEq(out, 10 ether, "exact-in router: full amount converts");
        assertEq(address(adapter).balance, 1 ether, "force-sent ETH left for sweepETH");
        assertEq(weth.balanceOf(treasury), 0, "nothing forwarded when the router did not refund");
    }
}
