// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { NonceAwareDeploy } from "../utils/NonceAwareDeploy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolKey, Currency } from "../../src/interfaces/IPoolManager.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../../src/QpullLiquidityLock.sol";
import { Treasury } from "../../src/Treasury.sol";
import { LpSizing } from "../../script/LpSizing.sol";
import { GoLiveMainnet } from "../../script/GoLiveMainnet.s.sol";
import { LaunchGuards } from "../../script/LaunchGuards.sol";

interface ILaunchMintable {
    function mint(address to, uint256 amt) external;
}

interface ILaunchWeth {
    function deposit() external payable;
}

interface ILaunchNft {
    function setRecipients(address lp, address seed, address team) external;
    function reserveMint(uint256 qty, address to) external;
    function setAllowlistRoot(bytes32 root) external;
    function setMintOpen(bool v) external;
    function openAllowlistMint() external;
    function publicOpensAt() external view returns (uint256);
    function mint() external payable;
    function finalizeLaunch() external;
    function withdrawProceeds() external;
    function lpReserve() external view returns (uint256);
    function totalMinted() external view returns (uint256);
    function setTaxHook(address h) external;
    function taxHook() external view returns (address);
}

interface ILaunchLockable {
    function lock() external;
}

interface ILaunchPacks {
    function setRecorder(address) external;
    function setEngine(address) external;
}

interface ILaunchQpullWethAdmin {
    function setTreasury(address) external;
    function setPoolKey(PoolKey calldata k) external;
}

interface ILaunchClaims {
    function setEngine(address e, address vault) external;
    function lockEngines(address[] calldata engines, address[] calldata vaults) external;
}

interface ILaunchVault {
    function setController(address c) external;
}

