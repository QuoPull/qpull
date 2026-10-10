// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice The ticket-accounting handler. It deploys the PackRegistry and holds BOTH privileged roles
///         (recorder and engine), so a fuzzed sequence can interleave the four things that move a ticket
///         in or out of the sliding window:
///           buy        -> recordBuy mints a paid cohort entry
///           claimFree  -> the NFT perk mints a free, rip-XP-INELIGIBLE cohort entry (spec §16)
///           draw       -> drawFrom swap-pops winners out of the window and marks them spent
///           rip        -> claimRipXp swap-pops a settled non-winner out WITHOUT marking it spent
///                         and banks its rarity-weighted XP
///         plus warpDays, which is how a cohort ages out: expiry here is free, an aged cohort is simply
///         never in-window again, so the window arithmetic is the only thing standing between the
///         protocol and a double-paid or vanished ticket.
/// @dev    Ghost ledgers are kept PER COHORT DAY (minted / drawn / ripped) so the invariants can prove
///         the bookkeeping cohort by cohort, not just in aggregate — a swap-pop that removed the wrong
///         element from the wrong cohort would net out in a global count but not a per-cohort one.
contract TicketAccountingHandler is Test {
    PackRegistry public immutable reg;
    MockDrandOracle public immutable oracle;
    MockNFT public immutable nft;
    MockRecorder public immutable leaderboard;

    uint256 internal constant TICKET = 10e18;
    uint32 internal constant LIFE_DAYS = 7;
    uint256 internal constant SCAN_WINDOW = 128; // bound the candidate scan so actions stay cheap

    address[] public actors;
    uint256[] public allIds;

    // ─── ghost ledgers ────────────────────────────────────────────────────────
    uint256 public minted;
    uint256 public drawn;
    uint256 public ripped;
    mapping(uint32 => uint256) public mintedOnDay;
    mapping(uint32 => uint256) public drawnOnDay;
    mapping(uint32 => uint256) public rippedOnDay;
    mapping(uint256 => bool) public everDrawn;
    uint256 public reverts;

    constructor(uint256 genesis_) {
        oracle = new MockDrandOracle(genesis_, 30); // 30s drand period
        nft = new MockNFT();
        leaderboard = new MockRecorder();
        reg = new PackRegistry(address(oracle), TICKET, genesis_, 1 hours, address(this));
        // This handler IS the recorder (the tax hook) and the engine (the RaffleEngine); both bindings
        // are write-once, so they are made here and never touched again.
        reg.setRecorder(address(this));
        reg.setEngine(address(this));
        reg.setLeaderboard(address(leaderboard));
        reg.setNft(address(nft));

        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("ticket-actor", i)))));
            actors.push(a);
            nft.set(i + 1, a, uint8(i)); // one pass each, rarities Common..Super rare
        }
    }

    /// @dev This handler IS the engine, so it answers the engine view isRipXpClaimable reads. There is
    ///      no opening in this model (the handler draws every day directly), so it reports settled.
    function openingDone() external pure returns (bool) {
        return true;
    }

    // ─── actions ──────────────────────────────────────────────────────────────

    /// A taxed buy: whole tickets on the fixed schedule, the sub-ticket remainder banked (spec §4).
    function buy(uint256 actorSeed, uint256 grossSeed) external {
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 gross = bound(grossSeed, 0, 60 * TICKET);
        uint32 cday = reg.today();
        uint256 firstId = reg.nextPackId();
        reg.recordBuy(who, gross); // handler is the recorder
        _bookMint(firstId, cday);
    }

    // NOTE: the old NFT free-entry perk (claimFreeEntries) was replaced by the VIRTUAL entry model, which
    // never mints packs into cohortLive, so it no longer participates in ticket accounting. This handler was
    // removed with it; the paid-ticket invariant below is unchanged.

    /// The day's raffle draw: pops up to k distinct live tickets out of the 7-day window.
    function draw(uint256 kSeed, uint256 beaconSeed) external {
        uint32 drawDay = reg.today();
        if (drawDay == 0) return; // day 0 has no eligible cohort yet
        uint256 k = bound(kSeed, 1, 40);

        uint256[] memory winners = reg.drawFrom(keccak256(abi.encode("draw", beaconSeed)), drawDay, k);
        for (uint256 i; i < winners.length; ++i) {
            uint256 id = winners[i];
            // No double-count: a ticket can be won at most once, ever.
            assertFalse(everDrawn[id], "pack drawn twice");
            // a ripped (already-banked) pack must have LEFT the live pool, so a later
            // draw can never also pay it. A corrupted swap-pop index would surface exactly here.
            assertFalse(reg.ripXpGranted(id), "a ripped pack was still drawable");
            everDrawn[id] = true;

            (address owner_,, uint32 cohortDay, bool spent) = reg.packs(id);
            assertTrue(owner_ != address(0), "drew a pack that was never minted");
            assertTrue(spent, "winner was not marked spent");
            // Cohorts age out correctly: a cohort minted on day D is eligible on D+1 .. D+7 and nowhere
            // else, so every winner must sit inside that band relative to the draw day.
            assertTrue(uint256(cohortDay) + 1 <= uint256(drawDay), "winner from a not-yet-eligible cohort");
            assertTrue(uint256(cohortDay) + LIFE_DAYS >= uint256(drawDay), "winner from an expired cohort");

            drawnOnDay[cohortDay] += 1;
        }
        drawn += winners.length;
    }

    /// Ripping settled non-winners: banks rarity-weighted XP and removes them from the live pool.
    function rip(uint256 actorSeed, uint256 startSeed) external {
        uint256 n = allIds.length;
        if (n == 0) return;
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 start = bound(startSeed, 0, n - 1);

        uint256[] memory batch = new uint256[](8);
        uint256 c;
        uint256 scan = n < SCAN_WINDOW ? n : SCAN_WINDOW;
        for (uint256 i; i < scan && c < 8; ++i) {
            uint256 id = allIds[(start + i) % n];
            if (reg.ownerOf(id) != who) continue;
            if (!reg.isRipXpClaimable(id)) continue;
            batch[c++] = id;
        }
        if (c == 0) return;
        assembly {
            mstore(batch, c) // shrink to the candidates actually found
        }

        vm.prank(who);
        try reg.claimRipXp(batch) {
            for (uint256 i; i < c; ++i) {
                uint256 id = batch[i];
                if (!reg.ripXpGranted(id)) continue; // skipped by claimRipXp, not ripped
                (,, uint32 cohortDay,) = reg.packs(id);
                rippedOnDay[cohortDay] += 1;
                ripped += 1;
            }
        } catch {
            ++reverts;
        }
    }

    /// Advance the cadence so cohorts actually slide out of the window and rips become claimable.
    function warpDays(uint256 daysSeed) external {
        vm.warp(block.timestamp + bound(daysSeed, 1, 4) * 1 days);
    }

    // ─── internals ────────────────────────────────────────────────────────────

    /// Book every id minted in this call into the ghost ledgers, and post the cohort's tier beacon the
    /// way the keeper would (one quantized round per day) so rips can settle later in the sequence.
    function _bookMint(uint256 firstId, uint32 cday) internal {
        uint256 lastId = reg.nextPackId();
        if (lastId == firstId) return;
        for (uint256 id = firstId; id < lastId; ++id) {
            allIds.push(id);
        }
        uint256 n = lastId - firstId;
        minted += n;
        mintedOnDay[cday] += n;

        (, uint64 revealRound,,) = reg.packs(firstId);
        if (!oracle.isAvailable(revealRound)) {
            oracle.setBeacon(revealRound, keccak256(abi.encode(revealRound)));
        }
    }
}

