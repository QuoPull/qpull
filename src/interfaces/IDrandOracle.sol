// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IDrandOracle
/// @notice The randomness source for every game: pack tiers, the daily raffle, the weekly holder draw, and
///         the Art Pass rarity reveal.
/// @dev    The only production implementation is BlsDrandOracle (EIP-2537 is live on RH). Tests
///         and the testnet run a settable mock behind the same interface; nothing downstream of randomness
///         cares which one is wired.
interface IDrandOracle {
    /// @return true once a verified beacon for `round` is stored.
    function isAvailable(uint64 round) external view returns (bool);

    /// @notice The verified 32-byte randomness for `round`.
    /// @dev    MUST revert if `round` is not yet available, callers rely on this to
    ///         enforce sealed-then-revealed: a future round has no answer.
    function randomness(uint64 round) external view returns (bytes32);

    /// @notice The highest round number for which a verified beacon has ever been stored (0 if none).
    /// @dev    The POSITIVE evidence that the drand chain is alive past a given round.
    ///         `isAvailable(r) == false` cannot tell "drand never produced r" apart from "nobody has paid
    ///         gas to relay r yet", and submitBeacon is permissionless, so the second case is the common
    ///         one. `highestRound() > r` says someone has relayed a LATER round, so the chain did not halt
    ///         at r. Escape hatches that discard a round require this before acting; a plain unavailability
    ///         check is not sufficient evidence to throw an outcome away. Monotonic: it only ever rises.
    function highestRound() external view returns (uint64);

    /// @notice The drand round whose scheduled publish time is the first at/after `timestamp`.
    /// @dev    Pure function of drand's genesis + period; binds a pack to a FUTURE round.
    function roundAt(uint256 timestamp) external view returns (uint64);
}
