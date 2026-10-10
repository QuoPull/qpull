// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployOracle } from "../script/DeployOracle.s.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";

/// @notice script/DeployOracle.s.sol through its REAL `_run`, as the broadcaster, with per-test env.
contract DeployOracleTest is Test, DeployOracle {
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

    /// Deploys the quicknet oracle and reads it back; the NFT deployer's nonce (a different key) never moves.
    function test_deploysTheQuicknetOracle_fromAnotherKey_nftDeployerNonceUntouched() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        address nftDeployer = makeAddr("nftDeployer");
        _setA("EXPECTED_NFT_DEPLOYER", nftDeployer);
        address published = vm.computeCreateAddress(nftDeployer, vm.getNonce(nftDeployer));
        _setA("EXPECTED_NFT_ADDRESS", published);
        uint64 nftNonce = vm.getNonce(nftDeployer);

        BlsDrandOracle o = BlsDrandOracle(_run(me));
        assertGt(address(o).code.length, 0, "deployed");
        assertEq(o.drandGenesis(), 1_692_803_367, "quicknet genesis");
        assertEq(o.drandPeriod(), 3, "quicknet period");
        assertEq(o.roundAt(1_692_803_367 + 3), 2, "the real round arithmetic");
        assertEq(vm.getNonce(nftDeployer), nftNonce, "the NFT deployer sent nothing");
        assertEq(vm.computeCreateAddress(nftDeployer, vm.getNonce(nftDeployer)), published, "the published NFT address still holds");
    }

    /// Refuses to run from the NFT deployer when EXPECTED_NFT_DEPLOYER names it; nothing is deployed.
    function test_refusesTheNftDeployerKey() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        _setA("EXPECTED_NFT_DEPLOYER", me);
        uint64 n = vm.getNonce(me);
        vm.expectRevert(
            bytes(
                "deploy-oracle: this key is EXPECTED_NFT_DEPLOYER: deploy the oracle from a different wallet (a transaction from the NFT deployer moves the precomputed NFT address)"
            )
        );
        this.runExt(me);
        assertEq(vm.computeCreateAddress(me, n).code.length, 0, "no oracle was created from the NFT deployer");
    }

    /// Without EXPECTED_NFT_DEPLOYER or EXPECTED_NFT_ADDRESS it still deploys (and says nothing was checked). It also
    /// pins the premise of the address check below: the oracle lands at CREATE(broadcaster, its nonce before the run).
    function test_unsetExpectedDeployer_stillDeploys() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        address predicted = vm.computeCreateAddress(me, vm.getNonce(me));
        address o = _run(me);
        assertEq(BlsDrandOracle(o).drandPeriod(), 3);
        assertEq(o, predicted, "the oracle lands at CREATE(broadcaster, current nonce)");
    }

    /// EXPECTED_NFT_ADDRESS without EXPECTED_NFT_DEPLOYER is refused before anything
    /// is sent. The case this pins: the NFT deployer key at the published nonce with only the address set used to deploy
    /// the oracle AT the published NFT address, printing just a NOTE.
    function test_refusesExpectedNftAddress_withoutExpectedNftDeployer() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        address published = vm.computeCreateAddress(me, n); // this key IS the NFT deployer, and nothing names it
        _setA("EXPECTED_NFT_ADDRESS", published);
        vm.expectRevert(
            bytes(
                "deploy-oracle: EXPECTED_NFT_ADDRESS is set but EXPECTED_NFT_DEPLOYER is not: set both (the NFT deployer's address and the NFT address published for it). Nothing was sent."
            )
        );
        this.runExt(me);
        assertEq(published.code.length, 0, "nothing landed at the published NFT address");
        assertEq(vm.getNonce(me), n, "the key's nonce did not move");
    }

    /// The broadcaster's next CREATE is EXPECTED_NFT_ADDRESS, so it IS the NFT deployer
    /// even though EXPECTED_NFT_DEPLOYER names another address (a typo there). Refused before anything is sent, and the
    /// published address stays free.
    function test_refusesWhenTheOracleWouldLandOnExpectedNftAddress() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        address published = vm.computeCreateAddress(me, n);
        _setA("EXPECTED_NFT_DEPLOYER", makeAddr("typoedNftDeployer"));
        _setA("EXPECTED_NFT_ADDRESS", published);
        vm.expectRevert(
            bytes(
                string.concat(
                    "deploy-oracle: this key creates EXPECTED_NFT_ADDRESS at its nonce ",
                    vm.toString(uint256(n)),
                    ", so it IS the NFT deployer (EXPECTED_NFT_DEPLOYER names another address): deploy the oracle from a different wallet. Nothing was sent."
                )
            )
        );
        this.runExt(me);
        assertEq(published.code.length, 0, "no oracle at the published NFT address");
        assertEq(vm.getNonce(me), n, "the NFT deployer's nonce did not move");
    }

    /// The same check looks ahead: a key that would create EXPECTED_NFT_ADDRESS a few nonces from now is the NFT deployer
    /// too (any transaction from it shifts that nonce), so it is refused as well.
    function test_refusesAKeyThatCreatesExpectedNftAddressAtALaterNonce() public {
        vm.warp(1_800_000_000);
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        _setA("EXPECTED_NFT_DEPLOYER", makeAddr("typoedNftDeployer"));
        _setA("EXPECTED_NFT_ADDRESS", vm.computeCreateAddress(me, uint256(n) + 7));
        vm.expectRevert(
            bytes(
                string.concat(
                    "deploy-oracle: this key creates EXPECTED_NFT_ADDRESS at its nonce ",
                    vm.toString(uint256(n) + 7),
                    ", so it IS the NFT deployer (EXPECTED_NFT_DEPLOYER names another address): deploy the oracle from a different wallet. Nothing was sent."
                )
            )
        );
        this.runExt(me);
        assertEq(vm.getNonce(me), n, "nothing was sent");
    }
}
