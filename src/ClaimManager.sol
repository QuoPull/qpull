// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";

/// @notice The one getter lockEngines cross-checks: every launch engine holds its vault as a public
///         immutable, so this is its generated getter, not a new obligation on the engines.
interface IEngineVaultView {
    function vault() external view returns (address);
}

/// @title  ClaimManager
/// @notice Pull-payment claims for all three games. An authorized engine registers a
///         prize, which reserves it against the vault's free balance, and the winner claims within
///         the 30-day window. An unclaimed prize is swept back to the vault and rolls into future pots.
/// @dev    This contract is the sole authorized controller on the vaults. It never holds funds.
///         Non-renounceable: setEngine / lockEngines must stay callable until the engines are bound and locked.
contract ClaimManager is IClaimManager, NonRenounceableOwnable2Step, ReentrancyGuard {
    struct Claim {
        address vault;
        address recipient;
        uint256 amount;
        uint64 deadline;
        bool settled;
    }

    mapping(uint256 => Claim) public claims;
    uint256 public nextClaimId;
    // Each engine is bound to the ONE vault it may touch (0 = unauthorized), so an engine can only reserve and
    // pay against its own game's vault.
    mapping(address => address) public engineVault;

    // The engine bindings stay mutable during launch wiring (including de-authorizing to zero) until the owner
    // calls lockEngines() ONCE, after which the engine<->vault map is frozen forever: the same "immutable after
    // launch" posture as the system's other write-once authority bindings (BaseVault.controller, the
    // registries' recorder, PackRegistry.engine/nft, the adapters' treasury and QpullWethAdapter's poolKey).
    // Deploy arms this at the end of wiring.
    bool public enginesLocked;
    // How many engines currently hold a non-zero binding. Maintained by setEngine (0 -> bound increments,
    // bound -> 0 decrements, a rebind is neutral) so lockEngines can require the supplied list to be EXACTLY
    // the bound set.
    uint256 public engineCount;

    event EngineSet(address indexed engine, address indexed vault);
    event EnginesLocked();
    event ClaimRegistered(
        uint256 indexed id, address vault, address recipient, uint256 amount, uint64 deadline
    );
    event Claimed(uint256 indexed id, address indexed recipient, uint256 amount);
    event Swept(uint256 indexed id, uint256 amount);

    error NotEngine();
    error WrongVault();
    error NotRecipient();
    error AlreadySettled();
    error Expired();
    error NotExpired();
    error ZeroRecipient();
    error BadDeadline();
    error NotRegistered();
    error EnginesAlreadyLocked(); // lockEngines() has run; the bindings are final
    error OnlySelf(); // settleSelf is an internal self-call only
    error IncompleteBindings(); // lockEngines refuses an incomplete engine map
    error ZeroEngine(); // address(0) is not an engine; binding it would pad engineCount
    /// @notice The engine says it pays from `declared`, but the lock was handed `given`.
    error BindingMismatch(address engine, address declared, address given);

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Authorize `e` to register claims AGAINST `vault` only. Pass `vault = address(0)`
    ///         to de-authorize. An engine may be bound to exactly one vault; re-binding overwrites.
    /// @dev    Reverts once lockEngines() has been called: the bindings are then final.
    function setEngine(address e, address vault) external onlyOwner {
        if (enginesLocked) revert EnginesAlreadyLocked();
        // address(0) can never call registerClaim, yet binding it would count toward engineCount and
        // let a lockEngines list carry a phantom (0, vault) pair in place of a real engine. Refuse the key.
        if (e == address(0)) revert ZeroEngine();
        address prev = engineVault[e];
        if (prev == address(0) && vault != address(0)) {
            ++engineCount; // fresh bind
        } else if (prev != address(0) && vault == address(0)) {
            --engineCount; // de-authorize (a bound -> bound rebind leaves the count untouched)
        }
        engineVault[e] = vault;
        emit EngineSet(e, vault);
    }

    /// @notice One-way, irreversible: freeze the engine<->vault bindings forever. Called once by the owner
    ///         after all engines are wired and verified at launch. After this, no engine can be rebound: the
    ///         same immutability BaseVault.controller has, extended to ClaimManager's delegated map.
    /// @dev    The caller passes the EXACT expected (engine, vault) pairs and each is verified live before the
    ///         freeze, so a lock issued before wiring is complete reverts.
    ///         The list must also be the WHOLE bound set: its length equals engineCount and no engine repeats
    ///         (a duplicate could pad the length while a real engine is missing). Together with the live
    ///         per-pair check this proves list == bound set. The list is the operator's expected set, so it
    ///         must include every game engine.
    function lockEngines(address[] calldata engines, address[] calldata vaults) external onlyOwner {
        uint256 n = engines.length;
        if (n == 0 || n != vaults.length || n != engineCount) revert IncompleteBindings();
        for (uint256 i; i < n; ++i) {
            if (vaults[i] == address(0) || engineVault[engines[i]] != vaults[i]) revert IncompleteBindings();
            // The checks above compare the declaration against THIS contract's own mapping. Also ask the
            // ENGINE what vault it holds and require the two to agree, which catches a transposed wiring
            // (engine A bound here to engine B's vault). All three launch engines expose `vault` as a public
            // immutable; an address that does not answer (an EOA, or an engine without the getter) is left
            // to the checks above rather than made un-lockable.
            // A RAW staticcall, not try/catch: Solidity inserts an extcodesize check before a typed external
            // call, and that check reverts the CALLER outright, try/catch cannot catch it, so a plain
            // address in this list would make the whole map un-lockable. The raw form returns
            // (true, empty) for an address with no code and (false, ...) for a contract without the getter,
            // and both simply skip. Same shape as Erc404Mirror.mirrorOf and Treasury's balance reads.
            (bool ok, bytes memory out) = engines[i].staticcall(abi.encodeCall(IEngineVaultView.vault, ()));
            if (ok && out.length == 32) {
                address declared = abi.decode(out, (address));
                if (declared != vaults[i]) revert BindingMismatch(engines[i], declared, vaults[i]);
            }
            for (uint256 j; j < i; ++j) {
                if (engines[j] == engines[i]) revert IncompleteBindings(); // duplicate would mask an omission
            }
        }
        enginesLocked = true;
        emit EnginesLocked();
    }

    /// @inheritdoc IClaimManager
    function registerClaim(address vault, address recipient, uint256 amount, uint64 deadline)
        external
        override
        nonReentrant // defense-in-depth on the reserve path
        returns (uint256 id)
    {
        address bound = engineVault[msg.sender];
        if (bound == address(0)) revert NotEngine();
        if (vault != bound) revert WrongVault(); // an engine can only touch its own vault
        if (recipient == address(0)) revert ZeroRecipient(); // a claim must name a recipient
        if (deadline <= block.timestamp) revert BadDeadline(); // the claim window must end in the future
        IVault(vault).reserve(amount); // reserves against free balance, reverts if insufficient
        id = ++nextClaimId;
        claims[id] = Claim(vault, recipient, amount, deadline, false);
        emit ClaimRegistered(id, vault, recipient, amount, deadline);
    }

    function claim(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.settled) revert AlreadySettled();
        if (msg.sender != c.recipient) revert NotRecipient();
        if (block.timestamp > c.deadline) revert Expired();
        _settle(id, c); // single claim: a failed payout reverts (the caller wants to know)
    }

    /// @notice Claim MANY prizes in one transaction (the "claim all" path). An id that is not the caller's,
    ///         already settled, or past its 30-day window is SKIPPED, never reverted, so a single stale id
    ///         does not fail the whole batch. A claim whose PAYOUT reverts (its vault paused/blacklisted by
    ///         QUOTRON) is also skipped: the failed settleSelf() self-call reverts atomically, rolling back its
    ///         `settled`/`release`, so that claim stays unsettled + reserved (retryable via single claim()),
    ///         while the caller's OTHER healthy claims still pay. Only the caller's own claims are ever paid.
    ///         Returns how many were actually paid.
    function claimBatch(uint256[] calldata ids) external nonReentrant returns (uint256 claimed) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            Claim storage c = claims[id];
            if (c.settled || msg.sender != c.recipient || block.timestamp > c.deadline) continue;
            try this.settleSelf(id) {
                unchecked {
                    ++claimed;
                }
            } catch {
                // payout reverted (e.g. a QUOTRON-blacklisted vault): leave the claim unsettled+reserved, skip
            }
        }
    }

    /// @dev External self-only wrapper so claimBatch can `try/catch` a reverting payout. MUST NOT be
    ///      nonReentrant: the parent (claim/claimBatch) is already ENTERED, so a nonReentrant modifier here
    ///      would make every self-call revert. Reentrancy is still fully covered, the external entrypoints
    ///      carry the guard and this does not reset it, so an ERC-404 receiver-hook re-entry still reverts.
    function settleSelf(uint256 id) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _settle(id, claims[id]);
    }

    /// @dev Effects-before-interactions: mark settled, release the reserve, then pay out.
    function _settle(uint256 id, Claim storage c) private {
        c.settled = true;
        IVault(c.vault).release(c.amount);
        IVault(c.vault).payOut(c.recipient, c.amount);
        emit Claimed(id, c.recipient, c.amount);
    }

    /// @notice After the window closes, return an unclaimed prize to the vault (rolls into future pots).
    function sweepExpired(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.vault == address(0)) revert NotRegistered(); // explicit guard, not an incidental revert
        if (c.settled) revert AlreadySettled();
        if (block.timestamp <= c.deadline) revert NotExpired();
        c.settled = true;
        IVault(c.vault).release(c.amount);
        emit Swept(id, c.amount);
    }
}
