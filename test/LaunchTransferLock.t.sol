// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// Minimal stand-in for QpullTaxHook's read surface used by the NFT launch transfer-lock. Lets a test drive
/// the launch window (launchTime + GATE_DURATION) and the per-wallet "made a gated buy" flag (earlyBuyer).
contract MockTaxHook {
    uint256 public launchTime;
    uint256 public GATE_DURATION = 1 hours; // mirrors the mainnet QpullTaxHook
    mapping(address => uint32) internal _buys;

    function setLaunchTime(uint256 t) external { launchTime = t; }
    function setBuys(address a, uint32 n) external { _buys[a] = n; }
    function earlyBuyer(address a) external view returns (uint64 lastBuyAt, uint32 buys) { return (0, _buys[a]); }
}

/// @notice spec §16 anti-Sybil: while the hook's launch buy-gate is open, a wallet that has made a gated buy
///         cannot transfer its passes out, so one pass can never be shuffled to unlock a second buying wallet.
contract LaunchTransferLockTest is Test {
    NFTCollection nft;
    MockDrandOracle oracle;
    PassArtRenderer renderer;
    MockTaxHook hook;

    address alice = makeAddr("alice"); // becomes a flagged buyer
    address bob = makeAddr("bob"); // a holder who never buys
    address carol = makeAddr("carol"); // a transfer target
    address lp = makeAddr("lp");
    address seed = makeAddr("seed");
    address team = makeAddr("team");

    uint256 constant PRICE = 0.1 ether;
    uint256 constant GENESIS = 1_000_000;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        renderer = new PassArtRenderer(address(this));
        renderer.lock(); // the NFTCollection ctor requires a locked renderer
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        nft.setRecipients(lp, seed, team);
        nft.setAllowlistRoot(keccak256(abi.encodePacked(address(this)))); // non-zero root; public path needs no proof
        nft.setMintOpen(true);
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt()); // PUBLIC window: the open mint path is live
        hook = new MockTaxHook();
        nft.setTaxHook(address(hook));
    }

    function _mint(address who) internal returns (uint256 id) {
        vm.deal(who, PRICE);
        vm.prank(who);
        nft.mint{ value: PRICE }();
        id = nft.totalMinted(); // ids are 1..totalMinted, so the newest id == the count
    }

    // setTaxHook is write-once.
    function test_setTaxHook_writeOnce() public {
        vm.expectRevert(NFTCollection.HookAlreadySet.selector);
        nft.setTaxHook(address(0xBEEF));
    }

    // Before launch (launchTime == 0) there is no lock — even a "flagged" wallet transfers freely.
    function test_noLock_beforeLaunch() public {
        uint256 id = _mint(alice);
        hook.setBuys(alice, 3);
        vm.prank(alice);
        nft.transferFrom(alice, carol, id);
        assertEq(nft.ownerOf(id), carol);
    }

    // Gate open + sender flagged => transfer blocked.
    function test_lock_blocksFlaggedBuyer() public {
        uint256 id = _mint(alice);
        hook.setLaunchTime(block.timestamp);
        hook.setBuys(alice, 1);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.PassLockedDuringLaunch.selector);
        nft.transferFrom(alice, carol, id);
        assertEq(nft.ownerOf(id), alice); // still hers
    }

    // Gate open + sender NOT flagged => transfer allowed (art stays liquid for non-buyers).
    function test_lock_allowsUnflaggedHolder() public {
        uint256 id = _mint(bob);
        hook.setLaunchTime(block.timestamp);
        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        assertEq(nft.ownerOf(id), carol);
    }

    // After the window, a flagged wallet can transfer again, and the lock latches off.
    function test_lock_liftsAfterWindow() public {
        uint256 id = _mint(alice);
        hook.setLaunchTime(block.timestamp);
        hook.setBuys(alice, 1);
        vm.warp(block.timestamp + hook.GATE_DURATION() + 1);
        vm.prank(alice);
        nft.transferFrom(alice, carol, id);
        assertEq(nft.ownerOf(id), carol);
        assertTrue(nft.launchLockLifted());
    }

    // The anti-recycling property: a pass can unlock at most one buying wallet during the window. Alice moves
    // the pass to Carol BEFORE buying (allowed, unflagged); once Carol buys and is flagged, the pass is stuck.
    function test_lock_preventsSerialRecycling() public {
        uint256 id = _mint(alice);
        hook.setLaunchTime(block.timestamp);
        vm.prank(alice); // alice not flagged yet
        nft.transferFrom(alice, carol, id);
        hook.setBuys(carol, 1); // carol buys -> flagged
        vm.prank(carol);
        vm.expectRevert(NFTCollection.PassLockedDuringLaunch.selector);
        nft.transferFrom(carol, bob, id);
    }
}
