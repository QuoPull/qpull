// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FullMath } from "v4-core/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "../lib/v4-core/test/utils/LiquidityAmounts.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  LpSizing — derive the launch pool's price and liquidity from the amounts actually being seeded
///
/// @notice The two most dangerous inputs in the whole go-live used to be hand-typed environment variables:
///         SQRT_PRICE_X96 and LP_LIQUIDITY. They decide how much of the launch capital the seed CONSUMES, and
///         QpullLiquidityLock has no withdrawal path, so whatever the add does not consume is entombed there
///         forever. Nothing rehearsed them: the one LP triple recorded in this repo was 322.6 bps off on the
///         WETH side, which the old code stranded in silence, and the mainnet values were never filled in at
///         all. Deriving them from the amounts removes the failure mode instead of checking for it.
///
/// @dev    The closed form, for a full-range position with the price set to the ratio of the two sides:
///           sqrtPriceX96 = sqrt(amount1 / amount0) * 2**96
///           liquidity    = min(L0, L1) at that price over the position's tick bounds
///         Setting the price to the ratio is what makes BOTH sides consume fully; any other price consumes
///         one side and strands the other. `amount0`/`amount1` are in v4's sorted-currency order, so the
///         caller must sort — getting that backwards inverts the launch price, and QpullLiquidityLock's
///         consumption band now turns that into a hard revert rather than a silent strand.
library LpSizing {
    error ZeroAmount();
    error PriceOutOfRange();

    /// @notice The Q64.96 price at which a full-range add consumes `amount0` and `amount1` together.
    function sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        // The ratio must fit a Q64.192 word. amount1 * 2**192 / amount0 < 2**256 exactly when
        // amount1 / amount0 < 2**64, so refuse larger ratios HERE, by name. Without this the mulDiv below
        // reverted with empty data inside FullMath, which named nothing.
        if (amount1 / amount0 >= (uint256(1) << 64)) revert PriceOutOfRange();
        // amount1 * 2**192 overflows uint256 on its own for any realistic supply, so the 512-bit
        // intermediate in FullMath.mulDiv is load-bearing, not a convenience.
        uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        uint256 s = Math.sqrt(ratioX192);
        // v4 refuses to initialize below MIN_SQRT_PRICE; fail here, where the message names the cause. The old
        // `s >= MAX_SQRT_PRICE` arm is removed because it is unreachable: ratioX192 < 2**256, so s < 2**128,
        // and TickMath.MAX_SQRT_PRICE is about 1.46e48 > 2**128 (about 3.4e38). The ratio check above is the
        // effective upper bound.
        if (s < TickMath.MIN_SQRT_PRICE) revert PriceOutOfRange();
        // casting to 'uint160' is safe because s < 2**128 (see above)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(s);
    }

    /// @notice The liquidity a full-range position over [tickLower, tickUpper] needs to consume both amounts.
    function fullRangeLiquidity(
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @notice Both values at once, from the UNSORTED pair, doing the currency sort for the caller.
    /// @return sqrtP the pool's initial price, @return liq the full-range liquidity to seed.
    function sizeFor(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint160 sqrtP, uint128 liq) {
        (uint256 amount0, uint256 amount1) = tokenA < tokenB ? (amountA, amountB) : (amountB, amountA);
        sqrtP = sqrtPriceX96(amount0, amount1);
        liq = fullRangeLiquidity(sqrtP, tickLower, tickUpper, amount0, amount1);
    }
}
