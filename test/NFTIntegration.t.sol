// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

// NOTE: the first-hour NFT-holder gate (spec §16) lives in QpullTaxHook, tested in
// test/QpullTaxHook.t.sol. This file covers the VIRTUAL Art Pass daily-entry model (docs/PLEDGE-ENTRY-SPEC.md)
// that replaced the old count-based claimFreeEntries perk: Super Rare auto-entry + Common/Uncommon/Rare
// pledge, a 10%-of-paid linear cap, multi-shot weighted selection folded into drawFrom, and synthetic
// virtual-winner ids decoded by ownerOf/tierOf.

/// @dev Minimal RaffleEngine stand-in: PackRegistry.drawFrom is onlyEngine, previewDraw reads
///      drawRound()/winnersPerDayAt() off the engine, and isRipXpClaimable reads openingDone().
contract MockEngine {
    uint256 public winnersPerDay;
    bool public openingDone = true;
    mapping(uint32 => uint64) public rounds;

    constructor(uint256 k) {
        winnersPerDay = k;
    }

    function setDrawRound(uint32 day, uint64 rr) external {
        rounds[day] = rr;
    }

    function drawRound(uint32 day) external view returns (uint64) {
        return rounds[day];
    }

    /// previewDraw reads the SCHEDULED winner count so it agrees with the draw it replays.
    /// The mock has no scheduling, so the live value IS the value in force for every period.
    function winnersPerDayAt(uint256) external view returns (uint256) {
        return winnersPerDay;
    }
}

