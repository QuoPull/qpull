// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { MockDrandOracle } from "../test/mocks/MockDrandOracle.sol";

/// @notice Minimal testnet redeploy of the NFT + a fresh settable MockDrandOracle, using the FULLY
///         ON-CHAIN art renderer (no IPFS/baseURI). Deploy + chunk the renderer first
///         (script/DeployPassArt.s.sol) and pass its address as RENDERER_ADDR. TESTNET ONLY: it deploys
///         a settable mock oracle and deployer-derived recipients.
contract DeployNftOnly is Script {
    function run() external {
        require(block.chainid != 4663, "DeployNftOnly is testnet-only (it deploys a MockDrandOracle)");
        uint256 mintPrice = 0.0075 ether; // launch price: 0.0075 ETH (matches the site)
        uint256 revealDelay = 1 hours; // >= 1h (NFTCollection.MIN_REVEAL_DELAY); mock beacon can be set right after finalizeLaunch
        uint256 genesis = block.timestamp; // mock oracle genesis
        address renderer = vm.envAddress("RENDERER_ADDR"); // fully on-chain art
        address me = msg.sender;

        vm.startBroadcast();
        MockDrandOracle oracle = new MockDrandOracle(genesis, 3);
        NFTCollection nft = new NFTCollection(mintPrice, address(oracle), revealDelay, renderer, me);
        // 3 distinct recipients (setRecipients requires it): deployer + two derived addresses
        nft.setRecipients(me, address(uint160(me) + 1), address(uint160(me) + 2));
        nft.setMintOpen(true); // kill switch on (pass-9: orthogonal to the phase — a mint needs both)
        // pass-11: start the tiered mint (real-time windows). Single-leaf allowlist root = the deployer.
        nft.setAllowlistRoot(keccak256(abi.encodePacked(me)));
        nft.openAllowlistMint();
        vm.stopBroadcast();

        console2.log("NFT     ", address(nft));
        console2.log("Oracle  ", address(oracle));
        console2.log("owner   ", me);
        console2.log("renderer", renderer);
        console2.log("public mint closes at (unix)", nft.publicMintClosesAt());
    }
}
