// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// Holds and pledges passes in one call each, so the isolated setup is a handful of transactions rather than hundreds.
/// @dev One storage slot, set at construction, so clearing it is a cold SSTORE 1 -> 0: about 5,000 gas gross with a
///      4,800 refund. Used only to read whether this Foundry's vm.lastCallGas() reports gasTotalUsed before or after
///      the refund, which changed between versions. See RunDrawIsolatedGasTest._gasTotalUsedIsGross.
contract RefundProbe {
    uint256 public x = 1;
    function noop() external { }
    function clear() external { x = 0; }
}

contract GasPassHolder {
    function holdSuperRares(MockNFT nft, uint256 n) external returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.set(1 + i, address(this), 3);
            ids[i] = 1 + i;
        }
    }

    function pledgeRares(MockNFT nft, PackRegistry packs, uint256 base, uint256 n) external {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.set(base + i, address(this), 2);
            ids[i] = base + i;
        }
        packs.pledge(ids);
    }
}

/// @notice The two existing max-K runDraw gas gates (RaffleFlow.t.sol and GasBenchmark.t.sol)
///         build the stack and draw inside ONE test transaction, so every slot the draw touches is already warm and
///         dirty, and they read `gasleft()` deltas. The documented "~25.9M" came from that shape. Robinhood Chain's
///         per-transaction limit (ArbGasInfo.getMaxTxGasLimit() = 32,000,000, read on 4663) applies to what a real,
///         separate transaction needs BEFORE its refund is credited, from cold storage.
///
///         So each test here runs with `isolate = true` (inline config): every top-level call below is committed as its
///         own transaction, and `runDraw` is measured as ONE transaction on cold storage. The gate is on the PRE-refund
///         requirement, which is what a transaction's gas LIMIT must cover:
///
///             preRefund  <=  32,000,000 - MARGIN,   MARGIN = 1,000,000
///
///         How preRefund is read from `vm.lastCallGas()` depends on the Foundry version, because `gasTotalUsed` changed
///         meaning: forge 1.7.1 reported it AFTER the refund (so preRefund = gasTotalUsed + gasRefunded), forge 1.8.4
///         reports it BEFORE (so preRefund = gasTotalUsed). `_gasTotalUsedIsGross` measures which applies against a
///         call with a known refund instead of assuming it. Assuming the old meaning on 1.8.4 double-counts the refund
///         and moved the K = 200 reading from its true 30,535,570 to 31,986,370.
///
///         MARGIN is stated, not derived: the minimum gas LIMIT exceeds the consumption by the EIP-150 63/64 reserve kept
///         back at each external call (about consumption / 63, ~0.5M at this size), plus the L1 data component
///         Robinhood Chain (Arbitrum Orbit) adds for a 36-byte call, and what is left is regression headroom. A change
///         that eats the margin fails here before it can void a K = 200 day on chain.
///
///         K = 200 is RaffleEngine.MAX_K: launch runs K = 10, and setWinnersPerDay can walk K up by at most 25% per day,
///         so 200 is reachable by deliberate raises (not only at construction).
contract RunDrawIsolatedGasTest is Test {
    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days;
    uint256 constant POT = 1_000_000e18;
    uint256 constant K = 200;
    uint256 constant RH_MAX_TX_GAS = 32_000_000; // ArbGasInfo.getMaxTxGasLimit() on 4663
    uint256 constant MARGIN = 1_000_000;

    PackRegistry packs;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;
    GasPassHolder holder;
    address token = makeAddr("token");

    function _build() internal {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 3);
        quotron = new MockERC20();
        nft = new MockNFT();
        holder = new GasPassHolder();
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, 1000, address(this)
        );
        assertEq(raffle.MAX_K(), K, "premise: K is MAX_K");
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        packs.setMaxTicketsPerBuy(200);
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        quotron.mint(address(vault), POT);
    }

    function _buyMany(uint256 n, uint256 salt) internal {
        uint256 left = n;
        for (uint256 i; left > 0; ++i) {
            uint256 m = left > 200 ? 200 : left;
            vm.prank(token);
            packs.recordBuy(address(uint160(uint256(keccak256(abi.encode("buyer", salt, i))))), m * TICKET);
            left -= m;
        }
    }

    function _openingEmpty() internal {
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 2 hours);
        raffle.runOpeningDraw(false); // empty window [0,1]: settles, touches none of the draw cohorts
        assertTrue(raffle.openingDone(), "premise: opening settled");
    }

    /// Runs runDraw(day) as its own transaction and returns (pre-refund gas, post-refund gas, refund).
    /// @dev Does this Foundry's `vm.lastCallGas().gasTotalUsed` already include the refund (gross), or has the refund
    ///      been subtracted (net)? It CHANGED: forge 1.7.1, which this gate was written and calibrated on, reported it
    ///      net, so the pre-refund requirement was gasTotalUsed + gasRefunded. forge 1.8.4 reports it gross. Adding the
    ///      refund back on 1.8.4 counts it twice, and the K = 200 draw read 31,986,370 instead of its true 30,535,570,
    ///      failing a gate it actually clears with the documented ~0.46M to spare.
    ///
    ///      Measured, not assumed, the same way deployCodeTo's nonce cost is (test/utils/NonceAwareDeploy.sol): a cold
    ///      SSTORE 1 -> 0 costs ~5,000 gross and refunds 4,800, so its gasTotalUsed sits ~5,000 above a no-op if the
    ///      refund is NOT subtracted and ~200 above it if it is. 2,500 splits the two cases with room on both sides.
    ///      MUST run before the measured call: it makes calls of its own, which overwrite lastCallGas.
    function _gasTotalUsedIsGross() internal returns (bool) {
        RefundProbe p = new RefundProbe();
        p.noop();
        uint256 base = vm.lastCallGas().gasTotalUsed;
        p.clear();
        uint256 withRefund = vm.lastCallGas().gasTotalUsed;
        return withRefund - base > 2_500;
    }

    function _measure(uint32 day, string memory tag) internal returns (uint256 preRefund) {
        bool gross = _gasTotalUsedIsGross(); // FIRST: its own calls overwrite lastCallGas
        uint256 claims0 = claimMgr.nextClaimId();
        raffle.runDraw(day);
        Vm.Gas memory g = vm.lastCallGas();
        uint256 refunded = uint256(uint64(g.gasRefunded));
        // The pre-refund requirement is what the transaction's gas LIMIT must cover. Gross: it is gasTotalUsed as
        // reported. Net: the refund was subtracted, so add it back.
        preRefund = gross ? g.gasTotalUsed : g.gasTotalUsed + refunded;
        assertTrue(raffle.drawn(day), "the draw day was consumed");
        assertEq(claimMgr.nextClaimId() - claims0, K, "a full field of K winners was selected and paid");
        console2.log(tag);
        console2.log(gross ? "  runDraw gasTotalUsed (GROSS, refund included)  " : "  runDraw gasTotalUsed (NET, after the refund)   ", g.gasTotalUsed);
        console2.log("  runDraw gasRefunded                            ", refunded);
        console2.log("  PRE-REFUND gas (what the tx limit must cover)  ", preRefund);
        console2.log("  + the 63/64 reserve estimate (preRefund / 63)  ", preRefund + preRefund / 63);
        console2.log("  gate: 32,000,000 - MARGIN                      ", RH_MAX_TX_GAS - MARGIN);
        assertLe(preRefund, RH_MAX_TX_GAS - MARGIN, "isolated runDraw at MAX_K exceeds 32M minus the stated margin");
    }

    /// The worst shape: seven non-empty cohorts in the sweep window (seven tier rounds, the cohort walk per paid pop),
    /// the virtual free block active with PackRegistry.MAX_SR_SCAN = 128 registered Super Rares plus 90 pledged Rares.
    /// forge-config: default.isolate = true
    function test_gas_isolated_runDraw_maxK_sevenCohorts_128SuperRares() public {
        _build();
        _openingEmpty(); // currentDay 2
        for (uint32 c = 2; c <= 8; ++c) {
            vm.warp(GENESIS + uint256(c) * DAY + 1);
            _buyMany(1500, c);
        }
        packs.registerSuperRare(holder.holdSuperRares(nft, 128));
        vm.warp(GENESIS + 9 * DAY + 1); // day 9: pledge for draw day 9
        holder.pledgeRares(nft, packs, 1000, 90);
        for (uint32 c = 2; c <= 8; ++c) {
            oracle.setBeacon(oracle.roundAt(GENESIS + (uint256(c) + 1) * DAY + 1 hours), keccak256(abi.encode("rev", c)));
        }
        oracle.setBeacon(raffle.drawRound(9), keccak256("d9"));
        vm.warp(GENESIS + 10 * DAY + 2 hours); // currentDay 10: draw day 9 sweeps cohorts [2..8]
        _measure(9, "=== isolated runDraw, K=200, 7 cohorts, 128 SR + 90 pledged Rares ===");
    }

    /// The RaffleFlow.t.sol gate's shape (paid only, a full 7-cohort window [3..9]), measured isolated.
    /// forge-config: default.isolate = true
    function test_gas_isolated_runDraw_maxK_paidOnly_fullWindow() public {
        _build();
        vm.prank(token);
        packs.recordBuy(makeAddr("alice"), 10 * TICKET); // cohort 0, for the opening
        for (uint32 c = 3; c <= 9; ++c) {
            vm.warp(GENESIS + uint256(c) * DAY + 1);
            vm.prank(token);
            packs.recordBuy(makeAddr("alice"), 40 * TICKET);
        }
        oracle.setBeacon(oracle.roundAt(GENESIS + 1 * DAY + 1 hours), keccak256("rev0"));
        for (uint32 c = 3; c <= 9; ++c) {
            oracle.setBeacon(oracle.roundAt(GENESIS + (uint256(c) + 1) * DAY + 1 hours), keccak256(abi.encode("rev", c)));
        }
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        raffle.runOpeningDraw(false);
        oracle.setBeacon(raffle.drawRound(10), keccak256("draw"));
        vm.warp(GENESIS + 11 * DAY + 1);
        _measure(10, "=== isolated runDraw, K=200, paid only, 7-cohort window ===");
    }
}
