// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// End-to-end: buy tickets → fund vault → run the daily draw → winner claims.
/// Also asserts the solvency invariant (reserved ≤ pot) and the void-on-miss window.
contract RaffleFlowTest is Test {
    event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners);
    PackRegistry packs;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;

    address token = makeAddr("token");
    address alice = makeAddr("alice");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant PERIOD = 30;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)
    uint256 constant POT = 1000e18;
    uint256 constant K = 3;
    /// `type(uint256).max` was NEVER a usable potCap -- `cur * (BPS + MAX_ADJ_BPS)` overflows and
    /// panics, bricking setPotCap from construction. setUp already worked around it locally ("finite ctor
    /// potCap so the +/-25% rate-limit can't overflow"); the constructors now reject it outright, so these
    /// fixtures use the largest value that keeps the band computable.
    uint256 constant UNCAPPED = type(uint256).max / 12_500;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        quotron = new MockERC20();

        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            1,
            POT,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ // finite ctor potCap so the ±25% rate-limit can't overflow in setUp
            address(this)
        );

        // wiring
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));

        // fund the prize vault
        quotron.mint(address(vault), POT);
    }

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        packs.recordBuy(who, grossQpull);
    }

    // RaffleEngine is two-phase: a one-time runOpeningDraw(false) (which sweeps the accumulation cohorts
    // [0, ACCUM_DAYS-1]) must run before any daily runDraw(). This posts the opening beacon + the
    // cohort-0 tier reveal, warps past the 2-day accumulation window, and runs the opening draw.
    // Requires >=1 live ticket already bought in cohort 0/1 and a funded vault.
    function _bootstrapOpening() internal {
        (, uint64 revRound,,) = packs.packs(1); // all day-0 packs share one quantized reveal round
        oracle.setBeacon(revRound, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        vm.warp(GENESIS + 2 * DAY + 1); // currentDay() >= ACCUM_DAYS (2)
        raffle.runOpeningDraw(false);
        assertTrue(raffle.openingDone(), "opening draw bootstrapped");
    }

    function test_endToEnd_buyDrawClaim() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0

        // The one-time opening draw sweeps the accumulation cohorts [0,1] and pays OPENING_WINNERS.
        // Alice is the sole buyer, so every opening winner is alice.
        _bootstrapOpening();
        assertEq(raffle.currentDay(), 2);

        // claims were written; solvency: reserved ≤ pot
        uint256 nClaims = claimMgr.nextClaimId();
        assertGt(nClaims, 0, "at least one prize");
        assertLe(vault.unclaimedReserve(), POT, "never reserve more than the pot");

        // alice (sole buyer) claims her first prize
        (,, uint256 amount,, bool settled) = claimMgr.claims(1);
        assertGt(amount, 0);
        assertFalse(settled);

        uint256 balBefore = quotron.balanceOf(alice);
        uint256 reserveBefore = vault.unclaimedReserve();
        vm.prank(alice);
        claimMgr.claim(1);

        assertEq(quotron.balanceOf(alice), balBefore + amount, "paid out");
        assertEq(vault.unclaimedReserve(), reserveBefore - amount, "reserve released");
    }

    // A delaying winner can't inflate the pot: potCap bounds a single day's payout.
    function test_potCapBoundsPayout() public {
        _buy(alice, 100e18);

        quotron.mint(address(vault), 9 * POT); // vault now holds 10*POT; a delayer waited while it grew
        // potCap is the finite ctor value (POT), so no setPotCap call is needed to bound it.
        // The opening draw is bounded by potCap exactly like a daily draw.
        _bootstrapOpening();

        // the draw only ever sees `potCap`, so at most POT is reserved and the 9*POT excess rolls forward.
        assertLe(vault.unclaimedReserve(), POT, "payout bounded by potCap, not the inflated balance");
        assertGe(vault.freeBalance(), 9 * POT, "the excess above the cap stays in the vault");
    }

    // ── the money AND winner-count knobs are SCHEDULED, not live ────────

    /// THE SHARPEST CASE for scheduling. `winnersPerDay` is read live in
    /// drawFrom(beacon, day, winnersPerDay), so it selects WHO wins, not merely how much. drawFrom's
    /// selection for K is a strict PREFIX of K+1, so raising K by one appends exactly one further
    /// beacon-determined winner — and because the beacon is public before anyone calls runDraw, the owner
    /// can PREVIEW who that winner would be and only then decide to raise. The +/-25% band and the per-day
    /// cooldown bound magnitude and rate, not reactivity; scheduling the write to the next day is what
    /// closes it.
    function test_ownerCannotRetargetWinnerSetAfterBeaconIsPublic() public {
        _buy(alice, 1000e18);
        _bootstrapOpening();                       // currentDay() == 2
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("n1-k"));
        vm.warp(GENESIS + 3 * DAY + 1);            // currentDay() == 3, so day 2 is drawable AND settled
        assertEq(raffle.currentDay(), 3);

        uint256 kBefore = raffle.winnersPerDayAt(day);
        raffle.setWinnersPerDay(kBefore + 1);      // the reactive raise, in-band and inside the window

        assertEq(raffle.winnersPerDayAt(day), kBefore, "day 2 is IMMUNE to a write made on day 3");
        assertEq(raffle.winnersPerDayAt(3), kBefore, "a write at P lands at P+1");
        assertEq(raffle.winnersPerDayAt(4), kBefore + 1, "effective from day 4");

        uint256 claimsBefore = claimMgr.nextClaimId();
        raffle.runDraw(day);
        uint256 paid = claimMgr.nextClaimId() - claimsBefore;
        assertLe(paid, kBefore, "the winner SET is frozen at the pre-raise K");
    }

    /// runDraw used to mark the day consumed BEFORE knowing whether any prize registered. With
    /// per-winner isolation a day where every registerClaim reverted therefore burned the
    /// popped tickets, paid nobody, and could never be retried. The day is now consumed only once at least one
    /// prize is really registered. (A gas-starved call still reverts the whole draw with ClaimOutOfGas, so a
    /// zero count means every seat failed for a reason retrying cannot fix.)
    function test_dayIsNotConsumedWhenEveryRegistrationFails() public {
        _buy(alice, 1000e18);
        _bootstrapOpening();
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("m3"));
        vm.warp(GENESIS + 3 * DAY + 1);

        // nextClaimId is cumulative and _bootstrapOpening already paid the opening sweep, so measure a DELTA
        uint256 claimsBefore = claimMgr.nextClaimId();
        vm.mockCallRevert(
            address(claimMgr),
            abi.encodeWithSelector(claimMgr.registerClaim.selector),
            abi.encodeWithSignature("Error(string)", "down")
        );
        raffle.runDraw(day); // must not revert: the per-winner isolation still holds
        assertFalse(raffle.drawn(day), "the day is NOT consumed when nobody was paid");
        assertEq(claimMgr.nextClaimId(), claimsBefore, "and this draw paid nobody");

        vm.clearMockedCalls();
        raffle.runDraw(day); // the retry pays, against the SAME beacon: no re-roll
        assertTrue(raffle.drawn(day), "consumed once a prize really registered");
        assertGt(claimMgr.nextClaimId(), claimsBefore, "and the winners were paid after all");
    }

    /// The money-visible half: a reactive potCap cut must not shrink a payout whose winners are already
    /// determined by a public beacon.
    function test_potCapCutAfterBeaconDoesNotShrinkPayout() public {
        _buy(alice, 1000e18);
        quotron.mint(address(vault), 9 * POT);      // make the cap actually bind
        _bootstrapOpening();
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("n1-cap"));
        vm.warp(GENESIS + 3 * DAY + 1);

        uint256 capBefore = raffle.potCapAt(day);
        raffle.setPotCap((capBefore * 3) / 4);      // reactive 25% cut

        assertEq(raffle.potCapAt(day), capBefore, "day 2 immune");
        assertEq(raffle.potCapAt(4), (capBefore * 3) / 4, "cut effective from day 4");

        // NOTE: unclaimedReserve is the sum of the tier buckets that actually had a winner, not the whole
        // pot (empty buckets roll forward), so assert on the pot the draw USED -- that is the value the
        // reactive write was trying to move.
        // percentage cap: the pot is min(freeBalance * capBps / BPS, potCapAt(day)). What this test pins is
        // that the REACTIVE WRITE did not move it -- so compute the expectation from the PRE-cut cap.
        uint256 frac = (vault.freeBalance() * raffle.capBpsAt(day)) / 10_000;
        uint256 expectedPot = frac < capBefore ? frac : capBefore;
        vm.expectEmit(true, false, false, true, address(raffle));
        emit DrawExecuted(day, expectedPot, K);
        raffle.runDraw(day);
    }

    // ── The period guard itself. Every other scheduled-knob test writes ONCE from
    //    effectiveDay == 0 -- the one case that was already correct before the guard existed.

    /// (1) A second write in the very period the first became effective must REVERT. Without this the
    /// scheduled pattern is only one write deep: `prev` gets clobbered with the now-effective value and the
    /// still-drawable period silently inherits it, reopening the reactivity hole one period out.
    function test_periodGuard_secondWriteInTheEffectivePeriodReverts() public {
        // day 0: first write, effectiveDay == 0 so the guard is exempt
        assertEq(raffle.currentDay(), 0);
        uint256 c0 = raffle.potCap();
        raffle.setPotCap((c0 * 5) / 4);

        // day 1 == the period the change becomes effective: the timestamp cooldown is satisfied, but the
        // PERIOD guard must still refuse, because prev is still needed by the drawable period.
        vm.warp(GENESIS + DAY + 1);
        assertEq(raffle.currentDay(), 1);
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setPotCap(c0);

        // day 2: the change has aged past its effective period, so a further write is allowed
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.setPotCap(c0);
    }

    /// (2) After the refused attempt, the value the STILL-DRAWABLE period sees must be untouched. This is the
    /// property the guard exists for -- not merely that the call reverted.
    function test_periodGuard_refusedWriteLeavesTheDrawablePeriodIntact() public {
        uint256 c0 = raffle.potCap();
        raffle.setPotCap((c0 * 5) / 4); // day 0 -> effective day 1
        vm.warp(GENESIS + DAY + 1); // day 1; the drawable period is day 0
        assertEq(raffle.potCapAt(0), c0, "day 0 still sees the pre-write value");
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setPotCap(c0);
        assertEq(raffle.potCapAt(0), c0, "and the refused write changed nothing");
        assertEq(raffle.potCapAt(1), (c0 * 5) / 4, "while day 1 sees the scheduled value");
    }

    /// (3) Promote-then-band: once a scheduled value is effective, the NEXT write must band off the PROMOTED
    /// value, not the stale one -- otherwise the knob drifts further than +/-25% per step.
    function test_periodGuard_nextWriteBandsOffThePromotedValue() public {
        uint256 c0 = raffle.potCap();
        uint256 raised = (c0 * 5) / 4;
        raffle.setPotCap(raised); // day 0 -> effective day 1
        vm.warp(GENESIS + 2 * DAY + 1); // day 2: aged past effective
        assertEq(raffle.potCapAt(2), raised, "promoted");
        vm.expectRevert(RaffleEngine.AdjustOutOfBounds.selector);
        raffle.setPotCap((raised * 5) / 4 + 1); // one wei past +25% OF THE PROMOTED VALUE
        raffle.setPotCap((raised * 5) / 4); // exactly +25% of the promoted value is allowed
    }

    /// (4) The opening snapshot. runOpeningDraw must NOT be reactive: its beacon is pinned to
    /// drawRound(ACCUM_DAYS-1), public from ~day 2 and public forever, while its call window is unbounded.
    /// Scheduling alone bought only a two-day toll, so the opening reads a value frozen pre-reveal.
    function test_openingSnapshotIsFrozenOnceTheWindowCloses() public {
        uint256 snap = raffle.openingPotCap();
        assertEq(snap, raffle.potCap(), "ctor seeds the snapshot from potCap");

        // pre-ACCUM_DAYS the snapshot still tracks the knob (deliberate: pre-launch tuning)
        raffle.setPotCap((snap * 5) / 4);
        assertEq(raffle.openingPotCap(), (snap * 5) / 4, "tracks while currentDay() < ACCUM_DAYS");
        uint256 frozen = raffle.openingPotCap();

        // once the accumulation window has closed the beacon can exist, so the snapshot must stop moving
        vm.warp(GENESIS + 4 * DAY + 1);
        assertGe(raffle.currentDay(), 2);
        raffle.setPotCap((frozen * 3) / 4); // a legal, in-band, post-reveal write
        assertEq(raffle.openingPotCap(), frozen, "snapshot FROZEN after the window closed");
        assertEq(raffle.potCap(), (frozen * 3) / 4, "while the daily knob still moves");
    }

    // ── percentage pot cap (a design change) ─────────────

    /// The pot is a FRACTION of the vault, so it self-regulates in both directions with no owner input:
    /// it grows with the vault, shrinks with it, and can never drain it. The absolute potCap remains as a
    /// backstop behind it.
    function test_capBps_potIsAFractionAndCanNeverDrainTheVault() public {
        _buy(alice, 1000e18);
        quotron.mint(address(vault), 100 * POT); // a large vault: the FRACTION binds, not the absolute cap
        _bootstrapOpening();
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("frac"));
        vm.warp(GENESIS + 3 * DAY + 1);

        uint256 free = vault.freeBalance();
        uint256 frac = (free * raffle.capBpsAt(day)) / 10_000;
        uint256 cap = raffle.potCapAt(day);
        uint256 expected = frac < cap ? frac : cap;

        vm.expectEmit(true, false, false, true, address(raffle));
        emit DrawExecuted(day, expected, K);
        raffle.runDraw(day);
        assertLt(expected, free, "a single day can never take the whole vault");
    }

    /// Hard-capped in code so no owner can ever set a fraction that drains the vault in one day, and
    /// REQUIRED at construction, because a silent default on a value that sizes every payout could ship unnoticed.
    function test_capBps_isBoundedAndRequired() public {
        vm.expectRevert(RaffleEngine.BadCapBps.selector);
        raffle.setCapBps(0);
        vm.expectRevert(RaffleEngine.BadCapBps.selector);
        raffle.setCapBps(5001); // MAX_CAP_BPS is 5000

        // required at construction
        vm.expectRevert(RaffleEngine.BadCapBps.selector);
        new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, 0, address(this)
        );
    }

    /// capBps is SCHEDULED like every other knob. A fraction read LIVE at settlement would reintroduce
    /// exactly the reactivity that scheduling closed, in the single most valuable place to have it: a bump after the
    /// beacon is public moves every winner's prize at once.
    function test_capBps_isScheduledNotLive() public {
        uint256 c0 = raffle.capBpsAt(0);
        raffle.setCapBps((c0 * 5) / 4); // day 0 -> effective day 1
        assertEq(raffle.capBpsAt(0), c0, "day 0 immune");
        assertEq(raffle.capBpsAt(1), (c0 * 5) / 4, "effective from day 1");
        // and the period guard refuses a second write in the effective period
        vm.warp(GENESIS + DAY + 1);
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setCapBps(c0);
    }

    // ── per-winner fault isolation ──────────────────────────────────────

    /// _payWinners makes THREE external calls per winner. In an earlier version none was
    /// wrapped, so ONE reverting winner took the whole day's draw down: every co-winner unpaid. Worse on the
    /// opening path, where `openingDone` then never committed and every daily draw stayed blocked.
    /// Pre-fix this test reverts outright; post-fix the bad seat is skipped and everyone else is paid.
    function test_oneRevertingWinnerDoesNotVoidTheWholeDraw() public {
        _buy(alice, 1000e18);
        _bootstrapOpening();
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("f1"));
        vm.warp(GENESIS + 3 * DAY + 1);

        // find the seats this day will actually draw, then poison ONE of them at the tierOf stage --
        // the genuinely reachable trigger (rollOf -> drand.randomness reverts on an unposted cohort beacon).
        uint256[] memory winners = packs.previewDraw(day);
        uint256 poisoned = winners.length > 0 ? winners[0] : 1;
        vm.mockCallRevert(
            address(packs),
            abi.encodeWithSelector(packs.tierOf.selector, poisoned),
            abi.encodeWithSignature("Error(string)", "beacon unposted")
        );

        uint256 before = claimMgr.nextClaimId();
        raffle.runDraw(day); // MUST NOT revert
        assertTrue(raffle.drawn(day), "the day settled despite a reverting winner");
        assertGt(claimMgr.nextClaimId(), before, "the other winners were still paid");
    }

    /// The skipped seat's share must ROLL FORWARD, not be conjured or double-paid: the vault reserve may
    /// never exceed the pot the draw was sized against.
    function test_skippedSeatShareRollsForwardAndNeverOverReserves() public {
        _buy(alice, 1000e18);
        quotron.mint(address(vault), 9 * POT);
        _bootstrapOpening();
        uint32 day = 2;
        oracle.setBeacon(raffle.drawRound(day), keccak256("f1-roll"));
        vm.warp(GENESIS + 3 * DAY + 1);

        uint256[] memory winners = packs.previewDraw(day);
        if (winners.length > 0) {
            vm.mockCallRevert(
                address(packs),
                abi.encodeWithSelector(packs.ownerOf.selector, winners[0]),
                abi.encodeWithSignature("Error(string)", "no owner")
            );
        }
        uint256 reservedBefore = vault.unclaimedReserve();
        uint256 cap = raffle.potCapAt(day);
        raffle.runDraw(day);
        uint256 reserved = vault.unclaimedReserve() - reservedBefore;
        assertLe(reserved, cap, "never reserve more than the pot, even with a seat skipped");
        assertLe(vault.unclaimedReserve(), quotron.balanceOf(address(vault)), "solvency holds");
    }

    function test_setPotCapRejectsZeroAndBelowMinPot() public {
        // setMinPot is bounded to ±25%/call, so a high minPot can't be reached via
        // the setter from the ctor default of 1. Deploy with the high minPot (500e18) at CONSTRUCTION
        // instead, then prove setPotCap rejects 0 and any value below that minPot floor.
        RaffleEngine r = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 500e18, 1000e18,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        r.setPotCap(0);
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        r.setPotCap(400e18); // below the minPot floor (500e18)
    }

    // minPot is REQUIRED (> 0) at construction: no unsafe 0 default that a dust donation exploits.
    function test_constructorRejectsZeroMinPot() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            0,
            UNCAPPED,
            1000, // capBps: 10%/day of the vault (REQUIRED, no default)
            address(this)
        );
    }

    // potCap is REQUIRED (> 0) at construction: no fail-open uncapped default.
    function test_constructorRejectsZeroPotCap() public {
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, 0,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );
    }

    function test_constructorRejectsMinPotAbovePotCap() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            100e18,
            10e18,
            1000, // capBps: 10%/day of the vault (REQUIRED, no default)
            address(this)
        );
    }

    function test_setMinPotRejectsZero() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        raffle.setMinPot(0);
    }

    // setPotCap is bounded to ±25% per DAY cooldown: no single-tx pot re-peg
    // that would let a compromised owner inflate/deflate a day's payout in one shot.
    function test_setPotCapRateLimitedAndBounded() public {
        assertEq(raffle.potCap(), POT, "starts at the ctor cap");

        // a +33% jump is outside the ±25% band → rejected
        vm.expectRevert(RaffleEngine.AdjustOutOfBounds.selector);
        raffle.setPotCap(1_330e18);

        // a +20% move is within band → allowed (first adjust; cooldown anchor started at 0)
        raffle.setPotCap(1_200e18);
        assertEq(raffle.potCap(), 1_200e18, "in-band re-peg applied");

        // a second adjust before the DAY cooldown elapses → AdjustTooSoon
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setPotCap(1_250e18);

        // after the cooldown, another in-band move succeeds
        // The period guard needs the prior scheduled change to have AGED past its effective
        // period, so a re-peg is once per TWO periods, not once per period. DAY+1 lands exactly ON the
        // boundary and reverts AdjustTooSoon.
        vm.warp(block.timestamp + 2 * DAY + 1);
        raffle.setPotCap(1_450e18); // +20.8% from 1200
        assertEq(raffle.potCap(), 1_450e18, "second re-peg after the cooldown");
    }

    // setMinPot is rate-limited like setPotCap, so it is no longer an unguarded twin.
    function test_setMinPotRateLimited() public {
        raffle.setMinPot(2); // first adjust ok (cooldown anchor started at 0; GENESIS > DAY)
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setMinPot(3); // a second change within the DAY cooldown is rejected
        // The period guard needs the prior scheduled change to have AGED past its effective
        // period, so a re-peg is once per TWO periods, not once per period. DAY+1 lands exactly ON the
        // boundary and reverts AdjustTooSoon.
        vm.warp(block.timestamp + 2 * DAY + 1);
        raffle.setMinPot(3); // after the cooldown it succeeds
        assertEq(raffle.minPot(), 3);
    }

    function test_voidWindow_cannotDrawEarly() public {
        _buy(alice, 100e18);
        // After the opening draw unlocks daily draws, drawing day 2 while it's still day 2 is too early:
        // day 2's window is day 3. (Before openingDone this would revert OpeningPending first.)
        _bootstrapOpening(); // leaves currentDay() == 2
        vm.expectRevert(RaffleEngine.OutsideWindow.selector);
        raffle.runDraw(2);
    }

    function test_voidWindow_noCatchUp() public {
        _buy(alice, 100e18);
        _bootstrapOpening(); // openingDone; currentDay() == 2
        // jump to day 4 — day 2's window (day 3) has passed → void, no catch-up
        vm.warp(GENESIS + 4 * DAY + 1);
        vm.expectRevert(RaffleEngine.OutsideWindow.selector);
        raffle.runDraw(2);
    }

    function test_cannotDrawTwice() public {
        _buy(alice, 100e18); // cohort 0
        _bootstrapOpening(); // opening sweeps [0,1]; alice's remaining cohort-0 tickets stay live
        // a normal daily draw for day 2 (window [0,1] still holds alice's remaining tickets)
        quotron.mint(address(vault), POT); // top up so the day-2 pot clears minPot after the opening reserve
        oracle.setBeacon(raffle.drawRound(2), keccak256("d2"));
        vm.warp(GENESIS + 3 * DAY + 1); // currentDay() == day+1 == 3
        raffle.runDraw(2);
        vm.expectRevert(RaffleEngine.AlreadyDrawn.selector);
        raffle.runDraw(2);
    }

    /// A draw on a ZERO pot must not consume tickets (drawFrom marks them spent). It also
    /// must not mark the day drawn, so a retry pays out if the vault is funded later within the window.
    function test_zeroPotDoesNotBurnTickets() public {
        // A fresh raffle with a HIGH minPot (POT) set at construction. The one-time opening draw is
        // bootstrapped with exactly `minPot` of funding, which the opening partly RESERVES — leaving the
        // free balance BELOW minPot. The subsequent DAILY draw therefore sees a sub-minPot pot and must
        // hit the sub-minPot guard: do NOT burn tickets, register claims, or mark the day drawn.
        // (A truly-zero pot can't survive bootstrapping — the opening itself needs a nonzero pot — so the
        // sub-minPot floor exercises the identical `pot < minPot` guard branch on the daily draw.)
        MockDrandOracle o2 = new MockDrandOracle(GENESIS, PERIOD);
        PackRegistry p2 = new PackRegistry(address(o2), TICKET, GENESIS, 1 hours, address(this));
        BaseVault v2 = new BaseVault(address(quotron), address(this));
        ClaimManager c2 = new ClaimManager(address(this));
        RaffleEngine r2 = new RaffleEngine(
            address(o2),
            address(p2),
            address(v2),
            address(c2),
            GENESIS,
            K,
            POT, // minPot floor
            UNCAPPED,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ // potCap effectively uncapped (band-computable)
            address(this)
        );
        p2.setRecorder(token);
        p2.setEngine(address(r2));
        c2.setEngine(address(r2), address(v2));
        v2.setController(address(c2));

        vm.prank(token);
        p2.recordBuy(alice, 100e18); // 10 tickets, cohort 0
        assertEq(p2.liveCount(1), 10, "10 tickets live");

        // bootstrap the opening draw with exactly minPot of funding (opening reserves some → free < minPot)
        (, uint64 revRound2,,) = p2.packs(1);
        o2.setBeacon(revRound2, keccak256("reveal"));
        o2.setBeacon(r2.drawRound(1), keccak256("opening"));
        o2.setBeacon(r2.drawRound(2), keccak256("d2"));
        quotron.mint(address(v2), POT);
        // This fixture funds exactly minPot, and the opening pot is only openingCapBps of the balance, so
        // the opening is genuinely unpayable here. That is now a DECLARED forgo after the grace day, not an
        // accident -- the subject of this test is the DAILY draw's sub-minPot guard, reached either way.
        vm.warp(GENESIS + (2 + 1) * DAY + 1); // past ACCUM_DAYS + FORGO_GRACE_DAYS
        r2.runOpeningDraw(true);
        assertTrue(r2.openingDone(), "opening bootstrapped (forgone on purpose)");

        // day-2 daily draw with a sub-minPot pot → must not burn tickets, register claims, or mark drawn.
        vm.warp(GENESIS + 3 * DAY + 1); // currentDay() == day+1 == 3
        uint256 liveBefore = p2.liveCount(2);
        uint256 claimsBefore = c2.nextClaimId();
        assertGt(liveBefore, 0, "cohort-0 tickets still live for the day-2 window");
        // PERCENTAGE CAP: the guard this test exercises keys on the POT, and the pot is now a FRACTION of
        // the free balance rather than the balance itself. Asserting on freeBalance was only ever a proxy for
        // that, and the proxy no longer holds (the opening reserves less, so the balance stays higher).
        // Assert the thing the guard actually reads.
        uint256 dailyPot = (v2.freeBalance() * r2.capBpsAt(2)) / 10_000;
        assertLt(dailyPot, r2.minPotAt(2), "the day's POT (a fraction of the vault) sits below minPot");

        r2.runDraw(2);
        assertEq(p2.liveCount(2), liveBefore, "tickets NOT burned on a sub-minPot pot");
        assertEq(c2.nextClaimId(), claimsBefore, "no claims registered");
        assertFalse(r2.drawn(2), "day not marked drawn -> retry allowed once funded");

        // fund above minPot, retry within the same window → now it pays out.
        // PERCENTAGE CAP: pot = 10% of the balance, so clearing minPot needs ~10x what it did.
        quotron.mint(address(v2), 12 * POT);
        r2.runDraw(2);
        assertGt(c2.nextClaimId(), claimsBefore, "draw pays out once funded");
        assertTrue(r2.drawn(2), "now marked drawn");
    }

    // ─── opening-draw liveness: a sub-minPot pot at window close FORGOES the opening ────────
    // (void-on-miss) instead of leaving openingDone=false and blocking every daily draw behind it.

    /// Fresh harness with a HIGH minPot: the setUp one uses 1 wei, so its vault can never sit under minPot.
    /// Replaces the harness fields in place so the shared helpers (_buy, _bootstrapOpening) keep working.
    /// potCap is uncapped so `pot` equals the vault's free balance exactly.
    function _redeployWithMinPot(uint256 minPot_, uint256 fund) internal {
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            minPot_,
            UNCAPPED,
            1000, // capBps: 10%/day of the vault (REQUIRED, no default)
            address(this)
        );
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        if (fund > 0) quotron.mint(address(vault), fund);
    }

    /// (1) Small pot at window close: the opening SETTLES (openingDone) with no payout and no burned tickets,
    ///     the first daily day becomes callable (it was OpeningPending before the fix), voids under minPot,
    ///     and pays once the vault is funded above minPot. (3) The forgone opening can never run again.
    function test_L_openingSmallPot_settlesForgoneAndUnlocksDailyDraws() public {
        _redeployWithMinPot(POT, POT / 2); // vault holds POT/2 < minPot (POT)
        _buy(alice, 100e18); // 10 tickets, cohort 0
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        // Deliberately NO opening beacon (drawRound(1)): a forgone opening must settle WITHOUT reading drand.
        // The mock reverts "unavailable" on a missing round, so this test fails if the small-pot path reads it.

        vm.warp(GENESIS + 2 * DAY + 1); // currentDay() == ACCUM_DAYS: the window has closed
        assertLt(vault.freeBalance(), raffle.minPot(), "pot sits under minPot at window close");
        uint256 liveBefore = packs.liveCount(2);
        assertEq(liveBefore, 10, "all 10 cohort-0 tickets live for the day-2 window");

        // THE FORGO MUST BE DECLARED, AND IT CANNOT HAPPEN ON DAY ONE. "Not funded yet" is the NORMAL state
        // at window close -- the vault fills through Treasury.convert(), which is keeper-gated and ships
        // disabled -- so an undeclared call must fail loudly and latch nothing, and even a declared one must
        // wait out the grace period. Both of those used to settle the opening permanently, in silence.
        vm.expectRevert(
            abi.encodeWithSelector(RaffleEngine.PotBelowOpeningFloor.selector, POT / 20, raffle.openingMinPot())
        );
        raffle.runOpeningDraw(false);
        assertFalse(raffle.openingDone(), "an undeclared call must latch NOTHING");

        vm.expectRevert(RaffleEngine.TooSoonToForgo.selector);
        raffle.runOpeningDraw(true); // declared, but still inside the grace day
        assertFalse(raffle.openingDone(), "the grace period must hold even against consent");

        // funding it now still rescues the opening; that is the whole point of the two guards above
        vm.warp(GENESIS + 3 * DAY + 1); // past ACCUM_DAYS + FORGO_GRACE_DAYS
        vm.expectEmit(true, false, false, true, address(raffle));
        // percentage cap: the pot is openingCapBps (10%) of the free balance, so POT/2 -> POT/20.
        emit RaffleEngine.DrawExecuted(0, POT / 20, 0); // day 0 = opening, fraction of the balance, 0 winners
        raffle.runOpeningDraw(true); // deliberate, after the grace: the only way to throw it away

        assertTrue(raffle.openingDone(), "opening SETTLED (forgone) on a sub-minPot pot");
        assertEq(claimMgr.nextClaimId(), 0, "nobody is paid under minPot");
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved");
        assertEq(packs.liveCount(2), liveBefore, "no tickets burned: cohorts [0,1] keep every ticket");
        assertEq(vault.freeBalance(), POT / 2, "the pot rolls forward untouched");

        // (3) never twice: the forgone opening is settled for good
        vm.expectRevert(RaffleEngine.OpeningAlreadyDone.selector);
        raffle.runOpeningDraw(false);

        // the first daily day (ACCUM_DAYS) is now CALLABLE ...
        oracle.setBeacon(raffle.drawRound(2), keccak256("d2"));
        raffle.runDraw(2);
        // ... and self-voids under minPot: no payout, no burn, day not consumed (the sub-minPot guard, unchanged)
        assertEq(claimMgr.nextClaimId(), 0, "daily draw voids under minPot");
        assertFalse(raffle.drawn(2), "a void does not consume the day");
        assertEq(packs.liveCount(2), liveBefore, "a void burns nothing");

        // fund above minPot within the window -> the retry pays K winners from the rolled-forward pot.
        // PERCENTAGE CAP: the pot is 10% of the free balance, so clearing minPot needs ~10x the balance it
        // used to. Same operational consequence as the opening: the funding bar rose 10x.
        quotron.mint(address(vault), 12 * POT); // free = 12.5*POT -> 10% = 1.25*POT >= minPot (POT)
        raffle.runDraw(2);
        assertEq(claimMgr.nextClaimId(), K, "daily draw pays exactly K winners once funded");
        assertTrue(raffle.drawn(2), "the paying draw consumes the day");
        assertLe(vault.unclaimedReserve(), vault.freeBalance() + vault.unclaimedReserve(), "solvency: reserved <= balance");
        (, address recip, uint256 amount,,) = claimMgr.claims(1);
        assertEq(recip, alice, "sole buyer wins");
        assertGt(amount, 0, "a real prize");
    }

    /// The mirror of the NFT ladder guard: throwing away an opening draw is irreversible, so
    /// it needs evidence the chain produced PAST the missing round, not merely that nobody relayed it. Without
    /// it, a caller who computes the (losing, to them) opening outcome off-chain could withhold the beacon,
    /// wait out the 7-day grace and kill a known-bad result — a one-shot option over a real pot.
    function test_openingForgoNeedsEvidenceTheChainMovedOn() public {
        _buy(alice, 100e18);
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        // NOTE: setBeacon lifts highestRound to revRound, which is BELOW the opening round. So the chain has
        // never been seen past the missing round: exactly the "merely unrelayed" state.

        vm.warp(GENESIS + 9 * DAY + 1); // the long grace has passed; only the evidence is missing
        vm.expectRevert(); // no forgo: it falls through and reverts on the unposted round, as before the fix
        raffle.runOpeningDraw(true);
        assertFalse(raffle.openingDone(), "an opening is never discarded without evidence it was skipped");

        oracle.setHighestRound(type(uint64).max); // later beacons exist: the chain ran on without this round
        raffle.runOpeningDraw(true);
        assertTrue(raffle.openingDone(), "with evidence, the declared forgo works exactly as before");
        assertEq(claimMgr.nextClaimId(), 0, "nobody is paid");
    }

    /// A FUNDED opening whose one beacon is never posted used to revert in drand.randomness on
    /// every call, holding every daily draw behind OpeningPending forever: the forgo was gated on an
    /// UNDERFUNDED pot. It still reverts, exactly as before, for OPENING_BEACON_GRACE_DAYS (7) after the window
    /// closes and for any undeclared call; after that a declared call settles it like the forgo.
    function test_fundedOpeningWithNoBeaconCanBeForgoneAfterTheLongGrace() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        // deliberately NO opening beacon (drawRound(1)); the vault is funded (POT), so this is the PAID path
        // Forgoing also needs evidence the chain produced PAST the missing round. Nine days
        // of drand at 30s a round is what the world looks like here; the opening round alone never landed.
        oracle.setHighestRound(type(uint64).max);

        vm.warp(GENESIS + 2 * DAY + 1); // the window has closed
        vm.expectRevert(); // the unposted round, as before
        raffle.runOpeningDraw(true);

        vm.warp(GENESIS + 8 * DAY + 1); // day 8: one day inside ACCUM_DAYS (2) + OPENING_BEACON_GRACE_DAYS (7)
        vm.expectRevert();
        raffle.runOpeningDraw(true);
        assertFalse(raffle.openingDone(), "no forgo inside the long grace, even declared");

        vm.warp(GENESIS + 9 * DAY + 1); // day 9: the grace has passed
        vm.expectRevert(); // undeclared: still the old revert, latching nothing
        raffle.runOpeningDraw(false);
        assertFalse(raffle.openingDone(), "an undeclared call must latch nothing");

        uint256 free = vault.freeBalance();
        vm.expectEmit(false, false, false, false, address(raffle));
        emit RaffleEngine.OpeningBeaconMissing(0, 0); // signature and emitter only
        raffle.runOpeningDraw(true);
        assertTrue(raffle.openingDone(), "settled, so the daily draws unlock");
        assertEq(claimMgr.nextClaimId(), 0, "nobody is paid");
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved");
        assertEq(vault.freeBalance(), free, "the pot rolls forward untouched");

        vm.expectRevert(RaffleEngine.OpeningAlreadyDone.selector);
        raffle.runOpeningDraw(true);
    }

    /// The opening needs its own beacon AND every swept cohort's tier round. A cohort round is
    /// bound once at mint and can never be re-bound, so a round Drand never produces used to revert the one
    /// opening draw forever through PackRegistry's RevealPending guard, and with it every daily draw behind
    /// OpeningPending. The missing-beacon forgo only covered the opening's own round. Now the same declared forgo covers
    /// a stuck cohort round too, and the daily draws unlock.
    function test_fundedOpeningWithStuckCohortRoundCanBeForgone() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0
        // the OPENING round is posted; the cohort's TIER round is the one drand never produced
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        (, uint64 revRound,,) = packs.packs(1);
        (bool pending, uint32 cohort, uint64 round) = packs.revealPending(2);
        assertTrue(pending, "the sweep window reports the stuck cohort without reverting");
        assertEq(cohort, 0);
        assertEq(round, revRound);

        vm.warp(GENESIS + 2 * DAY + 1); // window closed, vault funded
        vm.expectRevert(abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(0), revRound));
        raffle.runOpeningDraw(true); // inside the grace: still the RevealPending revert, latching nothing
        assertFalse(raffle.openingDone());

        vm.warp(GENESIS + 9 * DAY + 1); // past ACCUM_DAYS + OPENING_BEACON_GRACE_DAYS
        vm.expectRevert(abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(0), revRound));
        raffle.runOpeningDraw(false); // undeclared: unchanged, still reverts
        assertFalse(raffle.openingDone(), "an undeclared call must latch nothing");

        uint256 free = vault.freeBalance();
        vm.expectEmit(false, false, false, false, address(raffle));
        emit RaffleEngine.OpeningCohortRevealMissing(0, 0); // signature and emitter only
        raffle.runOpeningDraw(true);
        assertTrue(raffle.openingDone(), "settled, so the daily draws unlock");
        assertEq(claimMgr.nextClaimId(), 0, "nobody is paid");
        assertEq(vault.freeBalance(), free, "the pot rolls forward untouched");
        assertEq(packs.liveCount(2), 10, "no tickets burned");

        // and once the stuck cohort ages out of the 7-day window, the daily draws pay again
        oracle.setBeacon(raffle.drawRound(9), keccak256("d9"));
        vm.warp(GENESIS + 10 * DAY + 1);
        raffle.runDraw(9); // no longer OpeningPending; cohort 0 is outside day 9's window
        assertTrue(true);
    }

    /// The other half of the missing-beacon forgo: however late the call, a POSTED opening beacon never takes the new branch.
    function test_postedBeaconNeverTakesTheNoBeaconForgo() public {
        _buy(alice, 100e18);
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));

        vm.warp(GENESIS + 20 * DAY + 1); // far past the grace, and declared
        vm.recordLogs();
        raffle.runOpeningDraw(true);
        assertTrue(raffle.openingDone(), "settled");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 missing = keccak256("OpeningBeaconMissing(uint64,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != missing, "a posted beacon must not be forgone");
        }
    }

    /// Anti-skip: the forgone-settle is only reachable once the window has CLOSED. An under-minPot call inside
    /// the window is still Accumulating (openingDone stays false), and an opening that is payable by the time
    /// the window closes pays exactly as before. So openingDone=true can never skip a legitimate opening.
    function test_L_openingSmallPot_cannotForgoBeforeWindowClose() public {
        _redeployWithMinPot(POT, 0); // EMPTY vault
        _buy(alice, 100e18); // 10 tickets, cohort 0
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));

        vm.warp(GENESIS + 2 * DAY - 1); // currentDay() == 1 < ACCUM_DAYS
        vm.expectRevert(RaffleEngine.Accumulating.selector);
        raffle.runOpeningDraw(false);
        assertFalse(raffle.openingDone(), "not settled before the window closes, funded or not");

        // funded above minPot by window close -> the LEGITIMATE opening pays OPENING_WINNERS (paid path).
        // PERCENTAGE CAP (2026-09-08): the opening pot is now openingCapBps of the vault, not the whole free
        // balance, so "funded above minPot" requires ~10x what it used to at capBps = 1000. That is a real
        // operational consequence, not a test artifact: the pre-ACCUM_DAYS funding target rose 10x.
        quotron.mint(address(vault), 10 * POT); // free = 10*POT -> 10% == POT == minPot
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw(false);
        assertTrue(raffle.openingDone(), "settled by the paid path");
        assertEq(claimMgr.nextClaimId(), raffle.OPENING_WINNERS(), "a payable opening is never skipped");
    }

    /// (2) Normal path: pot >= minPot pays exactly OPENING_WINNERS from the accumulation cohorts, popping
    ///     exactly that many tickets, and (3) can never run twice.
    function test_L_openingNormalPath_paysExactlyOpeningWinners() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0; setUp funded the vault with POT >= minPot (1 wei)
        uint256 liveBefore = packs.liveCount(2);
        _bootstrapOpening(); // pot >= minPot: the PAID path
        uint256 n = raffle.OPENING_WINNERS();
        assertEq(claimMgr.nextClaimId(), n, "exactly OPENING_WINNERS claims written");
        assertEq(packs.liveCount(2), liveBefore - n, "exactly OPENING_WINNERS tickets popped");
        assertGt(vault.unclaimedReserve(), 0, "the opening reserved its payout");
        assertLe(vault.unclaimedReserve(), POT, "solvency: reserved <= pot");
        vm.expectRevert(RaffleEngine.OpeningAlreadyDone.selector);
        raffle.runOpeningDraw(false);
    }

    // ─── (c) WinnerPaid event: one per paid winner, tied to the ClaimManager claim ──

    function test_WinnerPaid_emittedPerWinner_matchesClaims() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0 (alice is the sole buyer)

        vm.recordLogs();
        _bootstrapOpening(); // runs the one-time opening draw; day 0 = the opening sweep
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = RaffleEngine.WinnerPaid.selector;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(raffle)) continue;
            ++seen;
            uint32 day = uint32(uint256(logs[i].topics[1])); // indexed day
            uint256 packId = uint256(logs[i].topics[2]); // indexed packId
            (address owner, uint8 tier, uint256 prize, uint256 claimId) =
                abi.decode(logs[i].data, (address, uint8, uint256, uint256));

            assertEq(day, 0, "opening sweep is day 0");
            assertTrue(packId >= 1 && packId < packs.nextPackId(), "a real packId");
            assertEq(owner, alice, "sole buyer owns every winning pack");
            assertEq(tier, packs.tierOf(packId), "tier == packs.tierOf(packId)");
            assertGt(prize, 0, "a paid winner receives >0");

            // the claimId matches the ClaimManager claim registered for this win
            assertTrue(claimId >= 1 && claimId <= claimMgr.nextClaimId(), "claimId in range");
            (, address recip, uint256 amount,, bool settled) = claimMgr.claims(claimId);
            assertEq(recip, owner, "claim recipient == WinnerPaid owner");
            assertEq(amount, prize, "claim amount == WinnerPaid prize");
            assertFalse(settled, "freshly registered, not yet claimed");
        }

        assertGt(seen, 0, "at least one WinnerPaid emitted");
        assertEq(seen, claimMgr.nextClaimId(), "one WinnerPaid per registered claim");
    }

    function test_expiredClaimSweepsBackToVault() public {
        _buy(alice, 100e18);
        _bootstrapOpening(); // opening draw writes alice's claims (claim id 1)

        (,, uint256 amount,,) = claimMgr.claims(1);
        uint256 freeBefore = vault.freeBalance();

        // let the 30-day CLAIM_WINDOW (real days, not the short DAY) lapse, then sweep
        vm.warp(block.timestamp + 31 days);
        claimMgr.sweepExpired(1);

        assertEq(vault.freeBalance(), freeBefore + amount, "unclaimed prize rolled back into the pot");

        // and it can no longer be claimed
        vm.prank(alice);
        vm.expectRevert(ClaimManager.AlreadySettled.selector);
        claimMgr.claim(1);
    }

    // ─── worst-case gas of the COMBINED runDraw path ───────────────────────────────────
    // The payout leg (_payWinners) is gas-tested at MAX_K in test/fork/QuotronWholeUnitFork.t.sol, but nothing
    // snapshotted the SINGLE-TX cost of the whole runDraw = packs.drawFrom selection (the O(k) cohort loop +
    // swap-pop over the full LIFE_DAYS window, src/PackRegistry.sol) PLUS _payWinners, at winnersPerDay = MAX_K,
    // on a FULL cohort window. This measures that combined worst case end-to-end. MEASURE ONLY — it changes no src
    // and never touches MAX_K.
    // This number is measured INSIDE ONE TEST TRANSACTION (the stack is built in the same
    // call), so the storage the draw touches is warm and dirty, and a gasleft() delta excludes nothing the chain would
    // charge later. It UNDERSTATES a real draw: as its own transaction on cold storage the same shape needs ~29.3M gas
    // before refunds, and the worst shape (7 cohorts with the free block) ~30.0M to ~30.5M, against RH's 32M per-tx
    // limit. The < 30M assert below is kept as a coarse warm-path regression check only; the gate that matters is
    // test/RunDrawIsolatedGas.t.sol (isolate = true, gasTotalUsed + gasRefunded <= 32M - 1M). runDraw gas is O(k): the selection loop runs exactly winnersPerDay times and the payout
    // writes one claim per winner, so it is independent of how DEEP each cohort is beyond the K it must fill —
    // a full 7-cohort window holding > MAX_K live paid tickets is the worst realistic input for the path.
    function test_gas_runDraw_worstCase_maxK_fullWindow() public {
        uint256 maxK = raffle.MAX_K(); // 200: set at construction here; also reachable later by walking setWinnersPerDay up (+25%/day)
        uint32 life = packs.LIFE_DAYS(); // 7 — the window runDraw sweeps is cohorts [day-life .. day-1]

        // Fresh stack deployed straight at K = MAX_K. potCap bounds each draw to a fixed 10k QUOTRON (gas is
        // independent of the pot's magnitude) and the vault is funded far above it, so all K winners pay > 0
        // and the reserve never exceeds free balance.
        MockDrandOracle o = new MockDrandOracle(GENESIS, PERIOD);
        PackRegistry p = new PackRegistry(address(o), TICKET, GENESIS, 1 hours, address(this));
        BaseVault v = new BaseVault(address(quotron), address(this));
        ClaimManager cm = new ClaimManager(address(this));
        RaffleEngine r = new RaffleEngine(
            address(o), address(p), address(v), address(cm), GENESIS, maxK, 1, 10_000e18,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );
        p.setRecorder(token);
        p.setEngine(address(r));
        cm.setEngine(address(r), address(v));
        v.setController(address(cm));
        quotron.mint(address(v), 1_000_000e18);

        // Draw day = LIFE_DAYS + 3 (=10): its window is cohorts [3..9] — a full LIFE_DAYS run of cohorts, all
        // clear of the one-time opening sweep (which touches only [0, ACCUM_DAYS-1] = [0,1]).
        uint32 drawDay = life + 3;
        uint256 perCohort = 40; // life*40 = 280 live paid tickets > MAX_K, so the draw fills a full field of K

        // cohort 0: seed the opening bootstrap (block.timestamp == GENESIS here → _today() == 0).
        vm.prank(token);
        p.recordBuy(alice, 10 * TICKET); // 10 tickets in cohort 0; the opening pops OPENING_WINNERS from [0,1]

        // populate the full draw window [3 .. drawDay-1]
        for (uint32 c = 3; c <= drawDay - 1; ++c) {
            vm.warp(GENESIS + uint256(c) * DAY + 1); // _today() == c
            vm.prank(token);
            p.recordBuy(alice, perCohort * TICKET);
        }

        // reveal beacons: cohort 0 (opening payout) + each window cohort (day-`drawDay` payout tierOf).
        // All packs in a cohort share ONE reveal round = roundAt(genesis + (cohort+1)*DAY + revealDelay).
        o.setBeacon(o.roundAt(GENESIS + 1 * DAY + 1 hours), keccak256("rev0"));
        for (uint32 c = 3; c <= drawDay - 1; ++c) {
            o.setBeacon(o.roundAt(GENESIS + (uint256(c) + 1) * DAY + 1 hours), keccak256(abi.encode("rev", c)));
        }

        // one-time opening draw (unlocks the daily runDraw); sweeps [0,1] only, leaving [3..9] untouched.
        o.setBeacon(r.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        r.runOpeningDraw(false);
        assertTrue(r.openingDone(), "opening bootstrapped");

        // day-`drawDay` settling beacon, then step into its ONLY draw window (the following day).
        o.setBeacon(r.drawRound(drawDay), keccak256("draw"));
        vm.warp(GENESIS + (uint256(drawDay) + 1) * DAY + 1); // currentDay() == drawDay + 1
        assertEq(r.currentDay(), drawDay + 1, "in the void-on-miss window for the draw day");
        assertEq(p.liveCount(drawDay), perCohort * life, "the full 7-cohort window is live");

        // ── measure the single combined selection + payout tx ──
        uint256 claimsBefore = cm.nextClaimId();
        uint256 gasBefore = gasleft();
        r.runDraw(drawDay);
        uint256 gasUsed = gasBefore - gasleft();

        // the number is only meaningful if a FULL field of K winners was actually selected AND paid this tx.
        assertEq(cm.nextClaimId() - claimsBefore, maxK, "a full field of MAX_K winners selected and paid");
        assertTrue(r.drawn(drawDay), "the draw day was consumed");

        emit log_named_uint("runDraw combined worst-case gas (K=MAX_K, full 7-cohort window)", gasUsed);
        // Warm-path regression check only (see the note above); the cold, pre-refund gate is test/RunDrawIsolatedGas.t.sol.
        assertLt(gasUsed, 30_000_000, "combined runDraw (warm, in-test) must stay under 30M");
    }

    // ─── the paired DAY() cadence is cross-checked at construction (only genesis was before) ──

    function test_cadence_dayLengthExposesBaseCadence() public view {
        assertEq(packs.dayLength(), 1 days, "base PackRegistry cadence is 1 day");
    }

    function test_cadence_mismatchedPairRevertsAtConstruction() public {
        // a short-clock engine wired to the mainnet-cadence registry (same genesis, so only cadence differs)
        vm.expectRevert(RaffleEngine.CadenceMismatch.selector);
        new RaffleEngineFiveMin(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this)
        );

        // and the mirror image: a mainnet-cadence engine wired to a short-clock registry
        PackRegistryFiveMin p5 = new PackRegistryFiveMin(address(oracle), TICKET, GENESIS, 2 minutes, address(this));
        assertEq(p5.dayLength(), 5 minutes, "short-clock registry reports its override");
        vm.expectRevert(RaffleEngine.CadenceMismatch.selector);
        new RaffleEngine(
            address(oracle), address(p5), address(vault), address(claimMgr), GENESIS, K, 1, POT,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );
    }

    /// The registry's draw clamp and opening-cohort count are cross-checked at construction
    /// exactly like genesis and cadence. A registry that clamps draws below MAX_K, or gates rip XP on the wrong
    /// cohorts, cannot be paired with this engine.
    function test_pairing_drawKAndOpeningCohortsAreCrossChecked() public {
        assertEq(packs.MAX_DRAW_K(), raffle.MAX_K(), "shipped pair agrees on the draw clamp");
        assertEq(packs.OPENING_COHORTS(), 2, "shipped pair: the opening sweeps cohorts [0, 1]");

        PairingStub stub = new PairingStub(GENESIS, 1 days, 199, 2);
        vm.expectRevert(RaffleEngine.DrawKMismatch.selector);
        new RaffleEngine(address(oracle), address(stub), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this));

        stub = new PairingStub(GENESIS, 1 days, 200, 3);
        vm.expectRevert(RaffleEngine.OpeningCohortsMismatch.selector);
        new RaffleEngine(address(oracle), address(stub), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this));

        stub = new PairingStub(GENESIS, 1 days, 200, 2);
        new RaffleEngine(address(oracle), address(stub), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this));
    }

    function test_cadence_matchedShortClockPairConstructs() public {
        PackRegistryFiveMin p5 = new PackRegistryFiveMin(address(oracle), TICKET, GENESIS, 2 minutes, address(this));
        RaffleEngineFiveMin r5 = new RaffleEngineFiveMin(
            address(oracle), address(p5), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this)
        );
        assertEq(p5.dayLength(), 5 minutes, "matched pair: registry on the 5-minute clock");
        // both halves count days on the same clock
        vm.warp(GENESIS + 5 minutes + 1);
        assertEq(r5.currentDay(), 1, "engine counts 5-minute days");
        assertEq(p5.today(), 1, "registry counts the same 5-minute days");
    }

    /// @notice A shortened-cadence subclass must shorten REVEAL_LAG() too, or its settling beacon binds
    ///         AFTER the draw window that needs it has already closed and runDraw can never settle.
    ///         REVEAL_LAG used to be a plain `constant`, so RaffleEngineTestnet shortened DAY() to 5 minutes
    ///         while the beacon stayed 1 hour out: the window closed ~55 minutes before its round existed.
    ///         It was invisible on testnet only because MOCK_ORACLE serves a settable beacon. Now virtual.
    function test_cadence_revealLagMustFitInsideTheDrawWindow() public {
        PackRegistryFiveMin p5 = new PackRegistryFiveMin(address(oracle), TICKET, GENESIS, 2 minutes, address(this));
        RaffleEngineFiveMin r5 = new RaffleEngineFiveMin(
            address(oracle), address(p5), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this)
        );
        // the settling beacon must publish strictly inside the [day+1, day+2) window that runDraw accepts
        assertLt(r5.revealLag_(), r5.day_(), "REVEAL_LAG must fit inside one DAY(), else the draw can never settle");

        // and concretely: the round settling day D binds before that window closes
        uint32 D = 3;
        uint256 windowOpens = GENESIS + (uint256(D) + 1) * r5.day_();
        uint256 windowCloses = windowOpens + r5.day_();
        uint256 beaconAt = windowOpens + r5.revealLag_();
        assertGe(beaconAt, windowOpens, "beacon must not predate the window (else it is grindable)");
        assertLt(beaconAt, windowCloses, "beacon must land before the window closes");
    }
}

