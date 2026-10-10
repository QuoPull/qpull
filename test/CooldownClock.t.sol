// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import { Test } from "forge-std/Test.sol";
import { PackRegistryTestnet } from "../src/testnet/TestnetShortClock.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
contract CooldownClockTest is Test {
    function test_testnetCooldownTracksTheCompressedDay() public {
        MockDrandOracle o = new MockDrandOracle(1_800_000_000, 3);
        // 2 minutes, not the mainnet 1 hours: a testnet registry with a mainnet-sized reveal delay is exactly
        // the combination that puts a cohort's tier round past the pack's own life, and is now rejected.
        PackRegistryTestnet r = new PackRegistryTestnet(address(o), 3e15, 1_800_000_000, 2 minutes, address(this));
        assertEq(r.ADJUST_COOLDOWN(), 5 minutes, "must compress with DAY(), or the re-peg cadence is untestable");
    }
}
