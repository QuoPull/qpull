// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Cross-check for tools/build-allowlist.js. The fixture below (root + proofs) was produced by
///         the builder for five addresses; here we feed it to the SAME OpenZeppelin MerkleProof library
///         the NFT uses, proving the tool's output verifies exactly on-chain. Leaf = keccak256(abi.encodePacked(addr)).
///         Regenerate with: node tools/build-allowlist.js <cfg> and paste new values if the tool changes.
contract AllowlistMerkleTest is Test {
    bytes32 constant ROOT = 0x51c195465e71d4179b88473fc3a8a2f17fd66ea392d3965ad7b80f6fd03db0dd;

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

    // ── every generated proof verifies against the root (the exact allowlistMint check) ──
    function test_member_a1() public pure {
        bytes32[] memory p = new bytes32[](3);
        p[0] = 0x2ab0a4443bbea3fbe4d0e1503d11ff1367842fb0c8b28a5c8550f27599a40751;
        p[1] = 0x0aafebc39b02f78812dd98aa2d43138e57bf2e2129476469fcffb7c1d572f346;
        p[2] = 0x6bbb60d3643be44ad565e34b4f5619d8173017bb576a5c7427d3ecdc41228efa;
        assertTrue(MerkleProof.verify(p, ROOT, _leaf(0x1111111111111111111111111111111111111111)));
    }

    function test_member_a3() public pure {
        bytes32[] memory p = new bytes32[](3);
        p[0] = 0x4cfa6af4bfa0111fd5e7625d43e84cd2d40629cf6008219d2c0e30ed48abf8b6;
        p[1] = 0x4beda981c9d34f2dd099131be6049a1d87676d227e63f4a409ee629043314b4f;
        p[2] = 0x6bbb60d3643be44ad565e34b4f5619d8173017bb576a5c7427d3ecdc41228efa;
        assertTrue(MerkleProof.verify(p, ROOT, _leaf(0x3333333333333333333333333333333333333333)));
    }

    // ── the carried odd node (address 5) has a length-1 proof and still verifies ──
    function test_member_a5_oddCarry() public pure {
        bytes32[] memory p = new bytes32[](1);
        p[0] = 0x8ea0e3a5b1bcc3d21d094be4a529068bb97ef23671d5a18bc24c5ae11cffdbf7;
        assertTrue(MerkleProof.verify(p, ROOT, _leaf(0x5555555555555555555555555555555555555555)));
    }

    // ── a non-member address cannot forge membership with someone else's proof ──
    function test_nonMember_rejected() public pure {
        bytes32[] memory p = new bytes32[](3);
        p[0] = 0x2ab0a4443bbea3fbe4d0e1503d11ff1367842fb0c8b28a5c8550f27599a40751;
        p[1] = 0x0aafebc39b02f78812dd98aa2d43138e57bf2e2129476469fcffb7c1d572f346;
        p[2] = 0x6bbb60d3643be44ad565e34b4f5619d8173017bb576a5c7427d3ecdc41228efa;
        assertFalse(MerkleProof.verify(p, ROOT, _leaf(0x9999999999999999999999999999999999999999)));
    }

    // ── single-leaf tree: root == leaf, empty proof verifies (the shape of a one-address allowlist) ──
    function test_singleLeaf_emptyProof() public pure {
        address only = 0x7777777777777777777777777777777777777777;
        bytes32 root = _leaf(only); // builder prints 0x526b134e...cf9ac17f for this address
        assertEq(root, 0x526b134eb58ba3aee0caaad9759ef7b2a1e0b26b1e4a1c606555c1eecf9ac17f);
        bytes32[] memory empty;
        assertTrue(MerkleProof.verify(empty, root, _leaf(only)));
    }
}
