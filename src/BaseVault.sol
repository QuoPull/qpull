// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Erc404Mirror } from "./utils/Erc404Mirror.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IVault } from "./interfaces/IVault.sol";

/// @title  BaseVault
/// @notice Holds QUOTRON as pure prize inventory and pays it out fractionally ONLY on
///         the instruction of an authorized controller (an engine or the claim manager).
///         Tracks `unclaimedReserve` so `freeBalance` never counts prizes already owed:
///         the invariant that makes a pot structurally impossible to over-state.
/// @dev    payOut reverts if it would dip into `unclaimedReserve`. `release` takes a bare amount, so the
///         controller must pair each release with its payOut; ClaimManager does this one-for-one per claim.
///         The sole controller (ClaimManager) is bound ONCE and is then immutable: the owner can neither
///         revoke it nor add a second controller.
contract BaseVault is IVault, IERC721Receiver, NonRenounceableOwnable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable quotron;
    /// @notice QUOTRON's paired ERC-721 mirror, read once at construction, or address(0) if it has none.
    /// @dev    The only address besides the token itself whose ERC-721 receipt callback is
    ///         expected. Read via a raw staticcall (Erc404Mirror) so a token without the getter deploys fine.
    address public immutable quotronMirror;
    // The SINGLE controller (ClaimManager). Set ONCE, then immutable: never replaced, never revoked.
    address public controller;
    uint256 public override unclaimedReserve;

    event ControllerSet(address indexed controller);
    event PaidOut(address indexed to, uint256 amount);
    event Reserved(uint256 amount, uint256 totalReserve);
    event Released(uint256 amount, uint256 totalReserve);

    error NotController();
    error UnexpectedNft(); // only QUOTRON's own ERC-404 auto-mint may push a 721 here
    error ControllerAlreadySet();
    error ReserveUnderflow();
    error InsufficientFree();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(address quotron_, address initialOwner) Ownable(initialOwner) {
        quotron = IERC20(quotron_);
        quotronMirror = Erc404Mirror.mirrorOf(address(quotron)); // address(0) if QUOTRON has no mirror
    }

    /// @notice Bind the single controller (ClaimManager) ONCE: it can never be changed or revoked after.
    ///         Set at launch (Deploy.s.sol binds the ClaimManager).
    function setController(address c) external onlyOwner {
        if (controller != address(0)) revert ControllerAlreadySet();
        if (c == address(0)) revert NotController();
        controller = c;
        emit ControllerSet(c);
    }

    /// @inheritdoc IVault
    function freeBalance() public view override returns (uint256) {
        uint256 bal = quotron.balanceOf(address(this));
        return bal > unclaimedReserve ? bal - unclaimedReserve : 0;
    }

    /// @inheritdoc IVault
    function payOut(address to, uint256 amount) external override onlyController {
        // Never move reserved balance. On the claim path release() runs first (lowering
        // unclaimedReserve), so the payOut of a just-released claim passes; any payOut is limited to the
        // free balance and can NEVER touch funds already owed to winners.
        if (amount + unclaimedReserve > quotron.balanceOf(address(this))) revert InsufficientFree();
        quotron.safeTransfer(to, amount);
        emit PaidOut(to, amount);
    }

    /// @inheritdoc IVault
    /// @dev Reserves against a written prize claim. Can only reserve genuinely free balance,
    ///      so total reservations can never exceed the held balance.
    function reserve(uint256 amount) external override onlyController {
        if (amount > freeBalance()) revert InsufficientFree();
        unclaimedReserve += amount;
        emit Reserved(amount, unclaimedReserve);
    }

    /// @inheritdoc IVault
    /// @dev Releases a reservation on claim (paired with payOut) or on claim-window expiry rollover.
    function release(uint256 amount) external override onlyController {
        if (amount > unclaimedReserve) revert ReserveUnderflow();
        unclaimedReserve -= amount;
        emit Released(amount, unclaimedReserve);
    }

    /// @notice Accept ERC-721 terminal mints: QUOTRON is a custom ERC-404 whose auto-mint may
    ///         call this on a whole-unit crossing, so accepting one must never revert.
    /// @dev    Only the token and its ERC-721 mirror are accepted (an ERC-404 callback comes from one of
    ///         them). Any other sender reverts, as ERC-721's `_checkOnERC721Received` would for a
    ///         non-receiver: this vault has no ERC-721 egress (its only outbound call is
    ///         `quotron.safeTransfer`, with no `transferFrom`, no rescue, and nothing `virtual` for a
    ///         subclass to add one), so any other NFT sent here could never leave.
    ///         Real QUOTRON does NOT fire a receiver callback on a plain contract, so this hook is defense
    ///         in depth, not a correctness requirement.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        // QUOTRON's ERC-721 side is a SEPARATE mirror contract, so a real ERC-404 callback arrives from
        // `quotronMirror`, never from the token. The gate admits both and refuses every other sender: a
        // misdirected safeTransferFrom from anywhere else reverts for its sender instead of stranding their
        // NFT here (no ERC-721 egress).
        if (msg.sender != address(quotron) && msg.sender != quotronMirror) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }
}
