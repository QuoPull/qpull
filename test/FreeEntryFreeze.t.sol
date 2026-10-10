// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistryHarness, PledgeFloodBase } from "./NFTIntegration.t.sol";

/// @notice The free-entry seat geometry must be a function of state frozen at
///         `freeze = genesis + (day+1)*DAY()`, so that a transfer made AFTER the daily beacon is public
///         cannot reshuffle the draw.
///
///         THE BUG: `_buildSrList` filtered Super Rare membership on LIVE `ownerSince`/`ownerOf`. Because
///         `ownerSince` is re-stamped on every transfer, moving a pass after the freeze dropped it from the
///         list, which changed `srCount`, which changed `wb = srCount*SR_WEIGHT + pledges` AND the dense
///         `srList` index map. Both feed the seat roll (`x % wb`, then `srList[x % srCount]`), so ONE
///         transfer re-rolled EVERY seat. The beacon is public before the draw runs, so a holder of several
///         Super Rares could preview each candidate `srCount`, pick the arrangement that seated their
///         remaining passes best, and execute it.
///
///         THE FIX: membership is decided ONLY by `srRegisteredAt <= freeze` (write-once, freeze-gated, and
///         the scan is a prefix of an append-only array), so `srCount`, `srList` and `wb` are immutable after
///         the freeze. Ownership is tested PER SEAT inside `_pickVirtual`, as a TERMINAL void that burns no
///         rejection budget.
///
///         THE GUARANTEE THESE TESTS PIN: a post-freeze transfer of
///         a Super Rare can void that pass's own seats and can do nothing else. It cannot move a win to a
///         different pass, cannot change any other seat's occupant, and cannot consume rejection budget.
///
/// @dev    Every test here depends on `MockNFT.transferTo`, which re-stamps `ownerSince` the way the real
///         collection does. `MockNFT.set` deliberately does NOT re-stamp, so using it as a "transfer" would
///         make all of these pass VACUOUSLY against unfixed code. Do not swap transferTo back to set.
contract FreeEntryFreezeTest is PledgeFloodBase {
    address alt = makeAddr("alt");
    address srA = makeAddr("srA");
    address srB = makeAddr("srB");
    address srC = makeAddr("srC");

    uint256 constant SAMPLE = 400; // seats sampled per comparison

    /// @dev Register `n` Super Rares each to a DISTINCT owner. The synthetic winner id encodes the OWNER, not
    ///      the token id, so distinct owners are the only way to attribute a seat back to a specific pass.
    function _srsDistinct() internal {
        address[3] memory owners = [srA, srB, srC];
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            nft.set(SR_BASE + i, owners[i], 3);
            ids[i] = SR_BASE + i;
        }
        packs.registerSuperRare(ids);
    }

    function _freeze() internal pure returns (uint256) {
        return GENESIS + (uint256(D) + 1) * DAY;
    }

    /// @dev Snapshot the occupant of every sampled seat through the shared resolver.
    function _seats(bytes32 beacon) internal view returns (uint256[] memory out) {
        out = new uint256[](SAMPLE);
        for (uint256 s; s < SAMPLE; ++s) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, s);
            out[s] = tid;
        }
    }

    // ── THE DISCRIMINATING TEST: fails on unfixed code, passes after the fix ────────────────────────────

    /// @notice Moving one Super Rare after the freeze must void ONLY that pass's own seats and leave every
    ///         other seat byte-identical. On unfixed code srCount goes 3 -> 2 and wb goes 24 -> 16, so
    ///         `x % wb` and `srList[x % srCount]` both change and essentially every seat is reassigned.
    function test_srMovedAfterFreeze_everyOtherSeatUnchanged() public {
        _srsDistinct();
        _warpToDraw();

        bytes32 beacon = keccak256("fs3-discriminating");
        uint256[] memory before = _seats(beacon);

        // the moved pass must actually occupy seats in the baseline, or the test proves nothing
        uint256 movedSeats;
        for (uint256 s; s < SAMPLE; ++s) if (before[s] == SR_BASE + 1) ++movedSeats;
        assertGt(movedSeats, 0, "fixture: moved pass must win seats in the baseline");

        // a REAL post-freeze transfer (re-stamps ownerSince), after the beacon is public
        nft.transferTo(SR_BASE + 1, alt);
        uint256[] memory afterMove = _seats(beacon);

        uint256 voided;
        for (uint256 s; s < SAMPLE; ++s) {
            if (before[s] == SR_BASE + 1) {
                assertEq(afterMove[s], packs.notSeated(), "moved pass's own seat must VOID");
                ++voided;
            } else {
                // the load-bearing assertion: every other seat is untouched
                assertEq(afterMove[s], before[s], "an unrelated seat was reassigned: geometry is not frozen");
            }
        }
        assertEq(voided, movedSeats, "exactly the moved pass's seats voided");
    }

    /// @notice The mover cannot hand seats to anyone, including themselves via the recipient.
    function test_movedPassSeatsGoToNobody() public {
        _srsDistinct();
        _warpToDraw();
        bytes32 beacon = keccak256("fs3-nobody");
        uint256[] memory before = _seats(beacon);
        nft.transferTo(SR_BASE + 1, alt);
        uint256[] memory afterMove = _seats(beacon);
        for (uint256 s; s < SAMPLE; ++s) {
            if (before[s] == SR_BASE + 1) assertEq(afterMove[s], packs.notSeated(), "forfeited, not redirected");
        }
    }

    // ── the frozen geometry itself ──────────────────────────────────────────────────────────────────────

    /// @notice srCount / wb / vPool must be immune to post-freeze transfers AND post-freeze registrations.
    ///         This is the mirror that fails loudly if anyone reintroduces an ownership filter into
    ///         _buildSrList.
    function test_freeCfgIsFreezeStable() public {
        _srsDistinct();
        _warpToDraw();
        (uint256 c0, uint256 wb0, uint256 v0) = packs.freeCfg(D, PAID);
        assertEq(c0, 3, "3 registered before the freeze");
        assertEq(wb0, 24, "wb = 3 * SR_WEIGHT(8), no pledges");

        // (a) move every pass after the freeze
        nft.transferTo(SR_BASE, alt);
        nft.transferTo(SR_BASE + 1, alt);
        nft.transferTo(SR_BASE + 2, alt);
        // (b) register more ids after the freeze
        uint256[] memory late = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            nft.set(50 + i, alt, 3);
            late[i] = 50 + i;
        }
        packs.registerSuperRare(late);

        (uint256 c1, uint256 wb1, uint256 v1) = packs.freeCfg(D, PAID);
        assertEq(c1, c0, "srCount must not move");
        assertEq(wb1, wb0, "wb must not move");
        assertEq(v1, v0, "vPool must not move");
    }

    /// @notice Late registration stays excluded from this day (non-regression). The fix removed two
    ///         of the three original filters, so srRegisteredAt now carries the anti-snipe weight alone.
    function test_lateRegistrationStillExcludedThisDay() public {
        _warpToDraw();
        uint256[] memory ids = new uint256[](1);
        nft.set(SR_BASE, srA, 3);
        ids[0] = SR_BASE;
        packs.registerSuperRare(ids); // registered AFTER freeze(D)
        (uint256 c, uint256 wb,) = packs.freeCfg(D, PAID);
        assertEq(c, 0, "registered after the freeze: not in this day's set");
        assertEq(wb, 0, "no entrants, no weight");
    }

    // ── the per-seat predicate ──────────────────────────────────────────────────────────────────────────

    /// @notice Both edges of the new guard, including the zero clause. Writing the predicate as a bare
    ///         `ownerSince <= freeze` would seat an id whose ownerSince is 0 and this test would fail.
    function test_ownerSinceBoundary_andZeroClause() public {
        _srsDistinct();
        _warpToDraw();
        bytes32 beacon = keccak256("fs3-boundary");

        // find a seat that lands on SR_BASE while everything is eligible
        uint256 target = type(uint256).max;
        for (uint256 s; s < SAMPLE; ++s) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, s);
            if (tid == SR_BASE) { target = s; break; }
        }
        assertLt(target, SAMPLE, "fixture: need a seat landing on SR_BASE");

        // inclusive boundary: held exactly AT the freeze still seats
        nft.setOwnerSince(SR_BASE, uint64(_freeze()));
        uint256 atFreeze = packs.pickVirtual(beacon, D, PAID, target);
        assertEq(atFreeze, SR_BASE, "ownerSince == freeze is eligible (inclusive)");

        // one second later: forfeits
        nft.setOwnerSince(SR_BASE, uint64(_freeze() + 1));
        uint256 afterFreeze = packs.pickVirtual(beacon, D, PAID, target);
        assertEq(afterFreeze, packs.notSeated(), "acquired after the freeze must forfeit");

        // the zero clause: ownerSince == 0 must FORFEIT, not seat
        nft.setOwnerSince(SR_BASE, 0);
        uint256 zero = packs.pickVirtual(beacon, D, PAID, target);
        assertEq(zero, packs.notSeated(), "ownerSince == 0 must forfeit (explicit zero clause)");
    }

    /// @notice The SR void must be TERMINAL and must burn NO shared rejection budget. If someone "simplifies"
    ///         it into a re-roll, the seat would be redirected onto another token (the reshuffle this suite rules out) and a
    ///         griefer could drain the shared budget by moving passes, so this pins both properties.
    function test_ineligibleSrVoidsTerminally() public {
        _srsDistinct();
        _warpToDraw();
        bytes32 beacon = keccak256("fs3-budget");

        uint256 target = type(uint256).max;
        for (uint256 s; s < SAMPLE; ++s) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, s);
            if (tid == SR_BASE + 2) { target = s; break; }
        }
        assertLt(target, SAMPLE, "fixture: need a seat landing on SR_BASE+2");

        nft.transferTo(SR_BASE + 2, alt);
        uint256 tid2 = packs.pickVirtual(beacon, D, PAID, target);
        assertEq(tid2, packs.notSeated(), "forfeited SR voids terminally: the seat is destroyed, never moved");
    }

    // ── the deliberate behavior change, pinned so it is a decision and not a surprise ───────────────────

    /// @notice A day on which every registered Super Rare has moved still folds a cap-sized free block whose
    ///         seats all void, where the old code degenerated to paid-only. vPool must stay driven by wb
    ///         alone: making it depend on eligibility would feed `total` and re-roll the PAID winners too.
    function test_allForfeited_blockStillFoldsAndVoids() public {
        _srsDistinct();
        _warpToDraw();
        (, uint256 wb0, uint256 v0) = packs.freeCfg(D, PAID);
        assertGt(v0, 0, "baseline has a free block");

        nft.transferTo(SR_BASE, alt);
        nft.transferTo(SR_BASE + 1, alt);
        nft.transferTo(SR_BASE + 2, alt);

        (, uint256 wb1, uint256 v1) = packs.freeCfg(D, PAID);
        assertEq(wb1, wb0, "wb unchanged: membership is frozen");
        assertEq(v1, v0, "vPool unchanged (NOT zero) even with every pass forfeited");

        bytes32 beacon = keccak256("fs3-allvoid");
        for (uint256 s; s < 50; ++s) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, s);
            assertEq(tid, packs.notSeated(), "every seat voids when every pass forfeited");
        }
    }

    /// @notice A self-transfer must NOT forfeit. ownerSince is now the sole eligibility input for the daily
    ///         free block, so the `from == to` guard is load-bearing: without it, any marketplace approval a
    ///         holder ever granted becomes a daily kill switch on their own free entries.
    function test_selfTransferCannotForfeitASeat() public {
        _srsDistinct();
        _warpToDraw();
        bytes32 beacon = keccak256("fs3-self");
        uint256[] memory before = _seats(beacon);

        nft.transferTo(SR_BASE + 1, srB); // srB already owns it: self-transfer

        uint256[] memory afterSelf = _seats(beacon);
        for (uint256 s; s < SAMPLE; ++s) {
            assertEq(afterSelf[s], before[s], "a self-transfer must not re-stamp or forfeit");
        }
    }
}

