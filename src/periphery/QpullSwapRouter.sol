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
} from "../interfaces/IPoolManager.sol";

/// @dev The canonical wrapped-ETH surface the router uses (WETH9, and the proxied WETH on Robinhood Chain).
interface IWETHLike {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @dev The immutables of QpullTaxHook the router binds itself to at construction. A read surface only, so this
///      file does not pull the hook's source into its compilation unit.
interface IQpullTaxHookBinding {
    function poolManager() external view returns (address);
    function qpull() external view returns (address);
    function weth() external view returns (address);
    function canonicalFee() external view returns (uint24);
    function canonicalTickSpacing() external view returns (int24);
    function exemptSender() external view returns (address);
    function REQUIRED_FLAGS() external view returns (uint160);
    function isCanonical(PoolKey calldata key) external view returns (bool);
}

/// @title  QpullSwapRouter: the QuoPull site's buy and sell, ETH in and ETH out, on the canonical QPULL/WETH pool
///
/// @notice The site's swap widget calls THIS contract on mainnet (4663) and on testnet (46630), not Uniswap's
///         Universal Router. Two calls, both EXACT INPUT, both atomic:
///           buy(minQpullOut, deadline){value: G}    wrap G ETH to WETH, swap exact-in WETH -> QPULL, QPULL to the caller
///           sell(qpullIn, minEthOut, deadline)      pull qpullIn QPULL from the caller into the pool, swap exact-in
///                                                   QPULL -> WETH, unwrap, ETH to the caller
///
///         EVERY SWAP IS TAXED. The router is an ordinary swapper as far as QpullTaxHook can tell: it is never the
///         hook's immutable exemptSender (checked at construction), so beforeSwap/afterSwap charge the WETH fee on
///         both directions exactly as for any other router (4% on buys, the decaying launch rate on
///         sells). The caller pays the fee inside the pool's own deltas; the router never computes it.
///
///         WHO GETS CREDIT, AND WHO IS GATED. Nothing. The hook attributes a buy to `tx.origin` (the signer), for
///         the pack and leaderboard credit, the 1-hour launch holder gate (GATE_DURATION()) and the launch throttle.
///         The router passes no hookData (the hook ignores it anyway) and adds no identity of its own, so a buy
///         through it resolves to the same signer as a buy through any other router: packs mint to the EOA that
///         signed, and inside the gate a signer holding no pass reverts Gated.
///
///         WHAT THE CALLER RECEIVES IS WHAT IS CHECKED. On a buy the router has the PoolManager transfer the QPULL
///         straight to the caller and measures the caller's QPULL balance across that transfer; `minQpullOut` is
///         compared with that measured amount. On a sell the WETH output is taken to the router, unwrapped, and the
///         ETH sent to the caller; `minEthOut` is compared with the WETH the pool paid out, which is exactly the
///         ETH forwarded (native ETH has no transfer fee). Both floors must be non-zero: a zero floor accepts any
///         price, so the router refuses it (ZeroMinOut).
///
///         NO PARTIAL FILLS. Each swap runs with the extreme price limit, so on the full-range launch position it
///         stops early only if the pool runs out of price range. The hook already reverts a WETH-specified buy that
///         stops early (PartialFill). The router applies the same rule to sells: if the pool consumed less than
///         `qpullIn`, the whole call reverts PartialFill() (same selector as the hook's error), so a sell never
///         leaves the caller with an unexpected remainder or a half-used allowance.
///
///         THE ROUTER HOLDS NOTHING BETWEEN CALLS. It never approves anything to anyone and keeps no user funds:
///           - buy: the ETH is wrapped and the exact WETH is paid into the PoolManager inside the same unlock; the
///             QPULL goes from the PoolManager straight to the caller;
///           - sell: the QPULL goes from the caller straight to the PoolManager (transferFrom, so the caller approves
///             this router for exactly `qpullIn`); the WETH output is unwrapped and forwarded in the same call.
///         STRAYS. Anyone can push value into any address: an ERC-20 transfer of WETH or QPULL, or ETH forced in by a
///         self-destruct or a block reward. With no owner there is no rescue, so instead every buy and sell ends by
///         forwarding every stray balance to its own caller, in the form that call already pays out: a buy forwards
///         stray QPULL as QPULL and stray WETH and ETH as WETH (a buyer need not accept ETH); a sell forwards stray
///         QPULL as QPULL and stray WETH and ETH as ETH. So after every successful call the router's ETH, WETH and
///         QPULL balances are zero. A stray is a donation to the next caller; it never changes the swap itself (the
///         swap uses msg.value or qpullIn only, so a donation can never move a buyer over the launch per-buy cap or
///         inflate anyone's credit). StraySwept is emitted whenever a stray was forwarded.
///
///         REENTRANCY. buy and sell take a transient-storage lock for their whole body, including the final ETH send,
///         and unlockCallback is accepted only from the PoolManager AND only while this contract is inside its own
///         pm.unlock (a second transient state). A buy or sell re-entered from the caller's receive() reverts
///         Reentrancy; if the caller lets that propagate, or rejects ETH at all, its ETH receipt fails and its own sell
///         reverts EthTransferFailed. Nothing is stranded either way: the ETH send is the last step, and a failed send
///         reverts the whole call.
///
///         ERRORS FROM THE POOL. The PoolManager wraps a hook's revert (Gated, BuyCooldown, EarlyBuyTooLarge,
///         PartialFill, SwapTooLarge, RecordOutOfGas) in v4's CustomRevert.WrappedError(hook, selector, reason,
///         details). The router does not catch or re-encode anything: that revert data reaches the caller unchanged,
///         and a front end unwraps WrappedError to the hook's inner selector.
///
///         TOKENS. The pair is fixed at construction to the hook's own qpull() and weth(). QPULL is QPULLToken, a
///         plain ownerless OpenZeppelin ERC-20 with no transfer hooks or fees. Even so, nothing here relies on that:
///         the buy floor is measured at the caller, and a short QPULL transfer into the PoolManager would fail
///         v4's settle accounting (CurrencyNotSettled) rather than be under-charged.
///
///         IMMUTABLE, NO OWNER. Every binding is an immutable, checked in the constructor against the hook's own
///         immutables and isCanonical(): the PoolManager, the WETH and QPULL addresses (and so the currency order),
///         the static fee, the tick spacing, and that the hook address carries the flags the hook requires.
contract QpullSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for BalanceDelta;

