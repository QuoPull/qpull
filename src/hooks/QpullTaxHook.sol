// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    IPoolManager,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../interfaces/IPoolManager.sol";
import { IPackRegistry, ILeaderboardRegistry } from "../interfaces/IRegistries.sol";
import { INFTCollection } from "../interfaces/INFTCollection.sol";

/// @title  QpullTaxHook: the 4% trade tax as a Uniswap-V4 hook
/// @notice The trade tax is a swap fee, not a token transfer tax: a token that skims transfers is
///         incompatible with V4's flash accounting and breaks `settle()` (CurrencyNotSettled) for every
///         router that trades it. The canonical QPULL/WETH pool deploys WITH this hook, and the tax is
///         a swap fee taken inside the locked context:
///           - the tax is ALWAYS WETH: beforeSwap charges it on the specified WETH leg (exact-in buy,
///             exact-out sell), afterSwap on the unspecified WETH leg (exact-out buy, exact-in sell), and
///             afterSwap take()s it to the Treasury; credit = min(WETH paid, fee * BPS / TAX_BPS);
///           - the game registries are notified on buys: buy -> pack tickets + leaderboard points;
///             sells record nothing game-side;
///           - the 1-hour launch NFT-holder gate (GATE_DURATION()) is enforced on buys, together
///             with the same-window anti-sniper throttle (per-wallet buy cooldown, and a per-buy WETH size cap
///             that lasts for a per-wallet cumulative-spend budget) described under TRUST MODEL below.
///         QPULLToken itself is a plain, ownerless ERC-20: transfers are untaxed and V4 settlement paths
///         never break.
///
/// @dev    TRUST MODEL: this contract is fully immutable (no owner, no setters, constants for the
///         tax and the gate). A hook governs the protocol's only liquid pool, so it carries no admin
///         power of any kind. Design notes:
///           - the 4% applies to swaps on the canonical hooked pool, which holds ALL protocol-owned
///             liquidity (80% of NFT-mint ETH);
///           - trader identity is tx.origin (the transaction signer); hookData is IGNORED because it is
///             caller-supplied and unauthenticated. Rewards are credited to tx.origin, while the fee itself
///             is always paid by the actual swapper via the hook delta. During the 1-hour gate window the
///             gate reads balanceOf(tx.origin), so the pass must be held by the signing wallet to buy in
///             that window; after the gate expires, anyone can buy. The launch throttle (cooldown, spend
///             budget, size cap) is keyed on tx.origin too, so the gate and the throttle always agree
///             about who a buyer is, and buys that share a signer share one cooldown and one spend budget;
///           - the 1-hour gate window (GATE_DURATION()) is measured from POOL CREATION (afterInitialize), because that
///             is the only launch instant the hook can observe. Liquidity can only be added AFTER the
///             pool exists, and QpullLiquidityLock.seed creates the pool and adds the launch liquidity in the
///             same transaction, so the gate starts the instant liquidity exists;
///           - LAUNCH THROTTLE (anti-sniper), active ONLY inside that same gate window and on BUYS.
///             A holder who passes the gate must also satisfy two limits, each with its own error so an
///             integrator can tell them apart: at least BUY_COOLDOWN between two of their buys (BuyCooldown),
///             and, while the wallet's cumulative gated-window spend is below EARLY_BUY_COUNT * earlyBuyCapWei,
///             at most `earlyBuyCapWei` of WETH on any one buy (EarlyBuyTooLarge). There is
///             NO buy-count limit of any kind: once that budget is spent, further gated buys are uncapped.
///             Sells, and every buy after the window closes, are untouched: no throttle record is read or
///             written outside the window, so post-launch swaps carry none of this gas. All three are
///             immutable by construction: one constant (EARLY_BUY_COUNT), one virtual getter fixed per contract
///             (BUY_COOLDOWN(), 2 minutes here; only the never-mainnet testnet subclass returns a shorter value)
///             and one constructor immutable (earlyBuyCapWei). No owner, no setter. At the shipped values a wallet
///             can spend its whole capped budget inside the window: EARLY_BUY_COUNT at-cap buys need
///             (EARLY_BUY_COUNT - 1) * BUY_COOLDOWN() = 18 minutes of the 60-minute gate;
///           - THE SIZE CAP IS A FIXED AMOUNT OF ETH, NOT A DOLLAR FIGURE. `earlyBuyCapWei` is a wei
///             amount frozen at deploy. There is deliberately NO USD conversion: this chain has no price
///             feed the hook can rely on, the pool's own price can move within a single block, and a
///             QPULL-denominated cap is meaningless once the pool floats. The deployed value is picked
///             by hand from the ETH/USD price on deploy day (0.25 ether, set in script/Deploy.s.sol) and
///             does not track USD afterwards. The cap applies only during the gate window (1 hour) after
///             pool creation;
///           - the cap measures the WETH the buyer actually spends, computed exactly from this swap's own
///             delta plus the WETH fee, never estimated (see `wethPaid` in afterSwap);
///           - registry notification is try/catch: this hook is immutable, so a registry LOGIC fault
///             costs only that trade's rewards (RecordFailed event) and never blocks swaps. A registry
///             that runs OUT OF GAS reverts the buy with RecordOutOfGas instead, so a buyer never pays the
///             tax without receiving credit. Sells never call a registry.
///             The fee take() and the gate are NOT try/caught: fee delivery and the gate fail closed.
///           - afterSwap is `nonReentrant` (transient guard). Reentrancy is already prevented by the
///             PoolManager's unlock-lock, onlyPoolManager, and trusted storage-only registries, and the
///             only state a swap writes in this contract is the launch-throttle record (`earlyBuyer`), which is
///             checked and written in one uninterrupted internal call with no external call between them, so it
///             cannot be re-entered mid-update. The guard is defense in depth. It does NOT block multi-hop
///             routing (sequential afterSwap calls, not nested); it only bars a true nested re-entry.
///
///         V4 mechanics (verified against vendored v4-core v4.0.0):
///           - address flag bits: AFTER_INITIALIZE (1<<12) | BEFORE_ADD_LIQUIDITY (1<<11) |
///             BEFORE_REMOVE_LIQUIDITY (1<<9) | BEFORE_SWAP (1<<7) | AFTER_SWAP (1<<6) |
///             BEFORE_SWAP_RETURNS_DELTA (1<<3) | AFTER_SWAP_RETURNS_DELTA (1<<2) = 0x1ACC.
///             The deployer mines a CREATE2 salt so the hook address carries exactly these bits
///             (script/HookMiner.sol);
///           - beforeSwap returns (selector, BeforeSwapDelta, 0). Its SPECIFIED half is the WETH fee on the
///             two kinds whose WETH leg is the specified currency; v4 adds it to amountToSwap (Hooks.sol:274),
///             so an exact-in buy of G swaps G - fee and an exact-out sell of N swaps N + fee. Only a
///             beforeSwap delta can touch the specified currency. beforeSwap is `view` and moves nothing;
///           - afterSwap returns (selector, int128 hookDeltaUnspecified). POSITIVE means the swapper
///             pays the hook that amount of the unspecified currency (Hooks.sol: "the caller has to
///             pay for the hook's delta"; swapDelta -= hookDelta). The hook's credit (from either
///             callback) is settled by take()-ing the fee to the Treasury inside afterSwap, same unlock,
///             nets to zero;
///           - the unspecified currency is currency1 when (exactInput == zeroForOne), else currency0;
///             WETH is therefore the specified currency iff (exactInput == isBuy);
///           - PoolManager.initialize is PERMISSIONLESS, so afterInitialize restricts pool creation:
///             only `initializer` (QpullLiquidityLock, a contract, never a key) may create the canonical pool,
///             which stamps launchTime and opens the 1-hour gate window, and no other PoolKey may attach this
///             hook at all, so registry rewards come only from swaps on the canonical pool.
contract QpullTaxHook is ReentrancyGuardTransient {
    using BalanceDeltaLib for BalanceDelta;

    // ─── constants ───────────────────────────────────────────────────────────
    uint256 public constant TAX_BPS = 400; // 4%, immutable by construction, no owner can change it
    uint256 internal constant BPS = 10_000;
    // Launch anti-dump (SELL-ONLY): sells are taxed on a decaying schedule for the launch window, 20% for the
    // first step, dropping 4pp per step to the 4% floor (20/16/12/8 -> 4%). Buys are ALWAYS 4%. The elevated
    // tax routes to the same Treasury/prize vaults, so early sells seed a bigger opening pot. The time getters
    // are `virtual` so a TESTNET-ONLY subclass can COMPRESS them; mainnet keeps the real 48h/12h/1h schedule.
    // No owner can change any of these, a testnet subclass hardcodes short values, mainnet is fixed at 48h/etc.
    // The schedule SATURATES at TAX_BPS (_taxBps) and the constructor refuses a zero SELL_STEP(), so no
    // decay/step ratio a subclass picks can ever make a sell revert.
    uint256 public constant SELL_TAX_START_BPS = 2000; // 20% at launch
    uint256 public constant SELL_STEP_BPS = 400; // -4pp per step
    function SELL_STEP() public view virtual returns (uint256) { return 12 hours; } // step length
    function SELL_DECAY() public view virtual returns (uint256) { return 48 hours; } // window the elevated sell tax decays over
    // Launch holder gate + NFTCollection transfer-lock window: 1 hour on mainnet. Independent of the 48h
    // sell-tax decay, which is measured from launchTime on its own.
    function GATE_DURATION() public view virtual returns (uint256) { return 1 hours; }

    // Launch anti-sniper throttle. Applies ONLY to BUYS and ONLY while the holder gate above is open, on the
    // same tx.origin identity the gate uses. BUY_COOLDOWN is `virtual` (testnet compression). EARLY_BUY_COUNT
    // sizes a wallet's capped SPEND BUDGET, EARLY_BUY_COUNT * earlyBuyCapWei of cumulative gated-window WETH:
    // while that budget is unspent no single buy may exceed earlyBuyCapWei. Despite the name it counts no
    // buys and limits nothing once the budget is spent.
    function BUY_COOLDOWN() public view virtual returns (uint256) { return 2 minutes; } // min spacing between one wallet's gated buys
    uint256 public constant EARLY_BUY_COUNT = 10; // budget multiplier: cap binds until spentWei >= 10 * cap

    // Hook address flag bits this contract requires (v4-core Hooks.sol bit layout).
    // AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP
    //   | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    // The two liquidity bits make the PoolManager invoke this hook on every LP add AND remove: adds are
    // restricted to the protocol and removes always revert. BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA let the
    // hook charge the WETH fee on the SPECIFIED currency (exact-in buys, exact-out sells), which only a
    // beforeSwap delta can do; v4 requires bit 7 whenever bit 3 is set (Hooks.sol:110).
    uint160 public constant REQUIRED_FLAGS =
        (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint160 internal constant ALL_FLAG_MASK = (1 << 14) - 1;

    /// @dev Every swap amount the pool can realise fits int128 (Pool.sol:455/459 toInt128).
    uint256 internal constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    /// @dev EIP-150: a depth-d out-of-gas chain hands this frame back at most g*(1-(63/64)^d)
    ///      (11.8% at d=8). A logic revert returns its unused gas. Today's deepest registry path is
    ///      hook -> PackRegistry.recordBuy -> drand.roundAt (d=2, in PackRegistry._mintPacks). THE REGISTRY PATH MUST
    ///      STAY AT DEPTH <= 8, or an out-of-gas record can slip back into the soft-fail branch.
    uint256 internal constant RECORD_OOG_DIVISOR = 8;

    // ─── immutable wiring (no owner, no setters) ─────────────────────────────
    IPoolManager public immutable poolManager;
    address public immutable qpull;
    address public immutable weth;
    bool internal immutable qpullIs0; // address-sort order of the canonical pair
    uint24 public immutable canonicalFee;
    int24 public immutable canonicalTickSpacing;
    address public immutable treasury; // receives the tax, always in WETH
    IPackRegistry public immutable packRegistry;
    ILeaderboardRegistry public immutable leaderboardRegistry;
    INFTCollection public immutable nft; // launch-gate (1h) membership
    address public immutable exemptSender; // the Treasury's QpullWethAdapter: convert() sells untaxed
    /// @notice QpullLiquidityLock: the ONLY address allowed to create the canonical pool AND the only one
    ///         allowed to add liquidity to it. A CONTRACT, deliberately, not a key, see the LP gate below.
    address public immutable initializer;

    /// @notice Largest amount of WETH one wallet may spend on a single buy while the 1-hour launch gate is
    ///         open, until that wallet's cumulative gated-window spend reaches EARLY_BUY_COUNT * earlyBuyCapWei
    ///         (after which its gated buys are uncapped). A FIXED WEI AMOUNT, frozen at deploy, with NO USD
    ///         tracking of any kind: there is no price feed on this chain the hook could rely on, and the
    ///         pool's own price can move within a single block, so the cap is not priced in dollars
    ///         on-chain. The deploy value is chosen by hand from that day's ETH/USD price (0.25 ether, set
    ///         in script/Deploy.s.sol) and its dollar value moves with ETH from then on. Immutable: no owner
    ///         and no setter can change it, and it applies only for GATE_DURATION() (1 hour) after pool
    ///         creation.
    uint256 public immutable earlyBuyCapWei;

    uint256 public launchTime; // stamped by afterInitialize, opens the 1-hour gate window (GATE_DURATION())

    /// @notice Per-wallet gate-window buy record. One storage slot: written only inside the gate window,
    ///         never read or written by this hook after it closes.
    struct EarlyBuyer {
        uint64 lastBuyAt; // timestamp of this wallet's most recent gated buy (0 = none yet); drives BuyCooldown
        // Gated buys made so far. LOAD-BEARING, not observability: NFTCollection._enforceLaunchLock reverts
        // PassLockedDuringLaunch on any pass transfer out of a wallet with buys > 0 while the gate is open (the
        // flag-on-buy transfer-lock). The size cap is governed by spentWei, not by this count.
        uint32 buys;
        // Cumulative gated-window spend, in WETH wei. Fits the same slot (64 + 32 + 128 = 224 bits), so this
        // costs no extra storage.
        uint128 spentWei;
    }

    /// @notice Gated-window buy record per tx.origin. Public so a front end can show a buyer their cooldown and
    ///         remaining capped budget (EARLY_BUY_COUNT * earlyBuyCapWei - spentWei) instead of letting the
    ///         swap revert, and so NFTCollection can read `buys` for the launch transfer-lock.
    mapping(address => EarlyBuyer) public earlyBuyer;

    struct HookConfig {
        address poolManager;
        address qpull;
        address weth;
        uint24 fee;
        int24 tickSpacing;
        address treasury;
        address packRegistry;
        address leaderboardRegistry;
        address nft;
        address exemptSender;
        // QpullLiquidityLock: a CONTRACT whose CREATE address Deploy.s.sol predicts before the hook is mined. Never a
        // key: the pool-creation gate and the LP gate are plain `sender == initializer` checks.
        address initializer;
        // Gate-window (1h) per-buy WETH cap, in wei. Fixed at deploy from that day's ETH price (0.25 ether, set in
        // script/Deploy.s.sol; the USD worth is re-derived at deploy time, not recorded here). NOT a USD
        // figure and it never becomes one, see `earlyBuyCapWei`.
        uint256 earlyBuyCapWei;
    }

    event Launched(uint256 launchTime);
    event TaxTaken(address indexed trader, bool isBuy, uint256 grossQpull, address feeCurrency, uint256 fee); // feeCurrency is always weth
    event RecordFailed(bytes32 indexed which, address indexed trader, uint256 credit); // registry LOGIC fault only

    error ZeroAddress();
    error BadFee();
    error BadFlags();
    error NotPoolManager();
    error NotCanonicalPool();
    error NotInitializer();
    error Gated(); // gate-window (1h) buy by a wallet holding no pass
    error BadEarlyBuyCap(); // constructor: a zero cap would block every gated buy for the whole 1-hour gate window
    error BadTickSpacing(); // constructor: tickSpacing outside v4's [MIN_TICK_SPACING, MAX_TICK_SPACING] = [1, 32767]
    error BadSellSchedule(); // constructor: zero SELL_STEP() (divide by zero), or NOT TAX_BPS <= start < BPS
    error BuyCooldown(); // gated buy less than BUY_COOLDOWN after this wallet's previous one
    error EarlyBuyTooLarge(); // gated buy > earlyBuyCapWei while spentWei < EARLY_BUY_COUNT * earlyBuyCapWei
    error MintStillOpen(); // pool creation blocked until the NFT mint is closed (finalizeLaunch)
    error LiquidityRestricted(); // only the protocol may provide liquidity
    error LiquidityRemovalDisabled(); // removal does not exist on the canonical pool
    error PartialFill(); // a WETH-specified taxed swap (exact-in buy, exact-out sell) stopped at its price limit
    error SwapTooLarge(); // |amountSpecified|, or an exact-out sell's amt + fee, exceeds int128.max
    error RecordOutOfGas(bytes32 which); // a registry ran out of gas; caller gas shortfall, resend with more gas

    modifier onlyPoolManager() {
        // afterInitialize and afterSwap mutate protocol state (launchTime, registry records), so only the
        // PoolManager may call them. beforeSwap is view, but is gated too so its fee quote is only ever consumed
        // by the PoolManager.
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(HookConfig memory c) {
        if (
            c.poolManager == address(0) || c.qpull == address(0) || c.weth == address(0)
                || c.treasury == address(0) || c.packRegistry == address(0)
                || c.leaderboardRegistry == address(0) || c.nft == address(0) || c.exemptSender == address(0)
                || c.initializer == address(0)
        ) revert ZeroAddress();
        if (c.fee > 1_000_000) revert BadFee(); // static LP fee only, <= 100% (dynamic sentinel 0x800000 > 1M)
        // A zero cap would reject every buy for the whole 1-hour gate window (any buy spends more than 0), so it
        // is refused at deploy rather than discovered at launch. There is no upper bound to check: a cap
        // larger than the pool can absorb simply never binds.
        if (c.earlyBuyCapWei == 0) revert BadEarlyBuyCap();
        // v4 refuses to initialize a pool whose tickSpacing is outside
        // [TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING] = [1, type(int16).max]. This hook is immutable and
        // isCanonical() admits exactly one key, so an out-of-range value here would make the canonical pool
        // uncreatable. Refused at deploy.
        if (c.tickSpacing < 1 || c.tickSpacing > 32_767) revert BadTickSpacing();
        // Sell-schedule config invariant. The decaying sell tax divides by SELL_STEP()
        // and saturates at TAX_BPS. SELL_STEP()/SELL_DECAY() are virtual, and Solidity dispatches a virtual
        // call from a base constructor to the most-derived override, so this sees the subclass's values.
        // Refuse at deploy the two edits the saturating schedule cannot absorb: a zero step (division by zero
        // on every launch-window sell) and a start rate below the floor (the saturation bound
        // `SELL_TAX_START_BPS - TAX_BPS` would itself underflow). The decay/step RATIO is deliberately
        // unconstrained: the schedule floors at TAX_BPS for any ratio, so a longer decay can only mean more
        // time at the flat 4%.
        // `SELL_TAX_START_BPS < TAX_BPS` and `SELL_TAX_START_BPS >= BPS` compare
        // constants, so neither can fire in this bytecode (2000 vs 400 and 10_000) and no subclass can reach
        // them (constants are not overridable). They are edit-time tripwires, not runtime defences: the
        // compiler folds them away, and an edit that ever breaks TAX_BPS <= SELL_TAX_START_BPS < BPS (the
        // _taxBps saturation bound and the exact-out sell gross-up's BPS - bps divisor) then fails every
        // deploy instead of shipping an immutable hook whose launch-window sells revert. Only the SELL_STEP()
        // operand is a live, subclass-reachable check.
        if (SELL_STEP() == 0 || SELL_TAX_START_BPS < TAX_BPS) revert BadSellSchedule();
        if (SELL_TAX_START_BPS >= BPS) revert BadSellSchedule();
        // The deployer must have mined a salt giving this address EXACTLY the required flag bits:
        // extra bits would make the PoolManager invoke callbacks this contract does not implement.
        if (uint160(address(this)) & ALL_FLAG_MASK != REQUIRED_FLAGS) revert BadFlags();
        poolManager = IPoolManager(c.poolManager);
        qpull = c.qpull;
        weth = c.weth;
        qpullIs0 = c.qpull < c.weth;
        canonicalFee = c.fee;
        canonicalTickSpacing = c.tickSpacing;
        treasury = c.treasury;
        packRegistry = IPackRegistry(c.packRegistry);
        leaderboardRegistry = ILeaderboardRegistry(c.leaderboardRegistry);
        nft = INFTCollection(c.nft);
        exemptSender = c.exemptSender;
        initializer = c.initializer;
        earlyBuyCapWei = c.earlyBuyCapWei;
    }

    /// @notice True iff `key` is the one pool this hook serves: address-sorted QPULL/WETH at the
    ///         canonical fee/tickSpacing. (key.hooks == this always holds inside our callbacks:
    ///         the PoolManager dispatches to key.hooks.)
    function isCanonical(PoolKey calldata key) public view returns (bool) {
        (address lo, address hi) = qpullIs0 ? (qpull, weth) : (weth, qpull);
        return Currency.unwrap(key.currency0) == lo && Currency.unwrap(key.currency1) == hi
            && key.fee == canonicalFee && key.tickSpacing == canonicalTickSpacing;
    }

    // ─── V4 callbacks ────────────────────────────────────────────────────────

    /// @notice Pool creation control + launch stamp. initialize() is permissionless on the PoolManager,
    ///         so this is where the hook decides which pools may exist with it attached: exactly one,
    ///         the canonical pool, created by `initializer` (QpullLiquidityLock.seed, in the same transaction
    ///         as the liquidity add). Reverting here reverts initialize().
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!isCanonical(key)) revert NotCanonicalPool(); // only the canonical pool may attach this hook
        if (sender != initializer) revert NotInitializer(); // only the protocol may create the pool
        if (!nft.launched()) revert MintStillOpen(); // swap/pool cannot open until the mint is closed (finalizeLaunch)
        // initialize() can only succeed once per pool id, so launchTime is written exactly once.
        launchTime = block.timestamp;
        emit Launched(block.timestamp);
        return this.afterInitialize.selector;
    }

    /// @notice Liquidity provision is restricted to the protocol. The 4% tax fires on SWAPS
    ///         (beforeSwap/afterSwap); adding/removing liquidity is NOT a swap, so V4 charges no tax on it,
    ///         and restricting provision keeps all trading on the taxed swap path. `initializer` IS
    ///         QpullLiquidityLock: the lock creates the canonical pool and seeds it in one transaction, so the
    ///         only address that ever satisfies this gate is a contract that adds liquidity exactly once and
    ///         contains no code that could remove it. `initializer` is a contract address, not a key.
    ///
    ///         REMOVAL DOES NOT EXIST. `beforeRemoveLiquidity` reverts unconditionally, for every caller
    ///         including the lock, so the pool itself enforces that the launch liquidity stays in place. The
    ///         canonical pool's depth is fixed forever at whatever the launch seeds, and no liquidity can be
    ///         added or removed after that.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        _onlyProtocolLp(sender, key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice REMOVING LIQUIDITY FROM THE CANONICAL POOL IS IMPOSSIBLE. This reverts for every caller,
    ///         unconditionally, with no branch and no privileged exception.
    ///
    ///         v4 keys every position by `owner: msg.sender`, and the launch position is owned by
    ///         QpullLiquidityLock, which has no removal code. This function makes the pool enforce the same
    ///         property for every caller.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert LiquidityRemovalDisabled();
    }

    /// @dev The LP gate: canonical pool only, and the provider must be `initializer`, QpullLiquidityLock,
    ///      the contract that creates this pool and seeds it in the same transaction. `sender` is the address
    ///      v4 passes as the caller of `modifyLiquidity`, which for the lock is the lock itself. There is no
    ///      `tx.origin` branch: only the lock contract itself satisfies the check. Since `initialize` is gated
    ///      to the same address and can only succeed once, and the lock adds exactly once, this admits
    ///      precisely one add in the pool's lifetime.
    function _onlyProtocolLp(address sender, PoolKey calldata key) internal view {
        if (!isCanonical(key)) revert NotCanonicalPool(); // this hook serves exactly one pool
        if (sender != initializer) revert LiquidityRestricted();
    }

    /// @notice Declares the WETH fee on the two swap kinds whose WETH leg is the SPECIFIED currency
    ///         (exact-in buy, exact-out sell). Only a beforeSwap delta can touch the specified currency
    ///         (v4-core Hooks.sol:265-277). Moves nothing and writes nothing: every token movement and every
    ///         state write stays in afterSwap, which recomputes the same fee from the same `params`
    ///         (PoolManager passes one `params` to both callbacks) and fails closed on any drift (PartialFill).
    /// @param  sender The address that called PoolManager.swap (a router, NOT the human swapper).
    /// @return selector, the BeforeSwapDelta (upper 128 bits = specified fee, lower 128 = 0), and a zero LP fee
    ///         override (ignored on this static-fee pool, Hooks.sol:262).
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata // hookData: deliberately IGNORED
    ) external view onlyPoolManager returns (bytes4, int256, uint24) {
        if (!isCanonical(key)) revert NotCanonicalPool(); // unreachable (afterInitialize), defense-in-depth
        // Exempt first, exactly as in afterSwap: the adapter's convert() path (and its partial-fill refund in
        // QpullWethAdapter.unlockCallback) never sees a hook delta, so it can never reach PartialFill.
        if (sender == exemptSender || !_wethSpecified(params)) return (this.beforeSwap.selector, 0, 0);
        uint256 fee = _specifiedWethFee(params.amountSpecified);
        // BeforeSwapDelta = int256, upper 128 bits specified, lower 128 unspecified (types/BeforeSwapDelta.sol).
        // fee < 2^127 (MAX_AMOUNT bound), so this equals toBeforeSwapDelta(int128(fee), 0).
        return (this.beforeSwap.selector, int256(fee) << 128, 0);
    }

    /// @notice The tax. Takes the WETH fee for the Treasury on all four swap kinds, enforces the 1-hour launch
    ///         holder gate on buys, and credits the game registries from the WETH fee.
    /// @dev    CREDIT INVARIANT: every wei of game credit satisfies credit * TAX_BPS <= fee * BPS, where
    ///         `fee` is WETH this same call has just take()n to the Treasury, and credit <= the WETH the buyer
    ///         actually paid. The hook never returns a QPULL delta, so the QPULL price does not enter either
    ///         side of that inequality.
    /// @param  sender The address that called PoolManager.swap (a router, NOT the human swapper).
    /// @return selector + the hook's unspecified-currency delta: the WETH fee on exact-out buys and exact-in
    ///         sells, 0 when the fee rode beforeSwap's specified delta (the swapper pays either way).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata // hookData: deliberately IGNORED, caller-supplied, cannot be trusted for identity
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        if (!isCanonical(key)) revert NotCanonicalPool(); // unreachable (afterInitialize), defense-in-depth

        // The protocol's own conversion path (Treasury -> QpullWethAdapter -> this pool) is exempt:
        // taxing it would just loop Treasury money back to the Treasury minus slippage. `sender` is the
        // PoolManager's msg.sender, the adapter contract itself, so this cannot be impersonated.
        if (sender == exemptSender) return (this.afterSwap.selector, 0);

        // Trade facts, all derived from swap params + the pool's own delta. None are caller-claimable.
        // `delta` is the RAW pool delta, before any hook delta is applied (Hooks.sol:299 vs :311).
        bool isBuy = _isBuy(params.zeroForOne); // buy = QPULL flows out to swapper
        uint256 grossQpull = _abs(qpullIs0 ? delta.amount0() : delta.amount1()); // QPULL trade size (TaxTaken event)
        uint256 poolWeth = _abs(qpullIs0 ? delta.amount1() : delta.amount0()); // the pool's WETH leg

        uint256 fee;
        int128 hookUnspecified; // stays 0 when the fee rode beforeSwap's specified delta
        if (_wethSpecified(params)) {
            // exact-in BUY or exact-out SELL: beforeSwap already put `fee` on the specified WETH leg.
            fee = _specifiedWethFee(params.amountSpecified);
            uint256 amt =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            // Full fill <=> the pool's specified leg == amountToSwap (Pool.sol:453-460). This also catches fee
            // drift between the two callbacks, and a PoolManager that ignored bits 7/3.
            if (poolWeth != (isBuy ? amt - fee : amt + fee)) revert PartialFill();
        } else if (isBuy) {
            // exact-out BUY: WETH is the unspecified input P. fee = ceil(P*t/(BPS-t)) >= t of (P + fee).
            fee = _ceilDiv(poolWeth * TAX_BPS, BPS - TAX_BPS);
            hookUnspecified = int128(int256(fee)); // fee <= P/24 + 1 and P fits int128
        } else {
            // exact-in SELL: WETH is the unspecified output G. Floor division (keeper.js grossUpForExemptSell
            // mirrors it). The saturating 20/16/12/8 -> 4% launch schedule lives in _taxBps.
            fee = (poolWeth * _taxBps(false)) / BPS;
            hookUnspecified = int128(int256(fee)); // fee <= G/5
        }

        // The WETH the buyer actually parts with: exact-in buy (amt - fee) + fee == G exactly; exact-out buy P + fee.
        uint256 wethPaid = isBuy ? poolWeth + fee : 0;

        // Launch holder gate (GATE_DURATION() = 1h), buys only, keyed on tx.origin (not hookData, not `sender`):
        // the EOA that signed this transaction. Fails closed, and a Gated revert unwinds beforeSwap's delta
        // together with the swap.
        // Inside that same window a holder is also throttled: a per-wallet cooldown and a per-buy size cap that
        // binds until the wallet's cumulative gated spend reaches its budget, all on the SAME tx.origin so gate
        // and throttle cannot disagree on identity.
        if (isBuy && launchTime != 0 && block.timestamp < launchTime + GATE_DURATION()) {
            if (nft.balanceOf(tx.origin) == 0) revert Gated();
            _throttleEarlyBuy(tx.origin, wethPaid);
        }

        // Hook delta: -fee now, +fee when the PoolManager accounts the hook delta (PoolManager.sol:222).
        // The PoolManager must physically hold `fee` WETH at this point (take precedes the caller's settle).
        if (fee != 0) poolManager.take(Currency.wrap(weth), treasury, fee);

        if (isBuy) {
            // CREDIT INVARIANT: credit * TAX_BPS <= fee * BPS (floor division), and credit <= WETH actually paid.
            // With the ceil fees above the min never binds on a full fill (25 * fee >= wethPaid), so credit ==
            // wethPaid: honest credit equals the ETH spent to the wei.
            uint256 credit = (fee * BPS) / TAX_BPS;
            if (credit > wethPaid) credit = wethPaid;
            if (credit != 0) _record(tx.origin, credit);
        }

        emit TaxTaken(tx.origin, isBuy, grossQpull, weth, fee);
        return (this.afterSwap.selector, hookUnspecified);
    }

    function _isBuy(bool zeroForOne) internal view returns (bool) {
        return qpullIs0 ? !zeroForOne : zeroForOne;
    }

    /// @dev WETH is the specified currency iff (exact-in == buy). Equivalent to v4's mapping (Hooks.sol:306-308)
    ///      for both token orders.
    function _wethSpecified(IPoolManager.SwapParams calldata p) internal view returns (bool) {
        return (p.amountSpecified < 0) == _isBuy(p.zeroForOne);
    }

    /// @dev Buys are flat TAX_BPS. Sells decay from 20% to 4% over the first 48h (-4pp per 12h step), a
    ///      sell-only launch anti-dump. SATURATING schedule: floor at TAX_BPS instead of a
    ///      bare subtraction. With the shipped 48h/12h (and testnet 20m/5m) values the max step is 3, so the
    ///      result is 2000 / 1600 / 1200 / 800. SELL_DECAY() and SELL_STEP() are virtual and nothing ties them to
    ///      the two BPS constants: a subclass with a longer decay or a smaller step (e.g. 60m/5m -> step 11)
    ///      would otherwise drive `SELL_TAX_START_BPS - step * SELL_STEP_BPS` below zero and REVERT every sell in
    ///      the window tail. Flooring cannot underflow: a mis-set subclass degrades to the flat 4% early.
    ///      SUBCLASS-SEAM GUARD: the `? TAX_BPS` saturation arm is unreachable on this base and on
    ///      QpullTaxHookTestnet (max decayBps 1200 < 1600); only a subclass with a longer decay/step ratio can
    ///      reach it (test/QpullTaxHook.t.sol LongDecaySellHook exercises it).
    function _taxBps(bool isBuy) internal view returns (uint256) {
        if (isBuy || launchTime == 0 || block.timestamp >= launchTime + SELL_DECAY()) return TAX_BPS;
        uint256 decayBps = ((block.timestamp - launchTime) / SELL_STEP()) * SELL_STEP_BPS;
        return decayBps >= SELL_TAX_START_BPS - TAX_BPS ? TAX_BPS : SELL_TAX_START_BPS - decayBps;
    }

    /// @dev Single source of truth for BOTH callbacks. Pure in (amountSpecified, launchTime, block.timestamp).
    ///      NEVER replace it with a tstore handoff: a stale slot from an earlier swap is the worse failure.
    function _specifiedWethFee(int256 amountSpecified) internal view returns (uint256 fee) {
        // int256.min: the checked negation panics.
        uint256 amt = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (amt > MAX_AMOUNT) revert SwapTooLarge();
        // exact-in BUY: the fee sits inside the spend; fee <= amt, so v4's kind-flip check never fires (Hooks.sol:275).
        if (amountSpecified < 0) return _ceilDiv(amt * TAX_BPS, BPS);
        // exact-out SELL: fee >= bps of (amt + fee), and the pool leg amt + fee must fit int128 (Pool.sol:455/459).
        uint256 bps = _taxBps(false);
        fee = _ceilDiv(amt * bps, BPS - bps);
        if (amt + fee > MAX_AMOUNT) revert SwapTooLarge();
    }

    function _ceilDiv(uint256 x, uint256 d) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / d + 1;
    }

    /// @dev Game notifications, credited to the signer, on BUYS ONLY. A bare catch means no
    ///      returndata copy. A registry LOGIC fault costs only that trade's rewards (RecordFailed). A
    ///      registry that ran OUT OF GAS leaves this frame at most g*(1-(63/64)^d) of the gas it had, which is
    ///      under g/8 for any depth d <= 8, so the whole buy reverts (RecordOutOfGas) instead of charging the tax
    ///      and crediting nothing.
    function _record(address buyer, uint256 credit) internal {
        uint256 g = gasleft();
        try packRegistry.recordBuy(buyer, credit) { }
        catch {
            if (gasleft() < g / RECORD_OOG_DIVISOR) revert RecordOutOfGas("pack");
            emit RecordFailed("pack", buyer, credit);
        }
        g = gasleft();
        try leaderboardRegistry.recordBuy(buyer, credit) { }
        catch {
            if (gasleft() < g / RECORD_OOG_DIVISOR) revert RecordOutOfGas("leaderboard");
            emit RecordFailed("leaderboard", buyer, credit);
        }
    }

    /// @notice Launch throttle for one buyer. Runs ONLY inside the 1-hour gate window, only on buys, and
    ///         only for a wallet that already passed the holder gate.
    /// @dev    Checks then effects, in one internal call with no external call in between, so the record
    ///         cannot be observed half-updated. Each rejection has its own error: an integrator, or a
    ///         front end, can tell "too big" (EarlyBuyTooLarge) from "too soon" (BuyCooldown) without guessing.
    ///         There is no third rejection: no buy count is ever enforced.
    ///         Deliberately keyed on tx.origin, matching the gate exactly (see the contract header).
    function _throttleEarlyBuy(address buyer, uint256 wethIn) internal {
        EarlyBuyer memory s = earlyBuyer[buyer];
        // The size cap is gated on CUMULATIVE SPEND, not on a buy count. The wallet gets a budget of
        // EARLY_BUY_COUNT * earlyBuyCapWei for the whole window; while it is unspent, no single buy may
        // exceed earlyBuyCapWei. Only real volume advances a wallet toward the uncapped tail: a bounded
        // early accumulation, then uncapped.
        // The budget product SATURATES: `earlyBuyCapWei == type(uint256).max` means "no cap", and a plain
        // EARLY_BUY_COUNT * cap would overflow (panic 0x11) for it. Saturating keeps that meaning: the
        // budget becomes max, and `wethIn > cap` is unreachable anyway, so an uncapped hook stays uncapped.
        uint256 cap = earlyBuyCapWei;
        uint256 budget = cap > type(uint256).max / EARLY_BUY_COUNT ? type(uint256).max : EARLY_BUY_COUNT * cap;
        if (uint256(s.spentWei) < budget && wethIn > cap) revert EarlyBuyTooLarge();
        if (s.lastBuyAt != 0 && block.timestamp < uint256(s.lastBuyAt) + BUY_COOLDOWN()) revert BuyCooldown();
        // uint64 holds timestamps past year 2500; buys just counts up (uint32 cannot overflow in one window) and
        // is read by NFTCollection's launch transfer-lock, not by this function.
        // spentWei saturates rather than wrapping: once past the budget the exact total stops mattering, and
        // a saturating add can never silently re-arm the cap by overflowing back under it.
        uint256 spent = uint256(s.spentWei) + wethIn;
        if (spent > type(uint128).max) spent = type(uint128).max;
        earlyBuyer[buyer] =
            EarlyBuyer({ lastBuyAt: uint64(block.timestamp), buys: s.buys + 1, spentWei: uint128(spent) });
    }

    function _abs(int128 x) internal pure returns (uint256) {
        // promote before negating so type(int128).min cannot overflow
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }
}