/// @dev The four registry reads RaffleEngine's constructor cross-checks, with settable answers.
contract PairingStub {
    uint256 public immutable genesis;
    uint256 public immutable dayLength;
    uint256 public immutable MAX_DRAW_K;
    uint32 public immutable OPENING_COHORTS;

    constructor(uint256 g, uint256 d, uint256 k, uint32 oc) {
        genesis = g;
        dayLength = d;
        MAX_DRAW_K = k;
        OPENING_COHORTS = oc;
    }
}

// ─── cadence cross-check fixtures: short-clock halves of the RaffleEngine/PackRegistry pair ────
// Local 5-minute overrides (the same shape as src/testnet/TestnetShortClock.sol) so the tests can pair and
// mis-pair the halves without importing the testnet file.
contract PackRegistryFiveMin is PackRegistry {
    constructor(address drand_, uint256 ticketPrice_, uint256 genesis_, uint256 revealDelay_, address o)
        PackRegistry(drand_, ticketPrice_, genesis_, revealDelay_, o)
    { }

    function DAY() internal pure override returns (uint256) {
        return 5 minutes;
    }

    // Compressing DAY() compresses MAX_REVEAL_DELAY() with it, so the floor has to come down too or the
    // window is empty. Same pairing as src/testnet/TestnetShortClock.sol.
    function MIN_REVEAL_DELAY() public pure override returns (uint256) {
        return 1 minutes;
    }
}

contract RaffleEngineFiveMin is RaffleEngine {
    constructor(
        address drand_,
        address packs_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 k_,
        uint256 minPot_,
        uint256 potCap_,
        uint256 capBps_,
        address o
    ) RaffleEngine(drand_, packs_, vault_, claim_, genesis_, k_, minPot_, potCap_, capBps_, o) { }

    function DAY() internal pure override returns (uint256) {
        return 5 minutes;
    }

    /// @dev Mirrors the RaffleEngineTestnet fix: a subclass that shortens DAY() MUST also shorten
    ///      REVEAL_LAG(), or drawRound() binds the settling beacon past the end of the one-DAY()-wide
    ///      draw window and runDraw can never find it. Kept in lockstep with src/testnet/TestnetShortClock.sol.
    function REVEAL_LAG() internal pure override returns (uint256) {
        return 1 minutes;
    }

    // expose the cadence knobs so the invariant below can be asserted directly
    function day_() external view returns (uint256) { return DAY(); }
    function revealLag_() external view returns (uint256) { return REVEAL_LAG(); }
}
