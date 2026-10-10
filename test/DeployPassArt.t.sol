// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployPassArt } from "../script/DeployPassArt.s.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";

/// @notice script/DeployPassArt.s.sol through its REAL `_run`, as the broadcaster,
///         with per-test env. Its ~23 transactions must never come from the NFT deployer, whose nonce the delegation-only
///         launch has already published as the NFT address.
contract DeployPassArtTest is Test, DeployPassArt {
    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => bool) internal envSet;

    function _envOrAddress(string memory key, address dflt) internal view override returns (address) {
        return envSet[keccak256(bytes(key))] ? envA[keccak256(bytes(key))] : dflt;
    }

    function _setA(string memory k, address v) internal {
        envA[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function runExt(address me) external returns (address) {
        return _run(me);
    }

    /// From another key with both addresses set: deploys, loads every chunk and locks, and the NFT deployer's nonce and
    /// the published NFT address are untouched.
    function test_deploysAndLocksTheRenderer_fromAnotherKey_nftDeployerUntouched() public {
        address me = msg.sender;
        address nftDeployer = makeAddr("nftDeployer");
        uint64 nftNonce = vm.getNonce(nftDeployer);
        address published = vm.computeCreateAddress(nftDeployer, nftNonce);
        _setA("EXPECTED_NFT_DEPLOYER", nftDeployer);
        _setA("EXPECTED_NFT_ADDRESS", published);

        PassArtRenderer r = PassArtRenderer(_run(me));
        assertTrue(r.locked(), "locked");
        assertEq(r.owner(), me, "owned by the art wallet");
        assertEq(r.chunkCount(0) + r.chunkCount(1) + r.chunkCount(2) + r.chunkCount(3) + r.chunkCount(4), 21, "21 chunks");
        assertEq(vm.getNonce(nftDeployer), nftNonce, "the NFT deployer sent nothing");
        assertEq(published.code.length, 0, "nothing at the published NFT address");
    }

    /// Refuses the key named in EXPECTED_NFT_DEPLOYER; nothing is deployed.
    function test_refusesTheNftDeployerKey() public {
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        _setA("EXPECTED_NFT_DEPLOYER", me);
        vm.expectRevert(
            bytes(
                "deploy-pass-art: this key is EXPECTED_NFT_DEPLOYER: deploy the art from a different wallet (a transaction from the NFT deployer moves the precomputed NFT address)"
            )
        );
        this.runExt(me);
        assertEq(vm.computeCreateAddress(me, n).code.length, 0, "no renderer was created from the NFT deployer");
        assertEq(vm.getNonce(me), n, "nothing was sent");
    }

    /// EXPECTED_NFT_ADDRESS without EXPECTED_NFT_DEPLOYER is refused before anything is sent.
    function test_refusesExpectedNftAddress_withoutExpectedNftDeployer() public {
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        address published = vm.computeCreateAddress(me, n);
        _setA("EXPECTED_NFT_ADDRESS", published);
        vm.expectRevert(
            bytes(
                "deploy-pass-art: EXPECTED_NFT_ADDRESS is set but EXPECTED_NFT_DEPLOYER is not: set both (the NFT deployer's address and the NFT address published for it). Nothing was sent."
            )
        );
        this.runExt(me);
        assertEq(published.code.length, 0, "nothing landed at the published NFT address");
        assertEq(vm.getNonce(me), n, "nothing was sent");
    }

    /// The key would reach EXPECTED_NFT_ADDRESS's nonce partway through its own chunk transactions (nonce + 12 of 23):
    /// not its first CREATE, but the run would still burn the published address. EXPECTED_NFT_DEPLOYER names another
    /// address (a typo), so only the address check can catch it, and it does.
    function test_refusesAKeyWhoseChunkTransactionsWouldBurnExpectedNftAddress() public {
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        _setA("EXPECTED_NFT_DEPLOYER", makeAddr("typoedNftDeployer"));
        _setA("EXPECTED_NFT_ADDRESS", vm.computeCreateAddress(me, uint256(n) + 12));
        vm.expectRevert(
            bytes(
                string.concat(
                    "deploy-pass-art: this key creates EXPECTED_NFT_ADDRESS at its nonce ",
                    vm.toString(uint256(n) + 12),
                    ", so it IS the NFT deployer (EXPECTED_NFT_DEPLOYER names another address): deploy the art from a different wallet. Nothing was sent."
                )
            )
        );
        this.runExt(me);
        assertEq(vm.getNonce(me), n, "nothing was sent");
    }
}
