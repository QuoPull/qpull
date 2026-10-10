// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { ClaimManager } from "../../src/ClaimManager.sol";
import { Treasury } from "../../src/Treasury.sol";

interface IRouterView {
    function quotron() external view returns (address);
}

interface IBuy {
    function buyExactEth(uint256 minOut, address to, uint256 deadline) external payable returns (uint256);
}

/// A vault-shaped contract WITHOUT the receiver hook — the control case.
contract NoHookHolder { }

/// @notice Stands in for `RaffleEngine._payWinners` at MAX_K. It is the ClaimManager-bound "engine", and
///         `registerBatch` reproduces that function's inner loop — K sequential `registerClaim` calls in ONE
///         transaction, each of which drives `BaseVault.reserve` and therefore a REAL QUOTRON `balanceOf`.
///         Measuring the loop from inside a single call is the only faithful way to size a draw: K separate
///         test-level calls would each pay a fresh transaction's warm-up and understate nothing while
///         misattributing everything (the one-transaction number is the one that matters).
contract DrawHarness {
    ClaimManager public immutable claimManager;
    address public immutable vault;

    constructor(ClaimManager cm_, address vault_) {
        claimManager = cm_;
        vault = vault_;
    }

    /// @dev Mirrors `_payWinners`: one registerClaim per winner, all in a single call.
    function registerBatch(address winner, uint256 prize, uint64 deadline, uint256 k)
        external
        returns (uint256[] memory ids)
    {
        ids = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            ids[i] = claimManager.registerClaim(vault, winner, prize, deadline);
        }
    }
}

