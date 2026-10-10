// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IQuotronRouter
/// @notice The Canonical ETH router on Robinhood Chain (`0x4202…1C18`), the router-gated door to
///         the QUOTRON/WETH v4 pool. Deals in native ETH. The 3% fee hook charges automatically.
interface IQuotronRouter {
    function buyExactEth(uint256 minQuotronOut, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 quotronOut);

    // The protocol only ever BUYS QUOTRON, so no sell entrypoint is declared. poolKey is read to confirm
    // the router's pool.

    function poolKey()
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