/// Stand-in for Quotron's canonical ETH router. Honest by default; `mode` models a misbound or non-delivering router.
contract StubQuotronRouter {
    address public immutable quotronT;
    address public immutable wethT;
    address public immutable otherToken;

    function quotron() external view returns (address) {
        return mode == 3 ? otherToken : quotronT; // mode 3 is a router genuinely bound to the other token
    }

    function weth() external view returns (address) {
        return wethT;
    }

    // 0 honest, 1 pays nothing, 2 pays a DIFFERENT token, 3 reports the wrong pool,
    // 4 strands value: pays QUOTRON for half the ETH and sends the other half back to the caller AS WETH
    uint8 public mode;

    constructor(address q, address w, address other) {
        quotronT = q;
        wethT = w;
        otherToken = other;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function buyExactEth(uint256 minOut, address recipient, uint256) external payable returns (uint256 out) {
        if (mode == 1) return 0;
        if (mode == 4) {
            uint256 half = msg.value / 2;
            ILaunchWeth(wethT).deposit{ value: half }();
            IERC20(wethT).transfer(msg.sender, half); // a WETH "refund" the adapter never forwards
            out = (msg.value - half) * 1000;
            require(out >= minOut, "router: slippage");
            ILaunchMintable(quotronT).mint(recipient, out);
            return out;
        }
        out = msg.value * 1000;
        require(out >= minOut, "router: slippage");
        ILaunchMintable(mode == 2 ? otherToken : quotronT).mint(recipient, out);
    }

    function poolKey() external view returns (address, address, uint24, int24, address) {
        if (mode == 3) {
            (address x, address y) = wethT < otherToken ? (wethT, otherToken) : (otherToken, wethT);
            return (x, y, 0x800000, 60, address(0));
        }
        (address a, address b) = wethT < quotronT ? (wethT, quotronT) : (quotronT, wethT);
        return (a, b, 0x800000, 60, address(0x62E200Cc8e4D95cf622f40Dd70f407C883EcB0cc));
    }
}

/// @notice The in-process launch world: a real vendored v4 PoolManager, the real QpullTaxHook, QpullLiquidityLock,
///         Treasury, BaseVaults, QuotronRouterAdapter, QpullWethAdapter, PackRegistry, RaffleEngine, LeaderboardRegistry
///         and a REAL NFTCollection raise, with per-test env storage for a script's env seam. Script-agnostic, so both the
///         GoLiveMainnet harness (below) and the GoLiveTestnet harness (test/GoLiveTestnetRouter.t.sol) build on it.
///         Holds no tests.
abstract contract LaunchWorld is NonceAwareDeploy {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // real RH WETH address (mock code)
    address constant QPULL_HI = 0xfFFF000000000000000000000000000000000FFF; // sorts ABOVE WETH
    address constant QPULL_LO = 0x00000000000000000000000000000000000A11cE; // sorts BELOW WETH
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant T0 = 1_800_000_000;
    uint256 constant GEN = T0 + 25 hours; // the planned go-live: one hour after the public window opens
    uint256 constant PRICE = 1 ether;
    uint256 constant PAID = 26;
    uint256 constant RESERVE = 25;
    uint256 constant BUCKET = (PAID * PRICE * 8000) / 10_000; // 20.8 ETH: the LP bucket the mint pays out

    address deployer = DEFAULT_SENDER;
    address pm;
    address qpullT;
    address wethT;
    address quotronT;
    address treasuryT;
    address hookT;
    address lockT;
    address adapterT;
    address wqT;
    address routerT;
    address prizeT;
    address holderT;
    address lbT;
    address teamT;
    address nftT;
    address keeperT;
    address claimsT;

    // Per-test env, read through the script's env seam (the process environment is shared by concurrent tests).
    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => uint256) internal envU;
    mapping(bytes32 => bool) internal envSet;

    function _worldEnvAddress(string memory key) internal view returns (address) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envA[keccak256(bytes(key))];
    }

    function _worldEnvUint(string memory key) internal view returns (uint256) {
        require(envSet[keccak256(bytes(key))], string.concat("test env unset: ", key));
        return envU[keccak256(bytes(key))];
    }

    function _worldEnvOrUint(string memory key, uint256 dflt) internal view returns (uint256) {
        return envSet[keccak256(bytes(key))] ? envU[keccak256(bytes(key))] : dflt;
    }

    function _setA(string memory key, address v) internal {
        envA[keccak256(bytes(key))] = v;
        envSet[keccak256(bytes(key))] = true;
    }

    function _setU(string memory key, uint256 v) internal {
        envU[keccak256(bytes(key))] = v;
        envSet[keccak256(bytes(key))] = true;
    }

    struct Opts {
        address qpullAt;
        bool lpToDeployer;
        bool withdraw;
        uint256 price; // mint price (wei per pass)
        uint256 paid; // paid passes on top of the 25-pass reserve
        // ClaimManager / vault wiring: 0 as Deploy.s.sol leaves it, 1 engines not locked, 2 the raffle bound to
        // the wrong vault, 3 the holder vault controlled by something other than the ClaimManager
        uint8 engineMode;
        // FORK MODE: on an RH mainnet fork, use the LIVE WETH, PoolManager, QUOTRON and Quotron router (the
        // LaunchGuards pins) and the real QPULLToken at `qpullAt`, and clock the world from the fork's own timestamp.
        bool realExternals;
        // 0 = the NFT is wired to the launched hook (Deploy.s.sol shape), 1 = left unwired
        uint8 nftHookMode;
    }

    /// The world's clock: T0/GEN locally; the fork's timestamp (and +25h) in fork mode.
    uint256 internal worldT0;
    uint256 internal worldGen;

    function _opts(address qpullAt) internal pure returns (Opts memory o) {
        o.qpullAt = qpullAt;
        o.lpToDeployer = true;
        o.withdraw = false; // the recommended flow: go-live withdraws the bucket itself (exact anchor)
        o.price = PRICE;
        o.paid = PAID;
    }

    function _deploy(Opts memory o) internal {
        qpullT = o.qpullAt;
        if (o.realExternals) {
            require(block.chainid == LaunchGuards.RH_MAINNET, "fork mode needs an RH mainnet fork");
            (worldT0, worldGen) = (block.timestamp, block.timestamp + 25 hours);
            wethT = LaunchGuards.RH_WETH;
            quotronT = LaunchGuards.RH_QUOTRON;
            routerT = LaunchGuards.RH_QUOTRON_ROUTER;
            pm = LaunchGuards.RH_POOL_MANAGER;
            require(qpullT.code.length == 0, "fork mode: QPULL address already has code on this chain");
            deployCodeTo("QPULLToken.sol:QPULLToken", abi.encode(SUPPLY, deployer), qpullT); // 100% to the deployer
        } else {
            (worldT0, worldGen) = (T0, GEN);
            vm.warp(T0);
            wethT = RH_WETH;
            vm.etch(wethT, deployCode("MockWETH.sol:MockWETH").code);
            vm.etch(qpullT, deployCode("MockERC20.sol:MockERC20").code);
            quotronT = deployCode("MockERC20.sol:MockERC20");
            routerT = address(new StubQuotronRouter(quotronT, wethT, deployCode("MockERC20.sol:MockERC20")));
            pm = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        }
        address oracle = deployCode("MockDrandOracle.sol:MockDrandOracle", abi.encode(worldT0, uint256(3)));
        teamT = makeAddr("team");
        keeperT = makeAddr("keeperBot");

        vm.startPrank(deployer);
        treasuryT = deployCode("Treasury.sol:Treasury", abi.encode(qpullT, wethT, quotronT, deployer));
        prizeT = deployCode("BaseVault.sol:BaseVault", abi.encode(quotronT, deployer));
        holderT = deployCode("BaseVault.sol:BaseVault", abi.encode(quotronT, deployer));
        lbT = deployCode("BaseVault.sol:BaseVault", abi.encode(quotronT, deployer));
        claimsT = deployCode("ClaimManager.sol:ClaimManager", abi.encode(deployer));
        address packs =
            deployCode("PackRegistry.sol:PackRegistry", abi.encode(oracle, uint256(3e15), worldGen, uint256(1 hours), deployer));
        address lbReg = deployCode("LeaderboardRegistry.sol:LeaderboardRegistry", abi.encode(worldGen, deployer));
        address raffle = deployCode(
            "RaffleEngine.sol:RaffleEngine",
            abi.encode(
                oracle, packs, prizeT, claimsT, worldGen, uint256(3), uint256(1), uint256(1000e18), uint256(1000), deployer
            )
        );
        ILaunchPacks(packs).setEngine(raffle);
        _wireClaims(o.engineMode, raffle);
        address renderer = deployCode("PassArtRenderer.sol:PassArtRenderer", abi.encode(deployer));
        ILaunchLockable(renderer).lock();
        nftT = deployCode(
            "NFTCollection.sol:NFTCollection", abi.encode(o.price, oracle, uint256(1 hours), renderer, deployer)
        );
        adapterT = deployCode("QpullWethAdapter.sol:QpullWethAdapter", abi.encode(pm, qpullT, wethT, deployer));
        wqT = deployCode(
            "QuotronRouterAdapter.sol:QuotronRouterAdapter", abi.encode(routerT, wethT, quotronT, deployer)
        );
        vm.stopPrank();

        // Deploy.s.sol shape: hook names the lock's PREDICTED address. deployCodeTo's nonce cost is measured,
        // not assumed: it changed between Foundry versions and failed 48 tests at once. See NonceAwareDeploy.
        address predicted = _predictCreateAfterDeployCodeTo(1);
        hookT = address(uint160((0x60E1 << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: pm,
                    qpull: qpullT,
                    weth: wethT,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: treasuryT,
                    packRegistry: packs,
                    leaderboardRegistry: lbReg,
                    nft: nftT,
                    exemptSender: adapterT,
                    initializer: predicted,
                    earlyBuyCapWei: 0.25 ether
                })
            ),
            hookT
        );
        lockT = deployCode(
            "QpullLiquidityLock.sol:QpullLiquidityLock",
            abi.encode(pm, qpullT, wethT, uint24(3000), int24(60), hookT, deployer)
        );
        require(lockT == predicted, "lock prediction");

        if (!o.realExternals) ILaunchMintable(qpullT).mint(deployer, SUPPLY); // deployer holds 100% of supply
        vm.startPrank(deployer);
        ILaunchPacks(packs).setRecorder(hookT);
        ILaunchPacks(lbReg).setRecorder(hookT);
        Treasury t = Treasury(payable(treasuryT));
        t.setAdapters(adapterT, wqT);
        t.setRouting(prizeT, holderT, lbT, teamT);
        t.setKeeper(keeperT, true);
        t.setConvertThreshold(1000e18);
        ILaunchQpullWethAdmin(adapterT).setTreasury(treasuryT);
        ILaunchQpullWethAdmin(adapterT).setPoolKey(_key());
        ILaunchQpullWethAdmin(wqT).setTreasury(treasuryT);
        vm.stopPrank();

        _raise(o);
        // Deploy.s.sol's _wire makes the write-once NFTCollection.setTaxHook(hook) after the raise; GoLiveMainnet checks it
        // (it refuses an NFT bound to any other hook). A world that must model a missing or foreign binding sets nftHookMode.
        if (o.nftHookMode == 0) {
            vm.prank(deployer);
            ILaunchNft(nftT).setTaxHook(hookT);
        }
        vm.warp(worldGen);
    }

    /// Deploy.s.sol's ClaimManager wiring (three vault controllers, three engine bindings, frozen), or a broken
    /// variant of it. Runs inside the deployer prank. The leaderboard and holder engines are stand-in addresses:
    /// GoLiveMainnet cannot reach them (TransferOwnership proves them), and ClaimManager accepts any non-zero key.
    function _wireClaims(uint8 mode, address raffle) internal {
        ILaunchVault(prizeT).setController(claimsT);
        ILaunchVault(holderT).setController(mode == 3 ? makeAddr("notTheClaimManager") : claimsT);
        ILaunchVault(lbT).setController(claimsT);
        address[] memory engs = new address[](3);
        address[] memory vlts = new address[](3);
        (engs[0], engs[1], engs[2]) = (raffle, makeAddr("leaderboardEngine"), makeAddr("holderEngine"));
        (vlts[0], vlts[1], vlts[2]) = mode == 2 ? (lbT, prizeT, holderT) : (prizeT, lbT, holderT);
        for (uint256 i; i < 3; ++i) {
            ILaunchClaims(claimsT).setEngine(engs[i], vlts[i]);
        }
        // mode 2 wires the TRANSPOSED graph but deliberately does NOT lock it: a ClaimManager change made
        // lockEngines ask each engine what vault it holds, so freezing a transposed map now reverts
        // BindingMismatch and this fixture could not be built at all. Leaving it unlocked is the state the
        // go-live preflight below is there to catch, and the one that is still reachable in real life.
        if (mode != 1 && mode != 2) ILaunchClaims(claimsT).lockEngines(engs, vlts);
    }

    /// The real raise: 25-pass reserve, `paid` passes at `price` (26 at 1 ETH by default), finalize; optionally
    /// withdraw the buckets early.
    function _raise(Opts memory o) internal {
        ILaunchNft n = ILaunchNft(nftT);
        vm.startPrank(deployer);
        n.setRecipients(o.lpToDeployer ? deployer : makeAddr("lpElsewhere"), makeAddr("seedTreasury"), teamT);
        n.reserveMint(RESERVE, deployer);
        n.setAllowlistRoot(keccak256("root"));
        n.setMintOpen(true);
        n.openAllowlistMint();
        vm.stopPrank();
        vm.warp(n.publicOpensAt());
        for (uint256 i; i < o.paid; ++i) {
            address m = address(uint160(0xB0B0000 + i));
            vm.deal(m, o.price);
            vm.prank(m);
            n.mint{ value: o.price }();
        }
        vm.prank(deployer);
        n.finalizeLaunch();
        vm.deal(deployer, 50 ether);
        assertEq(n.lpReserve(), (o.paid * o.price * 8000) / 10_000, "the mint split exactly 80% into the LP bucket");
        if (o.withdraw) n.withdrawProceeds(); // permissionless
    }

    function _setEnv(uint256 lpEth) internal {
        _setA("POOL_MANAGER", pm);
        _setA("QPULL", qpullT);
        _setA("WETH", wethT);
        _setA("TREASURY", treasuryT);
        _setA("HOOK", hookT);
        _setA("LOCK", lockT);
        _setA("PRIZE_VAULT", prizeT);
        _setA("HOLDER_VAULT", holderT);
        _setA("LEADERBOARD_VAULT", lbT);
        _setA("TEAM_WALLET", teamT);
        _setA("QPULL_WETH_ADAPTER", adapterT);
        _setA("WETH_QUOTRON_ADAPTER", wqT);
        _setA("QUOTRON", quotronT);
        _setA("QUOTRON_ROUTER", routerT);
        _setA("KEEPER", keeperT);
        _setU("LP_ETH_WEI", lpEth);
        _setU("LP_TOPUP_WEI", 0);
        _setU("ACCEPT_GENESIS_SLIP_SECS", 0);
        _setU("MAX_CONVERT_PER_CALL", 5_000_000e18);
        _setU("MAX_WETH_CONVERT_PER_CALL", 1e18);
    }

    function _key() internal view returns (PoolKey memory) {
        (address c0, address c1) = qpullT < wethT ? (qpullT, wethT) : (wethT, qpullT);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, hookT);
    }
}