contract VirtualEntryTest is Test {
    PackRegistry packs;
    MockDrandOracle oracle;
    MockNFT nft;
    MockEngine engine;

    address token = makeAddr("token"); // recorder
    address buyer = makeAddr("buyer");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18; // 1 paid pack per 10e18 of grossValue
    uint256 constant DAY = 1 days;
    uint256 constant FLAG = 1 << 255; // VIRTUAL_FLAG
    uint256 constant K = 100; // winnersPerDay

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        nft = new MockNFT(); // launched() defaults true
        engine = new MockEngine(K);
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        packs.setRecorder(token);
        packs.setEngine(address(engine));
        packs.setNft(address(nft));
        // A draw over a non-empty cohort reverts RevealPending until that cohort's tier round is posted.
        // Every paid pack in this suite is minted on day 0, so post cohort 0's round once, as the keeper would.
        oracle.setBeacon(oracle.roundAt(GENESIS + DAY + 1 hours), keccak256("reveal-c0"));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _paidBuy(uint256 gross) internal {
        vm.prank(token);
        packs.recordBuy(buyer, gross);
    }

    function _paidPacks(uint256 nPacks) internal {
        // maxTicketsPerBuy is 100; loop buys of 100 to reach nPacks
        while (nPacks > 0) {
            uint256 chunk = nPacks > 100 ? 100 : nPacks;
            _paidBuy(chunk * TICKET);
            nPacks -= chunk;
        }
    }

    function _warpToPledgeDay(uint32 drawDay) internal {
        vm.warp(GENESIS + uint256(drawDay) * DAY + 1); // _today() == drawDay
    }

    function _warpToDraw(uint32 drawDay) internal {
        vm.warp(GENESIS + (uint256(drawDay) + 1) * DAY + 1); // block.timestamp > freeze(drawDay)
    }

    function _draw(uint32 drawDay, bytes32 beacon, uint256 k) internal returns (uint256[] memory) {
        vm.prank(address(engine));
        return packs.drawFrom(beacon, drawDay, k);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _isVirtual(uint256 id) internal pure returns (bool) {
        return id & FLAG != 0;
    }

    function _countVirtual(uint256[] memory w) internal pure returns (uint256 n) {
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) ++n;
        }
    }

    // ── registerSuperRare ───────────────────────────────────────────────────────

    function test_registerSuperRare_indexesOnlySR() public {
        nft.set(1, buyer, 3); // Super Rare
        nft.set(2, buyer, 0); // Common
        nft.set(3, buyer, 3); // Super Rare
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 2; // non-SR — skipped
        ids[2] = 3;
        ids[3] = 1; // duplicate — skipped
        packs.registerSuperRare(ids);
        assertEq(packs.superRareCount(), 2, "only the two SR ids indexed");
        assertTrue(packs.srIndexed(1));
        assertTrue(packs.srIndexed(3));
        assertFalse(packs.srIndexed(2));
    }

    function test_registerSuperRare_idempotent() public {
        nft.set(1, buyer, 3);
        packs.registerSuperRare(_ids(1));
        packs.registerSuperRare(_ids(1)); // again — no-op
        assertEq(packs.superRareCount(), 1);
    }

    // ── pledge ──────────────────────────────────────────────────────────────────

    function test_pledge_countsDistinctAndRejectsSR() public {
        address alice = makeAddr("alice");
        nft.set(10, alice, 2); // Rare
        nft.set(11, alice, 3); // Super Rare
        _warpToPledgeDay(1);

        vm.prank(alice);
        packs.pledge(_ids(10));
        assertEq(packs.pledgeDistinct(1), 1, "one distinct pledger");

        vm.prank(alice);
        vm.expectRevert(PackRegistry.BadPledge.selector);
        packs.pledge(_ids(11)); // Super Rare cannot be pledged
    }

    function test_pledge_notOwnerReverts() public {
        address alice = makeAddr("alice");
        nft.set(10, alice, 1);
        _warpToPledgeDay(1);
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(PackRegistry.NotNftOwner.selector);
        packs.pledge(_ids(10));
    }

    function test_pledge_rePledgeByNewOwnerNoDoubleCount() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        nft.set(10, alice, 2); // Rare, weight 4
        _warpToPledgeDay(1);
        vm.prank(alice);
        packs.pledge(_ids(10));
        assertEq(packs.pledgeDistinct(1), 1);

        // alice sells to bob same day; bob re-pledges → overwrite, no new distinct/weight
        nft.set(10, bob, 2);
        vm.prank(bob);
        packs.pledge(_ids(10));
        assertEq(packs.pledgeDistinct(1), 1, "re-pledge does not double-count");
    }

    // ── drawFrom: Super Rare auto-entry ─────────────────────────────────────────

    function test_draw_superRareAutoWins_andDecodes() public {
        address sr = makeAddr("sr");
        _paidPacks(100); // cohort 0, 100 paid → cap = 10
        nft.set(1, sr, 3); // Super Rare, ownerSince = GENESIS
        packs.registerSuperRare(_ids(1));

        _warpToDraw(1);
        uint256[] memory w = _draw(1, keccak256("b"), K);

        uint256 v = _countVirtual(w);
        assertGt(v, 0, "at least one virtual (free) winner");

        // find a virtual winner and check the decode
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) {
                assertEq(packs.ownerOf(w[i]), sr, "virtual winner decodes to the SR holder");
                assertLt(packs.tierOf(w[i]), 4, "virtual tier in 0..3");
                vm.expectRevert(PackRegistry.VirtualId.selector);
                packs.rollOf(w[i]); // synthetic id has no on-chain roll
                break;
            }
        }
    }

    // ── multi-shot: one SR fills the whole 10% cap by repeats (holds ~9.09%) ─────

    function test_draw_multiShot_oneSRFillsCap() public {
        address sr = makeAddr("sr");
        _paidPacks(100); // cap = 10, total = 110 → free fraction ~9.09%
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));

        _warpToDraw(1);
        uint256[] memory w = _draw(1, keccak256("multishot"), K);
        uint256 v = _countVirtual(w);

        // MULTI-SHOT: vPool = cap = 10 even with a single eligible pass, so ~9 of 100 winners are free.
        // (1-shot would cap vPool at 1 eligible pass → ~1 free winner.) Assert clearly in the multi-shot band.
        assertGe(v, 5, "multi-shot fills the cap by repeats (would be ~1 under 1-shot)");
        // every free win is the same single SR holder (repeats)
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) assertEq(packs.ownerOf(w[i]), sr, "all free wins are the lone SR holder");
        }
    }

    // ── drawFrom: pledged Common/Uncommon/Rare win ──────────────────────────────

    function test_draw_pledgedPassWins() public {
        address alice = makeAddr("alice");
        _paidPacks(100);
        nft.set(10, alice, 2); // Rare
        _warpToPledgeDay(1);
        vm.prank(alice);
        packs.pledge(_ids(10));

        _warpToDraw(1);
        uint256[] memory w = _draw(1, keccak256("pledge"), K);
        uint256 v = _countVirtual(w);
        assertGt(v, 0, "the pledged pass wins free seats");
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) assertEq(packs.ownerOf(w[i]), alice, "free win decodes to the pledger");
        }
    }

    // ── freeze / opening: no virtual winners before the freeze instant ──────────

    function test_draw_beforeFreeze_paidOnly() public {
        address sr = makeAddr("sr");
        _paidPacks(100);
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));

        // draw drawDay=1 but at day 1 (block.timestamp <= freeze = GENESIS+2*DAY) → freeActive false
        vm.warp(GENESIS + DAY + 1);
        uint256[] memory w = _draw(1, keccak256("early"), K);
        assertEq(_countVirtual(w), 0, "no free winners before the freeze (opening sweep is paid-only)");
    }

    // ── dead day: no paid volume → cap 0 → no virtual, no revert ────────────────

    function test_draw_deadDay_noFreeNoRevert() public {
        address sr = makeAddr("sr");
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));
        _warpToDraw(1);
        uint256[] memory w = _draw(1, keccak256("dead"), K); // no paid packs at all
        assertEq(w.length, 0, "empty draw on a zero-ticket day, no revert");
    }

    // ── transfer voids a pledge (never rides to the buyer) ──────────────────────

    function test_draw_transferVoidsPledge() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _paidPacks(100);
        nft.set(10, alice, 2); // Rare
        _warpToPledgeDay(1);
        vm.prank(alice);
        packs.pledge(_ids(10));

        // alice sells to bob AFTER the freeze → ownerSince(10) > freeze → pledge is void, and bob is not SR
        _warpToDraw(1);
        nft.set(10, bob, 2); // ownerSince bumped to now (> freeze)
        uint256[] memory w = _draw(1, keccak256("void"), K);
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) assertTrue(false, "a transferred-out pledge must not win");
        }
    }

    // ── previewDraw == drawFrom (virtual subset) ────────────────────────────────

    function test_previewDraw_matchesDrawFrom() public {
        address sr = makeAddr("sr");
        address alice = makeAddr("alice");
        _paidPacks(80);
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));
        nft.set(10, alice, 2);
        _warpToPledgeDay(1);
        vm.prank(alice);
        packs.pledge(_ids(10));

        _warpToDraw(1);
        bytes32 beacon = keccak256("preview");
        uint64 rr = 4242;
        engine.setDrawRound(1, rr);
        oracle.setBeacon(rr, beacon);

        uint256[] memory pv = packs.previewDraw(1); // view, before the draw mutates state
        uint256[] memory w = _draw(1, beacon, K);

        // collect the virtual subset of the real draw, in order
        uint256 vCount = _countVirtual(w);
        assertEq(pv.length, vCount, "preview count == draw virtual count");
        uint256 j;
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) {
                assertEq(pv[j], w[i], "preview id matches draw id (same seat/tier/owner)");
                ++j;
            }
        }
    }

    // ── gas bound: K=200 draw with SR + a rejecting pledge field stays well under a block ──

    function test_gas_drawUnderBlock() public {
        // paid window
        _paidPacks(1000);
        // ~70 Super Rares
        uint256[] memory srIds = new uint256[](70);
        for (uint256 i; i < 70; ++i) {
            uint256 id = 1000 + i;
            nft.set(id, makeAddr(string(abi.encodePacked("sr", i))), 3);
            srIds[i] = id;
        }
        packs.registerSuperRare(srIds);
        // a pledge field, then transfer them all out so every pledge pick rejects (worst case)
        _warpToPledgeDay(1);
        for (uint256 i; i < 40; ++i) {
            uint256 id = 2000 + i;
            address a = makeAddr(string(abi.encodePacked("pl", i)));
            nft.set(id, a, 2); // Rare, weight 4
            vm.prank(a);
            packs.pledge(_ids(id));
        }

        _warpToDraw(1);
        // transfer every pledged pass out (after freeze) → all pledge picks reject → burns the reject budget
        for (uint256 i; i < 40; ++i) {
            nft.set(2000 + i, makeAddr("newowner"), 2);
        }

        vm.prank(address(engine));
        uint256 g0 = gasleft();
        packs.drawFrom(keccak256("gas"), 1, 200);
        uint256 used = g0 - gasleft();
        emit log_named_uint("drawFrom gas (K=200, 70 SR, rejecting pledges)", used);
        assertLt(used, 25_000_000, "draw fits comfortably in a 32M block");
    }

    // ── SECURITY FIX 1: SR draw set frozen per draw (srRegisteredAt <= freeze) ───
    // A registerSuperRare that lands AFTER a day's freeze (i.e. once that day's settling beacon is public)
    // must NOT enter that day's draw — otherwise an SR holder could read the beacon, then register to steer a
    // win. It DOES count from the next day, whose freeze now post-dates the registration.
    function test_lateSRRegistration_excludedThisDay_includedNext() public {
        address sr = makeAddr("sr");
        _paidPacks(300); // cohort 0 = 300 (survives day-1's pop of K=100, so day-2 still has paid volume)
        nft.set(1, sr, 3); // SR held since GENESIS (ownerSince <= every freeze)

        // register AFTER freeze(1) = GENESIS+2*DAY: srRegisteredAt[1] = GENESIS+2*DAY+1
        _warpToDraw(1);
        packs.registerSuperRare(_ids(1));

        // day 1: the SR is excluded (registered after the day-1 beacon is public)
        uint256[] memory w1 = _draw(1, keccak256("d1"), K);
        assertEq(_countVirtual(w1), 0, "SR registered after freeze(1) cannot win day 1");

        // day 2: the same SR is now eligible (srRegisteredAt <= freeze(2) = GENESIS+3*DAY)
        _warpToDraw(2);
        uint256[] memory w2 = _draw(2, keccak256("d2"), K);
        assertGt(_countVirtual(w2), 0, "the SR wins from the next day once its registration predates the freeze");
        for (uint256 i; i < w2.length; ++i) {
            if (_isVirtual(w2[i])) assertEq(packs.ownerOf(w2[i]), sr, "day-2 free win decodes to the SR holder");
        }
    }

    // ── SECURITY FIX 2: opening sweep is paid-only by construction, not by timing ─
    // drawFromPaidOnly must never fold the virtual free block, even when called past the freeze with an
    // otherwise-eligible SR present. The daily (free-enabled) drawFrom on the identical state DOES fold it,
    // proving the difference is the code path, not the clock.
    function test_paidOnlyDraw_neverFoldsFreeBlock_evenPastFreeze() public {
        address sr = makeAddr("sr");
        _paidPacks(100);
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1)); // eligible (registered before freeze)
        _warpToDraw(1); // past freeze(1): a free-enabled draw WOULD fold the free block here

        vm.prank(address(engine));
        uint256[] memory w = packs.drawFromPaidOnly(keccak256("open"), 1, K);
        assertEq(_countVirtual(w), 0, "paid-only draw excludes the free block regardless of timing");
        assertGt(w.length, 0, "paid winners are still drawn");
    }

    function test_freeEnabledDraw_doesFold_onSameState() public {
        address sr = makeAddr("sr");
        _paidPacks(100);
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));
        _warpToDraw(1);

        uint256[] memory w = _draw(1, keccak256("open"), K); // free-enabled path, identical setup
        assertGt(_countVirtual(w), 0, "the daily path DOES fold the free block; the only difference is the flag");
    }

    function test_paidOnlyDraw_onlyEngine() public {
        vm.expectRevert(PackRegistry.NotEngine.selector);
        packs.drawFromPaidOnly(keccak256("x"), 1, K); // caller is not the engine
    }

    // ── SECURITY FIX 3: VTIER keys on the FROZEN pass id + its per-draw win-index ─
    // Original hole (steering) is closed: VTIER is a pure function of (post-freeze beacon, day, tid, winIdx),
    // immutable under any post-beacon transfer / reshuffle. Regression guard: under multi-shot a lone pass
    // wins many seats, and each of those wins must roll an INDEPENDENT tier (winIdx = 0,1,2,...) rather than
    // all sharing one tier — otherwise a single SR roll could concentrate the whole SR bucket in a thin
    // market. Here the sole SR wins ~9 seats; the k-th win must equal _tierFromRoll(keccak(beacon,1,2,1,k)).
    function test_vtier_independentPerWin_notConcentrated() public {
        address sr = makeAddr("sr");
        _paidPacks(100); // cap 10, total 110, K=100 -> ~9 multi-shot wins, all tid=1
        nft.set(1, sr, 3);
        packs.registerSuperRare(_ids(1));
        _warpToDraw(1);

        bytes32 beacon = keccak256("vtier");
        uint256[] memory w = _draw(1, beacon, K);

        // virtual winners appear in seat order; with a single SR the k-th virtual winner is tid=1's k-th win,
        // so its winIdx == k. Each must match the per-(tid,winIdx) roll -> independent draws over 1/4/15/80.
        uint256 k;
        for (uint256 i; i < w.length; ++i) {
            if (_isVirtual(w[i])) {
                uint256 roll = uint256(keccak256(abi.encode(beacon, uint32(1), uint256(2), uint256(1), k))) % 10_000;
                uint8 expected = roll < 100 ? 3 : (roll < 500 ? 2 : (roll < 2000 ? 1 : 0));
                assertEq(packs.tierOf(w[i]), expected, "k-th win of tid=1 rolls its OWN independent VTIER (winIdx=k)");
                assertEq(packs.ownerOf(w[i]), sr, "still the SR holder");
                ++k;
            }
        }
        assertGt(k, 1, "multi-shot won multiple seats, so per-win independence is actually exercised");
    }
}

