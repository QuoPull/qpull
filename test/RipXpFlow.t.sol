// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// @notice rip-XP (feature a) end-to-end + regressions (a ripped pack is never drawn; rip XP only inside the
///         settle window), the ticket-price rescale (rip XP is RIP_XP_BPS of the cohort's ticket price per unit of
///         rarity weight) and the opening-cohort rip gate.
///         PackRegistry.claimRipXp banks rarity-weighted XP for FINAL non-winning ripped packs into
///         LeaderboardRegistry (PackRegistry is that registry's write-once xpRecorder). Mirrors the
///         RaffleFlow harness (short-day DAY=5m, MockDrandOracle beacons, _bootstrap-style warps).
contract RipXpFlowTest is Test {
    PackRegistry packs;
    LeaderboardRegistry board;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;

    address token = makeAddr("token"); // the recorder (stands in for QpullTaxHook)
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant PERIOD = 30;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)
    uint256 constant POT = 1000e18;
    uint256 constant K = 3;

    // mirrors PackRegistry.RIP_XP_BPS: rip XP per unit of rarity weight, in bps of the cohort ticket price
    uint256 constant RIP_XP_BPS = 180;
    uint256 constant TAX_BPS = 400; // QpullTaxHook: every credited (point-earning) WETH wei paid 4% tax

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        quotron = new MockERC20();
        nft = new MockNFT();

        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        board = new LeaderboardRegistry(GENESIS, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );

        // wiring
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        packs.setLeaderboard(address(board)); // rip-XP sink (write-once)
        board.setXpRecorder(address(packs)); // PackRegistry is the ONLY recordXp caller (write-once)
        board.setRecorder(token); // buys path (unused by most tests but mirrors production wiring)
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        packs.recordBuy(who, grossQpull);
    }

    function _revealCohort0() internal {
        (, uint64 rr,,) = packs.packs(1); // all day-0 packs share one reveal round
        oracle.setBeacon(rr, keccak256("reveal-c0"));
    }

    function _ids1(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    // mirrors PackRegistry.ripXpWeight (Common 1 / Uncommon 2 / Rare 4 / SR 10)
    function _w(uint8 tier) internal pure returns (uint256) {
        if (tier == 3) return 10;
        if (tier == 2) return 4;
        if (tier == 1) return 2;
        return 1;
    }

    // XP a rip of `tier` banks when its cohort's recorded (minimum) ticket price is `price`
    function _xp(uint256 price, uint8 tier) internal pure returns (uint256) {
        return (price * _w(tier) * RIP_XP_BPS) / 10_000;
    }

    // XP at the setUp ticket price (every cohort in the older tests mints at TICKET)
    function _weight(uint8 tier) internal pure returns (uint256) {
        return _xp(TICKET, tier);
    }

    /// Settle the one-time opening so the opening-cohort rip gate releases the opening cohorts [0, 1] for rip XP. Posts
    /// cohort 0's reveal and the opening round, funds the vault, and runs the paid opening at day 2.
    function _settleOpening() internal {
        _revealCohort0();
        quotron.mint(address(vault), POT);
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw(false);
        assertTrue(raffle.openingDone(), "opening settled");
    }

    /// ids 1..n that the opening did not pop
    function _unspent(uint256 n) internal view returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 c;
        for (uint256 id = 1; id <= n; ++id) {
            (,,, bool spent) = packs.packs(id);
            if (!spent) ids[c++] = id;
        }
        assembly { mstore(ids, c) }
    }

    // ─── (a) rip-XP happy path ─────────────────────────────────────────────────

    /// A taxed-buy pack that is revealed, never drawn, and past cohortDay+LIFE_DAYS+1 banks
    /// rarity-weighted XP into the leaderboard week, returns that total, emits RipXpClaimed, sets granted.
    function test_ripXp_happyPath_banksWeightedXp() public {
        _buy(alice, 100e18); // 10 taxed packs, cohort 0 (ids 1..10)
        _settleOpening(); // opening cohorts rip only after the opening has settled
        uint256[] memory ids = _unspent(10); // the opening popped OPENING_WINNERS of them

        vm.warp(GENESIS + 9 * DAY + 1); // today()=9: inside cohort-0 rip window (settled 8, window (8,15])
        uint256 wk = board.currentWeek();

        uint256 expected;
        for (uint256 i; i < ids.length; ++i) {
            expected += _weight(packs.tierOf(ids[i]));
        }
        assertGt(expected, 0, "some XP is earnable");

        uint256 before = board.points(wk, alice);
        vm.expectEmit(true, false, false, true, address(packs));
        emit PackRegistry.RipXpClaimed(alice, ids.length, expected);
        vm.prank(alice);
        uint256 got = packs.claimRipXp(ids);

        assertEq(got, expected, "returns the weighted total");
        assertEq(board.points(wk, alice), before + expected, "banked into leaderboard week points");
        assertEq(board.totalPoints(wk), before + expected, "all-buyer denominator credited too");
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(packs.ripXpGranted(ids[i]), "granted flag set");
        }
    }

    /// Once-only: a second claim on already-granted packs banks 0.
    function test_ripXp_onceOnly_secondClaimGrantsZero() public {
        _buy(alice, 100e18);
        _settleOpening();
        vm.warp(GENESIS + 9 * DAY + 1);

        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1; // includes the opening's spent winners: skipped, never reverts
        }
        vm.prank(alice);
        uint256 first = packs.claimRipXp(ids);
        assertGt(first, 0, "first claim pays");

        uint256 wk = board.currentWeek();
        uint256 mid = board.points(wk, alice);
        vm.prank(alice);
        uint256 second = packs.claimRipXp(ids);
        assertEq(second, 0, "second claim grants nothing");
        assertEq(board.points(wk, alice), mid, "board unchanged on the re-claim");
    }

    /// Mixed batch never reverts: only the eligible pack is credited; owned/unowned, revealed/unrevealed,
    /// in-window/out-of-window, and spent/not-spent are all tolerated in one call.
    function test_ripXp_mixedBatch_creditsOnlyEligible() public {
        // A stand-alone registry-level scenario: packs are spent by calling drawFrom directly as the engine, and
        // the engine's opening is marked settled by mocking openingDone (the opening-cohort rip gate) rather than by running it.
        vm.mockCall(address(raffle), abi.encodeWithSignature("openingDone()"), abi.encode(true));
        // day 0: alice buys 10 in cohort 0 (ids 1..10)
        _buy(alice, 100e18);
        _revealCohort0();

        // day 1: draw cohort 0 (only alice's packs are live) to create SPENT alice packs
        oracle.setBeacon(raffle.drawRound(1), keccak256("d1")); // not needed by drawFrom-directly, kept for parity
        vm.warp(GENESIS + 1 * DAY + 1); // today()=1
        vm.prank(address(raffle)); // engine-only entrypoint; raffle is the bound engine
        uint256[] memory won = packs.drawFrom(keccak256("spend"), 1, 3); // 3 alice packs now spent
        assertEq(won.length, 3, "3 packs spent");

        // day 1: bob buys (cohort 1) -> UNOWNED-by-alice packs (ids 11..12)
        _buy(bob, 20e18);
        uint256 bobId = 11;
        // day 1: alice buys (cohort 1) -> UNREVEALED + not-yet-in-window packs (ids 13..14)
        _buy(alice, 20e18);
        uint256 aliceUnrevealed = 13;

        // a surviving (not spent) alice cohort-0 pack is the ONLY eligible one at day 9
        uint256 eligible;
        for (uint256 id = 1; id <= 10; ++id) {
            (,,, bool spent) = packs.packs(id);
            if (!spent) {
                eligible = id;
                break;
            }
        }
        assertTrue(eligible != 0, "found a surviving cohort-0 pack");

        vm.warp(GENESIS + 9 * DAY + 1); // today()=9: cohort 0 in window; cohort 1 (settled 9) NOT yet, unrevealed

        uint256[] memory batch = new uint256[](4);
        batch[0] = eligible; // owned + revealed + in-window + not-spent -> credited
        batch[1] = won[0]; // owned + SPENT -> skipped
        batch[2] = bobId; // UNOWNED (bob) -> skipped
        batch[3] = aliceUnrevealed; // owned but UNREVEALED + out-of-window -> skipped

        uint256 wk = board.currentWeek();
        uint256 before = board.points(wk, alice);
        uint256 expected = _weight(packs.tierOf(eligible));

        vm.prank(alice);
        uint256 got = packs.claimRipXp(batch); // must NOT revert

        assertEq(got, expected, "only the eligible pack credited");
        assertEq(board.points(wk, alice), before + expected, "board credited by exactly one pack");
        assertTrue(packs.ripXpGranted(eligible), "eligible pack granted");
        assertFalse(packs.ripXpGranted(bobId), "unowned pack untouched");
        assertFalse(packs.ripXpGranted(aliceUnrevealed), "unrevealed pack untouched");
    }

    // ─── access control (recordXp / write-once bindings) ───────────────────────

    function test_recordXp_revertsForNonXpRecorder() public {
        vm.expectRevert(LeaderboardRegistry.NotXpRecorder.selector);
        board.recordXp(alice, 1); // caller = this (not the xpRecorder)
    }

    function test_setXpRecorder_writeOnce_andRejectsZero() public {
        // already set to `packs` in setUp -> a re-set reverts
        vm.expectRevert(LeaderboardRegistry.AlreadySet.selector);
        board.setXpRecorder(makeAddr("attacker"));

        // fresh registry: zero-addr set is refused (same combined guard)
        LeaderboardRegistry fresh = new LeaderboardRegistry(GENESIS, address(this));
        vm.expectRevert(LeaderboardRegistry.AlreadySet.selector);
        fresh.setXpRecorder(address(0));
    }

    function test_setLeaderboard_writeOnce_andRejectsZero() public {
        // already set to `board` in setUp -> a re-set reverts
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        packs.setLeaderboard(makeAddr("attacker"));

        // fresh registry: zero-addr set is refused (same combined guard)
        PackRegistry fresh = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        fresh.setLeaderboard(address(0));
    }

    // ─── a pack can never be BOTH rip-XP'd AND a draw winner ──────

    /// At the registry: a ripped pack leaves the live pool, so no later draw can ever return it.
    /// (The scenario this test used to build, ripping cohort-0 packs while the opening was still PENDING and then
    /// running the opening, is now unreachable by design: the opening-cohort gate holds those rips back until openingDone. It is
    /// pinned from the other side by test_openingCohortsFrozenUntilOpeningSettles and the two tests after it. Here the draw is called directly as the engine.)
    function test_rippedPackCannotAlsoBeDrawn() public {
        vm.mockCall(address(raffle), abi.encodeWithSignature("openingDone()"), abi.encode(true));
        _buy(alice, 100e18); // 10 packs, cohort 0
        _revealCohort0();

        vm.warp(GENESIS + 9 * DAY + 1); // today()=9, cohort-0 window (8,15]
        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            ids[i] = i + 1; // rip ids 1..6, keep 7..10 live
        }
        vm.prank(alice);
        uint256 got = packs.claimRipXp(ids);
        assertGt(got, 0, "packs were ripped for XP");
        assertEq(packs.cohortSize(0), 4, "the ripped packs left the live pool");

        // a draw over cohort 0 (drawDay 1 sweeps [0,0]) asks for more than is live: it can only return 7..10
        vm.prank(address(raffle));
        uint256[] memory won = packs.drawFromPaidOnly(keccak256("after-rip"), 1, 10);
        assertEq(won.length, 4, "only the four un-ripped packs were drawable");
        for (uint256 i; i < won.length; ++i) {
            assertGt(won[i], 6, "a ripped pack is never drawn");
        }
        for (uint256 i; i < 6; ++i) {
            (,,, bool spent) = packs.packs(i + 1);
            assertFalse(spent, "a ripped pack is never marked spent by a later draw");
            assertTrue(packs.ripXpGranted(i + 1), "the pack was rip-XP'd, not drawn");
        }
    }

    // ─── opening cohorts cannot be ripped while the opening is pending ────────────────────────────

    /// The attack this gate prevents: the opening is stuck past day 9, its beacon has been public for a week,
    /// and a holder of spare cohort-0/1 packs rips a chosen subset to reshuffle the candidate index order
    /// until the public beacon seats a pack they keep. The gate refuses every opening-cohort rip until the
    /// engine's own latch is set, so the candidate set is frozen; once the opening settles the same packs rip.
    function test_openingCohortsFrozenUntilOpeningSettles() public {
        _buy(alice, 50e18); // cohort 0, ids 1..5
        vm.warp(GENESIS + DAY + 1);
        _buy(alice, 50e18); // cohort 1, ids 6..10
        _revealCohort0();
        oracle.setBeacon(oracle.roundAt(GENESIS + 2 * DAY + 1 hours), keccak256("reveal-c1"));

        vm.warp(GENESIS + 10 * DAY + 1); // today()=10: BOTH cohorts are inside their rip windows
        assertFalse(raffle.openingDone(), "premise: nobody ran the opening");
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
            assertFalse(packs.isRipXpClaimable(i + 1), "an opening-cohort pack is not rippable while pending");
        }
        vm.prank(alice);
        assertEq(packs.claimRipXp(ids), 0, "a rip attempt banks nothing and never reverts");
        assertEq(packs.cohortSize(0) + packs.cohortSize(1), 10, "the opening's candidate set is untouched");

        // the opening is still callable and sweeps the full, unmodified candidate set
        quotron.mint(address(vault), POT);
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        raffle.runOpeningDraw(false);
        assertEq(claimMgr.nextClaimId(), raffle.OPENING_WINNERS(), "the opening pays from the frozen set");

        // settled: the survivors are now rippable, the opening's winners are not (spent)
        uint256 rippable;
        for (uint256 i; i < 10; ++i) {
            (,,, bool spent) = packs.packs(i + 1);
            assertEq(packs.isRipXpClaimable(i + 1), !spent, "released exactly the non-winners");
            if (!spent) ++rippable;
        }
        vm.prank(alice);
        packs.claimRipXp(ids);
        assertEq(packs.cohortSize(0) + packs.cohortSize(1), 0, "every survivor ripped after the opening");
        assertEq(rippable, 10 - raffle.OPENING_WINNERS());
    }

    /// A FORGONE opening is settled too: it releases the opening cohorts, which the forgo never popped.
    function test_forgoneOpeningReleasesTheCohorts() public {
        _buy(alice, 30e18); // cohort 0, ids 1..3
        _revealCohort0();
        vm.warp(GENESIS + 9 * DAY + 1);
        assertFalse(packs.isRipXpClaimable(1), "pending: held back");
        raffle.runOpeningDraw(true); // vault is empty: a declared forgo, well past the grace day
        assertTrue(raffle.openingDone());
        assertTrue(packs.isRipXpClaimable(1), "forgone opening settled: rippable");
        vm.prank(alice);
        assertGt(packs.claimRipXp(_ids1(1)), 0);
    }

    /// The gate is scoped to the opening cohorts only. A cohort the opening never sweeps (day 2 onward) is
    /// rippable on its normal schedule even while the opening is still pending.
    function test_laterCohortsAreNotGated() public {
        vm.warp(GENESIS + 2 * DAY + 1);
        _buy(alice, 30e18); // cohort 2, ids 1..3
        oracle.setBeacon(oracle.roundAt(GENESIS + 3 * DAY + 1 hours), keccak256("reveal-c2"));
        vm.warp(GENESIS + 11 * DAY + 1); // cohort 2 window (10, 17]
        assertFalse(raffle.openingDone(), "premise: opening still pending");
        assertEq(packs.OPENING_COHORTS(), 2);
        assertTrue(packs.isRipXpClaimable(1), "cohort 2 is outside the opening sweep: not gated");
    }

    // ─── rip XP scales off the ticket price actually paid ──────────────────────────────

    /// The exact formula: RIP_XP_BPS of the cohort ticket price per unit of weight 1/2/4/10.
    function test_ripXp_scalesWithTicketPrice_exactFormula() public {
        assertEq(packs.RIP_XP_BPS(), RIP_XP_BPS, "mirror is in sync");
        assertEq(packs.ripXpWeight(0), 1);
        assertEq(packs.ripXpWeight(1), 2);
        assertEq(packs.ripXpWeight(2), 4);
        assertEq(packs.ripXpWeight(3), 10);

        vm.warp(GENESIS + 2 * DAY + 1);
        uint256 price = 3e15; // the mainnet-shaped 0.003 ETH ticket
        PackRegistry reg = _registryAt(price);
        vm.prank(token);
        reg.recordBuy(alice, 20 * price); // cohort 2, ids 1..20
        assertEq(reg.cohortMinTicketPrice(2), price, "cohort price recorded at mint");
        oracle.setBeacon(oracle.roundAt(GENESIS + 3 * DAY + 1 hours), keccak256("scaled"));
        vm.warp(GENESIS + 11 * DAY + 1);

        uint256[] memory ids = new uint256[](20);
        uint256 expected;
        for (uint256 i; i < 20; ++i) {
            ids[i] = i + 1;
            uint8 t = reg.tierOf(i + 1);
            expected += (price * _w(t) * RIP_XP_BPS) / 10_000;
        }
        vm.prank(alice);
        uint256 got = reg.claimRipXp(ids);
        assertEq(got, expected, "rip XP == sum of price * weight * RIP_XP_BPS / 10_000");
        assertEq((price * 1 * RIP_XP_BPS) / 10_000, 5.4e13, "a Common rip at 0.003 ETH banks 5.4e13 points (1.8%)");
        assertEq((price * 10 * RIP_XP_BPS) / 10_000, 5.4e14, "a Super rare rip banks 5.4e14 points (18%)");
    }

    /// A cohort records the LOWEST price any of its packs paid, so a mid-day re-peg can only lower that
    /// cohort's rip XP, never raise it above RIP_XP_BPS of what a pack actually paid; and a re-peg after the
    /// cohort closed does not touch it at all. Owner re-pegs are the only drift source.
    function test_ripXp_cohortPriceIsTheDayMinimum_repegsCannotInflateIt() public {
        vm.warp(GENESIS + 2 * DAY + 1);
        uint256 p0 = 4e15;
        PackRegistry reg = _registryAt(p0);
        vm.prank(token);
        reg.recordBuy(alice, 10 * p0); // cohort 2 at p0
        assertEq(reg.cohortMinTicketPrice(2), p0);

        uint256 up = (p0 * 125) / 100;
        reg.setTicketPrice(up); // +25% mid-day
        vm.prank(token);
        reg.recordBuy(bob, 10 * up); // same cohort, paid more
        assertEq(reg.cohortMinTicketPrice(2), p0, "an UPWARD re-peg never raises the cohort's rip-XP price");

        vm.warp(block.timestamp + 1 days); // cohort 3 now: this re-peg can only reach cohort 3 onward
        uint256 down = (up * 75) / 100;
        reg.setTicketPrice(down);
        assertEq(reg.cohortMinTicketPrice(2), p0, "a re-peg after the cohort closed does not touch it");
        vm.prank(token);
        reg.recordBuy(bob, 10 * down); // cohort 3
        assertEq(reg.cohortMinTicketPrice(3), down, "the next cohort records the new price");

        // a DOWNWARD re-peg inside a day lowers that day's recorded price for every pack of the cohort
        vm.warp(block.timestamp + 1 days); // cohort 4
        uint256 p4 = reg.ticketPrice();
        vm.prank(token);
        reg.recordBuy(alice, 10 * p4);
        uint256 lower = (p4 * 80) / 100;
        reg.setTicketPrice(lower);
        vm.prank(token);
        reg.recordBuy(bob, 10 * lower);
        assertEq(reg.cohortMinTicketPrice(4), lower, "min over the day: the earlier, dearer packs get the lower scale");
    }

    /// THE SIGN-OFF NUMBER. Over a large sample of real pack rolls, the expected rip XP per non-winning pack
    /// is ~2.45% of the ticket price (analytically 1.36 * 1.80% = 2.448%), so in expectation buying a ticket's
    /// worth earns 1.0245 points per 0.04 of tax: a leaderboard point costs ~390 bps of tax. The old absolute
    /// 1e15 unit made that ~45% XP and ~276 bps.
    function test_ripXp_expectedXpPerPackAndCostPerPoint() public {
        vm.warp(GENESIS + 2 * DAY + 1);
        uint256 price = 3e15;
        PackRegistry reg = _registryAt(price);
        uint256 n = 2000;
        for (uint256 minted; minted < n; minted += 100) {
            vm.prank(token);
            reg.recordBuy(alice, 100 * price);
        }
        oracle.setBeacon(oracle.roundAt(GENESIS + 3 * DAY + 1 hours), keccak256("sample"));
        vm.warp(GENESIS + 11 * DAY + 1);

        uint256 totalXp;
        uint256[] memory batch = new uint256[](200);
        for (uint256 start = 1; start <= n; start += 200) {
            for (uint256 i; i < 200; ++i) batch[i] = start + i;
            vm.prank(alice);
            totalXp += reg.claimRipXp(batch);
        }
        uint256 xpBpsOfPrice = (totalXp * 10_000) / (n * price);
        uint256 costBpsPerPoint = (TAX_BPS * n * price) / (n * price + totalXp);
        emit log_named_uint("sampled packs", n);
        emit log_named_uint("expected rip XP per pack, bps of ticket price (analytic 244.8)", xpBpsOfPrice);
        emit log_named_uint("tax bps per leaderboard point (analytic 390.4)", costBpsPerPoint);
        // analytic E[w] = 1.36 -> 244.8 bps; sampling noise at n=2000 is ~+/-10 bps
        assertGe(xpBpsOfPrice, 225, "E[rip XP] near 2.45% of the ticket");
        assertLe(xpBpsOfPrice, 265, "and at most ~2.5% of it");
        assertGe(costBpsPerPoint, 385, "on the sample, a leaderboard point costs ~3.9% in tax");
        // and the analytic bound itself, from the constants
        uint256 eWeightTimes100 = 80 * 1 + 15 * 2 + 4 * 4 + 1 * 10; // 136
        assertEq((eWeightTimes100 * RIP_XP_BPS) / 100, 244, "E[rip XP] = 2.448% of the ticket price (floor)");
        assertGe((TAX_BPS * 10_000 * 100) / (10_000 * 100 + eWeightTimes100 * RIP_XP_BPS), 390, ">= 390 bps per point");
    }

    function _registryAt(uint256 price) internal returns (PackRegistry reg) {
        reg = new PackRegistry(address(oracle), price, GENESIS, 1 hours, address(this));
        reg.setRecorder(token);
        reg.setEngine(address(raffle));
        board2 = new LeaderboardRegistry(GENESIS, address(this));
        reg.setLeaderboard(address(board2));
        board2.setXpRecorder(address(reg));
    }

    LeaderboardRegistry board2;

    // NOTE: the old free (untaxed) NFT-perk packs were removed with claimFreeEntries. Under the
    // VIRTUAL entry model a free win is never a Pack (nothing enters cohortLive), so "free entries never earn
    // rip-XP" is now STRUCTURAL rather than a ripXpIneligible flag — there is no pack to rip. Test deleted.

    // ─── rip-XP is claimable only inside the one-week settle window ─

    function test_ripWindowBoundaries() public {
        _buy(alice, 30e18); // 3 packs (ids 1..3), cohort 0
        _revealCohort0();
        // Cohort 0 is an opening cohort; settle the opening as a declared forgo (empty vault) so the
        // window boundaries below are tested in isolation, with all three packs still unspent.
        vm.warp(GENESIS + 3 * DAY + 1);
        raffle.runOpeningDraw(true);

        // BEFORE settle: today()=8 == cohortDay+LIFE_DAYS+1 -> NOT yet claimable
        vm.warp(GENESIS + 8 * DAY + 1);
        assertFalse(packs.isRipXpClaimable(1), "not claimable at/ before settle");
        vm.prank(alice);
        assertEq(packs.claimRipXp(_ids1(1)), 0, "grants 0 before the window opens");
        assertFalse(packs.ripXpGranted(1), "a skipped pack is not consumed");

        // INSIDE window: today()=9 -> nonzero
        vm.warp(GENESIS + 9 * DAY + 1);
        uint256 wk = board.currentWeek(); // the leaderboard week the day-9 claim banks into
        assertTrue(packs.isRipXpClaimable(2), "claimable inside the window");
        vm.prank(alice);
        uint256 got = packs.claimRipXp(_ids1(2));
        assertGt(got, 0, "nonzero inside the window");
        assertEq(board.points(wk, alice), got, "banked exactly the in-window XP");

        // last in-window day: today()=15 == settled+RIP_XP_WINDOW -> still claimable
        vm.warp(GENESIS + 15 * DAY + 1);
        assertTrue(packs.isRipXpClaimable(3), "day 15 (settled+7) is the last in-window day");

        // AFTER window: today()=16 -> 0
        vm.warp(GENESIS + 16 * DAY + 1);
        assertFalse(packs.isRipXpClaimable(3), "not claimable after the window closes");
        vm.prank(alice);
        assertEq(packs.claimRipXp(_ids1(3)), 0, "grants 0 after the window closes");
        assertEq(board.points(wk, alice), got, "no extra credit outside the window");
    }
}