/// @notice The pledge band. In an earlier version `_pickVirtual` validated a pledged copy against LIVE ownership
///         and RE-ROLLED on failure, and a re-roll re-samples the whole region, so moving a pledged pass after the
///         beacon moved that seat onto a DIFFERENT token. The pledge band now answers the same way as the Super
///         Rare band: a pledged copy whose pass changed hands after the freeze voids its own seat, terminally.
///
/// @dev    The test below uses the byte-identity form of test_srMovedAfterFreeze_everyOtherSeatUnchanged:
///         every seat the moved pass held voids, and every other seat is unchanged.
contract FreeEntryPledgeBandTest is PledgeFloodBase {
    address alt2 = makeAddr("alt2");

    /// @notice Moving a pledged pass after the beacon is public used to
    ///         RE-ROLL that pass's seats onto a different token, which let a multi-pass holder pick a
    ///         better-paying tier with the whole outcome already known. Now the pledge band voids exactly like
    ///         the Super Rare band: the moved pass's own seats are destroyed and NOTHING else moves. Both
    ///         halves are asserted, because the second is what makes the first a fix rather than a reshuffle.
    function test_pledgeMoveAfterFreezeVoidsOwnSeatsAndMovesNothingElse() public {
        _srs(1);
        _warpToPledgeDay(); // pledge() records against _today(), which must be day D
        _pledgeRares(honest, HONEST_BASE, 3);
        _pledgeRares(flooder, FLOOD_BASE, 3);
        _warpToDraw();

        bytes32 beacon = keccak256("fs3b-closed");
        uint256 n = 300;
        uint256[] memory before = new uint256[](n);
        for (uint256 s; s < n; ++s) {
            before[s] = packs.pickVirtual(beacon, D, PAID, s);
        }

        // move a VALID pledged pass after the beacon is public
        nft.transferTo(HONEST_BASE, alt2);

        uint256 heldBefore;
        uint256 voided;
        uint256 reseated;
        uint256 unchangedElsewhere;
        for (uint256 s; s < n; ++s) {
            uint256 nowTid = packs.pickVirtual(beacon, D, PAID, s);
            if (before[s] == HONEST_BASE) {
                ++heldBefore;
                if (nowTid == packs.notSeated()) ++voided;
                else ++reseated;
            } else {
                assertEq(nowTid, before[s], "a seat the moved pass never held must not change at all");
                ++unchangedElsewhere;
            }
        }
        assertGt(heldBefore, 0, "fixture: the moved pledged pass must hold seats in the baseline");
        assertEq(reseated, 0, "a moved pledged pass must never re-seat another token");
        assertEq(voided, heldBefore, "every seat it held voids instead");
        assertGt(unchangedElsewhere, 0);
    }
}
