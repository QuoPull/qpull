// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// @notice Proves the fully on-chain art pipeline: SSTORE2 stores the master halftone tiles byte-for-byte,
///         the reveal flips sealed -> tier art via rarityOf, the per-token serial is the approved
///         smaller+italic style and is id-specific, and NFTCollection.tokenURI delegates correctly.
contract PassArtRendererTest is Test {
    NFTCollection nft;
    PassArtRenderer renderer;
    MockDrandOracle oracle;

    address alice = makeAddr("alice");
    uint256 constant GENESIS = 1_000_000;
    uint256 constant PRICE = 0.01 ether;
    uint256 constant CHUNK = 24_000;

    string constant SERIAL_STYLE = "scale(0.00750,-0.00750) skewX(12)"; // smaller + italic
    string constant SERIAL_MARK = '<g transform="translate(13.0,228.0)'; // start of the serial group

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 3);
        renderer = new PassArtRenderer(address(this));
        // load the real master art (same blobs the deploy script writes)
        _load(0, "web/art/onchain/common.inner");
        _load(1, "web/art/onchain/uncommon.inner");
        _load(2, "web/art/onchain/rare.inner");
        _load(3, "web/art/onchain/superrare.inner");
        _load(4, "web/art/onchain/sealed.svg");
        renderer.lock();

        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        nft.setRecipients(makeAddr("lp"), makeAddr("seed"), makeAddr("team"));
        nft.setAllowlistRoot(keccak256("art")); // any non-zero root; this suite mints on the open path
        nft.setMintOpen(true);
        // pass-11: `mintOpen` is the kill switch only — a mint also needs a LIVE window. Start the mint and
        // warp past GTD + overflow into the PUBLIC window; the art pipeline under test is window-agnostic, so
        // the shortest path to five minted ids (5 <= PUBLIC_CAP) is the right one here.
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt());
        vm.deal(alice, PRICE * 5);
        vm.prank(alice);
        nft.mintBatch{ value: PRICE * 5 }(5); // ids 1..5
    }

    // ── before reveal: sealed art, byte-exact, and NFT delegates with revealed=false ──
    function test_sealed_before_reveal_is_byte_exact() public view {
        assertFalse(nft.isRevealed(), "not revealed pre-finalize");
        string memory sealedFile = string(vm.readFileBinary("web/art/onchain/sealed.svg"));
        assertEq(renderer.renderSVG(1, false, 0), sealedFile, "sealed svg served verbatim");
        // NFT.tokenURI must delegate to the renderer with revealed=false
        assertEq(nft.tokenURI(1), renderer.tokenURI(1, false, 0), "nft delegates sealed uri");
        assertTrue(_startsWith(nft.tokenURI(1), "data:application/json;base64,"), "json data uri");
    }

    // ── reveal flips to tier art; the stored halftone is byte-identical to the master tile ──
    function test_reveal_inner_is_byte_identical_to_master() public {
        nft.finalizeLaunch();
        uint64 rr = nft.revealRound();
        assertFalse(nft.isRevealed(), "beacon not posted yet");
        oracle.setBeacon(rr, keccak256("beacon"));
        assertTrue(nft.isRevealed(), "revealed once beacon lands");

        for (uint256 id = 1; id <= 5; ++id) {
            uint8 r = nft.rarityOf(id);
            string memory svg = renderer.renderSVG(id, true, r);
            // extract the inner region (between the <svg ...> tag and the serial <g>) and compare byte-for-byte
            string memory innerOnChain = _between(svg, ">", SERIAL_MARK);
            string memory innerMaster = string(vm.readFileBinary(_innerPath(r)));
            assertEq(
                keccak256(bytes(innerOnChain)), keccak256(bytes(innerMaster)), "halftone stored byte-identical"
            );
            // NFT.tokenURI delegates with the revealed flag + the on-chain rarity
            assertEq(nft.tokenURI(id), renderer.tokenURI(id, true, r), "nft delegates revealed uri");
            // aria-label carries the matching tier name
            assertTrue(_contains(svg, _tierName(r)), "tier name in svg");
        }
    }

    // ── serial: approved smaller+italic style, correct fg, and id-specific ──
    function test_serial_style_and_id_specific() public view {
        // force the same tier for two ids so the ONLY difference is the serial
        string memory a = renderer.renderSVG(1, true, 0); // Common
        string memory b = renderer.renderSVG(2, true, 0); // Common
        assertTrue(_contains(a, SERIAL_STYLE), "smaller+italic serial transform");
        assertTrue(_contains(a, 'fill="#221B10"'), "common serial fg");
        assertTrue(_contains(a, 'transform="translate(0,0)"'), "No glyph at baseline-left");
        assertTrue(_contains(a, 'transform="translate(6480,0)"'), "last id digit position");
        // same tier => identical inner, so a != b proves the serial is id-specific
        assertTrue(keccak256(bytes(a)) != keccak256(bytes(b)), "serial differs by token id");
        // and the inner region is identical across same-tier ids
        assertEq(
            keccak256(bytes(_between(a, ">", SERIAL_MARK))),
            keccak256(bytes(_between(b, ">", SERIAL_MARK))),
            "same tier => same inner"
        );
    }

    // ── revert surface ──
    function test_addChunk_reverts_after_lock() public {
        vm.expectRevert(PassArtRenderer.Locked.selector);
        renderer.addChunk(0, "x");
    }

    function test_renderSVG_rejects_bad_rarity() public {
        vm.expectRevert(PassArtRenderer.NotRevealable.selector);
        renderer.renderSVG(1, true, 4);
    }

    function test_constructor_rejects_zero_renderer() public {
        vm.expectRevert(NFTCollection.ZeroRenderer.selector);
        new NFTCollection(PRICE, address(oracle), 1 hours, address(0), address(this));
    }

    // ── the bound art renderer MUST be locked (immutable) before the collection binds it ──
    function test_constructor_requires_locked_renderer() public {
        // a fresh, UNLOCKED renderer is rejected: its owner could still addChunk/swap the art post-deploy
        PassArtRenderer unlocked = new PassArtRenderer(address(this));
        vm.expectRevert(NFTCollection.RendererNotLocked.selector);
        new NFTCollection(PRICE, address(oracle), 1 hours, address(unlocked), address(this));
        // once locked, the same renderer binds fine
        unlocked.lock();
        NFTCollection ok = new NFTCollection(PRICE, address(oracle), 1 hours, address(unlocked), address(this));
        assertEq(address(ok.renderer()), address(unlocked), "locked renderer binds");
    }

    // ── gas guard: tokenURI is a VIEW (eth_call), but must stay well under common RPC caps (~50M) ──
    function test_tokenURI_view_cost_within_rpc_cap() public {
        nft.finalizeLaunch();
        oracle.setBeacon(nft.revealRound(), keccak256("beacon"));
        uint8 r = nft.rarityOf(1);
        uint256 g = gasleft();
        string memory uri = renderer.tokenURI(1, true, r);
        uint256 used = g - gasleft();
        emit log_named_uint("tokenURI gas (revealed)", used);
        emit log_named_uint("tokenURI length (bytes)", bytes(uri).length);
        assertLt(used, 40_000_000, "tokenURI must stay under a safe eth_call cap");
        assertTrue(_startsWith(uri, "data:application/json;base64,"), "json data uri");
    }

    // ── opt-in: dump the ACTUAL on-chain-rendered SVGs to web/art/onchain-preview/ (WRITE_PREVIEW=true) ──
    function test_write_onchain_preview() public {
        if (!vm.envOr("WRITE_PREVIEW", false)) return; // no-op in the normal suite
        nft.finalizeLaunch();
        oracle.setBeacon(nft.revealRound(), keccak256("beacon"));
        vm.writeFile("web/art/onchain-preview/sealed.svg", renderer.renderSVG(1, false, 0));
        vm.writeFile("web/art/onchain-preview/common.svg", renderer.renderSVG(3, true, 0));
        vm.writeFile("web/art/onchain-preview/uncommon.svg", renderer.renderSVG(4, true, 1));
        vm.writeFile("web/art/onchain-preview/rare.svg", renderer.renderSVG(1, true, 2));
        vm.writeFile("web/art/onchain-preview/superrare.svg", renderer.renderSVG(124, true, 3));
    }

    // ─────────────────────────── helpers ───────────────────────────
    function _load(uint8 slot, string memory path) internal {
        bytes memory data = vm.readFileBinary(path);
        uint256 off;
        while (off < data.length) {
            uint256 len = data.length - off;
            if (len > CHUNK) len = CHUNK;
            renderer.addChunk(slot, _slice(data, off, len));
            off += len;
        }
    }

    function _innerPath(uint8 r) internal pure returns (string memory) {
        if (r == 0) return "web/art/onchain/common.inner";
        if (r == 1) return "web/art/onchain/uncommon.inner";
        if (r == 2) return "web/art/onchain/rare.inner";
        return "web/art/onchain/superrare.inner";
    }

    function _tierName(uint8 r) internal pure returns (string memory) {
        if (r == 0) return "Common";
        if (r == 1) return "Uncommon";
        if (r == 2) return "Rare";
        return "Super rare";
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = data[start + i];
        }
    }

    /// substring of `s` from just after the first occurrence of `from` to the start of the first `to`.
    function _between(string memory s, string memory from, string memory to)
        internal
        pure
        returns (string memory)
    {
        uint256 a = _indexOf(s, from);
        require(a != type(uint256).max, "from not found");
        a += bytes(from).length;
        uint256 b = _indexOf(s, to);
        require(b != type(uint256).max && b >= a, "to not found");
        bytes memory sb = bytes(s);
        bytes memory out = new bytes(b - a);
        for (uint256 i; i < out.length; ++i) {
            out[i] = sb[a + i];
        }
        return string(out);
    }

    function _indexOf(string memory hay, string memory needle) internal pure returns (uint256) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return type(uint256).max;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return _indexOf(hay, needle) != type(uint256).max;
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (pb.length > sb.length) return false;
        for (uint256 i; i < pb.length; ++i) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }
}
