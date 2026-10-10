// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { LpSizing } from "./LpSizing.sol";
import { LaunchGuards } from "./LaunchGuards.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { Treasury } from "../src/Treasury.sol";

/// @dev The real-WETH9 calls this script makes (wrap only; there is no unwrap path in a go-live).
interface IWETH {
    function deposit() external payable;
}

/// @dev What the go-live reads off NFTCollection to anchor LP_ETH_WEI to what the mint actually raised.
interface INftLaunchLedger {
    function launched() external view returns (bool);
    function totalMinted() external view returns (uint256);
    function mintPrice() external view returns (uint256);
    function LP_BPS() external view returns (uint256);
    function RESERVE_CAP() external view returns (uint256);
    function reserveMinted() external view returns (bool);
    function lpReserve() external view returns (uint256);
    function lpTreasury() external view returns (address);
    function withdrawProceeds() external;
    function taxHook() external view returns (address);
}

/// @dev BaseVault and QuotronRouterAdapter both expose their immutable QUOTRON binding.
interface IQuotronBound {
    function quotron() external view returns (address);
}

interface IRouterAdapterBindings {
    function router() external view returns (address);
    function weth() external view returns (address);
    function quotron() external view returns (address);
    function treasury() external view returns (address);
}

interface IQpullWethAdapterBindings {
    function poolManager() external view returns (address);
    function qpull() external view returns (address);
    function weth() external view returns (address);
    function treasury() external view returns (address);
    function poolKeySet() external view returns (bool);
    function poolKey() external view returns (address, address, uint24, int24, address);
}

interface IGenesisClock {
    function genesis() external view returns (uint256);
}

interface IPackRegistryEngine {
    function engine() external view returns (address);
}

interface IRaffleOpening {
    function packs() external view returns (address);
    function openingWindowOpen() external view returns (bool);
    function vault() external view returns (address);
    function claimManager() external view returns (address);
}

/// @dev The frozen engine->vault map every prize payout goes through (ClaimManager).
interface IClaimManagerGraph {
    function engineVault(address engine) external view returns (address);
    function enginesLocked() external view returns (bool);
    function engineCount() external view returns (uint256);
}

/// @dev BaseVault's write-once single controller.
interface IVaultController {
    function controller() external view returns (address);
}

