// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ExerciseTestnet } from "../script/ExerciseTestnet.s.sol";

/// @notice script/ExerciseTestnet.s.sol drawRaffle. The raffle engine makes every draw REVEAL BEFORE
///         POP: runDraw reverts RevealPending(cohort, round) while ANY non-empty cohort in its window has an unposted
///         tier round. The helper used to post the round of one caller-named pack only, so as soon as the window held
///         two unrevealed cohorts it reverted. This runs the REAL script entry points (through its env seam) against a
///         real PackRegistry + RaffleEngine with three unrevealed cohorts in the window.
contract ExerciseTestnetDrawTest is Test, ExerciseTestnet {
    uint256 constant GENESIS = 1_000_000;
    uint256 constant DAY = 1 days;
    uint256 constant TICKET = 1e18;

    PackRegistry packs;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    address recorder = makeAddr("recorder");
    address buyer = makeAddr("buyer");

    mapping(bytes32 => address) internal envA;

    function _envAddress(string memory k) internal view override returns (address v) {
        v = envA[keccak256(bytes(k))];
        require(v != address(0), string.concat("test env unset: ", k));
    }

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        MockERC20 quotron = new MockERC20();
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        BaseVault vault = new BaseVault(address(quotron), address(this));
        ClaimManager cm = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(cm), GENESIS, 3, 1, 1_000_000e18, 1000, address(this)
        );
        packs.setRecorder(recorder);
        packs.setEngine(address(raffle));
        cm.setEngine(address(raffle), address(vault));
        vault.setController(address(cm));
        quotron.mint(address(vault), 1_000e18);
        envA[keccak256("ORACLE")] = address(oracle);
        envA[keccak256("RAFFLE_ENGINE")] = address(raffle);
        envA[keccak256("PACK_REGISTRY")] = address(packs);

        // cohorts 0 and 1, then the one-time opening (reveals of both posted, as the keeper does)
        uint256 first0 = _buyOnDay(0, 6);
        uint256 first1 = _buyOnDay(1, 6);
        (, uint64 r0,,) = packs.packs(first0);
        (, uint64 r1,,) = packs.packs(first1);
        oracle.setBeacon(r0, keccak256("reveal0"));
        oracle.setBeacon(r1, keccak256("reveal1"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw(false);
        // three more cohorts whose reveals nobody posts
        _buyOnDay(2, 4);
        _buyOnDay(3, 4);
        _buyOnDay(4, 4);
        vm.warp(GENESIS + 5 * DAY + 2 hours); // currentDay == 5: the draw window of day 4, sweeping cohorts [0, 3]
    }

    function _buyOnDay(uint256 day, uint256 n) internal returns (uint256 firstId) {
        vm.warp(GENESIS + day * DAY + 1);
        firstId = packs.nextPackId();
        vm.prank(recorder);
        packs.recordBuy(buyer, n * TICKET);
    }

    /// The old helper's shape: one named pack's reveal plus the draw round. Cohort 2 is still unrevealed, so it reverts.
    function test_postingOnlyOnePacksReveal_revertsRevealPending() public {
        (, uint64 r3,,) = packs.packs(packs.nextPackId() - 5); // a cohort-3 pack
        oracle.setBeacon(r3, keccak256("reveal3"));
        oracle.setBeacon(raffle.drawRound(4), keccak256("draw4"));
        (, uint64 r2,,) = packs.packs(packs.nextPackId() - 9); // a cohort-2 pack
        vm.expectRevert(abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(2), r2));
        raffle.runDraw(4);
    }

    /// The helper posts every non-empty in-window cohort's round, then the draw round, and the draw runs.
    function test_drawRaffle_postsEveryInWindowCohortReveal_thenDraws() public {
        for (uint32 c = 2; c <= 3; ++c) {
            assertFalse(oracle.isAvailable(_cohortRoundOf(c)), "premise: unrevealed cohort in the window");
        }
        this.drawRaffle(4);
        assertTrue(raffle.drawn(4), "day 4 drawn");
        for (uint32 c = 0; c <= 3; ++c) {
            assertTrue(oracle.isAvailable(_cohortRoundOf(c)), "every in-window cohort's tier round was posted");
        }
        // cohort 4 is outside day 4's window; its reveal round happens to BE drawRound(4) here (revealDelay == REVEAL_LAG
        // == 1h, so both are roundAt(genesis + 5 days + 1 hour)), which is why it is available now
        assertEq(_cohortRoundOf(4), raffle.drawRound(4), "cohort 4's reveal round coincides with day 4's draw round");
    }

    /// The two-argument form still works and cross-checks the named pack's stored round against the formula.
    function test_drawRaffle_withPackId_stillWorks() public {
        uint256 cohort3Pack = packs.nextPackId() - 5;
        (, uint64 stored, uint32 cday,) = packs.packs(cohort3Pack);
        assertEq(cday, 3, "premise: a cohort-3 pack");
        assertEq(stored, _cohortRoundOf(3), "PackRegistry stores exactly the round the helper derives");
        this.drawRaffle(4, cohort3Pack);
        assertTrue(raffle.drawn(4), "day 4 drawn");
    }

    function _cohortRoundOf(uint32 c) internal view returns (uint64) {
        return oracle.roundAt(GENESIS + (uint256(c) + 1) * DAY + 1 hours);
    }
}
