// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IDrandOracle } from "../interfaces/IDrandOracle.sol";

/// @title  BlsDrandOracle: trustless on-chain drand verification
/// @notice Verifies drand **quicknet** beacons (scheme `bls-unchained-g1-rfc9380`) fully on-chain
///         using the EIP-2537 BLS12-381 precompiles (confirmed live on RH). Anyone may
///         submit a beacon; only a signature that passes the pairing check against the drand group
///         key is accepted, no relayers, no trust. The sole IDrandOracle implementation the protocol
///         deploys.
///
/// @dev    quicknet: sigs on G1, pubkey on G2, period 3s. Verify: e(H(m), pk) == e(sig, G2) where
///         m = sha256(round_be8) and H is RFC-9380 hash-to-G1. submitBeacon takes BOTH the 48-byte
///         COMPRESSED sig drand publishes and its 128-byte uncompressed expansion: the pairing runs on the
///         128-byte form, the 48-byte form is bound to that verified point and stored, and the stored
///         randomness = keccak256(compressed). So signatureOf is byte-identical to drand's public archive
///         and recomputable by anyone from the beacon.
///
///         The verifier (hash-to-curve + pairing) is validated against a real beacon (round 1000)
///         via py_ecc-generated vectors in the test suite.
contract BlsDrandOracle is IDrandOracle {
    // precompiles
    address internal constant SHA256 = address(0x02);
    address internal constant MODEXP = address(0x05);
    address internal constant BLS_G1ADD = address(0x0b);
    address internal constant BLS_PAIRING = address(0x0f);
    address internal constant BLS_MAP_FP_TO_G1 = address(0x10);

    // BLS12-381 field modulus p (48 bytes)
    bytes internal constant P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    // (p-1)/2, 48 bytes. A y-coordinate is the "larger" of the two roots (compressed sign bit set) iff y > this.
    bytes internal constant HALF_P =
        hex"0d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555";

    // DST for bls-unchained-g1-rfc9380, with the trailing length byte (RFC 9380 DST_prime)
    bytes internal constant DST_PRIME =
        hex"424c535f5349475f424c53313233383147315f584d443a5348412d3235365f535357555f524f5f4e554c5f2b";

    // drand quicknet group public key (G2, 256-byte EIP-2537 uncompressed)
    bytes internal constant PK =
        hex"000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f045152730000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    // negated G2 generator (256-byte EIP-2537 uncompressed), for the product-equals-one pairing check
    bytes internal constant NEG_G2 =
        hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb80000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed";

    // A REAL drand quicknet beacon, used as a deploy-time known-answer test. Round 1000's
    // signature in the 128-byte EIP-2537 uncompressed form, the same vector test/BlsDrandOracle.t.sol
    // verifies. Its compressed form is drand's public archive value
    // b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39,
    // so anyone can refetch round 1000 from any drand node and confirm this constant is not invented.
    uint64 internal constant KAT_ROUND = 1000;
    bytes internal constant KAT_SIG =
        hex"00000000000000000000000000000000144679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e390000000000000000000000000000000011f92e4521ef54f047b64b85fa98db2d46f0f44add1f60b93f8a0dbddd63b34f238657c2d93aed18b90bddd60a01b6d2";

    uint256 public immutable drandGenesis; // 1692803367 for quicknet
    uint256 public immutable drandPeriod; // 3 for quicknet

    mapping(uint64 => bytes32) internal _rand;
    mapping(uint64 => bool) internal _ok;
    /// @notice The verified signature recorded per round, as drand's 48-byte COMPRESSED encoding, so anyone
    ///         can recompute the seed from on-chain state alone and check it against drand's public archive
    ///         for that round (public verifiability: fetch round R from any drand node, it IS these 48 bytes,
    ///         keccak them, compare to `randomness(R)`).
    mapping(uint64 => bytes) public signatureOf;

    /// @notice Highest round ever verified here. Monotonic, and the only state this
    ///         contract keeps that is not keyed by round: escape hatches elsewhere read it as evidence that
    ///         the chain produced rounds BEYOND the one they are about to discard. One SSTORE on a new high,
    ///         which is every honest post (the keeper relays forward), and none on a back-fill.
    uint64 public highestRound;

    event BeaconVerified(uint64 indexed round, bytes32 randomness);

    error BadSigLength();
    error BadCompressedForm(); // 48-byte compressed sig has the wrong length or bad flag bits
    error CompressionMismatch(); // the compressed sig is not the canonical compression of the verified point
    error InvalidBeacon();
    error PrecompileFailed();
    error TimestampBeforeGenesis();

    error BadDrandParams();
    error PrecompileUnavailable(); // a required precompile is missing at deploy
    error PrecompileKnownAnswerFailed(); // a REAL drand beacon did not verify at deploy

    constructor(uint256 drandGenesis_, uint256 drandPeriod_) {
        // Pin the drand SCHEDULE constants to quicknet, exactly like the crypto constants
        // (PK/DST/NEG_G2/P) are hardcoded. A wrong genesis/period would not revert anything (beacons still
        // verify) but would silently shift every reveal window. period==0 also panics.
        if (drandGenesis_ != 1_692_803_367 || drandPeriod_ != 3) revert BadDrandParams();
        drandGenesis = drandGenesis_;
        drandPeriod = drandPeriod_;

        // FAIL-CLOSED DEPLOY GATE. Every draw and the rarity reveal are a hard liveness
        // dependency on the EIP-2537 BLS12-381 precompiles; on a chain that lacks them a staticcall to the
        // precompile address hits an empty account and returns success with EMPTY returndata (not a revert),
        // so the absence is silent. Probe them here so this oracle can NEVER be deployed where they are
        // missing, the on-chain equivalent of script/bls_precompile_check.sh. G1ADD(inf,inf)==inf: 256 zero
        // bytes in -> a well-formed 128-byte G1 point out (absent -> 0-length). PAIRING of one infinity pair
        // == 1 (GT identity): 384 zero bytes in -> 32 bytes ending 0x01 (absent -> 0-length).
        (bool okAdd, bytes memory addOut) = BLS_G1ADD.staticcall(new bytes(256));
        if (!okAdd || addOut.length != 128) revert PrecompileUnavailable();
        (bool okPair, bytes memory pairOut) = BLS_PAIRING.staticcall(new bytes(384));
        if (!okPair || pairOut.length != 32 || pairOut[31] != 0x01) revert PrecompileUnavailable();
        // Also probe MAP_FP_TO_G1 (0x10), used by _hashToG1 on the submitBeacon path, so
        // a chain with G1ADD+PAIRING but not MAP_FP_TO_G1 would pass the gate yet fail every draw. 64 zero
        // bytes = the Fp encoding of 0 (a valid field element); map_to_curve is total -> a 128-byte G1 point.
        (bool okMap, bytes memory mapOut) = BLS_MAP_FP_TO_G1.staticcall(new bytes(64));
        if (!okMap || mapOut.length != 128) revert PrecompileUnavailable();
        // The beacon-verify path ALSO hard-depends on two universal precompiles:
        // SHA-256 (0x02), used for the message and expand_message_xmd, and MODEXP (0x05), used by _toFp for
        // the `mod p` reduction. They exist on every EVM chain, but for completeness gate them the same
        // fail-closed way so this oracle can NEVER deploy where ANY of its precompiles is missing. SHA-256:
        // any input -> a 32-byte digest (absent -> 0-length). MODEXP: 1^1 mod 2 = 1 with base/exp/mod
        // lengths all 1 (three 32-byte length words, then the value bytes 01 01 02) -> a 1-byte 0x01.
        (bool okSha, bytes memory shaOut) = SHA256.staticcall(new bytes(1));
        if (!okSha || shaOut.length != 32) revert PrecompileUnavailable();
        (bool okMod, bytes memory modOut) = MODEXP.staticcall(
            bytes.concat(bytes32(uint256(1)), bytes32(uint256(1)), bytes32(uint256(1)), hex"010102")
        );
        if (!okMod || modOut.length != 1 || modOut[0] != 0x01) revert PrecompileUnavailable();

        // Known-answer test. The five probes above prove the precompiles EXIST, but each uses a degenerate
        // input (all-zero points, 1^1 mod 2). So run the real thing once, at deploy: verify an actual drand
        // quicknet beacon through the exact path submitBeacon uses. This exercises SHA-256, MODEXP (inside
        // _toFp), MAP_FP_TO_G1 and G1ADD (inside _hashToG1) and the PAIRING, with real curve points, and fails
        // the deployment loudly if any of them is absent, stubbed or wrong. A chain that cannot verify round
        // 1000 cannot run this protocol.
        bytes memory katInput = bytes.concat(_hashToG1(sha256(abi.encodePacked(KAT_ROUND))), PK, KAT_SIG, NEG_G2);
        (bool okKat, bytes memory katOut) = BLS_PAIRING.staticcall(katInput);
        if (!okKat || katOut.length != 32 || katOut[31] != 0x01) revert PrecompileKnownAnswerFailed();
    }

    /// @notice Permissionless: submit round `round`'s drand signature in BOTH forms - the 48-byte COMPRESSED
    ///         encoding drand actually publishes (`comp`), and its 128-byte EIP-2537 UNCOMPRESSED expansion
    ///         (`sig`). The pairing is verified on `sig`; `comp` is then bound to that
    ///         verified point and stored, so `signatureOf[round]` is byte-identical to drand's public archive
    ///         and the seed is `keccak256(comp)`.
    ///
    /// @dev    WHY BOTH FORMS INSTEAD OF DECOMPRESSING ON-CHAIN: this contract is the randomness root. The
    ///         128-byte pairing path below does the verification; binding `comp` to it needs only byte
    ///         comparisons, adding NO cryptographic operation (no on-chain sqrt / field arithmetic)
    ///         to the security-critical path. `sig` is untrusted scratch: if it is not drand's real point the
    ///         pairing rejects it, and if `comp` is not the unique canonical compression of that verified
    ///         point the binding rejects it, so `comp` that is stored is provably drand's published bytes.
    ///
    ///         TWO SOUNDNESS PROPERTIES ARE DELEGATED TO THE EIP-2537 PAIRING PRECOMPILE (0x0f):
    ///
    ///         1. SUBGROUP MEMBERSHIP. Neither `H` nor `sig` is subgroup-checked here. EIP-2537's pairing
    ///            precompile validates that every input point is in the prime-order subgroup and rejects
    ///            (reverts) otherwise, so an off-subgroup "signature" can never verify. This is the correct
    ///            layer for the check: reimplementing it in Solidity would only add surface.
    ///
    ///         2. ENCODING CANONICITY => SEED UNIQUENESS. The seed is `keccak256(comp)`, and `_bindCompressed`
    ///            forces `comp` to be the ONE canonical compression of the pairing-verified point: the
    ///            compression flag set, the infinity flag clear, the 48-byte x equal to the verified point's x
    ///            (whose canonicity, x < p, the pairing precompile already enforced), and the sign bit equal to
    ///            whether the verified y exceeds (p-1)/2. Exactly one 48-byte string satisfies all four, so a
    ///            given beacon yields exactly one seed.
    function submitBeacon(uint64 round, bytes calldata sig, bytes calldata comp) external {
        if (sig.length != 128) revert BadSigLength();
        if (_ok[round]) return; // idempotent

        bytes32 m = sha256(abi.encodePacked(round)); // round as 8-byte big-endian
        bytes memory h = _hashToG1(m);

        // e(H, PK) * e(sig, -G2) == 1
        bytes memory input = bytes.concat(h, PK, sig, NEG_G2);
        (bool success, bytes memory out) = BLS_PAIRING.staticcall(input);
        if (!success || out.length != 32 || out[31] != 0x01) revert InvalidBeacon();

        // Bind drand's canonical 48-byte compressed form to the verified point, then store IT (byte-identical
        // to the drand archive) and seed from it. Reverts unless `comp` is that unique canonical compression.
        _bindCompressed(comp, sig);

        bytes32 rnd = keccak256(comp);
        _rand[round] = rnd;
        _ok[round] = true;
        signatureOf[round] = comp;
        if (round > highestRound) highestRound = round; // monotonic high-water mark
        emit BeaconVerified(round, rnd);
    }

    /// @dev Require that `comp` (48-byte compressed G1) is the unique canonical compression of the
    ///      already-pairing-verified point `sig` (128-byte EIP-2537 uncompressed). No field arithmetic: the
    ///      point's validity and x-canonicity were established by the pairing precompile; this only checks the
    ///      three metadata flag bits, that x matches, and that the sign bit matches y vs (p-1)/2.
    function _bindCompressed(bytes calldata comp, bytes calldata sig) internal pure {
        if (comp.length != 48) revert BadCompressedForm();
        uint8 b0 = uint8(comp[0]);
        if (b0 & 0x80 == 0) revert BadCompressedForm(); // compression flag MUST be set
        if (b0 & 0x40 != 0) revert BadCompressedForm(); // infinity flag MUST be clear (a real signature)
        // x from `comp` (top 3 flag bits cleared) must equal x from the verified point: sig[16..64).
        if (bytes1(b0 & 0x1f) != sig[16]) revert CompressionMismatch();
        for (uint256 i = 1; i < 48; ++i) {
            if (comp[i] != sig[16 + i]) revert CompressionMismatch();
        }
        // sign bit (bit 5) set iff the verified y = sig[80..128) is the larger root, i.e. y > (p-1)/2.
        bool signSet = (b0 & 0x20) != 0;
        if (signSet != _yExceedsHalfP(sig)) revert CompressionMismatch();
    }

    /// @dev Big-endian compare of the verified y-coordinate (sig[80..128), 48 bytes) against (p-1)/2.
    function _yExceedsHalfP(bytes calldata sig) internal pure returns (bool) {
        bytes memory half = HALF_P;
        for (uint256 i; i < 48; ++i) {
            uint8 y = uint8(sig[80 + i]);
            uint8 h = uint8(half[i]);
            if (y != h) return y > h;
        }
        return false; // exactly (p-1)/2 is not "larger"
    }

    // ─── RFC 9380 hash-to-G1 (expand_message_xmd + map_to_curve ×2 + add) ─────

    function _hashToG1(bytes32 m) internal view returns (bytes memory) {
        bytes memory b = _expandMessageXmd(m); // 128 bytes
        bytes memory q0 = _mapToG1(_toFp(b, 0));
        bytes memory q1 = _mapToG1(_toFp(b, 64));
        (bool s, bytes memory h) = BLS_G1ADD.staticcall(bytes.concat(q0, q1));
        if (!s || h.length != 128) revert PrecompileFailed();
        return h;
    }

    /// expand_message_xmd(SHA-256), len=128 → ell=4.
    function _expandMessageXmd(bytes32 m) internal pure returns (bytes memory) {
        bytes memory zpad = new bytes(64); // s_in_bytes zeros
        bytes32 b0 = sha256(bytes.concat(zpad, m, hex"0080", hex"00", DST_PRIME));
        bytes32 b1 = sha256(bytes.concat(b0, hex"01", DST_PRIME));
        bytes32 b2 = sha256(bytes.concat(b0 ^ b1, hex"02", DST_PRIME));
        bytes32 b3 = sha256(bytes.concat(b0 ^ b2, hex"03", DST_PRIME));
        bytes32 b4 = sha256(bytes.concat(b0 ^ b3, hex"04", DST_PRIME));
        return bytes.concat(b1, b2, b3, b4);
    }

    /// 64-byte chunk of `b` at `off` → field element mod p, EIP-2537 Fp (16 zero pad + 48-byte value).
    function _toFp(bytes memory b, uint256 off) internal view returns (bytes memory) {
        bytes memory chunk = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            chunk[i] = b[off + i];
        }
        // modexp(chunk, 1, p) = chunk mod p (48-byte output)
        bytes memory input =
            bytes.concat(bytes32(uint256(64)), bytes32(uint256(1)), bytes32(uint256(48)), chunk, hex"01", P);
        (bool s, bytes memory res) = MODEXP.staticcall(input);
        if (!s || res.length != 48) revert PrecompileFailed();
        return bytes.concat(new bytes(16), res); // pad to 64
    }

    function _mapToG1(bytes memory fp) internal view returns (bytes memory) {
        (bool s, bytes memory q) = BLS_MAP_FP_TO_G1.staticcall(fp);
        if (!s || q.length != 128) revert PrecompileFailed();
        return q;
    }

    // ─── IDrandOracle ────────────────────────────────────────────────────────

    function isAvailable(uint64 round) external view returns (bool) {
        return _ok[round];
    }

    function randomness(uint64 round) external view returns (bytes32) {
        require(_ok[round], "unavailable");
        return _rand[round];
    }

    function roundAt(uint256 timestamp) external view returns (uint64) {
        // REVERT rather than fail open: a timestamp at/before drand genesis (Aug 2023) would otherwise bind
        // a draw to round 1, a beacon that is already public. Unreachable in normal use (every consumer's
        // cutoff is the protocol genesis plus a lag, far past drandGenesis).
        if (timestamp <= drandGenesis) revert TimestampBeforeGenesis();
        // First round whose scheduled publish time is at/AFTER `timestamp` (CEIL), per IDrandOracle.
        // A FLOOR here would bind a draw to the round that publishes up to (period-1)s BEFORE the cutoff,
        // so the settling beacon could be public while entries/snapshots for that draw are still open.
        // Ceil guarantees reveal(roundAt(cutoff)) >= cutoff.
        return uint64((timestamp - drandGenesis + drandPeriod - 1) / drandPeriod) + 1;
    }
}