/// @notice GO-LIVE (MAINNET). The single reviewed script that takes the Deploy.s.sol protocol live, in this
///         order, from the deployer key:
///
///           0. PREFLIGHT, all view, before any transaction (see `_preflight`). Every binding the launch
///              freezes is read back from the chain and compared with the Deploy output: the lock and the
///              hook, the six routing bindings, the engine<->vault graph that pays out of the three frozen
///              vaults, the QUOTRON-side externals (pinned on 4663), the keeper (pinned), the LP
///              amount against what the mint raised, the convert threshold (dust-QPULL convert grief) and
///              GENESIS against the clock (RaffleEngine.openingWindowOpen).
///           1. Treasury.setMaxConvertPerCall + setMaxWethConvertPerCall   (pool-sized; convert() is
///              fail-CLOSED / NotConfigured until both are armed)
///           2. NFTCollection.withdrawProceeds() when the LP bucket is still in the NFT (exact anchor), then
///              move the WETH shortfall + the deployer's QPULL into the LOCK, so the lock holds at least
///              LP_ETH_WEI of WETH (any excess is a donation that is never seeded) and 100% of supply. Only the
///              SHORTFALL is funded, and WETH already in the deployer is sent before any new ETH is wrapped, so a
///              re-run after an interrupted broadcast never funds the lock twice and never wraps twice.
///           3. lock.seed(sqrtPriceX96, liq, totalSupply, LP_ETH_WEI): ONE transaction that creates the pool
///              AND adds the liquidity. afterInitialize stamps launchTime here. The lock refuses to latch
///              unless the add COSTS the declared amounts +/- 50 bps, measured from the pool manager's delta,
///              during the REAL broadcast. sqrtPriceX96 and liq are DERIVED (script/LpSizing.sol).
///           4. on-chain asserts against the post-seed state: lock.seeded(); the canonical position is owned by
///              the lock and is the pool's whole liquidity; deployer QPULL == 0; launchTime != 0; caps armed.
///           5. CONVERT REHEARSAL, simulation only (never broadcast), twice, each reverted afterwards: (a) fund the
///              Treasury with a little WETH and call convert() as the pinned keeper, requiring QUOTRON in all three
///              vaults and WETH at the team address; (b) the same with a threshold-sized QPULL donation to the
///              Treasury simulated as well, so convert LEG 1 (QPULL -> WETH through the fee-exempt
///              QpullWethAdapter, which lockRouting freezes) runs against the seeded pool too. A wrong QUOTRON /
///              QUOTRON_ROUTER / adapter binding fails HERE, before anything is frozen. Every check is a
///              before/after DELTA, so dust anyone can send to a public address cannot fail it.
///           6. Treasury.lockRouting(six declared bindings)   <- LAST
///
///         THE INITIALIZER IS THE LOCK, NOT A KEY. QpullTaxHook.initializer == LOCK, so only the lock can create
///         the canonical pool and only the lock can ever add liquidity (the add gate is
///         `sender == initializer`; there is no tx.origin in it). The sender of this script must be
///         `lock.opener()` (the only address that may call seed) AND the Treasury owner, which Deploy.s.sol
///         makes the same deployer key. The deployer is also NFTCollection.lpTreasury, so the LP bucket the
///         mint raised arrives in the key that seeds it.
///
///         RUN FROM THE DEPLOYER KEY (REQUIRED FLAGS):
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnet --rpc-url rh --account deployer
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnet --rpc-url rh --account deployer \
///             --broadcast --slow
///           - `--slow` IS REQUIRED on every broadcast of this file (GoLiveMainnet and GoLiveMainnetResume). It sends
///             each transaction only after the previous one is mined, so a failure stops the sequence with a clean
///             prefix. Without it forge sends the whole sequence at once, and a later transaction can land after
///             an earlier one failed (a failed lock.seed followed by a landed lockRouting). That state is
///             recoverable too (GoLiveMainnetResume, below), but it should never be produced on purpose.
///           - `--account <deployer>` sets the sender; with a raw --private-key add `--sender <deployer>`. The
///             sender is checked on-chain against lock.opener(), Treasury.owner() and NFTCollection.lpTreasury().
///           - Do NOT use `--resume` to finish an interrupted run, and do not re-run while any go-live transaction
///             from this key is still pending. Both scripts re-read the chain and send only what is missing; a
///             `--resume` replays calldata computed against the old state.
///
///         ORDER: NFTCollection.finalizeLaunch() -> Deploy.s.sol -> THIS SCRIPT. PREREQUISITES: finalizeLaunch()
///         has run (nft.launched()), NFTCollection.lpTreasury is this key, and the convert keeper is set on the
///         Treasury and is the only keeper.
///         RECOMMENDED: do NOT call withdrawProceeds before this script. While the LP bucket still sits in the
///         NFT (lpReserve > 0) the anchor is EXACT and the script withdraws it to this key as its first
///         broadcast step. If it was already withdrawn, the anchor falls back to bounds computed from
///         totalMinted, mintPrice and the reserve latch (see _lpBucketBounds).
///
///         ENV (vm.envAddress/vm.envUint revert if unset, so a missing input fails closed):
///           POOL_MANAGER, QPULL, WETH, TREASURY, HOOK, LOCK     from the Deploy.s.sol export block
///           PRIZE_VAULT, HOLDER_VAULT, LEADERBOARD_VAULT, TEAM_WALLET, QPULL_WETH_ADAPTER, WETH_QUOTRON_ADAPTER
///                                        the six bindings lockRouting freezes, from the Deploy export block
///           QUOTRON, QUOTRON_ROUTER      the QUOTRON-side externals (pinned on 4663)
///           KEEPER                       the convert keeper (the CONVERT_PK address)
///           LP_ETH_WEI                   wei of WETH the pool is seeded with. Must equal the mint's LP bucket
///                                        (80% of what the mint raised, read on-chain) plus LP_TOPUP_WEI.
///           MAX_CONVERT_PER_CALL         D18{QPULL} pool-sized ceiling per convert()
///           MAX_WETH_CONVERT_PER_CALL    D18{WETH} pool-sized ceiling per convert()
///         OPTIONAL:
///           LP_TOPUP_WEI                 wei of WETH added on top of the mint's LP bucket (default 0). At most
///                                        the larger of the bucket itself and the 1 ether floor: a normal raise
///                                        can never be priced more than 2x the mint-anchored price by top-up,
///                                        and a raise whose bucket is under 1 ether can still be topped up to
///                                        the floor and go live without a script change.
///           ACCEPT_GENESIS_SLIP_SECS     required only when go-live is more than 12h after GENESIS (or the
///                                        opening window has already closed): the operator declares the slip.
///         DONATIONS CANNOT BLOCK OR REPRICE THE LAUNCH. The price and the liquidity are derived from LP_ETH_WEI
///         and totalSupply only (LpSizing), never from a balance, and lock.seed charges exactly what that
///         liquidity costs at that price. WETH anyone sends the lock beyond LP_ETH_WEI is not seeded: it stays in
///         the lock (which has no path out) and is logged. A donation below LP_ETH_WEI only reduces what this key
///         funds. The lock has no payable entry, so forced ETH is never read, and before the seed 100% of the QPULL
///         supply sits in this key and the lock, so nobody else can send the lock QPULL.
///         fee / tickSpacing are NOT env: they are read from the hook (the only key it admits).
///
///         SIZING: the lock has NO path out, so whatever the seed does not consume is stranded forever.
///         LpSizing sets the price to the LP_ETH_WEI : supply ratio, which makes both sides consume fully.
///
///         ATOMICITY AND RECOVERY: forge simulates the whole run before broadcasting, so a failed require sends
///         NOTHING. The broadcast is [setMaxConvertPerCall, setMaxWethConvertPerCall, withdrawProceeds?, WETH.deposit?,
///         WETH.transfer?, QPULL.transfer?, lock.seed, lockRouting]. Every state a partial broadcast can leave is
///         keyed by the two on-chain latches, and each has exactly one scripted, preflighted path:
///           - lock NOT seeded, routing NOT locked (anything up to and including a failed seed): re-run THIS
///             script. Preflight accepts a lock that already holds part (or more than all) of the WETH, a deployer
///             that holds WETH from a wrap whose transfer never landed, QPULL split between the deployer and the
///             lock, and caps that are already armed; it funds only the shortfall.
///           - lock seeded, routing NOT locked (lockRouting failed or never sent, or the caps failed so lockRouting
///             reverted NotConfigured): `--tc GoLiveMainnetResume` re-arms the caps (idempotent), re-verifies
///             every binding and the seeded position, repeats both convert rehearsals and then locks routing.
///           - lock NOT seeded, routing LOCKED (only reachable without `--slow`: seed failed and lockRouting still
///             landed): `--tc GoLiveMainnetResume` proves the frozen routing is exactly the six declared bindings,
///             re-runs the full go-live preflight except the routing latch, funds the shortfall, seeds, asserts the
///             position and rehearses convert. lockRouting requires both caps, so this state always has them.
///           - lock seeded, routing LOCKED: nothing to resume. GoLiveMainnetResume re-verifies the seeded position
///             and the frozen bindings read-only and broadcasts nothing.
///         Each recovery path is itself a sequence whose partial failure lands in one of these four states again.
contract GoLiveMainnet is Script {
    uint256 internal constant BPS = 10_000;
    /// @notice Hard floor. A wei/ether unit error (LP_ETH_WEI=21) cannot seed.
    uint256 internal constant MIN_LP_ETH_WEI = 1 ether;
    /// @notice Dust-QPULL convert grief: a threshold-sized exempt sell must quote at least this much WETH at the seed
    ///         price, so a donation that trips the QPULL leg converts instead of swapping to 0 wei.
    uint256 internal constant MIN_THRESHOLD_QUOTE_WEI = 1e12;
    /// @notice Go-live may run at most this long before GENESIS...
    uint256 internal constant MAX_GENESIS_EARLY = 1 hours;
    /// @notice ...and this long after it without an explicit ACCEPT_GENESIS_SLIP_SECS declaration.
    uint256 internal constant MAX_GENESIS_SLIP = 12 hours;
    /// @notice WETH the convert rehearsal funds the Treasury with (capped at maxWethConvertPerCall).
    uint256 internal constant REHEARSAL_WETH = 0.01 ether;
    /// @dev A fixed, keyless address that only ever exists inside the simulation.
    address internal constant REHEARSAL_FUNDER = address(uint160(uint256(keccak256("quopull.golive.rehearsal"))));


    // Env + chain-derived config packed into a struct (stack-too-deep hygiene).
    struct GL {
        address poolManager;
        address qpull;
        address weth;
        address treasury;
        address hook;
        address lock; // QpullLiquidityLock, deployed by Deploy.s.sol as the hook's initializer
        // The four payout destinations lockRouting() will FREEZE FOREVER. Declared from the Deploy output,
        // never read back out of the Treasury: reading them from the thing being frozen would prove nothing.
        address prizeVault;
        address holderVault;
        address leaderboardVault;
        address team;
        // lockRouting freezes SIX bindings, not four: these two are the arbitrary-code contracts convert()
        // approves tokens to and calls. Freezing a wrong one is the least recoverable of the six.
        address qpullWethAdapter;
        address wethQuotronAdapter;
        address quotron; // pinned on 4663 (LaunchGuards)
        address quotronRouter; // pinned on 4663 (LaunchGuards)
        address keeper; // the convert keeper, pinned
        // derived from the hook's immutables, never env
        address nft;
        address packs;
        address raffle;
        address leaderboardRegistry;
        uint24 fee; // hook.canonicalFee
        int24 tickSpacing; // hook.canonicalTickSpacing
        uint256 lpEth; // LP_ETH_WEI
        uint256 lpTopUp; // LP_TOPUP_WEI
        uint256 lpBucketLo; // mint-derived LP bucket bounds (see _lpBucketBounds)
        uint256 lpBucketHi;
        bool withdrawLp; // the bucket is still in the NFT: withdraw it to this key in the broadcast (exact anchor)
        uint256 acceptSlip; // ACCEPT_GENESIS_SLIP_SECS
        // sqrtPriceX96 and liq are DERIVED from (lpEth, supply) by LpSizing, never env
        uint160 sqrtPriceX96;
        uint128 liq;
        uint256 maxConvertPerCall;
        uint256 maxWethConvertPerCall;
    }

    function run() external virtual {
        GL memory g = _env();
        address me = msg.sender; // = lock.opener() = Treasury owner = NFTCollection.lpTreasury
        _preflight(g, me);
        PoolKey memory key = _canonicalKey(g);
        QpullLiquidityLock lock = _goLive(g, key, me);
        _report(g, address(lock));
    }

    function _env() internal view returns (GL memory g) {
        _envAddresses(g);
        _envAmounts(g);
        // The canonical fee/tickSpacing and the game graph are the hook's immutables. Read the source of truth
        // rather than trusting an env copy of it.
        QpullTaxHook h = QpullTaxHook(g.hook);
        g.fee = h.canonicalFee();
        g.tickSpacing = h.canonicalTickSpacing();
        g.nft = address(h.nft());
        g.packs = address(h.packRegistry());
        g.leaderboardRegistry = address(h.leaderboardRegistry());
        g.raffle = IPackRegistryEngine(g.packs).engine();
    }

    /// @dev The env seam. Production reads the process environment; a test overrides these three to supply
    ///      per-test values, because vm.setEnv writes one process-wide environment that concurrently running
    ///      tests would race on.
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envUint(string memory key) internal view virtual returns (uint256) {
        return vm.envUint(key);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view virtual returns (uint256) {
        return vm.envOr(key, dflt);
    }

    /// @dev Every address is REQUIRED: vm.envAddress reverts when unset.
    function _envAddresses(GL memory g) internal view {
        g.poolManager = _envAddress("POOL_MANAGER");
        g.qpull = _envAddress("QPULL");
        g.weth = _envAddress("WETH");
        g.treasury = _envAddress("TREASURY");
        g.hook = _envAddress("HOOK");
        g.lock = _envAddress("LOCK");
        g.prizeVault = _envAddress("PRIZE_VAULT");
        g.holderVault = _envAddress("HOLDER_VAULT");
        g.leaderboardVault = _envAddress("LEADERBOARD_VAULT");
        g.team = _envAddress("TEAM_WALLET");
        g.qpullWethAdapter = _envAddress("QPULL_WETH_ADAPTER");
        g.wethQuotronAdapter = _envAddress("WETH_QUOTRON_ADAPTER");
        g.quotron = _envAddress("QUOTRON");
        g.quotronRouter = _envAddress("QUOTRON_ROUTER");
        g.keeper = _envAddress("KEEPER");
    }

    function _envAmounts(GL memory g) internal view {
        // Unit-suffixed. The old LP_ETH name is deliberately not read, so a stale env fails
        // closed instead of seeding against a value nobody re-checked.
        g.lpEth = _envUint("LP_ETH_WEI");
        g.lpTopUp = _envOrUint("LP_TOPUP_WEI", uint256(0));
        g.acceptSlip = _envOrUint("ACCEPT_GENESIS_SLIP_SECS", uint256(0));
        g.maxConvertPerCall = _envUint("MAX_CONVERT_PER_CALL");
        g.maxWethConvertPerCall = _envUint("MAX_WETH_CONVERT_PER_CALL");
    }

    /// @dev Everything that must be true BEFORE any tx is sent. All view; reverts fail the simulation.
    function _preflight(GL memory g, address me) internal view {
        _preflightUnseeded(g, me);
        // A locked routing table with an unseeded lock is a partial broadcast (see the header): the recovery is
        // GoLiveMainnetResume, which seeds without trying to lock again.
        require(
            !Treasury(g.treasury).routingLocked(),
            "go-live: Treasury routing already locked (partial broadcast: run --tc GoLiveMainnetResume)"
        );
    }

    /// @dev The go-live preflight minus the routing latch: shared by a fresh go-live and by the recovery of a
    ///      broadcast whose lockRouting landed while lock.seed did not.
    function _preflightUnseeded(GL memory g, address me) internal view {
        Treasury t = Treasury(g.treasury);
        // (a) the hook's initializer is the LOCK and the lock is bound to this hook, pair and key.
        _preflightLock(g, me);
        require(
            !QpullLiquidityLock(g.lock).seeded(), "go-live: the lock has already been seeded (run --tc GoLiveMainnetResume)"
        );
        // (b) the env addresses agree with what the hook was built against, and the hook is the design-D build.
        _preflightHook(g);
        // (c) the mint is closed, not already live, and the Treasury is ours to finish.
        require(
            INftLaunchLedger(g.nft).launched(), "go-live: NFT mint not finalized (run NFTCollection.finalizeLaunch first)"
        );
        require(QpullTaxHook(g.hook).launchTime() == 0, "go-live: pool already initialized (launchTime != 0)");
        require(t.owner() == me, "go-live: sender is not the Treasury owner");
        // (d) the caps are real pool-sized ceilings: never 0 and never type(uint256).max.
        require(
            g.maxConvertPerCall != 0 && g.maxConvertPerCall != type(uint256).max,
            "go-live: MAX_CONVERT_PER_CALL must be a pool-sized value"
        );
        require(
            g.maxWethConvertPerCall != 0 && g.maxWethConvertPerCall != type(uint256).max,
            "go-live: MAX_WETH_CONVERT_PER_CALL must be a pool-sized value"
        );
        // (e) the six frozen bindings and the keeper, and the engine graph that pays out of the three vaults.
        _preflightRouting(g, me);
        _preflightEngines(g);
        // (f) QUOTRON, QUOTRON_ROUTER and both adapters.
        _preflightQuotron(g);
        // (g) LP_ETH_WEI is anchored to the mint, and the funding is consistent.
        _preflightLp(g, me);
        // (h) the convert threshold (dust-QPULL convert grief).
        _preflightConvertThreshold(g);
        // (i) GENESIS against the clock, and the opening window.
        _preflightGenesis(g);
    }

    function _preflightHook(GL memory g) internal view {
        QpullTaxHook h = QpullTaxHook(g.hook);
        require(address(h.poolManager()) == g.poolManager, "go-live: POOL_MANAGER != hook.poolManager");
        require(h.qpull() == g.qpull, "go-live: QPULL != hook.qpull");
        require(h.weth() == g.weth, "go-live: WETH != hook.weth");
        require(h.treasury() == g.treasury, "go-live: TREASURY != hook.treasury");
        // The hook must be the 0x1ACC "design-D" build (beforeSwap + its delta, which lets it take the WETH fee on the
        // specified currency), not a stale 0x1A44 one.
        require(h.REQUIRED_FLAGS() == 0x1ACC, "go-live: hook is not the design-D build (REQUIRED_FLAGS != 0x1ACC)");
        require(uint160(g.hook) & 0x3FFF == 0x1ACC, "go-live: HOOK address does not carry flags 0x1ACC");
        // The NFT must be bound to THIS hook. NFTCollection.setTaxHook is write-once and is
        // what makes the 1-hour launch pass transfer lock work (_enforceLaunchLock reads taxHook on every transfer). A
        // redone deploy that left the NFT pointing at an older hook, or never wired it, would launch with that lock
        // silently open. g.nft is hook.nft(), so this closes the loop in both directions. Checked on the fresh go-live
        // and on every GoLiveMainnetResume path (all of them run this function).
        require(
            INftLaunchLedger(g.nft).taxHook() == g.hook,
            "go-live: NFTCollection.taxHook() != HOOK (the NFT is not wired to this hook: the launch transfer lock would not apply)"
        );
    }

    /// @dev The six bindings this run will FREEZE FOREVER, checked here so a mismatch aborts the simulation
    ///      rather than committing the launch. Treasury.lockRouting re-checks the same equality on-chain, so
    ///      the bound holds during the real broadcast and not only in this simulation.
    function _preflightRouting(GL memory g, address me) internal view {
        Treasury t = Treasury(g.treasury);
        _requireDeclaredRouting(g);
        // The keeper set must be exactly the ONE keeper the operator intends. isKeeper is a bare mapping
        // with no enumeration, so `keeperCount == 1` plus `isKeeper(KEEPER)` is the only way to say "this one
        // and no other" (the Treasury NatSpec relies on exactly this pair).
        require(g.keeper != me, "go-live: KEEPER is the deployer (the convert keeper must be its own key)");
        require(t.isKeeper(g.keeper), "go-live: KEEPER is not a Treasury keeper");
        require(t.keeperCount() == 1, "go-live: Treasury must have EXACTLY ONE keeper before go-live");
    }

    /// @dev The six bindings lockRouting freezes, and the hook's immutable exemptSender, equal to the declared env.
    function _requireDeclaredRouting(GL memory g) internal view {
        Treasury t = Treasury(g.treasury);
        require(t.prizeVault() == g.prizeVault, "go-live: PRIZE_VAULT != Treasury.prizeVault");
        require(t.holderVault() == g.holderVault, "go-live: HOLDER_VAULT != Treasury.holderVault");
        require(
            t.leaderboardVault() == g.leaderboardVault, "go-live: LEADERBOARD_VAULT != Treasury.leaderboardVault"
        );
        require(t.team() == g.team, "go-live: TEAM_WALLET != Treasury.team");
        require(
            address(t.qpullWeth()) == g.qpullWethAdapter, "go-live: QPULL_WETH_ADAPTER != Treasury.qpullWeth"
        );
        require(
            address(t.wethQuotron()) == g.wethQuotronAdapter,
            "go-live: WETH_QUOTRON_ADAPTER != Treasury.wethQuotron"
        );
        // The hook's exemptSender is IMMUTABLE and must name the same leg-1 adapter, or every conversion
        // pays the 4% tax forever and no redeploy can fix it.
        require(
            QpullTaxHook(g.hook).exemptSender() == g.qpullWethAdapter,
            "go-live: hook.exemptSender != QPULL_WETH_ADAPTER (leg 1 would be taxed forever)"
        );
    }

    /// @dev The engine<->vault graph, checked BEFORE lockRouting freezes the three vault destinations. A
    ///      destination no engine can pay out of would otherwise be frozen forever and only caught afterwards, by
    ///      TransferOwnership's gate. This is the part of OwnershipBase._checkEngines / _checkWriteOnceRoles the
    ///      hook graph reaches without the two env-typed engines: the RaffleEngine (PackRegistry.engine) and the
    ///      ClaimManager it is bound to. It proves the map is frozen at exactly three engines, the raffle is bound
    ///      to the prize vault, and the only payout path out of each of the three vaults is that frozen map. Which
    ///      engine the map binds to the leaderboard and holder vaults needs the two env-typed engines, and
    ///      TransferOwnership._checkEngines re-proves it.
    function _preflightEngines(GL memory g) internal view {
        require(g.raffle.code.length > 0, "go-live: PackRegistry.engine is unset");
        IRaffleOpening raffle = IRaffleOpening(g.raffle);
        require(raffle.packs() == g.packs, "go-live: PackRegistry.engine is not bound to it");
        require(raffle.vault() == g.prizeVault, "go-live: RaffleEngine.vault != PRIZE_VAULT");
        address cmAddr = raffle.claimManager();
        require(cmAddr.code.length > 0, "go-live: RaffleEngine.claimManager has no code");
        IClaimManagerGraph cm = IClaimManagerGraph(cmAddr);
        require(cm.enginesLocked(), "go-live: ClaimManager engines are not locked");
        require(cm.engineCount() == 3, "go-live: ClaimManager does not bind exactly three engines");
        require(cm.engineVault(g.raffle) == g.prizeVault, "go-live: ClaimManager does not bind RaffleEngine to PRIZE_VAULT");
        require(IVaultController(g.prizeVault).controller() == cmAddr, "go-live: PRIZE_VAULT.controller != ClaimManager");
        require(
            IVaultController(g.holderVault).controller() == cmAddr, "go-live: HOLDER_VAULT.controller != ClaimManager"
        );
        require(
            IVaultController(g.leaderboardVault).controller() == cmAddr,
            "go-live: LEADERBOARD_VAULT.controller != ClaimManager"
        );
    }

    /// @dev The QUOTRON binding is an immutable in the Treasury, all three vaults and the WETH->QUOTRON
    ///      adapter; the router is an immutable in that adapter. A stale or codeless address used to pass every
    ///      preflight, and the first convert() then reverted forever with routing already frozen. Each binding
    ///      is now read back and compared, the externals are pinned on 4663, and `_rehearseConvert` exercises
    ///      them end to end against the seeded state before lockRouting.
    function _preflightQuotron(GL memory g) internal view {
        LaunchGuards.requireExternals(g.quotron, g.quotronRouter, g.weth, g.poolManager);
        Treasury t = Treasury(g.treasury);
        require(address(t.quotron()) == g.quotron, "go-live: QUOTRON != Treasury.quotron");
        require(address(t.weth()) == g.weth && address(t.qpull()) == g.qpull, "go-live: Treasury pair != QPULL/WETH");
        require(IQuotronBound(g.prizeVault).quotron() == g.quotron, "go-live: PRIZE_VAULT.quotron != QUOTRON");
        require(IQuotronBound(g.holderVault).quotron() == g.quotron, "go-live: HOLDER_VAULT.quotron != QUOTRON");
        require(
            IQuotronBound(g.leaderboardVault).quotron() == g.quotron, "go-live: LEADERBOARD_VAULT.quotron != QUOTRON"
        );
        IRouterAdapterBindings a = IRouterAdapterBindings(g.wethQuotronAdapter);
        require(a.router() == g.quotronRouter, "go-live: WETH_QUOTRON_ADAPTER.router != QUOTRON_ROUTER");
        require(a.quotron() == g.quotron && a.weth() == g.weth, "go-live: WETH_QUOTRON_ADAPTER pair != WETH/QUOTRON");
        require(a.treasury() == g.treasury, "go-live: WETH_QUOTRON_ADAPTER.treasury != TREASURY");
        IQpullWethAdapterBindings q = IQpullWethAdapterBindings(g.qpullWethAdapter);
        require(q.treasury() == g.treasury, "go-live: QPULL_WETH_ADAPTER.treasury != TREASURY");
        require(
            q.poolManager() == g.poolManager && q.qpull() == g.qpull && q.weth() == g.weth,
            "go-live: QPULL_WETH_ADAPTER is bound to a different manager or pair"
        );
        require(q.poolKeySet(), "go-live: QPULL_WETH_ADAPTER pool key not set");
        (address c0, address c1, uint24 fee, int24 ts, address hooks) = q.poolKey();
        (address lo, address hi) = g.qpull < g.weth ? (g.qpull, g.weth) : (g.weth, g.qpull);
        require(
            c0 == lo && c1 == hi && fee == g.fee && ts == g.tickSpacing && hooks == g.hook,
            "go-live: QPULL_WETH_ADAPTER pool key is not the canonical key"
        );
    }

    /// @notice The LP bucket NFTCollection's mint split paid out, bounded from on-chain state alone.
    /// @dev    Every paid mint splits msg.value 80/10/10 with LP absorbing the rounding, so the LP total is at
    ///         least `paid * LP_BPS / BPS` and at most that plus 2 wei per paid mint call. `reserveMint` passes
    ///         pay nothing and their count is not stored, only that a reserve (1..RESERVE_CAP passes) was taken,
    ///         so a reserve widens the window by at most RESERVE_CAP - 1 passes' LP share. The low bound assumes
    ///         a full RESERVE_CAP reserve and is exact when the reserve is RESERVE_CAP.
    function _lpBucketBounds(address nft) internal view returns (uint256 lo, uint256 hi) {
        INftLaunchLedger n = INftLaunchLedger(nft);
        uint256 minted = n.totalMinted();
        uint256 paidLo = minted;
        uint256 paidHi = minted;
        if (n.reserveMinted()) {
            uint256 cap = n.RESERVE_CAP();
            paidLo = minted > cap ? minted - cap : 0;
            paidHi = minted > 0 ? minted - 1 : 0;
        }
        uint256 price = n.mintPrice();
        uint256 lpBps = n.LP_BPS();
        lo = Math.mulDiv(paidLo * price, lpBps, BPS);
        hi = Math.mulDiv(paidHi * price, lpBps, BPS) + 2 * paidHi;
    }

    /// @dev LP_ETH_WEI alone sets the permanent launch price under a no-remove lock, and it used to
    ///      be checked only for `> 0` and against the deployer's balance, so LpSizing derived a price from a 10x
    ///      typo as happily as from the real number. It is now anchored to what the mint raised:
    ///        LP_ETH_WEI == (mint LP bucket) + LP_TOPUP_WEI,  LP_ETH_WEI >= 1 ether,
    ///        LP_TOPUP_WEI <= max(that bucket, 1 ether),
    ///      where the bucket is EXACT (NFTCollection.lpReserve) while it has not been withdrawn, and bounded from
    ///      totalMinted / mintPrice / the reserve latch once it has. The bucket is paid to THIS key
    ///      (lpTreasury == sender), so the pool is seeded with at least the 80% the site promises, checkably.
    ///      The top-up bound is the larger of the bucket and the floor: finalizeLaunch goes permissionless after
    ///      the backstop, so a raise whose bucket is under 1 ether is a reachable state, and it must be able to go
    ///      live by topping up to the floor rather than by editing this script.
    ///      The QPULL supply must sit entirely in the deployer and the lock (a re-run after an interrupted
    ///      funding), and only the WETH shortfall is funded, from the deployer's WETH first and then its ETH.
    function _preflightLp(GL memory g, address me) internal view {
        INftLaunchLedger n = INftLaunchLedger(g.nft);
        require(n.lpTreasury() == me, "go-live: NFTCollection.lpTreasury is not this key (the LP bucket goes elsewhere)");
        uint256 pending = n.lpReserve();
        if (pending != 0) {
            // exact: the whole LP bucket is still in the NFT, and this run withdraws it to this key first
            (g.lpBucketLo, g.lpBucketHi, g.withdrawLp) = (pending, pending, true);
        } else {
            (g.lpBucketLo, g.lpBucketHi) = _lpBucketBounds(g.nft);
        }
        require(g.lpEth >= MIN_LP_ETH_WEI, "go-live: LP_ETH_WEI below 1 ether (it is WEI: 21 ether = 21000000000000000000)");
        require(
            g.lpTopUp <= Math.max(g.lpBucketHi, MIN_LP_ETH_WEI),
            "go-live: LP_TOPUP_WEI exceeds both the mint's own LP bucket and the 1 ether floor"
        );
        require(
            g.lpEth >= g.lpBucketLo + g.lpTopUp,
            "go-live: LP_ETH_WEI is below the mint's LP bucket + LP_TOPUP_WEI (short of the 80% to liquidity)"
        );
        require(
            g.lpEth <= g.lpBucketHi + g.lpTopUp,
            "go-live: LP_ETH_WEI is above the mint's LP bucket + LP_TOPUP_WEI (declare any top-up in LP_TOPUP_WEI)"
        );

        uint256 supply = IERC20(g.qpull).totalSupply();
        require(
            IERC20(g.qpull).balanceOf(me) + IERC20(g.qpull).balanceOf(g.lock) == supply,
            "go-live: 100% of the QPULL supply is not held by the deployer and the lock"
        );
        // WETH already in the lock counts toward LP_ETH_WEI, and any amount ABOVE it is a stranger's donation that
        // is simply not seeded (an earlier `lockWeth <= LP_ETH_WEI` require here let anyone block the scripted
        // go-live by donating more than bucket + max(bucket, 1 ether)). The seed below declares and consumes exactly
        // LP_ETH_WEI whatever the lock holds, so the excess cannot move the price; it strands and _fund logs it.
        // An interrupted run whose WETH.deposit landed but whose transfer did not leaves the WETH in
        // this key. It counts toward the shortfall (and _fund sends it before wrapping anything new).
        require(
            me.balance + pending + IERC20(g.weth).balanceOf(me) >= _lockWethShortfall(g),
            "go-live: deployer ETH + WETH < the WETH still to fund (gas is on top)"
        );
    }

    /// @dev WETH this key still has to move into the lock so it holds at least LP_ETH_WEI. Zero when the lock
    ///      already holds that much or more (an earlier interrupted funding, or a donation).
    function _lockWethShortfall(GL memory g) internal view returns (uint256) {
        uint256 lockWeth = IERC20(g.weth).balanceOf(g.lock);
        return lockWeth >= g.lpEth ? 0 : g.lpEth - lockWeth;
    }

    /// @dev Dust-QPULL convert grief. The QPULL leg runs whenever the Treasury's QPULL balance
    ///      reaches convertThreshold; with 0 any dust donation forces it, it swaps to 0 WETH and the adapter
    ///      refuses minOut == 0, so convert() reverts. Fixed by config: non-zero, no larger than one capped
    ///      slice, and big enough that a threshold-sized sell quotes >= 1e12 wei at the seed price (spot,
    ///      threshold * LP_ETH_WEI / supply). Recoverable before go-live with Treasury.setConvertThreshold.
    function _preflightConvertThreshold(GL memory g) internal view {
        uint256 th = Treasury(g.treasury).convertThreshold();
        require(th != 0, "go-live: Treasury.convertThreshold is 0 (dust-QPULL convert grief)");
        require(g.maxConvertPerCall >= th, "go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold");
        require(
            Math.mulDiv(th, g.lpEth, IERC20(g.qpull).totalSupply()) >= MIN_THRESHOLD_QUOTE_WEI,
            "go-live: convertThreshold quotes < 1e12 wei at the seed price (raise it with setConvertThreshold)"
        );
    }

    /// @dev GENESIS is immutable in every engine and registry, and nothing compared it with the clock
    ///      before the irreversible seed. The registries the hook reaches must agree with each other, the
    ///      go-live must be within an hour before GENESIS, and a go-live more than 12h after it (or after the
    ///      opening window closed, RaffleEngine.openingWindowOpen) must be declared with
    ///      ACCEPT_GENESIS_SLIP_SECS. A hard stop there would be worse than the slip: NFTCollection.setTaxHook
    ///      is write-once, so the protocol cannot be redeployed against this raise.
    function _preflightGenesis(GL memory g) internal view {
        require(g.raffle.code.length > 0, "go-live: PackRegistry.engine is unset");
        uint256 gen = IGenesisClock(g.packs).genesis();
        require(IRaffleOpening(g.raffle).packs() == g.packs, "go-live: PackRegistry.engine is not bound to it");
        require(
            IGenesisClock(g.raffle).genesis() == gen && IGenesisClock(g.leaderboardRegistry).genesis() == gen,
            "go-live: RaffleEngine / LeaderboardRegistry genesis != PackRegistry genesis"
        );
        require(block.timestamp + MAX_GENESIS_EARLY >= gen, "go-live: more than 1h before GENESIS (wait)");
        uint256 slip = block.timestamp > gen ? block.timestamp - gen : 0;
        if (slip > MAX_GENESIS_SLIP) {
            require(
                g.acceptSlip >= slip,
                "go-live: more than 12h after GENESIS; set ACCEPT_GENESIS_SLIP_SECS >= the slip to proceed"
            );
        }
        if (!IRaffleOpening(g.raffle).openingWindowOpen()) {
            require(
                slip > 0 && g.acceptSlip >= slip,
                "go-live: the opening accumulation window has already closed; declare ACCEPT_GENESIS_SLIP_SECS"
            );
        }
    }

    /// @dev The lock is the hook's `initializer`: the ONLY address that may create the canonical pool and the
    ///      only one that may ever add liquidity to it. Everything it was constructed against is re-checked.
    function _preflightLock(GL memory g, address me) internal view {
        QpullLiquidityLock lock = QpullLiquidityLock(g.lock);
        require(
            QpullTaxHook(g.hook).initializer() == g.lock,
            "go-live: hook.initializer is not LOCK (wrong lock, or wrong hook)"
        );
        require(lock.opener() == me, "go-live: sender is not the lock's opener (use --account / --sender)");
        require(lock.hook() == g.hook, "go-live: lock.hook != HOOK");
        require(lock.qpull() == g.qpull && lock.weth() == g.weth, "go-live: lock is bound to a different pair");
        require(address(lock.poolManager()) == g.poolManager, "go-live: lock.poolManager != POOL_MANAGER");
        require(lock.fee() == g.fee && lock.tickSpacing() == g.tickSpacing, "go-live: lock key != hook key");
    }

    /// @dev The canonical QPULL/WETH key: address-sorted currencies + the hook's fee/tickSpacing + the hook.
    function _canonicalKey(GL memory g) internal view returns (PoolKey memory key) {
        (address c0, address c1) = g.qpull < g.weth ? (g.qpull, g.weth) : (g.weth, g.qpull); // V4: currency0 < currency1
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: g.fee,
            tickSpacing: g.tickSpacing,
            hooks: g.hook
        });
        require(QpullTaxHook(g.hook).isCanonical(key), "go-live: key is not the hook's canonical pool");
    }

    function _goLive(GL memory g, PoolKey memory key, address me) internal returns (QpullLiquidityLock lock) {
        return _seedAndMaybeLock(g, key, me, true);
    }

    /// @dev Steps 1-5, then step 6 when `lockAfter`. `lockAfter == false` is the recovery of a broadcast whose
    ///      lockRouting landed while lock.seed failed: routing is already frozen (and _requireDeclaredRouting proved
    ///      it is the declared six), so only the seed is missing.
    function _seedAndMaybeLock(GL memory g, PoolKey memory key, address me, bool lockAfter)
        internal
        returns (QpullLiquidityLock lock)
    {
        Treasury t = Treasury(g.treasury);
        lock = QpullLiquidityLock(g.lock); // deployed by Deploy.s.sol; it IS the hook's initializer

        uint256 supply = IERC20(g.qpull).totalSupply(); // preflight: all of it is in the deployer + the lock
        _size(g, lock, supply); // writes g.sqrtPriceX96 and g.liq

        vm.startBroadcast();
        // 1. ARM THE CONVERT CAPS. Idempotent, so a re-run repeats it harmlessly.
        t.setMaxConvertPerCall(g.maxConvertPerCall);
        t.setMaxWethConvertPerCall(g.maxWethConvertPerCall);
        // 2. PULL THE LP BUCKET (exact-anchor mode) and FUND THE LOCK, shortfall only. withdrawProceeds is
        //    permissionless and pays the frozen lpTreasury (this key), so a stranger calling it first only makes
        //    this call a no-op; the ETH still arrives here. The pool does NOT exist yet: seed() creates it.
        if (g.withdrawLp) INftLaunchLedger(g.nft).withdrawProceeds();
        _fund(g, address(lock), me);
        // 3. CREATE THE POOL AND SEED IT, ATOMICALLY. The declared amounts are LP_ETH_WEI and totalSupply, which the
        //    lock now holds at least (a WETH donation above LP_ETH_WEI is not declared, so it is never seeded).
        lock.seed(g.sqrtPriceX96, g.liq, supply, g.lpEth);
        vm.stopBroadcast();

        // 4. ON-CHAIN ASSERTS against the post-seed state (any failure = no broadcast).
        _assertSeeded(g, key, lock, g.liq);
        // The deployer holds NO QPULL: 100% of supply left it for the no-remove lock. Checked here, in the same
        // simulation as the funding, and deliberately NOT in _resume: once the pool is live anyone can send the
        // deployer 1 wei of QPULL, and the seeded position (asserted above) is the proof of the seed anyway.
        require(IERC20(g.qpull).balanceOf(me) == 0, "go-live: QPULL not 100% seeded to the lock");
        // 5. REHEARSE convert() against the post-seed state, WETH leg and then both legs. Simulation only.
        _rehearseConvert(g);
        _rehearseQpullLeg(g);

        // 6. LOCK ROUTING - LAST.
        if (lockAfter) {
            vm.startBroadcast();
            t.lockRouting(
                g.qpullWethAdapter, g.wethQuotronAdapter, g.prizeVault, g.holderVault, g.leaderboardVault, g.team
            );
            vm.stopBroadcast();
        }

        require(t.routingLocked(), "go-live: routing not locked");
    }

    /// @dev Top the lock up to at least LP_ETH_WEI of WETH and 100% of supply. Reads what it already holds so a
    ///      re-run after an interrupted broadcast funds only the difference. A stranger's WETH donation
    ///      only reduces what the deployer sends, and a donation beyond LP_ETH_WEI is never seeded: seed() declares
    ///      LP_ETH_WEI and the pool charges exactly the derived liquidity, so the excess stays stranded in the lock
    ///      and is logged here (and again in _reportResiduals).
    ///      WETH the deployer already holds (a wrap from an interrupted run whose transfer never landed) is sent
    ///      first, and only the remainder is wrapped, so a re-run never wraps a second LP_ETH_WEI.
    function _fund(GL memory g, address lock, address me) internal {
        uint256 lockWeth = IERC20(g.weth).balanceOf(lock);
        uint256 shortfall = lockWeth >= g.lpEth ? 0 : g.lpEth - lockWeth;
        if (lockWeth != 0) {
            console2.log("  lock already held WETH before funding (earlier run or donation), wei", lockWeth);
            console2.log("  so this key funds only the shortfall, wei                            ", shortfall);
        }
        if (lockWeth > g.lpEth) {
            console2.log("  WARNING: WETH in the lock ABOVE LP_ETH_WEI is NOT seeded and strands, wei", lockWeth - g.lpEth);
        }
        if (shortfall > 0) {
            uint256 heldWeth = IERC20(g.weth).balanceOf(me);
            if (heldWeth < shortfall) IWETH(g.weth).deposit{ value: shortfall - heldWeth }(); // ETH -> real WETH
            require(IERC20(g.weth).transfer(lock, shortfall), "go-live: WETH transfer to lock failed");
        }
        uint256 myQpull = IERC20(g.qpull).balanceOf(me);
        if (myQpull > 0) require(IERC20(g.qpull).transfer(lock, myQpull), "go-live: QPULL transfer to lock failed");
    }

    /// @dev DERIVE the price and the liquidity from the exact amounts being seeded. Setting the price to the
    ///      ratio of the two sides is what makes BOTH consume fully. LpSizing does the currency sort.
    function _size(GL memory g, QpullLiquidityLock lock, uint256 qpullIn) internal view {
        (g.sqrtPriceX96, g.liq) =
            LpSizing.sizeFor(g.qpull, qpullIn, g.weth, g.lpEth, lock.tickLower(), lock.tickUpper());
        require(g.liq > 0, "go-live: derived liquidity is zero (LP_ETH_WEI too small against supply?)");
    }

    /// @dev The post-seed facts the "can't rug" + "bounded convert" guarantees rest on, checked on-chain. Nothing
    ///      here reads a balance a stranger can change, because _resume runs it against a live pool.
    function _assertSeeded(GL memory g, PoolKey memory key, QpullLiquidityLock lock, uint128 liq) internal view {
        IV4PoolManager pm = IV4PoolManager(g.poolManager);
        // (i) the one-shot latch fired
        require(lock.seeded(), "go-live: lock.seeded() != true");
        // (ii) the canonical position is OWNED BY THE LOCK. v4 keys positions by (owner, tickLower, tickUpper,
        //      salt) and only the owner can ever modify one, so a position of exactly `liq` under the lock's
        //      key IS the ownership proof. PoolId = keccak256(abi.encode(key)).
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        bytes32 posKey = Position.calculatePositionKey(address(lock), lock.tickLower(), lock.tickUpper(), bytes32(0));
        require(
            StateLibrary.getPositionLiquidity(pm, poolId, posKey) == liq,
            "go-live: canonical position is not owned by the lock"
        );
        // (iii) ...and it is the ONLY liquidity in the pool (full range is always in range).
        require(StateLibrary.getLiquidity(pm, poolId) == liq, "go-live: pool liquidity != the lock's position");
        // (iv) "deployer QPULL == 0" is asserted by _goLive itself, not here (see there).
        // (v) sizing is enforced inside QpullLiquidityLock.seed against what the pool charged, during the real
        //     broadcast; a leftover-balance assert here could be failed by any donor. `_report` prints leftover balances.
        // (vi) launch stamped, and both convert caps armed to real values.
        require(QpullTaxHook(g.hook).launchTime() != 0, "go-live: launchTime not stamped by initialize");
        Treasury t = Treasury(g.treasury);
        require(
            t.maxConvertPerCall() != 0 && t.maxConvertPerCall() != type(uint256).max,
            "go-live: maxConvertPerCall not armed"
        );
        require(
            t.maxWethConvertPerCall() != 0 && t.maxWethConvertPerCall() != type(uint256).max,
            "go-live: maxWethConvertPerCall not armed"
        );
    }

    /// @dev The live half of the QUOTRON-side external checks (see _preflightQuotron).
    ///      Structural checks prove the bindings AGREE; only running convert() proves they
    ///      WORK. So, against the post-seed state and before lockRouting: fund the Treasury with a little WETH,
    ///      call convert(1, 1) as the pinned keeper through the real adapter and the real router, and require
    ///      QUOTRON in all three vaults, WETH at the team address, nothing owed and nothing new left in the
    ///      adapter. Then the simulated state is reverted. Nothing in this function is broadcast (there is no
    ///      active broadcast, and prank/deal/snapshot are local to the simulation), so the real chain never sees
    ///      it; but a binding that cannot convert aborts the run before routing is frozen.
    ///
    ///      GRIEF-PROOF BY CONSTRUCTION. Every address this reads is public before go-live and anyone can send it
    ///      dust, and a check that dust can fail would block the launch forever on a CORRECT config (setTaxHook
    ///      is write-once, and a replacement adapter can be dusted again). So every check is a delta:
    ///        - the adapter's WETH and ETH must be UNCHANGED across convert(), not zero. WETH arrives by a plain
    ///          transfer, ETH through its open receive(), and it has no WETH sweep.
    ///        - minWethOut is 1, not 0. The QPULL leg is skipped when the Treasury holds less than the threshold
    ///          (every fresh go-live) and is exercised when it holds more (a donation, or a _resume after buys),
    ///          and QpullWethAdapter refuses minOut == 0, so 0 would let a threshold-sized QPULL donation to the
    ///          Treasury revert the rehearsal. The QPULL leg is fee-exempt and ungated in the hook, and a
    ///          threshold-sized slice (>= 1e18 QPULL, quoted >= 1e12 wei at the seed price by preflight) sells
    ///          for far more than 1 wei.
    function _rehearseConvert(GL memory g) internal {
        _rehearse(g, false);
    }

    /// @dev Leg 1: on a fresh go-live the Treasury holds no QPULL, so the rehearsal above
    ///      never reaches convert LEG 1, the QPULL -> WETH swap through the fee-exempt QpullWethAdapter that
    ///      lockRouting freezes and the hook names immutably. This one simulates a convertThreshold-sized QPULL
    ///      donation to the Treasury (moved out of the PoolManager's balance with a prank: after the seed that is
    ///      where the whole supply is), plus a WETH funding strictly below the per-call cap so leg 1 is not skipped
    ///      (Treasury.convert skips it while a full WETH slice is backed up; any WETH backlog is parked outside the
    ///      Treasury for the simulation), and requires the slice to leave the
    ///      Treasury through the adapter with nothing stranded in it. Exemption itself stays a structural check
    ///      (_requireDeclaredRouting: hook.exemptSender == QPULL_WETH_ADAPTER): a taxed leg 1 would send its fee to
    ///      this same Treasury, so balances cannot tell the two apart. Everything is reverted.
    function _rehearseQpullLeg(GL memory g) internal {
        _rehearse(g, true);
    }

    function _rehearse(GL memory g, bool withQpull) internal {
        Treasury t = Treasury(g.treasury);
        uint256 snap = vm.snapshotState();
        uint256 cap = t.maxWethConvertPerCall();
        // With leg 1 under test the Treasury's WETH must stay BELOW the cap, or convert() skips leg 1.
        // On a resume after live trading the Treasury already holds tax WETH, so park that backlog outside it for
        // the simulation; otherwise anyone buying enough to back up one WETH slice could fail this rehearsal on a
        // correct config.
        if (withQpull) {
            uint256 backlog = IERC20(g.weth).balanceOf(g.treasury);
            if (backlog != 0) {
                vm.prank(g.treasury);
                require(IERC20(g.weth).transfer(REHEARSAL_FUNDER, backlog), "go-live: rehearsal WETH parking failed");
            }
        }
        uint256 amt = withQpull ? cap / 2 : cap;
        if (amt > REHEARSAL_WETH) amt = REHEARSAL_WETH;
        if (amt > 0) {
            vm.deal(REHEARSAL_FUNDER, amt);
            vm.prank(REHEARSAL_FUNDER);
            IWETH(g.weth).deposit{ value: amt }();
            vm.prank(REHEARSAL_FUNDER);
            require(IERC20(g.weth).transfer(g.treasury, amt), "go-live: rehearsal WETH funding failed");
        }

        uint256 qpullSlice;
        uint256 qpull0;
        uint256 adapterQpull0;
        uint256 adapterWethLeg10;
        if (withQpull) {
            uint256 th = t.convertThreshold();
            uint256 held = IERC20(g.qpull).balanceOf(g.treasury);
            if (held < th) {
                require(
                    IERC20(g.qpull).balanceOf(g.poolManager) >= th - held,
                    "go-live: rehearsal cannot simulate a threshold QPULL donation (PoolManager QPULL < threshold)"
                );
                vm.prank(g.poolManager);
                require(IERC20(g.qpull).transfer(g.treasury, th - held), "go-live: rehearsal QPULL donation failed");
            }
            qpull0 = IERC20(g.qpull).balanceOf(g.treasury);
            qpullSlice = qpull0 > t.maxConvertPerCall() ? t.maxConvertPerCall() : qpull0;
            adapterQpull0 = IERC20(g.qpull).balanceOf(g.qpullWethAdapter);
            adapterWethLeg10 = IERC20(g.weth).balanceOf(g.qpullWethAdapter);
        }

        IERC20 q = IERC20(g.quotron);
        uint256 p0 = q.balanceOf(g.prizeVault);
        uint256 h0 = q.balanceOf(g.holderVault);
        uint256 l0 = q.balanceOf(g.leaderboardVault);
        uint256 team0 = IERC20(g.weth).balanceOf(g.team);
        uint256 adapterWeth0 = IERC20(g.weth).balanceOf(g.wethQuotronAdapter);
        uint256 adapterEth0 = g.wethQuotronAdapter.balance;

        vm.prank(g.keeper);
        t.convert(1, 1); // both floors non-zero: the adapters refuse 0, and a live QPULL leg must sell for >= 1 wei

        require(
            q.balanceOf(g.prizeVault) > p0 && q.balanceOf(g.holderVault) > h0 && q.balanceOf(g.leaderboardVault) > l0,
            "go-live: rehearsed convert() did not deliver QUOTRON to all three vaults"
        );
        require(IERC20(g.weth).balanceOf(g.team) > team0, "go-live: rehearsed convert() paid no team WETH");
        require(
            t.quotronOwed(g.prizeVault) == 0 && t.quotronOwed(g.holderVault) == 0
                && t.quotronOwed(g.leaderboardVault) == 0,
            "go-live: rehearsed convert() left a vault owed (QUOTRON refused a vault)"
        );
        require(
            IERC20(g.weth).balanceOf(g.wethQuotronAdapter) == adapterWeth0 && g.wethQuotronAdapter.balance == adapterEth0,
            "go-live: rehearsed convert() left WETH/ETH in the WETH->QUOTRON adapter"
        );
        if (withQpull) {
            require(
                IERC20(g.qpull).balanceOf(g.treasury) == qpull0 - qpullSlice,
                "go-live: rehearsed convert() did not sell the QPULL slice through leg 1 (QPULL->WETH adapter)"
            );
            require(
                IERC20(g.qpull).balanceOf(g.qpullWethAdapter) == adapterQpull0
                    && IERC20(g.weth).balanceOf(g.qpullWethAdapter) == adapterWethLeg10,
                "go-live: rehearsed convert() left QPULL/WETH in the QPULL->WETH adapter"
            );
        }
        vm.revertToState(snap);
    }

    /// @dev The body of GoLiveMainnetResume (see its notice). Internal so a test can drive it with the broadcaster
    ///      as tx.origin and no prank. Dispatches on the two on-chain latches; see the contract header for the table.
    function _resume(GL memory g, address me) internal {
        bool seeded = QpullLiquidityLock(g.lock).seeded();
        bool locked = Treasury(g.treasury).routingLocked();
        if (!seeded && !locked) {
            revert("go-live-resume: lock unseeded and routing unlocked: nothing past the seed landed, re-run GoLiveMainnet");
        }
        if (!seeded) {
            _resumeSeedIntoFrozenRouting(g, me);
        } else if (!locked) {
            _resumeLockRouting(g, me);
        } else {
            _verifyComplete(g, me);
        }
    }

    /// @dev STATE (seeded = false, routingLocked = true). Only a non-`--slow` broadcast produces it: lock.seed failed
    ///      and lockRouting still landed. Routing was frozen by the on-chain RoutingMismatch/AdapterMismatch check
    ///      against the SAME six declared bindings, which _requireDeclaredRouting re-reads here, so what is missing is
    ///      exactly steps 1-5. Every other go-live preflight still applies (_preflightUnseeded).
    function _resumeSeedIntoFrozenRouting(GL memory g, address me) internal {
        _preflightUnseeded(g, me);
        console2.log("GO-LIVE RESUME: routing is frozen but the lock is unseeded; seeding into the frozen routing.");
        PoolKey memory key = _canonicalKey(g);
        QpullLiquidityLock lock = _seedAndMaybeLock(g, key, me, false);
        _report(g, address(lock));
    }

    /// @dev STATE (seeded = true, routingLocked = true). Nothing to send: re-verify read-only and say so.
    function _verifyComplete(GL memory g, address me) internal view {
        QpullLiquidityLock lock = QpullLiquidityLock(g.lock);
        _preflightLock(g, me);
        _preflightHook(g);
        _requireDeclaredRouting(g);
        PoolKey memory key = _canonicalKey(g);
        uint128 liq = _lockPositionLiquidity(g, key, lock);
        require(liq > 0, "go-live-resume: the lock owns no liquidity in the canonical pool");
        _assertSeeded(g, key, lock, liq);
        console2.log("GO-LIVE already complete: lock seeded, routing frozen to the declared bindings. Nothing sent.");
        _noteUnwithdrawnBucket(g);
    }

    /// @dev A partial broadcast whose withdrawProceeds was lost but whose seed landed funded the lock from this key's own
    ///      ETH, so the mint's LP bucket is still in the NFT. withdrawProceeds is permissionless and pays it to this key.
    function _noteUnwithdrawnBucket(GL memory g) internal view {
        uint256 pendingLp = INftLaunchLedger(g.nft).lpReserve();
        if (pendingLp != 0) {
            console2.log("NOTE: the mint's LP bucket is still in the NFT (the seed was funded from this key), wei", pendingLp);
            console2.log("      NFTCollection.withdrawProceeds() (permissionless) pays it to this key.");
        }
    }

    function _lockPositionLiquidity(GL memory g, PoolKey memory key, QpullLiquidityLock lock)
        internal
        view
        returns (uint128)
    {
        bytes32 posKey = Position.calculatePositionKey(address(lock), lock.tickLower(), lock.tickUpper(), bytes32(0));
        return StateLibrary.getPositionLiquidity(
            IV4PoolManager(g.poolManager), PoolId.wrap(keccak256(abi.encode(key))), posKey
        );
    }

    /// @dev STATE (seeded = true, routingLocked = false): lockRouting failed or was never sent, or the cap setters
    ///      failed and lockRouting reverted NotConfigured. Re-arm the caps first (idempotent), then verify, rehearse
    ///      and lock.
    function _resumeLockRouting(GL memory g, address me) internal {
        QpullLiquidityLock lock = QpullLiquidityLock(g.lock);
        _preflightLock(g, me);
        _preflightHook(g);
        Treasury t = Treasury(g.treasury);
        require(t.owner() == me, "go-live-resume: sender is not the Treasury owner");
        _preflightRouting(g, me);
        _preflightEngines(g);
        _preflightQuotron(g);
        require(t.convertThreshold() != 0, "go-live-resume: Treasury.convertThreshold is 0");
        require(
            g.maxConvertPerCall != 0 && g.maxConvertPerCall != type(uint256).max,
            "go-live: MAX_CONVERT_PER_CALL must be a pool-sized value"
        );
        require(
            g.maxWethConvertPerCall != 0 && g.maxWethConvertPerCall != type(uint256).max,
            "go-live: MAX_WETH_CONVERT_PER_CALL must be a pool-sized value"
        );
        require(g.maxConvertPerCall >= t.convertThreshold(), "go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold");
        // Step 1 again: a partial broadcast whose cap setters failed left lockRouting reverting NotConfigured.
        vm.startBroadcast();
        t.setMaxConvertPerCall(g.maxConvertPerCall);
        t.setMaxWethConvertPerCall(g.maxWethConvertPerCall);
        vm.stopBroadcast();
        PoolKey memory key = _canonicalKey(g);
        uint128 liq = _lockPositionLiquidity(g, key, lock);
        require(liq > 0, "go-live-resume: the lock owns no liquidity in the canonical pool");
        // No "deployer QPULL == 0" here: the pool is live, so anyone can send this key 1 wei of QPULL and block
        // the recovery. The lock-owned position being the pool's whole liquidity is the proof of the seed.
        _assertSeeded(g, key, lock, liq);
        console2.log("  deployer QPULL now (informational; strangers can send it)", IERC20(g.qpull).balanceOf(me));
        _rehearseConvert(g);
        _rehearseQpullLeg(g);
        vm.startBroadcast();
        t.lockRouting(
            g.qpullWethAdapter, g.wethQuotronAdapter, g.prizeVault, g.holderVault, g.leaderboardVault, g.team
        );
        vm.stopBroadcast();
        require(t.routingLocked(), "go-live-resume: routing not locked");
        console2.log("GO-LIVE RESUME complete: bindings re-verified, convert rehearsed, routing locked.");
        _noteUnwithdrawnBucket(g);
    }

    /// @dev INTERNAL, not `this.report(...)`: Foundry 1.7 aborts a script that touches `address(this)` AFTER
    ///      the launch body, discarding the whole run and broadcasting nothing (verified 2026-09-11 against an
    ///      anvil fork of RH mainnet). The logging stays split for stack room.
    function _report(GL memory g, address lock) internal view {
        console2.log("GO-LIVE (mainnet) complete. Pool created BY the lock; 100% of supply seeded into it.");
        console2.log("  hook (initializer == the lock below)             ", g.hook);
        console2.log("  LIQUIDITY LOCK (owns the position, no remove path)", lock);
        _reportSizing(g);
        _reportResiduals(g, lock);
    }

    /// @dev The derived values and the human-readable launch price, next to the raw sqrtPriceX96.
    function _reportSizing(GL memory g) internal view {
        uint256 supply = IERC20(g.qpull).totalSupply();
        console2.log("  seeded WETH (wei), LP_ETH_WEI                    ", g.lpEth);
        console2.log("  of which declared top-up (wei), LP_TOPUP_WEI     ", g.lpTopUp);
        console2.log("  LP bucket anchor exact (withdrawn by this run)?  ", g.withdrawLp);
        console2.log("  mint LP bucket, on-chain low bound (wei)         ", g.lpBucketLo);
        console2.log("  mint LP bucket, on-chain high bound (wei)        ", g.lpBucketHi);
        console2.log("  launch price: WETH wei per 1 whole QPULL (1e18)  ", Math.mulDiv(g.lpEth, 1e18, supply));
        console2.log("  launch FDV in WETH wei (100% of supply is pooled)", g.lpEth);
        console2.log("  liquidity units (DERIVED, script/LpSizing.sol)   ", uint256(g.liq));
        console2.log("  sqrtPriceX96 (DERIVED, script/LpSizing.sol)      ", uint256(g.sqrtPriceX96));
    }

    function _reportResiduals(GL memory g, address lock) internal view {
        console2.log("  QPULL left in the lock (locked dust/donations, wei)", IERC20(g.qpull).balanceOf(lock));
        console2.log("  WETH left in the lock (locked dust/donations, wei) ", IERC20(g.weth).balanceOf(lock));
        console2.log("  Treasury.maxConvertPerCall                       ", g.maxConvertPerCall);
        console2.log("  Treasury.maxWethConvertPerCall                   ", g.maxWethConvertPerCall);
        console2.log("  Treasury.convertThreshold                        ", Treasury(g.treasury).convertThreshold());
        console2.log("  Treasury.routingLocked                           ", Treasury(g.treasury).routingLocked());
        console2.log("NOTE: the holder gate is now OPEN for GATE_DURATION() seconds:", QpullTaxHook(g.hook).GATE_DURATION());
        console2.log("NOTE: start the keeper; convert() is armed and routing is final.");
    }
}

/// @notice RECOVERY ONLY, for any GoLiveMainnet broadcast that stopped part-way. It reads the two on-chain latches
///         and takes the one scripted path for that state (see GoLiveMainnet's ATOMICITY AND RECOVERY table):
///           - seeded, routing unlocked: re-arm the caps, re-verify every binding GoLiveMainnet checks before freezing
///             (the lock, the hook, the six routing bindings, the keeper, the engine graph, the QUOTRON-side
///             externals), prove the seeded position is the lock's and the pool's whole liquidity, rehearse both
///             convert legs against the live state, then lock routing;
///           - unseeded, routing LOCKED (a non-`--slow` broadcast whose seed failed after lockRouting landed): prove
///             the frozen routing is the declared six, run the go-live preflight, fund the shortfall, seed, assert
///             and rehearse, and send no lockRouting;
///           - seeded, routing locked: verify read-only and send nothing;
///           - unseeded, routing unlocked: refuse (that is a plain GoLiveMainnet re-run).
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnetResume --rpc-url rh --account deployer
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnetResume --rpc-url rh --account deployer \
///             --broadcast --slow
contract GoLiveMainnetResume is GoLiveMainnet {
    function run() external override {
        _resume(_env(), msg.sender);
    }
}
