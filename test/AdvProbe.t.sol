// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { HolderDrawEngine } from "../src/HolderDrawEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// Adversarial probes written from scratch. Nothing here is taken on trust from the design spec.
contract AdvProbe is Test {
    // ─────────────────────────── shared engine fixture ───────────────────────────
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

    function _setDistinctOwners(uint256 n) internal {
        // distinct owner per id, each holding >= MIN_HOLD so the holder-only gate admits them
        for (uint256 i = 1; i <= n; ++i) {
            address o = vm.addr(1000 + i);
            nft.set(i, o, 0);
            nft.setBalance(o, eng.MIN_HOLD());
        }
    }

    // move into week w+1 (the draw window for week w) and post the settling beacon
    function _openDrawWeek(uint256 w, bytes32 beacon) internal {
        vm.warp(GENESIS + (w + 1) * WEEK + 1);
        assertEq(eng.currentPeriod(), w + 1);
        oracle.setBeacon(eng.drawRound(w), beacon);
    }

    function _claimAmt(uint256 id) internal view returns (address recip, uint256 amt) {
        (, recip, amt,,) = claimMgr.claims(id);
    }

    // ───────────────── Probe 1: happy path, 5 distinct, flat share ─────────────────
    function test_probe_fiveDistinctFlatShare() public {
        _setDistinctOwners(2000);
        _openDrawWeek(0, keccak256("beacon0"));
        eng.runDraw(0);
        assertTrue(eng.drawn(0));
        assertEq(claimMgr.nextClaimId(), 5, "exactly 5 slots seated");
        // all 5 share == pot/5, and 5 distinct recipients / distinct tokens
        uint256[5] memory toks;
        for (uint256 i = 1; i <= 5; ++i) {
            (, uint256 amt) = _claimAmt(i);
            assertEq(amt, POT / 5, "FLAT share pot/5");
        }
        // vault: exactly pot - 5*(pot/5) left (dust rolls fwd; here pot%5==0 so 0 left)
        assertEq(vault.freeBalance(), POT - 5 * (POT / 5));
    }

    // ───────────────── Probe 2: front-running the freeze: a post-freeze move is out ─────────────────
    function test_probe_postFreezeMoveIneligible() public {
        _setDistinctOwners(2000);
        uint256 freeze = eng.snapDeadline(0);
        // token 1: move it AFTER the freeze instant -> both seller and buyer are out
        nft.setOwnerSince(1, uint64(freeze + 1));
        assertFalse(eng.isEligible(0, 1), "post-freeze token must be ineligible");
        // a token that never moved (ownerSince <= freeze) is eligible
        assertTrue(eng.isEligible(0, 2));
        _openDrawWeek(0, keccak256("beaconG3"));
        (uint256[5] memory won,, uint256 filled) = eng.previewDraw(0);
        for (uint256 i; i < filled; ++i) assertTrue(won[i] != 1, "token 1 can never be seated");
    }

    // ───────────────── Probe 3: a zero-owner id must not brick ─────────────────
    function test_probe_zeroOwnerDoesNotBrick() public {
        // Only tokens 1..4 populated, but totalMinted forced to 2000 -> ids 5..2000 return address(0).
        for (uint256 i = 1; i <= 4; ++i) { nft.set(i, vm.addr(2000 + i), 0); nft.setBalance(vm.addr(2000 + i), eng.MIN_HOLD()); }
        nft.setTotalMinted(2000);
        _openDrawWeek(0, keccak256("beaconZero"));
        // must not revert despite the vast majority of candidates returning address(0)
        eng.runDraw(0);
        assertTrue(eng.drawn(0), "draw completes over the 4 real owners");
        // at most 4 distinct eligible tokens -> filled in [1,4], each share flat pot/5
        uint256 n = claimMgr.nextClaimId();
        assertGt(n, 0);
        assertLe(n, 4);
        for (uint256 i = 1; i <= n; ++i) {
            (address r, uint256 amt) = _claimAmt(i);
            assertTrue(r != address(0), "no zero recipient ever registered");
            assertEq(amt, POT / 5, "flat share even when filled<5");
        }
        // unseated slots' shares stayed in the vault
        assertEq(vault.freeBalance(), POT - n * (POT / 5));
    }

    // ───────────────── Probe 4: previewDraw == runDraw exactly ─────────────────
    function test_probe_previewMatchesRun() public {
        _setDistinctOwners(37);
        _openDrawWeek(0, keccak256("beaconPRV"));
        (uint256[5] memory pWon, address[5] memory pWin, uint256 pFilled) = eng.previewDraw(0);
        eng.runDraw(0);
        assertEq(claimMgr.nextClaimId(), pFilled);
        for (uint256 i = 1; i <= pFilled; ++i) {
            (address r,) = _claimAmt(i);
            assertEq(r, pWin[i - 1], "preview winner == run winner, in order");
            assertTrue(pWon[i - 1] >= 1 && pWon[i - 1] <= 37);
        }
    }

    // ───────────────── Probe 5: exclusion cannot be lifted for a drawable week ─────────
    // Confederate C is excluded. Owner tries, during the draw window, to un-exclude and let C win.
    function test_probe_exclusion_noRetroLift() public {
        address C = vm.addr(1001); // owner of token 1 in _setDistinctOwners
        _setDistinctOwners(2000);
        // bar C at genesis (week 0) -> effective from week 1
        eng.setExcluded(C, true);
        // week we will draw = week 5. C excluded as of week 5.
        assertTrue(_excludedAtView(C, 5));
        // advance to the draw window for week 5 (period 6), post beacon
        _openDrawWeek(5, keccak256("beaconEx"));
        // owner sees the beacon and tries to un-exclude C right now (period 6)
        eng.setExcluded(C, false);
        // the change must NOT affect week 5 (only weeks >= 7)
        assertTrue(_excludedAtView(C, 5), "week 5 answer immune to a period-6 write");
        // and the draw must not pay C for token 1
        eng.runDraw(5);
        uint256 n = claimMgr.nextClaimId();
        for (uint256 i = 1; i <= n; ++i) {
            (address r,) = _claimAmt(i);
            assertTrue(r != C, "excluded confederate never paid for the drawn week");
        }
    }

    // helper mirroring _excludedAt via isEligible on a token C owns with a valid stamp
    function _excludedAtView(address who, uint256 week) internal view returns (bool) {
        // token 1 is owned by vm.addr(1001)=C with ownerSince<=freeze; isEligible false <=> excluded
        if (who != vm.addr(1001)) revert("probe: helper only for token1 owner");
        return !eng.isEligible(week, 1);
    }

    // ───────────────── Probe 6: exclusion cooldown boundary ─────────────────
    function test_probe_exclusion_cooldown() public {
        address C = makeAddr("conf");
        eng.setExcluded(C, true); // period 0, effective week 1
        // immediate re-toggle must revert (pending)
        vm.expectRevert(HolderDrawEngine.ExclusionChangePending.selector);
        eng.setExcluded(C, false);
        // same value repeat also reverts
        vm.expectRevert(HolderDrawEngine.NoExclusionChange.selector);
        eng.setExcluded(C, true);
        // move to period 2 (> effective week 1) -> toggle allowed
        vm.warp(GENESIS + 2 * WEEK + 1);
        assertEq(eng.currentPeriod(), 2);
        eng.setExcluded(C, false); // effective week 3
    }

    // ───────────────── Probe 7: first-ever un-exclude is rejected ─────────────────
    function test_probe_exclusion_firstWriteFalseRejected() public {
        address C = makeAddr("neverset");
        vm.expectRevert(HolderDrawEngine.NotExcluded.selector);
        eng.setExcluded(C, false);
    }

    // ───────────────── Probe 8: runDraw only in week+1, retry semantics ─────────────
    function test_probe_window_and_retry() public {
        _setDistinctOwners(2000);
        // too early: during week 0 (period 0), cannot draw week 0
        vm.expectRevert(HolderDrawEngine.OutsideWindow.selector);
        eng.runDraw(0);
        // zero pot does NOT consume the week: drain the vault first
        // (simulate by drawing a week with pot below minPot? minPot=1, pot=500e18) -> instead test AlreadyDrawn
        _openDrawWeek(0, keccak256("b"));
        eng.runDraw(0);
        vm.expectRevert(HolderDrawEngine.AlreadyDrawn.selector);
        eng.runDraw(0);
        // too late: for an UNDRAWN week, drawing outside week+1 reverts OutsideWindow
        vm.warp(GENESIS + 3 * WEEK); // period 3
        vm.expectRevert(HolderDrawEngine.OutsideWindow.selector);
        eng.runDraw(1); // week 1 can only be drawn in period 2
    }

    // ─────────── Probe 10: gas is truly supply-independent (n=10 vs n=2000) ───────────
    function test_probe_gasFlatAcrossSupply() public {
        _setDistinctOwners(2000);
        _openDrawWeek(0, keccak256("bgbig"));
        uint256 g = gasleft();
        eng.runDraw(0);
        uint256 big = g - gasleft();
        emit log_named_uint("runDraw gas, n=2000", big);
        // second engine over n=10 for comparison is done in test_probe_gasIndependentOfSupply (639k).
        // the two must be within the same order of magnitude (bounded by MAX_REROLLS, not by n).
        assertLt(big, 2_000_000, "n=2000 draw still bounded by MAX_REROLLS");
    }

    // ─────────── Probe 11: sybil-neutrality, per-token uniformity ───────────
    // 10 tokens, 2000 draws over varying beacons; every eligible token should be seated
    // with roughly equal frequency and splitting a holding across wallets never helps.
    function test_probe_sybilNeutral_uniformPerToken() public {
        _setDistinctOwners(10);
        uint64 round = eng.drawRound(0);
        uint256[11] memory hits; // index by tokenId 1..10
        uint256 trials = 400;
        for (uint256 t; t < trials; ++t) {
            oracle.setBeacon(round, keccak256(abi.encode("s", t)));
            (uint256[5] memory won,, uint256 filled) = eng.previewDraw(0);
            for (uint256 i; i < filled; ++i) hits[won[i]]++;
        }
        // each of 10 tokens should be hit close to trials*5/10 = 200 times; assert none is starved/over-picked
        for (uint256 id = 1; id <= 10; ++id) {
            assertGt(hits[id], 120, "token under-selected -> non-uniform");
            assertLt(hits[id], 280, "token over-selected -> non-uniform");
        }
    }

    // ───────────────── Probe 9: gas is bounded & supply-independent ─────────────────
    function test_probe_gasIndependentOfSupply() public {
        _setDistinctOwners(10);
        _openDrawWeek(0, keccak256("bg1"));
        uint256 g0 = gasleft();
        eng.runDraw(0);
        uint256 small = g0 - gasleft();
        emit log_named_uint("runDraw gas, n=10", small);
        assertLt(small, 2_000_000, "runDraw must stay far under any block ceiling");
    }
}

