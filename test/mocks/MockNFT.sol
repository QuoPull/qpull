// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { INFTCollection } from "../../src/interfaces/INFTCollection.sol";

/// @notice Test double for the NFT: set ownership + rarity directly (no mint/drand needed).
/// @dev    ownerOf DELIBERATELY returns address(0) for an id that was never set, instead of reverting. The
///         real ERC721 reverts, but the holder draw must survive BOTH shapes, and a mock with
///         totalMinted set above the ids actually populated is the only cheap way to reach the
///         zero-owner branch. Do not "fix" this into a revert.
contract MockNFT is INFTCollection {
    mapping(uint256 => address) internal _owner;
    mapping(address => uint256) internal _bal;
    mapping(uint256 => uint8) internal _rarity;
    bool public launched = true; // default true so pool-init tests pass; set false to exercise the mint-closed gate

    /// @notice High water mark of the ids ever passed to `set`, mirroring the real collection's sequential
    ///         ids, where the minted set is exactly 1..totalMinted. Overridable via setTotalMinted so a test
    ///         can open a gap and exercise the zero-owner rejection.
    uint256 public totalMinted;
    /// @notice Unix time the pass last changed hands, as the real collection stamps it. Stamped once on the
    ///         first `set` of an id; move it explicitly with setOwnerSince to place a pass on either side of
    ///         a draw week's freeze instant.
    mapping(uint256 => uint64) public ownerSince;
    /// @notice Mirrors NFTCollection.MIN_HOLD (the holder-draw threshold). The engine cross-checks this.
    uint256 public constant MIN_HOLD = 4;
    /// @notice Mirrors NFTCollection.qualifiedSince: stamped when a wallet's balance crosses up to MIN_HOLD,
    ///         cleared when it drops below. Auto-maintained by set()/setBalance() via _restamp, exactly like the
    ///         real _update, so a test that gives a wallet >= MIN_HOLD before a freeze auto-qualifies it; move it
    ///         explicitly with setQualifiedSince to place a wallet on either side of the freeze.
    mapping(address => uint64) public qualifiedSince;

    function setLaunched(bool v) external {
        launched = v;
    }

    function setOwnerSince(uint256 id, uint64 t) external {
        ownerSince[id] = t;
    }

    function setQualifiedSince(address a, uint64 t) external {
        qualifiedSince[a] = t;
    }

    /// @dev Mirror the real NFT's up/down-crossing stamp so the frozen holder-count gate behaves in tests.
    function _restamp(address a) internal {
        if (a == address(0)) return;
        if (qualifiedSince[a] == 0 && _bal[a] >= MIN_HOLD) qualifiedSince[a] = uint64(block.timestamp);
        else if (qualifiedSince[a] != 0 && _bal[a] < MIN_HOLD) qualifiedSince[a] = 0;
    }

    function setTotalMinted(uint256 n) external {
        totalMinted = n;
    }

    /// @notice Force a wallet's pass balance, independent of set(). Lets a draw test put an owner above or
    ///         below HolderDrawEngine.MIN_HOLD without minting that many ids to it.
    function setBalance(address a, uint256 n) external {
        _bal[a] = n;
        _restamp(a);
    }

    function set(uint256 id, address owner_, uint8 rarity_) external {
        address prev = _owner[id];
        if (prev != address(0)) {
            _bal[prev] -= 1;
            _restamp(prev);
        } else {
            // First time this id is populated: treat it as the mint.
            if (id > totalMinted) totalMinted = id;
            if (ownerSince[id] == 0) ownerSince[id] = uint64(block.timestamp);
        }
        _owner[id] = owner_;
        _bal[owner_] += 1;
        _restamp(owner_);
        _rarity[id] = rarity_;
    }

    /// @notice A REAL transfer, mirroring NFTCollection._update: it re-stamps `ownerSince`, which `set()`
    ///         deliberately does not.
    /// @dev    Harness prerequisite. `set()` stamps ownerSince only on an id's FIRST population, so
    ///         re-calling it (which much of the suite uses as a stand-in for a transfer) moves the owner while
    ///         leaving ownerSince frozen at the original stamp. Any test that tries to prove a post-freeze
    ///         transfer changes eligibility would therefore pass VACUOUSLY, against fixed and unfixed code
    ///         alike. Use this for anything that must behave like a real transfer.
    ///         The `from == to` early return is load-bearing and mirrors the real collection: a self-transfer
    ///         must NOT re-stamp, or every marketplace approval a holder has granted becomes a kill switch on
    ///         their own free entries and holder-draw qualification.
    ///         set() is left exactly as it was, so the pinned pledge-flood measurements keep their current
    ///         pledgerOf-only invalidation semantics.
    function transferTo(uint256 id, address to) external {
        address from = _owner[id];
        if (from == to) return; // self-transfer: no re-stamp, exactly like NFTCollection._update
        if (from != address(0)) {
            _bal[from] -= 1;
            _restamp(from);
        }
        _owner[id] = to;
        if (to != address(0)) {
            _bal[to] += 1;
            _restamp(to);
        }
        ownerSince[id] = uint64(block.timestamp);
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function balanceOf(address o) external view returns (uint256) {
        return _bal[o];
    }

    function rarityOf(uint256 id) external view returns (uint8) {
        return _rarity[id];
    }
}
