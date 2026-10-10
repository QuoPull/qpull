// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IQuotronRouter } from "../../src/interfaces/IQuotronRouter.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @notice Test double for the Canonical ETH router: receives ETH, mints QUOTRON at `rate` (1e18 = 1:1).
///         `refundBps` (default 0) models a MISBEHAVING router that sends part of msg.value back to the
///         caller and only converts the remainder — the real router is exact-ETH-in and never refunds
///         (fork-verified); this knob exists to test the adapter's refund recapture.
contract MockQuotronRouter is IQuotronRouter {
    MockERC20 public quotron;
    uint256 public rate; // QUOTRON per ETH, 1e18-scaled
    uint256 public refundBps; // share of msg.value refunded to msg.sender (0 = exact-in, like the real router)

    constructor(address quotron_, uint256 rate_) {
        quotron = MockERC20(quotron_);
        rate = rate_;
    }

    function setRefundBps(uint256 bps) external {
        require(bps <= 10_000, "bps");
        refundBps = bps;
    }

    function buyExactEth(uint256 minQuotronOut, address recipient, uint256)
        external
        payable
        returns (uint256 out)
    {
        uint256 refund = (msg.value * refundBps) / 10_000;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{ value: refund }("");
            require(ok, "refund");
        }
        out = ((msg.value - refund) * rate) / 1e18;
        require(out >= minQuotronOut, "slippage");
        quotron.mint(recipient, out);
    }

    function poolKey() external pure returns (address, address, uint24, int24, address) {
        return (address(0), address(0), 0, 0, address(0));
    }
}
