// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  IDelegateRegistry
/// @notice Minimal read view of the delegate.xyz v2 registry (the canonical cross-chain
///         delegation registry; deployed on Robinhood Chain at 0x00000000000000447e69651d841bD8D104Bed493).
/// @dev    `checkDelegateForContract(to, from, contract_, rights)` returns true when `to` (the delegate /
///         "hot" wallet) holds a delegation from `from` (the vault / allowlisted wallet) that covers
///         `contract_`. v2 is hierarchical: a broader "delegate ALL" from `from` to `to` also returns true
///         here, so a holder need not scope narrowly. `rights` is an optional scope tag; bytes32(0) = all
///         rights. This is a pure read against an external, immutable registry - QuoPull verifies no
///         signatures itself.
interface IDelegateRegistry {
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (bool);
}
