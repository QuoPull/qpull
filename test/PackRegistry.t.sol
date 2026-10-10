// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

contract PackRegistryTest is Test {
    PackRegistry reg;
    MockDrandOracle oracle;

    address token = makeAddr("token");
    address engine = makeAddr("engine");
    address alice = makeAddr("alice");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18; // 10 QPULL per ticket
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30); // 30s drand period
        reg = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        reg.setRecorder(token);
        reg.setEngine(engine);
    }

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        reg.recordBuy(who, grossQpull);
    }

    /// The shared tier round of every pack minted on `cohort` (PackRegistry._mintPacks).
    function _revealRound(uint32 cohort) internal view returns (uint64) {
        return oracle.roundAt(GENESIS + (uint256(cohort) + 1) * DAY + 1 hours);
    }

    /// Post a cohort's tier round, as the keeper's reveal job does. Draws over a non-empty cohort REVERT
    /// RevealPending until this has happened.
    function _revealCohort(uint32 cohort) internal {
        oracle.setBeacon(_revealRound(cohort), keccak256(abi.encode("reveal", cohort)));
    }

    // Reward-gating bindings are write-once (recorder / engine / nft).
    function test_setRecorderWriteOnce() public {
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setRecorder(makeAddr("attacker"));
    }

    function test_setEngineWriteOnce() public {
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setEngine(makeAddr("attacker"));
    }

    function test_setNftWriteOnce() public {
        reg.setNft(makeAddr("nft")); // first set OK
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setNft(makeAddr("nft2"));
    }

    // drawFrom clamps k to MAX_DRAW_K internally, so even the (write-once) engine,
    // or a hypothetical hostile one, cannot pop more than the ceiling of live tickets per call.
    // The draw clamp is its own constant, no longer the per-buy MAX_TICKETS_CEILING.
    function test_drawFromClampsK() public {
        // 300 live tickets in cohort 0 (per-buy cap is 100, so three buys).
        _buy(alice, 1000e18);
        _buy(makeAddr("b1"), 1000e18);
        _buy(makeAddr("b2"), 1000e18);
        assertEq(reg.liveCount(1), 300, "300 live tickets for the day-1 draw");
        _revealCohort(0);

        vm.warp(GENESIS + DAY + 1);
        vm.prank(engine);
        uint256[] memory won = reg.drawFrom(keccak256("b"), 1, type(uint256).max); // ask for "all 300+"
        assertEq(won.length, reg.MAX_DRAW_K(), "k clamped to the 200 ceiling, not 300");
        assertEq(reg.MAX_DRAW_K(), 200, "MAX_DRAW_K == RaffleEngine.MAX_K (asserted in its constructor)");
        assertEq(reg.liveCount(1), 100, "only the clamped 200 were popped; 100 survive");
    }

    // ─── reveal before pop, at the one chokepoint both draws share ───────────────────────────────────────

    /// A non-empty in-window cohort with an unposted tier round reverts the draw, naming the cohort and the
    /// round, on BOTH entrypoints, and pops nothing. Posting that round lets the identical call through.
    function test_drawRevertsNamingCohortAndRound_popsNothing() public {
        _buy(alice, 100e18); // 10 packs, cohort 0
        (, uint64 rr,,) = reg.packs(1);
        assertEq(rr, _revealRound(0));
        vm.warp(GENESIS + DAY + 2 hours); // the round has published; it just is not on the oracle

        bytes memory err = abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(0), rr);
        vm.prank(engine);
        vm.expectRevert(err);
        reg.drawFrom(keccak256("d1"), 1, 4);
        vm.prank(engine);
        vm.expectRevert(err);
        reg.drawFromPaidOnly(keccak256("d1"), 1, 4);
        assertEq(reg.liveCount(1), 10, "nothing popped");
        for (uint256 id = 1; id <= 10; ++id) {
            (,,, bool spent) = reg.packs(id);
            assertFalse(spent, "nothing spent");
        }

        _revealCohort(0);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d1"), 1, 4);
        assertEq(w.length, 4, "the same draw goes through once the round is posted");
    }

    /// Every non-empty cohort in [drawDay-7, drawDay-1] is checked; empty ones are skipped, and cohorts that
    /// have aged out of the window are not required.
    function test_onlyNonEmptyInWindowCohortsAreRequired() public {
        _buy(alice, 20e18); // cohort 0: ages out of day 9's window [2..8]
        vm.warp(GENESIS + 3 * DAY + 1);
        _buy(alice, 20e18); // cohort 3
        vm.warp(GENESIS + 6 * DAY + 1);
        _buy(alice, 20e18); // cohort 6
        vm.warp(GENESIS + 9 * DAY + 1);

        // day 9 sweeps [2..8]: cohorts 2, 4, 5, 7, 8 are empty, cohort 0 is out of window
        // (rounds computed BEFORE the prank: an external view call in the revert args would consume it)
        bytes memory err3 = abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(3), _revealRound(3));
        bytes memory err6 = abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(6), _revealRound(6));
        vm.prank(engine);
        vm.expectRevert(err3);
        reg.drawFrom(keccak256("d9"), 9, 10);

        _revealCohort(3);
        vm.prank(engine);
        vm.expectRevert(err6);
        reg.drawFrom(keccak256("d9"), 9, 10);

        _revealCohort(6); // cohort 0's round is still unposted, and does not matter
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d9"), 9, 10);
        assertEq(w.length, 4, "drew both in-window cohorts, and nothing from the aged-out one");
        for (uint256 i; i < w.length; ++i) assertGt(w[i], 2, "never a cohort-0 pack");
    }

    /// An entirely empty window needs no reveal at all and returns no winners, as before.
    function test_emptyWindowNeedsNoReveal() public {
        vm.warp(GENESIS + DAY + 1);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("empty"), 1, 5);
        assertEq(w.length, 0);
    }

    // ─── rip-XP scale is recorded per cohort, not per pack ───────────────────────────────────────────────

    function test_cohortMinTicketPrice_recordedOncePerCohort() public {
        assertEq(reg.cohortMinTicketPrice(0), 0, "unset before the first minting buy");
        _buy(alice, 9e18); // mints nothing: nothing to record
        assertEq(reg.cohortMinTicketPrice(0), 0, "a buy that mints no pack records nothing");
        _buy(alice, 100e18); // mints
        assertEq(reg.cohortMinTicketPrice(0), TICKET, "first minting buy records the price it paid");
        vm.warp(GENESIS + 1 days + 1);
        reg.setTicketPrice(TICKET + 1e18);
        _buy(alice, 110e18);
        assertEq(reg.cohortMinTicketPrice(0), TICKET, "a closed cohort is never rewritten");
        assertEq(reg.cohortMinTicketPrice(1), TICKET + 1e18, "the new cohort records the re-pegged price");
    }

    function test_mint_floorsAndBanksRemainder() public {
        _buy(alice, 25e18); // 25/10 = 2 tickets, 5 remainder
        assertEq(reg.nextPackId(), 3, "two ids minted");
        assertEq(reg.bankedRemainder(alice), 5e18, "5 banked");

        _buy(alice, 5e18); // 5 banked + 5 = 10 -> 1 ticket
        assertEq(reg.nextPackId(), 4, "third minted");
        assertEq(reg.bankedRemainder(alice), 0, "bank cleared");
    }

    function test_dustBelowMinMintsNothing() public {
        _buy(alice, 9e18); // below 10 -> 0 tickets, all banked
        assertEq(reg.nextPackId(), 1, "no ids");
        assertEq(reg.bankedRemainder(alice), 9e18);
    }

    function test_cohortAssignment() public {
        _buy(alice, 100e18); // 10 tickets, day 0
        assertEq(reg.cohortSize(0), 10);

        vm.warp(GENESIS + 1 * DAY + 1);
        _buy(alice, 50e18); // 5 tickets, day 1
        assertEq(reg.today(), 1);
        assertEq(reg.cohortSize(1), 5);
        assertEq(reg.cohortSize(0), 10);
    }

    function test_drawSelectsDistinctFromWindow() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0
        _revealCohort(0);
        vm.warp(GENESIS + 1 * DAY + 1); // day 1

        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d1"), 1, 4);

        assertEq(w.length, 4, "drew 4");
        for (uint256 i; i < 4; ++i) {
            assertTrue(w[i] >= 1 && w[i] <= 10, "in range");
            for (uint256 j = i + 1; j < 4; ++j) {
                assertTrue(w[i] != w[j], "distinct");
            }
        }
        assertEq(reg.liveCount(1), 6, "6 remain live");
    }

    function test_drawCapsAtAvailable() public {
        _buy(alice, 30e18); // 3 tickets
        _revealCohort(0);
        vm.warp(GENESIS + 1 * DAY + 1);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d1"), 1, 10); // ask 10, only 3 live
        assertEq(w.length, 3, "capped at live count");
        assertEq(reg.liveCount(1), 0);
    }

    function test_expiryWindowSlides() public {
        _buy(alice, 100e18); // cohort 0, eligible days 1..7
        assertEq(reg.liveCount(7), 10, "still live on last eligible day");

        vm.warp(GENESIS + 8 * DAY + 1);
        assertEq(reg.liveCount(8), 0, "expired: cohort 0 out of window on day 8");
    }

    function test_tierDerivationSealedThenRevealed() public {
        _buy(alice, 10e18); // pack 1
        (, uint64 rr,,) = reg.packs(1); // the pack's actual (quantized) reveal round

        vm.expectRevert(); // sealed: round not yet published
        reg.tierOf(1);

        oracle.setBeacon(rr, keccak256("beacon"));
        uint8 t = reg.tierOf(1);
        assertLe(t, 3, "valid tier");
    }

    /// Fuzz: draws never exceed the live set and never repeat a pack across a day's draw.
    function testFuzz_drawNeverExceedsOrRepeats(uint256 buyAmt, uint256 k) public {
        buyAmt = bound(buyAmt, TICKET, 500 * TICKET); // up to 500 tickets requested
        k = bound(k, 1, 100);
        _buy(alice, buyAmt);
        uint256 minted = buyAmt / TICKET;
        uint256 cap = reg.maxTicketsPerBuy(); // a buy mints at most the cap; rest is banked
        if (minted > cap) minted = cap;
        _revealCohort(0);

        vm.warp(GENESIS + 1 * DAY + 1);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("fuzz"), 1, k);

        assertLe(w.length, minted, "never more than minted");
        assertLe(w.length, k, "never more than requested");
        // uniqueness
        for (uint256 i; i < w.length; ++i) {
            for (uint256 j = i + 1; j < w.length; ++j) {
                assertTrue(w[i] != w[j], "no repeats");
            }
        }
        assertEq(reg.liveCount(1), minted - w.length, "live set decremented exactly");
    }

    // ─── bounded ticket-price re-peg (§13.4) ─────────────────────────────────

    function test_setTicketPrice_withinBoundsUpdatesAndEmits() public {
        uint256 up = TICKET * 125 / 100; // +25% exactly (upper bound)
        vm.expectEmit(true, true, true, true);
        emit PackRegistry.TicketPriceSet(TICKET, up);
        reg.setTicketPrice(up);
        assertEq(reg.ticketPrice(), up, "price updated to +25%");

        vm.warp(GENESIS + 1 days + 1); // clear cooldown
        uint256 down = up * 75 / 100; // −25% exactly (lower bound)
        reg.setTicketPrice(down);
        assertEq(reg.ticketPrice(), down, "price updated to -25%");
    }

    function test_setTicketPrice_revertsAboveBound() public {
        vm.expectRevert(PackRegistry.AdjustOutOfBounds.selector);
        reg.setTicketPrice(TICKET * 125 / 100 + 1); // one wei above +25%
    }

    function test_setTicketPrice_revertsBelowBound() public {
        vm.expectRevert(PackRegistry.AdjustOutOfBounds.selector);
        reg.setTicketPrice(TICKET * 75 / 100 - 1); // one wei below −25%
    }

    function test_setTicketPrice_cooldownEnforced() public {
        reg.setTicketPrice(TICKET + 1e18); // first re-peg ok (within +25%)
        vm.expectRevert(PackRegistry.AdjustTooSoon.selector);
        reg.setTicketPrice(TICKET + 2e18); // same day → too soon

        vm.warp(GENESIS + 1 days + 1);
        reg.setTicketPrice(TICKET + 2e18); // a day later → ok
        assertEq(reg.ticketPrice(), TICKET + 2e18);
    }

    function test_setTicketPrice_zeroReverts() public {
        vm.expectRevert(PackRegistry.TicketPriceZero.selector);
        reg.setTicketPrice(0);
    }

    function test_setTicketPrice_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // Ownable: caller is not the owner
        reg.setTicketPrice(TICKET + 1e18);
    }

    function test_setTicketPrice_takesEffectOnMinting() public {
        // Under the launch price (10 QPULL), a 25-QPULL buy = 2 tickets + 5 banked.
        // After re-pegging to 12.5 QPULL, the same 25-QPULL buy = 2 tickets + 0 banked.
        reg.setTicketPrice(125e17); // 12.5e18, +25%
        _buy(alice, 25e18);
        assertEq(reg.nextPackId(), 3, "2 tickets at the new price");
        assertEq(reg.bankedRemainder(alice), 0, "no remainder at 12.5 (proves new price in effect)");
    }

    function test_constructor_zeroTicketPriceReverts() public {
        vm.expectRevert(PackRegistry.TicketPriceZero.selector);
        new PackRegistry(address(oracle), 0, GENESIS, 1 hours, address(this));
    }

    // ─── (c) rollOf / tierAndRollOf (verifiable rip) ──────────────────────────

    // mirrors PackRegistry._tierFromRoll (the fixed, published rarity bands)
    function _tierFromRoll(uint256 roll) internal pure returns (uint8) {
        if (roll < 100) return 3; // SUPER_RARE 1%
        if (roll < 500) return 2; // RARE 4%
        if (roll < 2000) return 1; // UNCOMMON 15%
        return 0; // COMMON 80%
    }

    function test_rollOf_revertsBeforeReveal() public {
        _buy(alice, 10e18); // pack 1
        vm.expectRevert(); // sealed: the reveal round's beacon is not yet published
        reg.rollOf(1);
    }

    function test_rollOf_inRangeAndMatchesTier() public {
        _buy(alice, 100e18); // 10 packs, cohort 0
        (, uint64 rr,,) = reg.packs(1); // all day-0 packs share one reveal round
        oracle.setBeacon(rr, keccak256("beacon"));

        for (uint256 id = 1; id <= 10; ++id) {
            uint256 roll = reg.rollOf(id);
            assertLt(roll, 10_000, "roll in [0,10000)");
            // _tierFromRoll(rollOf(id)) == tierOf(id)
            assertEq(_tierFromRoll(roll), reg.tierOf(id), "tier derived from the roll matches tierOf");

            // tierAndRollOf returns the matching (tier, roll) pair
            (uint8 t, uint256 r) = reg.tierAndRollOf(id);
            assertEq(r, roll, "tierAndRollOf roll matches rollOf");
            assertEq(t, reg.tierOf(id), "tierAndRollOf tier matches tierOf");
        }
    }

    function test_tierAndRollOf_revertsBeforeReveal() public {
        _buy(alice, 10e18);
        vm.expectRevert(); // rollOf() reverts until the round reveals
        reg.tierAndRollOf(1);
    }

    /// The ticket-price re-peg cooldown must be on the SAME virtual clock as everything else, or the one
    /// recurring owner duty in the protocol can never be rehearsed.
    ///
    /// It used to be `uint256 public constant ADJUST_COOLDOWN = 1 days` -- the only adjust-cooldown in the
    /// protocol not derived from a virtual clock, while all four of RaffleEngine's use DAY(). On the testnet
    /// short clock DAY() is 5 minutes, so a hardcoded day was 288 compressed days; and because
    /// `lastTicketAdjust` starts at 0 the FIRST re-peg is free, a testnet run got exactly one re-peg ever
    /// and could never exercise the cadence. Being unable to rehearse a recurring duty is how it goes wrong
    /// for the first time in production.
    function test_adjustCooldownIsOnTheVirtualClock() public view {
        assertEq(reg.ADJUST_COOLDOWN(), 1 days, "mainnet: exactly one day, unchanged");
    }

    /// The first re-peg is free (lastTicketAdjust == 0), the second must wait exactly one DAY() -- so the
    /// cadence is now walkable on a compressed clock instead of taking a real 24 hours.
    function test_repegCadenceIsWalkable() public {
        uint256 start = reg.ticketPrice();
        reg.setTicketPrice(start + start / 10); // free: lastTicketAdjust starts at 0
        assertEq(reg.ticketPrice(), start + start / 10, "first re-peg lands");

        vm.expectRevert(PackRegistry.AdjustTooSoon.selector);
        reg.setTicketPrice(start); // immediately after: refused

        vm.warp(block.timestamp + reg.ADJUST_COOLDOWN());
        reg.setTicketPrice(start); // exactly one DAY() later: allowed
        assertEq(reg.ticketPrice(), start, "second re-peg lands after exactly one DAY()");
    }
}
