// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPackRegistry, ILeaderboardRegistry } from "../../src/interfaces/IRegistries.sol";

/// @notice Test double for the game registries as seen from QpullTaxHook: records the last
///         notification and can be switched to revert (to prove the hook's try/catch keeps the
///         canonical pool trading when a registry faults). The standalone jackpot registry is gone —
///         the hook now notifies only the pack and leaderboard registries (buys only).
contract MockRecorder is IPackRegistry, ILeaderboardRegistry {
    address public lastTrader;
    uint256 public lastGross;
    uint256 public calls;
    uint256 public totalGross; // wash-trade tests: sum of every credited value
    bool public revertAll;

    function setRevert(bool v) external {
        revertAll = v;
    }

    function recordBuy(address buyer, uint256 grossValue)
        external
        override(IPackRegistry, ILeaderboardRegistry)
    {
        _rec(buyer, grossValue);
    }

    function recordXp(address who, uint256 amount) external override {
        _rec(who, amount);
    }

    function _rec(address a, uint256 g) internal {
        if (revertAll) revert("recorder down");
        lastTrader = a;
        lastGross = g;
        totalGross += g;
        ++calls;
    }
}
