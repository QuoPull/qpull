// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  QPULLToken
/// @notice A clean, fixed-supply, OWNERLESS ERC-20. That is the whole contract, deliberately.
///
///         The trade tax, the 1-hour NFT-holder launch gate, and the game-registry notifications
///         live in QpullTaxHook, attached to the canonical QPULL/WETH Uniswap-V4 pool, not in this
///         token: a transfer-tax token is STRUCTURALLY INCOMPATIBLE with V4's flash accounting
///         (skimming transfers breaks `settle()` with CurrencyNotSettled for every router that
///         touches the token). Taxing in the pool's own hook taxes actual trades, settles inside the
///         locked context, and leaves plain transfers (wallets, vaults, claims) untouched.
///
///         Security properties, all deliberate:
///           - no owner: nothing to renounce, no launch-only exemptions to revoke, no wiring setters;
///           - no transfer hooks: no reentrancy surface, and the token cannot block
///             any settlement path, DEX or otherwise;
///           - fixed supply, minted once to `recipient` (the deployer, which moves the whole supply into
///             QpullLiquidityLock at go-live). No mint, no burn, no pause, no blocklist.
contract QPULLToken is ERC20 {
    constructor(uint256 initialSupply, address recipient) ERC20("QPULL", "QPULL") {
        _mint(recipient, initialSupply);
    }
}
