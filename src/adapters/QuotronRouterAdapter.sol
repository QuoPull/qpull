// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "../utils/NonRenounceableOwnable2Step.sol";
import { ISwapAdapter } from "../interfaces/ISwapAdapter.sol";
import { IQuotronRouter, IWETH } from "../interfaces/IQuotronRouter.sol";

/// @title  QuotronRouterAdapter: production WETH→QUOTRON adapter
/// @notice The concrete `ISwapAdapter` for the QUOTRON leg (router-gated). Pulls WETH,
///         unwraps to native ETH, and buys QUOTRON through Quotron's Canonical ETH router (the 3%
///         fee hook charges automatically). `minOut` is supplied by the caller (the Treasury computes
///         it off-chain, a standard MEV/slippage guard that needs no on-chain quoter).
/// @dev    Only the WETH→QUOTRON path is supported; the QPULL→WETH leg uses a separate adapter for
///         QPULL's own pool (created at launch).
///         Non-renounceable: setTreasury is write-once wiring, and Treasury.lockRouting freezes this adapter,
///         so the owner must always be able to complete that wiring.
contract QuotronRouterAdapter is ISwapAdapter, NonRenounceableOwnable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IQuotronRouter public immutable router;
    address public immutable weth;
    address public immutable quotron;
    address public treasury; // the ONLY authorized caller of swapExactIn
    uint256 public deadlineBuffer = 15 minutes;
    uint256 internal constant MAX_DEADLINE_BUFFER = 1 hours; // upper bound for deadlineBuffer

    event DeadlineBufferSet(uint256 seconds_);
    event TreasurySet(address treasury);
    event SweptETH(address indexed to, uint256 amount);
    event RefundForwarded(address indexed to, uint256 amount); // unexpected router refund recaptured

    error UnsupportedPath();
    error MinOutRequired();
    error NotTreasury();
    error Slippage();
    error BadBuffer();
    error TreasuryAlreadySet(); // setTreasury is write-once
    error ZeroAddress();
    error SweepFailed();

    constructor(address router_, address weth_, address quotron_, address initialOwner)
        Ownable(initialOwner)
    {
        // Zero-address checks: these bindings are immutable with no re-deploy path.
        if (router_ == address(0) || weth_ == address(0) || quotron_ == address(0)) revert ZeroAddress();
        router = IQuotronRouter(router_);
        weth = weth_;
        quotron = quotron_;
    }

    /// @notice Authorize the Treasury as the sole caller of swapExactIn. WRITE-ONCE. Until set,
    ///         swapExactIn is closed (fail-safe).
    function setTreasury(address t) external onlyOwner {
        if (treasury != address(0)) revert TreasuryAlreadySet();
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Owner-only rescue for native ETH stranded in this adapter. In normal
    ///         operation the adapter holds no ETH (WETH is unwrapped and forwarded to the router in the
    ///         same tx); this recovers force-sent ETH. A router refund does not strand here: swapExactIn
    ///         re-wraps and forwards it to the Treasury in the same call. Touches no
    ///         WETH/QUOTRON accounting, the adapter never holds those between calls.
    function sweepETH(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{ value: bal }("");
        if (!ok) revert SweepFailed();
        emit SweptETH(to, bal);
    }

    function setDeadlineBuffer(uint256 s) external onlyOwner {
        if (s == 0 || s > MAX_DEADLINE_BUFFER) revert BadBuffer(); // no overflow / zero deadline
        deadlineBuffer = s;
        emit DeadlineBufferSet(s);
    }

    /// @inheritdoc ISwapAdapter
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != treasury) revert NotTreasury(); // only the Treasury may swap
        if (tokenIn != weth || tokenOut != quotron) revert UnsupportedPath();
        if (minOut == 0) revert MinOutRequired(); // the router rejects minOut==0 (InvalidAmount), always set a floor
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amountIn);
        // Snapshot BEFORE unwrapping so any pre-existing force-sent balance (sweepETH's domain) is not
        // mistaken for this call's refund.
        uint256 ethBefore = address(this).balance;
        IWETH(weth).withdraw(amountIn); // WETH → native ETH
        amountOut = router.buyExactEth{ value: amountIn }(minOut, to, block.timestamp + deadlineBuffer);
        if (amountOut < minOut) revert Slippage(); // enforce the floor locally, not only via the router
        // Router ETH refund: buyExactEth is exact-ETH-in (the router wraps the FULL msg.value and settles it
        // as the v4 exact-input amount), so a refund is not expected. Should one arrive it lands on receive()
        // below and is RECAPTURED rather than reverted on: `treasury` is write-once and Treasury.lockRouting()
        // freezes the adapter binding, so forwarding keeps convert() live and puts the value back into the
        // pipeline (it becomes next batch's wethHeld). The refund is re-wrapped to WETH because the Treasury
        // has no receive(); it goes to msg.sender (the Treasury, the only caller), never to `to`.
        // Bounded: the minOut floor above caps how much of amountIn could come back unconverted.
        uint256 refund = address(this).balance - ethBefore; // >= 0: ETH only leaves via the value call above
        if (refund > 0) {
            IWETH(weth).deposit{ value: refund }();
            IERC20(weth).safeTransfer(msg.sender, refund);
            emit RefundForwarded(msg.sender, refund);
        }
    }

    // Quoting is done OFF-CHAIN: compute minOut from the canonical View quoter and pass it to swapExactIn. An
    // on-chain quoter can be moved within the same block, so none is exposed.

    receive() external payable { } // ETH from WETH.withdraw (and any router refund, forwarded in swapExactIn)
}
