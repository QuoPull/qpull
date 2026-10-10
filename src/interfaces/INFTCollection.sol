// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title INFTCollection
/// @notice The launch NFT. Rarity (Common/Uncommon/Rare/Super Rare) is revealed via drand and
///         drives the holder's free daily raffle entries. Consumed by QpullTaxHook (the 1-hour
///         launch holder gate and the pool-creation gate on `launched`), PackRegistry (rarity-weighted free
///         entries) and HolderDrawEngine (ownerSince / qualifiedSince eligibility).
interface INFTCollection {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    /// @notice True once finalizeLaunch() has closed the mint (and sealed rarities). The tax hook gates
    ///         pool creation on this so the swap/pool cannot open until the mint is closed.
    function launched() external view returns (bool);
    /// @return tier 0=Common,1=Uncommon,2=Rare,3=Super Rare. Reverts until the token's round reveals.
    function rarityOf(uint256 tokenId) external view returns (uint8);
    /// @notice Unix time `tokenId` last changed hands; the mint itself counts as a change. 0 if never minted.
    ///         A self-transfer (from == to) is NOT a change of hands and does NOT move this.
    function ownerSince(uint256 tokenId) external view returns (uint64);
    /// @notice Unix time `owner`'s balance last CROSSED UP to `MIN_HOLD` and has stayed at or above it since;
    ///         0 while below MIN_HOLD. Lets the holder draw prove "held >= MIN_HOLD continuously since instant T"
    ///         in one SLOAD (`qualifiedSince(o) != 0 && qualifiedSince(o) <= T`), the frozen counterpart of a
    ///         live balanceOf gate, so eligibility cannot be topped up after the settling beacon is public.
    function qualifiedSince(address owner) external view returns (uint64);
    /// @notice The holder-draw threshold: the balance at or above which `qualifiedSince` runs. The
    ///         HolderDrawEngine cross-checks its own MIN_HOLD against this at construction.
    function MIN_HOLD() external view returns (uint256);
    /// @notice Passes minted so far. Ids are sequential, so the minted set is exactly 1..totalMinted.
    function totalMinted() external view returns (uint256);
}
