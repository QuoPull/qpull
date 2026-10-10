// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { QPULLToken } from "../src/QPULLToken.sol";
import { Treasury } from "../src/Treasury.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { LeaderboardEngine } from "../src/LeaderboardEngine.sol";
import { HolderDrawEngine } from "../src/HolderDrawEngine.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { QuotronRouterAdapter } from "../src/adapters/QuotronRouterAdapter.sol";
import { IPoolManager, PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";
import { HookMiner } from "./HookMiner.sol";
import { LaunchGuards } from "./LaunchGuards.sol";

/// @notice Deploys and wires the full QPULL protocol from .env config. Run from the deployer key:
///           forge script script/Deploy.s.sol --rpc-url rh --account deployer            (simulate)
///           forge script script/Deploy.s.sol --rpc-url rh --account deployer --broadcast
///
/// @dev  External addresses MUST come from the official Quotrons builders manifest (spec §9). On RH mainnet
///       (4663) QUOTRON, QUOTRON_ROUTER, WETH and POOL_MANAGER are also pinned in script/LaunchGuards.sol and
///       checked before anything is constructed.
///
///       Randomness: the time-locked quicknet BlsDrandOracle. It is NOT deployed here. DeployNFT.s.sol
///       already burned an oracle into NFTCollection as an immutable, so DRAND_ORACLE is REQUIRED and must be
///       exactly that oracle (an earlier "deploy a fresh BlsDrandOracle when unset" branch could
///       never pass the NFT-match require below, so it was dead and is gone). Deploy the oracle first:
///       `new BlsDrandOracle(1692803367, 3)`, then DeployNFT, then this.
///
///       PREREQUISITE: the NFT collection must already exist (DeployNFT.s.sol). The tax hook takes it as an
///       immutable (the 1-hour holder gate, GATE_DURATION()), and its mint funds the LP this launch seeds.
///
///       The 4% tax is a V4 hook: QpullTaxHook is CREATE2-deployed at a MINED address whose
///       low 14 bits encode its callbacks (REQUIRED_FLAGS 0x1ACC), and the canonical QPULL/WETH pool launches
///       WITH it. The hook's `initializer` is the QpullLiquidityLock deployed right after it (not a key): only
///       the lock may create the pool and only the lock may add liquidity. GO-LIVE is a SEPARATE, reviewed
///       script run from THIS deployer key, the lock's `opener` and the Treasury owner:
///         script/GoLiveMainnet.s.sol  (preflight -> arm convert caps -> fund the lock -> lock.seed creates
///         the pool and seeds it in one transaction -> on-chain asserts -> simulated convert() rehearsal ->
///         Treasury.lockRouting() LAST)
///       This deploy deliberately leaves convert() FAIL-CLOSED (both caps 0 => NotConfigured) and routing
///       UNLOCKED; GoLiveMainnet finishes both.
///
///       SITE SWAP ROUTER: src/periphery/QpullSwapRouter.sol, the contract web/index.html's swap
///       widget calls (taxed, exact-in buy/sell, ETH in and out, immutable, no owner), is deployed HERE, right after
///       the lock, and printed on its own line as `SWAP ROUTER (site buy/sell): 0x...` (script/wire-web.mjs reads
///       it). Here rather than in GoLiveMainnet because every input it binds (PoolManager, WETH, QPULL, the hook and
///       the canonical fee/tick spacing) is fixed by this run, and it needs no pool to exist: the site can then be
///       wired and checked (wire-web --check against this log) before go-live, and GoLiveMainnet's broadcast and
///       its partial-broadcast recovery table stay exactly as reviewed. Its constructor refuses any argument that
///       disagrees with the hook, and _postDeployBindings reads every binding back.
contract Deploy is Script {
    /// @notice Dust-QPULL convert grief: CONVERT_THRESHOLD is REQUIRED and at least one whole
    ///         QPULL. With a 0 threshold any QPULL donation, even 1 wei, forces convert()'s QPULL leg, which
    ///         swaps to 0 WETH and reverts in the adapter (minOut == 0), stalling convert() until the WETH
    ///         backlog reaches its cap. GoLiveMainnet then checks the threshold quotes well above 0 wei at the
    ///         seed price, which cannot be known here.
    uint256 internal constant MIN_CONVERT_THRESHOLD = 1e18;

    /// @notice Magnitude bounds on the two hand-typed ETH amounts, applied on Robinhood Chain
    ///         mainnet (4663) only. Both were checked only for being non-zero, so a 1000x slip passed every check: a wrong
    ///         ticket price takes 25 to 31 daily +/-25% re-pegs to walk back, and EARLY_BUY_CAP_WEI is a hook immutable
    ///         (a wrong cap is a redeploy). The bands are wide on purpose, about 1000x each, centred on the launch values
    ///         (0.003 ETH a ticket, 0.25 ETH a gated buy), so only unit slips are caught:
    ///           TICKET_PRICE_WETH  in [1e14, 1e17] wei  (0.0001 to 0.1 ETH per ticket)
    ///           EARLY_BUY_CAP_WEI  in [1e16, 5e18] wei  (0.01 to 5 ETH per gated buy)
    ///         OVERRIDE, deliberately explicit: set ACCEPT_TICKET_PRICE_WETH (or ACCEPT_EARLY_BUY_CAP_WEI) to EXACTLY the
    ///         out-of-band value. It then applies to that one value and cannot be left on for a different one by accident.
    uint256 internal constant MIN_TICKET_PRICE_WEI = 1e14;
    uint256 internal constant MAX_TICKET_PRICE_WEI = 1e17;
    uint256 internal constant MIN_EARLY_BUY_CAP_WEI = 1e16;
    uint256 internal constant MAX_EARLY_BUY_CAP_WEI = 5e18;

    struct Ext {
        address quotron;
        address weth;
        address poolManager; // V4 singleton (builders manifest)
        address quotronRouter; // Quotron Canonical ETH router (buyExactEth), the WETH->QUOTRON adapter's target
        address oracle; // REQUIRED: the quicknet BlsDrandOracle the NFT was built against
        address nft; // REQUIRED: hook gate + holder draw
        address team;
        address keeper; // REQUIRED: the convert() keeper (the CONVERT_PK address), never the deployer
        uint256 genesis; // REQUIRED: the planned go-live timestamp (unix seconds); every engine/registry clocks from it
        uint256 ticketPrice;
        uint256 revealDelay;
        uint256 winnersPerDay;
        uint256 capBps; // daily vault fraction, bps
        uint256 convertThreshold; // D18{QPULL}, >= MIN_CONVERT_THRESHOLD
        uint256 initialSupply;
        uint256 holderPotCap; // D18{QUOTRON} weekly holder-draw per-draw cap
        uint256 holderPotCeiling; // D18{QUOTRON} immutable ceiling on the holder-draw cap
        uint256 holderMinPot; // D18{QUOTRON} required (>0) dust floor, <= holderPotCap
        uint256 raffleMinPot; // D18{QUOTRON}
        uint256 leaderboardMinPot; // D18{QUOTRON}
        uint256 rafflePotCap; // D18{QUOTRON} bound a single day's payout
        uint256 leaderboardPotCap; // D18{QUOTRON} bound a single week's payout
        uint256 earlyBuyCapWei; // WETH wei per gated early buy (hook immutable)
        uint24 poolFee; // canonical QPULL/WETH pool LP fee (static)
        int24 poolTickSpacing;
        uint256 acceptTicketPrice; // ACCEPT_TICKET_PRICE_WETH, magnitude-band override (0 = none)
        uint256 acceptEarlyBuyCap; // ACCEPT_EARLY_BUY_CAP_WEI, magnitude-band override (0 = none)
    }

    struct Deployed {
        address oracle;
        address token;
        address treasury;
        address prizeVault;
        address leaderboardVault;
        address claimMgr;
        address packs;
        address leaderboardReg;
        address raffle;
        address leaderboardEng;
        address holderDrawVault;
        address holderDrawEngine;
        address qpullWethAdapter;
        address wethQuotronAdapter;
        address hook;
        address lock; // QpullLiquidityLock: the hook's initializer AND the only ever LP
        address swapRouter; // QpullSwapRouter: the site's taxed buy/sell
    }

    /// @dev The env seam. Production reads the process environment; test/DeployRun.t.sol overrides these to run the
    ///      REAL run() body in-process with per-test values (vm.setEnv is process-wide and tests run concurrently).
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envUint(string memory key) internal view virtual returns (uint256) {
        return vm.envUint(key);
    }

    function _envOrAddress(string memory key, address dflt) internal view virtual returns (address) {
        return vm.envOr(key, dflt);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view virtual returns (uint256) {
        return vm.envOr(key, dflt);
    }

    function _cfg() internal view returns (Ext memory e) {
        e.quotron = _envAddress("QUOTRON");
        e.weth = _envAddress("WETH");
        e.poolManager = _envOrAddress("POOL_MANAGER", LaunchGuards.RH_POOL_MANAGER);
        e.quotronRouter = _envAddress("QUOTRON_ROUTER"); // Quotron Canonical ETH router (RH mainnet 0x4202...1C18)
        e.oracle = _envAddress("DRAND_ORACLE"); // REQUIRED: = NFTCollection.drand()
        e.nft = _envAddress("NFT_ADDRESS"); // required: run DeployNFT first (hook immutable)
        e.team = _envAddress("TEAM_WALLET");
        // KEEPER used to default to the deployer, which TransferOwnership then always refuses.
        // It is the convert() keeper (the CONVERT_PK address) and it is required.
        e.keeper = _envAddress("KEEPER");
        // GENESIS is REQUIRED and range-checked in _preflight: unix SECONDS of the planned go-live.
        e.genesis = _envUint("GENESIS");
        // ticketPrice is the ETH-IN VALUE per ticket, in WETH wei. The hook credits
        // tickets off the WETH-in value and PackRegistry divides it by ticketPrice. Fail-closed (vm.envUint) so
        // an operator must set the launch value deliberately. e.g. 0.003 ether = ~$10.
        e.ticketPrice = _envUint("TICKET_PRICE_WETH");
        // ONE name for the reveal delay across DeployNFT, DeployTestnet and the keeper, and
        // required on the mainnet path (the default was silent on an immutable).
        e.revealDelay = _envUint("REVEAL_DELAY");
        // REQUIRED. Launch value is 10.
        e.winnersPerDay = _envUint("WINNERS_PER_DAY");
        // REQUIRED, no default. 1000 = 10%/day of the vault; RaffleEngine caps it at 5000.
        e.capBps = _envUint("RAFFLE_CAP_BPS");
        // REQUIRED and non-zero (dust-QPULL convert grief). Was envOr(..., 0).
        e.convertThreshold = _envUint("CONVERT_THRESHOLD");
        e.initialSupply = _envOrUint("INITIAL_SUPPLY", uint256(1_000_000_000e18));
        // Both were envOr(0), which failed later as BadPotCap deep inside construction.
        e.holderPotCap = _envUint("HOLDER_POT_CAP");
        e.holderPotCeiling = _envUint("HOLDER_POT_CEILING");
        // The QPULL/WETH canonical key, NOT the Quotron pool's key (which is dynamic-fee 0x800000
        // and would fail closed in the hook with BadFee). Same names keeper.js reads.
        e.poolFee = _u24(_envOrUint("QPULL_POOL_FEE", uint256(3000))); // 0.30%
        e.poolTickSpacing = _tickSpacing(_envOrUint("QPULL_POOL_TICK_SPACING", uint256(60)));
        // All three engine minPots and potCaps are REQUIRED (> 0) at construction; vm.envUint
        // fails the deploy closed if any is unset.
        e.holderMinPot = _envUint("HOLDER_MIN_POT");
        e.raffleMinPot = _envUint("RAFFLE_MIN_POT");
        e.leaderboardMinPot = _envUint("LEADERBOARD_MIN_POT");
        e.rafflePotCap = _envUint("RAFFLE_POT_CAP");
        e.leaderboardPotCap = _envUint("LEADERBOARD_POT_CAP");
        // The launch anti-sniper cap was hardcoded to 0.25 ether here while testnet read an env,
        // so an env value was silently ignored on the path that matters. A FIXED AMOUNT OF ETH, immutable on
        // the hook: RE-CHECK IT AGAINST THE ETH PRICE IMMEDIATELY BEFORE DEPLOYING. Logged below.
        e.earlyBuyCapWei = _envUint("EARLY_BUY_CAP_WEI");
        // The explicit out-of-band overrides (see MIN_TICKET_PRICE_WEI). Unset = the bands apply on 4663.
        e.acceptTicketPrice = _envOrUint("ACCEPT_TICKET_PRICE_WETH", 0);
        e.acceptEarlyBuyCap = _envOrUint("ACCEPT_EARLY_BUY_CAP_WEI", 0);
    }

    function _u24(uint256 v) internal pure returns (uint24) {
        // the hook refuses fee > 1_000_000 (BadFee); refuse the truncating cast before it
        require(v <= 1_000_000, "deploy: QPULL_POOL_FEE must be a static fee <= 1000000 (not the Quotron 0x800000)");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(v);
    }

    function _tickSpacing(uint256 v) internal pure returns (int24) {
        // v4 TickMath.MIN_TICK_SPACING / MAX_TICK_SPACING. Checked BEFORE the int24 cast: a bad value otherwise
        // only fails at go-live, after the mint and the write-once NFT hook binding.
        require(v >= 1 && v <= 32_767, "deploy: QPULL_POOL_TICK_SPACING must be in [1, 32767]");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(int256(v));
    }

    /// @dev Every check that needs only env and chain state, run in simulation before anything is constructed.
    function _preflight(Ext memory e, address me) internal view {
        // The QUOTRON-side externals are pinned on 4663 and must be real, mutually consistent contracts.
        LaunchGuards.requireExternals(e.quotron, e.quotronRouter, e.weth, e.poolManager);
        // The oracle is the real quicknet oracle, and it is the one the NFT was built against.
        // (Leaving it split would resolve PASS RARITY against the NFT's oracle and every DRAW against another,
        // silently and permanently. Found by rehearsing the launch against a mainnet fork, 2026-09-11.)
        require(e.nft != address(0) && e.nft.code.length > 0, "deploy: NFT_ADDRESS has no code");
        LaunchGuards.requireQuicknetOracle(e.oracle);
        require(
            address(NFTCollection(e.nft).drand()) == e.oracle,
            "deploy: DRAND_ORACLE != the oracle the NFT was built against -- set it to NFTCollection.drand()"
        );
        // GENESIS feeds five immutable clocks.
        LaunchGuards.requireDeployGenesis(e.genesis, NFTCollection(e.nft).revealBoundAt());
        // Dust-QPULL convert grief (see MIN_CONVERT_THRESHOLD).
        require(
            e.convertThreshold >= MIN_CONVERT_THRESHOLD,
            "deploy: CONVERT_THRESHOLD must be >= 1e18 QPULL (dust-QPULL convert grief)"
        );
        // TransferOwnership refuses a deployer keeper, so refuse it at the source.
        require(e.keeper != me, "deploy: KEEPER must be the convert keeper, not the deployer");
        require(e.earlyBuyCapWei > 0, "deploy: EARLY_BUY_CAP_WEI must be > 0");
        // Magnitude bands on 4663, then print both amounts side by side for the read-back.
        _preflightEthAmounts(e);
    }

    /// @dev See MIN_TICKET_PRICE_WEI for the bands and the override rule.
    function _preflightEthAmounts(Ext memory e) internal view {
        if (block.chainid == LaunchGuards.RH_MAINNET) {
            if (e.ticketPrice < MIN_TICKET_PRICE_WEI || e.ticketPrice > MAX_TICKET_PRICE_WEI) {
                require(
                    e.acceptTicketPrice != 0 && e.acceptTicketPrice == e.ticketPrice,
                    "deploy: TICKET_PRICE_WETH is outside [1e14, 1e17] wei on 4663 (a unit slip?); to launch with it anyway set ACCEPT_TICKET_PRICE_WETH to exactly that value"
                );
                console2.log("WARNING: TICKET_PRICE_WETH is outside [1e14, 1e17] wei, accepted by ACCEPT_TICKET_PRICE_WETH");
            }
            if (e.earlyBuyCapWei < MIN_EARLY_BUY_CAP_WEI || e.earlyBuyCapWei > MAX_EARLY_BUY_CAP_WEI) {
                require(
                    e.acceptEarlyBuyCap != 0 && e.acceptEarlyBuyCap == e.earlyBuyCapWei,
                    "deploy: EARLY_BUY_CAP_WEI is outside [1e16, 5e18] wei on 4663 (a unit slip?); to launch with it anyway set ACCEPT_EARLY_BUY_CAP_WEI to exactly that value"
                );
                console2.log("WARNING: EARLY_BUY_CAP_WEI is outside [1e16, 5e18] wei, accepted by ACCEPT_EARLY_BUY_CAP_WEI");
            }
        }
        console2.log("TICKET_PRICE_WETH (wei of ETH-in per ticket)  ", e.ticketPrice);
        console2.log("EARLY_BUY_CAP_WEI (wei per gated launch buy)  ", e.earlyBuyCapWei);
    }

    function _deploy(Ext memory e, address me) internal returns (Deployed memory d) {
        d.oracle = e.oracle;
        d.token = address(new QPULLToken(e.initialSupply, me)); // clean ownerless ERC-20
        d.treasury = address(new Treasury(d.token, e.weth, e.quotron, me));
        d.prizeVault = address(new BaseVault(e.quotron, me));
        d.leaderboardVault = address(new BaseVault(e.quotron, me));
        d.claimMgr = address(new ClaimManager(me));
        d.packs = address(new PackRegistry(d.oracle, e.ticketPrice, e.genesis, e.revealDelay, me));
        d.leaderboardReg = address(new LeaderboardRegistry(e.genesis, me));
        d.raffle = address(
            new RaffleEngine(
                d.oracle,
                d.packs,
                d.prizeVault,
                d.claimMgr,
                e.genesis,
                e.winnersPerDay,
                e.raffleMinPot,
                e.rafflePotCap,
                e.capBps, // daily vault fraction (REQUIRED, no default)
                me
            )
        );
        d.leaderboardEng = address(
            new LeaderboardEngine(
                d.leaderboardReg,
                d.leaderboardVault,
                d.claimMgr,
                e.genesis,
                e.leaderboardMinPot,
                e.leaderboardPotCap,
                me
            )
        );

        // Weekly NFT-holder draw (5 tokenId slots, even split, drand-BLS time-locked). Its vault is FUNDED by the
        // 6.25% holder tax share (Treasury routes it here on every convert()). Left UNSEEDED at launch.
        d.holderDrawVault = address(new BaseVault(e.quotron, me));
        d.holderDrawEngine = address(
            new HolderDrawEngine(
                d.oracle,
                e.nft,
                d.holderDrawVault,
                d.claimMgr,
                e.genesis,
                e.holderPotCap,
                e.holderPotCeiling,
                e.holderMinPot,
                me
            )
        );

        // The Treasury's QPULL→WETH conversion adapter — deployed here because it binds the fresh token,
        // and because the hook must name it as the fee-exempt sender (an immutable) at construction.
        d.qpullWethAdapter = address(new QpullWethAdapter(e.poolManager, d.token, e.weth, me));

        // The Treasury's WETH->QUOTRON conversion adapter — buys QUOTRON from Quotron's canonical
        // QUOTRON/WETH v4 pool via their ETH router (buyExactEth).
        d.wethQuotronAdapter = address(new QuotronRouterAdapter(e.quotronRouter, e.weth, e.quotron, me));

        // The 4% tax hook. Its address must carry its callback flags in the low 14 bits, so
        // a CREATE2 salt is mined and the hook deployed through the deterministic CREATE2 deployer.
        //
        // The hook names the liquidity lock as its `initializer`, and the lock names the hook in its
        // constructor: a cycle. It is broken by predicting the lock's CREATE address, which depends only on
        // (deployer, nonce). The very next transaction from `me` is the hook's CREATE2-factory call (nonce
        // n), so the lock's own CREATE lands on nonce n+1. Both deployments are in this one function, in
        // this order, for exactly that reason — do not insert a transaction between them.
        address predictedLock = vm.computeCreateAddress(me, vm.getNonce(me) + 1);

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: e.poolManager,
            qpull: d.token,
            weth: e.weth,
            fee: e.poolFee,
            tickSpacing: e.poolTickSpacing,
            treasury: d.treasury,
            packRegistry: d.packs,
            leaderboardRegistry: d.leaderboardReg,
            nft: e.nft,
            exemptSender: d.qpullWethAdapter,
            // Against the empty-pool price walk: the initializer is the LIQUIDITY LOCK, not a
            // key. Only that contract may create the canonical pool, and only it may add liquidity — and it
            // does both in ONE transaction (QpullLiquidityLock.seed), so no block ever exists in which the
            // pool has a price and no liquidity for a stranger to walk for free. The lock does not exist yet,
            // so its address is PREDICTED here; the require after its deployment proves the prediction, in
            // simulation, before anything is broadcast.
            initializer: predictedLock,
            // Launch anti-sniper size cap (see e.earlyBuyCapWei). A FIXED AMOUNT OF ETH, never USD-tracking.
            earlyBuyCapWei: e.earlyBuyCapWei
        });
        // AFTER_INITIALIZE (12) | BEFORE_ADD_LIQUIDITY (11) | BEFORE_REMOVE_LIQUIDITY (9) | BEFORE_SWAP (7)
        //   | AFTER_SWAP (6) | BEFORE_SWAP_RETURNS_DELTA (3) | AFTER_SWAP_RETURNS_DELTA (2) = 0x1ACC. It must equal
        // QpullTaxHook.REQUIRED_FLAGS; the hook's constructor reverts (BadFlags) on any mismatch and the require
        // below re-reads the constant, so this cannot drift. Bits 7 and 3 let the hook charge the WETH fee on the
        // specified currency (exact-in buys, exact-out sells).
        uint160 flags = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
        (address mined, bytes32 salt) = HookMiner.find(
            HookMiner.CREATE2_DEPLOYER,
            flags,
            abi.encodePacked(type(QpullTaxHook).creationCode, abi.encode(hc))
        );
        d.hook = address(new QpullTaxHook{ salt: salt }(hc));
        require(d.hook == mined, "hook address mismatch: CREATE2 deployer differs from HookMiner's");
        require(
            uint160(d.hook) & HookMiner.FLAG_MASK == QpullTaxHook(d.hook).REQUIRED_FLAGS(),
            "hook address does not carry REQUIRED_FLAGS"
        );

        // THE PERMANENT LIQUIDITY LOCK — deployed here, immediately after the hook, because the hook is
        // immutable and has just been mined against this exact address. It must land at `predictedLock` or
        // the hook's initializer points at nothing and the pool could never be created: an unrecoverable
        // brick. The require below fails the SIMULATION, so a nonce that drifted costs a re-run, never a
        // broadcast. Keep them adjacent.
        d.lock = address(
            new QpullLiquidityLock(
                IPoolManager(e.poolManager), d.token, e.weth, e.poolFee, e.poolTickSpacing, d.hook, me
            )
        );
        require(d.lock == predictedLock, "lock address mismatch: hook.initializer would be a dead address");

        // THE SITE SWAP ROUTER. After the lock, never between the hook and the lock (the nonce
        // prediction above). Immutable and ownerless; the constructor checks each argument against the hook.
        d.swapRouter =
            address(new QpullSwapRouter(e.poolManager, e.weth, d.token, d.hook, e.poolFee, e.poolTickSpacing));
    }

    function _wire(Deployed memory d, Ext memory e) internal {
        // The hook is the sole recorder on both registries (the token no longer notifies anything).
        PackRegistry(d.packs).setRecorder(d.hook);
        LeaderboardRegistry(d.leaderboardReg).setRecorder(d.hook);
        NFTCollection(e.nft).setTaxHook(d.hook); // wire the launch transfer-lock (flag-on-buy, spec §16)

        PackRegistry(d.packs).setEngine(d.raffle);
        PackRegistry(d.packs).setNft(e.nft);
        // rip-XP: PackRegistry.claimRipXp -> LeaderboardRegistry.recordXp (both bindings write-once)
        PackRegistry(d.packs).setLeaderboard(d.leaderboardReg);
        LeaderboardRegistry(d.leaderboardReg).setXpRecorder(d.packs);

        BaseVault(d.prizeVault).setController(d.claimMgr);
        BaseVault(d.leaderboardVault).setController(d.claimMgr);
        BaseVault(d.holderDrawVault).setController(d.claimMgr);

        // Each engine is bound to the ONE vault it may register claims against.
        ClaimManager(d.claimMgr).setEngine(d.raffle, d.prizeVault);
        ClaimManager(d.claimMgr).setEngine(d.leaderboardEng, d.leaderboardVault);
        ClaimManager(d.claimMgr).setEngine(d.holderDrawEngine, d.holderDrawVault);
        // Freeze the engine<->vault bindings forever. Pass the exact expected (engine, vault) pairs so a lock
        // issued before wiring is complete reverts, not bricks.
        address[] memory engs = new address[](3);
        address[] memory vlts = new address[](3);
        engs[0] = d.raffle;
        vlts[0] = d.prizeVault;
        engs[1] = d.leaderboardEng;
        vlts[1] = d.leaderboardVault;
        engs[2] = d.holderDrawEngine;
        vlts[2] = d.holderDrawVault;
        ClaimManager(d.claimMgr).lockEngines(engs, vlts);

        // HolderDrawEngine has no registry to anchor its genesis; assert it matches the
        // shared launch genesis so a mis-typed value can't silently desync its weekly schedule.
        require(
            HolderDrawEngine(d.holderDrawEngine).genesis() == RaffleEngine(d.raffle).genesis(),
            "holder-draw genesis mismatch"
        );

        // On MAINNET the cohort tier rounds and the daily draw rounds must coincide, which
        // holds exactly when PackRegistry.revealDelay() == RaffleEngine.revealLag(). That equality is what makes
        // the documented "one beacon a day" operating model correct; split them and every draw needs a second
        // round posted, and a keeper following that one-beacon model would leave every runDraw reverting
        // RevealPending. It is asserted HERE, not in the engine's constructor, because the short-clock testnet
        // pair deliberately runs unequal values (1 minute against 2) and settles fine with a keeper that posts
        // every round it computes. Mainnet has no such keeper allowance documented, so it fails the deploy.
        require(
            PackRegistry(d.packs).revealDelay() == RaffleEngine(d.raffle).revealLag(),
            "REVEAL_DELAY must equal the raffle engine's reveal lag (1 hour) on mainnet"
        );

        Treasury(d.treasury).setAdapters(d.qpullWethAdapter, d.wethQuotronAdapter);
        // The 6.25% holder tax share routes to the holder-draw vault (the SAME BaseVault HolderDrawEngine
        // draws from).
        Treasury(d.treasury).setRouting(d.prizeVault, d.holderDrawVault, d.leaderboardVault, e.team);
        // lockRouting() is deliberately NOT called here: it is the FINAL step of script/GoLiveMainnet.s.sol,
        // after the pool is seeded, the bindings are re-verified and a convert() has been rehearsed against
        // the seeded state. The keeper stays rotatable either way.
        Treasury(d.treasury).setConvertThreshold(e.convertThreshold);
        Treasury(d.treasury).setKeeper(e.keeper, true); // convert() is keeper-gated

        // Bind the adapter to the canonical hooked pool. setPoolKey verifies on-chain that the hook
        // names this adapter as its fee-exempt sender and matches fee/tickSpacing/PoolManager.
        QpullWethAdapter(d.qpullWethAdapter).setTreasury(d.treasury);
        QpullWethAdapter(d.qpullWethAdapter).setPoolKey(_canonicalKey(d, e));

        // Authorize the Treasury as the sole caller of the WETH->QUOTRON adapter (write-once).
        QuotronRouterAdapter(payable(d.wethQuotronAdapter)).setTreasury(d.treasury);
    }

    /// @dev The external-address checks, mirrored after construction:
    ///      every immutable that names QUOTRON names the SAME contract the
    ///      router's pool pays out, and the WETH-side adapter targets the router that was checked.
    function _postDeployBindings(Deployed memory d, Ext memory e) internal view {
        require(address(Treasury(d.treasury).quotron()) == e.quotron, "deploy: Treasury.quotron != QUOTRON");
        require(address(BaseVault(d.prizeVault).quotron()) == e.quotron, "deploy: prizeVault.quotron != QUOTRON");
        require(
            address(BaseVault(d.holderDrawVault).quotron()) == e.quotron, "deploy: holderDrawVault.quotron != QUOTRON"
        );
        require(
            address(BaseVault(d.leaderboardVault).quotron()) == e.quotron,
            "deploy: leaderboardVault.quotron != QUOTRON"
        );
        QuotronRouterAdapter a = QuotronRouterAdapter(payable(d.wethQuotronAdapter));
        require(a.quotron() == e.quotron && a.weth() == e.weth, "deploy: WETH->QUOTRON adapter pair mismatch");
        require(address(a.router()) == e.quotronRouter, "deploy: WETH->QUOTRON adapter router != QUOTRON_ROUTER");
        require(a.treasury() == d.treasury, "deploy: WETH->QUOTRON adapter treasury != Treasury");
        require(QpullWethAdapter(d.qpullWethAdapter).treasury() == d.treasury, "deploy: QPULL->WETH treasury");
        // The site swap router trades exactly the canonical pool, and is taxed.
        QpullSwapRouter r = QpullSwapRouter(payable(d.swapRouter));
        require(
            address(r.poolManager()) == e.poolManager && r.weth() == e.weth && r.qpull() == d.token,
            "deploy: swap router PoolManager/WETH/QPULL != this deploy"
        );
        require(
            r.hook() == d.hook && r.fee() == e.poolFee && r.tickSpacing() == e.poolTickSpacing,
            "deploy: swap router hook/fee/tickSpacing != the canonical key"
        );
        require(r.wethIsCurrency0() == (e.weth < d.token), "deploy: swap router currency order");
        require(QpullTaxHook(d.hook).isCanonical(r.poolKey()), "deploy: swap router key is not the hook's canonical pool");
        require(
            QpullTaxHook(d.hook).exemptSender() != d.swapRouter,
            "deploy: swap router is the hook's exemptSender (site swaps would be untaxed)"
        );
    }

    function _canonicalKey(Deployed memory d, Ext memory e) internal pure returns (PoolKey memory k) {
        (address lo, address hi) = d.token < e.weth ? (d.token, e.weth) : (e.weth, d.token);
        k = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: e.poolFee,
            tickSpacing: e.poolTickSpacing,
            hooks: d.hook
        });
    }

    function run() external {
        _run(msg.sender);
    }

    /// @dev The whole run() body. Internal so test/DeployRun.t.sol can execute it with the broadcaster as
    ///      msg.sender/tx.origin (an external `this.run()` would make the test contract the sender and break the
    ///      lock's nonce prediction).
    function _run(address me) internal returns (Deployed memory d) {
        Ext memory e = _cfg();
        _preflight(e, me);
        vm.startBroadcast();
        d = _deploy(e, me);
        _wire(d, e);
        vm.stopBroadcast();
        _postDeployBindings(d, e);
        _log(d, e);
    }

    function _log(Deployed memory d, Ext memory e) internal view {
        console2.log("oracle            ", d.oracle);
        console2.log("QPULLToken        ", d.token);
        console2.log("Treasury          ", d.treasury);
        console2.log("PrizeVault        ", d.prizeVault);
        console2.log("LeaderboardVault  ", d.leaderboardVault);
        console2.log("ClaimManager      ", d.claimMgr);
        console2.log("PackRegistry      ", d.packs);
        console2.log("LeaderboardReg    ", d.leaderboardReg);
        console2.log("RaffleEngine      ", d.raffle);
        console2.log("LeaderboardEngine ", d.leaderboardEng);
        console2.log("HolderDrawVault   ", d.holderDrawVault);
        console2.log("HolderDrawEngine  ", d.holderDrawEngine);
        console2.log("QpullWethAdapter  ", d.qpullWethAdapter);
        console2.log("WethQuotronAdapter", d.wethQuotronAdapter);
        console2.log("QpullTaxHook      ", d.hook);
        // REQUIRED go-live input (LOCK=). It is the hook's immutable `initializer`, so this pairing is fixed
        // forever: no other lock can ever create or seed the canonical pool.
        console2.log("LiquidityLock     ", d.lock);
        // The site's buy/sell contract, on its own line in exactly this form (script/wire-web.mjs and
        // tools/check-web-wiring.mjs match the phrase).
        console2.log("SWAP ROUTER (site buy/sell):", d.swapRouter);
        console2.log("PackRegistry.ticketPrice (WETH wei)      ", PackRegistry(d.packs).ticketPrice());
        console2.log("hook.earlyBuyCapWei (immutable, WETH wei)", QpullTaxHook(d.hook).earlyBuyCapWei());
        console2.log("Treasury.convertThreshold (QPULL wei)    ", e.convertThreshold);
        console2.log("GENESIS (unix seconds)                   ", e.genesis);
        _logExports(d, e);
        console2.log("Deploy leaves convert() FAIL-CLOSED (both caps 0 => NotConfigured) and routing UNLOCKED.");
        console2.log("ORDER: NFTCollection.finalizeLaunch() -> Deploy.s.sol (this) -> GoLiveMainnet.s.sol.");
        console2.log("NEXT: script/GoLiveMainnet.s.sol from THIS key with the exports above plus LP_ETH_WEI,");
        console2.log("      MAX_CONVERT_PER_CALL and MAX_WETH_CONVERT_PER_CALL. Do NOT call withdrawProceeds()");
        console2.log("      first: GoLiveMainnet anchors LP_ETH_WEI to nft.lpReserve() EXACTLY and withdraws it");
        console2.log("      itself (after an early withdraw the anchor is only a bound). It preflights every");
        console2.log("      binding, seeds through the lock, rehearses a convert() and only then locks routing.");
    }

    /// @dev The exact env names GoLiveMainnet, TransferOwnership and keeper.js read, so nothing
    ///      downstream is retyped by hand.
    function _logExports(Deployed memory d, Ext memory e) internal pure {
        console2.log(string.concat("export POOL_MANAGER=", vm.toString(e.poolManager)));
        console2.log(string.concat("export WETH=", vm.toString(e.weth)));
        console2.log(string.concat("export QUOTRON=", vm.toString(e.quotron)));
        console2.log(string.concat("export QUOTRON_ROUTER=", vm.toString(e.quotronRouter)));
        console2.log(string.concat("export QPULL=", vm.toString(d.token)));
        console2.log(string.concat("export TREASURY=", vm.toString(d.treasury)));
        console2.log(string.concat("export HOOK=", vm.toString(d.hook)));
        console2.log(string.concat("export LOCK=", vm.toString(d.lock)));
        console2.log(string.concat("export PRIZE_VAULT=", vm.toString(d.prizeVault)));
        console2.log(string.concat("export HOLDER_VAULT=", vm.toString(d.holderDrawVault)));
        console2.log(string.concat("export LEADERBOARD_VAULT=", vm.toString(d.leaderboardVault)));
        console2.log(string.concat("export TEAM_WALLET=", vm.toString(e.team)));
        console2.log(string.concat("export QPULL_WETH_ADAPTER=", vm.toString(d.qpullWethAdapter)));
        console2.log(string.concat("export WETH_QUOTRON_ADAPTER=", vm.toString(d.wethQuotronAdapter)));
        console2.log(string.concat("export KEEPER=", vm.toString(e.keeper)));
        console2.log(string.concat("export LEADERBOARD_ENGINE=", vm.toString(d.leaderboardEng)));
        console2.log(string.concat("export HOLDER_ENGINE=", vm.toString(d.holderDrawEngine)));
        console2.log(string.concat("export RAFFLE_ENGINE=", vm.toString(d.raffle)));
        console2.log(string.concat("export PACK_REGISTRY=", vm.toString(d.packs)));
        console2.log(string.concat("export LEADERBOARD_REG=", vm.toString(d.leaderboardReg)));
        console2.log(string.concat("export CLAIM_MANAGER=", vm.toString(d.claimMgr)));
        console2.log(string.concat("export ORACLE=", vm.toString(d.oracle)));
        console2.log(string.concat("export QPULL_POOL_HOOK=", vm.toString(d.hook)));
    }
}
