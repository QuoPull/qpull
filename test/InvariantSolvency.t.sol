// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice A minimal stand-in for one prize engine (RaffleEngine / HolderDrawEngine / LeaderboardEngine),
///         bound to exactly ONE vault the way ClaimManager.engineVault requires. The handler
///         drives three of these so the fuzzed sequence exercises the real multi-vault topology instead of
///         a single-vault special case.
/// @dev    `driver` is the invariant handler; nothing else may register claims through this stub.
contract SolvencyEngineStub {
    ClaimManager public immutable claimMgr;
    address public immutable vault;
    address public immutable driver;

    error NotDriver();

    constructor(ClaimManager claimMgr_, address vault_, address driver_) {
        claimMgr = claimMgr_;
        vault = vault_;
        driver = driver_;
    }

    function register(address recipient, uint256 amount, uint64 deadline) external returns (uint256 id) {
        if (msg.sender != driver) revert NotDriver();
        id = claimMgr.registerClaim(vault, recipient, amount, deadline);
    }
}

/// @notice The solvency handler: fuzzed prize registrations (draws), single claims, "claim all" batches,
///         expiry sweeps, treasury top-ups and time warps against THREE BaseVaults sharing one
///         ClaimManager. Every action is try/catch'd so a legitimately-reverting step (over-reservation,
///         an expired window, a non-recipient caller) advances the sequence instead of aborting it.
/// @dev    Ghost ledgers are O(1) per action: `ghostFunded`/`ghostPaid` track every token in and out of a
///         vault, `ghostOpen` tracks the sum of registered-but-unsettled claim amounts. The invariants then
///         reconcile those ledgers against the live contract state.
contract SolvencyHandler is Test {
    MockERC20 public immutable quotron;
    ClaimManager public immutable claimMgr;

    BaseVault[] public vaults;
    SolvencyEngineStub[] public engines;
    address[] public actors;

    // ─── ghost ledgers ────────────────────────────────────────────────────────
    mapping(address => uint256) public ghostFunded; // QUOTRON ever minted INTO a vault (Treasury.convert)
    mapping(address => uint256) public ghostPaid; // QUOTRON ever paid OUT of a vault (settled claims)
    mapping(address => uint256) public ghostOpen; // sum of registered-but-unsettled claim amounts

    uint256[] public claimIds; // every id registerClaim actually returned
    uint256 public registered;
    uint256 public settled;
    uint256 public swept;
    uint256 public reverts;

    uint256 internal constant MAX_FUND = 1_000_000e18;
    // Deliberately larger than a single top-up so the fuzzer regularly ATTEMPTS to over-reserve; those
    // registerClaim calls must revert inside BaseVault.reserve rather than over-stating the pot.
    uint256 internal constant MAX_PRIZE = 3_000_000e18;

    error AlreadyWired();

    constructor(
        MockERC20 quotron_,
        ClaimManager claimMgr_,
        BaseVault[] memory vaults_,
        address[] memory actors_
    ) {
        quotron = quotron_;
        claimMgr = claimMgr_;
        for (uint256 i; i < vaults_.length; ++i) {
            vaults.push(vaults_[i]);
            // Seed inventory (a first Treasury.convert) so the opening registrations can succeed, and
            // book it through the same ghost ledger the invariants reconcile against.
            quotron_.mint(address(vaults_[i]), 100_000e18);
            ghostFunded[address(vaults_[i])] += 100_000e18;
        }
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
        }
    }

    /// @dev Breaks the deploy cycle: each stub needs THIS handler as its driver, so the stubs are
    ///      constructed after the handler and wired in once, before the fuzz campaign starts.
    function wireEngines(SolvencyEngineStub[] memory engines_) external {
        if (engines.length != 0) revert AlreadyWired();
        for (uint256 i; i < engines_.length; ++i) {
            engines.push(engines_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function claimIdCount() external view returns (uint256) {
        return claimIds.length;
    }

    // ─── actions ──────────────────────────────────────────────────────────────

    /// A Treasury.convert() landing prize inventory in a vault.
    function fundVault(uint256 vaultSeed, uint256 amountSeed) external {
        uint256 vi = bound(vaultSeed, 0, vaults.length - 1);
        uint256 amt = bound(amountSeed, 0, MAX_FUND);
        address v = address(vaults[vi]);
        quotron.mint(v, amt);
        ghostFunded[v] += amt;
    }

    /// An engine registering a drawn prize: reserves against the vault's FREE balance (spec §8).
    function registerPrize(uint256 vaultSeed, uint256 actorSeed, uint256 amountSeed, uint256 windowSeed)
        external
    {
        uint256 vi = bound(vaultSeed, 0, vaults.length - 1);
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 amt = bound(amountSeed, 0, MAX_PRIZE);
        uint64 deadline = uint64(block.timestamp + bound(windowSeed, 1, 40 days));

        try engines[vi].register(who, amt, deadline) returns (uint256 id) {
            claimIds.push(id);
            ghostOpen[address(vaults[vi])] += amt;
            ++registered;
        } catch {
            ++reverts;
        }
    }

    /// A winner pulling a single prize.
    function claimOne(uint256 idxSeed) external {
        uint256 n = claimIds.length;
        if (n == 0) return;
        uint256 id = claimIds[bound(idxSeed, 0, n - 1)];
        (address v, address to, uint256 amt,, bool alreadySettled) = claimMgr.claims(id);
        if (alreadySettled) return;

        vm.prank(to);
        try claimMgr.claim(id) {
            ghostOpen[v] -= amt;
            ghostPaid[v] += amt;
            ++settled;
        } catch {
            ++reverts;
        }
    }

    /// The "claim all" path: a batch of distinct ids, only the caller's own of which may settle.
    function claimSome(uint256 idxSeed, uint256 countSeed) external {
        uint256 n = claimIds.length;
        if (n == 0) return;
        uint256 cnt = bound(countSeed, 1, n < 5 ? n : 5);
        uint256 start = bound(idxSeed, 0, n - 1);

        uint256[] memory batch = new uint256[](cnt);
        bool[] memory was = new bool[](cnt);
        for (uint256 i; i < cnt; ++i) {
            batch[i] = claimIds[(start + i) % n]; // distinct positions, so distinct ids
            (,,,, was[i]) = claimMgr.claims(batch[i]);
        }
        (, address caller,,,) = claimMgr.claims(batch[0]);

        vm.prank(caller);
        try claimMgr.claimBatch(batch) {
            for (uint256 i; i < cnt; ++i) {
                (address v,, uint256 amt,, bool nowSettled) = claimMgr.claims(batch[i]);
                if (!was[i] && nowSettled) {
                    // inside claimBatch, "newly settled" can only mean "paid out"
                    ghostOpen[v] -= amt;
                    ghostPaid[v] += amt;
                    ++settled;
                }
            }
        } catch {
            ++reverts;
        }
    }

    /// Post-window sweep: the reservation is released back to the vault and rolls into future pots.
    function sweepExpired(uint256 idxSeed) external {
        uint256 n = claimIds.length;
        if (n == 0) return;
        uint256 id = claimIds[bound(idxSeed, 0, n - 1)];
        (address v,, uint256 amt,, bool alreadySettled) = claimMgr.claims(id);
        if (alreadySettled) return;

        try claimMgr.sweepExpired(id) {
            ghostOpen[v] -= amt;
            ++swept;
        } catch {
            ++reverts;
        }
    }

    /// Push time forward so claim windows actually close during the sequence.
    function warp(uint256 daysSeed) external {
        vm.warp(block.timestamp + bound(daysSeed, 1, 20) * 1 days);
    }
}

/// @title  InvariantSolvencyTest
/// @notice INVARIANT 1 (SOLVENCY). Across BaseVault + ClaimManager, no vault can ever owe more QUOTRON
///         than it holds: `unclaimedReserve <= balanceOf(vault)` under any fuzzed sequence of prize
///         registrations (draws), single claims, batch claims, expiry sweeps, funding and time warps.
/// @dev    The unit suites (test/ClaimManager.t.sol) pin the individual paths; this pins the ACCOUNTING
///         across arbitrary interleavings: the reserve/release/payOut triple is where solvency can break.
contract InvariantSolvencyTest is Test {
    MockERC20 quotron;
    ClaimManager claimMgr;
    BaseVault[] vaults;
    SolvencyEngineStub[] engines;
    address[] actors;
    SolvencyHandler handler;

    function setUp() public {
        vm.warp(1_000_000);
        quotron = new MockERC20();
        claimMgr = new ClaimManager(address(this));

        // Three vaults, one per game, exactly as the launch wiring binds them.
        for (uint256 i; i < 3; ++i) {
            BaseVault v = new BaseVault(address(quotron), address(this));
            v.setController(address(claimMgr)); // write-once controller
            vaults.push(v);
        }

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        // The handler is the driver behind all three engine stubs, so it is deployed first and the
        // stubs are wired into it afterwards.
        handler = new SolvencyHandler(quotron, claimMgr, vaults, actors);

        SolvencyEngineStub[] memory stubs = new SolvencyEngineStub[](3);
        address[] memory eng = new address[](3);
        address[] memory vlt = new address[](3);
        for (uint256 i; i < 3; ++i) {
            stubs[i] = new SolvencyEngineStub(claimMgr, address(vaults[i]), address(handler));
            eng[i] = address(stubs[i]);
            vlt[i] = address(vaults[i]);
            claimMgr.setEngine(eng[i], vlt[i]); // each engine bound to its own vault
        }
        handler.wireEngines(stubs);
        claimMgr.lockEngines(eng, vlt); // fuzz the frozen, launch-shaped binding set

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SolvencyHandler.fundVault.selector;
        selectors[1] = SolvencyHandler.registerPrize.selector;
        selectors[2] = SolvencyHandler.claimOne.selector;
        selectors[3] = SolvencyHandler.claimSome.selector;
        selectors[4] = SolvencyHandler.sweepExpired.selector;
        selectors[5] = SolvencyHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// THE solvency invariant (spec §8/§9): a vault can never owe more than it holds.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_reserveNeverExceedsBalance() public view {
        for (uint256 i; i < vaults.length; ++i) {
            BaseVault v = vaults[i];
            assertLe(
                v.unclaimedReserve(), quotron.balanceOf(address(v)), "vault owes more QUOTRON than it holds"
            );
        }
    }

    /// freeBalance() must be the EXACT complement of the reservation, never a truncated 0 that would
    /// let a snapshot over-state the pot (the one accounting bug that breaks solvency, IVault docs).
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_freeBalanceIsExactComplement() public view {
        for (uint256 i; i < vaults.length; ++i) {
            BaseVault v = vaults[i];
            uint256 bal = quotron.balanceOf(address(v));
            assertEq(v.freeBalance(), bal - v.unclaimedReserve(), "freeBalance is not balance - reserve");
        }
    }

    /// Every wei of `unclaimedReserve` is backed by exactly one open (registered, unsettled) claim:
    /// no orphan reservation survives a claim/sweep, and no claim is left unreserved.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_reserveEqualsOpenClaims() public view {
        for (uint256 i; i < vaults.length; ++i) {
            address v = address(vaults[i]);
            assertEq(
                vaults[i].unclaimedReserve(), handler.ghostOpen(v), "reserve drifted from open claim total"
            );
        }
    }

    /// A vault's balance is exactly what was funded into it minus what settled claims paid out:
    /// nothing else can move QUOTRON out of a vault.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_vaultBalanceMatchesFlows() public view {
        for (uint256 i; i < vaults.length; ++i) {
            address v = address(vaults[i]);
            assertEq(
                quotron.balanceOf(v),
                handler.ghostFunded(v) - handler.ghostPaid(v),
                "vault balance drifted from funded - paid"
            );
        }
    }

    /// No QUOTRON escapes the system: every token is either still in a vault or in a winner's hands.
    /// In particular the ClaimManager, which never holds funds, must hold none.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_noQuotronLeaks() public view {
        uint256 held;
        for (uint256 i; i < vaults.length; ++i) {
            held += quotron.balanceOf(address(vaults[i]));
        }
        for (uint256 i; i < actors.length; ++i) {
            held += quotron.balanceOf(actors[i]);
        }
        assertEq(quotron.totalSupply(), held, "QUOTRON leaked outside the vaults and winners");
        assertEq(quotron.balanceOf(address(claimMgr)), 0, "ClaimManager must never hold funds");
    }
}
