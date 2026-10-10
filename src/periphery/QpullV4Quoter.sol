// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    BalanceDelta,
    BalanceDeltaLib
} from "../interfaces/IPoolManager.sol";

/// @title  QpullV4Quoter: the off-chain quoter the keeper needs to size convert()'s first leg
///
/// @notice WHY THIS EXISTS. `Treasury.convert()`'s QPULL→WETH leg needs a `minWethOut` floor, and the keeper
///         computes it off-chain from a Uniswap v4 quoter (`keeper.js`, quoteConvert). There is no canonical
///         v4 Quoter deployed on Robinhood Chain, and Quotron's View quoter is a different interface
///         (`quoteBuyExactEth`, priced for THEIR pool), so this contract provides one.
///
///         The hook takes the tax in WETH on every swap kind, so convert()'s WETH-only path funds the prize
///         vaults with no QPULL quote at all. The QPULL→WETH leg only handles QPULL donated to the Treasury;
///         this quoter (or the keeper's bisection fallback) sizes that leg's floor. Exact-in sells, the only
///         kind it quotes, take the hook's afterSwap floor-fee path (beforeSwap returns zero for them).
///
/// @dev    WHY IT IS SAFE.
///
///         It cannot move value. The quote is produced the standard v4 way: `unlock` → `swap` → **revert with
///         the answer**. The callback NEVER settles and NEVER takes; it reverts unconditionally, so the swap
///         and every balance it touched roll back with it. There is no code path in this contract that
///         transfers a token, and it holds no balances, no approvals, no owner and no privileges. Its only
///         output is a number, and slippage is enforced by `Treasury.convert()` against the keeper's floor.
///
///         It is deliberately NOT `view`. v4 quoting must go through `unlock()`, which is state-mutating in
///         the ABI even though this use of it cannot persist anything. Callers must `staticCall`, which is
///         exactly what `keeper.js` does (`quoteExactInputSingle.staticCall`), and what makes the
///         revert-with-answer pattern airtight from the caller's side too.
///
///         The signature matches `keeper.js`'s `v4QuoterAbi` exactly:
///           quoteExactInputSingle((address,address,uint24,int24,address),bool,uint128,bytes)
///             returns (uint256 amountOut, uint256 gasEstimate)
///
///         THE QUOTE IS TAXED; THE REAL LEG IS NOT. This contract swaps as an ordinary sender, so
///         the hook charges it the sell tax and `amountOut` is AFTER tax. QpullWethAdapter, which performs the
///         real conversion, is the hook's immutable `exemptSender` and receives the larger untaxed amount. A
///         caller must gross the quote up before using it as a floor. `keeper.js` does (quoteLeg1 applies
///         `grossUpForExemptSell(outWeth, taxBps)` at the block's sell-tax rate, then its slippage), so the
///         minWethOut it sends matches the adapter's real fill. Used raw, the quote gives a floor about 4% too
///         low (up to 20% in the 48h launch decay): looser, never a false revert.
contract QpullV4Quoter is IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;

    IPoolManager public immutable poolManager;

    /// Same price-limit sentinels the production adapter swaps with (QpullWethAdapter's MIN_SQRT_PRICE_P1 /
    /// MAX_SQRT_PRICE_M1), so the
    /// quote is taken against the same bounds the real swap will use. A quoter that clamped differently
    /// would silently quote a different trade than the one convert() performs.
    uint160 internal constant MIN_SQRT_PRICE_P1 = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT_PRICE_M1 =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    error NotPoolManager();
    error ZeroPoolManager();
    /// @dev The callback reverts by design. If `unlock` ever RETURNS, the pattern's core assumption is gone
    ///      and a swap may have been left settled, refuse loudly rather than hand back a number.
    error QuoteDidNotRevert();
    error MalformedQuote();

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroPoolManager();
        poolManager = poolManager_;
    }

    /// @notice Quote an exact-input single-hop swap. NOT view, `staticCall` it.
    /// @param  key         the pool key; must match the hook's canonical PoolKey or you are quoting a pool
    ///                     that does not exist
    /// @param  zeroForOne  true when selling currency0 for currency1
    /// @param  exactAmount exact input amount
    /// @param  hookData    passed through to the hook, exactly as the real swap would
    /// @return amountOut   tokens the pool would pay out
    /// @return gasEstimate gas this quote consumed (indicative only)
    function quoteExactInputSingle(PoolKey memory key, bool zeroForOne, uint128 exactAmount, bytes calldata hookData)
        external
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(key, zeroForOne, exactAmount, hookData)) returns (bytes memory) {
            revert QuoteDidNotRevert();
        } catch (bytes memory reason) {
            amountOut = _decodeQuote(reason);
        }
        gasEstimate = gasBefore - gasleft();
    }

    /// @notice v4 unlock callback. Performs the swap purely to learn its output, then REVERTS with that
    ///         output so nothing settles. Never returns normally.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint128 exactAmount, bytes memory hookData) =
            abi.decode(data, (PoolKey, bool, uint128, bytes));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(exactAmount)), // negative = exact input
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_P1 : MAX_SQRT_PRICE_M1
            }),
            hookData
        );

        // The output side of the delta is the positive one. This is the same delta READ as QpullWethAdapter's,
        // but not the same QUANTITY: this sender is taxed and the adapter is the hook's exempt
        // sender, so the adapter takes more. Gross the quote up before using it as a floor (see the header).
        int128 out128 = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 out = out128 > 0 ? uint256(uint128(out128)) : 0;

        // Revert with the answer. This is the whole safety argument: no settle, no take, no transfer, the
        // swap above is undone by this revert, along with anything the hook did.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, out)
            revert(p, 32)
        }
    }

    /// @dev The callback reverts with exactly 32 bytes holding the amount. Anything else is a REAL revert
    ///      (pool uninitialised, hook rejected the swap, insufficient liquidity) and must be surfaced, not
    ///      silently read as a quote of zero, a zero would set the keeper's floor to zero and disable the
    ///      slippage guard on a live convert.
    function _decodeQuote(bytes memory reason) internal pure returns (uint256) {
        if (reason.length != 32) {
            if (reason.length == 0) revert MalformedQuote();
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        return abi.decode(reason, (uint256));
    }
}
