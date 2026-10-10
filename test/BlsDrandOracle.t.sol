// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";

/// Exposes the internal hash-to-curve steps for validation against py_ecc reference vectors.
contract BlsHarness is BlsDrandOracle {
    constructor(uint256 g, uint256 p) BlsDrandOracle(g, p) { }

    function hashToG1(bytes32 m) external view returns (bytes memory) {
        return _hashToG1(m);
    }
}

/// Validates the on-chain drand verifier against a REAL quicknet beacon (round 1000), using vectors
/// generated off-chain with py_ecc. Requires evm_version = "prague" (EIP-2537 precompiles).
contract BlsDrandOracleTest is Test {
    BlsHarness oracle;

    uint64 constant ROUND = 1000;
    uint256 constant DRAND_GENESIS = 1692803367;
    uint256 constant DRAND_PERIOD = 3;

    // msg = sha256(round_be8)
    bytes32 constant MSG = 0xf652498d092acd949bad74e40683bf3824fb817980504a0c7e6722cfc5a9c0a3;

    // round-1000 signature, EIP-2537 uncompressed G1 (128 bytes)
    bytes constant SIG =
        hex"00000000000000000000000000000000144679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e390000000000000000000000000000000011f92e4521ef54f047b64b85fa98db2d46f0f44add1f60b93f8a0dbddd63b34f238657c2d93aed18b90bddd60a01b6d2";
    // the SAME beacon as drand PUBLISHES it: 48-byte compressed G1. High byte 0xb4 = 0x14 (x[0]) | 0x80
    // (compression) | 0x20 (sign: this y is the larger root). This is exactly what a drand node returns.
    bytes constant COMP =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";

    // expected hash-to-G1(MSG), EIP-2537 G1 (128 bytes)
    bytes constant H =
        hex"000000000000000000000000000000000f5a32d53837b00fbc0ee31ce9966435a41c5188a80ce9934d3c80588b6ad6f643ebda1b83ef89e44da9ced6205cdecf0000000000000000000000000000000004754d95146af4bd20a900b0494bcd1fb6406778975b4a9e38e806651736ff051ba689cf130adb29d362a1ab3214e6f7";

    function setUp() public {
        oracle = new BlsHarness(DRAND_GENESIS, DRAND_PERIOD);
    }

    function test_messageConstruction() public pure {
        assertEq(sha256(abi.encodePacked(ROUND)), MSG, "msg = sha256(round_be8)");
    }

    /// @notice The constructor's fail-closed precompile gate also probes SHA-256 (0x02) and
    ///         MODEXP (0x05) — both hard dependencies of the beacon-verify path — alongside the three BLS
    ///         precompiles. Under Foundry (evm_version = prague) all five exist, so the added probes must NOT
    ///         false-revert: a successful construction (non-empty code) proves every probe passed.
    function test_precompileGate_constructionSucceeds() public {
        BlsDrandOracle o = new BlsDrandOracle(DRAND_GENESIS, DRAND_PERIOD);
        assertGt(address(o).code.length, 0, "oracle deployed: all precompile probes (incl. SHA-256/MODEXP) passed");
    }

    function test_hashToG1_matchesReference() public view {
        assertEq(oracle.hashToG1(MSG), H, "on-chain hash-to-G1 == py_ecc reference");
    }

    function test_submitBeacon_verifiesRealBeacon() public {
        oracle.submitBeacon(ROUND, SIG, COMP);
        assertTrue(oracle.isAvailable(ROUND), "beacon accepted");
        assertEq(oracle.randomness(ROUND), keccak256(COMP), "randomness = keccak(compressed)");
    }

    /// @notice The public-verifiability guarantee: signatureOf stores Drand's EXACT published 48-byte compressed form,
    ///         so anyone can fetch round 1000 from a drand node and byte-compare it to on-chain state.
    function test_signatureOf_isDrandCanonicalCompressed() public {
        oracle.submitBeacon(ROUND, SIG, COMP);
        assertEq(oracle.signatureOf(ROUND), COMP, "signatureOf == drand's 48-byte compressed sig");
        assertEq(oracle.signatureOf(ROUND).length, 48, "stored form is the compressed encoding");
    }

    function test_rejectsTamperedSignature() public {
        bytes memory bad = SIG;
        bad[100] = bytes1(uint8(bad[100]) ^ 0x01); // flip a bit → not the valid signature
        vm.expectRevert(); // InvalidBeacon, or a precompile input/subgroup failure
        oracle.submitBeacon(ROUND, bad, COMP);
    }

    /// @notice A valid pairing but a compressed form that does not match the verified point is rejected, so
    ///         the stored bytes can only ever be the canonical compression (seed uniqueness).
    function test_rejectsMismatchedCompressed_wrongX() public {
        bytes memory badComp = COMP;
        badComp[10] = bytes1(uint8(badComp[10]) ^ 0x01); // corrupt an x byte
        vm.expectRevert(BlsDrandOracle.CompressionMismatch.selector);
        oracle.submitBeacon(ROUND, SIG, badComp);
    }

    function test_rejectsMismatchedCompressed_wrongSignBit() public {
        bytes memory badComp = COMP;
        badComp[0] = bytes1(uint8(badComp[0]) ^ 0x20); // flip the sign bit → claims the wrong y root
        vm.expectRevert(BlsDrandOracle.CompressionMismatch.selector);
        oracle.submitBeacon(ROUND, SIG, badComp);
    }

    function test_rejectsBadCompressedFlag() public {
        bytes memory badComp = COMP;
        badComp[0] = bytes1(uint8(badComp[0]) & 0x7f); // clear the compression flag
        vm.expectRevert(BlsDrandOracle.BadCompressedForm.selector);
        oracle.submitBeacon(ROUND, SIG, badComp);
    }

    function test_rejectsWrongCompressedLength() public {
        vm.expectRevert(BlsDrandOracle.BadCompressedForm.selector);
        oracle.submitBeacon(ROUND, SIG, hex"b446"); // not 48 bytes
    }

    function test_idempotentAndRoundAt() public {
        oracle.submitBeacon(ROUND, SIG, COMP);
        oracle.submitBeacon(ROUND, SIG, COMP); // no-op, no revert
        // a timestamp at/before Drand genesis reverts (fail-closed) instead of returning round 1.
        vm.expectRevert(BlsDrandOracle.TimestampBeforeGenesis.selector);
        oracle.roundAt(DRAND_GENESIS);
        assertEq(oracle.roundAt(DRAND_GENESIS + DRAND_PERIOD), 2);
    }

    /// @notice Regression lock: roundAt must return the FIRST round publishing at/AFTER `ts` (CEIL).
    ///         A floor formula returned the last round at/before ts, so a draw bound to a cutoff could settle
    ///         on a beacon that was already public up to (period-1)s before the cutoff.
    function test_roundAt_firstAtOrAfter_ceil() public view {
        uint256 ts = DRAND_GENESIS + DRAND_PERIOD + 1; // 1s into round 2's interval — deliberately unaligned
        uint64 r = oracle.roundAt(ts);
        uint256 reveal = DRAND_GENESIS + (uint256(r) - 1) * DRAND_PERIOD; // scheduled publish time of round r
        uint256 revealPrev = DRAND_GENESIS + (uint256(r) - 2) * DRAND_PERIOD;
        assertGe(reveal, ts, "round must publish at/after ts (a floor bug would publish before)");
        assertLt(revealPrev, ts, "and it is the FIRST such round");
    }
}
