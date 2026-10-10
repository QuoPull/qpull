// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "../../src/utils/NonRenounceableOwnable2Step.sol";
import { IPoolManager, PoolKey, Currency } from "../../src/interfaces/IPoolManager.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import { Treasury } from "../../src/Treasury.sol";
import { PackRegistry } from "../../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../../src/LeaderboardRegistry.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { ClaimManager } from "../../src/ClaimManager.sol";
import { HolderDrawEngine } from "../../src/HolderDrawEngine.sol";
import { LeaderboardEngine } from "../../src/LeaderboardEngine.sol";
import { TransferOwnership, VerifyOwnership } from "../../script/TransferOwnership.s.sol";

/// Per-test env for the scripts' env seam (the process environment is shared by concurrent tests).
contract HandoverEnv {
    mapping(bytes32 => address) internal _a;
    mapping(bytes32 => bytes32) internal _b;

    function setA(string memory k, address v) external {
        _a[keccak256(bytes(k))] = v;
    }

    function setB(string memory k, bytes32 v) external {
        _b[keccak256(bytes(k))] = v;
    }

    function getA(string memory k) external view returns (address v) {
        v = _a[keccak256(bytes(k))];
        require(v != address(0), string.concat("HandoverEnv: unset ", k));
    }

    function getB(string memory k) external view returns (bytes32) {
        return _b[keccak256(bytes(k))];
    }
}

/// The REAL TransferOwnership / VerifyOwnership, reading env through the seam instead of the process environment.
contract HandoverStage is TransferOwnership {
    HandoverEnv internal immutable env;

    constructor(HandoverEnv e) {
        env = e;
    }

    function _envAddress(string memory k) internal view override returns (address) {
        return env.getA(k);
    }

    function _envBytes32(string memory k) internal view override returns (bytes32) {
        return env.getB(k);
    }

    /// @dev This harness runs on chain id 4663 against the HandoverSafe stand-in, which cannot carry the canonical Safe
    ///      1.4.1 proxy/singleton code the script pins there. The pin itself is exercised against a REAL Safe on a
    ///      4663 fork in test/fork/SafePinFork.t.sol; every other gate check still runs here.
    function _checkSafeCode(address) internal view override { }
}

contract HandoverGate is VerifyOwnership {
    HandoverEnv internal immutable env;

    constructor(HandoverEnv e) {
        env = e;
    }

    function _envAddress(string memory k) internal view override returns (address) {
        return env.getA(k);
    }

    function _envBytes32(string memory k) internal view override returns (bytes32) {
        return env.getB(k);
    }

    /// @dev This harness runs on chain id 4663 against the HandoverSafe stand-in, which cannot carry the canonical Safe
    ///      1.4.1 proxy/singleton code the script pins there. The pin itself is exercised against a REAL Safe on a
    ///      4663 fork in test/fork/SafePinFork.t.sol; every other gate check still runs here.
    function _checkSafeCode(address) internal view override { }
}