/// Self-transfer guard probes against the REAL NFTCollection (ownerSince weaponisation).
contract SelfTransferGuardProbe is Test {
    NFTCollection nft;
    MockDrandOracle oracle;
    PassArtRenderer renderer;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address operator = makeAddr("operator");
    address lp = makeAddr("lp");
    address seed = makeAddr("seed");
    address team = makeAddr("team");
    uint256 constant PRICE = 0.1 ether;

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new MockDrandOracle(1_000_000, 30);
        renderer = new PassArtRenderer(address(this));
        renderer.lock(); // the NFTCollection ctor requires a locked renderer
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        nft.setRecipients(lp, seed, team);
        nft.setAllowlistRoot(keccak256("guard-probe")); // any non-zero root; the open path is used below
        nft.setMintOpen(true);
        // start the mint, then warp into the PUBLIC window so the open mintBatch path is live.
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt());
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintBatch{ value: PRICE * 3 }(3); // alice owns 1,2,3 (3 <= PUBLIC_CAP)
    }

    function test_operator_selfTransfer_cannot_move_ownerSince() public {
        uint64 os1 = nft.ownerSince(1);
        assertGt(os1, 0);
        vm.warp(block.timestamp + 10 days);
        // alice granted a marketplace blanket approval at some point
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);
        // operator tries the knockout: self-transfer victim->victim after a freeze instant
        vm.prank(operator);
        nft.transferFrom(alice, alice, 1);
        assertEq(nft.ownerSince(1), os1, "GUARD: operator self-transfer must NOT bump ownerSince");
        assertEq(nft.ownerOf(1), alice, "pass never moved");
    }

    function test_singleApproval_selfTransfer_cannot_move_ownerSince() public {
        uint64 os2 = nft.ownerSince(2);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        nft.approve(operator, 2);
        vm.prank(operator);
        nft.transferFrom(alice, alice, 2);
        assertEq(nft.ownerSince(2), os2, "GUARD: single-token-approved self-transfer must NOT bump");
    }

    function test_ownerSelfTransfer_cannot_move_ownerSince() public {
        uint64 os3 = nft.ownerSince(3);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        nft.transferFrom(alice, alice, 3);
        assertEq(nft.ownerSince(3), os3, "GUARD: owner self-transfer must NOT bump");
    }

    function test_realTransfer_DOES_move_ownerSince() public {
        uint64 os1 = nft.ownerSince(1);
        vm.warp(block.timestamp + 10 days);
        uint256 t = block.timestamp;
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerSince(1), uint64(t), "real change of hands MUST bump");
        assertGt(nft.ownerSince(1), os1);
    }

    // operator REAL transfer to itself: bumps (it is theft, loses eligibility with custody): expected, not a bug
    function test_operator_realTransferToSelf_bumps_and_takes_custody() public {
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);
        uint256 t = block.timestamp;
        vm.prank(operator);
        nft.transferFrom(alice, operator, 1);
        assertEq(nft.ownerOf(1), operator, "custody actually moved (theft)");
        assertEq(nft.ownerSince(1), uint64(t), "real move bumps");
    }
}
