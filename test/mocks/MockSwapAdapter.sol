// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ISwapAdapter } from "../../src/interfaces/ISwapAdapter.sol";
import { MockERC20 } from "./MockERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Test adapter: pulls tokenIn and mints tokenOut. `quoteRate` drives quote(); `fillRate`
///         drives the actual delivery — set fillRate < quoteRate to simulate slippage/under-fill.
///         Rates scaled 1e18 (1e18 = 1:1). Stands in for the real DEX adapter (§13.1).
/// @dev    Ownable2Step for one reason only: DeployTestnet substitutes this for QuotronRouterAdapter,
///         which IS Ownable2Step, and the ownership-handover rehearsal walks Treasury.wethQuotron(). A mock
///         that answers a narrower interface than the thing it stands in for makes the rehearsal skip a leg
///         of the real procedure -- which is exactly what happened: the handover preflight died on this
///         contract with a bare EvmError, mid-rehearsal, and the escape hatch in TransferOwnership.s.sol
///         exists only because routing was already locked by then and this could no longer be replaced.
contract MockSwapAdapter is ISwapAdapter, Ownable2Step {
    uint256 public quoteRate;
    uint256 public fillRate;

    constructor(uint256 quoteRate_, uint256 fillRate_) Ownable(msg.sender) {
        quoteRate = quoteRate_;
        fillRate = fillRate_;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * quoteRate) / 1e18;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * fillRate) / 1e18;
        require(amountOut >= minOut, "slippage");
        MockERC20(tokenOut).mint(to, amountOut);
    }
}
