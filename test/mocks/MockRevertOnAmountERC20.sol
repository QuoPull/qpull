// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that reverts on a transfer of exactly `poison` units — lets a test trigger ONE failing
///         payout inside a same-recipient claimBatch (griefing resistance). `poison == 0` disables.
contract MockRevertOnAmountERC20 is ERC20 {
    uint256 public poison;

    constructor() ERC20("Poison", "PSN") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setPoison(uint256 p) external {
        poison = p;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(poison == 0 || value != poison, "poison amount");
        super._update(from, to, value);
    }
}