/// @notice The GoLiveMainnet in-process harness on the LaunchWorld: the script's env seam reads the world's per-test env.
///         Shared by GoLiveLpEthUncheckedTest (below) and test/GoLivePartialBroadcast.t.sol. Holds no tests.
abstract contract GoLiveHarness is LaunchWorld, GoLiveMainnet {
    function _envAddress(string memory key) internal view override returns (address) {
        return _worldEnvAddress(key);
    }

    function _envUint(string memory key) internal view override returns (uint256) {
        return _worldEnvUint(key);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view override returns (uint256) {
        return _worldEnvOrUint(key, dflt);
    }

    /// GoLiveMainnet.run() body, verbatim sequence (run() is external; calling it via this.run() would change
    /// msg.sender away from the broadcaster).
    function _runGoLive() internal {
        GL memory g = _env();
        address me = msg.sender;
        _preflight(g, me);
        PoolKey memory key = _canonicalKey(g);
        QpullLiquidityLock lock = _goLive(g, key, me);
        _report(g, address(lock));
    }

    function goLiveExt(address me) external {
        GL memory g = _env();
        _preflight(g, me);
        _goLive(g, _canonicalKey(g), me);
    }

    function preflightExt(address me) external view {
        GL memory g = _env();
        _preflight(g, me);
    }

    function sizeExt(uint256 lpEth) external view returns (uint160, uint128) {
        return LpSizing.sizeFor(qpullT, SUPPLY, wethT, lpEth, -887_220, 887_220);
    }

    struct SeededEv {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 qpullConsumed;
        uint256 wethConsumed;
    }

    function _seededEvent() internal returns (SeededEv memory e) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Seeded(uint160,uint128,int24,int24,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == lockT && logs[i].topics[0] == sig) {
                e = abi.decode(logs[i].data, (SeededEv));
                found = true;
            }
        }
        assertTrue(found, "Seeded emitted");
    }

    function _expectPreflightRevert(bytes memory reason) internal {
        vm.expectRevert(reason);
        this.preflightExt(deployer);
    }
}

