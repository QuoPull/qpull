// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { console2 } from "forge-std/Script.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { NftDeployerGuard } from "./NftDeployerGuard.sol";

/// @notice Deploy the fully on-chain art renderer and load the tier + sealed SVG blobs into it as SSTORE2
///         chunks, then lock it. Run this FIRST; pass the printed address to the NFT deploy as RENDERER_ADDR.
///
/// @dev    Blobs live at web/art/onchain/{common,uncommon,rare,superrare}.inner (the tier dot-field inner
///         content) and sealed.svg (the full sealed tile), produced from the master SVGs. Each is split into
///         <=24,000-byte chunks (under the 24,576 runtime-code limit). ~22 chunk txs; ~$12 at 0.04 gwei.
///
///         NOT FROM THE NFT DEPLOYER. Every one of this script's ~23 transactions
///         moves the sending key's nonce, so run from the NFT deployer it burns the NFT address published for the
///         delegation-only launch. Pass the same two addresses DeployOracle takes and script/NftDeployerGuard.sol refuses
///         before anything is sent (EXPECTED_NFT_ADDRESS without EXPECTED_NFT_DEPLOYER; a run from EXPECTED_NFT_DEPLOYER;
///         a run from any key that creates EXPECTED_NFT_ADDRESS at a nonce this run would use, or the next
///         NONCE_LOOKAHEAD):
///           EXPECTED_NFT_DEPLOYER=<nft deployer address> EXPECTED_NFT_ADDRESS=<published NFT address> \
///           forge script script/DeployPassArt.s.sol --rpc-url rh --account <art key>                 (simulate)
///           forge script script/DeployPassArt.s.sol --rpc-url rh --account <art key> --broadcast --slow
///         With neither set (testnet flows) nothing is checked and the script prints a note saying so.
contract DeployPassArt is NftDeployerGuard {
    uint256 internal constant CHUNK = 24_000;

    function run() external {
        _run(msg.sender);
    }

    /// @dev `me` is the broadcasting key (msg.sender of run()); test/DeployPassArt.t.sol drives this body directly.
    function _run(address me) internal returns (address) {
        // slot order MUST match PassArtRenderer: 0=common,1=uncommon,2=rare,3=superrare,4=sealed
        bytes memory common = vm.readFileBinary("web/art/onchain/common.inner");
        bytes memory uncommon = vm.readFileBinary("web/art/onchain/uncommon.inner");
        bytes memory rare = vm.readFileBinary("web/art/onchain/rare.inner");
        bytes memory superrare = vm.readFileBinary("web/art/onchain/superrare.inner");
        bytes memory sealedSvg = vm.readFileBinary("web/art/onchain/sealed.svg");

        // Transactions from `me`: the renderer CREATE, one addChunk per chunk, and lock().
        uint256 txCount = 2 + _chunks(common.length) + _chunks(uncommon.length) + _chunks(rare.length)
            + _chunks(superrare.length) + _chunks(sealedSvg.length);
        (address nftDeployer,) = _refuseNftDeployer(me, txCount, "deploy-pass-art", "the art");

        vm.startBroadcast();
        PassArtRenderer renderer = new PassArtRenderer(me);
        _load(renderer, 0, common);
        _load(renderer, 1, uncommon);
        _load(renderer, 2, rare);
        _load(renderer, 3, superrare);
        _load(renderer, 4, sealedSvg);
        renderer.lock();
        vm.stopBroadcast();

        console2.log("PassArtRenderer", address(renderer));
        console2.log("  common   chunks", renderer.chunkCount(0));
        console2.log("  uncommon chunks", renderer.chunkCount(1));
        console2.log("  rare     chunks", renderer.chunkCount(2));
        console2.log("  superrare chunks", renderer.chunkCount(3));
        console2.log("  sealed   chunks", renderer.chunkCount(4));
        if (nftDeployer == address(0)) {
            console2.log("NOTE: EXPECTED_NFT_DEPLOYER unset: nothing checked that this key is not the NFT deployer");
        }
        console2.log(string.concat("export RENDERER_ADDR=", vm.toString(address(renderer))));
        return address(renderer);
    }

    function _chunks(uint256 len) internal pure returns (uint256) {
        return (len + CHUNK - 1) / CHUNK;
    }

    function _load(PassArtRenderer renderer, uint8 slot, bytes memory data) internal {
        uint256 off;
        while (off < data.length) {
            uint256 len = data.length - off;
            if (len > CHUNK) len = CHUNK;
            renderer.addChunk(slot, _slice(data, off, len));
            off += len;
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
