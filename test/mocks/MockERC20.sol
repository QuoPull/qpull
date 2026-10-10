// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for QUOTRON in unit tests (no ERC-404 terminal behaviour needed — the vault
///         only ever holds and pays fractional balances, spec §9). ERC-404 receipt is covered by
///         the §13.3 fork probe, not here.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock QUOTRON", "mQTRN") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}
