// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { IPassArtRenderer } from "../src/interfaces/IPassArtRenderer.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// @notice Minimal renderer stand-in: these tests never call tokenURI, but NFTCollection now requires the
///         bound renderer to report locked() == true at construction (art frozen before binding).
contract MockLockedRenderer is IPassArtRenderer {
    function locked() external pure returns (bool) {
        return true;
    }

    function tokenURI(uint256, bool, uint8) external pure returns (string memory) {
        return "";
    }
}

/// @notice Configurable stand-in for the delegate.xyz v2 registry.
contract MockDelegateRegistry {
    mapping(bytes32 => bool) internal ok;

    function setDelegate(address to, address from, address contract_, bool v) external {
        ok[keccak256(abi.encode(to, from, contract_))] = v;
    }

    function checkDelegateForContract(address to, address from, address contract_, bytes32)
        external
        view
        returns (bool)
    {
        return ok[keccak256(abi.encode(to, from, contract_))];
    }
}

/// @notice Delegated allowlist minting: an allowlisted VAULT (A) delegates a hot wallet (B) on delegate.xyz;
///         B mints A's allocation via delegatedAllowlistMint, passes land in B, and the cap is keyed to A.
contract NFTCollectionDelegatedTest is Test {
    /// This contract stands in as the LP treasury below, and setRecipients now probes that a payout
    /// destination can actually accept ETH -- a real one must, so this one must too.
    receive() external payable { }

    NFTCollection nft;
    MockDrandOracle oracle;
    MockDelegateRegistry reg;
    MockLockedRenderer renderer;

    address vaultA = makeAddr("vaultA"); // allowlisted, kept limited
    address delegateB = makeAddr("delegateB"); // hot wallet that operates
    uint256 constant PRICE = 0.001 ether;
    uint256 constant GEN = 1_000_000;
    bytes32[] empty; // empty proof: single-leaf allowlist root == leaf

    function setUp() public {
        vm.warp(GEN);
        oracle = new MockDrandOracle(GEN, 3);
        reg = new MockDelegateRegistry();
        renderer = new MockLockedRenderer();
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        nft.setRecipients(address(this), makeAddr("seed"), makeAddr("team"));
        nft.setDelegateRegistry(address(reg)); // before opening the mint
        nft.setMintOpen(true);
        nft.setAllowlistRoot(keccak256(abi.encodePacked(vaultA))); // single-leaf allowlist = vaultA
        nft.openAllowlistMint(); // GTD window (cap 3), phase ALLOWLIST
    }

    function _delegate(bool v) internal {
        reg.setDelegate(delegateB, vaultA, address(nft), v);
    }

    // ── happy path: B mints A's allocation; passes to B, cap counted against A ──
    function test_delegatedMint_mintsToDelegate_capOnVault() public {
        _delegate(true);
        vm.deal(delegateB, PRICE * 3);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE * 3 }(3, empty, vaultA);
        assertEq(nft.balanceOf(delegateB), 3, "passes land in the delegate");
        assertEq(nft.balanceOf(vaultA), 0, "vault holds none");
        assertEq(nft.mintedBy(vaultA), 3, "allocation counted against the vault");
        assertEq(nft.mintedBy(delegateB), 0, "not against the delegate");
    }

    // ── no delegation in the registry -> NotDelegated ──
    function test_delegatedMint_revertsWithoutDelegation() public {
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── the vault must be on the allowlist (proof is the VAULT's, not the caller's) ──
    function test_delegatedMint_revertsIfVaultNotAllowlisted() public {
        address vaultC = makeAddr("vaultC"); // not the allowlisted leaf
        reg.setDelegate(delegateB, vaultC, address(nft), true);
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultC);
    }

    // ── the vault's cap is SHARED with its own direct mint: a delegate cannot exceed it ──
    function test_delegatedMint_capSharedWithVaultDirect() public {
        _delegate(true);
        vm.deal(delegateB, PRICE * 3);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE * 2 }(2, empty, vaultA); // 2 of the vault's cap-3
        assertEq(nft.mintedBy(vaultA), 2);
        // the vault mints 1 directly -> reaches cap 3; a 2nd direct mint reverts
        vm.deal(vaultA, PRICE * 2);
        vm.prank(vaultA);
        nft.allowlistMint{ value: PRICE }(1, empty);
        assertEq(nft.mintedBy(vaultA), 3);
        vm.prank(vaultA);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        nft.allowlistMint{ value: PRICE }(1, empty);
        // and the delegate also can't push past the cap
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── delegated mint is off until a registry is wired ──
    function test_delegatedMint_disabledWhenRegistryUnset() public {
        NFTCollection n2 = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n2.setRecipients(address(this), makeAddr("s2"), makeAddr("t2"));
        n2.setMintOpen(true);
        n2.setAllowlistRoot(keccak256(abi.encodePacked(vaultA)));
        n2.openAllowlistMint();
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.DelegationDisabled.selector);
        n2.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── setDelegateRegistry is write-once ──
    function test_setDelegateRegistry_writeOnce() public {
        vm.expectRevert(NFTCollection.RegistryAlreadySet.selector);
        nft.setDelegateRegistry(address(reg));
    }

    // ── a revoked delegation stops working ──
    function test_delegatedMint_respectsRevocation() public {
        _delegate(true);
        vm.deal(delegateB, PRICE * 2);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
        _delegate(false); // vault revokes on the registry
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }
}
