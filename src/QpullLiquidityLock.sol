// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "./interfaces/IPoolManager.sol";

/// @title  QpullLiquidityLock
/// @notice A PERMANENT, one-way liquidity lock for the QuoPull canonical QPULL/WETH pool. The launch
///         liquidity (the fair-launch supply + its paired WETH) is added to a single full-range position
///         owned by THIS contract, exactly once, and can then NEVER be removed.
///
/// @dev    THE GUARANTEE IS THE ABSENCE OF CODE, NOT A GATE. In Uniswap v4 a position is owned by the
///         address that called `modifyLiquidity` to create it (this contract). Only that owner can ever
///         modify or remove it. This contract:
///           - adds liquidity EXACTLY ONCE (`seed`, opener-only, latched), and
///           - contains NO function that removes, withdraws, collects, or otherwise reduces the position
///             (no negative `liquidityDelta`, no fee-collect, no token sweep-out, no owner, no setter, no
///             delegatecall, no selfdestruct).
///         Therefore no transaction can ever pull the liquidity: removal is not restricted, it does not
///         exist in the bytecode. Anyone can verify this by reading this (small, immutable) contract.
///
///         LP fees (the pool's static `fee`, 0.30% by default, distinct from the protocol's trade tax) accrue
///         to this locked position and are DELIBERATELY never collected: there is no collect path, so they
///         stay with the locked position forever. The trade tax (taken in WETH by QpullTaxHook) funds the
///         prize games separately.
///
///         THIS CONTRACT ALSO CREATES THE POOL. `seed` calls `poolManager.initialize` and adds the liquidity
///         in the SAME transaction, and the hook names THIS CONTRACT as its `initializer`, so no other
///         address can create the canonical pool and no block ever exists in which the pool has a price but
///         no liquidity. The token amounts an add costs are a pure function of the pool price, which is
///         unconstrained while liquidity is zero, so creation and seeding happen atomically.
///
///         Because the hook's `initializer` is this contract, the hook's LP gate is a plain `sender ==
///         initializer` check with no `tx.origin` branch: the only address that may ever add liquidity to the
///         canonical pool is this lock, which does it exactly once. None of that affects the guarantee above,
///         which rests solely on this contract owning the position and never exposing a removal.
contract QpullLiquidityLock is IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable qpull;
    address public immutable weth;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hook;
    address public immutable opener; // the ONLY address allowed to trigger the one-time seed
    int24 public immutable tickLower; // full range, aligned to tickSpacing
    int24 public immutable tickUpper;
    bool internal immutable qpullIs0; // address-sort order of the canonical pair

    bool public seeded; // one-shot latch: true after `seed`, so it can never run twice

    event Seeded(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 qpullConsumed,
        uint256 wethConsumed
    );

    /// @dev The add must CONSUME what the opener declares it funded, to within 50 bps either way; a wider
    ///      miss means the liquidity was mis-sized against the pool price, and the seed is refused rather than
    ///      stranding launch capital forever in a contract that has no withdrawal path.
    uint256 internal constant MAX_RESIDUAL_BPS = 50;
    uint256 internal constant BPS_DENOM = 10_000;

    error NotOpener();
    error AlreadySeeded();
    error NotPoolManager();
    error ZeroAddress();
    error ZeroLiquidity();
    error BadTickSpacing(); // tickSpacing_ outside v4's [1, 32767]: <= 0 panics on division below, > 32767 never initializes
    error BadExpectedInput(); // a declared input of zero, or above the uint128 a v4 delta can ever express
    /// @dev the add did not cost what the opener said it funded: the difference would be stranded forever
    error SeedConsumptionOutOfBand(address token, uint256 consumed, uint256 expected);

    constructor(
        IPoolManager poolManager_,
        address qpull_,
        address weth_,
        uint24 fee_,
        int24 tickSpacing_,
        address hook_,
        address opener_
    ) {
        if (
            address(poolManager_) == address(0) || qpull_ == address(0) || weth_ == address(0)
                || hook_ == address(0) || opener_ == address(0)
        ) revert ZeroAddress();
        // tickSpacing_ is DIVIDED BY below. Zero panics; a negative value yields a negative maxUsable, hence
        // tickLower > tickUpper, an invalid range that would only surface at seed(), after the lock is funded.
        // The upper bound: v4's TickMath.MAX_TICK_SPACING is type(int16).max, and PoolManager.initialize
        // refuses anything above it (TickSpacingTooLarge). QpullTaxHook's constructor refuses the same range.
        if (tickSpacing_ <= 0 || tickSpacing_ > 32_767) revert BadTickSpacing();
        poolManager = poolManager_;
        qpull = qpull_;
        weth = weth_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        hook = hook_;
        opener = opener_;
        qpullIs0 = qpull_ < weth_;
        // Widest range aligned to tickSpacing (the v4 usable-tick bound is 887272).
        int24 maxUsable = int24((int256(887_272) / int256(tickSpacing_)) * int256(tickSpacing_));
        tickLower = -maxUsable;
        tickUpper = maxUsable;
    }

    /// @notice The canonical pool key this lock serves (currencies sorted, carrying the tax hook).
    function poolKey() public view returns (PoolKey memory) {
        (address c0, address c1) = qpullIs0 ? (qpull, weth) : (weth, qpull);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });
    }

    /// @notice CREATE the canonical pool and add the launch liquidity to it, ONCE, in one transaction, and
    ///         lock that liquidity forever. This contract must already hold the QPULL and WETH to seed
    ///         (transferred in by the opener). After this call there is no remaining privileged action, and
    ///         nothing this contract holds (the position, its fees, or any leftover token dust) can ever
    ///         leave. THIS IS THE ONLY STATE-CHANGING ENTRYPOINT.
    ///
    /// @param sqrtPriceX96  the price to create the pool at, Q64.96, sized OFF-CHAIN from the ratio of the
    ///                      two amounts being seeded. Nobody can move it before the add: the pool does not
    ///                      exist until the line above the add, in this same transaction.
    /// @param liquidity     v4 liquidity units for the full-range position, sized OFF-CHAIN to consume the
    ///                      two amounts below at `sqrtPriceX96`.
    /// @param expectedQpull QPULL the opener funded this lock with and therefore expects the add to consume.
    /// @param expectedWeth  WETH the opener funded this lock with and therefore expects the add to consume.
    ///
    /// @dev `liquidity` is caller-supplied and the TOKEN AMOUNTS it consumes depend entirely on the pool's
    ///      price. THIS CONTRACT HAS NO WITHDRAWAL PATH, by design, because that absence is the "can't rug"
    ///      guarantee, so anything the add does not consume stays here permanently. The add is therefore
    ///      required to consume the declared `expected*` amounts to within 50 bps (`_assertConsumed`).
    ///
    ///      THE MEASUREMENT IS CONSUMPTION, NOT LEFTOVER. A leftover test (post-add `balanceOf(this)` against
    ///      a pre-add snapshot of it) would depend on a balance that unsolicited transfers can change. What
    ///      the pool CHARGES is fixed by `liquidity`, the price and the tick range, and it is reported by the
    ///      manager's own BalanceDelta, so the band is applied to the settled delta. An unsolicited transfer
    ///      into this lock just joins the locked position's dust.
    ///
    ///      The contract cannot know the opener's intent except by being told it, so `expected*` is the
    ///      anchor. GoLiveMainnet derives both the transfer and the declaration from the same value, so they
    ///      cannot drift; funding less than declared fails closed in `_settle` (the transfer reverts).
    ///
    ///      Reverting here unwinds the whole seed -- the pool creation, the add and the `seeded` latch -- so
    ///      the opener can retry with a corrected size. That is strictly better than latching a bad seed
    ///      permanently, and it is why creation belongs inside this function rather than before it.
    function seed(uint160 sqrtPriceX96, uint128 liquidity, uint256 expectedQpull, uint256 expectedWeth)
        external
    {
        if (msg.sender != opener) revert NotOpener();
        if (seeded) revert AlreadySeeded();
        if (liquidity == 0) revert ZeroLiquidity(); // no-op seed would latch and strand the pre-funded tokens
        // A v4 BalanceDelta is a pair of int128, so consumption can NEVER exceed type(uint128).max. An
        // expectation above that is unsatisfiable by construction, and refusing it here also keeps the
        // tolerance arithmetic below overflow-free.
        uint256 maxDelta = uint256(type(uint128).max);
        if (expectedQpull == 0 || expectedQpull > maxDelta) revert BadExpectedInput();
        if (expectedWeth == 0 || expectedWeth > maxDelta) revert BadExpectedInput();

        if (sqrtPriceX96 == 0) revert BadExpectedInput();

        seeded = true; // effects before interactions; permanent one-shot latch

        // CREATE THE POOL. The hook's `initializer` is this contract, so this is the only call that can ever
        // succeed here; afterInitialize stamps launchTime, which starts the holder gate and the sell-tax
        // decay at the instant liquidity exists. `initialize` reverts if the pool already exists, so this
        // doubles as the retry guard on a re-run.
        poolManager.initialize(poolKey(), sqrtPriceX96);

        // -> unlockCallback adds the liquidity and reports what the manager actually charged, per token
        (uint256 qpullUsed, uint256 wethUsed) =
            abi.decode(poolManager.unlock(abi.encode(liquidity)), (uint256, uint256));

        _assertConsumed(qpull, qpullUsed, expectedQpull);
        _assertConsumed(weth, wethUsed, expectedWeth);

        emit Seeded(sqrtPriceX96, liquidity, tickLower, tickUpper, qpullUsed, wethUsed);
    }

    /// @dev `used` must land within 50 bps of `expected`, on BOTH sides. Under-consuming strands the
    ///      difference in here forever, which is the failure this guard exists for; over-consuming means the
    ///      declaration did not describe the add that actually happened, so it is refused rather than
    ///      trusted. `used` comes from the pool manager's own delta, not from a token balance.
    function _assertConsumed(address token, uint256 used, uint256 expected) internal pure {
        uint256 tol = (expected * MAX_RESIDUAL_BPS) / BPS_DENOM; // expected <= uint128 max: cannot overflow
        if (used < expected - tol || used > expected + tol) {
            revert SeedConsumptionOutOfBand(token, used, expected);
        }
    }

    /// @dev V4 unlock callback: add the liquidity and pay both currencies from this contract's balance.
    ///      ONLY the pool manager can call it, and it is reachable ONLY via `seed` (guarded above), so it
    ///      can never be driven to remove liquidity (liquidityDelta is always the positive `seed` amount).
    ///      It returns what the add COST in (qpull, weth) order, so `seed` can band-check the real number
    ///      instead of a leftover balance -- see the note on `seed`.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint128 liquidity = abi.decode(data, (uint128));
        PoolKey memory key = poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), bytes32(0)),
            ""
        );
        uint256 paid0 = _settle(key.currency0, delta.amount0());
        uint256 paid1 = _settle(key.currency1, delta.amount1());
        return qpullIs0 ? abi.encode(paid0, paid1) : abi.encode(paid1, paid0);
    }

    /// @dev Pay the pool manager what the add owes (delta < 0) and REPORT it. The `amt > 0` branch (manager
    ///      owes us) cannot occur on a pure add, but is handled defensively by taking it back into this locked
    ///      contract (it stays locked here; there is still no path out). That branch reports zero consumed,
    ///      which fails seed's band: a side of the add that costs nothing is not a seed of that side.
    function _settle(Currency c, int128 amt) internal returns (uint256 paid) {
        if (amt < 0) {
            // widen before negating: -type(int128).min would overflow int128
            paid = uint256(-int256(amt));
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint256(uint128(amt)));
        }
    }
}
