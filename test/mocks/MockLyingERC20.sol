// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that can report a SUCCESSFUL transfer while moving nothing.
/// @dev    The exact shape the old `_trySendQuotron` could not see through: it judged success from the
///         returndata, so a token that returns a clean `true` (or returns nothing at all, the shape a
///         codeless address also produces) was believed, the owed slice was cleared, and the tokens never
///         moved. Judging by the measured balance delta catches every variant of this.
contract MockLyingERC20 is ERC20 {
    bool public lie; // when true, transfer() moves nothing but still reports success
    bool public silent; // when true, transfer() returns NO data at all (the codeless-address shape)

    constructor() ERC20("MockLying", "LIE") { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setLie(bool v) external {
        lie = v;
    }

    function setSilent(bool v) external {
        silent = v;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (!lie) return super.transfer(to, value);
        if (silent) {
            assembly ("memory-safe") {
                return(0, 0) // no return data, exactly like a call into an address that holds no code
            }
        }
        return true; // a clean, well-formed, entirely false `true`
    }
}
