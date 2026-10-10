// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVault
/// @notice A prize-inventory vault. Holds QUOTRON (pure prize inventory, never
///         hardwired) and pays it out fractionally on the instruction of its engine/claim path.
/// @dev    `freeBalance` excludes `unclaimedReserve`, the prizes already owed but not yet claimed.
///         Every snapshot MUST read freeBalance, never the raw token balance, or the
///         pot can be over-stated (the one accounting bug that breaks solvency).
interface IVault {
    /// @return QUOTRON balance genuinely available to distribute (raw balance - unclaimedReserve).
    function freeBalance() external view returns (uint256);

    /// @notice Move `amount` QUOTRON to `to`. Restricted to the vault's authorized engine/claim manager.
    function payOut(address to, uint256 amount) external;

    /// @notice Reserve `amount` against future claims (increments unclaimedReserve).
    function reserve(uint256 amount) external;

    /// @notice Release `amount` of reservation (on claim or on claim-window expiry rollover).
    function release(uint256 amount) external;

    function unclaimedReserve() external view returns (uint256);
}
