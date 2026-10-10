// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IClaimManager
/// @notice Engines register won prizes here; winners pull them. Registering a prize
///         reserves it against the vault's free balance so the pot can never be over-stated.
interface IClaimManager {
    function registerClaim(address vault, address recipient, uint256 amount, uint64 deadline)
        external
        returns (uint256 id);
}
