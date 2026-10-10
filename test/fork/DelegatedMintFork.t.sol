// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../../src/NFTCollection.sol";
import { PassArtRenderer } from "../../src/nft/PassArtRenderer.sol";
import { MockDrandOracle } from "../mocks/MockDrandOracle.sol";
import { DeployNFT } from "../../script/DeployNFT.s.sol";

/// @notice delegate.xyz v2 registry, write side. `checkDelegateForContract` is what NFTCollection reads;
///         the two delegate* setters here are what a holder calls (Path 1). Same shape as the on-chain ABI.
interface IDelegateRegistryV2 {
    function delegateContract(address to, address contract_, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (bool);
}

/// @notice BOTH delegated-mint paths against the REAL delegate.xyz v2 registry on a Robinhood Chain fork.
///         The unit tests (test/NFTCollectionDelegated.t.sol) use a mock registry; this proves the flow
///         round-trips against the ACTUAL registry bytecode: vault A delegates hot wallet B (Path 1), then
///         B mints A's allocation (Path 2), with the cap keyed to A and passes landing in B. It also proves
///         the v2 ALL-scope hierarchy and revocation behave exactly as the contract assumes.
///
///         RH_RPC_URL selects the chain (defaults to RH mainnet; the registry is deployed identically on
///         mainnet and testnet). Skips cleanly if the RPC is unreachable, so it never reds a normal run.
contract DelegatedMintForkTest is Test {
    /// This contract stands in as the LP treasury below, and setRecipients now probes that a payout
    /// destination can actually accept ETH -- a real one must, so this one must too.
    receive() external payable { }

    // canonical delegate.xyz v2 registry, same address on every chain it is deployed to
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    bytes32 constant RIGHTS = bytes32(0); // "all rights"; matches the bytes32(0) NFTCollection passes
    uint256 constant PRICE = 0.001 ether;

    string rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    NFTCollection nft;
    MockDrandOracle oracle;
    IDelegateRegistryV2 reg = IDelegateRegistryV2(REGISTRY);

    address vaultA = makeAddr("vaultA"); // allowlisted cold wallet
    address delegateB = makeAddr("delegateB"); // hot wallet that mints
    bytes32[] empty; // single-leaf allowlist root == leaf, so the proof is empty

    function _reachable() internal returns (bool) {
        try vm.rpc(rpc, "eth_blockNumber", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function setUp() public {
        if (!_reachable()) {
            emit log("DelegatedMintFork: RH_RPC_URL unreachable, skipping (set a reachable Robinhood Chain RPC to run).");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc); // latest is always served (avoids the pruning-node pinned-state failure)
        require(REGISTRY.code.length > 0, "delegate.xyz v2 registry is not deployed on this chain");

        oracle = new MockDrandOracle(block.timestamp, 3);
        PassArtRenderer _rndr = new PassArtRenderer(address(this)); _rndr.lock(); // a locked renderer is required (was address(0xBEEF))
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(_rndr), address(this));
        nft.setRecipients(address(this), makeAddr("seed"), makeAddr("team"));
        nft.setDelegateRegistry(REGISTRY); // wire the REAL registry, not a mock
        nft.setMintOpen(true);
        nft.setAllowlistRoot(keccak256(abi.encodePacked(vaultA))); // single-leaf allowlist = vaultA
        nft.openAllowlistMint(); // GTD window (cap 3), ALLOWLIST phase
    }

    // ── Path 1 (delegateContract, scoped) then Path 2 (delegatedAllowlistMint): passes to B, cap to A ──
    function test_bothPaths_scoped() public {
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        assertTrue(
            reg.checkDelegateForContract(delegateB, vaultA, address(nft), RIGHTS),
            "real registry honors the scoped delegation"
        );

        vm.deal(delegateB, PRICE * 3);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE * 3 }(3, empty, vaultA);

        assertEq(nft.balanceOf(delegateB), 3, "passes land in the delegate B");
        assertEq(nft.balanceOf(vaultA), 0, "vault A holds none");
        assertEq(nft.mintedBy(vaultA), 3, "allocation counted against the vault A");
        assertEq(nft.mintedBy(delegateB), 0, "not counted against the delegate");
    }

    // ── v2 is hierarchical: a broad delegate-ALL also satisfies the per-contract check ──
    function test_allScope_alsoWorks() public {
        vm.prank(vaultA);
        reg.delegateAll(delegateB, RIGHTS, true);
        assertTrue(
            reg.checkDelegateForContract(delegateB, vaultA, address(nft), RIGHTS),
            "ALL scope covers the mint contract"
        );
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
        assertEq(nft.balanceOf(delegateB), 1);
        assertEq(nft.mintedBy(vaultA), 1);
    }

    // ── no delegation on the real registry -> NotDelegated ──
    function test_noDelegation_reverts() public {
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── revocation on the real registry stops the mint ──
    function test_revoke_reverts() public {
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        vm.deal(delegateB, PRICE * 2);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA); // works while delegated
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, false); // revoke on the real registry
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── a valid delegation for a NON-allowlisted vault still cannot mint ──
    function test_vaultNotAllowlisted_reverts() public {
        address vaultC = makeAddr("vaultC");
        vm.prank(vaultC);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultC);
    }
}

