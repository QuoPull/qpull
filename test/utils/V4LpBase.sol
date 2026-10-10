// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta, BalanceDeltaLibrary } from "v4-core/types/BalanceDelta.sol";

/// @title  V4LpBase — provide liquidity the way production does: as the pool's own initializer
///
/// @notice An earlier QpullTaxHook LP gate also admitted `tx.origin == initializer`. That branch is gone, so
///         the gate is now a plain `sender == initializer`. `sender` is whoever calls `modifyLiquidity` on
///         the PoolManager, which for a v4-core test router is THE ROUTER, not the test contract behind it.
///         Tests that seeded through PoolModifyLiquidityTest were therefore only ever admitted by the
///         tx.origin branch, the exact branch a phished contract could borrow and the reason it was
///         removed. They cannot model the production path any more.
///
///         In production the initializer is QpullLiquidityLock: a contract that calls `initialize` and
///         `modifyLiquidity` itself, from its own address, inside its own unlock. Inherit this and configure
///         the hook with `initializer: address(this)`, and the test contract becomes exactly that shape.
///
/// @dev    Removal is deliberately NOT offered here. `beforeRemoveLiquidity` reverts unconditionally now, so
///         a helper that removes would only ever be a helper for asserting that it reverts — do that inline,
///         where the expectation is visible.
abstract contract V4LpBase is IUnlockCallback {
    using BalanceDeltaLibrary for V4BalanceDelta;

    IV4PoolManager internal _lpManager;

    /// Call once in setUp, before any liquidity is added.
    function _initLp(IV4PoolManager manager) internal {
        _lpManager = manager;
    }

    /// Create the pool from THIS address, so the hook's afterInitialize gate sees `sender == initializer`.
    function _initializePool(V4PoolKey memory key, uint160 sqrtPriceX96) internal {
        _lpManager.initialize(key, sqrtPriceX96);
    }

    /// Add `liq` over [tickLower, tickUpper], paid out of this contract's own balances.
    function _addLiquidity(V4PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liq) internal {
        _lpManager.unlock(abi.encode(key, tickLower, tickUpper, int256(liq)));
    }

    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        require(msg.sender == address(_lpManager), "V4LpBase: not the pool manager");
        (V4PoolKey memory key, int24 tl, int24 tu, int256 liq) =
            abi.decode(data, (V4PoolKey, int24, int24, int256));
        (V4BalanceDelta delta,) =
            _lpManager.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(tl, tu, liq, bytes32(0)), "");
        _lpSettle(key.currency0, delta.amount0());
        _lpSettle(key.currency1, delta.amount1());
        return "";
    }

    function _lpSettle(V4Currency c, int128 amt) private {
        if (amt < 0) {
            _lpManager.sync(c);
            IERC20(V4Currency.unwrap(c)).transfer(address(_lpManager), uint256(-int256(amt)));
            _lpManager.settle();
        } else if (amt > 0) {
            _lpManager.take(c, address(this), uint256(uint128(amt)));
        }
    }
}