/// @dev Exposes the internal seat resolver so the pick ORDER and the shared-budget accounting can be asserted
///      directly. drawFrom only reveals the seated winners, so the harness exposes the per-seat pick itself.
contract PackRegistryHarness is PackRegistry {
    constructor(address drand_, uint256 ticketPrice_, uint256 genesis_, uint256 revealDelay_, address owner_)
        PackRegistry(drand_, ticketPrice_, genesis_, revealDelay_, owner_)
    { }

    function pickVirtual(bytes32 beacon, uint32 day, uint256 paidRemaining, uint256 seat)
        external
        view
        returns (uint256 tid)
    {
        FreeCfg memory cfg = _buildFreeCfg(day, paidRemaining, true);
        return _pickVirtual(beacon, day, cfg, seat);
    }

    function freeCfg(uint32 day, uint256 paidRemaining)
        external
        view
        returns (uint256 srCount, uint256 wb, uint256 vPool)
    {
        FreeCfg memory cfg = _buildFreeCfg(day, paidRemaining, true);
        return (cfg.srCount, cfg.wb, cfg.vPool);
    }

    /// Prune-cost measurement. This is EXACTLY the work an eager `wb` prune must do: walk pledgeList[day] and
    /// run the same validity predicate _pickVirtual applies lazily to the copies it actually rolls.
    /// Returns the surviving count so the compiler cannot optimise the loop away.
    function pruneWalk(uint32 day, uint256 freeze) external view returns (uint256 valid) {
        uint256[] storage pl = pledgeList[day];
        uint256 n = pl.length;
        for (uint256 i; i < n; ++i) {
            uint256 cand = pl[i];
            if (pledgerOf[cand][day] == _safeOwnerOf(cand) && nft.ownerSince(cand) <= freeze) {
                unchecked { ++valid; }
            }
        }
    }

    function notSeated() external pure returns (uint256) { return NOT_SEATED; }
}