/// @notice The expected-NFT-address guard against the REAL delegate.xyz v2 registry on a read-only Robinhood Chain fork, through
///         the REAL DeployNFT._run body as the broadcaster: the delegation-only launch. A cold vault delegates a hot wallet
///         against the NFT address published in advance (CREATE(deployer, nonce), delegate.html's default scope). With
///         EXPECTED_NFT_ADDRESS set, DeployNFT lands the NFT exactly there (so that delegation mints), refuses outright if
///         the deployer nonce drifted (instead of silently deploying elsewhere and killing every scoped delegation), and
///         after a partial broadcast finishes the NFT already at the published address instead of deploying a second one.
contract DeployNFTExpectedAddressForkTest is Test, DeployNFT {
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    uint256 constant PRICE = 0.0075 ether;
    string rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => uint256) internal envU;
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

    function _envOrBool(string memory, bool dflt) internal pure override returns (bool) {
        return dflt;
    }

    function _setA(string memory k, address v) internal {
        envA[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function _setU(string memory k, uint256 v) internal {
        envU[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function runExt(address me) external returns (address) {
        return _run(me);
    }

    address me;
    address vault = makeAddr("coldVault");
    address hot = makeAddr("hotWallet");
    bytes32[] empty;
    address published;

    function _world() internal {
        try vm.rpc(rpc, "eth_blockNumber", "[]") returns (bytes memory) { }
        catch {
            emit log("DeployNFTExpectedAddressFork: RH_RPC_URL unreachable, skipping.");
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "RH mainnet fork");
        me = msg.sender; // the account DeployNFT's argless vm.startBroadcast() sends from
        assertEq(me.code.length, 0, "premise: the broadcaster is a plain key");
        vm.deal(me, 5 ether);
        // the oracle and the art come from ANOTHER wallet (this test contract), as the delegation-only launch requires
        address oracle = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        PassArtRenderer renderer = new PassArtRenderer(address(this));
        renderer.lock();
        _setU("MINT_PRICE_WEI", PRICE);
        _setU("REVEAL_DELAY", 1 hours);
        _setA("DRAND_ORACLE", oracle);
        _setA("LP_TREASURY", me);
        _setA("SEED_TREASURY", makeAddr("seedTreasury"));
        _setA("TEAM_WALLET", makeAddr("team+ops"));
        _setA("RENDERER_ADDR", address(renderer));
        _setA("DELEGATE_REGISTRY", REGISTRY);
        published = vm.computeCreateAddress(me, vm.getNonce(me));
        _setA("EXPECTED_NFT_ADDRESS", published);
        // the holder signs the scoped delegation against the PUBLISHED address, before DeployNFT runs
        vm.prank(vault);
        IDelegateRegistryV2(REGISTRY).delegateContract(hot, published, bytes32(0), true);
    }

    function _openAndMintAsDelegate(NFTCollection nft) internal {
        vm.startPrank(me);
        nft.setAllowlistRoot(keccak256(abi.encodePacked(vault)));
        nft.setMintOpen(true);
        nft.openAllowlistMint();
        vm.stopPrank();
        vm.deal(hot, PRICE);
        vm.prank(hot);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vault);
        assertEq(nft.balanceOf(hot), 1, "the delegation signed against the published address mints");
    }

    function test_fork_expected_landsAtPublished_scopedDelegationMints() public {
        _world();
        NFTCollection nft = NFTCollection(_run(me));
        assertEq(address(nft), published, "the NFT is at the published address");
        assertEq(address(nft.delegateRegistry()), REGISTRY, "wired to the real registry");
        _openAndMintAsDelegate(nft);
    }

    function test_fork_expected_nonceDrift_refused_nothingDeployed() public {
        _world();
        uint64 n = vm.getNonce(me);
        vm.setNonce(me, n + 1); // any earlier transaction from the deployer key
        vm.expectRevert(
            bytes(
                string.concat(
                    "deploy-nft: EXPECTED_NFT_ADDRESS ",
                    vm.toString(published),
                    " is not the address this deploy would create (",
                    vm.toString(vm.computeCreateAddress(me, n + 1)),
                    " at deployer nonce ",
                    vm.toString(uint256(n + 1)),
                    "): the deployer key sent a transaction first, or EXPECTED_NFT_ADDRESS is wrong. Nothing was sent."
                )
            )
        );
        this.runExt(me);
        assertEq(vm.computeCreateAddress(me, n + 1).code.length, 0, "no NFT at a drifted address");
    }

    function test_fork_expected_resumeAfterPartialBroadcast_finishesThePublishedNft() public {
        _world();
        vm.broadcast(me);
        NFTCollection first = new NFTCollection(PRICE, envA[keccak256("DRAND_ORACLE")], 1 hours, envA[keccak256("RENDERER_ADDR")], me);
        assertEq(address(first), published, "premise: the partial broadcast's CREATE landed");
        uint64 n0 = vm.getNonce(me);
        assertEq(_run(me), published, "the resume returns the published NFT");
        assertEq(vm.computeCreateAddress(me, n0).code.length, 0, "no second NFT");
        assertEq(address(first.delegateRegistry()), REGISTRY, "setDelegateRegistry sent");
        assertEq(first.lpTreasury(), me, "setRecipients sent");
        _openAndMintAsDelegate(first);
    }
}
