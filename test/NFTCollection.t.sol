// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { NFTCollectionTestnet } from "../src/testnet/TestnetShortClock.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// A payout recipient that rejects ETH, to prove finalizeLaunch's reveal survives a bad recipient.
contract RejectETH {
    receive() external payable {
        // Accepts the ZERO-VALUE probe that setRecipients now makes, and rejects a real payout. A zero-value
        // probe cannot tell this apart from a good recipient (a payable receive that reverts only on value),
        // so it is exactly the shape the reveal has to survive: a bad
        // payout recipient must not brick the reveal. A recipient that rejects even the probe is now
        // refused at setRecipients, which is the case the probe DOES cover.
        if (msg.value > 0) revert("no ETH");
    }
}

/// Test-only subclass with a SMALL soft-close cap (+10m), so the MAX_EXTENSION clamp is reachable with the
/// 4-wallet allowlist fixture. The real cap is 6h (72 five-minute steps); the clamp LOGIC is identical.
contract SmallCapNFT is NFTCollection {
    constructor(uint256 p, address o, uint256 rd, address r, address ow) NFTCollection(p, o, rd, r, ow) { }
    function MAX_EXTENSION() public pure override returns (uint256) { return 10 minutes; }
}

/// Test-only MIS-SET subclass: a caller-chosen MAX_EXTENSION, so the soft-close invariant guard
/// (MAX_EXTENSION() < PUBLIC_MINT_WINDOW(), asserted in openAllowlistMint) can be probed on both sides.
contract BadSoftCloseNFT is NFTCollection {
    uint256 internal immutable ext;
    constructor(uint256 p, address o, uint256 rd, address r, address ow, uint256 ext_)
        NFTCollection(p, o, rd, r, ow)
    {
        ext = ext_;
    }
    function MAX_EXTENSION() public view override returns (uint256) { return ext; }
}

/// Test-only SHORT-STEP subclass: a 2h reveal fallback step, so the constructor guard
/// (revealDelay_ < REVEAL_FALLBACK_STEP(), a virtual getter) is proven to see a subclass override.
contract ShortFallbackNFT is NFTCollection {
    constructor(uint256 p, address o, uint256 rd, address r, address ow) NFTCollection(p, o, rd, r, ow) { }
    function REVEAL_FALLBACK_STEP() public pure override returns (uint256) { return 2 hours; }
}

/// @notice pass-11 TIERED, TIME-BOXED MINT.
///
/// The mint starts ONCE (openAllowlistMint stamps `mintStart`); from that instant three windows advance on the
/// clock with NO further owner action:
///   [S,            S+GTD)                 GTD:      allowlist proof path only, cumulative cap GTD_CAP      (3)
///   [S+GTD,        S+GTD+OVF)             OVERFLOW: allowlist proof path only, cumulative cap OVERFLOW_CAP (8)
///   [S+GTD+OVF, S+GTD+OVF+PUB]         PUBLIC:   open path + proof path,    cumulative cap PUBLIC_CAP   (20)
/// After S+GTD+OVF+PUB the collection is CLOSED by time and finalizeLaunch() is permissionless.
/// `mintedBy` is ONE cumulative counter, so a wallet that took its GTD 3 can reach 8 in overflow and 20 in public.
/// Hook-binding probes. A contract that EXISTS but does not answer ITaxHook: `code.length` alone would accept it,
/// and every transfer would then revert on the first hook read.
contract NotAHook {
    function unrelated() external pure returns (uint256) { return 1; }
}

/// Answers the interface at wiring time, then starts reverting. Models a hook whose behaviour changes AFTER
/// the write-once binding is made -- which the setter validation cannot prevent.
contract FlakyHook {
    bool public broken;
    function breakIt() external { broken = true; }
    function launchTime() external view returns (uint256) { require(!broken, "down"); return 0; }
    function GATE_DURATION() external view returns (uint256) { require(!broken, "down"); return 1 hours; }
    function earlyBuyer(address) external view returns (uint64, uint32) { require(!broken, "down"); return (0, 0); }
}