    /// @dev v4 TickMath bounds, one step inside so a swap may run to the edge of the full range.
    uint160 internal constant MIN_PRICE_LIMIT = 4_295_128_739 + 1;
    uint160 internal constant MAX_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    /// @dev Every amount v4 can swap fits int128 (Pool.sol toInt128).
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    /// @dev The v4 hook-permission bits live in the low 14 bits of the hook address.
    uint160 internal constant HOOK_FLAG_MASK = (1 << 14) - 1;

    /// @dev Transient slot: keccak256("quopull.QpullSwapRouter.state") - 1. IDLE, ENTERED (inside buy/sell) or
    ///      IN_UNLOCK (inside this contract's own pm.unlock). Transient, so it can never be left set by a revert.
    uint256 internal constant STATE_SLOT = 0x5a426ffcaa018addd9a23cd920f75091fec55ef99e6a9e6e44813ae702b16bb6;
    uint256 internal constant IDLE = 0;
    uint256 internal constant ENTERED = 1;
    uint256 internal constant IN_UNLOCK = 2;

    IPoolManager public immutable poolManager;
    address public immutable weth;
    address public immutable qpull;
    address public immutable hook;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    /// @notice Address-sort order of the canonical pair: true when WETH is currency0.
    bool public immutable wethIsCurrency0;

    /// @notice Stray balances (see the contract notice) forwarded to `to` at the end of a buy or sell. `eth` is ETH
    ///         plus WETH, delivered as WETH on a buy and as ETH on a sell; `qpullAmount` is QPULL.
    event StraySwept(address indexed to, uint256 eth, uint256 qpullAmount);

    // ── swap errors ──
    error Slippage(); // the caller would receive less than its floor
    error Expired(); // block.timestamp > deadline
    error ZeroAmount(); // buy with no ETH, or sell of 0 QPULL
    error ZeroMinOut(); // a zero floor accepts any price; refused
    error SwapTooLarge(); // amount above int128.max (same selector as QpullTaxHook.SwapTooLarge)
    error PartialFill(); // the pool consumed less than the exact input (same selector as QpullTaxHook.PartialFill)
    error EthTransferFailed(); // the sell's ETH could not be delivered to the caller
    error Reentrancy(); // buy or sell entered while one is already running
    error NotPoolManager(); // unlockCallback from anyone but the PoolManager
    error NotInSwap(); // unlockCallback outside this contract's own pm.unlock
    error NotWeth(); // ETH sent directly by anything but WETH.withdraw
    // ── constructor errors ──
    error ZeroAddress();
    error NoCode();
    error HookMismatch(); // an argument disagrees with the hook's immutables, or the address lacks the hook's flags
    error NotCanonicalPool(); // the hook does not accept this key
    error RouterIsExempt(); // the hook names this router as its untaxed exemptSender

