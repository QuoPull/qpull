// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";
import { LpSizing } from "./LpSizing.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { Treasury } from "../src/Treasury.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

// The throwaway self-owned `LiquiditySeeder` that used to live here
// was DELETED. It seeded a position owned by the seeder/deployer, i.e. a REMOVABLE position (the hook's LP gate
// admits a remove via tx.origin == initializer), which is exactly the rug path QpullLiquidityLock exists to
// make impossible. Nothing in this go-live used it any more; every seed goes through the lock below. If a
// throwaway seeder is ever needed for a fork test, use test/fork/QpullWethPoolFork's V4LiquidityHelper.

/// @notice GO-LIVE (testnet, HELPER 1/3): create the canonical QPULL/WETH pool + seed liquidity, so the
///         "curve" exists for buying. RUN FROM THE DEPLOYER KEY — it is the LOCK'S `opener`, the only address
///         allowed to trigger the one-shot seed. The pool is created BY THE LOCK inside that same seed
///         transaction: the hook's `initializer` is the lock, and the `beforeAddLiquidity` gate is a plain
///         `sender == initializer` with no `tx.origin` branch.
///
/// @dev    Env (from the DeployTestnet output — see its printed `export` block):
///           POOL_MANAGER, QPULL_TOKEN, WETH, HOOK, TREASURY, LOCK  (required)
///           POOL_FEE (3000), POOL_TICK_SPACING (60)  (optional)
///           LP_ETH (0.5e18, ETH to wrap for the WETH side)  (optional)
///           LP_QPULL (10_000e18) — sizes the CONVERT CAP only; the seed always moves the whole balance
///           MAX_CONVERT_PER_CALL (= LP_QPULL), MAX_WETH_CONVERT_PER_CALL (= LP_ETH)  (optional; wei)
///         SQRT_PRICE and LP_LIQUIDITY ARE NO LONGER INPUTS — script/LpSizing.sol derives both from the
///         amounts being seeded. Their old defaults (1:1 price, 1e17 liquidity, 0.5 ETH and the entire supply
///         funded in) were mutually inconsistent by four orders of magnitude and nothing detected it.
///
///         CONVERT CAPS: Treasury.convert() is fail-CLOSED and reverts
///         NotConfigured until BOTH per-call caps are armed. DeployTestnet arms only PLACEHOLDER caps of 1 wei (its
///         in-deploy lockRouting requires both armed; convert() can move at most 1 wei per leg until go-live), and
///         leaves the pool-sized caps to go-live like Deploy.s.sol, so this script arms the real ones as its FIRST
///         step, exactly where GoLiveMainnet does (its step 1). Testnet defaults = the LP sizing itself, so the
///         caps are pool-sized by construction; lower them via env to exercise the slice-draining path.
///
///         ORDER NOTE vs MAINNET: DeployTestnet runs lockRouting() IN-DEPLOY and defaults GENESIS to deploy
///         time; GoLiveMainnet arms the caps first and runs lockRouting() LAST. That is acceptable on testnet
///         because the caps are deliberately NOT frozen by lockRouting (they are the owner-mutable keeper-MEV
///         bound), so arming them here, after the testnet lock, is valid.
///
///         SITE SWAP ROUTER: after the seed this deploys src/periphery/QpullSwapRouter.sol, the
///         SAME contract Deploy.s.sol deploys on mainnet (taxed, exact-in buy/sell, ETH in and out, immutable, no
///         owner; its constructor refuses any argument that disagrees with the hook), and prints it on its own line
///         as `SWAP ROUTER (site buy/sell): 0x...`, which script/wire-web.mjs reads.
///
///         CONVERT THRESHOLD FLOOR (mirrors GoLiveMainnet._preflightConvertThreshold): a convertThreshold-sized QPULL
///         sell must quote at least 1e12 wei at the seed price (threshold * LP_ETH / supply). At the 0.5 ETH default
///         LP and a 1e27 supply that needs a threshold of at least 2,000 QPULL; DeployTestnet's default is 10,000.
contract GoLiveTestnet is Script {
    /// @notice Same floor GoLiveMainnet enforces (dust-QPULL convert grief): a threshold-sized sell quotes >= 1e12 wei.
    uint256 internal constant MIN_THRESHOLD_QUOTE_WEI = 1e12;

    // Env packed into a struct so run() stays under the stack-too-deep limit.
    struct GL {
        address poolManager;
        address qpull;
        address weth;
        address hook;
        address lock; // QpullLiquidityLock, deployed by DeployTestnet as the hook's initializer
        address treasury;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPrice; // DERIVED (LpSizing), not env
        uint256 lpEth;
        uint256 lpQpull;
        uint128 liq;
        uint256 maxConvertPerCall; // QPULL ceiling per convert(); testnet default = lpQpull
        uint256 maxWethConvertPerCall; // WETH ceiling per convert(); testnet default = lpEth
    }

    function run() external {
        // Testnet-only (it sizes from testnet defaults and arms caps in a testnet order). Mainnet is
        // GoLiveMainnet.s.sol; the site swap router it deploys is the same QpullSwapRouter Deploy.s.sol deploys.
        require(block.chainid != 4663, "GoLiveTestnet is testnet-only; mainnet (4663) uses GoLiveMainnet.s.sol");
        GL memory g = _env();
        // No PoolKey is built here any more: the lock owns the canonical key (lock.poolKey()) and creates the
        // pool itself inside seed(). This script never touches poolManager.initialize.
        (address lock, address router) = _goLive(g);
        _report(g, lock, router);
    }

    /// @dev The env seam. Production reads the process environment; test/GoLiveTestnetRouter.t.sol overrides these
    ///      (vm.setEnv is process-wide and tests run concurrently).
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view virtual returns (uint256) {
        return vm.envOr(key, dflt);
    }

    function _env() internal view returns (GL memory g) {
        g.poolManager = _envAddress("POOL_MANAGER");
        g.qpull = _envAddress("QPULL_TOKEN");
        g.weth = _envAddress("WETH");
        g.hook = _envAddress("HOOK");
        g.lock = _envAddress("LOCK"); // printed by DeployTestnet
        g.treasury = _envAddress("TREASURY"); // required: the caps must be armed or convert() is bricked
        g.fee = uint24(_envOrUint("POOL_FEE", uint256(3000)));
        g.tickSpacing = int24(int256(_envOrUint("POOL_TICK_SPACING", uint256(60))));
        g.lpEth = _envOrUint("LP_ETH", uint256(0.5 ether));
        // LP_QPULL now sizes only the CONVERT CAP, not the seed: the seed always moves the deployer's whole
        // balance. SQRT_PRICE and LP_LIQUIDITY are gone as inputs -- both are derived from the amounts being
        // seeded (script/LpSizing.sol). The old defaults (1:1 price, 1e17 liquidity, 0.5 ETH and the entire
        // supply funded in) were mutually inconsistent by four orders of magnitude, which nothing detected
        // while the seed silently stranded the difference.
        g.lpQpull = _envOrUint("LP_QPULL", uint256(10_000e18));
        // Pool-sized by construction: default each cap to the matching side of the LP seed (see header).
        g.maxConvertPerCall = _envOrUint("MAX_CONVERT_PER_CALL", g.lpQpull);
        g.maxWethConvertPerCall = _envOrUint("MAX_WETH_CONVERT_PER_CALL", g.lpEth);
        // Same bound GoLiveMainnet enforces: never 0 (the setter rejects it) and never the old fail-open max.
        require(
            g.maxConvertPerCall != 0 && g.maxConvertPerCall != type(uint256).max,
            "go-live: MAX_CONVERT_PER_CALL must be a pool-sized value"
        );
        require(
            g.maxWethConvertPerCall != 0 && g.maxWethConvertPerCall != type(uint256).max,
            "go-live: MAX_WETH_CONVERT_PER_CALL must be a pool-sized value"
        );
    }

    function _goLive(GL memory g) internal returns (address lockAddr, address router) {
        address me = msg.sender; // the deployer = THE LOCK'S OPENER (the hook's initializer is the lock itself)
        Treasury t = Treasury(g.treasury);
        require(t.owner() == me, "go-live: sender is not the Treasury owner (caps are onlyOwner)");

        // The hook is immutable and was mined against the lock's address; if these disagree the pool can
        // never be created, so fail here rather than five transactions in.
        QpullLiquidityLock lock = QpullLiquidityLock(g.lock);
        require(QpullTaxHook(g.hook).initializer() == g.lock, "go-live: hook.initializer != LOCK");
        require(lock.opener() == me, "go-live: sender is not the lock's opener");
        require(!lock.seeded(), "go-live: the lock has already been seeded");

        // DERIVE the price and the liquidity from the amounts actually being seeded (script/LpSizing.sol).
        uint256 qpullIn = IERC20(g.qpull).balanceOf(me);
        (g.sqrtPrice, g.liq) =
            LpSizing.sizeFor(g.qpull, qpullIn, g.weth, g.lpEth, lock.tickLower(), lock.tickUpper());
        require(g.liq > 0, "go-live: derived liquidity is zero (LP_ETH too small against supply?)");
        // Dust-QPULL convert grief, mirrored from GoLiveMainnet before anything is sent: a non-zero threshold that fits one
        // capped QPULL slice and quotes >= 1e12 wei at the seed price (spot: threshold * LP_ETH / supply).
        uint256 th = t.convertThreshold();
        require(th != 0, "go-live: Treasury.convertThreshold is 0 (dust-QPULL convert grief)");
        require(
            Math.mulDiv(th, g.lpEth, IERC20(g.qpull).totalSupply()) >= MIN_THRESHOLD_QUOTE_WEI,
            "go-live: convertThreshold quotes < 1e12 wei at the seed price (raise it with setConvertThreshold)"
        );
        require(g.maxConvertPerCall >= th, "go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold");
        // DeployTestnet's in-deploy lockRouting() latched its caps as ceilings; a higher cap here
        // would revert CapTooLarge mid-broadcast, so refuse it up front with the reason.
        if (t.routingLocked()) {
            require(
                g.maxConvertPerCall <= t.lockedMaxConvertPerCall(),
                "go-live: MAX_CONVERT_PER_CALL is above the ceiling DeployTestnet locked (use the same env for both)"
            );
            require(
                g.maxWethConvertPerCall <= t.lockedMaxWethConvertPerCall(),
                "go-live: MAX_WETH_CONVERT_PER_CALL is above the ceiling DeployTestnet locked (use the same env for both)"
            );
        }

        vm.startBroadcast();
        // 1. ARM THE CONVERT CAPS FIRST, in the same slot as GoLiveMainnet step 1. convert()
        //    reverts NotConfigured until BOTH are set. DeployTestnet already armed the same values before its
        //    in-deploy lockRouting() (the lock latches them as ceilings), so this re-arm is a
        //    no-op at the defaults and keeps the step order identical to mainnet (mainnet locks routing LAST).
        t.setMaxConvertPerCall(g.maxConvertPerCall);
        t.setMaxWethConvertPerCall(g.maxWethConvertPerCall);

        // 2. fund the PERMANENT lock. No pool exists yet — seed() creates it in the same transaction as the
        //    add, so there is no window in which a zero-liquidity pool's price can be walked for free. The
        //    lock owns the full-range position and exposes NO remove/withdraw/collect path, and the hook
        //    refuses removal for every caller, so this liquidity can never be pulled. The LP gate passes
        //    because the lock IS the hook's initializer (no tx.origin branch any more).
        IWETHDeposit(g.weth).deposit{ value: g.lpEth }(); // wrap testnet ETH -> mock WETH
        IERC20(g.weth).transfer(address(lock), g.lpEth);
        // Seed 100% of supply: transfer the deployer's ENTIRE QPULL balance into the permanent lock, not a
        // hand-typed LP_QPULL. This makes under-seeding impossible (no number to get wrong).
        IERC20(g.qpull).transfer(address(lock), qpullIn);
        // one-shot; position owned by the lock, permanently unremovable. seed() CREATES the pool and adds the
        // liquidity in this single transaction, so no block exists in which the pool has a price and no
        // liquidity for anyone to walk for free. The last two amounts DECLARE what was just funded in, and
        // the lock refuses to latch unless the add actually COSTS that (+/- 50 bps).
        lock.seed(g.sqrtPrice, g.liq, qpullIn, g.lpEth);
        // Enforce "100% of supply to the locked LP, deployer holds nothing" at the tx level: the whole go-live
        // reverts if any QPULL is left with the deployer. Fair-launch / can't-rug becomes a bytecode fact, not
        // a promise. (NOTE: this asserts supply LEFT the deployer into the no-remove lock; sizing sqrtPrice/liq
        // so the bulk is TRADEABLE rather than locked excess is a separate step.)
        require(IERC20(g.qpull).balanceOf(me) == 0, "go-live: QPULL not 100% seeded to the lock");

        // 4. deploy the site's swap router: src/periphery/QpullSwapRouter.sol, the same contract mainnet deploys
        //    (Deploy.s.sol). Its constructor checks every argument against the hook's immutables.
        QpullSwapRouter swapRouter =
            new QpullSwapRouter(g.poolManager, g.weth, g.qpull, g.hook, g.fee, g.tickSpacing);
        vm.stopBroadcast();

        // Read back: convert() is only unbricked if BOTH caps are non-zero on-chain (mirrors GoLiveMainnet (vi)).
        require(t.maxConvertPerCall() != 0, "go-live: maxConvertPerCall not armed");
        require(t.maxWethConvertPerCall() != 0, "go-live: maxWethConvertPerCall not armed");
        // Mirrors GoLiveMainnet._preflightConvertThreshold: DeployTestnet now arms a non-zero convertThreshold like
        // mainnet, and a QPULL slice cap below it would make every threshold-sized QPULL leg sell a sub-threshold
        // slice.
        require(
            t.maxConvertPerCall() >= t.convertThreshold(), "go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold"
        );
        require(swapRouter.hook() == g.hook && swapRouter.qpull() == g.qpull, "go-live: swap router bound elsewhere");
        return (address(lock), address(swapRouter));
    }

    function _report(GL memory g, address lock, address router) internal view {
        console2.log("GO-LIVE complete. Pool created + liquidity seeded into the PERMANENT lock.");
        console2.log("  hook (initializer-gated):", g.hook);
        console2.log("  LIQUIDITY LOCK (owns the position, no remove path):", lock);
        console2.log("  seeded WETH (wei):", g.lpEth);
        // The lock's QPULL balance AFTER the seed is the unconsumed remainder (dust/donations), not the amount seeded:
        // the seed moved the deployer's whole balance and the pool consumed it to within MAX_RESIDUAL_BPS (matches
        // GoLiveMainnet._reportResiduals). The consumed amounts are in the lock's Seeded event.
        console2.log("  QPULL left in the lock (locked dust/donations, wei):", IERC20(g.qpull).balanceOf(lock));
        console2.log("  liquidity units (DERIVED):", uint256(g.liq));
        console2.log("  sqrtPriceX96 (DERIVED):", uint256(g.sqrtPrice));
        console2.log("  SWAP ROUTER (site buy/sell):", router);
        console2.log("  Treasury.maxConvertPerCall (QPULL wei, armed):", g.maxConvertPerCall);
        console2.log("  Treasury.maxWethConvertPerCall (WETH wei, armed):", g.maxWethConvertPerCall);
        // GATE_DURATION() is 1h on mainnet and 15m on the testnet hook subclass; read it rather than guess.
        console2.log("NOTE: the holder gate is now OPEN. Seconds remaining:", QpullTaxHook(g.hook).GATE_DURATION());
        console2.log("NOTE: convert() is ARMED (both caps set). ExerciseTestnet convertNow() / the keeper can run it.");
    }
}
