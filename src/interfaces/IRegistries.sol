// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Buys mint raffle tickets on the fixed whole-ticket schedule.
///         `grossValue` is the hook's `credit`, in WETH wei: the WETH the buyer actually paid (exact-in buy: G;
///         exact-out buy: pool input + WETH fee), capped at fee * BPS / TAX_BPS of the WETH fee QpullTaxHook
///         took to the Treasury in the same swap. It is never the QPULL received. PackRegistry prices
///         tickets in WETH (`ticketPrice`), so tickets = grossValue / ticketPrice: oracle-free, independent of
///         pool depth / slippage, and immune to spot-price manipulation, since every credited wei paid 4% in WETH.
interface IPackRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
}

/// @notice Buys accrue leaderboard points for the current weekly period. Non-winning ripped
///         packs also accrue points, rarity-weighted, via recordXp (called by PackRegistry.claimRipXp).
///         `grossValue` is the same hook credit (WETH wei) the hook passes to IPackRegistry.recordBuy.
interface ILeaderboardRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
    function recordXp(address who, uint256 amount) external;
}