// ── pledge flood: stale pledge copies vs the SR-first, one-roll seat pick ───────────────────────────────
// An owner pledges C/U/R passes and then transfers them away (no re-pledge): their weight-expanded copies stay
// in the append-only pledgeList as INVALID weight F, inflating the sampling region wb = 8s + Pv + F. Design:
// _pickVirtual resolves the Super Rare band FIRST, and a seat takes exactly ONE roll that
// is terminal in both bands, so an SR-band roll can never be voided or pre-empted and an invalid pledge copy
// voids its own seat instead of re-rolling. Per free seat, with q = (8*S_bad + F)/wb (here every SR is
// valid, so q = F/wb): P(SR) = 8s/wb, P(valid pledge) = Pv/wb, P(void) = q. These tests pin both the
// SR immunity and that per-seat law; every count below is deterministic in the fixed beacon.
// The harness samples _pickVirtual with an explicit seat nonce per sample, i.e. INDEPENDENT seats. That is only
// what the real drawFrom path does since the cascade fix (PledgeCascadeTest below): the fixture is shared.
abstract contract PledgeFloodBase is Test {
    PackRegistryHarness packs;
    MockDrandOracle oracle;
    MockNFT nft;
    MockEngine engine;

    address token = makeAddr("token");
    address buyer = makeAddr("buyer");
    address srHolder = makeAddr("srHolder");
    address honest = makeAddr("honest"); // valid pledger: pledges and keeps the passes
    address flooder = makeAddr("flooder"); // pledges, then transfers to `sybil` without a re-pledge
    address sybil = makeAddr("sybil");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days;
    uint256 constant FLAG = 1 << 255;
    uint256 constant K = 200;
    uint32 constant D = 1; // the draw day every test uses
    uint256 constant PAID = 1000; // paid window: cap = 100 so the free block is active
    uint256 constant SEATS = 1000; // seats sampled through the harness for the statistical bounds

    // token id layout: SR 1..9, honest Rares 10..99, flood Rares 100..
    uint256 constant SR_BASE = 1;
    uint256 constant HONEST_BASE = 10;
    uint256 constant FLOOD_BASE = 100;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        nft = new MockNFT();
        engine = new MockEngine(K);
        packs = new PackRegistryHarness(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        packs.setRecorder(token);
        packs.setEngine(address(engine));
        packs.setNft(address(nft));
        // paid window in cohort 0 (before day 1), so drawDay=1 has cap = PAID/10
        for (uint256 i; i < PAID / 100; ++i) {
            vm.prank(token);
            packs.recordBuy(buyer, 100 * TICKET);
        }
        // Post cohort 0's tier round so draws over it are allowed (as the keeper's reveal job does)
        oracle.setBeacon(oracle.roundAt(GENESIS + DAY + 1 hours), keccak256("reveal-c0"));
    }

    // ── scenario builders (all pledges happen on day D, before its freeze) ──────────────────────────────

    function _srs(uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.set(SR_BASE + i, srHolder, 3);
            ids[i] = SR_BASE + i;
        }
        packs.registerSuperRare(ids); // srRegisteredAt = now (GENESIS) <= freeze(D)
    }

    function _pledgeRares(address who, uint256 base, uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.set(base + i, who, 2); // Rare, weight 4
            ids[i] = base + i;
        }
        vm.prank(who);
        packs.pledge(ids);
    }

    /// @dev The flood: `n` Rares pledged by `flooder` on day D, then handed to `sybil` who never re-pledges, so
    ///      pledgerOf != ownerOf and every one of their 4n copies is invalid at the draw.
    function _flood(uint256 n) internal {
        _pledgeRares(flooder, FLOOD_BASE, n);
        for (uint256 i; i < n; ++i) nft.set(FLOOD_BASE + i, sybil, 2); // ownerSince unchanged (mock), pledger mismatch
    }

    function _warpToPledgeDay() internal {
        vm.warp(GENESIS + uint256(D) * DAY + 1);
    }

    function _warpToDraw() internal {
        vm.warp(GENESIS + (uint256(D) + 1) * DAY + 1); // > freeze(D)
    }

    function _isSR(uint256 tid) internal pure returns (bool) {
        return tid >= SR_BASE && tid < HONEST_BASE;
    }

    function _isHonest(uint256 tid) internal pure returns (bool) {
        return tid >= HONEST_BASE && tid < FLOOD_BASE;
    }

    function _isFlood(uint256 tid) internal pure returns (bool) {
        return tid >= FLOOD_BASE && tid != type(uint256).max;
    }

    /// @dev The seat's ONLY roll, recomputed exactly as _pickVirtual does (domain tag 1; there is no roll
    ///      index in the key, so a seat is keyed on (beacon, day, 1, seat) and nothing else).
    function _firstRoll(bytes32 beacon, uint256 seat, uint256 wb) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(beacon, D, uint256(1), seat))) % wb;
    }

    struct Tally {
        uint256 sr;
        uint256 honest;
        uint256 flood;
        uint256 void_;
    }

    function _tally(bytes32 beacon) internal view returns (Tally memory t) {
        for (uint256 seat; seat < SEATS; ++seat) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, seat);
            if (tid == packs.notSeated()) ++t.void_;
            else if (_isSR(tid)) ++t.sr;
            else if (_isHonest(tid)) ++t.honest;
            else ++t.flood;
        }
    }
}

