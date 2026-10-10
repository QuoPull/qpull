// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IDrandOracle } from "../../src/interfaces/IDrandOracle.sol";

/// @notice Test-only oracle. Lets tests set/withhold beacons and drives roundAt deterministically.
contract MockDrandOracle is IDrandOracle {
    uint256 public gen;
    uint256 public per;
    mapping(uint64 => bytes32) internal _r;
    mapping(uint64 => bool) internal _ok;

    constructor(uint256 gen_, uint256 per_) {
        gen = gen_;
        per = per_;
    }

    uint64 public highestRound; // mirrors BlsDrandOracle's high-water mark

    function setBeacon(uint64 round, bytes32 rnd) external {
        _r[round] = rnd;
        _ok[round] = true;
        if (round > highestRound) highestRound = round;
    }

    /// @dev Test-only: move the high-water mark WITHOUT storing a beacon, so a suite can stage
    ///      "the chain is alive past round r, but r itself never landed": the reveal fallback's evidence.
    function setHighestRound(uint64 round) external {
        highestRound = round;
    }

    function isAvailable(uint64 round) external view returns (bool) {
        return _ok[round];
    }

    function randomness(uint64 round) external view returns (bytes32) {
        require(_ok[round], "unavailable");
        return _r[round];
    }

    function roundAt(uint256 ts) external view returns (uint64) {
        if (ts <= gen) return 1;
        // CEIL — matches the production oracles (first round at/AFTER `ts`).
        return uint64((ts - gen + per - 1) / per) + 1;
    }
}
