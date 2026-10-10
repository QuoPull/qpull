// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { SSTORE2 } from "../utils/SSTORE2.sol";
import { IPassArtRenderer } from "../interfaces/IPassArtRenderer.sol";

/// @title  PassArtRenderer
/// @notice Fully on-chain art for the QuoPull Art Pass. The four tier tiles (the halftone dot fields) and
///         the sealed tile are stored verbatim as SSTORE2 blobs at deploy; `tokenURI` reads them back and
///         assembles a `data:application/json;base64` metadata URI whose `image` is a `data:image/svg+xml`
///         URI, no IPFS, no `setBaseURI`. The reveal is driven entirely by NFTCollection.rarityOf (the
///         drand beacon), so the marketplace image flips from sealed to the token's tier the instant the
///         beacon is POSTED on chain. Nobody can choose or alter the art, and the image can never disagree
///         with the on-chain rarity.
/// @dev    Art is chunked because each tier SVG (~100KB) exceeds the 24KB runtime-code limit. `addChunk`
///         appends SSTORE2 pointers to a slot in order; `lock()` makes the art permanent. The per-token
///         serial (`№ 041-XXXX`) is generated on-chain as vector paths, byte-for-byte matching the
///         off-chain `serialPaths()` renderer (smaller + italic: scale 0.00750, skewX 12).
contract PassArtRenderer is IPassArtRenderer, Ownable {
    using Strings for uint256;

    // slots 0..3 = tier INNER content (bg rect + dot <g>); slot 4 = sealed FULL svg
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;
    uint8 internal constant SEALED = 4;

    mapping(uint8 => address[]) internal _chunks; // slot => ordered SSTORE2 pointers
    bool public locked; // once true, art is immutable

    // serial layout (mirrors serialPaths in web/art/quo-art.js): upem 1000, mono advance 700, tracking 0.02
    // -> per-glyph advance 720; scale = fs/upem = 7.5/1000 = 0.00750; italic skewX 12; baseline (13,228).
    uint256 internal constant ADVANCE = 720;

    error Locked();
    error BadSlot();
    error NotRevealable();

    constructor(address admin) Ownable(admin) {}

    // ─── art loading (deploy-time, then locked) ──────────────────────────────
    function addChunk(uint8 slot, bytes calldata data) external onlyOwner returns (address pointer) {
        if (locked) revert Locked();
        if (slot > SEALED) revert BadSlot();
        pointer = SSTORE2.write(data);
        _chunks[slot].push(pointer);
    }

    function lock() external onlyOwner {
        locked = true;
    }

    function chunkCount(uint8 slot) external view returns (uint256) {
        return _chunks[slot].length;
    }

    // ─── token URI ────────────────────────────────────────────────────────────
    /// @inheritdoc IPassArtRenderer
    function tokenURI(uint256 tokenId, bool revealed, uint8 rarity)
        external
        view
        override
        returns (string memory)
    {
        string memory image = renderSVG(tokenId, revealed, rarity);
        string memory attrs;
        string memory desc;
        if (!revealed) {
            attrs = '{"trait_type":"Tier","value":"Sealed"}';
            desc = "QuoPull Art Pass on Robinhood Chain. Sealed until reveal.";
        } else {
            attrs = string.concat(
                '{"trait_type":"Tier","value":"',
                _tierName(rarity),
                '"},{"trait_type":"Pool share","value":"',
                _pool(rarity),
                '"}'
            );
            desc =
                "QuoPull Art Pass on Robinhood Chain. Hold for free daily raffle entries and the weekly holder draw; buying $QPULL prints packs that pay fractional $QUOTRON from the protocol's vault.";
        }
        string memory json = string.concat(
            '{"name":"QuoPull #',
            tokenId.toString(),
            '","description":"',
            desc,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image)),
            '","attributes":[',
            attrs,
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ─── svg assembly ───────────────────────────────────────────────────────
    /// @notice The raw on-chain SVG for a pass (no JSON/base64 wrapper): sealed art while `revealed` is
    ///         false, else the token's tier art. Useful for consumers that want the image directly.
    function renderSVG(uint256 tokenId, bool revealed, uint8 rarity) public view returns (string memory) {
        if (!revealed) return _readSlot(SEALED); // full sealed svg, verbatim
        if (rarity > SUPER_RARE) revert NotRevealable();
        return _revealedSVG(tokenId, rarity);
    }

    function _revealedSVG(uint256 tokenId, uint8 rarity) internal view returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240" width="1200" height="1200" role="img" aria-label="QuoPull #',
            tokenId.toString(),
            " ",
            _tierName(rarity),
            '">',
            _readSlot(rarity), // stored inner (bg rect + halftone dots), byte-identical to the master tile
            _serialGroup(tokenId, _fg(rarity)),
            "</svg>"
        );
    }

    /// On-chain port of serialPaths('№ 041-XXXX', 13, 228, 7.5, fg, 0.02, 12): a <g> of vector glyph paths.
    function _serialGroup(uint256 tokenId, string memory fg) internal pure returns (string memory) {
        // sequence: № , space, 0, 4, 1, -, then the 4 zero-padded id digits
        uint256[10] memory seq = [
            uint256(12), // №
            11, // space (no path, but advances)
            0,
            4,
            1,
            10, // -
            (tokenId / 1000) % 10,
            (tokenId / 100) % 10,
            (tokenId / 10) % 10,
            tokenId % 10
        ];
        string memory body = "";
        uint256 ox = 0;
        for (uint256 i; i < 10; ++i) {
            string memory d = _glyph(seq[i]);
            if (bytes(d).length != 0) {
                body = string.concat(body, '<path d="', d, '" transform="translate(', ox.toString(), ',0)"/>');
            }
            ox += ADVANCE;
        }
        return string.concat(
            '<g transform="translate(13.0,228.0) scale(0.00750,-0.00750) skewX(12)" fill="', fg, '">', body, "</g>"
        );
    }

    function _readSlot(uint8 slot) internal view returns (string memory out) {
        address[] storage cs = _chunks[slot];
        uint256 n = cs.length;
        out = "";
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, string(SSTORE2.read(cs[i])));
        }
    }

    // ─── tier metadata ────────────────────────────────────────────────────────
    function _tierName(uint8 r) internal pure returns (string memory) {
        if (r == COMMON) return "Common";
        if (r == UNCOMMON) return "Uncommon";
        if (r == RARE) return "Rare";
        return "Super rare";
    }

    function _fg(uint8 r) internal pure returns (string memory) {
        if (r == COMMON) return "#221B10";
        if (r == UNCOMMON) return "#E8F3EA";
        if (r == RARE) return "#E4ECFA";
        return "#E8B65A";
    }

    function _pool(uint8 r) internal pure returns (string memory) {
        if (r == COMMON) return "10%";
        if (r == UNCOMMON) return "20%";
        if (r == RARE) return "25%";
        return "45%";
    }

    // ─── Martian-mono glyph paths (upem 1000), digits 0-9, '-', ' ', '№' ─────
    function _glyph(uint256 code) internal pure returns (string memory) {
        if (code == 0) return "M350 -18Q198 -18 120.5 87.5Q43 193 43 400Q43 607 120.5 712.5Q198 818 350 818Q502 818 579.5 712.5Q657 607 657 400Q657 193 579.5 87.5Q502 -18 350 -18ZM350 120Q430 120 468.5 188.5Q507 257 507 400Q507 543 468.5 611.5Q430 680 350 680Q270 680 231.5 611.5Q193 543 193 400Q193 257 231.5 188.5Q270 120 350 120ZM148 321 567 638V479L148 162Z";
        if (code == 1) return "M456 800V142H645V0H95V142H306V716L338 699L95 540V700L254 800Z";
        if (code == 2) return "M96 214 385 405Q435 438 458.0 475.5Q481 513 481 558Q481 615 449.0 647.5Q417 680 359 680Q303 680 267.5 646.0Q232 612 218 546H75Q80 632 116.5 693.0Q153 754 215.5 786.0Q278 818 359 818Q442 818 503.5 786.0Q565 754 598.0 696.0Q631 638 631 558Q631 476 588.5 410.0Q546 344 456 290L249 157V142H614V0H96Z";
        if (code == 3) return "M630 213Q630 145 595.5 92.5Q561 40 499.5 11.0Q438 -18 358 -18Q270 -18 206.5 13.0Q143 44 108.0 102.5Q73 161 71 244H211Q222 182 258.5 150.5Q295 119 356 119Q393 119 421.0 132.5Q449 146 464.0 170.5Q479 195 479 228Q479 280 448.5 310.0Q418 340 363 340H273V472H365Q421 472 453.0 500.0Q485 528 485 576Q485 623 451.0 652.0Q417 681 361 681Q298 681 259.5 647.5Q221 614 207 546H66Q70 633 106.5 693.5Q143 754 208.0 786.0Q273 818 363 818Q443 818 504.5 789.5Q566 761 600.0 710.0Q634 659 634 590Q634 528 601.5 483.5Q569 439 513 422V402Q567 384 598.5 334.0Q630 284 630 213Z";
        if (code == 4) return "M549 800V354H669V212H549V0H401V212H43V407L290 800ZM174 369V354H401V765H429Z";
        if (code == 5) return "M98 800H620V661H203L248 701V498H282Q303 517 334.0 527.5Q365 538 401 538Q471 538 524.0 504.5Q577 471 607.0 411.0Q637 351 637 271Q637 185 601.5 120.0Q566 55 503.5 18.5Q441 -18 358 -18Q231 -18 156.0 48.5Q81 115 72 234H215Q230 178 265.0 148.5Q300 119 355 119Q396 119 425.5 137.5Q455 156 471.0 190.5Q487 225 487 271Q487 316 471.0 348.0Q455 380 426.5 397.0Q398 414 357 414Q313 414 282.0 394.5Q251 375 236 336H98Z";
        if (code == 6) return "M349 -18Q266 -18 201.0 18.0Q136 54 99.0 118.0Q62 182 62 266Q62 328 85.0 391.0Q108 454 158 525L347 800H514L334 547L353 530Q360 532 368.5 533.0Q377 534 386 534Q459 534 515.5 499.0Q572 464 605.0 403.5Q638 343 638 266Q638 183 601.0 118.5Q564 54 499.0 18.0Q434 -18 349 -18ZM212 266Q212 222 229.5 189.0Q247 156 277.5 138.0Q308 120 349 120Q391 120 422.0 138.0Q453 156 470.5 189.0Q488 222 488 266Q488 310 471.0 342.0Q454 374 423.0 392.5Q392 411 351 411Q309 411 278.0 392.5Q247 374 229.5 342.0Q212 310 212 266Z";
        if (code == 7) return "M600 579 330 0H166L476 643V658H81V800H600Z";
        if (code == 8) return "M350 469Q416 469 452.5 497.0Q489 525 489 575Q489 625 452.5 653.0Q416 681 350 681Q284 681 247.5 653.0Q211 625 211 575Q211 525 247.5 497.0Q284 469 350 469ZM67 593Q67 662 102.0 712.5Q137 763 200.5 790.5Q264 818 350 818Q437 818 500.5 790.5Q564 763 598.5 712.5Q633 662 633 593Q633 532 601.5 486.0Q570 440 516 422V402Q570 383 602.0 332.0Q634 281 634 214Q634 143 599.0 91.0Q564 39 500.5 10.5Q437 -18 350 -18Q263 -18 199.5 10.5Q136 39 101.0 91.0Q66 143 66 214Q66 281 98.0 332.0Q130 383 184 402V422Q131 440 99.0 486.0Q67 532 67 593ZM213 232Q213 179 249.0 149.0Q285 119 350 119Q415 119 451.0 149.0Q487 179 487 232Q487 286 451.0 315.5Q415 345 350 345Q285 345 249.0 315.5Q213 286 213 232Z";
        if (code == 9) return "M351 818Q435 818 499.5 782.0Q564 746 601.0 682.0Q638 618 638 534Q638 472 615.0 409.5Q592 347 542 275L353 0H186L366 253L347 270Q341 268 332.5 267.0Q324 266 314 266Q241 266 184.5 301.0Q128 336 95.0 396.5Q62 457 62 534Q62 618 99.0 682.0Q136 746 201.5 782.0Q267 818 351 818ZM488 534Q488 578 471.0 611.0Q454 644 423.0 662.0Q392 680 351 680Q309 680 278.0 662.0Q247 644 229.5 611.5Q212 579 212 534Q212 491 229.5 458.5Q247 426 277.5 407.5Q308 389 349 389Q391 389 422.0 407.5Q453 426 470.5 458.5Q488 491 488 534Z";
        if (code == 10) return "M50 285V415H650V285Z"; // -
        if (code == 12) {
            return "M49 0V800H243L316 130H332L319 388V800H435V0H240L168 670H152L165 412V0ZM573 470Q535 470 511.0 487.5Q487 505 475.5 543.5Q464 582 464 644Q464 707 475.5 745.0Q487 783 511.0 800.5Q535 818 573 818Q611 818 635.0 800.5Q659 783 670.0 745.0Q681 707 681 644Q681 582 670.0 543.5Q659 505 635.0 487.5Q611 470 573 470ZM573 546Q584 546 588.0 566.0Q592 586 592 644Q592 702 588.0 722.0Q584 742 573 742Q561 742 557.0 722.0Q553 702 553 644Q553 586 557.0 566.0Q561 546 573 546ZM484 334V420H661V334Z"; // №
        }
        return ""; // 11 = space (advances, no path)
    }
}
