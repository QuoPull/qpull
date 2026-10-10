// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

/// @notice The NFT-deployer guard for the PHASE 0 scripts that must NOT run from the NFT deployer key (DeployOracle, DeployPassArt).
///
///         The delegation-only launch publishes the NFT address X = CREATE(NFT deployer, nonce) before DeployNFT runs.
///         Any transaction from the NFT deployer before DeployNFT moves its nonce, so X can never be deployed again and
///         every scoped delegation points at nothing. Two env values describe that plan, both ADDRESSES, never keys:
///           EXPECTED_NFT_DEPLOYER   the NFT deployer's address
///           EXPECTED_NFT_ADDRESS    X, the NFT address published for it
///         `_refuseNftDeployer` refuses, before anything is broadcast:
///           (1) EXPECTED_NFT_ADDRESS set while EXPECTED_NFT_DEPLOYER is not. Without the deployer's address the key
///               check below cannot run, and a wrong --account would burn X.
///           (2) the broadcasting key IS EXPECTED_NFT_DEPLOYER.
///           (3) the broadcasting key creates X at ANY nonce from its current one through every transaction this
///               script sends plus NONCE_LOOKAHEAD more. That key is the NFT deployer whatever EXPECTED_NFT_DEPLOYER
///               says (a typo there disables check 2), and one transaction from it moves X. Before this check a run
///               from the NFT deployer at nonce 0 with only EXPECTED_NFT_ADDRESS set deployed the ORACLE at X.
///         With neither value set nothing is checked (the testnet flows), and the caller prints a note saying so.
abstract contract NftDeployerGuard is Script {
    /// @dev Nonces checked beyond the ones this script consumes. A CREATE address collision is not a practical
    ///      concern, so a match anywhere in the window means this key is the NFT deployer.
    uint256 internal constant NONCE_LOOKAHEAD = 256;

    /// @dev The env seam. Tests override it (vm.setEnv is process-wide and tests run concurrently).
    function _envOrAddress(string memory key, address dflt) internal view virtual returns (address) {
        return vm.envOr(key, dflt);
    }

    /// @param me       the broadcasting key (msg.sender of run())
    /// @param txCount  how many transactions this script will send from `me`
    /// @param tag      the script's revert prefix, e.g. "deploy-oracle"
    /// @param what     what the script deploys, e.g. "the oracle"
    function _refuseNftDeployer(address me, uint256 txCount, string memory tag, string memory what)
        internal
        view
        returns (address nftDeployer, address expectedNft)
    {
        nftDeployer = _envOrAddress("EXPECTED_NFT_DEPLOYER", address(0));
        expectedNft = _envOrAddress("EXPECTED_NFT_ADDRESS", address(0));
        if (expectedNft != address(0) && nftDeployer == address(0)) {
            revert(
                string.concat(
                    tag,
                    ": EXPECTED_NFT_ADDRESS is set but EXPECTED_NFT_DEPLOYER is not: set both (the NFT deployer's address and the NFT address published for it). Nothing was sent."
                )
            );
        }
        if (nftDeployer != address(0) && me == nftDeployer) {
            revert(
                string.concat(
                    tag,
                    ": this key is EXPECTED_NFT_DEPLOYER: deploy ",
                    what,
                    " from a different wallet (a transaction from the NFT deployer moves the precomputed NFT address)"
                )
            );
        }
        if (expectedNft != address(0)) {
            uint256 n = vm.getNonce(me);
            uint256 end = n + txCount + NONCE_LOOKAHEAD;
            for (uint256 i = n; i < end; ++i) {
                if (vm.computeCreateAddress(me, i) == expectedNft) {
                    revert(
                        string.concat(
                            tag,
                            ": this key creates EXPECTED_NFT_ADDRESS at its nonce ",
                            vm.toString(i),
                            ", so it IS the NFT deployer (EXPECTED_NFT_DEPLOYER names another address): deploy ",
                            what,
                            " from a different wallet. Nothing was sent."
                        )
                    );
                }
            }
        }
    }
}
