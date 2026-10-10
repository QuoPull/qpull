// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { PackRegistryTestnet } from "../src/testnet/TestnetShortClock.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// @notice `revealDelay` was a constructor param with HARDCODED bounds (>= 1 hours, < 1 days) while every
///         sibling cadence had already been converted to a virtual getter. On the 5-minute testnet clock a
///         pack's entire 7-day life is 35 minutes, so a 1-hour floor put its tier round PAST the pack's own
///         death. The mock oracle hid it -- a mock stores a beacon for a round drand has not reached -- so
///         the defect only bites under a REAL oracle, where every paid winner becomes WinnerSkipped.
///         RaffleEngineTestnet.REVEAL_LAG's comment already names this exact failure ("a real-oracle testnet
///         draw could never settle"); it was fixed there and missed here because this one is not a getter.
contract RevealDelayBoundsTest is Test {
    uint256 constant GEN = 1_800_000_000;
    MockDrandOracle o;

    function setUp() public {
        o = new MockDrandOracle(GEN, 3);
    }

    function _mainnet(uint256 d) internal returns (PackRegistry) {
        return new PackRegistry(address(o), 3e15, GEN, d, address(this));
    }

    function _testnet(uint256 d) internal returns (PackRegistryTestnet) {
        return new PackRegistryTestnet(address(o), 3e15, GEN, d, address(this));
    }

    // ── mainnet is UNCHANGED. This is the regression guard on the whole change: making the bounds virtual
    //    must not move a single mainnet value.
    function test_mainnetBoundsAreExactlyWhatTheyWere() public {
        PackRegistry r = _mainnet(1 hours);
        assertEq(r.MIN_REVEAL_DELAY(), 1 hours, "mainnet floor moved");
        assertEq(r.MAX_REVEAL_DELAY(), 1 days, "mainnet ceiling moved");
        vm.expectRevert(PackRegistry.BadRevealDelay.selector);
        _mainnet(1 hours - 1);
        vm.expectRevert(PackRegistry.BadRevealDelay.selector);
        _mainnet(1 days);
    }

    // ── the bug itself: a testnet registry must REFUSE a mainnet-sized reveal delay.
    function test_testnetRejectsAMainnetSizedRevealDelay() public {
        vm.expectRevert(PackRegistry.BadRevealDelay.selector);
        _testnet(1 hours);
    }

    function test_testnetBoundsCompress() public {
        PackRegistryTestnet r = _testnet(2 minutes);
        assertEq(r.MIN_REVEAL_DELAY(), 1 minutes, "floor must track the engines' REVEAL_LAG (1 minute)");
        assertEq(r.MAX_REVEAL_DELAY(), 5 minutes, "ceiling must equal the compressed DAY()");
        assertEq(r.revealDelay(), 2 minutes);
        vm.expectRevert(PackRegistry.BadRevealDelay.selector);
        _testnet(1 minutes - 1);
        vm.expectRevert(PackRegistry.BadRevealDelay.selector);
        _testnet(5 minutes);
    }

    // ── THE PROPERTY THE BOUNDS EXIST FOR, asserted rather than assumed.
    //    A cohort's tier round is roundAt(genesis + (c+1)*DAY() + revealDelay). That cohort's FIRST draw runs
    //    during day c+2, i.e. from genesis + (c+2)*DAY(). The round is therefore readable in time IFF
    //    revealDelay < DAY() -- which is exactly what MAX_REVEAL_DELAY derives. ADJUST_COOLDOWN() is DAY()
    //    exposed publicly, so the test can do the arithmetic the contract does.
    function _assertRevealLandsBeforeTheFirstDraw(PackRegistry r, uint256 delay) internal view {
        uint256 day = r.ADJUST_COOLDOWN(); // == DAY()
        uint32 c = 9;
        uint256 revealAt = GEN + (uint256(c) + 1) * day + delay;
        uint256 firstDrawOpensAt = GEN + (uint256(c) + 2) * day;
        assertLt(revealAt, firstDrawOpensAt, "tier round lands after the cohort's first draw -- unsettleable");
    }

    function test_anyAcceptedDelayRevealsBeforeTheCohortsFirstDraw() public {
        _assertRevealLandsBeforeTheFirstDraw(_mainnet(1 hours), 1 hours);
        _assertRevealLandsBeforeTheFirstDraw(_mainnet(1 days - 1), 1 days - 1);
        _assertRevealLandsBeforeTheFirstDraw(_testnet(1 minutes), 1 minutes);
        _assertRevealLandsBeforeTheFirstDraw(_testnet(5 minutes - 1), 5 minutes - 1);
    }

    // The ceiling is the binding constraint, so prove it is tight: one second over and the property fails.
    function test_theCeilingIsTightNotArbitrary() public {
        PackRegistryTestnet r = _testnet(2 minutes);
        uint256 day = r.ADJUST_COOLDOWN();
        assertEq(r.MAX_REVEAL_DELAY(), day, "ceiling must BE DAY(), not merely near it");
        uint32 c = 9;
        assertEq(GEN + (uint256(c) + 1) * day + day, GEN + (uint256(c) + 2) * day, "at the ceiling they coincide");
    }
}

// ── THE EMPTY-WINDOW CASE IS NOT TESTABLE HERE, AND THAT IS THE GOOD OUTCOME.
//    A subclass that compresses DAY() (which MAX_REVEAL_DELAY derives from) but leaves MIN_REVEAL_DELAY at
//    the mainnet hour has a 1-hour floor under a 5-minute ceiling. Every override in this codebase returns a
//    LITERAL, so `MIN_REVEAL_DELAY() >= MAX_REVEAL_DELAY()` constant-folds to true, the constructor becomes
//    unconditionally reverting, the optimizer drops the immutable assignments as dead code, and solc refuses
//    the contract outright: "Some immutables were read from but never assigned". The mistake cannot reach a
//    chain, so there is no runtime behaviour left to assert -- writing the fixture only breaks the build.
//    PackRegistry keeps the explicit RevealDelayWindowEmpty check anyway: it costs nothing (it folds away
//    when the bounds are constants) and it still catches a future override computed from state, which the
//    compiler cannot fold and therefore cannot reject.
