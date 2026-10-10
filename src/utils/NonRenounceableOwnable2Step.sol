// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title  NonRenounceableOwnable2Step
/// @notice Ownable2Step whose ownership can NEVER be renounced.
/// @dev    OZ's `Ownable` ships a single-step `renounceOwnership()` that sets the owner to address(0).
///         Some contracts need a permanently-live owner: the three engines (setPotCap / setMinPot /
///         setWinnersPerDay / setCapBps / setExcluded), PackRegistry (setTicketPrice re-peg), Treasury
///         (setKeeper rotation) and NFTCollection (mint start, pause and pre-expiry finalize). Others have
///         write-once wiring that must land before the owner is vestigial: BaseVault (setController),
///         ClaimManager (setEngine / lockEngines), LeaderboardRegistry (setRecorder / setXpRecorder) and both
///         swap adapters (setTreasury, and QpullWethAdapter.setPoolKey). All of them use this base, so those
///         owner functions always stay callable. Two-step transfer of ownership to the launch owner is
///         preserved; only the renounce path is closed. The one contract that deliberately does NOT use this
///         base is PassArtRenderer (plain Ownable): DeployNFT refuses an unlocked renderer, so a renounce
///         before lock() cannot reach the NFT.
abstract contract NonRenounceableOwnable2Step is Ownable2Step {
    error OwnershipCannotBeRenounced();

    /// @dev Overrides OZ `Ownable.renounceOwnership` to revert unconditionally.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }
}
