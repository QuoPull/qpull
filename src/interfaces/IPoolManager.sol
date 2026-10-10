// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A V4 currency is just an address (address(0) = native ETH).
type Currency is address;

/// @notice V4 packs two int128 amounts into one int256: amount0 in the high 128 bits, amount1 in the low.
type BalanceDelta is int256;

/// @notice The identity of a V4 pool (sorted currencies + fee + tickSpacing + hook).
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title  IPoolManager: the minimal Uniswap-V4 core surface QPULL needs
/// @notice Hand-written subset of v4-core's IPoolManager (RH's DEX is V4; PoolManager lives at
///         0x8366a39CC670B4001A1121B8F6A443A643e40951). Only the calls this repo makes are declared: the tax
///         hook (take), QpullLiquidityLock (initialize, unlock, modifyLiquidity, sync/settle/take),
///         QpullWethAdapter (unlock, swap, sync/settle/take), QpullV4Quoter (unlock and swap only: it reverts
///         the result out of the callback and never settles or takes), and test helpers. Struct field types and
///         order match v4-core so the ABI selectors are identical to the real contract.
interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified; // negative = exact input
        uint160 sqrtPriceLimitX96;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    /// @notice Enter the locked context; the manager calls `unlockCallback` back on `msg.sender`.
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Initialize a fresh pool at `sqrtPriceX96`.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    /// @notice Add/remove liquidity (only callable inside unlock). Returns the caller's balance delta.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /// @notice Swap (only callable inside unlock). Returns the swap's balance delta from the caller's view.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);

    /// @notice Snapshot a currency's reserves before paying it in (pair with a transfer + settle).
    function sync(Currency currency) external;

    /// @notice Pay a currency owed to the manager; credits the difference since the last sync.
    function settle() external payable returns (uint256 paid);

    /// @notice Withdraw a currency the manager owes to `to`.
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Raw storage read (v4-core Extsload). Hooks read the pool's price and liquidity through it.
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

/// @notice The manager calls this on whoever called `unlock`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Unpack V4's BalanceDelta into its two signed 128-bit halves (matches v4-core exactly).
library BalanceDeltaLib {
    function amount0(BalanceDelta d) internal pure returns (int128 a0) {
        assembly {
            a0 := sar(128, d)
        }
    }

    function amount1(BalanceDelta d) internal pure returns (int128 a1) {
        assembly {
            a1 := signextend(15, d)
        }
    }
}
