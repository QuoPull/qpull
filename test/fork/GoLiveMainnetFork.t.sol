// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

/// @notice WHY THERE IS NO SOLIDITY FORK TEST OF THE LAUNCH HERE, AND WHERE THE REAL ONE LIVES.
///
///         Deploy.s.sol breaks the hook<->lock circularity by PREDICTING the lock's CREATE address:
///         `computeCreateAddress(me, getNonce(me) + 1)` (Deploy.s.sol:225). That holds under a real
///         broadcast, where each `new` is its own transaction FROM the deployer. Called in-process from
///         `forge test` through an external `deploy.run()`, msg.sender is the test contract rather than the
///         broadcaster, the nonce arithmetic does not apply, and the deploy aborts: "lock address mismatch:
///         hook.initializer would be a dead address".
///         CORRECTION: that is a property of calling run() EXTERNALLY, not of forge test. test/DeployRun.t.sol
///         inherits Deploy and runs the internal body with msg.sender == tx.origin == the broadcaster, and the
///         prediction holds in-process (locally, against stand-ins for the RH externals). What still needs the
///         multi-script anvil rehearsal below is the real RH state carried across several scripts.
///
///         THE REAL REHEARSAL: a local shell script, not shipped in this repo. It runs
///             anvil --fork-url <RH mainnet> --port 8899
///         and then drives PassArtRenderer -> BlsDrandOracle -> DeployNFT -> Deploy -> setAllowlistRoot +
///         reserveMint + openAllowlistMint -> mint -> finalizeLaunch -> GoLiveMainnet, each with
///         `--broadcast` against 127.0.0.1. State persists across invocations, which is what the real
///         launch is: several scripts carrying addresses between them. It REFUSES any non-loopback RPC.
///         Verified 2026-09-11: launchTime stamped, lock seeded, routing frozen, deployer QPULL 0, with
///         the real LP_ETH of 21 ETH. It found that GoLiveMainnet could not execute at all on Foundry
///         1.7.1 (`this.report(...)` tripping the `address(this)` script check, aborting the run AFTER the
///         launch body so the trace looked fine while the chain stayed untouched).
///
///         What a Solidity fork test CAN still do usefully is assert the premise everything else rests on:
///         that the addresses the config names are real on mainnet. That is what remains below.
contract MainnetPremiseForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant QUOTRON = 0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F; // ERC-404 core
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant QUOTRON_ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;
    address constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    function test_everyAddressTheLaunchDependsOnIsRealOnMainnet() public {
        vm.createSelectFork(RPC);
        assertGt(POOL_MANAGER.code.length, 0, "v4 PoolManager");
        assertGt(QUOTRON.code.length, 0, "QUOTRON (ERC-404 core)");
        assertGt(WETH.code.length, 0, "canonical WETH");
        assertGt(QUOTRON_ROUTER.code.length, 0, "Quotron canonical ETH router");
        assertGt(DELEGATE_REGISTRY.code.length, 0, "delegate.xyz v2 -- delegatedAllowlistMint needs it");
    }

    /// @notice anvil's default accounts are SQUATTED on RH mainnet, so on a fork they are not EOAs and
    ///         _safeMint rejects them (ERC721InvalidReceiver). Anyone writing a fork harness will reach for
    ///         them first; this is here so they find out from a named assertion instead of a mint revert.
    function test_anvilDefaultAccountsAreNotUsableAsAForkDeployer() public {
        vm.createSelectFork(RPC);
        assertGt(address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266).code.length, 0, "anvil acct 0 is squatted");
        assertGt(address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8).code.length, 0, "anvil acct 1 is squatted");
    }
}
