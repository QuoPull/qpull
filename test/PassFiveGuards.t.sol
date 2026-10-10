// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { Treasury } from "../src/Treasury.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { NonRenounceableOwnable2Step } from "../src/utils/NonRenounceableOwnable2Step.sol";

/// @notice Focused coverage for the pass-5 authority-hardening: adapter setTreasury write-once and
///         the non-renounceable owner on the contracts that need a permanently-live owner.
contract PassFiveGuardsTest is Test {
    address constant PM = address(0x1111);
    address constant QPULL = address(0x2222);
    address constant WETH = address(0x3333);
    address constant QUOTRON = address(0x4444);

    // ─── pass-5: QpullWethAdapter.setTreasury is WRITE-ONCE ───────────────────────────────────

    function test_qpullWethAdapterSetTreasuryWriteOnce() public {
        QpullWethAdapter a = new QpullWethAdapter(PM, QPULL, WETH, address(this));
        address treasury = makeAddr("treasury");
        a.setTreasury(treasury);
        assertEq(a.treasury(), treasury);
        // a second set — the permanent 0%-tax route / convert DoS lever — is rejected
        vm.expectRevert(QpullWethAdapter.TreasuryAlreadySet.selector);
        a.setTreasury(makeAddr("attacker"));
    }

    function test_qpullWethAdapterSetTreasuryRejectsZero() public {
        QpullWethAdapter a = new QpullWethAdapter(PM, QPULL, WETH, address(this));
        vm.expectRevert(QpullWethAdapter.ZeroAddress.selector);
        a.setTreasury(address(0));
    }

    // ─── pass-5: renounceOwnership reverts on contracts needing a live owner ──────────────────

    function test_treasuryCannotRenounce() public {
        Treasury t = new Treasury(QPULL, WETH, QUOTRON, address(this));
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        t.renounceOwnership();
        assertEq(t.owner(), address(this), "still owned");
    }

    function test_packRegistryCannotRenounce() public {
        PackRegistry p = new PackRegistry(address(0xBEEF), 1e18, 1_000_000, 1 hours, address(this));
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        p.renounceOwnership();
    }

    function test_transferOwnershipStillWorks() public {
        // ownership can still be handed to the launch timelock/multisig (two-step) — only renounce is closed
        Treasury t = new Treasury(QPULL, WETH, QUOTRON, address(this));
        address timelock = makeAddr("timelock");
        t.transferOwnership(timelock);
        vm.prank(timelock);
        t.acceptOwnership();
        assertEq(t.owner(), timelock, "two-step transfer unaffected");
    }
}
