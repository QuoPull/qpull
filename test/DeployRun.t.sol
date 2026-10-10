// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "../script/Deploy.s.sol";
import { HookMiner } from "../script/HookMiner.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { Treasury } from "../src/Treasury.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";

/// Quotron canonical ETH router stand-in: the three reads LaunchGuards.requireExternals makes.
contract DRRouter {
    address public quotron;
    address public weth;

    constructor(address q, address w) {
        quotron = q;
        weth = w;
    }

    function poolKey() external view returns (address, address, uint24, int24, address) {
        (address a, address b) = weth < quotron ? (weth, quotron) : (quotron, weth);
        return (a, b, 0x800000, 60, address(0));
    }
}

/// @notice Deploy.run() exercised end to end. This runs the REAL run() body
///         (`_run`: `_cfg` through the env seam, `_preflight`, `vm.startBroadcast`, `_deploy` with the HookMiner CREATE2
///         and the predicted lock CREATE, `_wire`, `_postDeployBindings`, `_log`) in-process, as the broadcaster.
///
///         WHY THIS IS NOW POSSIBLE. test/fork/GoLiveMainnetFork.t.sol records that calling the script from a test
///         aborted with "lock address mismatch". That was an external `deploy.run()`: msg.sender was the test contract,
///         not the broadcaster, so `computeCreateAddress(me, getNonce(me) + 1)` predicted a CREATE from the wrong
///         account. The test below INHERITS the script and calls the internal body with msg.sender == tx.origin == the
///         default broadcaster, so every broadcast call and CREATE is accounted to `me`, exactly as `forge script` does.
///         The load-bearing facts it therefore proves in-process: the REQUIRED_FLAGS STATICCALL between the hook's
///         CREATE2-factory call and the lock's CREATE consumes no nonce (the `lock == predictedLock` require would fail
///         otherwise); the renamed env contract; the required variables; and _postDeployBindings.
///         It does NOT prove RH-specific behaviour (the real externals and the real BlsDrandOracle on a 4663 fork): that
///         remains scratchpad/mainnet-rehearsal.sh's job.
contract DeployRunTest is Test, Deploy {
    uint256 constant NOW = 1_800_000_000;

    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => uint256) internal envU;
    mapping(bytes32 => bool) internal envSet;

    /// Every variable Deploy._cfg reads with no default.
    function _required() internal pure returns (string[21] memory r) {
        r[0] = "QUOTRON";
        r[1] = "WETH";
        r[2] = "QUOTRON_ROUTER";
        r[3] = "DRAND_ORACLE";
        r[4] = "NFT_ADDRESS";
        r[5] = "TEAM_WALLET";
        r[6] = "KEEPER";
        r[7] = "GENESIS";
        r[8] = "TICKET_PRICE_WETH";
        r[9] = "REVEAL_DELAY";
        r[10] = "WINNERS_PER_DAY";
        r[11] = "RAFFLE_CAP_BPS";
        r[12] = "CONVERT_THRESHOLD";
        r[13] = "HOLDER_POT_CAP";
        r[14] = "HOLDER_POT_CEILING";
        r[15] = "HOLDER_MIN_POT";
        r[16] = "RAFFLE_MIN_POT";
        r[17] = "LEADERBOARD_MIN_POT";
        r[18] = "RAFFLE_POT_CAP";
        r[19] = "LEADERBOARD_POT_CAP";
        r[20] = "EARLY_BUY_CAP_WEI";
    }

    function _envAddress(string memory key) internal view override returns (address) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envA[keccak256(bytes(key))];
    }

    function _envUint(string memory key) internal view override returns (uint256) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envU[keccak256(bytes(key))];
    }

    function _envOrAddress(string memory key, address dflt) internal view override returns (address) {
        return envSet[keccak256(bytes(key))] ? envA[keccak256(bytes(key))] : dflt;
    }

    function _envOrUint(string memory key, uint256 dflt) internal view override returns (uint256) {
        return envSet[keccak256(bytes(key))] ? envU[keccak256(bytes(key))] : dflt;
    }

    function _setA(string memory k, address v) internal {
        envA[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function _setU(string memory k, uint256 v) internal {
        envU[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function runExt() external {
        _run(msg.sender);
    }

    address nft;
    address oracle;

    /// The environment Deploy.s.sol needs, against local stand-ins for the RH externals and a real NFTCollection
    /// (owned by the broadcaster, built against a real BlsDrandOracle).
    function _world() internal {
        vm.warp(NOW);
        address quotron = deployCode("MockERC20.sol:MockERC20");
        address weth = deployCode("MockWETH.sol:MockWETH");
        address pm = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        oracle = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        PassArtRenderer renderer = new PassArtRenderer(address(this));
        renderer.lock();
        nft = address(new NFTCollection(0.0075 ether, oracle, 1 hours, address(renderer), DEFAULT_SENDER));

        _setA("QUOTRON", quotron);
        _setA("WETH", weth);
        _setA("POOL_MANAGER", pm);
        _setA("QUOTRON_ROUTER", address(new DRRouter(quotron, weth)));
        _setA("DRAND_ORACLE", oracle);
        _setA("NFT_ADDRESS", nft);
        _setA("TEAM_WALLET", makeAddr("team+ops"));
        _setA("KEEPER", makeAddr("convertKeeper"));
        _setU("GENESIS", NOW + 3 days);
        _setU("TICKET_PRICE_WETH", 0.003 ether);
        _setU("REVEAL_DELAY", 1 hours);
        _setU("WINNERS_PER_DAY", 10);
        _setU("RAFFLE_CAP_BPS", 1000);
        _setU("CONVERT_THRESHOLD", 1000e18);
        _setU("HOLDER_POT_CAP", 5e18);
        _setU("HOLDER_POT_CEILING", 100e18);
        _setU("HOLDER_MIN_POT", 0.01e18);
        _setU("RAFFLE_MIN_POT", 0.01e18);
        _setU("LEADERBOARD_MIN_POT", 0.02e18);
        _setU("RAFFLE_POT_CAP", 10e18);
        _setU("LEADERBOARD_POT_CAP", 10e18);
        _setU("EARLY_BUY_CAP_WEI", 0.25 ether);
    }

    function test_deployRun_endToEnd_asTheBroadcaster() public {
        _world();
        address me = msg.sender;
        assertEq(me, DEFAULT_SENDER, "the test caller is the default broadcaster");
        assertEq(tx.origin, me, "and tx.origin");

        Deployed memory d = _run(me);

        // the hook<->lock cycle, closed by the nonce prediction
        QpullTaxHook hook = QpullTaxHook(d.hook);
        QpullLiquidityLock lock = QpullLiquidityLock(d.lock);
        assertEq(uint160(d.hook) & HookMiner.FLAG_MASK, 0x1ACC, "hook mined to 0x1ACC");
        assertEq(hook.REQUIRED_FLAGS(), 0x1ACC, "the 0x1ACC WETH-tax hook");
        assertEq(hook.initializer(), d.lock, "hook.initializer == the lock CREATE'd right after it");
        assertEq(lock.hook(), d.hook, "lock bound to the hook");
        assertEq(lock.opener(), me, "the deployer opens the lock");
        assertEq(hook.GATE_DURATION(), 1 hours, "mainnet 1-hour holder gate");
        assertEq(hook.earlyBuyCapWei(), 0.25 ether, "EARLY_BUY_CAP_WEI read");
        assertEq(hook.canonicalFee(), 3000, "QPULL_POOL_FEE default");
        assertEq(hook.canonicalTickSpacing(), 60, "QPULL_POOL_TICK_SPACING default");

        // _wire
        assertEq(NFTCollection(nft).owner(), me, "premise: the broadcaster owns the NFT");
        assertEq(address(NFTCollection(nft).taxHook()), d.hook, "setTaxHook wired the transfer-lock");
        assertEq(PackRegistry(d.packs).recorder(), d.hook, "hook is the pack recorder");
        assertEq(PackRegistry(d.packs).engine(), d.raffle, "raffle bound");
        assertTrue(ClaimManager(d.claimMgr).enginesLocked(), "engines frozen");
        Treasury t = Treasury(payable(d.treasury));
        assertEq(t.owner(), me, "Treasury owned by the deployer");
        assertEq(t.convertThreshold(), 1000e18, "CONVERT_THRESHOLD read and set");
        assertTrue(t.isKeeper(makeAddr("convertKeeper")) && t.keeperCount() == 1, "exactly the one keeper");
        assertFalse(t.routingLocked(), "routing left for GoLiveMainnet");
        assertEq(t.maxConvertPerCall(), 0, "convert() left fail-closed");
        assertTrue(QpullWethAdapter(d.qpullWethAdapter).poolKeySet(), "adapter bound to the canonical key");
        assertEq(QpullWethAdapter(d.qpullWethAdapter).treasury(), d.treasury, "adapter treasury");
        assertFalse(lock.seeded(), "nothing seeded");

        // the site swap router (the owner's choice), deployed right after the lock and bound to the canonical key
        QpullSwapRouter r = QpullSwapRouter(payable(d.swapRouter));
        assertGt(d.swapRouter.code.length, 0, "the router was deployed");
        assertEq(r.hook(), d.hook, "router hook");
        assertEq(r.qpull(), d.token, "router QPULL");
        assertEq(r.weth(), envA[keccak256("WETH")], "router WETH");
        assertEq(address(r.poolManager()), envA[keccak256("POOL_MANAGER")], "router PoolManager");
        assertEq(r.fee(), 3000, "router fee");
        assertEq(r.tickSpacing(), int24(60), "router tick spacing");
        assertTrue(hook.isCanonical(r.poolKey()), "router key is the hook's canonical key");
        assertTrue(hook.exemptSender() != d.swapRouter, "router is taxed (not the exemptSender)");
        assertEq(hook.exemptSender(), d.qpullWethAdapter, "only the convert adapter is exempt");
        assertTrue(d.swapRouter != d.lock && d.swapRouter != d.hook, "a distinct contract");
    }

    /// Every variable _cfg reads as REQUIRED fails the run closed when unset, before anything is deployed.
    function test_deployRun_everyRequiredVariable_failsClosedWhenUnset() public {
        _world();
        string[21] memory required = _required();
        for (uint256 i; i < required.length; ++i) {
            bytes32 k = keccak256(bytes(required[i]));
            envSet[k] = false;
            vm.expectRevert(bytes(string.concat("test env unset: ", required[i])));
            this.runExt();
            envSet[k] = true;
        }
    }

    /// A tick spacing outside v4's range is refused by the script before the int24 cast (and by the hook and the lock
    /// constructors behind it).
    function test_deployRun_badTickSpacing_refusedBeforeAnyDeploy() public {
        _world();
        _setU("QPULL_POOL_TICK_SPACING", 32_768);
        vm.expectRevert(bytes("deploy: QPULL_POOL_TICK_SPACING must be in [1, 32767]"));
        this.runExt();
    }
}
