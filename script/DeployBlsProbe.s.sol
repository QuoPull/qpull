// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";

/// @notice "Random Run" LIVE probe. Deploys a STANDALONE BlsDrandOracle (wired to nothing) and submits a
///         REAL drand quicknet beacon (round 1000) to prove the FULL on-chain BLS path — the constructor's
///         precompile fail-closed gate, RH's own hash-to-G1 (MAP_FP_TO_G1 + G1ADD), and the pairing
///         verification — end to end on the TARGET CHAIN's actual EIP-2537 precompiles. ~214k gas, no funds,
///         no protocol wiring. Run on testnet first, then mainnet:
///           forge script script/DeployBlsProbe.s.sol --tc DeployBlsProbe --rpc-url <RPC> --account <probe key> --broadcast
///         NEVER from the NFT deployer key: in the delegation-only launch the NFT address is published
///         in advance as CREATE(NFT deployer, nonce), and any transaction from that key before DeployNFT moves it.
///         If the precompiles/hash-to-G1/pairing are wrong on the chain, the constructor reverts
///         (PrecompileUnavailable) or submitBeacon reverts (InvalidBeacon) — fail-closed, so a passing run is
///         a real proof. A standalone helper (never wired into a deploy).
contract DeployBlsProbe is Script {
    uint64 internal constant ROUND = 1000;
    // round-1000 quicknet signature, EIP-2537 uncompressed G1 (128 bytes) — the same real vector the
    // forge suite verifies (test/BlsDrandOracle.t.sol).
    bytes internal constant SIG =
        hex"00000000000000000000000000000000144679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e390000000000000000000000000000000011f92e4521ef54f047b64b85fa98db2d46f0f44add1f60b93f8a0dbddd63b34f238657c2d93aed18b90bddd60a01b6d2";
    // the SAME round-1000 signature as drand actually publishes it: 48-byte compressed G1 (sign bit set).
    bytes internal constant COMP =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";

    function run() external {
        vm.startBroadcast();
        // constructor self-checks G1ADD/PAIRING/MAP_FP_TO_G1 and reverts if any is missing on this chain.
        BlsDrandOracle oracle = new BlsDrandOracle(1_692_803_367, 3);
        // verifies the BLS pairing against the drand group key and binds the compressed form; reverts on failure.
        oracle.submitBeacon(ROUND, SIG, COMP);
        vm.stopBroadcast();

        bytes32 rnd = oracle.randomness(ROUND);
        console2.log("BlsDrandOracle (probe):", address(oracle));
        console2.log("round 1000 available  :", oracle.isAvailable(ROUND));
        console2.logBytes32(rnd);
        require(rnd == keccak256(COMP), "randomness != keccak(compressed) -- BLS path FAILED on this chain");
        console2.log("RANDOM RUN PASSED: real drand beacon verified on-chain (precompiles + hash-to-G1 + pairing).");
    }
}
