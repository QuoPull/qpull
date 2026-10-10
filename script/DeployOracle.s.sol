// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { console2 } from "forge-std/Script.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";
import { LaunchGuards } from "./LaunchGuards.sol";
import { NftDeployerGuard } from "./NftDeployerGuard.sol";

/// @notice PHASE 0: deploy the time-locked Drand quicknet oracle that DeployNFT burns into
///         NFTCollection as an immutable and Deploy.s.sol requires to be the same one.
///
///         FROM A WALLET OTHER THAN THE NFT DEPLOYER. The delegation-only launch publishes the NFT address in advance as
///         CREATE(NFT deployer, nonce), and any transaction from that key before DeployNFT moves the NFT. Deploying
///         the oracle is exactly such a transaction, so it must come from a different key. Set EXPECTED_NFT_DEPLOYER to
///         the NFT deployer's address and EXPECTED_NFT_ADDRESS to the published NFT address (both addresses, never keys):
///           EXPECTED_NFT_DEPLOYER=<nft deployer address> EXPECTED_NFT_ADDRESS=<published NFT address> \
///           forge script script/DeployOracle.s.sol --rpc-url rh --account <oracle key>            (simulate)
///           forge script script/DeployOracle.s.sol --rpc-url rh --account <oracle key> --broadcast --slow
///         script/NftDeployerGuard.sol then refuses, before anything is sent: EXPECTED_NFT_ADDRESS without
///         EXPECTED_NFT_DEPLOYER; a run from EXPECTED_NFT_DEPLOYER; and a run from any key that creates
///         EXPECTED_NFT_ADDRESS at a nonce this run (or the next NONCE_LOOKAHEAD) would use, which means that key is the
///         NFT deployer and the oracle would otherwise land AT the published NFT address. With EXPECTED_NFT_ADDRESS set,
///         the script also reports whether it is still CREATE(EXPECTED_NFT_DEPLOYER, its current nonce), as an early
///         warning; DeployNFT itself enforces it.
///
///         WHAT IS CHECKED, after the CREATE and before anything is printed as final: the constructor's own gates
///         (quicknet genesis 1692803367 and period 3 only; the five precompiles it needs answer on this chain), then the
///         read-back drandGenesis() / drandPeriod(), and the exact LaunchGuards.requireQuicknetOracle check DeployNFT and
///         Deploy run on DRAND_ORACLE, so an address this script prints can never be refused by them.
contract DeployOracle is NftDeployerGuard {
    function run() external {
        _run(msg.sender);
    }

    function _run(address me) internal returns (address oracle) {
        // One transaction from `me`: the oracle CREATE. The env seam (_envOrAddress) lives in NftDeployerGuard.
        (address nftDeployer, address expectedNft) = _refuseNftDeployer(me, 1, "deploy-oracle", "the oracle");

        vm.startBroadcast();
        BlsDrandOracle o = new BlsDrandOracle(LaunchGuards.DRAND_QUICKNET_GENESIS, LaunchGuards.DRAND_QUICKNET_PERIOD);
        vm.stopBroadcast();
        oracle = address(o);

        require(oracle.code.length > 0, "deploy-oracle: no code at the oracle address");
        require(o.drandGenesis() == LaunchGuards.DRAND_QUICKNET_GENESIS, "deploy-oracle: drandGenesis read-back");
        require(o.drandPeriod() == LaunchGuards.DRAND_QUICKNET_PERIOD, "deploy-oracle: drandPeriod read-back");
        LaunchGuards.requireQuicknetOracle(oracle); // the same check DeployNFT and Deploy.s.sol run on DRAND_ORACLE

        console2.log("BlsDrandOracle (drand quicknet)", oracle);
        console2.log("  drandGenesis (unix seconds)  ", o.drandGenesis());
        console2.log("  drandPeriod (seconds)        ", o.drandPeriod());
        console2.log("  roundAt(now)                 ", uint256(o.roundAt(block.timestamp)));
        console2.log("  deployed by (NOT the NFT deployer)", me);
        if (nftDeployer == address(0)) {
            console2.log("NOTE: EXPECTED_NFT_DEPLOYER unset: nothing checked that this key is not the NFT deployer");
        } else if (expectedNft != address(0)) {
            bool still = vm.computeCreateAddress(nftDeployer, vm.getNonce(nftDeployer)) == expectedNft;
            console2.log("  EXPECTED_NFT_ADDRESS still CREATE(EXPECTED_NFT_DEPLOYER, current nonce)?", still);
            if (!still) console2.log("WARNING: the NFT deployer's nonce no longer predicts EXPECTED_NFT_ADDRESS");
        }
        console2.log(string.concat("export DRAND_ORACLE=", vm.toString(oracle)));
        console2.log(
            "Next: script/DeployPassArt.s.sol with the same EXPECTED_NFT_DEPLOYER / EXPECTED_NFT_ADDRESS (not from the NFT deployer either), then script/DeployNFT.s.sol"
        );
    }
}
