// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH for tests: deposit ETH → mint WETH; withdraw WETH → burn + send ETH.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") { }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amt) external {
        _burn(msg.sender, amt);
        (bool ok,) = msg.sender.call{ value: amt }("");
        require(ok, "eth send");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
