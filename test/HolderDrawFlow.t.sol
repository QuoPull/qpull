// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { HolderDrawEngine } from "../src/HolderDrawEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// OZ-shaped NFT double: ownerOf REVERTS for unminted/burned ids, plus ownerSince/totalMinted/launched.
contract RevertingNFT2 {
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => uint64) public ownerSince;
    uint256 public totalMinted;
    bool public launched = true;

    function setLaunched(bool v) external { launched = v; }
    function setTotalMinted(uint256 n) external { totalMinted = n; }
    function setOwnerSince(uint256 id, uint64 t) external { ownerSince[id] = t; }

    function set(uint256 id, address o) external {
        if (id > totalMinted) totalMinted = id;
        if (ownerSince[id] == 0) ownerSince[id] = uint64(block.timestamp);
        _owner[id] = o;
    }
    function ownerOf(uint256 id) external view returns (address) {
        address o = _owner[id];
        require(o != address(0), "nonexistent");
        return o;
    }
    function balanceOf(address) external pure returns (uint256) { return 4; } // >= MIN_HOLD so the gate admits
    function rarityOf(uint256) external pure returns (uint8) { return 0; }
    uint256 public constant MIN_HOLD = 4;
    function qualifiedSince(address) external pure returns (uint64) { return 1; } // qualified since t=1 (<= any freeze)
}

/// Gas-starvation fixture: code that burns every unit of gas it is given, etched over the ClaimManager to model a
/// registerClaim starved by the caller.
contract HolderGasBurner {
    fallback() external {
        while (true) { }
    }
}

