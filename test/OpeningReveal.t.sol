// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { RaffleFlowTest } from "./RaffleFlow.t.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// OPENING-REVEAL REGRESSION SUITE. Same harness as RaffleFlow.
///
/// The bug: runOpeningDraw and runDraw are permissionless, and so is posting a drand round. Before the fix, a
/// draw could run while a swept cohort's tier-reveal round was still unposted. _drawCore popped the winners
/// (spent = true), then _payWinners caught tierOf's revert and emitted WinnerSkipped: the pack was burned with
/// no claim, its share went to its same-tier co-winners, and on the opening path openingDone latched so the
/// sweep could never be re-run. keeper.js posted exactly drawRound(ACCUM_DAYS - 1) before the opening and
/// nothing else, so mainnet would have skipped every launch-day winner, and any holder could do the same
/// deliberately.
///
/// The fix: PackRegistry._drawCore, the single chokepoint both draws share, reverts RevealPending(cohort, round)
/// before popping anything while any NON-EMPTY swept cohort's round is unposted. These tests pin: the revert,
/// that it latches and consumes nothing, that posting the named round lets the SAME call pay every winner, and
/// that empty cohorts do not block.
contract OpeningRevealTest is RaffleFlowTest {
    bytes32 constant SKIPPED = keccak256("WinnerSkipped(uint32,uint256,uint8)");
    bytes32 constant PAID = keccak256("WinnerPaid(uint32,uint256,address,uint8,uint256,uint256)");

    address bob = makeAddr("bob");

    function _count(Vm.Log[] memory logs, bytes32 t) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(raffle) && logs[i].topics.length > 0 && logs[i].topics[0] == t) ++n;
        }
    }

    function _revealRound(uint32 cohort) internal view returns (uint64) {
        return oracle.roundAt(GENESIS + (uint256(cohort) + 1) * DAY + packs.revealDelay());
    }

    function _pendingErr(uint32 cohort, uint64 round) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PackRegistry.RevealPending.selector, cohort, round);
    }

    function _assertNothingSpent(uint256 firstId, uint256 lastIdExcl) internal view {
        for (uint256 id = firstId; id < lastIdExcl; ++id) {
            (,,, bool spent) = packs.packs(id);
            assertFalse(spent, "a reverted draw must not leave any pack spent");
        }
    }

    // ─── the opening ────────────────────────────────────────────────────────────────────────────────────

    /// EXACTLY what keeper.js used to post before the opening, and exactly what an attacker would post: the
    /// opening's own settling round and nothing else. Pre-fix: 5 WinnerSkipped, 0 paid, openingDone latched.
    function test_opening_drawRoundOnly_revertsAndLatchesNothing() public {
        _buy(alice, 100e18); // 10 tickets, all in cohort 0 (launch day)
        (, uint64 rev0,,) = packs.packs(1);
        assertEq(rev0, _revealRound(0), "every cohort-0 pack carries cohort 0's round");
        assertEq(rev0, raffle.drawRound(0), "premise: cohort-0 reveal round == drawRound(0) when revealDelay == REVEAL_LAG");
        assertTrue(rev0 != raffle.drawRound(1), "premise: it is NOT the round the opening reads");

        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // the ONLY beacon posted
        vm.warp(GENESIS + 2 * DAY + 1);
        uint256 liveBefore = packs.liveCount(2);

        vm.expectRevert(_pendingErr(0, rev0));
        raffle.runOpeningDraw(false);

        assertFalse(raffle.openingDone(), "the opening must NOT latch: it stays retryable");
        assertEq(claimMgr.nextClaimId(), 0, "no claim registered");
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved");
        assertEq(packs.liveCount(2), liveBefore, "no ticket popped");
        _assertNothingSpent(1, packs.nextPackId());
        vm.expectRevert(RaffleEngine.OpeningPending.selector);
        raffle.runDraw(2); // and the daily draws stay locked behind the still-pending opening
    }

    /// Recovery: post the round the revert named and the SAME call pays every winner. No skip, ever.
    function test_opening_postingTheNamedRevealPaysEveryWinner() public {
        _buy(alice, 100e18);
        (, uint64 rev0,,) = packs.packs(1);
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1);

        vm.expectRevert(_pendingErr(0, rev0));
        raffle.runOpeningDraw(false);

        oracle.setBeacon(rev0, keccak256("reveal")); // anyone can post it; it published a day ago
        vm.recordLogs();
        raffle.runOpeningDraw(false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 n = raffle.OPENING_WINNERS();
        assertEq(_count(logs, SKIPPED), 0, "no WinnerSkipped once the reveal is posted");
        assertEq(_count(logs, PAID), n, "every opening winner paid");
        assertEq(claimMgr.nextClaimId(), n, "one claim per winner");
        assertTrue(raffle.openingDone(), "the opening settles on the paying call");
        assertEq(packs.liveCount(2), 10 - n, "exactly the winners were popped");
    }

    /// Both opening cohorts are checked, not just cohort 0. With revealDelay != REVEAL_LAG, cohort 1's reveal
    /// round is NOT the opening's settling round either, and pre-fix every cohort-1 winner was skipped too.
    /// The guard names each missing cohort in turn, and nothing moves until both are posted.
    function test_opening_everyNonEmptyCohortIsRequired_revealDelayNotLag() public {
        // fresh stack whose revealDelay (2h) differs from the engine's REVEAL_LAG (1h)
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 2 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this)
        );
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        quotron.mint(address(vault), POT);

        _buy(alice, 50e18); // 5 packs, cohort 0 (ids 1..5)
        vm.warp(GENESIS + DAY + 1);
        _buy(bob, 50e18); // 5 packs, cohort 1 (ids 6..10)
        uint64 rev0 = _revealRound(0);
        uint64 rev1 = _revealRound(1);
        assertTrue(rev1 != raffle.drawRound(1), "premise: with a 2h delay cohort 1's round is not the opening's");

        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 3 hours); // both reveal rounds have published; only the draw round is posted

        vm.expectRevert(_pendingErr(0, rev0)); // the oldest missing cohort is named first
        raffle.runOpeningDraw(false);

        oracle.setBeacon(rev0, keccak256("rev0"));
        vm.expectRevert(_pendingErr(1, rev1)); // cohort 0 alone is not enough
        raffle.runOpeningDraw(false);
        assertFalse(raffle.openingDone(), "still nothing latched");
        _assertNothingSpent(1, packs.nextPackId());

        oracle.setBeacon(rev1, keccak256("rev1"));
        vm.recordLogs();
        raffle.runOpeningDraw(false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SKIPPED), 0, "no skips across both cohorts");
        assertEq(_count(logs, PAID), raffle.OPENING_WINNERS(), "every opening winner paid");
        assertTrue(raffle.openingDone());
    }

    /// An EMPTY cohort pops nothing, so its reveal is irrelevant and must not block the draw. Here launch day
    /// had no buys: cohort 0 is empty and cohort 1's round (== drawRound(1) at the 1h default) is the only one.
    function test_opening_emptyCohortDoesNotBlock() public {
        vm.warp(GENESIS + DAY + 1);
        _buy(alice, 100e18); // cohort 1 only
        assertEq(packs.cohortSize(0), 0, "premise: cohort 0 is empty");
        assertFalse(oracle.isAvailable(_revealRound(0)), "premise: cohort 0's round is NOT posted");
        assertEq(_revealRound(1), raffle.drawRound(1), "premise: cohort 1's round is the opening's round");

        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1 hours + 1);
        raffle.runOpeningDraw(false);
        assertTrue(raffle.openingDone(), "an empty cohort's missing reveal does not block the opening");
        assertEq(claimMgr.nextClaimId(), raffle.OPENING_WINNERS(), "and every winner is paid");
    }

    /// The forgo path pops nothing and reads no beacon, so an unposted reveal must not block a DECLARED forgo.
    function test_opening_forgoIsNotBlockedByAnUnpostedReveal() public {
        _redeployWithMinPot(POT, POT / 2); // underfunded: the opening pot is POT/20 < minPot
        _buy(alice, 100e18);
        vm.warp(GENESIS + 3 * DAY + 1); // past ACCUM_DAYS + FORGO_GRACE_DAYS
        raffle.runOpeningDraw(true); // no reveal and no draw round posted at all
        assertTrue(raffle.openingDone(), "declared forgo settles without touching the oracle");
        assertEq(packs.liveCount(3), 10, "and pops nothing");
    }

    // ─── the daily draw ─────────────────────────────────────────────────────────────────────────────────

    /// The permissionless daily variant: after an outage skipped day 2's draw, nobody posted drawRound(2),
    /// which is also cohort 2's reveal round at the default delay. Anyone can post drawRound(3) and call
    /// runDraw(3) while cohort 2's reveal is still missing. Pre-fix: every cohort-2 winner was skipped and the
    /// day consumed. Now: revert, the day is not consumed, and a retry inside the window pays everyone.
    function test_daily_unpostedNewestCohortReverts_dayNotConsumed_retryPays() public {
        _buy(alice, 100e18); // cohort 0
        _bootstrapOpening(); // posts cohort 0's reveal + the opening round; currentDay() == 2
        _buy(bob, 100e18); // cohort 2 (day 2), ids 11..20
        uint64 rev2 = _revealRound(2);
        assertEq(rev2, raffle.drawRound(2), "premise: cohort 2's reveal is the round a skipped day-2 draw never posted");

        oracle.setBeacon(raffle.drawRound(3), keccak256("d3")); // day 3's settling round, and nothing else
        vm.warp(GENESIS + 4 * DAY + 1); // currentDay() == 4: day 3's only window
        uint256 liveBefore = packs.liveCount(3);
        uint256 claimsBefore = claimMgr.nextClaimId();
        uint256 reservedBefore = vault.unclaimedReserve();

        vm.expectRevert(_pendingErr(2, rev2));
        raffle.runDraw(3);

        assertFalse(raffle.drawn(3), "the day is NOT consumed");
        assertEq(packs.liveCount(3), liveBefore, "no ticket popped");
        assertEq(claimMgr.nextClaimId(), claimsBefore, "no claim registered");
        assertEq(vault.unclaimedReserve(), reservedBefore, "nothing reserved");
        _assertNothingSpent(11, 21);

        oracle.setBeacon(rev2, keccak256("rev2"));
        vm.recordLogs();
        raffle.runDraw(3); // same window, retried
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SKIPPED), 0, "no WinnerSkipped once the reveal is posted");
        assertEq(_count(logs, PAID), K, "all K winners paid");
        assertTrue(raffle.drawn(3), "the paying retry consumes the day");
        assertEq(packs.liveCount(3), liveBefore - K, "exactly K popped");
    }

    /// An OLDER in-window cohort is checked too, not just the newest: here cohort 2's reveal was never posted
    /// and day 5's draw still sweeps it.
    function test_daily_olderInWindowCohortIsCheckedToo() public {
        _buy(alice, 100e18); // cohort 0
        _bootstrapOpening(); // currentDay() == 2
        _buy(bob, 100e18); // cohort 2, reveal never posted
        vm.warp(GENESIS + 4 * DAY + 1);
        _buy(alice, 100e18); // cohort 4
        oracle.setBeacon(_revealRound(4), keccak256("rev4")); // the newest cohort IS revealed
        oracle.setBeacon(raffle.drawRound(5), keccak256("d5"));
        vm.warp(GENESIS + 6 * DAY + 1); // currentDay() == 6: day 5's window, sweeps cohorts [0..4]

        vm.expectRevert(_pendingErr(2, _revealRound(2)));
        raffle.runDraw(5);
        assertFalse(raffle.drawn(5));

        oracle.setBeacon(_revealRound(2), keccak256("rev2"));
        raffle.runDraw(5);
        assertTrue(raffle.drawn(5), "pays once every non-empty in-window cohort is revealed");
    }

    /// A draw that could not pay anyway (sub-minPot) returns before touching tickets or the oracle, so the
    /// guard does not change the void-without-consuming behaviour.
    function test_daily_subMinPotVoidStillReturnsBeforeTheGuard() public {
        _redeployWithMinPot(POT, 10 * POT); // opening pot = 10% of 10*POT = POT == minPot: payable
        _buy(alice, 100e18);
        _bootstrapOpening();
        _buy(bob, 100e18); // cohort 2, reveal never posted
        vm.warp(GENESIS + 4 * DAY + 1);
        // free balance is now below 10 * minPot, so day 3's pot sits under minPot: the void branch
        assertLt((vault.freeBalance() * raffle.capBpsAt(3)) / 10_000, raffle.minPotAt(3), "premise: sub-minPot");
        raffle.runDraw(3); // must not revert RevealPending: it voids before the draw
        assertFalse(raffle.drawn(3), "void does not consume the day");
    }
}
