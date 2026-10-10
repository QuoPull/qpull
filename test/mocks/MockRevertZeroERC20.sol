// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An adversarial ERC-20 that REVERTS on any zero-value transfer — the exact behavior some
///         ERC-404s exhibit. Used to prove Treasury.convert()'s zero-value split-transfer guards.
contract MockRevertZeroERC20 is ERC20 {
    constructor() ERC20("Revert-Zero", "RZ") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value > 0, "zero transfer");
        super._update(from, to, value);
    }
}