contract PledgeFloodTest is PledgeFloodBase {
    // ── (1) a flood cannot stop SR seats being picked at their weight ─────────────────────────────────────

    // s=2 (16), Pv=16 (4 honest Rares), F=32 (8 flooded Rares): wb=64, q=0.5. ONE roll per seat, every outcome
    // terminal, so the law is the weights themselves: SR 16/64 = 25%, valid pledges 16/64 = 25%,
    // void 32/64 = 50%. An earlier version re-rolled on an invalid copy (void share q^6 = 1.6%), which left
    // the re-roll open to steering; one terminal roll closes that. The flood still seats NOTHING and gains NOTHING.
    function test_flood_srSeatsPickedAtWeight_halfInvalid() public {
        _srs(2);
        _warpToPledgeDay();
        _pledgeRares(honest, HONEST_BASE, 4);
        _flood(8);
        _warpToDraw();
        (uint256 srCount, uint256 wb,) = packs.freeCfg(D, PAID);
        assertEq(srCount, 2);
        assertEq(wb, 16 + 16 + 32, "wb counts the invalid copies (append-only list)");

        Tally memory t = _tally(keccak256("flood-half"));
        emit log_named_uint("q=0.5  SR seats / 1000 (law 250)", t.sr);
        emit log_named_uint("q=0.5  valid pledge seats / 1000 (law 250)", t.honest);
        emit log_named_uint("q=0.5  void seats / 1000 (law 500)", t.void_);
        assertEq(t.flood, 0, "a transferred-away pledge never seats");
        assertGe(t.sr, (SEATS * 20) / 100, "SR seated at its weight share, 25%");
        assertLe(t.sr, (SEATS * 30) / 100);
        assertGe(t.honest, (SEATS * 20) / 100, "valid pledges seated at their weight share, 25%");
        assertLe(t.honest, (SEATS * 30) / 100);
        uint256 diff = t.sr > t.honest ? t.sr - t.honest : t.honest - t.sr;
        assertLe(diff, (SEATS * 9) / 100, "8:4 ladder exact among seated seats (16 SR weight vs 16 valid pledge weight)");
        assertGe(t.void_, (SEATS * 44) / 100, "one terminal roll per seat: the void share is q, not q^6");
        assertLe(t.void_, (SEATS * 56) / 100);
    }

    // A heavy flood under the one-roll law: s=2 (16), Pv=0, F=144 (36 flooded Rares): wb=160, q=0.9.
    // SR keeps its weight share 16/160 = 10% and 90% of free seats void. A void pays nobody and is NOT
    // redirected: RaffleEngine._payWinners divides each tier bucket by its realized winners, so a voided seat
    // is shared among that bucket's survivors. The flood costs 36 real passes the flooder must own and pledge.
    function test_flood_bound_q90_srKeepsItsWeightShare() public {
        _srs(2);
        _warpToPledgeDay();
        _flood(36);
        _warpToDraw();
        (, uint256 wb,) = packs.freeCfg(D, PAID);
        assertEq(wb, 16 + 144);

        Tally memory t = _tally(keccak256("flood-heavy"));
        emit log_named_uint("q=0.9  SR seats / 1000 (law 100)", t.sr);
        emit log_named_uint("q=0.9  void seats / 1000 (law 900)", t.void_);
        assertEq(t.flood, 0);
        assertEq(t.honest, 0);
        assertGe(t.sr, (SEATS * 6) / 100, "SR keeps its 10% weight share even at q=0.9");
        assertLe(t.sr, (SEATS * 15) / 100);
        assertGe(t.void_, (SEATS * 85) / 100, "void share tracks q at q=0.9 (one terminal roll per seat)");
        assertEq(t.sr + t.void_, SEATS);
    }

    // ── (2) the SR band is resolved first, and an invalid pledge copy voids its own seat only ───────────

    // Every seat is decided by ONE roll. A roll in the SR band seats exactly the SR that band indexes; a roll
    // onto an invalid copy voids THAT seat and nothing else, and never seats the flooder.
    function test_flood_oneRollPerSeat_srBandFirst_invalidCopyVoids() public {
        _srs(2);
        _warpToPledgeDay();
        _flood(12); // F=48, wb=64: 25% of rolls land in the SR band
        _warpToDraw();
        (, uint256 wb,) = packs.freeCfg(D, PAID);
        assertEq(wb, 64);
        bytes32 beacon = keccak256("one-roll");

        uint256 srSeats;
        uint256 voids;
        for (uint256 seat; seat < 200; ++seat) {
            uint256 tid = packs.pickVirtual(beacon, D, PAID, seat);
            uint256 x0 = _firstRoll(beacon, seat, wb);
            if (x0 < 16) {
                assertEq(tid, SR_BASE + (x0 % 2), "SR-band roll seats the SR the band indexes");
                ++srSeats;
            } else {
                assertEq(tid, packs.notSeated(), "a roll onto an invalid copy voids the seat, terminally");
                ++voids;
            }
            assertFalse(_isFlood(tid), "invalid copies never seat");
        }
        assertGt(srSeats, 0);
        assertGt(voids, 0);
    }

    // SR-only region: no pledge copy exists, so no roll can ever void.
    function test_flood_srOnlyRegion_neverVoids() public {
        _srs(3);
        _warpToDraw();
        bytes32 beacon = keccak256("sr-only");
        for (uint256 seat; seat < 200; ++seat) {
            assertTrue(_isSR(packs.pickVirtual(beacon, D, PAID, seat)));
        }
    }

    // ── (3) valid pledges are still picked, end to end through drawFrom ──────────────────────────────────

    // 1 SR (8), 3 honest Rares (12), 5 flooded Rares (20): wb=40, q=0.5. The ~18 free seats of a K=200 draw
    // decode only to the SR holder or the honest pledger, never to the flooder or the sybil.
    function test_flood_fullDraw_validPledgesAndSRWin_floodNever() public {
        _srs(1);
        _warpToPledgeDay();
        _pledgeRares(honest, HONEST_BASE, 3);
        _flood(5);
        _warpToDraw();

        vm.prank(address(engine));
        uint256[] memory w = packs.drawFrom(keccak256("full-draw"), D, K);
        uint256 srWins;
        uint256 honestWins;
        for (uint256 i; i < w.length; ++i) {
            if (w[i] & FLAG == 0) continue;
            address o = packs.ownerOf(w[i]);
            assertTrue(o != flooder && o != sybil, "neither the flooder nor the sybil ever wins a free seat");
            if (o == srHolder) ++srWins;
            else if (o == honest) ++honestWins;
            else assertTrue(false, "unexpected free winner");
        }
        assertGt(srWins, 0, "the SR auto still wins under the flood");
        assertGt(honestWins, 0, "a valid pledge still wins under the flood");
        assertGt(w.length - srWins - honestWins, 0, "paid winners are untouched by the free block");
    }

    // ── (4) determinism: the same beacon yields the same winners ─────────────────────────────────────────

    function test_flood_deterministic_sameBeaconSameWinners() public {
        _srs(2);
        _warpToPledgeDay();
        _pledgeRares(honest, HONEST_BASE, 3);
        _flood(9);
        _warpToDraw();
        bytes32 beacon = keccak256("deterministic");
        engine.setDrawRound(D, 777);
        oracle.setBeacon(777, beacon);

        uint256[] memory p1 = packs.previewDraw(D);
        uint256[] memory p2 = packs.previewDraw(D);
        assertEq(p1.length, p2.length);
        for (uint256 i; i < p1.length; ++i) assertEq(p1[i], p2[i], "preview is a pure function of the beacon");
        assertGt(p1.length, 0);

        uint256 snap = vm.snapshotState();
        vm.prank(address(engine));
        uint256[] memory w1 = packs.drawFrom(beacon, D, K);
        vm.revertToState(snap);
        vm.prank(address(engine));
        uint256[] memory w2 = packs.drawFrom(beacon, D, K);
        assertEq(w1.length, w2.length);
        uint256 j;
        for (uint256 i; i < w1.length; ++i) {
            assertEq(w1[i], w2[i], "same beacon, same state: identical winners in identical order");
            if (w1[i] & FLAG != 0) {
                assertEq(w1[i], p1[j], "and the virtual subset equals the preview");
                ++j;
            }
        }
        assertEq(j, p1.length);
    }
}