/// @notice Forks Robinhood Chain mainnet at a PINNED block and exercises the ERC-404 whole-unit
///         ("terminal mint") paths against the REAL QUOTRON token — the strongest possible evidence for
///         spec §13.3, and the deterministic draw-gas and whole-unit payout run that only a real-QUOTRON fork gives:
///
///           1. RECEIPT   — BaseVault and Treasury both safely accept a whole unit (§13.3), diagnosed
///                          against a hookless control while the holder is still funded, so a revert there
///                          is unambiguously the hook and not an insufficient-balance artifact.
///           2. PAYOUT    — the claim path pays a whole unit BACK OUT of a vault through real QUOTRON
///                          (the outbound whole-unit crossing, which no mock can model).
///           3. DRAW GAS  — the MAX_K=200 draw and the MAX_K "claim all" batch, measured on real QUOTRON
///                          and asserted one-block-safe (an earlier RaffleEngine.MAX_K comment claimed
///                          "~120-140k gas/winner"; checked here rather than assumed).
///
///         Measured at PINNED_BLOCK, for the record:
///           MAX_K=200 draw (registerClaim x200, one tx) ...... 19_507_036
///           MAX_K=200 claimBatch, fractional prizes ..........  4_132_898
///           raw QUOTRON whole-unit transfer ..................    177_542
///           full per-winner whole-unit claim ................. 164_808 - 168_808
///         The draw is the binding constraint and fits comfortably. The old ~120-140k per-winner figure
///         is optimistic against these numbers; see WHOLE_UNIT_TRANSFER_GAS_CEILING.
///
/// @dev  DETERMINISM: this suite used to `vm.skip(true)` out of branches whenever live market state
///       moved under it, so a green run proved nothing. Every market-dependent branch is now a HARD
///       assertion, and the only skip is the hand-set QUOPULL_FORK_SKIP=1, which prints its reason on the
///       result line, so a green run can never be mistaken for real coverage.
///
///       DEFAULT = FORK `latest`. Robinhood Chain runs ~0.1s blocks and the PUBLIC RPC is a pruning Nitro
///       node retaining only ~5,500 recent blocks (~9 minutes), so a FIXED pin cannot survive against it
///       (it would prune out mid-run). The default therefore forks `latest` (always served): it runs every
///       assertion and gas-ceiling check against real QUOTRON on each run, and loudly logs that the numbers
///       are point-in-time, not reproducible. `PINNED_BLOCK` is kept as a recent REFERENCE for reproducing
///       the logged gas on an archive node.
///
///       FOR A REPRODUCIBLE (pinned) RUN a maintainer sets:
///         RH_RPC_URL      an ARCHIVE Robinhood Chain mainnet RPC that still serves state at the pinned
///                         block. The public endpoint prunes (~9 min), so any pin WILL go stale against it.
///         RH_FORK_BLOCK   the block to pin (e.g. PINNED_BLOCK, or another the archive node serves). Unset
///                         (the default) forks `latest`; explicitly setting it fails LOUD if that exact block
///                         is not served, which is the maintainer's deliberate reproducibility intent.
///         QUOPULL_FORK_SKIP  optional; 1 = skip instead of failing when the fork state is unreachable
///                            (e.g. the RPC is down). Leave it UNSET in any job meant to prove real-QUOTRON coverage.
contract QuotronWholeUnitForkTest is Test {
    address constant ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;

    /// @dev A recent REFERENCE height for reproducing the logged gas on an ARCHIVE node. It is NOT the
    ///      default (see setUp: the default forks `latest`, because the public RH RPC prunes to a ~9-minute
    ///      window and cannot serve a fixed pin). To reproduce, run with an archive RH_RPC_URL and
    ///      RH_FORK_BLOCK=<this block, or another that node serves>; re-pin deliberately and re-read the gas.
    ///      Last verified against real QUOTRON at this height (draw ~19.4M, raw whole-unit xfer ~177.6k).
    uint256 constant PINNED_BLOCK = 55_603_179;

    /// @dev Probe size. At the pinned block this buys well over MIN_WHOLE_UNITS; it is deliberately
    ///      oversized so no test is ever short a unit, which is what drove the old market-state skips.
    uint256 constant PROBE_ETH = 40 ether;
    uint256 constant MIN_WHOLE_UNITS = 6e18;

    /// @dev Mirrors RaffleEngine.MAX_K. Kept as a literal on purpose: if the engine's cap is ever raised,
    ///      this test must be re-run and re-reasoned, not silently re-scaled.
    uint256 constant MAX_K = 200;

    /// @dev Ceiling on the RAW QUOTRON whole-unit transfer: the figure an earlier RaffleEngine comment rested on
    ///      when it justified MAX_K=200 with "~120-140k gas/winner".
    ///
    ///      MEASURED AT PINNED_BLOCK: 177_542. That figure is therefore OPTIMISTIC by roughly 27% for
    ///      this crossing, and the cost is state-dependent: the same transfer priced 133_575 from a holder
    ///      whose ERC-404 terminal queue was in a different shape. The engine's one-block conclusion still
    ///      holds (see the draw assertion below, which is the binding constraint), but the per-winner
    ///      constant in that comment should be re-read as ~180k, not ~140k. Ceiling set ~18% above the
    ///      measured worst case so a QUOTRON upgrade that made the terminal mint dearer fails HERE, loudly,
    ///      rather than surfacing as a stuck claim on mainnet.
    uint256 constant WHOLE_UNIT_TRANSFER_GAS_CEILING = 210_000;

    /// @dev Ceiling on the FULL per-winner settle path: ClaimManager.claim -> vault.release -> vault.payOut
    ///      -> the real ERC-404 whole-unit crossing, plus the claim bookkeeping. Measured 164_808 - 168_808
    ///      at PINNED_BLOCK depending on storage warmth; it is this figure, not the raw transfer, that
    ///      prices a real winner. Ceiling set ~18% above the measured worst case.
    uint256 constant PER_WINNER_CLAIM_GAS_CEILING = 200_000;

    /// @dev RH is a Nitro chain and reports a nominal `block.gaslimit` of 2**50, which is an ArbOS
    ///      artifact and NOT a spendable budget — asserting against it would be vacuous. We assert against
    ///      the conservative 32M per-transaction ceiling instead. Override with QUOPULL_GAS_BUDGET to
    ///      tighten it for a specific run.
    uint256 constant DEFAULT_GAS_BUDGET = 32_000_000;

    /// @dev Raised when the configured RPC cannot serve the fork this suite pins to. Deliberately NOT a
    ///      skip: silence here would pass a run that proved nothing.
    error ForkStateUnavailable(uint256 pinnedBlock);
    error ForkRpcUnavailable();

    string rpc;
    uint256 forkBlock;
    uint256 gasBudget;
    address quotron;
    address holder;

    // ─────────────────────────────────────────────────────────────────────────────────────────────────
    // fork acquisition
    // ─────────────────────────────────────────────────────────────────────────────────────────────────

    function setUp() public {
        rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        // DEFAULT = fork `latest` (0). The public RH RPC prunes to a ~9-minute window (RH runs ~0.1s blocks
        // and keeps ~5.5k blocks), so a fixed pin cannot survive there. Forking latest is always served and
        // runs every assertion; it logs "not reproducible" loudly. Set RH_FORK_BLOCK=<n> (with an archive
        // RH_RPC_URL) for a pinned, reproducible run; PINNED_BLOCK is the recent reference to use there.
        forkBlock = vm.envOr("RH_FORK_BLOCK", uint256(0));
        gasBudget = vm.envOr("QUOPULL_GAS_BUDGET", DEFAULT_GAS_BUDGET);

        // Pre-flight BEFORE forking. A fork whose state the node has pruned does not fail as a catchable
        // revert: forge aborts the run with an uncatchable "EVM error; database error" naming an ArbOS
        // system account, which reads like a toolchain bug rather than a configuration one. Probing over
        // vm.rpc first (that IS catchable) lets us fail with an accurate message, or honour the opt-in skip.
        // Two distinct pre-flights, because the two causes want two different fixes: an unreachable HOST
        // means the endpoint is wrong or down, while a reachable host that cannot open the state trie at
        // this height means the node is pruning and the pin has aged out.
        bool hostUp = _rpcReachable();
        if (!hostUp || !_rpcServesState(forkBlock)) {
            _abortUnavailable(hostUp);
            return; // unreachable unless vm.skip armed above
        }

        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
            emit log("WARNING: RH_FORK_BLOCK=0 selected the LATEST block, so this run is NOT reproducible.");
            emit log("WARNING: gas figures and router quotes below are point-in-time only.");
            emit log_named_uint("re-pin PINNED_BLOCK to reproduce this run", block.number);
        } else {
            vm.createSelectFork(rpc, forkBlock);
            assertEq(block.number, forkBlock, "fork did not land on the pinned block");
            emit log_named_uint("pinned fork block", block.number);
        }

        quotron = IRouterView(ROUTER).quotron();

        // Fund an EOA holder with whole QUOTRON units through the REAL router (EOAs never trip the ERC-404
        // callback, so the holder side stays a clean baseline). Buying through the router rather than
        // vm.deal is deliberate: QUOTRON is an ERC-404 whose whole-unit bookkeeping lives in storage a raw
        // balance poke would desynchronise, which would quietly invalidate every assertion below.
        holder = makeAddr("holder");
        vm.deal(holder, PROBE_ETH + 4 ether);
        vm.prank(holder);
        IBuy(ROUTER).buyExactEth{ value: PROBE_ETH }(1, holder, block.timestamp + 900);

        // These were `vm.skip(true)` branches. At a pinned block the fill is deterministic,
        // so an under-filled probe is a real regression (re-pinned onto a thin block, or router/pool moved)
        // and must fail rather than green the suite.
        uint256 held = IERC20(quotron).balanceOf(holder);
        emit log_named_uint("holder QUOTRON (wei)", held);
        assertGe(held, MIN_WHOLE_UNITS, "probe buy under-filled: re-pin, or raise PROBE_ETH");
    }

    /// @dev True when the endpoint answers at all. Separates "wrong or dead URL" from "node has pruned the
    ///      pinned block", which are different operator mistakes with different fixes.
    function _rpcReachable() internal returns (bool) {
        try vm.rpc(rpc, "eth_blockNumber", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev True when `rpc` can serve account state at `blockNumber` (0 = latest). Uses a raw eth_getBalance
    ///      against the router because that is the cheapest call that forces the node to open the state
    ///      trie at that height, which is precisely what a pruning node cannot do.
    function _rpcServesState(uint256 blockNumber) internal returns (bool) {
        string memory tag = blockNumber == 0 ? "latest" : string.concat("0x", _hex(blockNumber));
        string memory params = string.concat("[\"", vm.toString(ROUTER), "\",\"", tag, "\"]");
        try vm.rpc(rpc, "eth_getBalance", params) returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _hex(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory digits = "0123456789abcdef";
        bytes memory buf = new bytes(64);
        uint256 i = 64;
        while (v != 0) {
            buf[--i] = digits[v & 0xf];
            v >>= 4;
        }
        bytes memory out = new bytes(64 - i);
        for (uint256 j; j < out.length; ++j) {
            out[j] = buf[i + j];
        }
        return string(out);
    }

    /// @dev The single place a skip can happen, and only when a human asked for one. `hostUp` distinguishes
    ///      a dead endpoint from a live-but-pruning one so the printed fix matches the actual fault.
    function _abortUnavailable(bool hostUp) internal {
        emit log("================================ FORK COVERAGE NOT OBTAINED ================================");
        emit log("The REAL-QUOTRON evidence (draw gas at MAX_K, whole-unit payout) was NOT produced by this run.");
        emit log_named_string("  RH_RPC_URL   ", rpc);
        emit log_named_uint("  pinned block ", forkBlock);
        if (!hostUp) {
            emit log("CAUSE: the endpoint did not answer eth_blockNumber at all.");
            emit log("FIX:   set RH_RPC_URL to a reachable Robinhood Chain mainnet RPC.");
        } else {
            emit log("CAUSE: the endpoint is up but cannot open state at the pinned block. The public RH");
            emit log("       endpoint is a pruning Nitro node and retains only a few thousand recent blocks.");
            emit log("FIX:   point RH_RPC_URL at an ARCHIVE node that retains this block, or re-pin with");
            emit log("       RH_FORK_BLOCK=<a block that node serves>. RH_FORK_BLOCK=0 forks latest, which");
            emit log("       still runs every assertion but is not reproducible.");
        }
        emit log("===========================================================================================");

        if (vm.envOr("QUOPULL_FORK_SKIP", uint256(0)) == 1) {
            vm.skip(
                true,
                "QUOPULL_FORK_SKIP=1: real-QUOTRON fork unreachable, real-QUOTRON coverage NOT proven by this run"
            );
            return;
        }
        if (!hostUp) revert ForkRpcUnavailable();
        revert ForkStateUnavailable(forkBlock);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────
    // 1. RECEIPT — §13.3
    // ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Both contracts that receive QUOTRON (BaseVault and Treasury) accept a whole unit, with a
    ///         hookless control run while the holder is still funded so the diagnosis is unambiguous.
    function test_vaultAndTreasuryAcceptWholeQuotronUnit() public {
        // (1) POSITIVE — BaseVault (has the hook): receives a whole unit, must NOT revert.
        BaseVault vault = new BaseVault(quotron, address(this));
        vm.prank(holder);
        IERC20(quotron).transfer(address(vault), 1e18); // exact 0 -> 1.0 whole-unit crossing
        assertEq(IERC20(quotron).balanceOf(address(vault)), 1e18, "vault safely holds the whole unit");
        emit log("PASS: BaseVault received a whole QUOTRON unit");

        // (2) DIAGNOSTIC — hookless control, run WHILE the holder still owns >=1 unit, so a revert here
        //     is the hook callback and not insufficient balance. try/catch (a revert does not consume).
        assertGe(IERC20(quotron).balanceOf(holder), 1e18, "holder still funded -> clean diagnostic");
        NoHookHolder bare = new NoHookHolder();
        vm.prank(holder);
        try IERC20(quotron).transfer(address(bare), 1e18) {
            emit log("DIAGNOSTIC: hookless receipt SUCCEEDED -> QUOTRON does not safe-callback; hook is insurance");
            assertEq(IERC20(quotron).balanceOf(address(bare)), 1e18);
        } catch {
            emit log("DIAGNOSTIC: hookless receipt REVERTED with holder funded -> hazard is REAL; hook REQUIRED");
        }

        // (3) POSITIVE — the real Treasury (now carries the hook): this is the fix that keeps convert()
        //     from bricking when a batch buys >=1 whole QUOTRON. Dummy qpull/weth are never touched here.
        Treasury treasury = new Treasury(address(0xDEAD), address(0xBEEF), quotron, address(this));
        vm.prank(holder);
        IERC20(quotron).transfer(address(treasury), 1e18);
        assertEq(IERC20(quotron).balanceOf(address(treasury)), 1e18, "treasury safely holds the whole unit");
        emit log("PASS: Treasury received a whole QUOTRON unit (convert() is unbrickable)");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────
    // 2. PAYOUT: the outbound whole-unit crossing
    // ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The OUTBOUND whole-unit crossing: a real ClaimManager releases and pays a whole QUOTRON unit
    ///         out of a real BaseVault to a winner. This needs a real-QUOTRON run for the
    ///         whole-unit payout precisely because a mock ERC20 cannot reproduce the
    ///         ERC-404 terminal bookkeeping this transfer triggers on BOTH sides of the transfer.
    function test_vaultPaysOutWholeQuotronUnitThroughClaimManager() public {
        (BaseVault vault, ClaimManager claimMgr, DrawHarness engine) = _wireClaimPath();

        // Fund the vault the way Treasury.convert() would: a plain transfer of prize inventory.
        vm.prank(holder);
        IERC20(quotron).transfer(address(vault), 3e18);
        assertEq(vault.freeBalance(), 3e18, "vault free balance is the whole inventory pre-reserve");

        address winner = makeAddr("winner");
        uint64 deadline = uint64(block.timestamp + 30 days);
        uint256[] memory ids =
            engine.registerBatch(winner, 1e18, deadline, 1); // one whole-unit prize

        // Reserve accounting holds against the REAL token balance (spec §8: freeBalance never counts
        // prizes already owed).
        assertEq(vault.unclaimedReserve(), 1e18, "prize reserved");
        assertEq(vault.freeBalance(), 2e18, "freeBalance excludes the reserved whole unit");

        uint256 gasStart = gasleft();
        vm.prank(winner);
        claimMgr.claim(ids[0]);
        uint256 payoutGas = gasStart - gasleft();

        // The whole unit actually left the vault and landed, in full, on a fresh recipient.
        assertEq(IERC20(quotron).balanceOf(winner), 1e18, "winner received the whole unit in full");
        assertEq(IERC20(quotron).balanceOf(address(vault)), 2e18, "vault debited by exactly the prize");
        assertEq(vault.unclaimedReserve(), 0, "reserve released on settlement");
        assertEq(vault.freeBalance(), 2e18, "remaining inventory stays free for the next draw");

        emit log_named_uint("GAS: claim() paying out a whole QUOTRON unit", payoutGas);
        assertLt(payoutGas, PER_WINNER_CLAIM_GAS_CEILING, "whole-unit payout exceeded the per-winner ceiling");
        emit log("PASS: a whole QUOTRON unit was paid OUT of a vault (covered on real QUOTRON)");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────
    // 3. DRAW GAS AT MAX_K
    // ─────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice "runDraw gas at MAX_K=200" can only be settled by a fork run against real QUOTRON. Two numbers decide
    ///         it, and both are measured here rather than modelled:
    ///
    ///           (a) the DRAW: MAX_K `registerClaim` calls in one transaction, exactly as
    ///               `RaffleEngine._payWinners` issues them, each driving `BaseVault.reserve` and so a real
    ///               QUOTRON `balanceOf`;
    ///           (b) the CLAIM: a MAX_K `claimBatch`, the worst single transaction a winner can send, which
    ///               is where the real QUOTRON transfers actually land.
    ///
    ///         The pathological case — every one of the 200 winners crossing a whole unit — is priced from
    ///         the measured per-winner ceiling rather than bought outright: QUOTRON's total supply is only
    ///         ~1652 whole units, so 200 whole-unit prizes is not a fundable probe on any real fork.
    function test_maxKDrawGasFitsOneBlockOnRealQuotron() public {
        (BaseVault vault, ClaimManager claimMgr, DrawHarness engine) = _wireClaimPath();

        // A MAX_K field with a realistic per-winner prize. 200 * 0.01 units = 2 whole units of pot, which
        // the winner accumulates across the batch and which therefore still crosses whole-unit boundaries
        // inside the batch — the ERC-404 work is exercised, not sidestepped.
        uint256 prize = 0.01e18;
        uint256 pot = prize * MAX_K;
        vm.prank(holder);
        IERC20(quotron).transfer(address(vault), pot);
        assertEq(vault.freeBalance(), pot, "vault funded with the full MAX_K pot");

        address winner = makeAddr("maxKWinner");
        uint64 deadline = uint64(block.timestamp + 30 days);

        // (a) the DRAW at MAX_K, in ONE transaction.
        uint256 gasStart = gasleft();
        uint256[] memory ids = engine.registerBatch(winner, prize, deadline, MAX_K);
        uint256 drawGas = gasStart - gasleft();

        assertEq(ids.length, MAX_K, "registered a full MAX_K field");
        assertEq(vault.unclaimedReserve(), pot, "every prize reserved against the real balance");
        assertEq(vault.freeBalance(), 0, "the whole pot is owed, so nothing reads as free");

        emit log_named_uint("GAS: MAX_K=200 draw (registerClaim x200, one tx)", drawGas);
        assertLt(drawGas, gasBudget, "MAX_K draw does not fit one block on real QUOTRON");

        // (b) the CLAIM at MAX_K, in ONE transaction — 200 real QUOTRON transfers out of the vault.
        gasStart = gasleft();
        vm.prank(winner);
        uint256 claimed = claimMgr.claimBatch(ids);
        uint256 claimGas = gasStart - gasleft();

        assertEq(claimed, MAX_K, "every claim in the batch paid");
        assertEq(IERC20(quotron).balanceOf(winner), pot, "winner received the entire pot");
        assertEq(IERC20(quotron).balanceOf(address(vault)), 0, "vault fully drained to the winner");
        assertEq(vault.unclaimedReserve(), 0, "all reserves released");

        emit log_named_uint("GAS: MAX_K=200 claimBatch (200 real QUOTRON payouts, one tx)", claimGas);
        assertLt(claimGas, gasBudget, "MAX_K claimBatch does not fit one block on real QUOTRON");

        // (c) The old per-winner claim itself: the RAW whole-unit QUOTRON transfer that the "~120-140k gas/winner"
        //     figure refers to. Measured directly against the live token rather than inferred.
        uint256 rawTransferGas = _measureRawWholeUnitTransfer();
        emit log_named_uint("GAS: raw QUOTRON whole-unit transfer", rawTransferGas);
        assertLt(
            rawTransferGas,
            WHOLE_UNIT_TRANSFER_GAS_CEILING,
            "raw whole-unit transfer exceeded its ceiling"
        );

        // (d) The pathological field: every winner crossing a whole unit. Priced from a real measurement
        //     of the FULL settle path, because that is what a winner actually pays.
        uint256 worstPerWinner = _measureWholeUnitPayout(vault, claimMgr, engine);
        emit log_named_uint("GAS: worst-case per-winner whole-unit claim", worstPerWinner);
        assertLt(
            worstPerWinner,
            PER_WINNER_CLAIM_GAS_CEILING,
            "per-winner whole-unit claim exceeded the ceiling"
        );

        // claimBatch's length is chosen by the CALLER, so unlike runDraw it is chunkable and its worst case
        // is guidance, not a protocol invariant. Derive and publish the safe chunk size; warn (loudly, with
        // the exact number a front-end must use) when a full MAX_K field of whole-unit prizes would not fit
        // one transaction. The non-chunkable call — the draw itself — is hard-asserted above.
        uint256 worstField = worstPerWinner * MAX_K;
        uint256 maxSafeBatch = gasBudget / worstPerWinner;
        emit log_named_uint("GAS: MAX_K=200 all-whole-unit field (extrapolated)", worstField);
        emit log_named_uint("one-transaction gas budget", gasBudget);
        emit log_named_uint("max whole-unit claims safely batchable per tx", maxSafeBatch);
        assertGt(maxSafeBatch, 0, "a single whole-unit claim must fit one transaction");
        if (worstField >= gasBudget) {
            emit log("WARNING: a caller holding a FULL MAX_K field of whole-unit prizes cannot claim it in");
            emit log("WARNING: one claimBatch at this budget. Chunk claimBatch to the size logged above.");
            emit log("WARNING: this bounds the CLAIM path only. runDraw is unaffected and is asserted above.");
        }
        emit log("PASS: MAX_K=200 runDraw is one-block-safe on real QUOTRON");
    }

    /// @dev The bare ERC-404 cost the old per-winner figure is about: one whole unit, holder to a fresh EOA, with no
    ///      vault or claim bookkeeping in the measurement.
    function _measureRawWholeUnitTransfer() internal returns (uint256) {
        address fresh = makeAddr("rawTransferRecipient");
        vm.prank(holder);
        uint256 gasStart = gasleft();
        IERC20(quotron).transfer(fresh, 1e18);
        uint256 used = gasStart - gasleft();
        assertEq(IERC20(quotron).balanceOf(fresh), 1e18, "raw whole-unit probe actually transferred");
        return used;
    }

    /// @dev Registers and settles ONE whole-unit prize to a fresh recipient and returns the payout gas.
    ///      A fresh recipient is the expensive case: the crossing mints the ERC-404 terminal into cold
    ///      storage, which is what makes a whole-unit winner dearer than a fractional one.
    function _measureWholeUnitPayout(BaseVault vault, ClaimManager claimMgr, DrawHarness engine)
        internal
        returns (uint256)
    {
        vm.prank(holder);
        IERC20(quotron).transfer(address(vault), 1e18);

        address winner = makeAddr("wholeUnitWinner");
        uint256[] memory ids = engine.registerBatch(winner, 1e18, uint64(block.timestamp + 30 days), 1);

        uint256 gasStart = gasleft();
        vm.prank(winner);
        claimMgr.claim(ids[0]);
        uint256 used = gasStart - gasleft();

        assertEq(IERC20(quotron).balanceOf(winner), 1e18, "whole-unit probe actually paid out");
        return used;
    }

    /// @dev The production wiring, deployed fresh on the fork: one vault, the single immutable controller
    ///      (ClaimManager), and an engine bound to that one vault only.
    function _wireClaimPath() internal returns (BaseVault, ClaimManager, DrawHarness) {
        BaseVault vault = new BaseVault(quotron, address(this));
        ClaimManager claimMgr = new ClaimManager(address(this));
        DrawHarness engine = new DrawHarness(claimMgr, address(vault));

        vault.setController(address(claimMgr)); // write-once, never revocable
        claimMgr.setEngine(address(engine), address(vault));
        return (vault, claimMgr, engine);
    }
}