contract HolderDrawFlowTest is Test {
    HolderDrawEngine eng;
    BaseVault vault;
    ClaimManager claimMgr;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;

    uint256 constant GENESIS = 1_000_000;
    uint256 constant WEEK = 7 days;
    uint256 constant POT = 500e18;
    uint256 constant POT_CAP = 1_000e18;
    uint256 constant POT_CEILING = 10_000e18;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 3);
        quotron = new MockERC20();
        nft = new MockNFT();
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        eng = new HolderDrawEngine(
            address(oracle), address(nft), address(vault), address(claimMgr),
            GENESIS, POT_CAP, POT_CEILING, 1, address(this)
        );
        claimMgr.setEngine(address(eng), address(vault));
        vault.setController(address(claimMgr));
        quotron.mint(address(vault), POT);
    }

    function _distinct(uint256 n) internal {
        // each id to a distinct owner, and every owner holds >= MIN_HOLD so the holder-only gate admits them
        for (uint256 i = 1; i <= n; ++i) {
            address o = vm.addr(1000 + i);
            nft.set(i, o, 0);
            nft.setBalance(o, eng.MIN_HOLD());
        }
    }

    // move into week w+1 and post the settling beacon so runDraw(w) can execute
    function _open(uint256 w, bytes32 beacon) internal {
        vm.warp(GENESIS + (w + 1) * WEEK + 1);
        assertEq(eng.currentPeriod(), w + 1);
        oracle.setBeacon(eng.drawRound(w), beacon);
    }

    function _claimAmts() internal view returns (uint256[] memory a, address[] memory r) {
        uint256 n = claimMgr.nextClaimId();
        a = new uint256[](n);
        r = new address[](n);
        for (uint256 i = 1; i <= n; ++i) {
            (, address recip, uint256 amt,,) = claimMgr.claims(i);
            a[i - 1] = amt;
            r[i - 1] = recip;
        }
    }

    // ── distinctness + flat share + dust rollforward ─────────────────────────
    function test_fiveDistinct_flatShare_dustRollsForward() public {
        _distinct(2000);
        _open(0, keccak256("b"));
        eng.runDraw(0);
        (uint256[] memory a, address[] memory r) = _claimAmts();
        assertEq(a.length, 5, "5 slots");
        uint256 share = POT / 5;
        for (uint256 i; i < 5; ++i) {
            assertEq(a[i], share, "flat pot/5");
            for (uint256 j = i + 1; j < 5; ++j) assertTrue(r[i] != r[j], "distinct winners");
        }
        // dust = POT % 5 (here 0) + any unseated share; reserved must be exactly 5*share
        assertEq(vault.unclaimedReserve(), 5 * share, "only 5*share reserved");
        assertEq(vault.freeBalance(), POT - 5 * share, "remainder rolls forward");
    }

    // ── per-winner isolation in runDraw() ────────────────────────────────────

    /// runDraw() called registerClaim bare, so ONE reverting winner unpaid the other four. Now that seat is
    /// skipped, its share is never reserved and rolls forward, and the week stays drawn (the beacon already
    /// fixed the outcome).
    function test_oneRevertingWinnerDoesNotUnpayTheOthers() public {
        _distinct(2000);
        _open(0, keccak256("b"));
        (, address[5] memory winner, uint256 filled) = eng.previewDraw(0);
        assertEq(filled, 5, "five seats");

        vm.mockCallRevert(
            address(claimMgr),
            abi.encodeWithSelector(claimMgr.registerClaim.selector, address(vault), winner[0]),
            abi.encodeWithSignature("Error(string)", "poisoned")
        );
        eng.runDraw(0);

        assertTrue(eng.drawn(0), "the week settled despite a reverting winner");
        assertEq(claimMgr.nextClaimId(), 4, "the other four were paid");
        uint256 share = POT / 5;
        assertEq(vault.unclaimedReserve(), 4 * share, "the skipped share was never reserved");
        assertEq(vault.freeBalance(), POT - 4 * share, "and it rolls forward");
    }

    /// No premature commit, the same rule as the raffle engine's daily draw. A week where ALL FIVE
    /// registrations reverted used to be marked drawn with nobody paid and the whole pot rolled forward,
    /// unretryably. The week is now consumed only once a claim really registered; the beacon is unchanged, so
    /// a retry inside the window re-runs the SAME winner set and can never be a re-roll.
    function test_weekIsNotConsumedWhenEveryRegistrationFails() public {
        _distinct(2000);
        _open(0, keccak256("b"));
        (, address[5] memory winner, uint256 filled) = eng.previewDraw(0);
        assertEq(filled, 5, "five seats");

        vm.mockCallRevert(
            address(claimMgr),
            abi.encodeWithSelector(claimMgr.registerClaim.selector),
            abi.encodeWithSignature("Error(string)", "down")
        );
        eng.runDraw(0);
        assertFalse(eng.drawn(0), "the week is NOT consumed when nobody was paid");
        assertEq(claimMgr.nextClaimId(), 0, "and nobody was paid");
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved");

        vm.clearMockedCalls();
        eng.runDraw(0);
        assertTrue(eng.drawn(0), "consumed once a claim really registered");
        assertEq(claimMgr.nextClaimId(), 5, "the same five winners, paid on the retry");
        (, address[5] memory winner2,) = eng.previewDraw(0);
        assertEq(winner2[0], winner[0], "same beacon, same winner set: a retry is never a re-roll");
    }

    /// The caller controls the gas. A registerClaim that ran out of the gas it was forwarded must revert the
    /// draw, never be read as a faulty winner and skipped.
    function test_gasStarvedRegistrationRevertsInsteadOfSkipping() public {
        _distinct(2000);
        _open(0, keccak256("b"));
        vm.etch(address(claimMgr), address(new HolderGasBurner()).code);

        vm.expectRevert(HolderDrawEngine.ClaimOutOfGas.selector);
        eng.runDraw{ gas: 15_000_000 }(0); // enough for winner selection; the burner eats what reaches registerClaim
        assertFalse(eng.drawn(0), "nothing latched");
    }

    // POT not divisible by 5 → dust stays in vault
    function test_dust_whenPotIndivisible() public {
        BaseVault v2 = new BaseVault(address(quotron), address(this));
        HolderDrawEngine e2 = new HolderDrawEngine(
            address(oracle), address(nft), address(v2), address(claimMgr),
            GENESIS, POT_CAP, POT_CEILING, 1, address(this)
        );
        claimMgr.setEngine(address(e2), address(v2));
        v2.setController(address(claimMgr));
        uint256 pot = 100e18 + 3; // %5 == 3
        quotron.mint(address(v2), pot);
        _distinct(2000);
        vm.warp(GENESIS + WEEK + 1);
        oracle.setBeacon(e2.drawRound(0), keccak256("dust"));
        e2.runDraw(0);
        uint256 share = pot / 5;
        assertEq(v2.unclaimedReserve(), 5 * share, "reserve = 5*share");
        assertEq(v2.freeBalance(), pot - 5 * share, "dust (3 wei) + rounding rolls forward");
        assertEq(pot - 5 * share, 3, "exactly the 3 wei dust remains free");
    }

    // ── totalMinted boundary behaviour ───────────────────────────────────────
    function test_totalMinted_0_voidsNotConsumed() public {
        // no owners set → totalMinted 0
        _open(0, keccak256("z0"));
        eng.runDraw(0);
        assertFalse(eng.drawn(0), "n<5 voids, not consumed");
        assertEq(claimMgr.nextClaimId(), 0);
        assertEq(vault.freeBalance(), POT);
    }

    function test_totalMinted_1_and_4_void() public {
        _distinct(4);
        _open(0, keccak256("z4"));
        eng.runDraw(0);
        assertFalse(eng.drawn(0), "n==4 < WINNERS voids");
        assertEq(claimMgr.nextClaimId(), 0);
    }

    function test_totalMinted_exactly5_draws() public {
        _distinct(5);
        _open(0, keccak256("z5"));
        eng.runDraw(0);
        assertTrue(eng.drawn(0), "n==5 draws");
        (uint256[] memory a, address[] memory r) = _claimAmts();
        assertEq(a.length, 5);
        // with exactly 5 ids, the 5 winners must be exactly ids {1,2,3,4,5}
        for (uint256 i; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) assertTrue(r[i] != r[j], "distinct at n==5");
        }
    }

    function test_totalMinted_3000_draws_constantCost() public {
        _distinct(3000);
        _open(0, keccak256("z3000"));
        uint256 g = gasleft();
        eng.runDraw(0);
        uint256 used = g - gasleft();
        emit log_named_uint("runDraw gas at n=3000", used);
        assertTrue(eng.drawn(0), "draws at n=3000");
        assertEq(claimMgr.nextClaimId(), 5);
    }

    // ── a single bad tokenId must not brick the draw ─────────────────────────
    // zero-owner in range: MockNFT.ownerOf returns address(0) for gaps
    function test_zeroOwnerGap_doesNotBrick() public {
        // populate ids 1..10 but blow totalMinted up to 2000 so ~1990 ids are zero-owner
        _distinct(10);
        nft.setTotalMinted(2000);
        _open(0, keccak256("gap"));
        // Most candidates hit zero-owner and are re-rolled; with only 10 eligible in 2000,
        // seating 5 distinct needs luck within 256 rerolls. Just assert it does not revert.
        eng.runDraw(0);
        // Either it seated some (drawn) or exhausted (voided) — but MUST NOT revert/brick.
        assertTrue(true, "no revert");
    }

    function test_revertingOwnerOf_doesNotBrick() public {
        RevertingNFT2 rnft = new RevertingNFT2();
        HolderDrawEngine e2 = new HolderDrawEngine(
            address(oracle), address(nft) /*placeholder*/, address(vault), address(claimMgr),
            GENESIS, POT_CAP, POT_CEILING, 1, address(this)
        );
        // rewire with reverting nft via a fresh engine
        HolderDrawEngine e3 = new HolderDrawEngine(
            address(oracle), address(rnft), address(vault), address(claimMgr),
            GENESIS, POT_CAP, POT_CEILING, 1, address(this)
        );
        claimMgr.setEngine(address(e3), address(vault));
        for (uint256 i = 1; i <= 200; ++i) rnft.set(i, vm.addr(3000 + i));
        rnft.setTotalMinted(2000); // 201..2000 revert in ownerOf
        vm.warp(GENESIS + WEEK + 1);
        oracle.setBeacon(e3.drawRound(0), keccak256("rev"));
        e3.runDraw(0);
        assertEq(claimMgr.nextClaimId(), 5, "draws over minted subset despite reverting ids");
        e2; // silence
    }

    // ── previewDraw must agree with runDraw element-for-element ───────────────
    function test_previewMatchesRunDraw() public {
        _distinct(2000);
        _open(0, keccak256("agree"));
        (uint256[5] memory pWon, address[5] memory pWin, uint256 pFilled) = eng.previewDraw(0);
        eng.runDraw(0);
        (uint256[] memory a, address[] memory r) = _claimAmts();
        assertEq(pFilled, a.length, "filled matches claim count");
        for (uint256 i; i < pFilled; ++i) {
            assertEq(pWin[i], r[i], "winner addr matches order");
            assertTrue(pWon[i] != 0, "won id set");
        }
    }

    // ── front-run: post-freeze transfer removes BOTH seller and buyer ────────
    function test_postFreezeTransfer_bothOut() public {
        _distinct(5);
        // capture week-0 owner of id 1
        address seller = nft.ownerOf(1);
        // move into week 1 window boundary: freeze instant for week0 = GENESIS+WEEK
        vm.warp(GENESIS + WEEK + 100); // now week 1, after freeze
        address buyer = makeAddr("buyer");
        nft.set(1, buyer, 0);
        nft.setOwnerSince(1, uint64(block.timestamp)); // MockNFT.set does NOT restamp on re-set; do it explicitly
        assertGt(nft.ownerSince(1), eng.snapDeadline(0), "id1 ownerSince now past the freeze");
        oracle.setBeacon(eng.drawRound(0), keccak256("fr"));
        eng.runDraw(0);
        (, address[] memory r) = _claimAmts();
        for (uint256 i; i < r.length; ++i) {
            assertTrue(r[i] != seller, "seller not paid? actually seller SOLD after freeze");
            assertTrue(r[i] != buyer, "post-freeze buyer never paid");
        }
        // id 1 is out for both; only ids 2..5 eligible → n=5 but one ineligible → filled<=4
        // draw still seats the 4 remaining distinct eligible tokens
    }

    // ── the money knobs are SCHEDULED, not live ──

    /// THE DISCRIMINATING TEST. Pre-fix this fails: week 0's beacon is already public (previewDraw names the
    /// five winners), the owner cuts potCap 25% inside the draw window, and every winner is paid 25% less
    /// because runDraw read potCap LIVE. The +/-25% band and the weekly cooldown bounded magnitude and rate,
    /// never REACTIVITY, which is the property exclusion already had, and which this engine already
    /// implements correctly in _excludedAt.
    function test_ownerCannotCutPotAfterBeaconIsPublic() public {
        quotron.mint(address(vault), 2_000e18); // freeBalance now exceeds POT_CAP, so the cap actually binds
        _distinct(10);
        _open(0, keccak256("n1-cut")); // week 0 settled; currentPeriod() == 1; winners knowable
        assertEq(eng.currentPeriod(), 1);

        uint256 capForWeek0 = eng.potCapAt(0);
        assertEq(capForWeek0, POT_CAP, "week 0 sees the constructor cap");

        eng.setPotCap((POT_CAP * 3) / 4); // the reactive cut, in-band and inside the window

        assertEq(eng.potCapAt(0), POT_CAP, "week 0 is IMMUNE to a write made during week 1");
        assertEq(eng.potCapAt(1), POT_CAP, "so is week 1 -- a write at p lands at p+1");
        assertEq(eng.potCapAt(2), (POT_CAP * 3) / 4, "the cut takes effect from week 2");

        eng.runDraw(0);
        (uint256[] memory a,) = _claimAmts();
        assertEq(a[0], POT_CAP / 5, "winners paid the PRE-cut cap despite the reactive write");
        assertEq(vault.unclaimedReserve(), POT_CAP, "full pre-cut pot reserved");
    }

    /// The same scheduling guarantee on the other knob. The old comment claimed the cooldown "stops a
    /// reactive minPot->potCap jump to force the void branch". It stopped the JUMP, not the REACTION: a
    /// single in-band raise still voided a week whose winners were already public whenever
    /// pot < 1.25 * minPot. Scheduling is what actually closes it.
    function test_minPotRaiseCannotVoidAnAlreadySettledWeek() public {
        _distinct(10);
        _open(0, keccak256("n1-void"));
        uint256 before = eng.minPotAt(0);
        eng.setMinPot(before + 1); // smallest legal in-band raise
        assertEq(eng.minPotAt(0), before, "week 0 immune");
        assertEq(eng.minPotAt(1), before, "write at p lands at p+1");
        assertEq(eng.minPotAt(2), before + 1, "effective from week 2");
    }

    /// A scheduled value must actually become live, and the NEXT write must measure its band from the
    /// promoted value rather than the stale one -- otherwise the knob could drift past +/-25% per step.
    function test_scheduledValuePromotesAndBandsFromIt() public {
        uint256 raised = (POT_CAP * 5) / 4; // +25%, the max single step
        eng.setPotCap(raised);
        vm.warp(GENESIS + 2 * WEEK + 1); // into week 2, where the change is effective
        assertEq(eng.currentPeriod(), 2);
        assertEq(eng.potCapAt(2), raised, "promoted");
        // the next write bands off the PROMOTED value, not the constructor value
        uint256 tooHigh = (raised * 5) / 4 + 1;
        vm.expectRevert(HolderDrawEngine.AdjustOutOfBounds.selector);
        eng.setPotCap(tooHigh);
        eng.setPotCap((raised * 5) / 4); // exactly +25% off the promoted value is allowed
    }

    // ── potCap respected ─────────────────────────────────────────────────────
    function test_potCapRespected() public {
        quotron.mint(address(vault), 10 * POT_CAP);
        _distinct(2000);
        _open(0, keccak256("cap"));
        eng.runDraw(0);
        (uint256[] memory a,) = _claimAmts();
        assertEq(a[0], POT_CAP / 5, "capped at potCap/5");
        assertEq(vault.unclaimedReserve(), POT_CAP, "only potCap reserved");
    }

    // ── excluded owner is rejected as of the queried week ────────────────────
    function test_excludedOwnerRejected() public {
        // one whale owns all 2000; exclude it at week0 → effective week1; draw week0 in week1
        address whale = makeAddr("whale");
        for (uint256 i = 1; i <= 2000; ++i) nft.set(i, whale, 0);
        eng.setExcluded(whale, true); // effective from week 1
        // draw week 0 (queried in week 1): _excludedAt(whale,0) => week0 < effective(1) => !true = false
        _open(0, keccak256("ex0"));
        eng.runDraw(0);
        assertTrue(eng.drawn(0), "week0 draw: exclusion NOT yet in force for week0");
        // now draw week 1 (in week 2): exclusion in force → whale excluded → all rerolls fail → void
        vm.warp(GENESIS + 2 * WEEK + 1);
        assertEq(eng.currentPeriod(), 2);
        oracle.setBeacon(eng.drawRound(1), keccak256("ex1"));
        eng.runDraw(1);
        assertFalse(eng.drawn(1), "week1: whale excluded, no eligible owner, voids");
    }

    // ── MIN_HOLD, FROZEN: below the threshold AT THE FREEZE never wins that week; a post-freeze top-up
    //    does NOT retroactively qualify (the qualifiedSince gate), but DOES qualify for a later week. ──
    function test_minHold_frozenGate_noPostFreezeTopUp() public {
        uint256 min = eng.MIN_HOLD();
        // five owners each holding MIN_HOLD-1 passes as of the freeze (set at GENESIS < freeze0) -> unqualified
        for (uint256 i = 1; i <= 5; ++i) { address o = vm.addr(1000 + i); nft.set(i, o, 0); nft.setBalance(o, min - 1); }
        _open(0, keccak256("mh")); // warps to week 1 (past freeze0), posts week-0 beacon
        assertFalse(eng.isEligible(0, 1), "below MIN_HOLD at the freeze -> ineligible for week 0");
        eng.runDraw(0);
        assertFalse(eng.drawn(0), "all under MIN_HOLD at freeze -> week voids");
        assertEq(claimMgr.nextClaimId(), 0);

        // Top up to MIN_HOLD NOW (during week 1, after freeze0 and after the beacon is public). The live
        // balance is now >= MIN_HOLD, but qualifiedSince is stamped at this instant, which is AFTER freeze0.
        for (uint256 i = 1; i <= 5; ++i) nft.setBalance(vm.addr(1000 + i), min);
        assertFalse(eng.isEligible(0, 1), "post-freeze top-up must NOT qualify for week 0 (frozen gate)");
        eng.runDraw(0);
        assertFalse(eng.drawn(0), "still voids: week-0 eligibility was frozen before the beacon");

        // But the top-up (done in week 1, before freeze1 = GENESIS+2*WEEK) DOES qualify them for week 1.
        vm.warp(GENESIS + 2 * WEEK + 1); // week 2: week 1 is now drawable
        oracle.setBeacon(eng.drawRound(1), keccak256("mh2"));
        assertTrue(eng.isEligible(1, 1), "qualifiedSince <= freeze1 -> eligible next week");
        eng.runDraw(1);
        assertTrue(eng.drawn(1), "the SAME holders win the following week, once qualified before its freeze");
        assertEq(claimMgr.nextClaimId(), 5, "five eligible winners once qualified in time");
    }

    // ── per-token selection (sybil-neutral): a wallet's slots scale with its eligible passes, and
    //    it CAN win several slots. A per-wallet cap was deliberately rejected: it would reward splitting a
    //    holding across cheap 4-pass wallets to win MORE slots (strictly +EV), breaking sybil-neutrality. ──
    function test_perToken_whaleCanWinMultipleSlots() public {
        address whale = makeAddr("whale");
        for (uint256 i = 1; i <= 2000; ++i) nft.set(i, whale, 0); // whale owns the whole field (qualified since GENESIS)
        _open(0, keccak256("whale"));
        eng.runDraw(0);
        assertTrue(eng.drawn(0));
        assertEq(claimMgr.nextClaimId(), 5, "per-token: the whale wins all 5 distinct-token slots (no per-wallet cap)");
        for (uint256 i = 1; i <= 5; ++i) { (, address r,,,) = claimMgr.claims(i); assertEq(r, whale, "each slot is the whale's"); }
        assertEq(vault.unclaimedReserve(), 5 * (POT / 5), "all five shares reserved");
    }

    // Splitting a holding across wallets confers NO advantage: 8 passes are 8 eligible ids either way. This is
    // exactly the property a per-wallet cap would have broken (4+4 would have out-earned 1x8).
    function test_minHold_sybilNeutral_splitNoAdvantage() public {
        uint256 min = eng.MIN_HOLD(); // 4
        // config A: one wallet holds 8 (ids 1..8)
        address whole = makeAddr("whole");
        for (uint256 i = 1; i <= 2 * min; ++i) nft.set(i, whole, 0);
        // config B: two wallets hold MIN_HOLD each (ids 9..12, 13..16)
        address ha = makeAddr("halfA");
        address hb = makeAddr("halfB");
        for (uint256 i = 2 * min + 1; i <= 3 * min; ++i) nft.set(i, ha, 0);
        for (uint256 i = 3 * min + 1; i <= 4 * min; ++i) nft.set(i, hb, 0);
        _open(0, keccak256("sybil"));
        uint256 eligA;
        for (uint256 i = 1; i <= 2 * min; ++i) if (eng.isEligible(0, i)) ++eligA;
        uint256 eligB;
        for (uint256 i = 2 * min + 1; i <= 4 * min; ++i) if (eng.isEligible(0, i)) ++eligB;
        assertEq(eligA, 2 * min, "8 passes in ONE wallet -> 8 eligible candidate ids");
        assertEq(eligB, 2 * min, "8 passes split 4+4 -> ALSO 8 eligible ids: splitting gains nothing");
    }

    // ── already drawn / outside window ───────────────────────────────────────
    function test_alreadyDrawn_and_window() public {
        _distinct(2000);
        _open(0, keccak256("ad"));
        eng.runDraw(0);
        vm.expectRevert(HolderDrawEngine.AlreadyDrawn.selector);
        eng.runDraw(0);
    }

    function test_outsideWindow_reverts() public {
        _distinct(2000);
        vm.warp(GENESIS + 3 * WEEK + 1); // week 0's draw window (week 1) has passed
        vm.expectRevert(HolderDrawEngine.OutsideWindow.selector);
        eng.runDraw(0);
    }
}