/// Gnosis-Safe stand-in: answers the shape queries and can execute the batched acceptOwnership().
contract HandoverSafe {
    address[] internal _owners;
    uint256 internal _threshold;

    constructor(address[] memory o, uint256 t) {
        _owners = o;
        _threshold = t;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function exec(address to, bytes calldata data) external {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

contract HandoverRenderer {
    bool public locked = true;

    function setLocked(bool v) external {
        locked = v;
    }
}

/// The NFT slot of the migration set only needs to be a real Ownable2Step (mainnet forbids the NOT_OWNABLE hatch)
/// that answers what QpullTaxHook.afterInitialize, HolderDrawEngine's constructor and the gate read.
contract HandoverOwnableNft is NonRenounceableOwnable2Step {
    address public taxHook;
    address public renderer;

    constructor(address o) Ownable(o) {
        renderer = address(new HandoverRenderer());
    }

    function launched() external pure returns (bool) {
        return true;
    }

    function MIN_HOLD() external pure returns (uint256) {
        return 4;
    }

    function setTaxHook(address h) external {
        taxHook = h;
    }
}

/// The hook's `initializer` on mainnet is QpullLiquidityLock, whose immutable `opener` is the deployer. The gate
/// derives the deployer from exactly that getter; this stand-in exposes it and creates the pool.
contract HandoverInitializer {
    address public opener;

    constructor(address o) {
        opener = o;
    }

    function init(address pm, PoolKey calldata key) external {
        IPoolManager(pm).initialize(key, 79_228_162_514_264_337_593_543_950_336);
    }
}

/// @notice Pins the fix for "LEADERBOARD_ENGINE / HOLDER_ENGINE are typed from env and never cross-checked",
///         together with the related checks at the same gate: the write-once non-Ownable roles, the
///         pinned keeper, the derived deployer and the Safe address bound into SAFE_OWNERS_HASH.
///
///         The real protocol graph is deployed from artifacts and wired as Deploy.s.sol wires it (every write-once
///         role, engines bound and locked in ClaimManager, routing locked, pool created so launchTime != 0, exactly
///         one keeper). Then the REAL script entry points run: `TransferOwnership.run()` (preflight + staging,
///         simulated broadcast from the deployer) and `VerifyOwnership.run()` (the gate).
contract OwnershipEngineEnvUncheckedTest is Test {
    uint256 constant GENESIS = 1_000_000;
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC

    address deployer = DEFAULT_SENDER; // tx.origin of this test == the broadcaster of TransferOwnership.run()

    HandoverSafe safe;
    address[] owners;
    Treasury treasury;
    PackRegistry packs;
    LeaderboardRegistry lbReg;
    HandoverOwnableNft nft;
    BaseVault prizeVault;
    BaseVault holderVault;
    BaseVault lbVault;
    address qpullWethAdapter;
    address wethQuotronAdapter;
    address raffle;
    ClaimManager claimMgr;
    HolderDrawEngine holderEng; // LIVE, bound in ClaimManager
    LeaderboardEngine lbEng; // LIVE, bound in ClaimManager
    address hookAddr;
    address keeperBot;
    HandoverEnv env;

    function setUp() public {
        vm.chainId(4663); // RH mainnet id: the NOT_OWNABLE hatch is forbidden here and is not used
        vm.warp(GENESIS);
        keeperBot = makeAddr("keeperBot");
        address oracle = deployCode("MockDrandOracle.sol:MockDrandOracle", abi.encode(GENESIS, uint256(30)));
        address qpull = deployCode("MockERC20.sol:MockERC20");
        address weth = deployCode("MockERC20.sol:MockERC20");
        address quotron = deployCode("MockERC20.sol:MockERC20");
        address pm = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        HandoverInitializer initializer = new HandoverInitializer(deployer);

        vm.startPrank(deployer);
        treasury = Treasury(payable(deployCode("Treasury.sol:Treasury", abi.encode(qpull, weth, quotron, deployer))));
        prizeVault = BaseVault(deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, deployer)));
        holderVault = BaseVault(deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, deployer)));
        lbVault = BaseVault(deployCode("BaseVault.sol:BaseVault", abi.encode(quotron, deployer)));
        claimMgr = ClaimManager(deployCode("ClaimManager.sol:ClaimManager", abi.encode(deployer)));
        packs = PackRegistry(
            deployCode("PackRegistry.sol:PackRegistry", abi.encode(oracle, uint256(3e15), GENESIS, uint256(1 hours), deployer))
        );
        lbReg = LeaderboardRegistry(deployCode("LeaderboardRegistry.sol:LeaderboardRegistry", abi.encode(GENESIS, deployer)));
        nft = new HandoverOwnableNft(deployer);
        raffle = deployCode(
            "RaffleEngine.sol:RaffleEngine",
            abi.encode(oracle, address(packs), address(prizeVault), address(claimMgr), GENESIS, uint256(3), uint256(1), uint256(1000e18), uint256(1000), deployer)
        );
        holderEng = HolderDrawEngine(
            deployCode(
                "HolderDrawEngine.sol:HolderDrawEngine",
                abi.encode(oracle, address(nft), address(holderVault), address(claimMgr), GENESIS, uint256(1000e18), uint256(1000e18), uint256(1e18), deployer)
            )
        );
        lbEng = LeaderboardEngine(
            deployCode(
                "LeaderboardEngine.sol:LeaderboardEngine",
                abi.encode(address(lbReg), address(lbVault), address(claimMgr), GENESIS, uint256(1e18), uint256(1000e18), deployer)
            )
        );
        qpullWethAdapter = deployCode("QpullWethAdapter.sol:QpullWethAdapter", abi.encode(pm, qpull, weth, deployer));
        wethQuotronAdapter = deployCode(
            "QuotronRouterAdapter.sol:QuotronRouterAdapter", abi.encode(makeAddr("quotronRouter"), weth, quotron, deployer)
        );
        vm.stopPrank();

        hookAddr = address(uint160((0x0B0B << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: pm,
                    qpull: qpull,
                    weth: weth,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: address(treasury),
                    packRegistry: address(packs),
                    leaderboardRegistry: address(lbReg),
                    nft: address(nft),
                    exemptSender: qpullWethAdapter,
                    initializer: address(initializer),
                    earlyBuyCapWei: 0.25 ether
                })
            ),
            hookAddr
        );

        // ── wiring, exactly as Deploy.s.sol / GoLiveMainnet leave it (xpRecorder is left to _wireXp) ──
        vm.startPrank(deployer);
        packs.setRecorder(hookAddr);
        packs.setEngine(raffle);
        packs.setNft(address(nft));
        packs.setLeaderboard(address(lbReg));
        lbReg.setRecorder(hookAddr);
        nft.setTaxHook(hookAddr);
        prizeVault.setController(address(claimMgr));
        holderVault.setController(address(claimMgr));
        lbVault.setController(address(claimMgr));
        claimMgr.setEngine(raffle, address(prizeVault));
        claimMgr.setEngine(address(holderEng), address(holderVault));
        claimMgr.setEngine(address(lbEng), address(lbVault));
        address[] memory engs = new address[](3);
        address[] memory vlts = new address[](3);
        (engs[0], engs[1], engs[2]) = (raffle, address(lbEng), address(holderEng));
        (vlts[0], vlts[1], vlts[2]) = (address(prizeVault), address(lbVault), address(holderVault));
        claimMgr.lockEngines(engs, vlts);
        treasury.setAdapters(qpullWethAdapter, wethQuotronAdapter);
        treasury.setRouting(address(prizeVault), address(holderVault), address(lbVault), makeAddr("team"));
        treasury.setMaxConvertPerCall(1_000_000e18);
        treasury.setMaxWethConvertPerCall(10e18);
        treasury.setKeeper(keeperBot, true);
        treasury.lockRouting(
            qpullWethAdapter, wethQuotronAdapter, address(prizeVault), address(holderVault), address(lbVault), makeAddr("team")
        );
        (bool ok1,) = qpullWethAdapter.call(abi.encodeWithSignature("setTreasury(address)", address(treasury)));
        (bool ok2,) = wethQuotronAdapter.call(abi.encodeWithSignature("setTreasury(address)", address(treasury)));
        require(ok1 && ok2, "adapter setTreasury");
        vm.stopPrank();
        (address c0, address c1) = qpull < weth ? (qpull, weth) : (weth, qpull);
        initializer.init(pm, PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, hookAddr));

        for (uint256 i; i < 3; ++i) owners.push(makeAddr(string.concat("signer", vm.toString(i))));
        safe = new HandoverSafe(owners, 2);

        env = new HandoverEnv();
        env.setA("SAFE", address(safe));
        env.setA("HOOK", hookAddr);
        env.setA("KEEPER", keeperBot);
        env.setB("SAFE_OWNERS_HASH", keccak256(abi.encode(address(safe), owners, uint256(2))));
        env.setA("LEADERBOARD_ENGINE", address(lbEng));
        env.setA("HOLDER_ENGINE", address(holderEng));
        // DEPLOYER is no longer an input at all: the gate derives it from the lock's `opener` (HandoverEnv would revert
        // "unset DEPLOYER" if the scripts still read it).
    }

    function _wireXp() internal {
        vm.prank(deployer);
        lbReg.setXpRecorder(address(packs));
    }

    function _all13() internal view returns (address[13] memory a) {
        a = [
            address(treasury),
            address(packs),
            address(lbReg),
            address(nft),
            address(prizeVault),
            address(holderVault),
            address(lbVault),
            qpullWethAdapter,
            wethQuotronAdapter,
            raffle,
            address(claimMgr),
            address(lbEng),
            address(holderEng)
        ];
    }

    function _acceptAsSafe(address target) internal {
        safe.exec(target, abi.encodeWithSignature("acceptOwnership()"));
    }

    function _migrateAll() internal {
        assertEq(tx.origin, deployer, "the script's broadcaster is the deployer");
        new HandoverStage(env).run();
        address[13] memory a = _all13();
        for (uint256 i; i < 13; ++i) _acceptAsSafe(a[i]);
    }

    /// (0) control: the correct env migrates all thirteen and the gate passes, with the LIVE engines on the Safe.
    function test_correctEnv_fullHandover_gatePasses() public {
        _wireXp();
        _migrateAll();
        new HandoverGate(env).run();
        assertEq(lbEng.owner(), address(safe), "LIVE LeaderboardEngine migrated");
        assertEq(holderEng.owner(), address(safe), "LIVE HolderDrawEngine migrated");
    }

    /// (1) orphan engines from an aborted/re-run Deploy broadcast, typed into env: the preflight refuses them before
    ///     anything is staged, and the gate refuses them after a real migration.
    function test_orphanEnginesInEnv_refusedByPreflightAndGate() public {
        _wireXp();
        vm.startPrank(deployer);
        address orphanLb = deployCode(
            "LeaderboardEngine.sol:LeaderboardEngine",
            abi.encode(address(lbReg), address(lbVault), address(claimMgr), GENESIS, uint256(1e18), uint256(1000e18), deployer)
        );
        address orphanHolder = deployCode(
            "HolderDrawEngine.sol:HolderDrawEngine",
            abi.encode(makeAddr("oracle2"), address(nft), address(holderVault), address(claimMgr), GENESIS, uint256(1000e18), uint256(1000e18), uint256(1e18), deployer)
        );
        vm.stopPrank();

        HandoverStage stage = new HandoverStage(env);
        env.setA("LEADERBOARD_ENGINE", orphanLb);
        vm.expectRevert(bytes("own: LEADERBOARD_ENGINE is not the engine ClaimManager binds to the leaderboard vault"));
        stage.run();
        env.setA("LEADERBOARD_ENGINE", address(lbEng));
        env.setA("HOLDER_ENGINE", orphanHolder);
        vm.expectRevert(bytes("own: HOLDER_ENGINE is not the engine ClaimManager binds to the holder vault"));
        stage.run();
        assertEq(lbEng.pendingOwner(), address(0), "nothing was staged");

        // a real migration, then the gate is handed the orphans (both Safe-owned, to make the lie maximal)
        env.setA("HOLDER_ENGINE", address(holderEng));
        _migrateAll();
        vm.startPrank(deployer);
        Ownable(orphanLb).transferOwnership(address(safe));
        Ownable(orphanHolder).transferOwnership(address(safe));
        vm.stopPrank();
        _acceptAsSafe(orphanLb);
        _acceptAsSafe(orphanHolder);
        HandoverGate gate = new HandoverGate(env);
        env.setA("LEADERBOARD_ENGINE", orphanLb);
        env.setA("HOLDER_ENGINE", orphanHolder);
        vm.expectRevert(bytes("own: LEADERBOARD_ENGINE is not the engine ClaimManager binds to the leaderboard vault"));
        gate.run();
    }

    /// (2) the gate alone: a stranger's `new ClaimManager(SAFE)` decoys, or the migrated ClaimManager named for BOTH
    ///     engines, no longer pass.
    function test_strangerDecoysOrDuplicates_refusedByGate() public {
        _wireXp();
        _migrateAll();

        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        address decoy1 = deployCode("ClaimManager.sol:ClaimManager", abi.encode(address(safe)));
        address decoy2 = deployCode("ClaimManager.sol:ClaimManager", abi.encode(address(safe)));
        vm.stopPrank();

        HandoverGate gate = new HandoverGate(env);
        env.setA("LEADERBOARD_ENGINE", decoy1);
        env.setA("HOLDER_ENGINE", decoy2);
        vm.expectRevert(bytes("own: LEADERBOARD_ENGINE is not the engine ClaimManager binds to the leaderboard vault"));
        gate.run();

        env.setA("LEADERBOARD_ENGINE", address(claimMgr));
        env.setA("HOLDER_ENGINE", address(claimMgr));
        vm.expectRevert(bytes("own: duplicate instance in the migration set"));
        gate.run();

        env.setA("LEADERBOARD_ENGINE", address(lbEng));
        env.setA("HOLDER_ENGINE", address(holderEng));
        gate.run(); // control: the correct engines pass
    }

    /// (3) the write-once, non-Ownable roles are part of the same gate.
    function test_writeOnceRoles_refused() public {
        vm.prank(deployer);
        lbReg.setXpRecorder(makeAddr("rogueXpRecorder"));
        HandoverStage stage = new HandoverStage(env);
        vm.expectRevert(bytes("own: LeaderboardRegistry.xpRecorder != PackRegistry"));
        stage.run();
        HandoverGate gate = new HandoverGate(env);
        vm.expectRevert(bytes("own: LeaderboardRegistry.xpRecorder != PackRegistry"));
        gate.run();
    }

    function test_nftBindings_refused() public {
        _wireXp();
        HandoverStage stage = new HandoverStage(env);
        nft.setTaxHook(makeAddr("otherHook"));
        vm.expectRevert(bytes("own: NFTCollection.taxHook != HOOK"));
        stage.run();
        nft.setTaxHook(hookAddr);
        HandoverRenderer(nft.renderer()).setLocked(false);
        vm.expectRevert(bytes("own: NFTCollection.renderer is not locked"));
        stage.run();
    }

    /// (4) the keeper is pinned, and the deployer is derived rather than typed.
    function test_keeperPin_refused() public {
        _wireXp();
        HandoverStage stage = new HandoverStage(env);
        env.setA("KEEPER", makeAddr("someOtherKeeper"));
        vm.expectRevert(bytes("own: KEEPER is not a Treasury keeper"));
        stage.run();
        env.setA("KEEPER", keeperBot);
        vm.prank(deployer);
        treasury.setKeeper(deployer, true);
        vm.expectRevert(bytes("own: deployer is STILL a Treasury keeper"));
        stage.run();
        vm.prank(deployer);
        treasury.setKeeper(deployer, false);
        vm.prank(deployer);
        treasury.setKeeper(makeAddr("secondKeeper"), true);
        vm.expectRevert(bytes("own: Treasury must have EXACTLY ONE keeper"));
        stage.run();
    }

    /// (5) SAFE_OWNERS_HASH binds the Safe's address: a lookalike returning the same signer set does not match.
    function test_lookalikeSafe_refused() public {
        _wireXp();
        HandoverSafe lookalike = new HandoverSafe(owners, 2);
        env.setA("SAFE", address(lookalike));
        HandoverStage stage = new HandoverStage(env);
        vm.expectRevert(
            bytes("own: SAFE address/owners/threshold do not match SAFE_OWNERS_HASH (wrong Safe, or it changed)")
        );
        stage.run();
    }
}