/// @notice Pins the fix for "LP_ETH is an unchecked raw-wei input that alone sets the permanent launch price",
///         together with the other GoLiveMainnet fixes (the QUOTRON bindings, the LP bucket recipient, a re-run
///         after an interrupted funding, GENESIS against the clock, the convert threshold, the keeper pin).
///
///         Runs the REAL GoLiveMainnet body (`_env`, `_preflight`, `_canonicalKey`, `_goLive` with its
///         vm.startBroadcast and its convert rehearsal, `_report`) against a real vendored v4 PoolManager, the real
///         QpullTaxHook, QpullLiquidityLock, Treasury, BaseVaults, QuotronRouterAdapter, QpullWethAdapter,
///         PackRegistry, RaffleEngine, LeaderboardRegistry and a REAL NFTCollection raise (a 25-pass reserve plus 26
///         paid passes at 1 ETH: an LP bucket of exactly 20.8 ETH, paid to the deployer). The test INHERITS the
///         script so that `msg.sender` inside the body is the test caller == tx.origin == the broadcaster
///         (DEFAULT_SENDER), which plays the deployer.
///
///         Before the fix: LP_ETH = 2.1 ETH, 21 wei and 1 wei all seeded and latched. Now each is refused in
///         preflight, before a transaction exists.
contract GoLiveLpEthUncheckedTest is GoLiveHarness {
    // ── (1) the real bucket seeds, the convert rehearsal runs and leaves no trace, routing locks ──
    function test_mintAnchoredLpEth_seeds_rehearsesConvert_locksRouting() public {
        _deploy(_opts(QPULL_HI));
        assertTrue(wethT < qpullT, "WETH is currency0 (the likely mainnet order)");
        _setEnv(BUCKET);
        uint256 ethBefore = deployer.balance;
        assertEq(msg.sender, deployer, "test caller is the deployer");
        assertEq(tx.origin, deployer, "and the broadcaster");

        vm.recordLogs();
        _runGoLive();
        SeededEv memory e = _seededEvent();

        assertTrue(QpullLiquidityLock(lockT).seeded(), "lock latched");
        assertGt(QpullTaxHook(hookT).launchTime(), 0, "pool created, launchTime stamped");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "routing frozen");
        assertEq(IERC20(qpullT).balanceOf(deployer), 0, "100% of supply left the deployer");
        (uint160 expP,) = LpSizing.sizeFor(qpullT, SUPPLY, wethT, BUCKET, -887_220, 887_220);
        assertEq(e.sqrtPriceX96, expP, "pool created at the mint-anchored price");
        assertApproxEqRel(e.wethConsumed, BUCKET, 0.005e18, "the pool holds the whole 80% LP bucket");
        assertEq(deployer.balance, ethBefore, "the run withdrew the 20.8 ETH bucket and seeded exactly that");
        assertEq(ILaunchNft(nftT).lpReserve(), 0, "the LP bucket left the NFT inside the run (exact anchor)");
        // the rehearsal ran against the seeded state and was reverted: nothing it did survives
        assertEq(IERC20(wethT).balanceOf(treasuryT), 0, "rehearsal WETH reverted");
        assertEq(IERC20(quotronT).balanceOf(prizeT), 0, "rehearsal QUOTRON reverted (prize)");
        assertEq(IERC20(quotronT).balanceOf(holderT), 0, "rehearsal QUOTRON reverted (holder)");
        assertEq(IERC20(quotronT).balanceOf(lbT), 0, "rehearsal QUOTRON reverted (leaderboard)");
        assertEq(IERC20(wethT).balanceOf(teamT), 0, "rehearsal team WETH reverted");

        // permanence: a second go-live refuses
        vm.expectRevert(bytes("go-live: the lock has already been seeded (run --tc GoLiveMainnetResume)"));
        this.preflightExt(deployer);
    }

    // ── (2) the bug's own inputs are now refused in preflight: one zero short, either sort order ──
    function test_oneZeroShort_refused_wethFirst() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET / 10); // 2.08 ETH
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is below the mint's LP bucket + LP_TOPUP_WEI (short of the 80% to liquidity)")
        );
    }

    function test_oneZeroShort_refused_qpullFirst() public {
        _deploy(_opts(QPULL_LO));
        assertTrue(qpullT < wethT, "QPULL is currency0");
        _setEnv(BUCKET / 10);
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is below the mint's LP bucket + LP_TOPUP_WEI (short of the 80% to liquidity)")
        );
    }

    // ── (3) a 10x overshoot is refused too, even with the ETH to fund it ──
    function test_tenXOver_refused() public {
        _deploy(_opts(QPULL_HI));
        vm.deal(deployer, 500 ether);
        _setEnv(BUCKET * 10);
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is above the mint's LP bucket + LP_TOPUP_WEI (declare any top-up in LP_TOPUP_WEI)")
        );
    }

    // ── (4) ether typed where wei is expected: 21, 1 and the old WETH-first threshold all refused ──
    function test_unitErrors_refused() public {
        _deploy(_opts(QPULL_LO));
        bytes memory floorMsg = bytes("go-live: LP_ETH_WEI below 1 ether (it is WEI: 21 ether = 21000000000000000000)");
        _setEnv(21);
        _expectPreflightRevert(floorMsg);
        _setEnv(1);
        _expectPreflightRevert(floorMsg);
        _setEnv(54_210_109);
        _expectPreflightRevert(floorMsg);
    }

    // ── (5) a declared top-up seeds; an undeclared or oversized one does not ──
    function test_topUp_mustBeDeclared_andBounded() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET + 5 ether);
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is above the mint's LP bucket + LP_TOPUP_WEI (declare any top-up in LP_TOPUP_WEI)")
        );
        _setU("LP_TOPUP_WEI", 30 ether);
        _expectPreflightRevert(bytes("go-live: LP_TOPUP_WEI exceeds both the mint's own LP bucket and the 1 ether floor"));
        _setU("LP_TOPUP_WEI", 5 ether);
        vm.recordLogs();
        _runGoLive();
        assertApproxEqRel(_seededEvent().wethConsumed, BUCKET + 5 ether, 0.005e18, "seeded bucket + declared top-up");
    }

    // ── (6) bounds mode: the bucket was withdrawn before go-live, so it is bounded from the mint's state ──
    function test_boundsMode_afterEarlyWithdraw() public {
        Opts memory o = _opts(QPULL_HI);
        o.withdraw = true;
        _deploy(o);
        assertEq(ILaunchNft(nftT).lpReserve(), 0, "withdrawn early");
        // 51 minted, reserve latched: paid is 26..50 passes, so the bucket is bounded to [20.8, 40] ETH (+dust).
        // The low bound assumes a full RESERVE_CAP reserve, which is exactly this raise, so it is tight here.
        _setEnv(BUCKET - 1);
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is below the mint's LP bucket + LP_TOPUP_WEI (short of the 80% to liquidity)")
        );
        _setEnv(BUCKET * 10);
        vm.deal(deployer, 500 ether);
        _expectPreflightRevert(
            bytes("go-live: LP_ETH_WEI is above the mint's LP bucket + LP_TOPUP_WEI (declare any top-up in LP_TOPUP_WEI)")
        );
        vm.deal(deployer, 70.8 ether);
        _setEnv(BUCKET);
        uint256 ethBefore = deployer.balance;
        vm.recordLogs();
        _runGoLive();
        assertApproxEqRel(_seededEvent().wethConsumed, BUCKET, 0.005e18, "seeded the bucket");
        assertEq(ethBefore - deployer.balance, BUCKET, "funded from the key the bucket was paid to");
    }

    // ── (6b) the bucket must be paid to THIS key ──
    function test_lpTreasuryNotTheDeployer_refused() public {
        Opts memory o = _opts(QPULL_HI);
        o.lpToDeployer = false;
        _deploy(o);
        _setEnv(BUCKET);
        _expectPreflightRevert(
            bytes("go-live: NFTCollection.lpTreasury is not this key (the LP bucket goes elsewhere)")
        );
    }

    // ── (7) QUOTRON-side bindings are read back, pinned on 4663, and consistent with the router's pool ──
    function test_quotronBindings_refused() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);

        _setA("QUOTRON", StubQuotronRouter(routerT).otherToken()); // a stale token with code
        _expectPreflightRevert(bytes("launch: QUOTRON_ROUTER.poolKey() is not the {WETH, QUOTRON} pool"));
        StubQuotronRouter(routerT).setMode(3); // the router now reports that stale token's pool...
        _expectPreflightRevert(bytes("go-live: QUOTRON != Treasury.quotron")); // ...and the Treasury still refuses it
        StubQuotronRouter(routerT).setMode(0);
        _setA("QUOTRON", quotronT);

        _setA("QUOTRON_ROUTER", makeAddr("codelessRouter"));
        _expectPreflightRevert(bytes("launch: QUOTRON_ROUTER has no code"));
        address otherRouter = address(new StubQuotronRouter(quotronT, wethT, quotronT));
        _setA("QUOTRON_ROUTER", otherRouter);
        _expectPreflightRevert(bytes("go-live: WETH_QUOTRON_ADAPTER.router != QUOTRON_ROUTER"));
        _setA("QUOTRON_ROUTER", routerT);

        vm.chainId(4663);
        _expectPreflightRevert(bytes("launch: QUOTRON is not the pinned RH mainnet QUOTRON"));
    }

    // ── (8) the live half: a router that does not deliver QUOTRON aborts the run BEFORE lockRouting ──
    function test_convertRehearsal_catchesNonDeliveringRouter() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        this.preflightExt(deployer); // every structural check passes

        StubQuotronRouter(routerT).setMode(1); // takes the ETH, pays nothing
        vm.expectRevert(bytes4(keccak256("Slippage()")));
        this.goLiveExt(deployer);

        StubQuotronRouter(routerT).setMode(2); // pays a different token: the Treasury measures no QUOTRON
        vm.expectRevert(bytes4(keccak256("SwapShortfall()")));
        this.goLiveExt(deployer);

        assertFalse(Treasury(payable(treasuryT)).routingLocked(), "routing was never frozen");
        assertFalse(QpullLiquidityLock(lockT).seeded(), "and nothing was seeded");
    }

    // ── (9) the convert threshold ──
    function test_convertThreshold_refused() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(0);
        _expectPreflightRevert(bytes("go-live: Treasury.convertThreshold is 0 (dust-QPULL convert grief)"));
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(1e18); // quotes 2.08e10 wei at the seed price
        _expectPreflightRevert(
            bytes("go-live: convertThreshold quotes < 1e12 wei at the seed price (raise it with setConvertThreshold)")
        );
        vm.prank(deployer);
        Treasury(payable(treasuryT)).setConvertThreshold(10_000_000e18);
        _expectPreflightRevert(bytes("go-live: MAX_CONVERT_PER_CALL < Treasury.convertThreshold"));
    }

    // ── (10) the keeper is pinned ──
    function test_keeperPin_refused() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _setA("KEEPER", makeAddr("someOtherKeeper"));
        _expectPreflightRevert(bytes("go-live: KEEPER is not a Treasury keeper"));
        _setA("KEEPER", deployer);
        _expectPreflightRevert(bytes("go-live: KEEPER is the deployer (the convert keeper must be its own key)"));
    }

    // ── (11) GENESIS against the clock ──
    function test_genesisWindow() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        vm.warp(GEN - 2 hours);
        _expectPreflightRevert(bytes("go-live: more than 1h before GENESIS (wait)"));
        vm.warp(GEN + 13 hours);
        _expectPreflightRevert(
            bytes("go-live: more than 12h after GENESIS; set ACCEPT_GENESIS_SLIP_SECS >= the slip to proceed")
        );
        _setU("ACCEPT_GENESIS_SLIP_SECS", 13 hours);
        this.preflightExt(deployer); // declared slip passes
        vm.warp(GEN + 49 hours); // the opening accumulation window has closed
        _expectPreflightRevert(
            bytes("go-live: more than 12h after GENESIS; set ACCEPT_GENESIS_SLIP_SECS >= the slip to proceed")
        );
        _setU("ACCEPT_GENESIS_SLIP_SECS", 49 hours);
        this.preflightExt(deployer);
    }

    // ── (12) a re-run after an interrupted funding funds only the shortfall ──
    function test_rerunAfterInterruptedFunding_fundsOnlyTheShortfall() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        // the interrupted first broadcast: the withdraw and the WETH transfer landed, then half the QPULL, then stop
        ILaunchNft(nftT).withdrawProceeds();
        vm.startPrank(deployer);
        ILaunchWeth(wethT).deposit{ value: BUCKET }();
        IERC20(wethT).transfer(lockT, BUCKET);
        IERC20(qpullT).transfer(lockT, SUPPLY / 2);
        vm.stopPrank();
        uint256 ethBefore = deployer.balance;

        vm.recordLogs();
        _runGoLive();
        SeededEv memory e = _seededEvent();
        assertEq(ethBefore - deployer.balance, 0, "no second LP_ETH_WEI was wrapped");
        assertApproxEqRel(e.wethConsumed, BUCKET, 0.005e18, "the seed consumed the single funding");
        assertApproxEqRel(e.qpullConsumed, SUPPLY, 0.005e18, "and the whole supply");
        assertLt(IERC20(wethT).balanceOf(lockT), BUCKET / 100, "no stranded LP_ETH_WEI in the lock");
    }

    /// INVERTED. This used to assert that a lock holding more WETH than LP_ETH_WEI was
    /// refused in preflight, which let ANY stranger block the scripted go-live by donating more than bucket +
    /// max(bucket, 1 ether) to the public LOCK address (LP_TOPUP_WEI could never catch up). Now the excess is simply
    /// not seeded: the seed still declares and consumes exactly LP_ETH_WEI at the LP_ETH_WEI : supply price, and the
    /// donation strands in the lock. test/GoLivePartialBroadcast.t.sol proves the price and the consumption are
    /// identical to an undonated launch for any donation size.
    function test_lockHoldingMoreWethThanDeclared_goesLive_excessStrands() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        vm.startPrank(deployer);
        ILaunchWeth(wethT).deposit{ value: BUCKET + 1 }();
        IERC20(wethT).transfer(lockT, BUCKET + 1);
        vm.stopPrank();
        this.preflightExt(deployer); // no longer refused
        vm.recordLogs();
        _runGoLive();
        SeededEv memory e = _seededEvent();
        (uint160 expP, uint128 expL) = LpSizing.sizeFor(qpullT, SUPPLY, wethT, BUCKET, -887_220, 887_220);
        assertEq(e.sqrtPriceX96, expP, "priced off LP_ETH_WEI, not the lock's balance");
        assertEq(e.liquidity, expL, "sized off LP_ETH_WEI, not the lock's balance");
        assertEq(IERC20(wethT).balanceOf(lockT), BUCKET + 1 - e.wethConsumed, "the 1 wei excess (plus dust) strands");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "and the launch completed");
    }

    /// The interrupted broadcast GoLiveMainnetResume exists for: caps armed, lock funded and seeded, no lockRouting.
    function _seedWithoutLockRouting() internal {
        GL memory g = _env();
        _preflight(g, deployer);
        _size(g, QpullLiquidityLock(lockT), SUPPLY);
        ILaunchNft(nftT).withdrawProceeds();
        vm.startPrank(deployer);
        Treasury(payable(treasuryT)).setMaxConvertPerCall(g.maxConvertPerCall);
        Treasury(payable(treasuryT)).setMaxWethConvertPerCall(g.maxWethConvertPerCall);
        ILaunchWeth(wethT).deposit{ value: BUCKET }();
        IERC20(wethT).transfer(lockT, BUCKET);
        IERC20(qpullT).transfer(lockT, SUPPLY);
        QpullLiquidityLock(lockT).seed(g.sqrtPriceX96, g.liq, SUPPLY, BUCKET);
        vm.stopPrank();
    }

    // ── (13) recovery: seed landed, lockRouting did not ──
    function test_resume_afterSeedWithoutLockRouting() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _seedWithoutLockRouting();
        assertFalse(Treasury(payable(treasuryT)).routingLocked(), "the interrupted state: seeded, not locked");

        vm.expectRevert(bytes("go-live: the lock has already been seeded (run --tc GoLiveMainnetResume)"));
        this.preflightExt(deployer); // GoLiveMainnet refuses to run again

        _resume(_env(), deployer); // GoLiveMainnetResume.run() body, with the broadcaster as tx.origin
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "resume verified, rehearsed and locked");
        assertEq(IERC20(quotronT).balanceOf(prizeT), 0, "resume rehearsal reverted");
    }

    // ── (14) LpSizing names the out-of-range ratio instead of an empty FullMath revert ──
    function test_lpSizing_namedPriceOutOfRange() public {
        _deploy(_opts(QPULL_HI));
        vm.expectRevert(LpSizing.PriceOutOfRange.selector);
        this.sizeExt(21);
        vm.expectRevert(LpSizing.PriceOutOfRange.selector);
        this.sizeExt(54_210_108);
        this.sizeExt(54_210_109); // no revert: amount1 / amount0 < 2**64
    }

    // ── (15) dust on the public WETH->QUOTRON adapter cannot block go-live ──
    // Before: the rehearsal required the adapter to hold exactly 0 WETH and 0 ETH, so 1 wei of either, sent by
    // anyone to an address that is public from the moment Deploy runs, reverted GoLiveMainnet forever on a correct
    // config. Now the check is before/after, and the dust is simply left where the stranger put it.
    function test_dustOnWethQuotronAdapter_doesNotBlockGoLive() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _dustAdapter();

        _runGoLive();
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "go-live completed despite the dust");
        assertEq(IERC20(wethT).balanceOf(wqT), 1, "the stranger's WETH dust is untouched");
        assertEq(wqT.balance, 1, "the stranger's ETH dust is untouched");
    }

    // ── (15b) ...and the delta check still catches a convert() that strands value in the adapter, dust or not ──
    function test_rehearsal_stillCatchesValueLeftInTheAdapter() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _dustAdapter();
        this.preflightExt(deployer); // every structural check passes
        StubQuotronRouter(routerT).setMode(4); // half the ETH comes back to the adapter as WETH and stays there
        vm.expectRevert(bytes("go-live: rehearsed convert() left WETH/ETH in the WETH->QUOTRON adapter"));
        this.goLiveExt(deployer);
        assertFalse(Treasury(payable(treasuryT)).routingLocked(), "routing was never frozen");
    }

    function _dustAdapter() internal {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 2);
        vm.startPrank(stranger);
        ILaunchWeth(wethT).deposit{ value: 1 }();
        IERC20(wethT).transfer(wqT, 1); // plain ERC20 transfer; the adapter has no WETH sweep
        (bool ok,) = wqT.call{ value: 1 }(""); // its open receive()
        vm.stopPrank();
        assertTrue(ok, "adapter accepts ETH");
    }

    // ── (16) the scripted recovery cannot be blocked by a QPULL donation or deployer dust ──
    // Before: the rehearsal's convert(0, 1) ran the QPULL leg with minWethOut == 0 once the Treasury held
    // >= convertThreshold QPULL (QpullWethAdapter: MinOutRequired), and _assertSeeded required deployer QPULL == 0.
    // Now the rehearsal is convert(1, 1), which EXERCISES the QPULL leg on the donation, and resume proves the
    // seed from the lock-owned position alone.
    function test_resume_notBlockedByQpullDonationDeployerDustOrAdapterDust() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _seedWithoutLockRouting();
        // stand-ins for post-seed buyers (the whole supply is in the pool, so MockERC20.mint models the transfers)
        ILaunchMintable(qpullT).mint(treasuryT, 1000e18); // == convertThreshold: the QPULL leg will run
        ILaunchMintable(qpullT).mint(deployer, 1); // 1 wei of QPULL to the deployer
        _dustAdapter();

        vm.recordLogs();
        _resume(_env(), deployer);
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "resume completed");
        assertEq(IERC20(qpullT).balanceOf(treasuryT), 1000e18, "the rehearsal's QPULL sale was reverted");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Converted(uint256,uint256,uint256,uint256)");
        uint256 qpullIn;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == treasuryT && logs[i].topics[0] == sig) {
                (qpullIn,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
        assertEq(qpullIn, 1000e18, "the rehearsal exercised the QPULL leg on the donation");
    }

    // ── (17) the other interrupted-funding case: a wrap that landed without its transfer is not wrapped twice ──
    function test_rerunAfterWrapWithoutTransfer_usesTheDeployersWeth() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        ILaunchNft(nftT).withdrawProceeds();
        vm.prank(deployer);
        ILaunchWeth(wethT).deposit{ value: BUCKET }(); // the interrupted run: WETH.deposit landed, the transfer did not
        vm.deal(deployer, 1 ether); // and the key no longer has a second LP_ETH_WEI of ETH
        uint256 ethBefore = deployer.balance;

        vm.recordLogs();
        _runGoLive(); // before: "deployer ETH < the WETH still to fund"
        assertEq(deployer.balance, ethBefore, "no new ETH was wrapped");
        assertEq(IERC20(wethT).balanceOf(deployer), 0, "the deployer's WETH went to the lock");
        assertApproxEqRel(_seededEvent().wethConsumed, BUCKET, 0.005e18, "and seeded exactly one LP_ETH_WEI");
    }

    // ── (18) the engine<->vault graph is checked BEFORE lockRouting freezes the vaults ──
    function test_engineGraph_enginesNotLocked_refused() public {
        Opts memory o = _opts(QPULL_HI);
        o.engineMode = 1;
        _deploy(o);
        _setEnv(BUCKET);
        _expectPreflightRevert(bytes("go-live: ClaimManager engines are not locked"));
    }

    /// A transposed engine graph is refused twice over, and a ClaimManager change altered WHICH refusal lands first.
    /// `ClaimManager.lockEngines` now asks each engine what vault it actually holds, so this graph can no
    /// longer be frozen at all (pinned in ClaimManager.t.sol). The only way it can still reach go-live is
    /// UNLOCKED, and the preflight refuses that on its own gate, which is what this test now pins.
    /// The preflight's more specific "does not bind RaffleEngine to PRIZE_VAULT" message is consequently
    /// unreachable with a real RaffleEngine and a locked map. It is deliberately kept as defence in depth:
    /// it still covers a map locked by an older ClaimManager, and an engine that cannot answer `vault()`
    /// for the contract to cross-check.
    function test_engineGraph_raffleOnWrongVault_refused() public {
        Opts memory o = _opts(QPULL_HI);
        o.engineMode = 2;
        _deploy(o);
        _setEnv(BUCKET);
        _expectPreflightRevert(bytes("go-live: ClaimManager engines are not locked"));
    }

    function test_engineGraph_vaultNotControlledByClaimManager_refused() public {
        Opts memory o = _opts(QPULL_HI);
        o.engineMode = 3;
        _deploy(o);
        _setEnv(BUCKET);
        _expectPreflightRevert(bytes("go-live: HOLDER_VAULT.controller != ClaimManager"));
    }

    // ── (19) a raise whose LP bucket is under 1 ether goes live by topping up to the floor ──
    // 25-pass reserve + 2 paid passes at 0.25 ETH: an exact LP bucket of 0.4 ETH, below the 1 ether floor. Before,
    // LP_TOPUP_WEI <= bucket capped the pool at 0.8 ETH, so nothing could pass the floor without a script change.
    function test_smallRaise_topsUpToTheFloor() public {
        Opts memory o = _opts(QPULL_HI);
        o.price = 0.25 ether;
        o.paid = 2;
        _deploy(o);
        uint256 bucket = 0.4 ether;
        _setEnv(bucket);
        _expectPreflightRevert(bytes("go-live: LP_ETH_WEI below 1 ether (it is WEI: 21 ether = 21000000000000000000)"));
        _setEnv(1 ether + 0.4 ether + 1);
        _setU("LP_TOPUP_WEI", 1 ether + 1);
        _expectPreflightRevert(bytes("go-live: LP_TOPUP_WEI exceeds both the mint's own LP bucket and the 1 ether floor"));
        _setEnv(1 ether);
        _setU("LP_TOPUP_WEI", 0.6 ether);
        vm.recordLogs();
        _runGoLive();
        assertApproxEqRel(_seededEvent().wethConsumed, 1 ether, 0.005e18, "seeded the 0.4 ETH bucket + 0.6 ETH top-up");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "and went live");
    }
}
