// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Erc404Mirror } from "./utils/Erc404Mirror.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ISwapAdapter } from "./interfaces/ISwapAdapter.sol";

/// @title  Treasury
/// @notice Receives the trade tax from QpullTaxHook, always in WETH on every swap kind, and, on a batched
///         `convert()`, turns it into prize inventory: any QPULL sent here by other means → WETH (via
///         adapter), team takes 20% of all WETH, the remaining 80% → QUOTRON and is split to the three
///         prize vaults. Batching keeps Quotron's 3% hook fee off every trade: it is paid once per
///         conversion.
///
/// @dev    Split, in bps of total tax: raffle 6125 / holder 625 / leaderboard 1250 / team 2000.
///         Swaps route through ISwapAdapter with slippage bounds, keeper-gated (see convert()).
///         The QpullWethAdapter is fee-exempt on the hook (exemptSender), so the protocol-side
///         QPULL→WETH conversion swap is itself untaxed.
contract Treasury is NonRenounceableOwnable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    IERC20 public immutable qpull;
    IERC20 public immutable weth;
    IERC20 public immutable quotron;
    /// @notice QUOTRON's paired ERC-721 mirror, read once at construction, or address(0) if it has none.
    /// @dev    The only address besides the token itself whose ERC-721 receipt callback is expected. Read
    ///         via a raw staticcall (Erc404Mirror) so a token without the getter deploys fine.
    address public immutable quotronMirror;

    uint256 internal constant BPS = 10_000;
    uint256 public constant TEAM_BPS = 2000; // 20% of tax
    uint256 public constant RAFFLE_BPS = 6125; // 61.25% (daily raffle)
    uint256 public constant HOLDER_BPS = 625; // 6.25% (weekly holder draw)
    uint256 public constant LEADERBOARD_BPS = 1250; // 12.5% (weekly leaderboard)
    uint256 internal constant PRIZE_BPS = RAFFLE_BPS + HOLDER_BPS + LEADERBOARD_BPS; // 8000

    ISwapAdapter public qpullWeth; // QPULL -> WETH
    ISwapAdapter public wethQuotron; // WETH -> QUOTRON
    address public prizeVault;
    address public holderVault;
    address public leaderboardVault;
    address public team;

    uint256 public convertThreshold; // min QPULL balance for convert()'s QPULL leg (a WETH-only sweep ignores it)
    // Max QPULL swapped per convert() call. The owner sets a pool-sized ceiling at go-live; a larger balance
    // is converted over several pool-sized slices, and the excess stays as QPULL balance meanwhile.
    // Defaults to 0 = "not configured": convert() reverts NotConfigured until BOTH caps are set. The setter
    // rejects 0, so 0 is an unambiguous "never set" sentinel.
    uint256 public maxConvertPerCall; // 0 = not configured (fail-closed); see convert()
    // Max WETH swapped per convert() call: the mirror of maxConvertPerCall for the WETH->QUOTRON leg. All
    // tax arrives here as WETH, so a WETH balance above the cap is likewise converted over several
    // pool-sized slices. Same fail-closed default as maxConvertPerCall: 0 until the owner sets a pool-sized
    // ceiling at go-live.
    uint256 public maxWethConvertPerCall; // 0 = not configured (fail-closed); see convert()

    // convert() rate limit. Both per-call caps are sized to pool depth, which bounds price impact only when
    // the calls are spaced out, so two limits apply:
    //   1. ONE convert() per block, unconditionally and with no configuration (the keeper ticks on a fixed
    //      interval, never per block).
    //   2. An optional `convertCooldown` in seconds on top, bounding the conversion rate ACROSS blocks.
    //      0 = block spacing only, which is the deploy default.
    // Adapter timelock. After lockRouting() the WETH->QUOTRON adapter can still be replaced, but only in
    // public and slowly: a replacement is PROPOSED on chain, waits out ADAPTER_TIMELOCK, and only then is
    // committed; the owner can cancel it in between. The purchase leg is the one external call in convert()
    // without fault isolation, so this keeps convert() recoverable if the third-party router it swaps
    // through stops working.
    //   SCOPE: the WETH->QUOTRON adapter ONLY. Routing DESTINATIONS stay frozen forever, and so does the
    //   QPULL->WETH adapter, because QpullTaxHook.exemptSender is IMMUTABLE and names that exact
    //   QpullWethAdapter (a replacement would pay the sell tax on every conversion). The QUOTRON adapter
    //   holds no funds: convert() approves it per call and forceApprove(..., 0)s immediately after, so a
    //   swap leaves nothing behind for the outgoing one.
    uint256 public constant ADAPTER_TIMELOCK = 7 days;
    address public pendingWethQuotron;
    uint64 public adapterProposedAt; // 0 = no live proposal

    uint256 public constant MAX_CONVERT_COOLDOWN = 1 hours; // a cooldown can delay convert(), never stop it
    uint256 public convertCooldown; // seconds between convert() calls; 0 = one-per-block only
    uint64 public lastConvertAt; // timestamp of the last convert() that got past the rate limit
    uint64 public lastConvertBlock; // and its block number (packed with lastConvertAt: one slot, one SSTORE)

    mapping(address => bool) public isKeeper; // only an authorized keeper may trigger convert()
    /// @notice How many addresses currently hold the keeper role. `isKeeper` is a bare mapping with no
    ///         enumeration, so this count is the way to ask "how many keepers exist?": `keeperCount == 1`
    ///         together with `isKeeper(wallet)` confirms exactly one keeper and no other.
    uint256 public keeperCount;
    mapping(address => uint256) public quotronOwed; // QUOTRON from a failed vault send, retried to THAT vault

    // setRouting sets convert()'s unconditional payout destinations (the three prize vaults + the 20% team
    // cut). They stay settable through staged launch wiring, then the owner calls lockRouting() ONCE to
    // freeze the destinations forever. The keeper role stays mutable on purpose: it is a rotatable hot key.
    bool public routingLocked;
    // The two per-call caps in force when lockRouting() ran. After the lock each cap may be lowered (a
    // thinner pool) and raised back, but never above these values. 0 until the lock.
    uint256 public lockedMaxConvertPerCall;
    uint256 public lockedMaxWethConvertPerCall;

    event AdaptersSet(address qpullWeth, address wethQuotron);
    event RoutingSet(address prizeVault, address holderVault, address leaderboardVault, address team);
    /// @dev carries what was frozen, so the one irreversible act in the protocol is observable in logs
    event RoutingLocked(
        address qpullWeth,
        address wethQuotron,
        address prizeVault,
        address holderVault,
        address leaderboardVault,
        address team
    );
    event ConvertThresholdSet(uint256 convertThreshold);
    event MaxConvertPerCallSet(uint256 maxConvertPerCall);
    event MaxWethConvertPerCallSet(uint256 maxWethConvertPerCall);
    event ConvertCooldownSet(uint256 convertCooldown);
    event AdapterSwapProposed(address wethQuotron, uint256 executableAt);
    event AdapterSwapCancelled(address wethQuotron);
    event AdapterSwapCommitted(address wethQuotron);
    event KeeperSet(address indexed keeper, bool authorized);
    event Converted(uint256 qpullIn, uint256 wethOut, uint256 quotronOut, uint256 teamWeth);

    error NotConfigured();
    error BelowThreshold();
    error NotKeeper();
    error SwapShortfall();
    error RoutingAlreadyLocked(); // lockRouting() has frozen the routing
    error VaultsNotDistinct(); // aliased vaults would double-count in owedTotal
    error OwedBeforeReroute(); // a reroute would orphan the outgoing vault's owed slice
    error CapTooLarge(); // type(uint256).max, or above the ceiling latched by lockRouting()
    error UnexpectedNft(); // only QUOTRON's own auto-mint (token or mirror) may push a 721 here
    /// @dev the caller asked to freeze destinations that are not the ones actually stored
    error RoutingMismatch(address prize, address holder, address leaderboard, address team);
    /// @dev the caller asked to freeze adapters that are not the ones actually bound
    error AdapterMismatch(address qpullWeth, address wethQuotron);
    error AdapterNotContract(); // a swap adapter must have code: convert() calls it
    error ZeroKeeper(); // a keyed-by-address role cannot be address(0)
    error NoAdapterProposal(); // commit/cancel with nothing proposed
    error TimelockNotElapsed(); // the proposal is still inside ADAPTER_TIMELOCK
    error ConvertRateLimited(); // same block as the last convert, or inside convertCooldown
    error CooldownTooLong(); // above MAX_CONVERT_COOLDOWN

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address qpull_, address weth_, address quotron_, address initialOwner) Ownable(initialOwner) {
        // These three bindings are immutable, so a zero address here would be permanent and convert() could
        // never run (balanceOf on a codeless address returns EMPTY returndata, which the decoder rejects).
        // Fail at construction rather than at the first convert().
        if (qpull_ == address(0) || weth_ == address(0) || quotron_ == address(0)) revert NotConfigured();
        qpull = IERC20(qpull_);
        weth = IERC20(weth_);
        quotron = IERC20(quotron_);
        quotronMirror = Erc404Mirror.mirrorOf(address(quotron)); // address(0) if QUOTRON exposes no mirror
    }

    /// @notice Authorize/deauthorize a keeper allowed to call convert(). convert() takes its slippage
    ///         floors from the caller, so only a trusted keeper that computes a tight off-chain minOut may
    ///         trigger it.
    /// @dev address(0) is refused in both directions: this role is keyed by raw address, and an unset or
    ///      truncated value would otherwise look configured while authorizing nothing. Redundant writes
    ///      return early rather than emitting, so `keeperCount` cannot drift and a KeeperSet event always
    ///      means the set actually changed. Revoking the LAST keeper is allowed on purpose, so a keeper key
    ///      can be revoked at once, before a replacement is ready. Zero keepers pauses `convert()`; it breaks
    ///      nothing permanently, and the owner can always grant a new one.
    function setKeeper(address k, bool v) external onlyOwner {
        if (k == address(0)) revert ZeroKeeper();
        if (isKeeper[k] == v) return; // no state change: no event, no count drift
        isKeeper[k] = v;
        unchecked {
            // cannot overflow (bounded by the number of distinct addresses ever granted) and cannot
            // underflow (only reached when isKeeper[k] was true, so the count is at least 1)
            keeperCount = v ? keeperCount + 1 : keeperCount - 1;
        }
        emit KeeperSet(k, v);
    }

    /// @dev The swap adapters custody QPULL/WETH mid-convert(), so lockRouting() freezes them together with
    ///      the payout destinations (the WETH->QUOTRON adapter stays replaceable only via the timelocked
    ///      proposeAdapterSwap / commitAdapterSwap path).
    function setAdapters(address qpullWeth_, address wethQuotron_) external onlyOwner {
        if (routingLocked) revert RoutingAlreadyLocked();
        if (qpullWeth_ == address(0) || wethQuotron_ == address(0)) revert NotConfigured(); // both required
        // Both are frozen by lockRouting and CALLED by convert(), so each must have code: a call to an
        // address with no code returns success with empty returndata, and convert() decodes a uint256 from
        // it, so a codeless adapter would make every conversion revert.
        if (qpullWeth_.code.length == 0 || wethQuotron_.code.length == 0) revert AdapterNotContract();
        qpullWeth = ISwapAdapter(qpullWeth_);
        wethQuotron = ISwapAdapter(wethQuotron_);
        emit AdaptersSet(qpullWeth_, wethQuotron_);
    }

    /// @notice Propose replacing the WETH->QUOTRON adapter. Takes effect only via `commitAdapterSwap()`, and
    ///         only after `ADAPTER_TIMELOCK` has passed. This path works both before and after `lockRouting()`.
    ///         The QPULL->WETH adapter has no timelocked path: only `setAdapters` sets it, and the lock freezes it.
    /// @dev    Same validation as `setAdapters`: non-zero, and code at the address. Proposing again replaces
    ///         any live proposal AND restarts its clock, so every target is public for the full
    ///         `ADAPTER_TIMELOCK` before it can be committed.
    function proposeAdapterSwap(address wethQuotron_) external onlyOwner {
        if (wethQuotron_ == address(0)) revert NotConfigured();
        if (wethQuotron_.code.length == 0) revert AdapterNotContract();
        pendingWethQuotron = wethQuotron_;
        adapterProposedAt = uint64(block.timestamp);
        emit AdapterSwapProposed(wethQuotron_, block.timestamp + ADAPTER_TIMELOCK);
    }

    /// @notice Withdraw a live adapter proposal before it is committed.
    function cancelAdapterSwap() external onlyOwner {
        if (adapterProposedAt == 0) revert NoAdapterProposal();
        emit AdapterSwapCancelled(pendingWethQuotron);
        delete pendingWethQuotron;
        delete adapterProposedAt;
    }

    /// @notice Apply a proposal once `ADAPTER_TIMELOCK` has elapsed.
    /// @dev    No allowance cleanup is needed: convert() approves the adapter for exactly the slice it is
    ///         about to swap and forceApprove(..., 0) immediately after, so an outgoing adapter never holds a
    ///         standing allowance.
    function commitAdapterSwap() external onlyOwner {
        uint64 proposedAt = adapterProposedAt;
        if (proposedAt == 0) revert NoAdapterProposal();
        if (block.timestamp < uint256(proposedAt) + ADAPTER_TIMELOCK) revert TimelockNotElapsed();
        address wq = pendingWethQuotron;
        wethQuotron = ISwapAdapter(wq);
        delete pendingWethQuotron;
        delete adapterProposedAt;
        emit AdapterSwapCommitted(wq);
        // indexers that already follow AdaptersSet see the change without needing to learn a new event
        emit AdaptersSet(address(qpullWeth), wq);
    }

    function setRouting(address prize_, address holder_, address leaderboard_, address team_)
        external
        onlyOwner
    {
        if (routingLocked) revert RoutingAlreadyLocked(); // destinations are final
        if (
            prize_ == address(0) || holder_ == address(0) || leaderboard_ == address(0)
                || team_ == address(0)
        ) {
            revert NotConfigured(); // no zero routing destinations
        }
        // convert() computes owedTotal by summing quotronOwed at the three CURRENT role addresses, so the
        // three vaults must be distinct or that sum double-counts. `team` is exempt: it takes WETH, never
        // QUOTRON, and is not part of owedTotal.
        if (prize_ == holder_ || holder_ == leaderboard_ || prize_ == leaderboard_) revert VaultsNotDistinct();
        // quotronOwed is keyed by raw address, so routing cannot change while any vault holds an owed slice:
        // that slice would drop out of owedTotal and be split to the current vaults instead of retried to
        // its own vault.
        if (
            quotronOwed[prizeVault] != 0 || quotronOwed[holderVault] != 0
                || quotronOwed[leaderboardVault] != 0
        ) revert OwedBeforeReroute();
        prizeVault = prize_;
        holderVault = holder_;
        leaderboardVault = leaderboard_;
        team = team_;
        emit RoutingSet(prize_, holder_, leaderboard_, team_);
    }

    /// @notice One-way, irreversible: freeze convert()'s payout destinations forever. The owner calls this
    ///         once at launch after setRouting is verified. After this, prize funding and the team cut cannot
    ///         be redirected. The keeper role is left rotatable by design (setKeeper). The lock also latches
    ///         both per-call caps as permanent ceilings, so each convert() call stays bounded by the go-live
    ///         caps.
    ///
    /// @param qpullWeth_ @param wethQuotron_ @param prize_ @param holder_ @param leaderboard_ @param team_
    ///        ALL SIX bindings this call freezes, as the caller believes them to be. Each must equal what is
    ///        actually stored, or this reverts.
    ///
    /// @dev THE CALLER MUST DECLARE WHAT IT IS FREEZING. All six bindings (the four payout destinations and
    ///      the two adapters, which `setAdapters` also latches here) are compared with what is stored, and a
    ///      mismatch reverts (RoutingMismatch / AdapterMismatch) instead of freezing a configuration the
    ///      caller did not verify. The declaration is meant to be derived independently from the deploy
    ///      output. The adapters are included because convert() approves QPULL and WETH to them and then
    ///      calls them, and the QPULL->WETH adapter cannot be replaced later because
    ///      QpullTaxHook.exemptSender is IMMUTABLE and names this exact QpullWethAdapter (a replacement would
    ///      pay the sell tax on every conversion). One binding is not absolute: the WETH->QUOTRON adapter can
    ///      be replaced after this lock, but ONLY through proposeAdapterSwap -> ADAPTER_TIMELOCK (7 days, in
    ///      public) -> commitAdapterSwap, so convert() stays recoverable if the third-party router it swaps
    ///      through stops working. The other five bindings remain frozen with no escape at all.
    function lockRouting(
        address qpullWeth_,
        address wethQuotron_,
        address prize_,
        address holder_,
        address leaderboard_,
        address team_
    ) external onlyOwner {
        // Refuse to freeze an INCOMPLETE config: require exactly what convert() demands (adapters + all four
        // destinations).
        if (
            address(qpullWeth) == address(0) || address(wethQuotron) == address(0) || prizeVault == address(0)
                || holderVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured();
        // convert() ALSO requires both caps (see its own NotConfigured check), so callers must set the caps
        // before the lock.
        if (maxConvertPerCall == 0 || maxWethConvertPerCall == 0) revert NotConfigured();
        // The freeze must be of the configuration the caller actually verified. Checked AFTER the non-zero
        // sweep above, so an entirely unconfigured Treasury (all four zero, caller passes four zeros, which
        // would "match") still fails on NotConfigured rather than latching an empty routing table forever.
        if (
            prize_ != prizeVault || holder_ != holderVault || leaderboard_ != leaderboardVault
                || team_ != team
        ) revert RoutingMismatch(prizeVault, holderVault, leaderboardVault, team);
        if (qpullWeth_ != address(qpullWeth) || wethQuotron_ != address(wethQuotron)) {
            revert AdapterMismatch(address(qpullWeth), address(wethQuotron));
        }
        // The current caps, sized against the live pool, become permanent ceilings.
        lockedMaxConvertPerCall = maxConvertPerCall;
        lockedMaxWethConvertPerCall = maxWethConvertPerCall;
        routingLocked = true;
        emit RoutingLocked(
            address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team
        );
    }

    function setConvertThreshold(uint256 t) external onlyOwner {
        // Intentionally NOT frozen by lockRouting: pool-sized conversion limits are tuned at go-live (after
        // the pool exists) and may need ongoing tuning.
        convertThreshold = t;
        emit ConvertThresholdSet(t);
    }

    /// @notice Ceiling on QPULL swapped per convert() call. A larger balance is converted in pool-sized
    ///         slices over several calls rather than in a single oversized swap.
    /// @dev    convert()'s minOut floors come from the keeper, which derives them from pool state it reads.
    ///         These two per-call caps are the on-chain bound on a single conversion: size each to a small
    ///         share of the live pool.
    function setMaxConvertPerCall(uint256 m) external onlyOwner {
        if (m == 0) revert BelowThreshold();
        if (m == type(uint256).max) revert CapTooLarge(); // see setMaxWethConvertPerCall
        if (routingLocked && m > lockedMaxConvertPerCall) revert CapTooLarge(); // at most the latched cap
        maxConvertPerCall = m;
        emit MaxConvertPerCallSet(m);
    }

    /// @notice Ceiling on WETH swapped per convert() call: the mirror of maxConvertPerCall for the
    ///         WETH→QUOTRON leg. A larger balance is converted in pool-sized slices over several calls.
    function setMaxWethConvertPerCall(uint256 m) external onlyOwner {
        // Each cap must be a real, pool-sized ceiling, so type(uint256).max is refused. After lockRouting()
        // both caps are bounded by the values the lock latched: they can be lowered for a thinner pool and
        // raised back, never above. A deeper pool needs no higher cap, only more convert() calls, each a
        // pool-sized slice.
        if (m == 0) revert BelowThreshold();
        if (m == type(uint256).max) revert CapTooLarge();
        if (routingLocked && m > lockedMaxWethConvertPerCall) revert CapTooLarge(); // at most the latched cap
        maxWethConvertPerCall = m;
        emit MaxWethConvertPerCallSet(m);
    }

    /// @notice Minimum seconds between convert() calls. 0 leaves only the one-per-block rule.
    /// @dev    Bounded by MAX_CONVERT_COOLDOWN, so a cooldown can delay the prize conversion by at most an
    ///         hour, never stop it. Deliberately NOT latched by lockRouting: a larger value here only slows
    ///         conversion, and leaving it mutable lets the owner tighten the conversion rate at any time
    ///         without touching the locked routing.
    function setConvertCooldown(uint256 s_) external onlyOwner {
        if (s_ > MAX_CONVERT_COOLDOWN) revert CooldownTooLong();
        convertCooldown = s_;
        emit ConvertCooldownSet(s_);
    }

    /// @dev Kept out of convert()'s own frame: that function already sits close to the via_ir stack limit.
    function _rateLimit() private {
        // Both fields are 0 until the FIRST convert, and 0 must mean "never", not "block 0 / timestamp 0".
        // The `!= 0` guards keep the very first convert from being compared against `0 + cd`, which would
        // block it on any chain whose clock starts below the cooldown itself.
        uint64 lastBlock = lastConvertBlock;
        if (lastBlock != 0 && uint64(block.number) == lastBlock) revert ConvertRateLimited();
        uint64 lastAt = lastConvertAt;
        uint256 cd = convertCooldown;
        if (lastAt != 0 && cd != 0 && block.timestamp < uint256(lastAt) + cd) revert ConvertRateLimited();
        lastConvertBlock = uint64(block.number);
        lastConvertAt = uint64(block.timestamp);
    }

    /// @notice Batch-convert accumulated WETH tax (plus any donated QPULL) into prize inventory + team WETH.
    ///         KEEPER-ONLY.
    /// @param  minWethOut     slippage floor for QPULL→WETH, computed OFF-CHAIN by the keeper
    /// @param  minQuotronOut  slippage floor for WETH→QUOTRON, computed OFF-CHAIN
    /// @dev    Keeper-gated (onlyKeeper): the off-chain slippage floors are only trustworthy from a keeper
    ///         that computes them tightly. The keeper account should be a bot key the team controls
    ///         (rotatable).
    function convert(uint256 minWethOut, uint256 minQuotronOut) external nonReentrant onlyKeeper {
        if (
            address(qpullWeth) == address(0) || address(wethQuotron) == address(0) || prizeVault == address(0)
                || holderVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured(); // holder/leaderboard vaults are unconditional transfer targets
        // Both per-call caps ship as 0 = "not configured", and convert() refuses to run until the owner
        // sets BOTH pool-sized ceilings (fail-closed). The setters reject 0, so a 0 here can only mean
        // "never set".
        if (maxConvertPerCall == 0 || maxWethConvertPerCall == 0) revert NotConfigured();
        _rateLimit(); // one slice per block, plus any cooldown the owner set

        // All hook tax arrives as WETH: QpullTaxHook take()s the WETH fee on every swap kind straight
        // to this Treasury, and never charges QPULL. The QPULL leg (leg 1) only handles QPULL sent to the
        // Treasury by other means (donations); WETH already held merges into the flow after it.
        uint256 qpullBal = qpull.balanceOf(address(this));
        uint256 wethHeld = weth.balanceOf(address(this));
        // Gate on the RAW balance, THEN cap the slice. convertThreshold is a MIN-BATCH gate ("enough QPULL
        // accumulated to amortize the swap"; that QPULL is only ever donated, never tax); maxConvertPerCall
        // is a MAX-SLICE safety ("don't swap more than pool depth per call"). They are independent: testing
        // the threshold against the already-capped slice would mean any config with maxConvertPerCall <
        // convertThreshold never runs the QPULL→WETH conversion, even with a large balance.
        // Also skip the QPULL leg when a full WETH slice is already backed up (wethHeld >=
        // maxWethConvertPerCall). The QPULL leg's WETH OUTPUT is bounded only by the deep QPULL/WETH pool,
        // not by maxWethConvertPerCall (which is sized for the shallower QUOTRON pool), so converting the
        // WETH backlog first keeps unprocessed WETH from growing call over call and the two legs from
        // diverging.
        bool qpullLeg = qpullBal > 0 && qpullBal >= convertThreshold && wethHeld < maxWethConvertPerCall;
        uint256 qpullIn = qpullBal > maxConvertPerCall ? maxConvertPerCall : qpullBal; // pool-sized slice
        // Sub-threshold QPULL waits; a WETH-only sweep is always allowed (threshold is an
        // anti-dust backstop for the QPULL swap leg, and convert() is keeper-gated anyway).
        if (!qpullLeg && wethHeld == 0) revert BelowThreshold();

        // 1. QPULL -> WETH. Trust the MEASURED balance delta, not the adapter's return value, so the floor
        //    check keys on what actually arrived.
        if (qpullLeg) {
            uint256 wethBefore = weth.balanceOf(address(this));
            qpull.forceApprove(address(qpullWeth), qpullIn);
            qpullWeth.swapExactIn(address(qpull), address(weth), qpullIn, minWethOut, address(this));
            qpull.forceApprove(address(qpullWeth), 0); // leave no standing allowance
            if (weth.balanceOf(address(this)) - wethBefore < minWethOut) revert SwapShortfall();
        } else {
            qpullIn = 0; // nothing swapped this call
        }

        // 2. team slice: 20% of the WETH processed THIS batch. wethOut is capped to a pool-sized slice; the
        //    remainder stays as WETH balance and is converted over subsequent convert() calls.
        uint256 wethOut = weth.balanceOf(address(this)); // swapped + hook-fee WETH; all of it is tax
        if (wethOut > maxWethConvertPerCall) wethOut = maxWethConvertPerCall;
        uint256 teamWeth = (wethOut * TEAM_BPS) / BPS;
        if (teamWeth > 0) weth.safeTransfer(team, teamWeth); // zero-guard like the QUOTRON legs
        uint256 prizeWeth = wethOut - teamWeth;

        // 3. prize WETH -> QUOTRON, measured delta again. The swap is skipped entirely on a zero slice,
        //    mirroring the zero-guards on the team leg (`teamWeth > 0` above) and the vault sends
        //    (_trySendQuotron), so the adapter is never called with amountIn == 0. The shortfall check stays
        //    OUTSIDE the guard so a keeper that asked for output it cannot get still reverts rather than
        //    silently succeeding.
        uint256 qOut;
        if (prizeWeth > 0) {
            uint256 qBefore = quotron.balanceOf(address(this));
            weth.forceApprove(address(wethQuotron), prizeWeth);
            wethQuotron.swapExactIn(address(weth), address(quotron), prizeWeth, minQuotronOut, address(this));
            weth.forceApprove(address(wethQuotron), 0); // leave no standing allowance
            qOut = quotron.balanceOf(address(this)) - qBefore; // THIS-swap delta: the floor check keys on it
        }
        if (qOut < minQuotronOut) revert SwapShortfall();

        // 4. Split the NEWLY-CONVERTED QUOTRON across the prize vaults (of the 8000 prize bps). The three
        //    sends are per-vault ISOLATED (best-effort), so a send that fails for ONE vault does not revert
        //    the whole convert() or hold up the other two vaults and the team/QPULL legs. A failed send is
        //    credited to quotronOwed[vault] and retried ONLY to that same vault on the next convert(), so a
        //    stuck slice is never redistributed to its sibling games. We therefore split only `splittable`
        //    (balance minus already-owed), and _trySendQuotron folds each vault's own owed back in.
        //    Zero-value legs are skipped: a thin batch floors the small legs to 0.
        uint256 qBal = quotron.balanceOf(address(this));
        uint256 owedTotal = quotronOwed[prizeVault] + quotronOwed[holderVault] + quotronOwed[leaderboardVault];
        uint256 splittable = qBal > owedTotal ? qBal - owedTotal : 0; // only the fresh conversion is split by ratio
        uint256 toHolder = (splittable * HOLDER_BPS) / PRIZE_BPS;
        uint256 toLeaderboard = (splittable * LEADERBOARD_BPS) / PRIZE_BPS;
        uint256 toRaffle = splittable - toHolder - toLeaderboard;
        _trySendQuotron(prizeVault, toRaffle);
        _trySendQuotron(holderVault, toHolder);
        _trySendQuotron(leaderboardVault, toLeaderboard);

        emit Converted(qpullIn, wethOut, qOut, teamWeth);
    }

    /// @dev Best-effort QUOTRON send that retries to the SAME vault. Sends `amount` PLUS any slice already
    ///      owed to `to` (from an earlier failed send); on failure the whole total is re-credited to
    ///      quotronOwed[to], so a stuck vault's funds always retry to IT, never to its siblings, and one
    ///      recipient that cannot receive neither reverts convert() nor misallocates its game's funding.
    ///      Reentrancy-safe: convert() is nonReentrant, these sends are its LAST step (nothing runs after
    ///      them), and real QUOTRON auto-exempts contract recipients from the ERC-404 callback.
    function _trySendQuotron(address to, uint256 amount) private {
        uint256 total = amount + quotronOwed[to];
        if (total == 0) return; // zero-value skip
        quotronOwed[to] = 0; // clear first; re-set below if the send still fails
        // Success is decided by the MEASURED balance this contract gave up, not by the call result or its
        // returndata: a token that returns false but moved the tokens is a success (they are gone, re-owing
        // them would double-count), and one that returns true without moving them, or a codeless `quotron`
        // (a bare call to it also reports success with empty returndata), is a failure that re-owes to THIS
        // vault. Measuring OUR OWN balance, never the recipient's, is deliberate: a blocked destination
        // leaves the tokens here, the delta is 0, and the slice is re-owed for a retry. Every external call
        // here is raw, so this helper never reverts and one bad destination never unwinds the batch.
        if (!_sendQuotronMeasured(to, total)) {
            quotronOwed[to] = total; // still blocked: owe the full slice to THIS vault, retry next convert
        }
    }

    /// @dev Transfer `total` QUOTRON to `to` and report whether this contract's balance actually fell by it.
    ///      Never reverts: every failure shape (codeless token, revert, false return, no movement, unreadable
    ///      balance) returns false so the caller can re-owe the slice.
    function _sendQuotronMeasured(address to, uint256 total) private returns (bool) {
        (bool okBefore, uint256 balBefore) = _quotronBalanceOfSelf();
        (bool sent,) = address(quotron).call(abi.encodeCall(IERC20.transfer, (to, total)));
        if (!sent || !okBefore || balBefore < total) return false;
        (bool okAfter, uint256 balAfter) = _quotronBalanceOfSelf();
        return okAfter && balAfter <= balBefore - total;
    }

    /// @dev balanceOf(this) via a raw staticcall: a codeless or misbehaving token reports `ok == false`
    ///      instead of reverting the batch. A reply shorter than one word is unreadable, so it is not a
    ///      balance (a buffer is never abi.decoded before its length is checked).
    function _quotronBalanceOfSelf() private view returns (bool ok, uint256 bal) {
        (bool s_, bytes memory out) =
            address(quotron).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (s_ && out.length >= 32) {
            bal = abi.decode(out, (uint256));
            ok = true;
        }
    }

    /// @notice ERC-404 terminal-mint safety, defense-in-depth. A convert() batch that buys ≥1 whole QUOTRON
    ///         unit crosses a whole-unit boundary on receipt. Real QUOTRON does NOT fire a receiver callback
    ///         on a plain contract (it appears to auto-exempt contracts from the NFT side), so convert() is
    ///         safe without this. It is implemented anyway: zero cost, uniform with the vaults, and a hedge
    ///         if that exemption ever changes.
    /// @dev Treasury has NO ERC-721 egress (no transferFrom, no rescue, no sweep), so this gates on
    ///      msg.sender: an ERC-404 callback always comes from the token or its mirror, and any other sender's
    ///      safeTransferFrom reverts, as ERC-721's _checkOnERC721Received would for a non-receiver, instead
    ///      of leaving the NFT stuck here.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        // QUOTRON's ERC-721 side is a SEPARATE mirror contract, so a real ERC-404 callback arrives from
        // `quotronMirror`, never from the token. The gate admits both and refuses every other sender: a
        // misdirected safeTransferFrom from anywhere else reverts for its sender instead of leaving their NFT
        // here (no ERC-721 egress).
        if (msg.sender != address(quotron) && msg.sender != quotronMirror) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }
}
