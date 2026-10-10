// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that reverts on any transfer touching a blacklisted address — a stand-in for QUOTRON's
///         per-address `blacklist` (used to test convert isolation and claimBatch resilience).
contract MockBlacklistERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor() ERC20("MockBlacklist", "MBL") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setBlacklisted(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}
