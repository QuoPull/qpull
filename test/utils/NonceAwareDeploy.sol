// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

/// @dev No constructor arguments and no side effects. It exists only to be placed by deployCodeTo so the
///      cheatcode's own nonce cost can be read without any contract-specific behaviour mixed in.
contract DeployCodeToProbe { }

/// @notice deployCodeTo's nonce cost is a property of the FOUNDRY VERSION, not of the contract it places.
///
///         The launch tests predict the liquidity lock's CREATE address, because the hook must name the lock
///         and the lock must name the hook, and the cycle is broken by deriving the lock's address from
///         (deployer, nonce) before either exists. They place the hook with deployCodeTo in between and every
///         one of them asserted, in a comment and in arithmetic, that deployCodeTo consumes no nonce.
///
///         That was true when they were written. It is not true now: measured, deployCodeTo consumes exactly
///         one nonce, including on a contract with an empty constructor, so the cost is the cheatcode's and
///         not the hook's. Forty-eight tests failed at once with "lock prediction" the day CI first ran on a
///         current Foundry. The production deploy was never affected, because it places the hook by CREATE2
///         through a factory and never touches deployCodeTo.
///
///         Read the cost instead of assuming it. Measured inside a snapshot, so the measurement consumes
///         nothing, and it returns 0 again if a future Foundry reverts to the old behaviour.
abstract contract NonceAwareDeploy is Test {
    function _deployCodeToNonceCost() internal returns (uint256 cost) {
        uint256 snap = vm.snapshotState();
        uint256 before = vm.getNonce(address(this));
        deployCodeTo("NonceAwareDeploy.sol:DeployCodeToProbe", "", address(uint160(uint256(keccak256("nonce-probe")))));
        cost = vm.getNonce(address(this)) - before;
        vm.revertToState(snap);
    }

    /// @notice The CREATE address this contract's next CREATE will use, after `deployCodeTo` calls placed in
    ///         between. Pass how many deployCodeTo calls sit between this prediction and the CREATE.
    function _predictCreateAfterDeployCodeTo(uint256 deployCodeToCalls) internal returns (address) {
        return vm.computeCreateAddress(
            address(this), vm.getNonce(address(this)) + deployCodeToCalls * _deployCodeToNonceCost()
        );
    }
}