    /// @param poolManager_ the Uniswap v4 PoolManager the hook is bound to
    /// @param weth_        the hook's WETH
    /// @param qpull_       the hook's QPULL
    /// @param hook_        the canonical pool's QpullTaxHook
    /// @param fee_         the canonical static LP fee (must equal hook.canonicalFee())
    /// @param tickSpacing_ the canonical tick spacing (must equal hook.canonicalTickSpacing())
    constructor(
        address poolManager_,
        address weth_,
        address qpull_,
        address hook_,
        uint24 fee_,
        int24 tickSpacing_
    ) {
        if (poolManager_ == address(0) || weth_ == address(0) || qpull_ == address(0) || hook_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            poolManager_.code.length == 0 || weth_.code.length == 0 || qpull_.code.length == 0
                || hook_.code.length == 0
        ) revert NoCode();
        IQpullTaxHookBinding h = IQpullTaxHookBinding(hook_);
        // Double entry: every argument must equal the hook's own immutable, so a stale or mistyped value fails here.
        if (
            h.poolManager() != poolManager_ || h.weth() != weth_ || h.qpull() != qpull_ || h.canonicalFee() != fee_
                || h.canonicalTickSpacing() != tickSpacing_
        ) revert HookMismatch();
        // The PoolManager dispatches callbacks by the address bits, so the address must carry exactly what the hook
        // itself requires, or its beforeSwap/afterSwap (and with them the tax) would not run.
        if (uint160(hook_) & HOOK_FLAG_MASK != h.REQUIRED_FLAGS()) revert HookMismatch();
        bool w0 = weth_ < qpull_;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(w0 ? weth_ : qpull_),
            currency1: Currency.wrap(w0 ? qpull_ : weth_),
            fee: fee_,
            tickSpacing: tickSpacing_,
            hooks: hook_
        });
        if (!h.isCanonical(key)) revert NotCanonicalPool();
        // Swaps through this router must be TAXED: it may never be the one sender the hook lets trade for free.
        if (h.exemptSender() == address(this)) revert RouterIsExempt();

        poolManager = IPoolManager(poolManager_);
        weth = weth_;
        qpull = qpull_;
        hook = hook_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        wethIsCurrency0 = w0;
    }

    /// @notice Only WETH.withdraw (inside sell) sends this contract ETH. Anything else is refused, so a mistaken
    ///         plain transfer fails instead of becoming a stray. (ETH forced in without a call cannot be refused; it
    ///         is forwarded by the next buy or sell.) Kept within WETH9's 2,300-gas transfer stipend.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }

    /// @notice The canonical QPULL/WETH pool key this router trades.
    function poolKey() public view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(wethIsCurrency0 ? weth : qpull),
            currency1: Currency.wrap(wethIsCurrency0 ? qpull : weth),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });
    }

    /// @notice BUY QPULL with exactly msg.value of ETH (exact input). The WETH fee is part of that input; the QPULL
    ///         output is untaxed. Packs and leaderboard points are credited by the hook to tx.origin.
    /// @param  minQpullOut the least QPULL the caller accepts, measured at the caller (must be > 0)
    /// @param  deadline    the last block.timestamp at which the buy may execute
    /// @return qpullOut    QPULL the caller received from the swap (strays forwarded on top are not included)
    function buy(uint256 minQpullOut, uint256 deadline) external payable returns (uint256 qpullOut) {
        _enter();
        // A user-chosen deadline; sequencer timestamp skew only moves its edge.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        if (minQpullOut == 0) revert ZeroMinOut();
        if (msg.value > MAX_AMOUNT) revert SwapTooLarge();

        IWETHLike(weth).deposit{ value: msg.value }();
        qpullOut = _unlock(true, msg.sender, msg.value);
        if (qpullOut < minQpullOut) revert Slippage();

        // Strays: QPULL as QPULL, ETH and WETH as WETH (msg.value is already wrapped and paid into the pool).
        uint256 strayQpull = IERC20(qpull).balanceOf(address(this));
        if (strayQpull != 0) IERC20(qpull).safeTransfer(msg.sender, strayQpull);
        uint256 strayEth = address(this).balance;
        if (strayEth != 0) IWETHLike(weth).deposit{ value: strayEth }();
        uint256 strayWeth = IERC20(weth).balanceOf(address(this));
        if (strayWeth != 0) IERC20(weth).safeTransfer(msg.sender, strayWeth);
        if (strayQpull != 0 || strayWeth != 0) emit StraySwept(msg.sender, strayWeth, strayQpull);
        _exit();
    }

    /// @notice SELL exactly `qpullIn` QPULL for ETH (exact input). Approve this router for `qpullIn` QPULL first; the
    ///         tokens move from the caller straight into the PoolManager. The WETH fee (the launch sell rate) comes
    ///         out of the WETH output inside the pool; `ethOut` is what is left and what the caller receives.
    /// @param  qpullIn   QPULL to sell (must be > 0 and fully consumed, or the call reverts PartialFill)
    /// @param  minEthOut the least ETH the caller accepts (must be > 0)
    /// @param  deadline  the last block.timestamp at which the sell may execute
    /// @return ethOut    ETH the swap paid the caller (strays forwarded on top are not included)
    function sell(uint256 qpullIn, uint256 minEthOut, uint256 deadline) external returns (uint256 ethOut) {
        _enter();
        // A user-chosen deadline; sequencer timestamp skew only moves its edge.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        if (qpullIn == 0) revert ZeroAmount();
        if (minEthOut == 0) revert ZeroMinOut();
        if (qpullIn > MAX_AMOUNT) revert SwapTooLarge();

        ethOut = _unlock(false, msg.sender, qpullIn);
        if (ethOut < minEthOut) revert Slippage();

        // Unwrap the output together with any stray WETH, forward stray QPULL, then send every wei of ETH held.
        uint256 wethHeld = IERC20(weth).balanceOf(address(this)); // == ethOut + stray WETH
        IWETHLike(weth).withdraw(wethHeld);
        uint256 strayQpull = IERC20(qpull).balanceOf(address(this));
        if (strayQpull != 0) IERC20(qpull).safeTransfer(msg.sender, strayQpull);
        uint256 ethHeld = address(this).balance; // == ethOut + stray WETH + stray ETH
        if (ethHeld != ethOut || strayQpull != 0) emit StraySwept(msg.sender, ethHeld - ethOut, strayQpull);
        (bool ok,) = msg.sender.call{ value: ethHeld }("");
        if (!ok) revert EthTransferFailed();
        _exit();
    }

    /// @notice v4 callback. Accepted only from the PoolManager, and only while this contract is inside its own
    ///         pm.unlock from buy or sell, so `data` is always what this contract itself encoded.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_state() != IN_UNLOCK) revert NotInSwap();
        (bool isBuy, address user, uint256 amountIn) = abi.decode(data, (bool, address, uint256));

        // BUY: WETH in (zeroForOne iff WETH is currency0). SELL: QPULL in.
        bool zeroForOne = isBuy == wethIsCurrency0;
        // Exact input. buy() and sell() refuse amountIn > int128.max (SwapTooLarge), so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactIn = -int256(amountIn);
        BalanceDelta delta = poolManager.swap(
            poolKey(),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ""
        );
        // The caller-side delta, after the hook's deltas: negative = owed to the pool, positive = owed to us.
        (int128 wethDelta, int128 qpullDelta) =
            wethIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        uint256 out;
        if (isBuy) {
            // Exact-in buy: the whole input, fee included, is owed (the hook itself refuses a short fill).
            if (wethDelta != exactIn || qpullDelta < 0) revert PartialFill();
            _pay(weth, address(this), amountIn); // msg.value, wrapped in buy()
            if (qpullDelta > 0) {
                uint256 bal0 = IERC20(qpull).balanceOf(user);
                // qpullDelta > 0 here, so the cast is exact.
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.take(Currency.wrap(qpull), user, uint256(uint128(qpullDelta)));
                out = IERC20(qpull).balanceOf(user) - bal0; // what the caller actually received
            }
        } else {
            // Exact-in sell: refuse a short fill rather than leave the caller a remainder.
            if (qpullDelta != exactIn || wethDelta < 0) revert PartialFill();
            _pay(qpull, user, amountIn); // straight from the caller into the PoolManager
            if (wethDelta > 0) {
                // wethDelta > 0 here, so the cast is exact.
                // forge-lint: disable-next-line(unsafe-typecast)
                out = uint256(uint128(wethDelta));
                poolManager.take(Currency.wrap(weth), address(this), out);
            }
        }
        return abi.encode(out);
    }

    /// @dev Pay `amount` of `token` into the PoolManager from `from` (this contract, or the seller via transferFrom).
    ///      v4 credits exactly the balance increase between sync and settle.
    function _pay(address token, address from, uint256 amount) internal {
        poolManager.sync(Currency.wrap(token));
        if (from == address(this)) IERC20(token).safeTransfer(address(poolManager), amount);
        else IERC20(token).safeTransferFrom(from, address(poolManager), amount);
        poolManager.settle();
    }

    function _unlock(bool isBuy, address user, uint256 amountIn) internal returns (uint256 out) {
        _setState(IN_UNLOCK);
        bytes memory ret = poolManager.unlock(abi.encode(isBuy, user, amountIn));
        _setState(ENTERED);
        out = abi.decode(ret, (uint256));
    }

    function _enter() internal {
        if (_state() != IDLE) revert Reentrancy();
        _setState(ENTERED);
    }

    function _exit() internal {
        _setState(IDLE);
    }

    function _state() internal view returns (uint256 s) {
        assembly {
            s := tload(STATE_SLOT)
        }
    }

    function _setState(uint256 s) internal {
        assembly {
            tstore(STATE_SLOT, s)
        }
    }
}
