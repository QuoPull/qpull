// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockRevertOnAmountERC20 } from "./mocks/MockRevertOnAmountERC20.sol";

/// @notice Focused coverage for the pull-claim primitives — especially claimBatch (the "claim all" path).
contract ClaimManagerTest is Test {
    ClaimManager claimMgr;
    BaseVault vault;
    MockERC20 quotron;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant FUND = 1000e18;
    uint256 constant SHARE = 10e18;
    uint64 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        deadline = uint64(block.timestamp + 30 days);
        quotron = new MockERC20();
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        vault.setController(address(claimMgr));
        claimMgr.setEngine(address(this), address(vault)); // this contract is the "engine" bound to `vault`
        quotron.mint(address(vault), FUND);
    }

    function _register(address who, uint256 amt) internal returns (uint256 id) {
        id = claimMgr.registerClaim(address(vault), who, amt, deadline);
    }

    // Register n claims to `who`, return their ids.
    function _registerMany(address who, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _register(who, SHARE);
        }
    }

    // ─── an engine is bound to exactly one vault and cannot touch another ────────────

    function test_engineCannotRegisterAgainstAnotherVault() public {
        // a SECOND vault, also controlled by this ClaimManager, that `this` engine is NOT bound to
        BaseVault other = new BaseVault(address(quotron), address(this));
        other.setController(address(claimMgr));
        quotron.mint(address(other), FUND);

        // registering against our own bound vault works...
        _register(alice, SHARE);
        // ...but registering against the OTHER vault reverts, even though we are an authorized engine.
        vm.expectRevert(ClaimManager.WrongVault.selector);
        claimMgr.registerClaim(address(other), alice, SHARE, deadline);
    }

    function test_unboundCallerIsNotEngine() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ClaimManager.NotEngine.selector);
        claimMgr.registerClaim(address(vault), alice, SHARE, deadline);
    }

    function test_deauthorizeByBindingToZero() public {
        claimMgr.setEngine(address(this), address(0)); // de-authorize
        vm.expectRevert(ClaimManager.NotEngine.selector);
        claimMgr.registerClaim(address(vault), alice, SHARE, deadline);
    }

    // ─── lockEngines cross-checks each engine's OWN vault() ──────────────────────

    /// The declaration and `engineVault` are both written by the same owner call, so a transposed wiring
    /// agrees with itself perfectly and used to freeze forever. Every registerClaim from that engine then
    /// reverts WrongVault against the vault it actually pays from: the game silently pays nobody, with no
    /// way back. Ask the engine instead.
    function test_lockEnginesRefusesATransposedBinding() public {
        BaseVault other = new BaseVault(address(quotron), address(this));
        other.setController(address(claimMgr));
        StubEngine engine = new StubEngine(address(vault)); // the engine really pays from `vault`
        claimMgr.setEngine(address(engine), address(other)); // ...but it is declared against `other`

        address[] memory e = new address[](2);
        address[] memory v = new address[](2);
        (e[0], e[1]) = (address(this), address(engine));
        (v[0], v[1]) = (address(vault), address(other));
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimManager.BindingMismatch.selector, address(engine), address(vault), address(other)
            )
        );
        claimMgr.lockEngines(e, v);

        // declare it against the vault it actually holds and the same list locks
        claimMgr.setEngine(address(engine), address(vault));
        (v[0], v[1]) = (address(vault), address(vault));
        claimMgr.lockEngines(e, v);
        assertTrue(claimMgr.enginesLocked(), "the corrected map locks normally");
    }

    /// An address that cannot answer `vault()` must not become un-lockable: a plain address returns
    /// (success, empty) and a contract without the getter reverts inside the call. Both skip the
    /// cross-check rather than reverting lockEngines, which a typed call would have done uncatchably.
    function test_addressesThatCannotAnswerAreStillLockable() public {
        address eoa = makeAddr("plain address, no code");
        claimMgr.setEngine(eoa, address(vault));
        address[] memory e = new address[](2);
        address[] memory v = new address[](2);
        (e[0], e[1]) = (address(this), eoa); // `this` is a contract with no vault() getter
        (v[0], v[1]) = (address(vault), address(vault));
        claimMgr.lockEngines(e, v); // MUST NOT revert
        assertTrue(claimMgr.enginesLocked());
    }

    // ─── lockEngines() freezes the engine<->vault bindings forever ──────────

    function test_lockEnginesFreezesSetEngine() public {
        // de-auth still works BEFORE the lock (the de-authorize emergency lever is preserved during wiring)
        claimMgr.setEngine(makeAddr("tmp"), address(vault));
        claimMgr.setEngine(makeAddr("tmp"), address(0));

        address[] memory e1 = new address[](1);
        address[] memory v1 = new address[](1);
        e1[0] = address(this);
        v1[0] = address(vault);
        claimMgr.lockEngines(e1, v1);
        assertTrue(claimMgr.enginesLocked(), "locked");

        // after the lock, no rebind (the compromised-owner drain vector) and no de-auth are possible
        vm.expectRevert(ClaimManager.EnginesAlreadyLocked.selector);
        claimMgr.setEngine(makeAddr("attacker"), address(vault));
        vm.expectRevert(ClaimManager.EnginesAlreadyLocked.selector);
        claimMgr.setEngine(address(this), address(0));
    }

    function test_lockEnginesOnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        claimMgr.lockEngines(new address[](0), new address[](0));
    }

    // lockEngines refuses to freeze an incomplete/mismatched binding set.
    function test_lockEnginesRejectsIncompleteBindings() public {
        address[] memory e = new address[](1);
        address[] memory v = new address[](1);
        e[0] = makeAddr("unbound"); // never bound to anything
        v[0] = address(vault);
        vm.expectRevert(ClaimManager.IncompleteBindings.selector);
        claimMgr.lockEngines(e, v);
        assertFalse(claimMgr.enginesLocked(), "not locked on a bad set");
    }

    function test_boundEngineStillWorksAfterLock() public {
        // the legitimately-bound engine (this contract, bound in setUp) keeps functioning post-lock
        address[] memory e2 = new address[](1);
        address[] memory v2 = new address[](1);
        e2[0] = address(this);
        v2[0] = address(vault);
        claimMgr.lockEngines(e2, v2);
        uint256 id = _register(alice, SHARE);
        vm.prank(alice);
        claimMgr.claim(id);
        assertEq(quotron.balanceOf(alice), SHARE, "bound engine still pays after lock");
    }

    function test_claimBatch_paysAllCallerClaimsInOneTx() public {
        uint256[] memory ids = _registerMany(alice, 5);
        assertEq(vault.unclaimedReserve(), 5 * SHARE, "5 prizes reserved");

        vm.prank(alice);
        uint256 claimed = claimMgr.claimBatch(ids);

        assertEq(claimed, 5, "all 5 paid");
        assertEq(quotron.balanceOf(alice), 5 * SHARE, "alice received the full batch");
        assertEq(vault.unclaimedReserve(), 0, "reserve fully released");
        for (uint256 i; i < ids.length; ++i) {
            (,,,, bool settled) = claimMgr.claims(ids[i]);
            assertTrue(settled, "each id settled");
        }
    }

    function test_claimBatch_skipsSettledAndDoubleClaim() public {
        uint256[] memory ids = _registerMany(alice, 3);

        // Claim one individually first, then batch all three — the already-settled one is skipped.
        vm.prank(alice);
        claimMgr.claim(ids[0]);

        vm.prank(alice);
        uint256 claimed = claimMgr.claimBatch(ids);
        assertEq(claimed, 2, "only the two still-open ids paid");
        assertEq(quotron.balanceOf(alice), 3 * SHARE, "alice paid exactly once per prize");

        // Re-running the batch pays nothing (all settled) and does not revert.
        vm.prank(alice);
        assertEq(claimMgr.claimBatch(ids), 0, "idempotent: nothing left to claim");
    }

    function test_claimBatch_skipsExpired() public {
        uint256[] memory ids = _registerMany(alice, 2);
        vm.warp(uint256(deadline) + 1); // both windows closed

        vm.prank(alice);
        uint256 claimed = claimMgr.claimBatch(ids);
        assertEq(claimed, 0, "expired prizes are skipped, not reverted");
        assertEq(quotron.balanceOf(alice), 0, "nothing paid");
    }

    function test_claimBatch_neverPaysOthersClaims() public {
        uint256 aliceId = _register(alice, SHARE);
        uint256 bobId = _register(bob, SHARE);

        uint256[] memory mixed = new uint256[](2);
        mixed[0] = aliceId;
        mixed[1] = bobId; // alice tries to include bob's id

        vm.prank(alice);
        uint256 claimed = claimMgr.claimBatch(mixed);

        assertEq(claimed, 1, "only alice's own id paid");
        assertEq(quotron.balanceOf(alice), SHARE, "alice paid her share");
        assertEq(quotron.balanceOf(bob), 0, "bob's prize untouched by alice's batch");
        (,,,, bool bobSettled) = claimMgr.claims(bobId);
        assertFalse(bobSettled, "bob's claim still open for bob to claim himself");
    }

    // a single reverting payout must NOT abort the whole batch. The reverting claim is
    // left unsettled + still reserved (retryable once unblocked); every other claim in the batch still pays.
    function test_claimBatchSkipsRevertingPayoutButPaysRest() public {
        MockRevertOnAmountERC20 pz = new MockRevertOnAmountERC20();
        BaseVault pv = new BaseVault(address(pz), address(this));
        ClaimManager cm = new ClaimManager(address(this));
        pv.setController(address(cm));
        cm.setEngine(address(this), address(pv));
        pz.mint(address(pv), FUND);

        uint256 POISON = 7e18;
        uint256 g1 = cm.registerClaim(address(pv), alice, SHARE, deadline); // pays
        uint256 bad = cm.registerClaim(address(pv), alice, POISON, deadline); // payout reverts
        uint256 g2 = cm.registerClaim(address(pv), alice, SHARE, deadline); // pays

        pz.setPoison(POISON); // transfers of exactly POISON now revert (stands in for a blacklisted payout)

        uint256[] memory batch = new uint256[](3);
        batch[0] = g1;
        batch[1] = bad;
        batch[2] = g2;

        vm.prank(alice);
        uint256 claimed = cm.claimBatch(batch); // must NOT revert despite the middle payout failing

        assertEq(claimed, 2, "the two good claims paid, the reverting one skipped");
        assertEq(pz.balanceOf(alice), 2 * SHARE, "alice received both good payouts");

        // the reverting claim rolled back cleanly: unsettled AND still reserved for a retry
        (,,,, bool badSettled) = cm.claims(bad);
        assertFalse(badSettled, "reverting claim stays unsettled");
        assertEq(pv.unclaimedReserve(), POISON, "its prize stays reserved, not lost");

        // once the block clears, the stranded claim settles and pays on a plain retry
        pz.setPoison(0);
        vm.prank(alice);
        cm.claim(bad);
        assertEq(pz.balanceOf(alice), 2 * SHARE + POISON, "reverting claim paid on retry");
        assertEq(pv.unclaimedReserve(), 0, "reserve cleared after the retry");
    }

    function test_claimBatch_mixedGoodAndBad() public {
        // ids: [alice-open, alice-settled, bob-open, alice-expiresLater-open]
        uint256 a1 = _register(alice, SHARE);
        uint256 a2 = _register(alice, SHARE);
        uint256 bobId = _register(bob, SHARE);
        uint256 a3 = _register(alice, SHARE);

        vm.prank(alice);
        claimMgr.claim(a2); // pre-settle a2

        uint256[] memory batch = new uint256[](5);
        batch[0] = a1;
        batch[1] = a2; // settled -> skip
        batch[2] = bobId; // not alice -> skip
        batch[3] = a3;
        batch[4] = 9999; // nonexistent -> recipient == address(0) -> skip

        vm.prank(alice);
        uint256 claimed = claimMgr.claimBatch(batch);
        assertEq(claimed, 2, "only a1 and a3 paid");
        assertEq(quotron.balanceOf(alice), 3 * SHARE, "a1 + a2(earlier) + a3");
    }

    // ─── lockEngines must be handed the WHOLE bound set. A bound engine left off the list used to
    //     be invisible to the check, so the lock froze a map nobody had verified in full. ────────────────────

    function _pair(address e0, address v0) internal pure returns (address[] memory e, address[] memory v) {
        e = new address[](1);
        v = new address[](1);
        e[0] = e0;
        v[0] = v0;
    }

    function test_engineCount_tracksBindRebindDeauth() public {
        assertEq(claimMgr.engineCount(), 1, "setUp bound `this`");
        address e2 = makeAddr("e2");
        claimMgr.setEngine(e2, address(vault));
        assertEq(claimMgr.engineCount(), 2, "a fresh bind increments");

        BaseVault other = new BaseVault(address(quotron), address(this));
        claimMgr.setEngine(e2, address(other)); // bound -> bound rebind
        assertEq(claimMgr.engineCount(), 2, "a rebind is neutral");

        claimMgr.setEngine(e2, address(0)); // de-authorize
        assertEq(claimMgr.engineCount(), 1, "a de-auth decrements");
        claimMgr.setEngine(e2, address(0)); // de-auth of an already-unbound engine
        assertEq(claimMgr.engineCount(), 1, "a no-op de-auth stays neutral");
    }

    /// address(0) is never a valid engine key. Binding it used to count toward engineCount, so a
    /// lockEngines list could carry a phantom (0, vault) pair in place of a real engine and still "match".
    function test_setEngine_rejectsZeroEngine() public {
        vm.expectRevert(ClaimManager.ZeroEngine.selector);
        claimMgr.setEngine(address(0), address(vault)); // bind
        vm.expectRevert(ClaimManager.ZeroEngine.selector);
        claimMgr.setEngine(address(0), address(0)); // "de-auth" of the zero key is refused too
        assertEq(claimMgr.engineCount(), 1, "the zero key never padded the count");
        assertEq(claimMgr.engineVault(address(0)), address(0), "zero key stays unbound");
        // a phantom (0, vault) pair can therefore never stand in for a real engine in the lock list
        (address[] memory e, address[] memory v) = _pair(address(0), address(vault));
        vm.expectRevert(ClaimManager.IncompleteBindings.selector);
        claimMgr.lockEngines(e, v);
        assertFalse(claimMgr.enginesLocked(), "not locked on a phantom pair");
    }

    function test_lockEngines_rejectsListOmittingBoundEngine() public {
        claimMgr.setEngine(makeAddr("e2"), address(vault)); // two engines bound now: this + e2
        (address[] memory e, address[] memory v) = _pair(address(this), address(vault)); // e2 omitted
        vm.expectRevert(ClaimManager.IncompleteBindings.selector);
        claimMgr.lockEngines(e, v); // the old check verified only this pair and would have frozen the map
        assertFalse(claimMgr.enginesLocked(), "not locked on an incomplete list");
    }

    function test_lockEngines_rejectsDuplicatePaddedList() public {
        claimMgr.setEngine(makeAddr("e2"), address(vault)); // engineCount == 2
        address[] memory e = new address[](2);
        address[] memory v = new address[](2);
        e[0] = address(this);
        v[0] = address(vault);
        e[1] = address(this); // the duplicate pads the length to engineCount while e2 is still missing
        v[1] = address(vault);
        vm.expectRevert(ClaimManager.IncompleteBindings.selector);
        claimMgr.lockEngines(e, v);
        assertFalse(claimMgr.enginesLocked(), "a duplicate cannot stand in for a missing engine");
    }

    function test_lockEngines_completeListSucceedsInAnyOrder() public {
        address e2 = makeAddr("e2");
        BaseVault other = new BaseVault(address(quotron), address(this));
        claimMgr.setEngine(e2, address(other));
        address[] memory e = new address[](2);
        address[] memory v = new address[](2);
        e[0] = e2; // listed in a different order than bound
        v[0] = address(other);
        e[1] = address(this);
        v[1] = address(vault);
        claimMgr.lockEngines(e, v);
        assertTrue(claimMgr.enginesLocked(), "the exact bound set locks");
    }

    function test_lockEngines_deauthedEngineIsNotPartOfTheSet() public {
        address tmp = makeAddr("tmp");
        claimMgr.setEngine(tmp, address(vault));
        claimMgr.setEngine(tmp, address(0)); // wired then de-authorized during launch (the de-authorize lever)
        (address[] memory e, address[] memory v) = _pair(address(this), address(vault));
        claimMgr.lockEngines(e, v); // tmp is unbound, so it is neither required nor accepted
        assertTrue(claimMgr.enginesLocked(), "locks without the de-authed engine");
    }
}

/// @notice Minimal stand-in for a prize engine: all `lockEngines` cross-checks is the `vault()` getter that
///         every real engine already has from its public immutable.
contract StubEngine {
    address public vault;

    constructor(address v) {
        vault = v;
    }
}