// ── cascade fix: virtual seats are INDEPENDENT on the real draw path ──────────────────────────────────────
// An earlier drawFrom had a cascade: `seat` advanced only when a seat FILLED, so a voided seat was re-rolled
// with identical inputs against unchanged storage at every later virtual slot and voided again. ONE void
// ended the free block for the rest of the draw, so the real path did not follow the per-seat law the harness
// tests above measure (independent samples by construction). The fix advances `seat` on a void as
// well as on a fill, identically in _drawCore and _replayVirtual. Everything here runs through the REAL drawFrom
// / previewDraw path, never the harness's isolated _pickVirtual samples. Free SLOTS of a draw = K minus the paid
// winners (a paid hit always seats), so seated / slots is the realized free-block share.
contract PledgeCascadeTest is PledgeFloodBase {
    uint256 constant BEACONS = 40; // draws per bound test; ~18 free slots each, so ~700 slots per estimate

    /// @dev Bring up one flood scenario: `nSr` Super Rares, `nHonest` valid Rare pledges (weight 4 each) and
    ///      `nFlood` pledged-then-transferred Rares (invalid weight 4 each), then move past the freeze.
    function _scenario(uint256 nSr, uint256 nHonest, uint256 nFlood) internal returns (uint256 wb) {
        _srs(nSr);
        _warpToPledgeDay();
        if (nHonest > 0) _pledgeRares(honest, HONEST_BASE, nHonest);
        _flood(nFlood);
        _warpToDraw();
        (, wb,) = packs.freeCfg(D, PAID);
    }

    /// @dev One real drawFrom against the SAME frozen state (snapshot / revert), so every beacon is drawn from
    ///      identical storage and the draws are comparable.
    function _drawAt(bytes32 beacon) internal returns (uint256[] memory w) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(engine));
        w = packs.drawFrom(beacon, D, K);
        vm.revertToState(snap);
    }

    /// @dev (free slots, seated free winners) of a draw. PAID + cap (1100) > K, so all K slots run, and a
    ///      slot is either a paid win (always seated) or a virtual slot (seated or voided).
    function _slotStats(uint256[] memory w) internal pure returns (uint256 slots, uint256 seated) {
        for (uint256 i; i < w.length; ++i) {
            if (w[i] & FLAG != 0) ++seated;
        }
        slots = K - (w.length - seated);
    }

    /// @dev The virtual SLOT index a synthetic id was seated at (its uniqueness nonce, bits 168+).
    function _seatOf(uint256 vid) internal pure returns (uint256) {
        return (vid ^ FLAG) >> 168;
    }

    /// @dev Aggregate seated / slots over BEACONS real draws and pin it to the one-roll expectation (1 - q)
    ///      of the free slots, in bps, within `tolBps`. Also re-checks the flood never seats.
    function _assertSeatedShare(uint256 wb, uint256 expectBps, uint256 tolBps, string memory label) internal {
        uint256 slots;
        uint256 seated;
        for (uint256 b; b < BEACONS; ++b) {
            uint256[] memory w = _drawAt(keccak256(abi.encode("cascade", label, b)));
            (uint256 s, uint256 v) = _slotStats(w);
            slots += s;
            seated += v;
            for (uint256 i; i < w.length; ++i) {
                if (w[i] & FLAG == 0) continue;
                address o = packs.ownerOf(w[i]);
                assertTrue(o != flooder && o != sybil, "an invalid copy never seats on the real path either");
            }
        }
        uint256 gotBps = (seated * 10_000) / slots;
        emit log_named_uint(string(abi.encodePacked(label, " wb")), wb);
        emit log_named_uint(string(abi.encodePacked(label, " free slots over all draws")), slots);
        emit log_named_uint(string(abi.encodePacked(label, " seated bps (expect 1 - q)")), gotBps);
        emit log_named_uint(string(abi.encodePacked(label, " expected bps")), expectBps);
        assertGe(slots, 500, "enough free slots for the estimate to mean something");
        uint256 diff = gotBps > expectBps ? gotBps - expectBps : expectBps - gotBps;
        assertLe(diff, tolBps, "seated share of the free slots is (1 - q): one roll per seat, both bands terminal");
    }

    // ── (1) seated share of the free block is (1 - q) at q = 0.5 / 0.8 / 0.9 ──────────────────────────
    // Tolerances are ~3 sigma of a binomial at ~700 slots (sd ~189 bps at q=0.5, ~151 at q=0.8, ~113 at
    // q=0.9). Each sits far below the share the earlier re-roll law would have produced (98.4% / 73.8% /
    // 46.9%), so these bounds still tell the two laws apart, and far above the dead-block cascade (16% / 15%
    // / 4%) they were written to catch.

    // s=2 (16), Pv=16 (4 honest Rares), F=32 (8 flooded Rares): wb=64, q=0.5, seated 1-q = 50%.
    function test_cascade_seatedShare_q50() public {
        uint256 wb = _scenario(2, 4, 8);
        assertEq(wb, 64);
        _assertSeatedShare(wb, 5000, 600, "q=0.5");
    }

    // s=2 (16), Pv=16 (4 honest Rares), F=128 (32 flooded Rares): wb=160, q=0.8, seated 1-q = 20%.
    function test_cascade_seatedShare_q80() public {
        uint256 wb = _scenario(2, 4, 32);
        assertEq(wb, 160);
        _assertSeatedShare(wb, 2000, 500, "q=0.8");
    }

    // s=2 (16), Pv=0, F=144 (36 flooded Rares): wb=160, q=0.9, seated 1-q = 10% (all of it the SR band).
    function test_cascade_seatedShare_q90() public {
        uint256 wb = _scenario(2, 0, 36);
        assertEq(wb, 160);
        _assertSeatedShare(wb, 1000, 400, "q=0.9");
    }

    // ── (2) one void does not end the free block: later slots of the SAME draw still seat ──────────────
    // SR-only honest weight, so a slot voids iff its one roll lands in the flood region [16, 32). q=0.5 here,
    // not the 0.9 the share bounds use: the point of this test is that seats and voids INTERLEAVE, and at
    // q=0.9 a ~18-slot draw seats so rarely (p=0.1) that a beacon can spend its only seat before the first
    // void and prove nothing. At q=0.5 roughly half the slots seat, so seats land on both sides of it.
    // The test replays the slot walk and the per-slot roll exactly as _drawCore does, so the seated slot
    // indices (the ids' seat nonces) are pinned one by one, gaps included.
    function test_cascade_voidDoesNotEndFreeBlock() public {
        uint256 wb = _scenario(2, 0, 4); // s=2 (16), Pv=0, F=16: wb=32, q=0.5
        assertEq(wb, 32);
        bytes32 beacon = keccak256("one-void-is-one-seat");
        uint256[] memory w = _drawAt(beacon);

        // expected: walk the K slots, and for each virtual slot decide void / seat from its own single roll
        uint256 total = PAID + PAID / 10;
        uint256 paidRemaining = PAID;
        uint256 slot;
        uint256[] memory expectSeat = new uint256[](K);
        uint256 nExpect;
        uint256 firstVoid = type(uint256).max;
        for (uint256 j; j < K; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, D, j))) % total;
            if (r < paidRemaining) {
                --paidRemaining;
            } else {
                // SR-only honest region: the seat seats iff its one roll lands in the SR band [0, 16), and
                // voids otherwise. No re-roll, so this is the whole decision.
                bool seats = uint256(keccak256(abi.encode(beacon, D, uint256(1), slot))) % wb < 16;
                if (seats) expectSeat[nExpect++] = slot;
                else if (firstVoid == type(uint256).max) firstVoid = slot;
                ++slot;
            }
            --total;
        }
        assertTrue(firstVoid != type(uint256).max, "the fixture voids at least one slot (q=0.5)");
        assertGt(slot, firstVoid + 1, "and there are virtual slots after the first void to seat");

        // actual: every seated free winner carries its slot index; they must match the expectation exactly
        uint256 got;
        uint256 afterVoid;
        for (uint256 i; i < w.length; ++i) {
            if (w[i] & FLAG == 0) continue;
            uint256 s = _seatOf(w[i]);
            assertEq(s, expectSeat[got], "seated slot index matches the independent per-slot roll walk");
            assertEq(packs.ownerOf(w[i]), srHolder, "only the SR holder can seat in an SR-only honest region");
            if (s > firstVoid) ++afterVoid;
            ++got;
        }
        assertEq(got, nExpect, "every non-voiding slot seated, every voiding slot did not");
        assertGt(afterVoid, 0, "slots AFTER the first void still seat (pre-fix: exactly zero, the block was dead)");
        emit log_named_uint("virtual slots", slot);
        emit log_named_uint("first voided slot", firstVoid);
        emit log_named_uint("seated after the first void", afterVoid);
    }

    // ── (3) previewDraw == drawFrom across voids ──────────────────────────────────────────────────────
    function test_cascade_previewMatchesDrawAcrossVoids() public {
        _scenario(2, 0, 36); // q=0.9: voids are certain in ~18 slots
        bytes32 beacon = keccak256("preview-across-voids");
        engine.setDrawRound(D, 4141);
        oracle.setBeacon(4141, beacon);

        uint256[] memory pv = packs.previewDraw(D);
        uint256[] memory w = _drawAt(beacon);
        (uint256 slots, uint256 seated) = _slotStats(w);
        assertGt(slots - seated, 0, "the draw actually voided some slots, so the replay is exercised across them");
        assertGt(seated, 0);
        assertEq(pv.length, seated, "preview count == seated free winners");
        uint256 j;
        for (uint256 i; i < w.length; ++i) {
            if (w[i] & FLAG == 0) continue;
            assertEq(pv[j], w[i], "preview id == draw id (same slot nonce, VTIER, owner) across voided slots");
            ++j;
        }
        // the seat nonces are strictly increasing with at least one gap (a void), never reused
        uint256 prev = type(uint256).max;
        bool gap;
        for (uint256 i; i < pv.length; ++i) {
            uint256 s = _seatOf(pv[i]);
            if (prev != type(uint256).max) {
                assertGt(s, prev, "slot nonces strictly increase");
                if (s > prev + 1) gap = true;
            } else if (s > 0) {
                gap = true;
            }
            prev = s;
        }
        assertTrue(gap, "a voided slot leaves a gap in the nonces; the next slot rolled fresh and seated");
    }

    // ── (4) determinism: same beacon, same frozen state, same winners ─────────────────────────────────
    function test_cascade_deterministic_sameBeaconSameWinners() public {
        _scenario(2, 4, 32); // q=0.8
        bytes32 beacon = keccak256("cascade-deterministic");
        uint256[] memory w1 = _drawAt(beacon);
        uint256[] memory w2 = _drawAt(beacon);
        assertEq(w1.length, w2.length);
        for (uint256 i; i < w1.length; ++i) {
            assertEq(w1[i], w2[i], "winner selection is a pure function of the beacon and the frozen state");
        }
        (uint256 slots, uint256 seated) = _slotStats(w1);
        assertGt(seated, 0);
        assertLe(seated, slots);
        // a different beacon is a different draw (the nonce advance did not collapse the roll space)
        uint256[] memory w3 = _drawAt(keccak256("cascade-other"));
        bool differs = w3.length != w1.length;
        for (uint256 i; !differs && i < w1.length; ++i) differs = w1[i] != w3[i];
        assertTrue(differs, "another beacon draws other winners");
    }
}
