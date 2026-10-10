// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { DeployNFT } from "../script/DeployNFT.s.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";

/// A contract wallet that accepts ETH (a Safe's shape, for the override).
contract DNPayableWallet {
    receive() external payable { }
}

/// A contract that refuses ETH.
contract DNRefusingWallet {
    receive() external payable {
        revert("no");
    }
}

/// The one read NFTCollection.setDelegateRegistry probes (a delegate.xyz v2 stand-in).
contract DNRegistry {
    function checkDelegateForContract(address, address, address, bytes32) external pure returns (bool) {
        return false;
    }
}

/// @notice SEED_TREASURY as a separate regular wallet (owner's choice), through the REAL DeployNFT body: `_preflight`
///         and the whole `_run` (NFTCollection construction, setRecipients) as the broadcaster, with per-test env.
contract DeployNFTPreflightTest is Test, DeployNFT {
    uint256 constant NOW = 1_800_000_000;

    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => uint256) internal envU;
    mapping(bytes32 => bool) internal envB;
    mapping(bytes32 => bool) internal envSet;

    function _envAddress(string memory key) internal view override returns (address) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envA[keccak256(bytes(key))];
    }

    function _envUint(string memory key) internal view override returns (uint256) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envU[keccak256(bytes(key))];
    }

    function _envOrAddress(string memory key, address dflt) internal view override returns (address) {
        return envSet[keccak256(bytes(key))] ? envA[keccak256(bytes(key))] : dflt;
    }

    function _envOrBool(string memory key, bool dflt) internal view override returns (bool) {
        return envSet[keccak256(bytes(key))] ? envB[keccak256(bytes(key))] : dflt;
    }

    function _setA(string memory k, address v) internal {
        envA[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function _setU(string memory k, uint256 v) internal {
        envU[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function _setB(string memory k, bool v) internal {
        envB[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function runExt(address broadcaster) external returns (address) {
        return _run(broadcaster);
    }

    address me;
    address seed = makeAddr("seedTreasury");
    address team = makeAddr("team+ops");

    function _world() internal {
        vm.warp(NOW);
        me = msg.sender; // the broadcaster
        address oracle = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        PassArtRenderer renderer = new PassArtRenderer(address(this));
        renderer.lock();
        _setU("MINT_PRICE_WEI", 0.0075 ether);
        _setU("REVEAL_DELAY", 1 hours);
        _setA("DRAND_ORACLE", oracle);
        _setA("LP_TREASURY", me);
        _setA("SEED_TREASURY", seed);
        _setA("TEAM_WALLET", team);
        _setA("RENDERER_ADDR", address(renderer));
    }

    function _expect(bytes memory reason) internal {
        vm.expectRevert(reason);
        this.runExt(me);
    }

    /// A regular seed wallet passes, and the whole run deploys with the three recipients as declared.
    function test_regularSeedWallet_passes_andRecipientsAreFrozenAsDeclared() public {
        _world();
        assertEq(tx.origin, me, "premise: the broadcaster");
        uint256 seedBal = seed.balance;
        NFTCollection nft = NFTCollection(_run(me));
        assertEq(nft.lpTreasury(), me, "LP bucket to the deployer key");
        assertEq(nft.seedTreasury(), seed, "prize seed to SEED_TREASURY");
        assertEq(nft.team(), team, "team + operations to TEAM_WALLET");
        assertEq(seed.balance, seedBal, "the 1-wei probe was simulation only (reverted)");
    }

    function test_seedTreasury_mustBeDistinctFromTheDeployerKeyAndTeam() public {
        _world();
        _setA("SEED_TREASURY", me);
        _expect(bytes("deploy-nft: SEED_TREASURY must not be the deployer key (LP_TREASURY)"));
        _setA("SEED_TREASURY", team);
        _expect(bytes("deploy-nft: SEED_TREASURY must not be TEAM_WALLET (the team + operations share)"));
        _setA("SEED_TREASURY", address(0));
        _expect(bytes("deploy-nft: SEED_TREASURY unset"));
        _setA("SEED_TREASURY", address(0x64)); // ArbSys: a precompile, not a wallet
        _expect(bytes("deploy-nft: SEED_TREASURY is a precompile or system address, not a wallet"));
        _setA("SEED_TREASURY", seed);
        _setA("TEAM_WALLET", me);
        _expect(bytes("deploy-nft: TEAM_WALLET must not be the deployer key (LP_TREASURY)"));
    }

    /// No code unless the override is set; with the override, code is REQUIRED; either way it must take ETH.
    function test_seedTreasury_code_andTheExplicitOverride() public {
        _world();
        address safeLike = address(new DNPayableWallet());
        _setA("SEED_TREASURY", safeLike);
        _expect(bytes("deploy-nft: SEED_TREASURY has code; it must be a regular wallet (SEED_TREASURY_ALLOW_CONTRACT=true for a Safe)"));

        _setB("SEED_TREASURY_ALLOW_CONTRACT", true);
        NFTCollection nft = NFTCollection(_run(me));
        assertEq(nft.seedTreasury(), safeLike, "the override admits a contract wallet that takes ETH");

        _setA("SEED_TREASURY", seed); // a plain wallet with the override still on
        _expect(bytes("deploy-nft: SEED_TREASURY_ALLOW_CONTRACT=true but SEED_TREASURY has no code (unset the override for a plain wallet)"));

        _setA("SEED_TREASURY", address(new DNRefusingWallet()));
        _expect(bytes("deploy-nft: SEED_TREASURY cannot receive ETH (a 1-wei probe reverted)"));

        // an EIP-7702-delegated account carries the 0xef0100 designator as code: not a regular wallet
        _setB("SEED_TREASURY_ALLOW_CONTRACT", false);
        address delegated = makeAddr("delegated7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(safeLike)));
        _setA("SEED_TREASURY", delegated);
        _expect(bytes("deploy-nft: SEED_TREASURY has code; it must be a regular wallet (SEED_TREASURY_ALLOW_CONTRACT=true for a Safe)"));
    }

    /// The existing guards still hold: LP_TREASURY is the broadcaster, and the oracle is the quicknet one.
    function test_lpTreasuryAndOracle_guards() public {
        _world();
        _setA("LP_TREASURY", makeAddr("elsewhere"));
        _expect(bytes("deploy-nft: LP_TREASURY must be the deployer key that runs GoLiveMainnet (use --account / --sender)"));
        _setA("LP_TREASURY", me);
        _setA("DRAND_ORACLE", makeAddr("codelessOracle"));
        _expect(bytes("launch: DRAND_ORACLE has no code"));
    }

    // ── EXPECTED_NFT_ADDRESS (the delegation-only launch) ───────────────────────────────────────────────────

    address registry;

    /// The world plus a registry and EXPECTED_NFT_ADDRESS = CREATE(deployer, current nonce), as published.
    function _expectedWorld() internal returns (address published) {
        _world();
        registry = address(new DNRegistry());
        _setA("DELEGATE_REGISTRY", registry);
        published = vm.computeCreateAddress(me, vm.getNonce(me));
        _setA("EXPECTED_NFT_ADDRESS", published);
    }

    function _driftMessage(address expected, uint64 nonce) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                "deploy-nft: EXPECTED_NFT_ADDRESS ",
                vm.toString(expected),
                " is not the address this deploy would create (",
                vm.toString(vm.computeCreateAddress(me, nonce)),
                " at deployer nonce ",
                vm.toString(uint256(nonce)),
                "): the deployer key sent a transaction first, or EXPECTED_NFT_ADDRESS is wrong. Nothing was sent."
            )
        );
    }

    /// Control: the key sent nothing first, so the NFT lands exactly at the published address with the registry wired.
    function test_expected_untouchedNonce_landsAtThePublishedAddress() public {
        address published = _expectedWorld();
        NFTCollection nft = NFTCollection(_run(me));
        assertEq(address(nft), published, "the NFT is at the published address");
        assertEq(address(nft.delegateRegistry()), registry, "the registry is wired");
        assertEq(nft.lpTreasury(), me, "recipients set");
    }

    /// The deployer key sent one transaction first: the run refuses, naming the drift, and deploys nothing.
    function test_expected_refusesWhenTheDeployerNonceMoved() public {
        address published = _expectedWorld();
        uint64 n = vm.getNonce(me);
        vm.setNonce(me, n + 1); // any earlier transaction from the deployer key
        _expect(_driftMessage(published, n + 1));
        assertEq(published.code.length, 0, "nothing deployed at the published address");
        assertEq(vm.computeCreateAddress(me, n + 1).code.length, 0, "nor at the drifted one");
    }

    /// A typo'd EXPECTED_NFT_ADDRESS is refused the same way.
    function test_expected_refusesAWrongAddress() public {
        _expectedWorld();
        address wrong = makeAddr("notTheDeployerCreate");
        _setA("EXPECTED_NFT_ADDRESS", wrong);
        _expect(_driftMessage(wrong, vm.getNonce(me)));
    }

    /// EXPECTED_NFT_ADDRESS without DELEGATE_REGISTRY is refused: the delegation-only launch needs the registry.
    function test_expected_requiresDelegateRegistry() public {
        _expectedWorld();
        envSet[keccak256("DELEGATE_REGISTRY")] = false;
        _expect(bytes("deploy-nft: EXPECTED_NFT_ADDRESS is set but DELEGATE_REGISTRY is not (a delegation-only launch needs the registry)"));
    }

    /// A deployer with code (the EIP-7702 designator) is refused: its delegate could move the nonce.
    function test_expected_refusesADeployerWithCode() public {
        _expectedWorld();
        vm.etch(me, abi.encodePacked(hex"ef0100", address(new DNPayableWallet())));
        _expect(bytes("deploy-nft: the deployer account has code (an EIP-7702 delegate can move its nonce): use a plain key with no code"));
        vm.etch(me, "");
    }

    /// On Robinhood Chain mainnet the registry must be the canonical delegate.xyz v2 registry the delegation page uses.
    function test_expected_onMainnet_requiresTheCanonicalRegistry() public {
        _expectedWorld();
        vm.chainId(4663);
        _expect(bytes("deploy-nft: DELEGATE_REGISTRY is not the canonical delegate.xyz v2 registry the delegation page writes to"));
        assertEq(DELEGATE_XYZ_V2, 0x00000000000000447e69651d841bD8D104Bed493, "the pinned registry");
    }

    /// Without EXPECTED_NFT_ADDRESS nothing changes: a moved nonce still deploys (no pin was requested).
    function test_noExpected_unchanged() public {
        _world();
        vm.setNonce(me, vm.getNonce(me) + 3);
        NFTCollection nft = NFTCollection(_run(me));
        assertEq(nft.lpTreasury(), me, "deployed as before");
    }

    /// RESUME: a partial broadcast landed only the CREATE. The re-run finishes THAT NFT (setRecipients and
    /// setDelegateRegistry) and deploys no second one.
    function test_resume_createOnly_finishesConfiguration_noSecondNft() public {
        address published = _expectedWorld();
        vm.broadcast(me);
        NFTCollection first = new NFTCollection(0.0075 ether, envA[keccak256("DRAND_ORACLE")], 1 hours, envA[keccak256("RENDERER_ADDR")], me);
        assertEq(address(first), published, "premise: the partial broadcast's CREATE landed at the published address");
        assertEq(first.lpTreasury(), address(0), "premise: unconfigured");
        uint64 n0 = vm.getNonce(me);

        address got = _run(me);
        assertEq(got, published, "the run returns the published NFT");
        assertEq(vm.computeCreateAddress(me, n0).code.length, 0, "no second NFT at the next CREATE address");
        assertEq(first.lpTreasury(), me, "setRecipients sent");
        assertEq(first.seedTreasury(), seed, "seed");
        assertEq(first.team(), team, "team");
        assertEq(address(first.delegateRegistry()), registry, "setDelegateRegistry sent");
    }

    /// RESUME: CREATE and setRecipients landed; only the registry is missing, and only it is sent.
    function test_resume_recipientsSet_sendsOnlyTheRegistry() public {
        address published = _expectedWorld();
        vm.startBroadcast(me);
        NFTCollection first = new NFTCollection(0.0075 ether, envA[keccak256("DRAND_ORACLE")], 1 hours, envA[keccak256("RENDERER_ADDR")], me);
        first.setRecipients(me, seed, team);
        vm.stopBroadcast();
        assertEq(address(first), published);
        _run(me);
        assertEq(address(first.delegateRegistry()), registry, "the missing registry was sent");
    }

    /// RESUME: everything already landed. The run verifies and sends nothing (the deployer nonce does not move).
    function test_resume_fullyConfigured_sendsNothing() public {
        _expectedWorld();
        _run(me); // the original, complete run
        uint64 n = vm.getNonce(me);
        _run(me); // re-run with the same env: resume path, nothing missing
        assertEq(vm.getNonce(me), n, "no transaction was sent");
    }

    /// RESUME refusals: code that is not this env's NFTCollection, an NFT this key did not create, an NFT it does not
    /// own, recipients that differ from the env, and a different write-once registry.
    function test_resume_refusals() public {
        address published = _expectedWorld();
        address oracle = envA[keccak256("DRAND_ORACLE")];
        address renderer = envA[keccak256("RENDERER_ADDR")];
        uint256 snap = vm.snapshotState();

        // (a) not NFTCollection at all
        vm.broadcast(me);
        address notNft = address(new DNPayableWallet());
        assertEq(notNft, published);
        bytes memory notNftReason = bytes(
            "deploy-nft: resume: the code at EXPECTED_NFT_ADDRESS is not NFTCollection built with MINT_PRICE_WEI / DRAND_ORACLE / REVEAL_DELAY / RENDERER_ADDR"
        );
        _expect(notNftReason);
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (b) our NFTCollection, but built with a different mint price than the env
        vm.broadcast(me);
        new NFTCollection(0.01 ether, oracle, 1 hours, renderer, me);
        _expect(notNftReason);
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (c) an identical NFTCollection that some other account created
        address other = makeAddr("otherCreator");
        vm.prank(other);
        address foreign = address(new NFTCollection(0.0075 ether, oracle, 1 hours, renderer, me));
        _setA("EXPECTED_NFT_ADDRESS", foreign);
        _expect(bytes("deploy-nft: resume: EXPECTED_NFT_ADDRESS was not created by this deployer key"));
        _setA("EXPECTED_NFT_ADDRESS", published);
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (d) created by this key but owned by someone else
        vm.broadcast(me);
        new NFTCollection(0.0075 ether, oracle, 1 hours, renderer, other);
        _expect(bytes("deploy-nft: resume: the NFT is not owned by this deployer key"));
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (e) recipients already set to different wallets
        vm.startBroadcast(me);
        NFTCollection e = new NFTCollection(0.0075 ether, oracle, 1 hours, renderer, me);
        e.setRecipients(me, makeAddr("otherSeed"), team);
        vm.stopBroadcast();
        _expect(bytes("deploy-nft: resume: the NFT's recipients differ from LP_TREASURY / SEED_TREASURY / TEAM_WALLET"));
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (f) bound (write-once) to a different registry
        vm.startBroadcast(me);
        NFTCollection f = new NFTCollection(0.0075 ether, oracle, 1 hours, renderer, me);
        f.setDelegateRegistry(address(new DNRegistry()));
        vm.stopBroadcast();
        _expect(bytes("deploy-nft: resume: the NFT is bound (write-once) to a different delegate registry than DELEGATE_REGISTRY"));
        vm.revertToState(snap);
        snap = vm.snapshotState();

        // (g) a pending ownership transfer
        vm.startBroadcast(me);
        NFTCollection g = new NFTCollection(0.0075 ether, oracle, 1 hours, renderer, me);
        g.transferOwnership(other);
        vm.stopBroadcast();
        _expect(bytes("deploy-nft: resume: the NFT has a pending ownership transfer"));
    }
}