/// @title  InvariantTicketAccountingTest
/// @notice INVARIANT 3 (SLIDING-WINDOW TICKET ACCOUNTING). PackRegistry's live-ticket cohort bookkeeping
///         stays consistent under fuzzed buys, free-entry claims, draws, rips and expiries:
///           - no double-count : cohort sizes plus everything removed equal everything minted, per day
///           - no negative     : a cohort can never be popped below its own minted total
///           - correct ageing  : liveCount(d) is exactly the cohorts [d-7 .. d-1] and nothing older
///         This is the O(K) draw's load-bearing assumption. If a swap-pop ever corrupts packLiveIndex,
///         a ticket is either paid twice or silently deleted, and both show up here.
/// @dev    The registry is deployed by the handler (it needs the handler as its write-once recorder and
///         engine), so the invariants read it back through handler.reg().
contract InvariantTicketAccountingTest is Test {
    TicketAccountingHandler handler;
    PackRegistry reg;

    uint32 internal constant LIFE_DAYS = 7;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new TicketAccountingHandler(block.timestamp);
        reg = handler.reg();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TicketAccountingHandler.buy.selector;
        selectors[1] = TicketAccountingHandler.draw.selector;
        selectors[2] = TicketAccountingHandler.rip.selector;
        selectors[3] = TicketAccountingHandler.warpDays.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Global conservation: every ticket ever minted is either still live in some cohort, was drawn as a
    /// winner, or was ripped out as a settled non-winner. Stated as an addition so an underflow in the
    /// bookkeeping cannot hide inside a subtraction.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_liveSetConservation() public view {
        uint32 today = reg.today();
        uint256 live;
        for (uint32 c; c <= today; ++c) {
            live += reg.cohortSize(c);
        }
        assertEq(
            live + handler.drawn() + handler.ripped(),
            handler.minted(),
            "live + drawn + ripped does not equal minted"
        );
    }

    /// The same conservation COHORT BY COHORT. A swap-pop that removed the right count from the wrong
    /// cohort would net out globally but breaks here.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_perCohortConservation() public view {
        uint32 today = reg.today();
        for (uint32 c; c <= today; ++c) {
            assertEq(
                reg.cohortSize(c) + handler.drawnOnDay(c) + handler.rippedOnDay(c),
                handler.mintedOnDay(c),
                "cohort ledger does not balance"
            );
        }
    }

    /// liveCount(d) is exactly the sum of the in-window cohorts [d-7 .. d-1] — recomputed here rather
    /// than trusted. Checked for today's draw and tomorrow's, the two the engine can actually run.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_liveCountMatchesSlidingWindow() public view {
        uint32 today = reg.today();
        for (uint32 d = today == 0 ? 1 : today; d <= today + 1; ++d) {
            uint32 from = d > LIFE_DAYS ? d - LIFE_DAYS : 0;
            uint256 expected;
            for (uint32 c = from; c <= d - 1; ++c) {
                expected += reg.cohortSize(c);
            }
            assertEq(reg.liveCount(d), expected, "liveCount does not match the 7-day window");
        }
    }

    /// Cohorts age out: tickets older than the window are still counted as minted, but contribute
    /// nothing to any future draw. The out-of-window remainder must be exactly the difference between
    /// the whole live set and the drawable set.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_agedCohortsLeaveTheDrawWindow() public view {
        uint32 today = reg.today();
        uint32 d = today + 1; // the next draw day
        uint32 from = d > LIFE_DAYS ? d - LIFE_DAYS : 0;

        uint256 live;
        uint256 expired;
        for (uint32 c; c <= today; ++c) {
            uint256 sz = reg.cohortSize(c);
            live += sz;
            if (c < from) expired += sz;
        }
        assertEq(live - reg.liveCount(d), expired, "expired cohorts are still inside the draw window");
        assertLe(reg.liveCount(d), live, "drawable set exceeds the live set");
    }

    /// Ids are handed out densely and only by minting: nextPackId is always one past everything minted,
    /// so no id is ever skipped (an unreachable ticket) or reused (a double-owned ticket).
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_packIdsAreDenseAndUnique() public view {
        assertEq(reg.nextPackId(), handler.minted() + 1, "pack id counter drifted from the minted total");
    }
}
