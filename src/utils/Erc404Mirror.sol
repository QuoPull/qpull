// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Erc404Mirror
/// @notice Reads an ERC-404 token's paired ERC-721 "mirror" contract, if it has one.
/// @dev    QUOTRON is an ERC-404 whose NFT side is a SEPARATE contract: on Robinhood Chain
///         mainnet `QUOTRON.mirror()` (0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F) returns
///         0x027ACa2794E44f24950D81227DcD516FfBB49d6e, and that address answers
///         `supportsInterface(0x80ac58cd)` with true (read on chain 4663, 2026-09-15). Anything that reaches
///         our contracts through the ERC-721 side therefore arrives with `msg.sender` == the MIRROR, never the
///         token.
///         Read with a raw staticcall, not a typed call, on purpose: `mirror()` is not part of any standard,
///         so a token without it must leave the reader at address(0) instead of reverting the constructor.
library Erc404Mirror {
    /// @return the paired ERC-721 mirror, or address(0) if the token exposes no `mirror()` getter
    function mirrorOf(address token) internal view returns (address) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("mirror()"));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }
}