contract NFTCollectionTest is Test {
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    NFTCollection nft;
    MockDrandOracle oracle;
    PassArtRenderer renderer; // empty but LOCKED renderer is fine here — these tests don't call tokenURI

    address alice = makeAddr("alice");
    address lpTreasury = makeAddr("lpTreasury");
    address seedTreasury = makeAddr("seedTreasury");
    address team = makeAddr("team");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant PRICE = 0.1 ether;

    // pass-11 tier caps (compile-time constants in the contract). CUMULATIVE per-wallet, rising over time.
    uint256 constant GTD_CAP = 3;
    uint256 constant OVERFLOW_CAP = 8;
    uint256 constant PUBLIC_CAP = 20;
    uint256 constant SUPPLY = 3500; // MAX_SUPPLY (final, 2026-09-03); 3500 = 175 wallets x PUBLIC_CAP (20) exactly

    // mainnet window durations (view getters on the base contract)
    uint256 constant GTD_W = 6 hours;
    uint256 constant OVF_W = 18 hours;
    uint256 constant PUB_W = 24 hours;
    uint256 constant BACKSTOP = 30 days;

    event MintStarted(uint256 mintStart);
    event OverflowExtended(uint256 newOverflowEnd);
    event ProceedsWithdrawn(address indexed recipient, uint256 amount, bool ok);

    // allowlist fixture: a 4-leaf merkle tree over four wallets, so proofs are 2 levels deep.
    address[4] alw;
    bytes32[4] leaves;
    bytes32 alRoot;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        // The reveal ladder needs positive evidence that Drand moved PAST the round it is
        // discarding. Default fixture = a live chain far ahead of anything these tests bind, which is the
        // normal world; the tests that exercise the guard itself lower this deliberately.
        oracle.setHighestRound(type(uint64).max);
        renderer = new PassArtRenderer(address(this));
        renderer.lock(); // NFTCollection requires a locked renderer at construction
        _buildAllowlist();
        // Default fixture: the mint is started and time is advanced into the PUBLIC window, so the open path
        // (mint/mintBatch) is live and the per-wallet cap is PUBLIC_CAP. Tiered-window tests build their own
        // collections and warp explicitly.
        nft = _newCollection();
        nft.openAllowlistMint(); // mintStart == GENESIS
        vm.warp(nft.publicOpensAt()); // GENESIS + GTD_W + OVF_W -> PUBLIC window
    }

    /// A collection wired and armed but still in phase CLOSED: recipients set, root set, kill switch on, unstarted.
    function _newCollection() internal returns (NFTCollection n) {
        n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n.setRecipients(lpTreasury, seedTreasury, team);
        n.setAllowlistRoot(alRoot);
        n.setMintOpen(true);
    }

    /// A started collection sitting in the GTD (allowlist) window: mintStart == block.timestamp, cap == GTD_CAP.
    function _allowlistPhaseCollection() internal returns (NFTCollection n) {
        n = _newCollection();
        n.openAllowlistMint();
    }

    /// A started collection warped into the PUBLIC window.
    function _publicPhaseCollection() internal returns (NFTCollection n) {
        n = _allowlistPhaseCollection();
        vm.warp(n.publicOpensAt());
    }

    // ─── merkle helpers (OZ sorted-pair hashing, leaf = keccak256(abi.encodePacked(wallet))) ───

    function _buildAllowlist() internal {
        alw[0] = makeAddr("al0");
        alw[1] = makeAddr("al1");
        alw[2] = makeAddr("al2");
        alw[3] = makeAddr("al3");
        for (uint256 i; i < 4; ++i) {
            leaves[i] = keccak256(abi.encodePacked(alw[i]));
        }
        alRoot = _hashPair(_hashPair(leaves[0], leaves[1]), _hashPair(leaves[2], leaves[3]));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofFor(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1]; // sibling leaf
        p[1] = i < 2 ? _hashPair(leaves[2], leaves[3]) : _hashPair(leaves[0], leaves[1]); // sibling subtree
    }

    function _mint(address who) internal returns (uint256) {
        vm.deal(who, PRICE);
        vm.prank(who);
        nft.mint{ value: PRICE }();
        return nft.totalMinted();
    }

    /// Mint the whole supply on the OPEN path in the PUBLIC window: SUPPLY/PUBLIC_CAP wallets at PUBLIC_CAP each,
    /// plus one remainder wallet. 3500 = 175 * 20 exactly, so there is no remainder, but the helper is general.
    /// The caller must already be in the PUBLIC window (the default `nft` is).
    function _fillSupply(NFTCollection n) internal {
        uint256 per = PUBLIC_CAP;
        uint256 full = SUPPLY / per;
        for (uint256 i; i < full; ++i) {
            address w = vm.addr(6000 + i);
            vm.deal(w, per * PRICE);
            vm.prank(w);
            n.mintBatch{ value: per * PRICE }(per);
        }
        uint256 rem = SUPPLY - full * per;
        if (rem > 0) {
            address w = vm.addr(6000 + full);
            vm.deal(w, rem * PRICE);
            vm.prank(w);
            n.mintBatch{ value: rem * PRICE }(rem);
        }
        assertEq(n.totalMinted(), SUPPLY, "collection sold out");
    }

    function COMMON() internal pure returns (uint8) { return 0; }
    function UNCOMMON() internal pure returns (uint8) { return 1; }
    function RARE() internal pure returns (uint8) { return 2; }
    function SUPER_RARE() internal pure returns (uint8) { return 3; }

    // ─── constants / tier surface ──────────────────────────────────────────────

    function test_launchConstants() public view {
        assertEq(nft.MAX_SUPPLY(), SUPPLY, "3500-piece collection");
        // pass-11: the caps are the distribution knob. Tiered, cumulative, rising 3 -> 8 -> 20.
        assertEq(nft.GTD_CAP(), GTD_CAP, "GTD cap 3");
        assertEq(nft.OVERFLOW_CAP(), OVERFLOW_CAP, "overflow cap 8");
        assertEq(nft.PUBLIC_CAP(), PUBLIC_CAP, "public cap 20");
        // 3500 = 175 wallets x PUBLIC_CAP: sell-out needs at least 175 distinct wallets.
        assertEq(nft.MAX_SUPPLY() / nft.PUBLIC_CAP(), 175, "sell-out needs >= 175 distinct wallets (3500/20)");
        // window lengths are VIEW getters now (virtual; testnet subclass overrides them)
        assertEq(nft.GTD_WINDOW(), GTD_W, "6h GTD window");
        assertEq(nft.OVERFLOW_WINDOW(), OVF_W, "18h overflow window");
        assertEq(nft.PUBLIC_MINT_WINDOW(), PUB_W, "24h public window");
        assertEq(nft.LAUNCH_BACKSTOP(), BACKSTOP, "30d launch backstop");
    }

    // ─── the split, price, supply on the open path ─────────────────────────────

    function test_mintSplitsProceeds() public {
        uint256 id = _mint(alice);
        assertEq(id, 1);
        assertEq(nft.ownerOf(1), alice);

        // 0.1 ETH -> LP 0.08 / seed 0.01 / team 0.01 (80/10/10)
        assertEq(nft.lpReserve(), 0.08 ether);
        assertEq(nft.seedReserve(), 0.01 ether);
        assertEq(nft.teamReserve(), 0.01 ether);
        assertEq(address(nft).balance, PRICE);
    }

    function test_badPriceReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.BadPrice.selector);
        nft.mint{ value: 0.2 ether }();
    }

    function test_soldOutAtMaxSupply() public {
        _fillSupply(nft);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.SoldOut.selector);
        nft.mint{ value: PRICE }();
    }

    // ─── reveal / finalize (unchanged by pass-11) ──────────────────────────────

    function test_raritySealedThenRevealed() public {
        _mint(alice);

        vm.expectRevert(); // sealed: not finalized yet, reveal round unset
        nft.rarityOf(1);

        nft.finalizeLaunch(); // seals ALL rarities to one future round
        uint64 rr = nft.revealRound();

        vm.expectRevert(); // finalized, but that round's beacon not yet posted
        nft.rarityOf(1);

        oracle.setBeacon(rr, keccak256("beacon"));
        uint8 r = nft.rarityOf(1);
        assertLe(r, 3, "valid tier");
    }

    function test_finalizeLaunchRoutesBuckets() public {
        _mint(alice);
        _mint(vm.addr(99)); // 2 mints → 0.2 ETH total

        uint256 lp = nft.lpReserve();
        uint256 seed = nft.seedReserve();
        uint256 t = nft.teamReserve();
        assertEq(lp + seed + t, 0.2 ether);

        nft.finalizeLaunch(); // seals rarity; moves no ETH
        assertTrue(nft.launched());
        nft.withdrawProceeds(); // pulls the buckets separately

        assertEq(lpTreasury.balance, lp, "LP routed");
        assertEq(seedTreasury.balance, seed, "seed routed");
        assertEq(team.balance, t, "team routed");
        assertEq(address(nft).balance, 0, "contract drained to purposes");
    }

    // A payout recipient that reverts on receive must NOT block the rarity reveal.
    function test_revertingRecipientDoesNotBrickReveal() public {
        NFTCollection n2 = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        RejectETH bad = new RejectETH();
        n2.setRecipients(address(bad), seedTreasury, team); // LP recipient rejects ETH
        n2.setAllowlistRoot(alRoot);
        n2.setMintOpen(true);
        n2.openAllowlistMint();
        vm.warp(n2.publicOpensAt()); // into PUBLIC so the open path is live
        vm.deal(alice, PRICE);
        vm.prank(alice);
        n2.mint{ value: PRICE }();

        n2.finalizeLaunch(); // must succeed and seal rarity despite the bad recipient
        oracle.setBeacon(n2.revealRound(), keccak256("b"));
        assertLe(n2.rarityOf(1), 3, "rarity revealed - reveal not bricked by the bad payout recipient");

        n2.withdrawProceeds(); // pays the good buckets, leaves LP's for retry
        assertEq(seedTreasury.balance, 0.01 ether, "seed still paid");
        assertEq(n2.lpReserve(), 0.08 ether, "bad LP bucket retained for retry, not lost");
    }

    // withdrawProceeds emits one ProceedsWithdrawn per non-zero bucket it attempts, so a payout, a refused
    // payout (bucket restored) and a no-op second call are distinguishable from the logs alone.
    function test_withdrawProceedsEmitsPerBucket() public {
        _mint(alice);
        _mint(vm.addr(99));
        uint256 lp = nft.lpReserve();
        uint256 seed = nft.seedReserve();
        uint256 t = nft.teamReserve();
        nft.finalizeLaunch();

        vm.expectEmit(true, false, false, true, address(nft));
        emit ProceedsWithdrawn(lpTreasury, lp, true);
        vm.expectEmit(true, false, false, true, address(nft));
        emit ProceedsWithdrawn(seedTreasury, seed, true);
        vm.expectEmit(true, false, false, true, address(nft));
        emit ProceedsWithdrawn(team, t, true);
        nft.withdrawProceeds();

        // second call: every bucket is zero, so nothing is attempted and nothing is logged
        vm.recordLogs();
        nft.withdrawProceeds();
        assertEq(vm.getRecordedLogs().length, 0, "no-op withdraw emits nothing");
    }

    function test_withdrawProceedsRevertingRecipientEmitsNotOk() public {
        NFTCollection n2 = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        RejectETH bad = new RejectETH();
        n2.setRecipients(address(bad), seedTreasury, team);
        n2.setAllowlistRoot(alRoot);
        n2.setMintOpen(true);
        n2.openAllowlistMint();
        vm.warp(n2.publicOpensAt());
        vm.deal(alice, PRICE);
        vm.prank(alice);
        n2.mint{ value: PRICE }();
        n2.finalizeLaunch();
        uint256 lp = n2.lpReserve();

        vm.expectEmit(true, false, false, true, address(n2));
        emit ProceedsWithdrawn(address(bad), lp, false);
        vm.expectEmit(true, false, false, true, address(n2));
        emit ProceedsWithdrawn(seedTreasury, 0.01 ether, true);
        vm.expectEmit(true, false, false, true, address(n2));
        emit ProceedsWithdrawn(team, 0.01 ether, true);
        n2.withdrawProceeds();
        assertEq(n2.lpReserve(), lp, "refused bucket restored");

        // the retry attempts only the restored bucket, and logs it as refused again
        vm.recordLogs();
        n2.withdrawProceeds();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the restored bucket is attempted");
        assertEq(logs[0].topics[0], keccak256("ProceedsWithdrawn(address,uint256,bool)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(bad));
        (uint256 amt, bool ok) = abi.decode(logs[0].data, (uint256, bool));
        assertEq(amt, lp);
        assertFalse(ok);
    }

    // currentCap() is the window's tier cap, not a liveness signal. After the public window closes it
    // still reads PUBLIC_CAP while phase() is CLOSED; the natspec says callers must check the phase.
    function test_currentCapStaysPublicCapAfterClose() public {
        vm.warp(nft.publicMintClosesAt() + 1);
        assertEq(uint8(nft.phase()), 0, "closed by time");
        assertTrue(nft.publicMintExpired());
        assertEq(nft.currentCap(), PUBLIC_CAP, "tier cap of the last window, documented");
    }

    function test_cannotFinalizeTwice() public {
        _mint(alice);
        nft.finalizeLaunch();
        vm.expectRevert(NFTCollection.AlreadyLaunched.selector);
        nft.finalizeLaunch();
    }

    function test_mintClosedAfterLaunch() public {
        _mint(alice);
        nft.finalizeLaunch();
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        nft.mint{ value: PRICE }();
    }

    /// Rarity distribution sanity: over many mints, ~2% Super Rare, ~70% Common (probabilistic).
    function test_rarityDistributionRoughlyOnTarget() public {
        uint256 n = 250;
        for (uint256 i = 1; i <= n; ++i) {
            _mint(vm.addr(1000 + i));
        }
        nft.finalizeLaunch(); // seal the collection's rarities to one round
        oracle.setBeacon(nft.revealRound(), keccak256("dist"));
        uint256[4] memory counts;
        for (uint256 i = 1; i <= n; ++i) {
            counts[nft.rarityOf(i)]++;
        }
        // loose bounds (probabilistic): Common is the plurality, Super Rare is rare
        assertGt(counts[COMMON()], counts[UNCOMMON()], "common most numerous");
        assertLt(counts[SUPER_RARE()], counts[RARE()], "super rare scarcest");
    }

    // ─── mintBatch (batch-mint UX) ─────────────────────────────────────────────

    function test_mintBatch_splitsIdsCountsAndProceeds() public {
        uint256 qty = 3;
        uint256 value = qty * PRICE; // 0.3 ETH
        vm.deal(alice, value);
        vm.prank(alice);
        nft.mintBatch{ value: value }(qty);

        // sequential ids, all to the caller
        assertEq(nft.totalMinted(), 3, "3 minted");
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.ownerOf(3), alice);
        assertEq(nft.mintedBy(alice), 3, "mintedBy += qty");

        // 80/10/10 split on the TOTAL value; team exact 10%, LP absorbs any dust
        uint256 seed = (value * 1000) / 10_000;
        uint256 teamCut = (value * 1000) / 10_000;
        assertEq(nft.seedReserve(), seed, "seed 10% of total");
        assertEq(nft.teamReserve(), teamCut, "team 10% of total");
        assertEq(nft.lpReserve(), value - seed - teamCut, "LP = remainder (80% + dust)");
        assertEq(address(nft).balance, value, "all ETH held pre-withdraw");
    }

    function test_mintBatch_idsSequentialAfterSingleMint() public {
        _mint(alice); // id 1 via mint()
        uint256 value = 2 * PRICE;
        vm.deal(vm.addr(77), value);
        vm.prank(vm.addr(77));
        nft.mintBatch{ value: value }(2); // ids 2,3
        assertEq(nft.ownerOf(2), vm.addr(77));
        assertEq(nft.ownerOf(3), vm.addr(77));
        assertEq(nft.totalMinted(), 3, "ids stay sequential across mint()+mintBatch()");
    }

    function test_mintBatch_revertsOnZeroQty() public {
        vm.prank(alice);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        nft.mintBatch{ value: 0 }(0);
    }

    function test_mintBatch_revertsAbovePublicCap() public {
        uint256 qty = PUBLIC_CAP + 1; // > cap in one shot (21 > 20)
        vm.deal(alice, qty * PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        nft.mintBatch{ value: qty * PRICE }(qty);
    }

    function test_mintBatch_revertsOnCumulativeOverCap() public {
        vm.deal(alice, 2 * PUBLIC_CAP * PRICE);
        vm.prank(alice);
        nft.mintBatch{ value: PUBLIC_CAP * PRICE }(PUBLIC_CAP); // 20 so far (== cap)
        vm.prank(alice);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        nft.mintBatch{ value: PRICE }(1); // 20 + 1 > 20 cumulative
    }

    function test_mintBatch_revertsOnWrongValue() public {
        vm.deal(alice, 2 * PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.BadPrice.selector);
        nft.mintBatch{ value: PRICE }(2); // must be exactly qty * PRICE
    }

    function test_mintBatch_revertsWhenSoldOut() public {
        _fillSupply(nft);
        address late = makeAddr("late");
        vm.deal(late, PRICE);
        vm.prank(late);
        vm.expectRevert(NFTCollection.SoldOut.selector);
        nft.mintBatch{ value: PRICE }(1);
    }

    // ─── pass-11: openAllowlistMint is the ONE start action ────────────────────

    function test_openAllowlistMint_stampsAndEmits() public {
        NFTCollection n = _newCollection(); // wired, armed, unstarted
        assertEq(n.mintStart(), 0, "unstarted");
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.CLOSED), "CLOSED before start");
        assertEq(n.currentCap(), 0, "no cap before start");

        uint256 t = block.timestamp;
        vm.expectEmit(false, false, false, true);
        emit MintStarted(t);
        n.openAllowlistMint();
        assertEq(n.mintStart(), t, "mintStart stamped to now");
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.ALLOWLIST), "ALLOWLIST at start");
    }

    function test_openAllowlistMint_requiresMintOpen() public {
        NFTCollection n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n.setRecipients(lpTreasury, seedTreasury, team);
        n.setAllowlistRoot(alRoot);
        // mintOpen still false: starting would burn the timed windows against a paused mint
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.openAllowlistMint();
    }

    function test_openAllowlistMint_revertsWithUnsetRoot() public {
        NFTCollection n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n.setRecipients(lpTreasury, seedTreasury, team);
        n.setMintOpen(true);
        vm.expectRevert(NFTCollection.AllowlistRootUnset.selector);
        n.openAllowlistMint(); // would open a GTD window nobody could ever pass (the root then freezes)
    }

    // Recipients must be frozen BEFORE the mint starts. pass-11 hoists that guard into
    // openAllowlistMint, so the one-shot clock can never start against a mint that would brick.
    function test_startBeforeRecipientsReverts() public {
        NFTCollection n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n.setAllowlistRoot(alRoot);
        n.setMintOpen(true); // armed WITHOUT setRecipients
        vm.expectRevert(NFTCollection.RecipientsUnset.selector);
        n.openAllowlistMint();
    }

    function test_openAllowlistMint_isOneShot() public {
        NFTCollection n = _allowlistPhaseCollection();
        // a second start (in ALLOWLIST) reverts: mintStart never moves, no window can be re-opened.
        vm.expectRevert(NFTCollection.AlreadyStarted.selector);
        n.openAllowlistMint();
        // still one-shot from the PUBLIC window
        vm.warp(n.publicOpensAt());
        vm.expectRevert(NFTCollection.AlreadyStarted.selector);
        n.openAllowlistMint();
    }

    function test_openAllowlistMint_isOwnerOnly() public {
        NFTCollection n = _newCollection();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        n.openAllowlistMint();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        n.setAllowlistRoot(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        n.setMintOpen(false);
        vm.stopPrank();
    }

    function test_startedCannotReopenAfterLaunch() public {
        NFTCollection n = _publicPhaseCollection();
        n.finalizeLaunch();
        vm.expectRevert(NFTCollection.AlreadyLaunched.selector);
        n.openAllowlistMint();
    }

    // ─── pass-11: phase() is derived from elapsed time (EXACT boundaries) ───────

    function test_phase_closedBeforeStartBlocksBothPaths() public {
        NFTCollection n = _newCollection(); // wired, kill switch on, unstarted
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.CLOSED), "CLOSED before start");
        assertEq(n.publicMintClosesAt(), 0, "no deadline before start");
        assertEq(n.publicOpensAt(), 0, "no open time before start");

        vm.deal(alw[0], 2 * PRICE);
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.mint{ value: PRICE }();
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(0));
    }

    /// phase() across the whole timeline, testing the EXACT boundary second on both sides.
    function test_phase_exactBoundaries() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 s = n.mintStart();

        // at start: ALLOWLIST
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.ALLOWLIST), "ALLOWLIST at t == S");

        // GTD/overflow internal boundary — phase stays ALLOWLIST across it
        vm.warp(s + GTD_W - 1);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.ALLOWLIST), "ALLOWLIST at S+GTD-1");
        vm.warp(s + GTD_W);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.ALLOWLIST), "ALLOWLIST at S+GTD");

        // overflow -> public boundary (== publicOpensAt)
        vm.warp(s + GTD_W + OVF_W - 1);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.ALLOWLIST), "ALLOWLIST at publicOpensAt-1");
        vm.warp(s + GTD_W + OVF_W);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.PUBLIC), "PUBLIC at t == publicOpensAt");
        assertEq(n.publicOpensAt(), s + GTD_W + OVF_W, "publicOpensAt = S + GTD + OVF");

        // public -> closed boundary (== publicMintClosesAt), inclusive of the boundary second
        uint256 close = n.publicMintClosesAt();
        assertEq(close, s + GTD_W + OVF_W + PUB_W, "publicMintClosesAt = S + GTD + OVF + PUB");
        vm.warp(close);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.PUBLIC), "PUBLIC at t == publicMintClosesAt");
        vm.warp(close + 1);
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.CLOSED), "CLOSED one second past the deadline");
    }

    /// currentCap() rises 0 -> 3 -> 8 -> 20 across the timeline, at the EXACT boundary seconds.
    function test_currentCap_exactBoundaries() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 s = n.mintStart();

        assertEq(n.currentCap(), GTD_CAP, "cap 3 at t == S");
        vm.warp(s + GTD_W - 1);
        assertEq(n.currentCap(), GTD_CAP, "cap 3 at S+GTD-1");
        vm.warp(s + GTD_W);
        assertEq(n.currentCap(), OVERFLOW_CAP, "cap 8 at t == S+GTD");
        vm.warp(s + GTD_W + OVF_W - 1);
        assertEq(n.currentCap(), OVERFLOW_CAP, "cap 8 at publicOpensAt-1");
        vm.warp(s + GTD_W + OVF_W);
        assertEq(n.currentCap(), PUBLIC_CAP, "cap 20 at t == publicOpensAt");
        // cap stays 20 through the whole public window, incl. past the close (view is monotone here)
        vm.warp(n.publicMintClosesAt() + 1);
        assertEq(n.currentCap(), PUBLIC_CAP, "cap view stays 20 after close");
    }

    // ─── pass-11: which path is live in which window ───────────────────────────

    function test_openPathClosedInAllowlistWindows() public {
        NFTCollection n = _allowlistPhaseCollection(); // GTD window
        vm.deal(alw[0], 2 * PRICE);

        // GTD: the open path is closed even to an allowlisted wallet
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.mint{ value: PRICE }();
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.mintBatch{ value: PRICE }(1);

        // OVERFLOW: still closed to the open path
        vm.warp(n.mintStart() + GTD_W);
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.mint{ value: PRICE }();

        // PUBLIC: the open path opens
        vm.warp(n.publicOpensAt());
        vm.prank(alw[0]);
        n.mint{ value: PRICE }();
        assertEq(n.mintedBy(alw[0]), 1, "open path succeeds in PUBLIC");
    }

    function test_allowlistPathLiveInBothAllowlistAndPublic() public {
        NFTCollection n = _allowlistPhaseCollection(); // GTD window

        // GTD: proof path works
        vm.deal(alw[1], 4 * PRICE);
        vm.prank(alw[1]);
        n.allowlistMint{ value: PRICE }(1, _proofFor(1));
        assertEq(n.mintedBy(alw[1]), 1, "proof path live in GTD");

        // OVERFLOW: still works
        vm.warp(n.mintStart() + GTD_W);
        vm.prank(alw[1]);
        n.allowlistMint{ value: PRICE }(1, _proofFor(1));
        assertEq(n.mintedBy(alw[1]), 2, "proof path live in overflow");

        // PUBLIC: still works (an allowlisted wallet never loses its path)
        vm.warp(n.publicOpensAt());
        vm.prank(alw[1]);
        n.allowlistMint{ value: PRICE }(1, _proofFor(1));
        assertEq(n.mintedBy(alw[1]), 3, "proof path survives into PUBLIC");
    }

    function test_allowlist_badProofRejected() public {
        NFTCollection n = _allowlistPhaseCollection();
        vm.deal(alw[0], PRICE);
        bytes32[] memory wrong = _proofFor(1); // alw[1]'s proof, presented by alw[0]
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        n.allowlistMint{ value: PRICE }(1, wrong);

        // an empty proof is not a bypass either
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        n.allowlistMint{ value: PRICE }(1, new bytes32[](0));
    }

    function test_allowlist_nonAllowlistedRejected() public {
        NFTCollection n = _allowlistPhaseCollection();
        vm.deal(alice, PRICE);
        // alice is not in the tree: no proof exists, and a real member's proof does not carry over
        vm.prank(alice);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(0));
    }

    function test_allowlist_splitHolds() public {
        NFTCollection n = _allowlistPhaseCollection();
        for (uint256 i; i < 4; ++i) {
            vm.deal(alw[i], 2 * PRICE);
            vm.prank(alw[i]);
            n.allowlistMint{ value: 2 * PRICE }(2, _proofFor(i)); // 2 <= GTD_CAP
            assertEq(n.mintedBy(alw[i]), 2, "allowlisted wallet minted");
        }
        assertEq(n.totalMinted(), 8, "8 passes via the allowlist path");
        assertEq(n.ownerOf(1), alw[0]);
        // the 80/10/10 split applies identically on the allowlist path
        assertEq(n.seedReserve(), (8 * PRICE * 1000) / 10_000, "seed 10%");
        assertEq(n.teamReserve(), (8 * PRICE * 1000) / 10_000, "team 10%");
        assertEq(n.lpReserve(), 8 * PRICE - n.seedReserve() - n.teamReserve(), "LP remainder");
    }

    // ─── pass-11: the tiered, cumulative per-wallet cap (3 -> 8 -> 20) ──────────

    function test_gtdWindow_capsAtThree() public {
        NFTCollection n = _allowlistPhaseCollection(); // GTD, cap 3
        address w = alw[2];
        vm.deal(w, 10 * PRICE);

        vm.prank(w);
        n.allowlistMint{ value: 3 * PRICE }(3, _proofFor(2)); // 3 in GTD is allowed
        assertEq(n.mintedBy(w), 3, "3 minted in GTD");

        // the 4th in GTD reverts (cap is 3)
        vm.prank(w);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(2));
    }

    function test_overflowWindow_topsUpToEight() public {
        NFTCollection n = _allowlistPhaseCollection();
        address w = alw[2];
        vm.deal(w, 20 * PRICE);

        vm.prank(w);
        n.allowlistMint{ value: 3 * PRICE }(3, _proofFor(2)); // 3 in GTD

        vm.warp(n.mintStart() + GTD_W); // overflow, cap 8
        vm.prank(w);
        n.allowlistMint{ value: 5 * PRICE }(5, _proofFor(2)); // +5 = 8 total
        assertEq(n.mintedBy(w), 8, "reached 8 in overflow");

        // the 9th in overflow reverts (cap is 8)
        vm.prank(w);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(2));
    }

    /// Full cumulative walk: 3 in GTD, +5 in overflow (=8), +12 in public (=20), then the 21st reverts.
    function test_cumulativeCap_acrossAllThreeWindows() public {
        NFTCollection n = _allowlistPhaseCollection();
        address w = alw[3];
        vm.deal(w, 30 * PRICE);

        // GTD: 3
        vm.prank(w);
        n.allowlistMint{ value: 3 * PRICE }(3, _proofFor(3));
        assertEq(n.mintedBy(w), 3);

        // OVERFLOW: +5 = 8
        vm.warp(n.mintStart() + GTD_W);
        vm.prank(w);
        n.allowlistMint{ value: 5 * PRICE }(5, _proofFor(3));
        assertEq(n.mintedBy(w), 8);

        // PUBLIC: +12 = 20, on the OPEN path (proves the counter is shared across paths)
        vm.warp(n.publicOpensAt());
        vm.prank(w);
        n.mintBatch{ value: 12 * PRICE }(12);
        assertEq(n.mintedBy(w), PUBLIC_CAP, "reached 20 total across all three windows");

        // the 21st reverts on EVERY path
        vm.prank(w);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        n.mint{ value: PRICE }();
        vm.prank(w);
        vm.expectRevert(NFTCollection.WalletLimit.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(3)); // the allowlist is not a second allocation
    }

    // ─── pass-11: allowlist root frozen once the mint starts ───────────────────

    function test_setAllowlistRoot_frozenOnceStarted() public {
        NFTCollection n = _newCollection();
        n.setAllowlistRoot(keccak256("still closed")); // fine while unstarted
        n.openAllowlistMint();
        vm.expectRevert(NFTCollection.AllowlistLocked.selector);
        n.setAllowlistRoot(keccak256("too late"));

        // and it stays frozen once time moves into PUBLIC, where the proof path is still live
        vm.warp(n.publicOpensAt());
        vm.expectRevert(NFTCollection.AllowlistLocked.selector);
        n.setAllowlistRoot(keccak256("still too late"));
    }

    // ─── pass-11: the kill switch still gates a live window ─────────────────────

    function test_killSwitchStillGatesALiveWindow() public {
        nft.setMintOpen(false); // owner pause (nft is in PUBLIC)
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        nft.mint{ value: PRICE }();
    }

    // ─── pass-11: the derived public window and its exact deadline ─────────────

    function test_publicWindow_derivedFromStart() public view {
        // nft started at GENESIS (setUp), so the public window is [GENESIS+8h, GENESIS+56h].
        assertEq(nft.mintStart(), GENESIS, "started at GENESIS");
        assertEq(nft.publicOpensAt(), GENESIS + GTD_W + OVF_W, "opens 24h after start");
        assertEq(nft.publicMintClosesAt(), GENESIS + GTD_W + OVF_W + PUB_W, "closes 48h after start (fixed)");
        assertFalse(nft.publicMintExpired(), "not expired inside the window");
    }

    function test_publicWindow_mintsUntilTheDeadlineThenCloses() public {
        // 1s before the deadline: fine.
        vm.warp(nft.publicMintClosesAt() - 1);
        _mint(alice);

        // AT the deadline: still open (phase() uses <=), and the permissionless finalize is not yet armed.
        vm.warp(nft.publicMintClosesAt());
        assertFalse(nft.publicMintExpired(), "not expired at t == closesAt");
        _mint(vm.addr(4242));

        // One second past it: phase() closes by time, so EVERY mint path reverts MintClosed (the phase gate in
        // _requireMintable fires before the belt-and-suspenders MintWindowClosed branch, which is now
        // unreachable because phase() itself returns CLOSED past the deadline).
        vm.warp(nft.publicMintClosesAt() + 1);
        assertTrue(nft.publicMintExpired(), "expired");
        assertEq(uint8(nft.phase()), uint8(NFTCollection.MintPhase.CLOSED), "phase closed by time");
        vm.deal(alice, 2 * PRICE);
        vm.prank(alice);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        nft.mint{ value: PRICE }();
        vm.prank(alice);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        nft.mintBatch{ value: PRICE }(1);
        vm.deal(alw[0], PRICE);
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        nft.allowlistMint{ value: PRICE }(1, _proofFor(0)); // the proof path closes with everything else
    }

    // ─── pass-11: finalizeLaunch — owner any time, permissionless after the deadline ───

    function test_finalizeLaunch_ownerStillWorksEarly() public {
        _mint(alice);
        assertFalse(nft.publicMintExpired(), "window still open");
        nft.finalizeLaunch(); // owner, mid-window
        assertTrue(nft.launched(), "owner can finalize at any time");
        assertGt(nft.revealRound(), 0, "rarities sealed");
    }

    function test_finalizeLaunch_permissionlessOnlyAfterTheDeadline() public {
        _mint(alice);
        address stranger = makeAddr("stranger");

        vm.prank(stranger); // before the deadline: owner-only
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        nft.finalizeLaunch();

        vm.warp(nft.publicMintClosesAt()); // AT the deadline: still owner-only (strict >)
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        nft.finalizeLaunch();

        vm.warp(nft.publicMintClosesAt() + 1); // past it: anyone can close the launch
        uint256 ethBefore = address(nft).balance;
        vm.prank(stranger);
        nft.finalizeLaunch();
        assertTrue(nft.launched(), "launch cannot stall on an absent owner");
        assertGt(nft.revealRound(), 0, "rarities sealed by the permissionless call");
        assertEq(address(nft).balance, ethBefore, "finalizeLaunch moves NO ETH");
    }

    // pass-10/pass-11: the LAUNCH_BACKSTOP is the OUTER self-closing clock, measured from mintStart. It arms
    // finalizeLaunch() permissionlessly at mintStart + LAUNCH_BACKSTOP(). (In pass-11 publicMintExpired arms
    // first, at ~56h, so the backstop is a redundant outer guard, but its boundary must still hold exactly.)
    function test_launchBackstop_armsAtExactBoundary() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 s = n.mintStart();
        address stranger = makeAddr("stranger");

        // AT the exact boundary the backstop has NOT armed (strict >).
        vm.warp(s + BACKSTOP);
        assertFalse(n.launchBackstopExpired(), "not armed at the exact boundary");

        // one second past it, the backstop arms and anyone can finalize.
        vm.warp(s + BACKSTOP + 1);
        assertTrue(n.launchBackstopExpired(), "backstop armed one second later");
        vm.prank(stranger);
        n.finalizeLaunch();
        assertTrue(n.launched(), "stranger sealed the abandoned launch via the backstop clock");
    }

    // The finalize recipients guard is defense in depth: pass-11 hoisted the same check into
    // openAllowlistMint, so the PERMISSIONLESS path can never reach finalize with recipients unset. The OWNER
    // path still can, so the guard stays and is asserted here.
    function test_finalizeLaunch_ownerStillRequiresRecipients() public {
        NFTCollection n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        vm.expectRevert(NFTCollection.RecipientsUnset.selector); // owner (this) finalizes with no recipients
        n.finalizeLaunch();
    }

    function test_finalizeLaunch_permissionlessIsStillOneShot() public {
        _mint(alice);
        vm.warp(nft.publicMintClosesAt() + 1);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        nft.finalizeLaunch();
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.AlreadyLaunched.selector);
        nft.finalizeLaunch();
        vm.expectRevert(NFTCollection.AlreadyLaunched.selector);
        nft.finalizeLaunch(); // owner too
    }

    // ─── pass-11: the caps and supply cap are shared across BOTH paths ─────────

    function test_supplyCapHoldsOnTheAllowlistPath() public {
        _fillSupply(nft); // SUPPLY minted on the open path (nft is in PUBLIC)
        vm.deal(alw[0], PRICE);
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.SoldOut.selector);
        nft.allowlistMint{ value: PRICE }(1, _proofFor(0)); // proof path live in PUBLIC, but sold out
    }

    // ─── pass-12: auction soft-close on the overflow window ────────────────────
    function _al(NFTCollection n, uint256 i) internal {
        vm.deal(alw[i], PRICE);
        vm.prank(alw[i]);
        n.allowlistMint{ value: PRICE }(1, _proofFor(i));
    }

    function test_auction_lateOverflowMintExtends() public {
        NFTCollection n = _allowlistPhaseCollection(); // started at GENESIS; overflowEnd = nominal
        uint256 nominal = n.mintStart() + n.GTD_WINDOW() + n.OVERFLOW_WINDOW();
        assertEq(n.overflowEnd(), nominal, "overflowEnd inits to the nominal end");
        vm.warp(nominal - 5 minutes); // inside the last EXTENSION_TRIGGER() (10m) of overflow
        vm.expectEmit(false, false, false, true);
        emit OverflowExtended(nominal + n.EXTENSION_STEP());
        _al(n, 0);
        assertEq(n.overflowEnd(), nominal + n.EXTENSION_STEP(), "a late mint pushes overflowEnd +STEP");
        assertEq(n.publicOpensAt(), nominal + n.EXTENSION_STEP(), "public open shifts LATER with it");
        // pass-12b: the close is FIXED (mintStart + GTD + OVF + PUB); the soft-close does NOT move the end,
        // it shortens the public window by the extension amount.
        uint256 fixedClose = n.mintStart() + n.GTD_WINDOW() + n.OVERFLOW_WINDOW() + n.PUBLIC_MINT_WINDOW();
        assertEq(n.publicMintClosesAt(), fixedClose, "close is FIXED, unmoved by the soft-close");
        assertEq(n.publicMintClosesAt() - n.publicOpensAt(), n.PUBLIC_MINT_WINDOW() - n.EXTENSION_STEP(),
            "public window shortened by exactly the extension");
        // still ALLOWLIST at what WOULD have been the nominal open, because the window extended
        vm.warp(nominal);
        assertEq(uint256(n.phase()), uint256(NFTCollection.MintPhase.ALLOWLIST), "extended: still allowlist at nominal");
    }

    function test_auction_earlyOverflowMintDoesNotExtend() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 nominal = n.overflowEnd();
        vm.warp(n.mintStart() + n.GTD_WINDOW() + 1 minutes); // in overflow, but far before the trigger tail
        _al(n, 0);
        assertEq(n.overflowEnd(), nominal, "an early overflow mint never extends");
    }

    function test_auction_gtdMintDoesNotExtend() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 nominal = n.overflowEnd();
        vm.warp(n.mintStart() + 1 minutes); // GTD window
        _al(n, 0);
        assertEq(n.overflowEnd(), nominal, "a GTD mint never extends the overflow");
    }

    // The real cap is 6h (72 five-minute steps, more than the 4-wallet fixture can mint), so this exercises
    // the identical clamp on a small-cap (+10m) subclass: two steps reach it, the third cannot exceed it.
    function test_auction_capsAtMaxExtension() public {
        SmallCapNFT n = new SmallCapNFT(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        n.setRecipients(lpTreasury, seedTreasury, team);
        n.setAllowlistRoot(alRoot);
        n.setMintOpen(true);
        n.openAllowlistMint();
        uint256 nominal = n.overflowEnd();
        uint256 hardCap = nominal + n.MAX_EXTENSION(); // +10m
        uint256 prev = nominal;
        for (uint256 k = 0; k < 6; ++k) {
            uint256 oe = n.overflowEnd();
            if (oe >= hardCap) break;
            vm.warp(oe - 1 minutes); // stay in the trigger tail as it moves
            _alN(n, k % 4);
            uint256 got = n.overflowEnd();
            assertLe(got, hardCap, "overflowEnd never exceeds the hard cap");
            assertTrue(got > prev || got == hardCap, "each triggering mint advances toward the cap");
            prev = got;
        }
        assertEq(n.overflowEnd(), hardCap, "overflowEnd caps at nominal + MAX_EXTENSION");
        // a further late mint cannot push past the cap
        vm.warp(n.overflowEnd() - 1 minutes);
        _alN(n, 0);
        assertEq(n.overflowEnd(), hardCap, "capped: no extension beyond MAX_EXTENSION");
        // and the fixed public close still leaves a real public window (overflow can never eat all of it)
        assertLt(n.overflowEnd(), n.publicMintClosesAt(), "public window survives the soft-close");
    }

    // allowlist mint helper for an arbitrary NFTCollection instance (the shared _al targets `nft`).
    function _alN(NFTCollection n, uint256 i) internal {
        vm.deal(alw[i], PRICE);
        vm.prank(alw[i]);
        n.allowlistMint{ value: PRICE }(1, _proofFor(i));
    }

    function test_auction_noExtensionOncePublic() public {
        NFTCollection n = _allowlistPhaseCollection();
        vm.warp(n.publicOpensAt()); // t == overflowEnd -> PUBLIC
        uint256 oe = n.overflowEnd();
        address buyer = makeAddr("pubBuyer");
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        n.mint{ value: PRICE }(); // open path
        assertEq(n.overflowEnd(), oe, "a public mint never extends the overflow");
    }

    function test_auction_backstopUnaffectedByExtension() public {
        NFTCollection n = _allowlistPhaseCollection();
        uint256 s = n.mintStart();
        vm.warp(n.overflowEnd() - 1 minutes);
        _al(n, 0); // extend once
        // the 30d backstop is measured from mintStart and is untouched by the soft-close
        vm.warp(s + n.LAUNCH_BACKSTOP());
        assertFalse(n.launchBackstopExpired(), "backstop not armed at the exact boundary");
        vm.warp(s + n.LAUNCH_BACKSTOP() + 1);
        assertTrue(n.launchBackstopExpired(), "backstop still arms from mintStart, not overflowEnd");
    }

    // ─── pass-13: treasury reserve (reserveMint) ───────────────────────────────

    address constant TREASURY = address(0x7EA5);

    /// happy path: 25 passes take ids 1..25, land in the treasury, count against supply, skip price + cap
    function test_reserveMint_happyPath() public {
        NFTCollection n = _newCollection(); // phase CLOSED, recipients set, unstarted
        vm.expectEmit(true, false, false, true, address(n));
        emit NFTCollection.ReserveMinted(TREASURY, 25);
        n.reserveMint(25, TREASURY);
        assertEq(n.totalMinted(), 25, "25 minted");
        assertEq(n.balanceOf(TREASURY), 25, "all to treasury");
        assertEq(n.ownerOf(1), TREASURY, "id 1 is the first reserved");
        assertEq(n.ownerOf(25), TREASURY, "id 25 is the last reserved");
        assertTrue(n.reserveMinted(), "latched");
        assertEq(n.mintedBy(TREASURY), 0, "reserve does not consume the per-wallet cap");
        // the sale continues from id 26
        n.openAllowlistMint();
        vm.warp(n.publicOpensAt());
        uint256 id = _mintOn(n, makeAddr("buyer"));
        assertEq(id, 26, "first sale mint is id 26");
    }

    /// reserve of 25 exceeds every per-wallet cap (max 20 public), proving it bypasses the cap
    function test_reserveMint_bypassesWalletCap() public {
        NFTCollection n = _newCollection();
        assertGt(uint256(25), n.PUBLIC_CAP()); // 25 > 20
        n.reserveMint(25, TREASURY);
        assertEq(n.balanceOf(TREASURY), 25);
    }

    /// no ETH is charged (reserveMint is not payable)
    function test_reserveMint_free() public {
        NFTCollection n = _newCollection();
        n.reserveMint(10, TREASURY);
        assertEq(address(n).balance, 0, "nothing paid");
        assertEq(n.lpReserve(), 0);
        assertEq(n.seedReserve(), 0);
        assertEq(n.teamReserve(), 0);
    }

    function test_reserveMint_onlyOwner() public {
        NFTCollection n = _newCollection();
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        n.reserveMint(25, TREASURY);
    }

    function test_reserveMint_oneShot() public {
        NFTCollection n = _newCollection();
        n.reserveMint(25, TREASURY);
        vm.expectRevert(NFTCollection.ReserveLocked.selector);
        n.reserveMint(1, TREASURY);
    }

    function test_reserveMint_onlyBeforeStart() public {
        NFTCollection n = _allowlistPhaseCollection(); // mintStart set
        vm.expectRevert(NFTCollection.AlreadyStarted.selector);
        n.reserveMint(25, TREASURY);
    }

    function test_reserveMint_capBound() public {
        NFTCollection n = _newCollection();
        uint256 tooBig = n.RESERVE_CAP() + 1; // read the getter BEFORE arming expectRevert
        vm.expectRevert(NFTCollection.ReserveTooLarge.selector);
        n.reserveMint(tooBig, TREASURY);
        vm.expectRevert(NFTCollection.ReserveTooLarge.selector);
        n.reserveMint(0, TREASURY);
    }

    /// reserve requires recipients set first (recipients frozen before any mint; setRecipients->reserve order)
    function test_reserveMint_requiresRecipients() public {
        NFTCollection n = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        vm.expectRevert(NFTCollection.RecipientsUnset.selector);
        n.reserveMint(25, TREASURY);
    }

    /// a reserved treasury can still mint on the sale paths (its cap was never touched)
    function test_reserveMint_treasuryCanStillMint() public {
        NFTCollection n = _newCollection();
        n.reserveMint(25, TREASURY);
        n.openAllowlistMint();
        vm.warp(n.publicOpensAt());
        vm.deal(TREASURY, 3 * PRICE);
        vm.prank(TREASURY);
        n.mintBatch{ value: 3 * PRICE }(3);
        assertEq(n.mintedBy(TREASURY), 3, "sale cap counts from zero, independent of the reserve");
        assertEq(n.balanceOf(TREASURY), 28, "25 reserved + 3 bought");
    }

    function _mintOn(NFTCollection n, address who) internal returns (uint256) {
        vm.deal(who, PRICE);
        vm.prank(who);
        n.mint{ value: PRICE }();
        return n.totalMinted();
    }

    // ─── soft-close invariant MAX_EXTENSION() < PUBLIC_MINT_WINDOW() ─────

    /// The invariant holds for the base contract and EVERY shipped subclass, and the guard is inert for them.
    function test_softClose_invariantHoldsForBaseAndShippedSubclasses() public {
        // base (already started in setUp without reverting; assert the inequality explicitly)
        assertLt(nft.MAX_EXTENSION(), nft.PUBLIC_MINT_WINDOW(), "base: 6h < 24h");
        // the small-cap test subclass
        SmallCapNFT sc = new SmallCapNFT(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        assertLt(sc.MAX_EXTENSION(), sc.PUBLIC_MINT_WINDOW(), "SmallCapNFT: 10m < 24h");
        // the never-mainnet testnet subclass (short clock): 1m < 6m, and it still opens cleanly
        NFTCollectionTestnet tn =
            new NFTCollectionTestnet(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        assertLt(tn.MAX_EXTENSION(), tn.PUBLIC_MINT_WINDOW(), "NFTCollectionTestnet: 1m < 6m");
        tn.setRecipients(lpTreasury, seedTreasury, team);
        tn.setAllowlistRoot(alRoot);
        tn.setMintOpen(true);
        tn.openAllowlistMint();
        assertEq(tn.mintStart(), block.timestamp, "testnet subclass starts under the guard");
    }

    /// A mis-set subclass (MAX_EXTENSION >= PUBLIC_MINT_WINDOW) fails LOUDLY at openAllowlistMint instead of
    /// silently shrinking the public window to zero. Equality is the exact boundary and must revert too.
    function test_softClose_misSetSubclassFailsLoudly() public {
        // equality: the soft-close could push overflowEnd exactly onto the fixed close (zero public window)
        BadSoftCloseNFT eq = _badSoftClose(PUB_W);
        vm.expectRevert(NFTCollection.SoftCloseEatsPublicWindow.selector);
        eq.openAllowlistMint();
        assertEq(eq.mintStart(), 0, "never started");
        // strictly greater: same loud failure
        BadSoftCloseNFT gt = _badSoftClose(PUB_W + 1);
        vm.expectRevert(NFTCollection.SoftCloseEatsPublicWindow.selector);
        gt.openAllowlistMint();
        // one second under the window: a (tiny) public window survives, so it is allowed
        BadSoftCloseNFT ok = _badSoftClose(PUB_W - 1);
        ok.openAllowlistMint();
        assertEq(ok.mintStart(), block.timestamp, "starts when the invariant holds");
    }

    function _badSoftClose(uint256 ext) internal returns (BadSoftCloseNFT n) {
        n = new BadSoftCloseNFT(PRICE, address(oracle), 1 hours, address(renderer), address(this), ext);
        n.setRecipients(lpTreasury, seedTreasury, team);
        n.setAllowlistRoot(alRoot);
        n.setMintOpen(true);
    }

    // ─── reserve-then-abandon backstop (reserveAt clock) ──────────────

    /// The brick: setRecipients -> reserveMint -> owner key lost before openAllowlistMint. Real tokens exist,
    /// mintStart is 0 forever, and (in an earlier version) nothing ever armed the permissionless finalize. Now the
    /// LAUNCH_BACKSTOP runs from reserveAt, so a stranger can finalize (reveal + unblock the pool gate).
    function test_reserveThenAbandon_strangerCanFinalizeAfterBackstop() public {
        NFTCollection n = _newCollection(); // recipients set, root set, unstarted
        assertEq(n.reserveAt(), 0, "no reserve clock before the reserve");
        n.reserveMint(25, TREASURY);
        assertEq(n.reserveAt(), block.timestamp, "reserveAt stamped when the reserve is taken");
        // NOTE: anchor on the STORED stamp, not a `block.timestamp` local. Under via_ir the optimizer may
        // rematerialize TIMESTAMP after a vm.warp (a legal EVM assumption that only cheatcodes violate),
        // which silently shifts every later `t0 + ...` expression. An external read cannot be rematerialized.
        uint256 t0 = n.reserveAt();
        assertEq(n.mintStart(), 0, "mint never opened (owner vanished)");
        address stranger = makeAddr("stranger");

        // before the backstop: owner-only, exactly as before
        assertFalse(n.launchBackstopExpired(), "not armed right after the reserve");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        n.finalizeLaunch();

        // AT the exact boundary: still not armed (strict >, same as the mintStart clock)
        vm.warp(t0 + BACKSTOP);
        assertFalse(n.launchBackstopExpired(), "not armed at the exact boundary");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        n.finalizeLaunch();

        // one second past it: armed; a stranger finalizes the reserved-only collection
        vm.warp(t0 + BACKSTOP + 1);
        assertTrue(n.launchBackstopExpired(), "reserve clock arms the backstop with mintStart == 0");
        vm.prank(stranger);
        n.finalizeLaunch();
        assertTrue(n.launched(), "stranger rescued the reserve-then-abandon brick");
        assertGt(n.revealRound(), 0, "rarities sealed");
        // the reserved passes reveal like any other
        oracle.setBeacon(n.revealRound(), keccak256("rescue"));
        assertLe(n.rarityOf(1), 3, "reserved pass has a rarity");
        assertLe(n.rarityOf(25), 3, "last reserved pass has a rarity");
        // and the mint can never be opened under a finalized collection
        vm.expectRevert(NFTCollection.AlreadyLaunched.selector);
        n.openAllowlistMint();
    }

    /// Once the mint starts, ONLY the mintStart clock counts: the reserve clock can never close or race a
    /// live mint, even when reserveAt + BACKSTOP has long passed.
    function test_reserveThenOpen_reserveClockYieldsToMintStartClock() public {
        NFTCollection n = _newCollection();
        n.reserveMint(5, TREASURY);
        uint256 t0 = n.reserveAt(); // stored stamp (see the via_ir TIMESTAMP-rematerialization note above)
        vm.warp(t0 + 20 days); // a long (but < BACKSTOP) gap, then the owner does open the mint
        n.openAllowlistMint();
        uint256 s = n.mintStart();
        assertEq(s, t0 + 20 days);

        // reserveAt + BACKSTOP + 1 has passed, but the mint is live: the mintStart clock governs
        vm.warp(t0 + BACKSTOP + 1);
        assertFalse(n.launchBackstopExpired(), "reserve clock is ignored once the mint has started");
        // the mintStart clock still arms at its own boundary
        vm.warp(s + BACKSTOP);
        assertFalse(n.launchBackstopExpired(), "mintStart clock: not armed at the exact boundary");
        vm.warp(s + BACKSTOP + 1);
        assertTrue(n.launchBackstopExpired(), "mintStart clock arms as before");
    }

    /// With NO tokens minted (no reserve, no start) there is nothing to rescue: no clock runs, ever.
    function test_noReserveNoStart_backstopNeverArms() public {
        NFTCollection n = _newCollection();
        vm.warp(block.timestamp + 365 days);
        assertFalse(n.launchBackstopExpired(), "no reserve, no start: nothing arms");
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        n.finalizeLaunch();
    }

    /// The reserve-only state has NO live mint path for the reserve clock to race: phase() is CLOSED.
    function test_reserveOnly_noMintPathIsLive() public {
        NFTCollection n = _newCollection();
        n.reserveMint(5, TREASURY);
        vm.warp(block.timestamp + BACKSTOP + 1); // reserve clock armed
        assertTrue(n.launchBackstopExpired());
        assertEq(uint8(n.phase()), uint8(NFTCollection.MintPhase.CLOSED), "unstarted: CLOSED");
        vm.deal(alw[0], 2 * PRICE);
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.mint{ value: PRICE }();
        vm.prank(alw[0]);
        vm.expectRevert(NFTCollection.MintClosed.selector);
        n.allowlistMint{ value: PRICE }(1, _proofFor(0));
    }

    // ─── reveal liveness fallback (permissionless, time-predetermined) ──

    uint256 constant STEP = 7 days; // REVEAL_FALLBACK_STEP()

    event RevealFallbackAdvanced(uint256 indexed rung, uint64 fromRound, uint64 toRound, uint256 rungTime);

    /// A finalized collection (one mint, owner finalize at the current block) on a FRESH instance.
    function _finalized() internal returns (NFTCollection n) {
        n = _publicPhaseCollection();
        _mintOn(n, alice);
        n.finalizeLaunch();
    }

    /// The tier rarityOf must return for `tokenId` under `beacon` (the contract's own formula).
    function _tierFor(bytes32 beacon, uint256 tokenId) internal pure returns (uint8) {
        uint256 roll = uint256(keccak256(abi.encodePacked(beacon, tokenId, "nft"))) % 10_000;
        if (roll < 200) return 3;
        if (roll < 1000) return 2;
        if (roll < 3000) return 1;
        return 0;
    }

    function test_revealFallback_constantsAndAnchor() public {
        assertEq(nft.REVEAL_FALLBACK_STEP(), STEP, "7-day fallback step");
        assertEq(nft.revealBoundAt(), 0, "unbound before finalize");
        assertEq(nft.revealFallbackRung(), 0, "no rung before finalize");
        uint256 t = block.timestamp;
        nft.finalizeLaunch();
        assertEq(nft.revealBoundAt(), t, "revealBoundAt stamped at finalize");
        assertEq(nft.revealFallbackRung(), 0, "rung 0 = the finalizeLaunch round");
    }

    /// The constructor refuses revealDelay_ >= REVEAL_FALLBACK_STEP(). Otherwise rung 1 of the fallback
    /// ladder (revealBoundAt + STEP) would fall due before the original reveal round (revealBoundAt + revealDelay)
    /// even exists, letting a not-yet-producible reveal be "fallen back" from. Equality is the boundary and reverts.
    function test_revealFallback_ctorRejectsRevealDelayAtOrAboveStep() public {
        // base: 7d == STEP reverts, 7d + 1 reverts, 7d - 1 constructs (and the shipped 1h is far under it)
        vm.expectRevert(NFTCollection.RevealDelayExceedsFallbackStep.selector);
        new NFTCollection(PRICE, address(oracle), STEP, address(renderer), address(this));
        vm.expectRevert(NFTCollection.RevealDelayExceedsFallbackStep.selector);
        new NFTCollection(PRICE, address(oracle), STEP + 1, address(renderer), address(this));
        NFTCollection ok =
            new NFTCollection(PRICE, address(oracle), STEP - 1, address(renderer), address(this));
        assertEq(ok.revealDelay(), STEP - 1, "one second under the step constructs");
        assertLt(nft.revealDelay(), nft.REVEAL_FALLBACK_STEP(), "shipped 1h < 7d");
        // the guard reads the VIRTUAL getter: a subclass that shortens the step is held to its own step
        vm.expectRevert(NFTCollection.RevealDelayExceedsFallbackStep.selector);
        new ShortFallbackNFT(PRICE, address(oracle), 2 hours, address(renderer), address(this));
        ShortFallbackNFT sf =
            new ShortFallbackNFT(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        assertEq(sf.REVEAL_FALLBACK_STEP(), 2 hours, "override seen");
        assertLt(sf.revealDelay(), sf.REVEAL_FALLBACK_STEP(), "1h < 2h constructs");
        // the 1h revealDelay floor still comes first: below 1h is BadRevealDelay, not the step error
        vm.expectRevert(NFTCollection.BadRevealDelay.selector);
        new ShortFallbackNFT(PRICE, address(oracle), 1 hours - 1, address(renderer), address(this));
        // the never-mainnet testnet subclass keeps the 7d step and constructs under the guard with 1h
        NFTCollectionTestnet tn =
            new NFTCollectionTestnet(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        assertLt(tn.revealDelay(), tn.REVEAL_FALLBACK_STEP(), "NFTCollectionTestnet: 1h < 7d");
    }

    // ── ERC-4906: the reveal must be visible to marketplaces ─────────────────

    /// tokenURI flips from sealed art to the token's tier the instant the drand beacon lands, and NO
    /// transaction touches this contract at that moment — the change is a pure function of an external
    /// oracle becoming readable. Marketplaces refresh on an ERC-4906 event or not at all, so without
    /// pokeReveal the collection can sit showing 3,500 sealed packs after a successful reveal.
    function test_erc4906_pokeRevealAnnouncesTheReveal() public {
        NFTCollection n = _finalized();
        assertFalse(n.isRevealed(), "sealed until the beacon lands");

        // refused while sealed, so it cannot be looped to make marketplaces re-cache the SEALED art
        vm.expectRevert(NFTCollection.NotRevealed.selector);
        n.pokeReveal();

        oracle.setBeacon(n.revealRound(), keccak256("reveal"));
        assertTrue(n.isRevealed());

        vm.expectEmit(false, false, false, true, address(n));
        emit BatchMetadataUpdate(1, n.totalMinted());
        vm.prank(makeAddr("anyoneAtAll")); // permissionless by design
        n.pokeReveal();
    }

    /// Idempotent and stateless: repeat calls are harmless, so there is nothing to grief.
    function test_erc4906_pokeRevealIsIdempotent() public {
        NFTCollection n = _finalized();
        oracle.setBeacon(n.revealRound(), keccak256("reveal"));
        n.pokeReveal();
        n.pokeReveal();
        n.pokeReveal();
        assertTrue(n.isRevealed(), "no state was touched");
    }

    /// Marketplaces check ERC-165 for 0x49064906 before honouring the event, so advertising it is required
    /// for the event to be acted on at all. ERC-721 and ERC-165 must still answer.
    function test_erc4906_interfaceIsAdvertised() public view {
        assertTrue(nft.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC-721 still answered");
        assertTrue(nft.supportsInterface(0x01ffc9a7), "ERC-165 still answered");
    }

    // ── the write-once bindings are validated, and the hook is contained ──

    /// Both bindings are WRITE-ONCE and `_enforceLaunchLock` reads the hook on EVERY transfer, so an
    /// unvalidated wrong address would brick the whole collection permanently with no escape.
    function test_setTaxHookRejectsEoaAndNonHookContract() public {
        NFTCollection n = _newCollection();
        vm.expectRevert(NFTCollection.NotAContract.selector);
        n.setTaxHook(makeAddr("justAnEoa"));

        // a contract that EXISTS but has no ITaxHook: code.length alone would have accepted this
        NotAHook nah = new NotAHook();
        vm.expectRevert(NFTCollection.BadInterface.selector);
        n.setTaxHook(address(nah));

        // a real one is accepted, and the binding stays write-once
        FlakyHook ok = new FlakyHook();
        n.setTaxHook(address(ok));
        assertEq(address(n.taxHook()), address(ok));
        // NOTE: hoist the CREATE out. vm.expectRevert applies to the NEXT call, and `new FlakyHook()`
        // inside the argument list executes first, so the expectation would attach to the constructor.
        FlakyHook second = new FlakyHook();
        vm.expectRevert(NFTCollection.HookAlreadySet.selector);
        n.setTaxHook(address(second));
    }

    function test_setDelegateRegistryRejectsEoaAndNonRegistry() public {
        NFTCollection n = _newCollection();
        vm.expectRevert(NFTCollection.NotAContract.selector);
        n.setDelegateRegistry(makeAddr("eoa"));
        NotAHook nah = new NotAHook();
        vm.expectRevert(NFTCollection.BadInterface.selector);
        n.setDelegateRegistry(address(nah));
    }

    /// The half the setter cannot cover: a hook that validated at wiring time and later starts reverting.
    /// FAIL-OPEN is deliberate — the launch lock is an anti-sniper measure over a bounded window, not a
    /// fund-safety invariant, so losing it beats bricking a 3,500-piece collection permanently.
    function test_brokenHookDoesNotBrickTransfers() public {
        NFTCollection n = _newCollection();
        FlakyHook h = new FlakyHook();
        n.setTaxHook(address(h));
        n.openAllowlistMint();
        vm.warp(n.publicOpensAt());
        _mintOn(n, alice);
        uint256 id = 1;

        h.breakIt(); // the hook now reverts on every read

        address recipient = makeAddr("f2recipient");
        vm.prank(alice);
        n.transferFrom(alice, recipient, id); // MUST NOT revert
        assertEq(n.ownerOf(id), recipient, "transfer survived a hook that reverts on every call");
    }

    function test_revealFallback_revertsBeforeAnyBinding() public {
        // nft is in PUBLIC, not finalized: no round to fall back from
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NFTCollection.RevealNotBound.selector);
        nft.advanceRevealFallback();
    }

    /// "Nobody posted it" is not "Drand never produced it". Beacons are public off-chain the
    /// moment they exist and submitBeacon is permissionless, so without this guard anyone could compute what
    /// the bound round would seal, dislike it, decline to post it, and re-roll the rarity map of the whole
    /// collection once the rung fell due — a free, repeatable selective-rejection option. The ladder now
    /// requires evidence the chain moved PAST the round being discarded.
    function test_ladderNeedsEvidenceTheRoundWasSkipped() public {
        NFTCollection n = _finalized();
        uint64 cur = n.revealRound();
        oracle.setHighestRound(cur); // nothing later has ever been relayed here
        vm.warp(n.revealBoundAt() + STEP + 1); // the rung is due and `cur` is long overdue

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NFTCollection.RevealRoundNotSkipped.selector);
        n.advanceRevealFallback();
        assertEq(n.revealRound(), cur, "round untouched");
        assertEq(n.revealFallbackRung(), 0, "no rung taken without evidence");

        // a LATER beacon is now on chain: the chain ran on without `cur`, which is the case the ladder exists
        // for, and the only case in which advancing could ever have helped.
        oracle.setHighestRound(cur + 1);
        vm.prank(makeAddr("stranger"));
        n.advanceRevealFallback();
        assertGt(n.revealRound(), cur, "with evidence it advances, to a FUTURE round as always");
        assertEq(n.revealFallbackRung(), 1);
    }

    /// The honest resolution always wins over the lever: posting `cur` itself ends the game permanently,
    /// even when the evidence for a skip is present.
    function test_postingTheRoundStillBeatsTheLadder() public {
        NFTCollection n = _finalized();
        uint64 cur = n.revealRound();
        oracle.setHighestRound(cur + 1); // evidence present
        vm.warp(n.revealBoundAt() + STEP + 1);
        oracle.setBeacon(cur, keccak256("posted after all")); // ...but somebody just posted it
        vm.expectRevert(NFTCollection.RevealAlreadyResolved.selector);
        n.advanceRevealFallback();
        assertTrue(n.isRevealed());
    }

    /// (a) A reveal whose beacon has landed can NEVER be re-rolled, however much time passes, by anyone.
    function test_revealFallback_blockedWhileCurrentRoundAvailable() public {
        NFTCollection n = _finalized();
        uint64 r0 = n.revealRound();
        oracle.setBeacon(r0, keccak256("r0")); // the honest path: the beacon is posted
        vm.warp(n.revealBoundAt() + 3 * STEP + 1); // several rungs "due" by time alone
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealAlreadyResolved.selector);
        n.advanceRevealFallback();
        vm.expectRevert(NFTCollection.RevealAlreadyResolved.selector);
        n.advanceRevealFallback(); // the owner has no lever either
        assertEq(n.revealRound(), r0, "round untouched");
        assertEq(n.revealFallbackRung(), 0, "no rung taken");
        assertTrue(n.isRevealed());
    }

    /// (b) The rung must be DUE: one second early reverts; the exact instant is allowed (>=).
    function test_revealFallback_notDueBeforeRungInstant() public {
        NFTCollection n = _finalized();
        uint256 b = n.revealBoundAt();
        uint64 r0 = n.revealRound();
        address stranger = makeAddr("stranger");
        vm.warp(b + STEP - 1);
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealFallbackNotDue.selector);
        n.advanceRevealFallback();
        vm.expectRevert(NFTCollection.RevealFallbackNotDue.selector);
        n.advanceRevealFallback(); // owner: same rule, no shortcut
        assertEq(n.revealRound(), r0, "unchanged while not due");
        vm.warp(b + STEP); // exactly due
        vm.prank(stranger);
        n.advanceRevealFallback();
        // The binding is roundAt(now + revealDelay), a FUTURE round, not
        // roundAt(b + STEP) — that instant has already passed, so its beacon would already be public.
        assertEq(n.revealRound(), oracle.roundAt(block.timestamp + n.revealDelay()), "bound to a FUTURE round");
        assertEq(n.revealFallbackRung(), 1);
    }

    /// (c) Past the rung instant with the round still unavailable, ANYONE advances.
    /// The new binding is a FUTURE round (roundAt(now + revealDelay)), not the round at the rung
    /// instant. Rarity then resolves from it once its beacon lands.
    function test_revealFallback_anyoneAdvancesToAFutureRound() public {
        NFTCollection n = _finalized();
        uint256 b = n.revealBoundAt();
        uint64 r0 = n.revealRound();

        vm.warp(b + STEP + 3 hours); // an arbitrary instant past rung 1
        uint64 expected = oracle.roundAt(block.timestamp + n.revealDelay());
        assertTrue(expected != r0, "the fallback round differs from the never-produced one");
        assertFalse(oracle.isAvailable(r0), "r0 never produced");
        address stranger = makeAddr("stranger");
        vm.expectEmit(true, false, false, true, address(n));
        emit RevealFallbackAdvanced(1, r0, expected, block.timestamp);
        vm.prank(stranger);
        n.advanceRevealFallback();

        assertEq(n.revealRound(), expected, "bound to a future round");
        assertEq(n.revealFallbackRung(), 1, "rung 1 taken");
        assertFalse(n.isRevealed(), "still sealed until the NEW round's beacon lands");
        vm.expectRevert(); // rarity now keys off the new round, which is not posted yet
        n.rarityOf(1);

        bytes32 beacon = keccak256("r1");
        oracle.setBeacon(expected, beacon);
        assertTrue(n.isRevealed(), "revealed from the fallback round");
        assertEq(n.rarityOf(1), _tierFor(beacon, 1), "rarity derives from the CURRENT (fallback) round");

        // resolved: the ladder is closed for good
        vm.warp(b + 5 * STEP);
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealAlreadyResolved.selector);
        n.advanceRevealFallback();
        assertEq(n.revealRound(), expected, "never re-rolled after resolution");
    }

    /// An earlier version of this test was called "TIME-DETERMINISM (no grinding)"
    /// and asserted that two callers at different instants bind the SAME round. That determinism WAS the
    /// grinding surface: the round it pinned was `roundAt(revealBoundAt + k*STEP)`, an instant already in
    /// the past, so its beacon was public and a caller could choose which rung to stop on. The property we
    /// actually need is the opposite: every binding is a round in the FUTURE, hence unknowable, so the
    /// call's timing selects nothing of VALUE even though it does select a different round.
    function test_differentCallTimesBindDifferentButAlwaysFutureRounds() public {
        NFTCollection a = _allowlistPhaseCollection();
        NFTCollection b = _allowlistPhaseCollection();
        vm.warp(a.publicOpensAt());
        _mintOn(a, alice);
        _mintOn(b, alice);
        a.finalizeLaunch();
        b.finalizeLaunch();
        assertEq(a.revealBoundAt(), b.revealBoundAt(), "same anchor");
        assertEq(a.revealRound(), b.revealRound(), "same rung-0 round");
        uint256 bound = a.revealBoundAt();

        // NOTE ON TEST AUTHORING (via_ir hazard, found writing this test): do NOT capture block.timestamp
        // into a local, then vm.warp, then use the local. Under via_ir the optimizer treats block.timestamp
        // as invariant within a call and REMATERIALIZES it at the use site, so the local silently tracks the
        // warped time. Proven here: a captured copy printed 1777600 immediately and 2382399 after a warp,
        // with no reassignment. Assert against block.timestamp at the instant it matters instead.
        vm.warp(bound + STEP); // first instant rung 1 is due
        vm.prank(makeAddr("early"));
        a.advanceRevealFallback();
        uint64 aRound = a.revealRound();
        assertGt(_roundPublishTime(aRound), block.timestamp, "early call bound an UNPUBLISHED round");

        vm.warp(bound + 2 * STEP - 1); // much later
        vm.prank(makeAddr("late"));
        b.advanceRevealFallback();
        uint64 bRound = b.revealRound();
        assertGt(_roundPublishTime(bRound), block.timestamp, "late call bound an UNPUBLISHED round");

        // different call times bind DIFFERENT rounds now, and that is correct: every candidate is equally
        // unknowable, so timing selects nothing of VALUE.
        assertTrue(aRound != bRound, "the call instant selects a different round, by design");
    }

    /// @dev In MockDrandOracle, roundAt(ts) is a CEIL, so round r first publishes at gen + (r-1)*per.
    function _roundPublishTime(uint64 r) internal view returns (uint256) {
        return oracle.gen() + (uint256(r) - 1) * oracle.per();
    }

    /// REGRESSION GATE. The earlier binding fails this outright: the ladder bound roundAt(rungTime) where
    /// rungTime <= block.timestamp by the gate immediately above it, so the round was ALREADY PUBLISHED
    /// and its beacon readable in drand's archive at the moment it became the seal for all 3,500 rarities.
    function test_fallbackNeverBindsAnAlreadyPublishedRound() public {
        NFTCollection n = _finalized();
        uint256 b = n.revealBoundAt();
        // walk several rungs, each one late, and check EVERY binding is still in the future
        for (uint256 k = 1; k <= 3; ++k) {
            vm.warp(b + k * STEP + 5 days); // deliberately long past the rung instant
            vm.prank(makeAddr("stranger"));
            n.advanceRevealFallback();
            assertGt(
                _roundPublishTime(n.revealRound()),
                block.timestamp,
                "a fallback binding must never be a round whose beacon is already public"
            );
            b = n.revealBoundAt(); // re-anchored to this advance
        }
    }

    /// An earlier version of this test asserted "the next call walks to rung 2 (same block is fine)".
    /// Same-block walking IS the grinding mechanism: with several rungs due, a caller stepped through them,
    /// read each already-published candidate beacon, stopped on the best rarity map, and welded it in via
    /// the permissionless submitBeacon in the same transaction. Re-anchoring revealBoundAt on every advance
    /// makes exactly one advance possible per REVEAL_FALLBACK_STEP, however late the call.
    function test_cannotWalkMultipleRungsInOneBlock() public {
        NFTCollection n = _finalized();
        uint256 b = n.revealBoundAt();
        uint64 r0 = n.revealRound();
        address stranger = makeAddr("stranger");

        vm.warp(b + 3 * STEP + 1); // three rungs "due" by elapsed time
        vm.prank(stranger);
        n.advanceRevealFallback();
        uint64 first = n.revealRound();
        assertEq(n.revealFallbackRung(), 1, "one advance only, however many rungs elapsed");
        assertEq(n.revealBoundAt(), block.timestamp, "anchor moved to this advance");

        // the second call in the SAME block must now revert -- this is the grinding surface, closed
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealFallbackNotDue.selector);
        n.advanceRevealFallback();
        assertEq(n.revealRound(), first, "round unchanged by the refused walk");

        // and a full step later exactly one further advance is possible
        vm.warp(block.timestamp + STEP);
        vm.prank(stranger);
        n.advanceRevealFallback();
        assertEq(n.revealFallbackRung(), 2);
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealFallbackNotDue.selector);
        n.advanceRevealFallback();

        uint64 r2 = n.revealRound();
        assertTrue(r2 != r0);
        // the beacon lands: resolved, ladder closed for good
        bytes32 beacon = keccak256("r2");
        oracle.setBeacon(r2, beacon);
        assertEq(n.rarityOf(1), _tierFor(beacon, 1), "rarity resolves from the current round");
        vm.warp(block.timestamp + 10 * STEP);
        vm.prank(stranger);
        vm.expectRevert(NFTCollection.RevealAlreadyResolved.selector);
        n.advanceRevealFallback();
    }

    /// No stale binding: after a re-bind, a LATE beacon for the old round changes nothing; rarity keys off
    /// the current round only.
    function test_revealFallback_lateOldBeaconIsIgnoredAfterRebind() public {
        NFTCollection n = _finalized();
        uint256 b = n.revealBoundAt();
        uint64 r0 = n.revealRound();
        vm.warp(b + STEP);
        vm.prank(makeAddr("stranger"));
        n.advanceRevealFallback();
        uint64 r1 = n.revealRound();

        oracle.setBeacon(r0, keccak256("r0-late")); // the old round shows up after the re-bind
        assertFalse(n.isRevealed(), "old round's beacon does not reveal the collection");
        vm.expectRevert();
        n.rarityOf(1);

        bytes32 beacon = keccak256("r1");
        oracle.setBeacon(r1, beacon);
        assertTrue(n.isRevealed());
        assertEq(n.rarityOf(1), _tierFor(beacon, 1), "rarity from the current round, not the stale one");
    }

    /// The three payout destinations are frozen at the first mint, `withdrawProceeds` is PERMISSIONLESS and
    /// pays exactly them forever, and those calls are the only ETH exits in the contract -- no rescue, no
    /// sweep, no owner override. So a recipient that cannot accept ETH strands its share of the raise
    /// permanently, and for the LP leg that is 80% of it.
    ///
    /// Earlier operator guidance steered straight into this: it said the LP destination
    /// "should be a locker, for trustlessness", and QpullLiquidityLock has no receive(), no fallback and no
    /// payable member at all. Following the advice used to pass every check here.
    function test_setRecipients_refusesADestinationThatCannotReceiveEth() public {
        NoReceive locker = new NoReceive(); // stands in for QpullLiquidityLock: no receive, no fallback
        NFTCollection n2 = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));

        vm.expectRevert(abi.encodeWithSelector(NFTCollection.RecipientCannotReceiveEth.selector, address(locker)));
        n2.setRecipients(address(locker), seedTreasury, team);
        vm.expectRevert(abi.encodeWithSelector(NFTCollection.RecipientCannotReceiveEth.selector, address(locker)));
        n2.setRecipients(lpTreasury, address(locker), team);
        vm.expectRevert(abi.encodeWithSelector(NFTCollection.RecipientCannotReceiveEth.selector, address(locker)));
        n2.setRecipients(lpTreasury, seedTreasury, address(locker));

        n2.setRecipients(lpTreasury, seedTreasury, team); // ordinary payable destinations still fine
        assertEq(n2.lpTreasury(), lpTreasury);
    }
}

/// A contract with neither receive() nor a payable fallback -- the QpullLiquidityLock shape.
contract NoReceive { }
