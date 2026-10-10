// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm, stdStorage, StdStorage } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { Treasury } from "../src/Treasury.sol";
import { ISwapAdapter } from "../src/interfaces/ISwapAdapter.sol";
import { LpSizing } from "../script/LpSizing.sol";
import { GoLiveHarness, ILaunchNft, ILaunchWeth } from "./regression/GoLiveLpEthUnchecked.t.sol";

/// @notice Items B, C and E of GoLiveMainnet, against the real in-process launch stack (GoLiveHarness).
///
///         B. EVERY PARTIAL BROADCAST IS RECOVERABLE BY SCRIPT. GoLiveMainnet's broadcast on a fresh go-live is eight
///            transactions. Without `--slow` forge sends them all at once, so any subset can fail on-chain while the
///            rest land, each against the state the earlier ones left. `_sendPlan` replays exactly that: the calldata
///            is fixed from the pre-broadcast simulation, every transaction in `dropMask` is lost, every other one is
///            attempted and lands or reverts on its own. All 256 masks are driven, and each is then finished by the
///            one scripted path for the state it produced (GoLiveMainnet for unseeded + unlocked, GoLiveMainnetResume
///            otherwise). Every run must end at the SAME launch: seeded at the planned price and liquidity, routing
///            frozen, exactly one LP_ETH_WEI funded, no ETH wrapped twice. Formerly the state "seed failed,
///            lockRouting landed" had no scripted path at all, and "seeded, caps failed" could not be resumed.
///         C. NO DONATION BLOCKS OR REPRICES THE LAUNCH. WETH of any size sent to the public LOCK address, before the
///            run or between its simulation and its broadcast, and ETH forced into it: the launch completes at the
///            price and liquidity LpSizing derives from LP_ETH_WEI and the supply, consuming the same amounts; the
///            excess strands in the lock.
///         E. The go-live rehearsal now also runs convert LEG 1 (QPULL -> WETH through the fee-exempt adapter).
contract GoLivePartialBroadcastTest is GoLiveHarness {
    using StateLibrary for IV4PoolManager;
    using stdStorage for StdStorage;

    uint256 constant N_TX = 8;
    uint256 constant TX_SEED = 6;
    uint256 constant TX_LOCK_ROUTING = 7;
    uint256 constant CAP_QPULL = 5_000_000e18; // = _setEnv's MAX_CONVERT_PER_CALL
    uint256 constant CAP_WETH = 1e18; // = _setEnv's MAX_WETH_CONVERT_PER_CALL

    /// The broadcast GoLiveMainnet._goLive computes on a fresh go-live, frozen at simulation time.
    struct Plan {
        uint160 sqrtP;
        uint128 liq;
        uint256 deposit; // WETH.deposit value
        uint256 wethXfer; // WETH.transfer(lock, ...)
        uint256 qpullXfer; // QPULL.transfer(lock, ...)
    }

    function resumeExt(address me) external {
        _resume(_env(), me);
    }

    /// Mirrors _goLive/_fund on the fresh state: the bucket is still in the NFT (withdraw), the lock holds nothing,
    /// the deployer holds no WETH, so the whole LP_ETH_WEI is wrapped and sent, then 100% of supply.
    function _plan() internal returns (Plan memory p) {
        GL memory g = _env();
        _preflight(g, deployer);
        _size(g, QpullLiquidityLock(lockT), SUPPLY);
        assertTrue(g.withdrawLp, "premise: exact-anchor mode, the bucket is still in the NFT");
        assertEq(IERC20(wethT).balanceOf(lockT), 0, "premise: an empty lock");
        (p.sqrtP, p.liq) = (g.sqrtPriceX96, g.liq);
        (p.deposit, p.wethXfer, p.qpullXfer) = (BUCKET, BUCKET, IERC20(qpullT).balanceOf(deployer));
    }

    /// One non-`--slow` broadcast: every transaction not in `dropMask` is sent from the deployer and lands or reverts
    /// against whatever the earlier ones left.
    function _sendPlan(Plan memory p, uint256 dropMask) internal returns (uint256 landedMask) {
        for (uint256 i; i < N_TX; ++i) {
            if ((dropMask >> i) & 1 == 1) continue;
            address to;
            uint256 value;
            bytes memory data;
            if (i == 0) {
                (to, data) = (treasuryT, abi.encodeCall(Treasury.setMaxConvertPerCall, (CAP_QPULL)));
            } else if (i == 1) {
                (to, data) = (treasuryT, abi.encodeCall(Treasury.setMaxWethConvertPerCall, (CAP_WETH)));
            } else if (i == 2) {
                (to, data) = (nftT, abi.encodeCall(ILaunchNft.withdrawProceeds, ()));
            } else if (i == 3) {
                (to, value, data) = (wethT, p.deposit, abi.encodeCall(ILaunchWeth.deposit, ()));
            } else if (i == 4) {
                (to, data) = (wethT, abi.encodeCall(IERC20.transfer, (lockT, p.wethXfer)));
            } else if (i == 5) {
                (to, data) = (qpullT, abi.encodeCall(IERC20.transfer, (lockT, p.qpullXfer)));
            } else if (i == TX_SEED) {
                (to, data) = (lockT, abi.encodeCall(QpullLiquidityLock.seed, (p.sqrtP, p.liq, SUPPLY, BUCKET)));
            } else {
                (to, data) = (treasuryT, abi.encodeCall(Treasury.lockRouting, (adapterT, wqT, prizeT, holderT, lbT, teamT)));
            }
            vm.prank(deployer, deployer);
            (bool ok,) = to.call{ value: value }(data);
            if (ok) landedMask |= uint256(1) << i;
        }
    }

    /// The one scripted path for whatever state the partial broadcast left (GoLiveMainnet header table).
    function _recover() internal {
        bool seeded = QpullLiquidityLock(lockT).seeded();
        bool locked = Treasury(payable(treasuryT)).routingLocked();
        if (!seeded && !locked) _runGoLive();
        else _resume(_env(), deployer);
    }

    /// The finished launch, identical for every partial-broadcast history.
    function _assertLaunched(Plan memory p, uint256 ethBefore, string memory tag) internal view {
        IV4PoolManager v4 = IV4PoolManager(pm);
        PoolId id = PoolId.wrap(keccak256(abi.encode(_key())));
        (uint160 sp,,,) = v4.getSlot0(id);
        require(QpullLiquidityLock(lockT).seeded(), string.concat(tag, ": lock not seeded"));
        require(Treasury(payable(treasuryT)).routingLocked(), string.concat(tag, ": routing not locked"));
        require(QpullTaxHook(hookT).launchTime() != 0, string.concat(tag, ": launchTime not stamped"));
        require(sp == p.sqrtP, string.concat(tag, ": pool not at the planned price"));
        require(v4.getLiquidity(id) == p.liq, string.concat(tag, ": pool liquidity != one planned seed"));
        require(IERC20(qpullT).balanceOf(deployer) == 0, string.concat(tag, ": deployer still holds QPULL"));
        require(IERC20(wethT).balanceOf(deployer) == 0, string.concat(tag, ": deployer left holding WETH"));
        require(
            IERC20(wethT).balanceOf(lockT) + IERC20(wethT).balanceOf(pm) == BUCKET,
            string.concat(tag, ": the lock was not funded with exactly one LP_ETH_WEI")
        );
        // ETH conservation between the deployer and the NFT's LP bucket (`ethBefore` is their sum before anything was
        // sent): exactly one LP_ETH_WEI left them, whichever of the eight transactions landed first time.
        require(
            deployer.balance + ILaunchNft(nftT).lpReserve() == ethBefore - BUCKET,
            string.concat(tag, ": ETH wrapped twice, or the bucket went missing")
        );
    }

    // ── B. all 256 partial broadcasts converge ───────────────────────────────────────────────────────────────

    function test_B_everyPartialBroadcast_hasAScriptedRecovery_toTheSameLaunch() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        // deployer ETH + the NFT's LP bucket, before anything is sent
        uint256 ethBefore = deployer.balance + ILaunchNft(nftT).lpReserve();
        uint256 lockedWithoutSeed;
        uint256 seededWithoutLock;
        for (uint256 mask; mask < (1 << N_TX); ++mask) {
            uint256 snap = vm.snapshotState();
            uint256 landed = _sendPlan(p, mask);
            if (landed & (1 << TX_LOCK_ROUTING) != 0 && landed & (1 << TX_SEED) == 0) ++lockedWithoutSeed;
            if (landed & (1 << TX_SEED) != 0 && landed & (1 << TX_LOCK_ROUTING) == 0) ++seededWithoutLock;
            _recover();
            _assertLaunched(p, ethBefore, string.concat("dropMask ", vm.toString(mask)));
            vm.revertToState(snap);
        }
        emit log_named_uint("histories where lockRouting landed and the seed did not (was unrecoverable)", lockedWithoutSeed);
        emit log_named_uint("histories where the seed landed and lockRouting did not", seededWithoutLock);
        assertGt(lockedWithoutSeed, 0, "the exhaustive run reached the formerly unrecoverable state");
        assertGt(seededWithoutLock, 0, "and the post-seed state");
    }

    // ── B. the four states by name, in the other token order ─────────────────────────────────────────────────

    /// seed failed, lockRouting landed (only possible without --slow). GoLiveMainnet refuses and names the recovery;
    /// GoLiveMainnetResume seeds into the frozen routing and sends no second lockRouting.
    function test_B_seedFailed_lockRoutingLanded_resumeSeedsIntoFrozenRouting() public {
        _deploy(_opts(QPULL_LO));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        uint256 ethBefore = deployer.balance + ILaunchNft(nftT).lpReserve();
        // the QPULL transfer is lost, so the seed reverts on settlement; lockRouting still lands
        uint256 landed = _sendPlan(p, 1 << 5);
        assertEq(landed & (1 << TX_SEED), 0, "the seed failed on-chain");
        assertTrue(landed & (1 << TX_LOCK_ROUTING) != 0, "and lockRouting landed after it");
        assertTrue(Treasury(payable(treasuryT)).routingLocked() && !QpullLiquidityLock(lockT).seeded(), "state (F, T)");

        vm.expectRevert(bytes("go-live: Treasury routing already locked (partial broadcast: run --tc GoLiveMainnetResume)"));
        this.preflightExt(deployer);

        vm.recordLogs();
        _resume(_env(), deployer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 routingLockedSig = keccak256("RoutingLocked(address,address,address,address,address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != routingLockedSig, "no second lockRouting");
        }
        _assertLaunched(p, ethBefore, "seed failed, lockRouting landed");
    }

    /// Cap setters failed, so lockRouting reverted NotConfigured after the seed landed. Resume re-arms the caps and locks.
    function test_B_capsFailed_seedLanded_resumeArmsCapsThenLocks() public {
        _deploy(_opts(QPULL_LO));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        uint256 ethBefore = deployer.balance + ILaunchNft(nftT).lpReserve();
        uint256 landed = _sendPlan(p, (1 << 0) | (1 << 1));
        assertTrue(landed & (1 << TX_SEED) != 0, "seed landed");
        assertEq(landed & (1 << TX_LOCK_ROUTING), 0, "lockRouting reverted NotConfigured");
        assertEq(Treasury(payable(treasuryT)).maxConvertPerCall(), 0, "caps never armed");
        _resume(_env(), deployer);
        assertEq(Treasury(payable(treasuryT)).maxConvertPerCall(), CAP_QPULL, "resume armed the caps");
        _assertLaunched(p, ethBefore, "caps failed, seed landed");
    }

    /// Nothing past the funding landed: Resume refuses and names GoLiveMainnet, whose re-run completes.
    function test_B_unseededUnlocked_resumeRefuses_goLiveReruns() public {
        _deploy(_opts(QPULL_LO));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        uint256 ethBefore = deployer.balance + ILaunchNft(nftT).lpReserve();
        _sendPlan(p, (1 << TX_SEED) | (1 << TX_LOCK_ROUTING));
        vm.expectRevert(
            bytes("go-live-resume: lock unseeded and routing unlocked: nothing past the seed landed, re-run GoLiveMainnet")
        );
        this.resumeExt(deployer);
        _runGoLive();
        _assertLaunched(p, ethBefore, "funded, not seeded");
    }

    /// Everything landed: Resume verifies read-only and emits nothing.
    function test_B_complete_resumeIsReadOnly() public {
        _deploy(_opts(QPULL_LO));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        uint256 ethBefore = deployer.balance + ILaunchNft(nftT).lpReserve();
        assertEq(_sendPlan(p, 0), (1 << N_TX) - 1, "all eight landed");
        vm.recordLogs();
        _resume(_env(), deployer);
        assertEq(vm.getRecordedLogs().length, 0, "resume on a finished launch changes nothing");
        _assertLaunched(p, ethBefore, "complete");
    }

    // ── C. donations cannot block or reprice ─────────────────────────────────────────────────────────────────

    /// Any WETH donation to the lock before the run (1 wei to 10,000 ETH, far beyond bucket + max(bucket, 1 ether)),
    /// plus forced ETH: the launch completes with the same price, liquidity and consumption as an undonated launch;
    /// the deployer funds only max(0, LP_ETH_WEI - donation); the rest strands in the lock.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_C_wethDonationToLock_neverBlocksNorReprices(uint256 donation) public {
        donation = bound(donation, 1, 10_000 ether);
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _runGoLive();
        SeededEv memory base = _seededEvent();
        vm.revertToState(snap);

        address stranger = makeAddr("stranger");
        vm.deal(stranger, donation);
        vm.startPrank(stranger);
        ILaunchWeth(wethT).deposit{ value: donation }();
        IERC20(wethT).transfer(lockT, donation);
        vm.stopPrank();
        vm.deal(lockT, 7 ether); // ETH forced in (selfdestruct-style): the lock has no payable entry and never reads it
        uint256 ethBefore = deployer.balance;

        vm.recordLogs();
        _runGoLive();
        SeededEv memory e = _seededEvent();
        (uint160 expP, uint128 expL) = LpSizing.sizeFor(qpullT, SUPPLY, wethT, BUCKET, -887_220, 887_220);
        assertEq(e.sqrtPriceX96, expP, "price is LP_ETH_WEI : supply");
        assertEq(e.sqrtPriceX96, base.sqrtPriceX96, "same price as with no donation");
        assertEq(e.liquidity, base.liquidity, "same liquidity");
        assertEq(e.liquidity, expL, "the derived liquidity");
        assertEq(e.wethConsumed, base.wethConsumed, "same WETH consumed");
        assertEq(e.qpullConsumed, base.qpullConsumed, "same QPULL consumed (the whole supply, to rounding)");
        (uint160 sp,,,) = IV4PoolManager(pm).getSlot0(PoolId.wrap(keccak256(abi.encode(_key()))));
        assertEq(sp, base.sqrtPriceX96, "the live pool sits at that price");
        uint256 held = donation > BUCKET ? donation : BUCKET;
        assertEq(IERC20(wethT).balanceOf(lockT), held - e.wethConsumed, "the excess strands in the lock");
        uint256 saved = donation < BUCKET ? donation : BUCKET;
        assertEq(deployer.balance, ethBefore + saved, "the deployer funded only LP_ETH_WEI minus the donation");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "the launch completed");
    }

    /// A donation that lands BETWEEN the simulation and the broadcast (the plan's calldata is already fixed): the
    /// lock ends up over-funded, and the seed still consumes exactly the planned amounts at the planned price.
    function test_C_donationBetweenSimulationAndBroadcast_seedsThePlan() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 500 ether);
        vm.startPrank(stranger);
        ILaunchWeth(wethT).deposit{ value: 500 ether }();
        IERC20(wethT).transfer(lockT, 500 ether);
        vm.stopPrank();
        vm.recordLogs();
        assertEq(_sendPlan(p, 0), (1 << N_TX) - 1, "all eight landed despite the donation");
        SeededEv memory e = _seededEvent();
        assertEq(e.sqrtPriceX96, p.sqrtP, "the planned price");
        assertEq(e.liquidity, p.liq, "the planned liquidity");
        assertEq(IERC20(wethT).balanceOf(lockT), BUCKET + 500 ether - e.wethConsumed, "the donation strands");
        assertApproxEqRel(e.wethConsumed, BUCKET, 0.005e18, "one LP_ETH_WEI seeded");
    }

    // ── E. the rehearsal exercises convert leg 1 ─────────────────────────────────────────────────────────────

    function _converted(Vm.Log[] memory logs) internal view returns (uint256[] memory qpullIns, uint256 n) {
        bytes32 sig = keccak256("Converted(uint256,uint256,uint256,uint256)");
        qpullIns = new uint256[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == treasuryT && logs[i].topics[0] == sig) {
                (qpullIns[n++],,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
        }
    }

    /// On a fresh go-live the Treasury holds no QPULL, and the old rehearsal never reached leg 1. Now the second
    /// rehearsal sells a convertThreshold-sized QPULL slice through the real QpullWethAdapter and the seeded pool, and
    /// every effect is reverted.
    function test_E_freshGoLive_rehearsesLeg1_andLeavesNoTrace() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        vm.recordLogs();
        _runGoLive();
        (uint256[] memory ins, uint256 n) = _converted(vm.getRecordedLogs());
        assertEq(n, 2, "two rehearsed convert() calls");
        assertEq(ins[0], 0, "rehearsal 1: WETH leg only");
        assertEq(ins[1], Treasury(payable(treasuryT)).convertThreshold(), "rehearsal 2: a threshold QPULL slice through leg 1");
        uint256 pmQpull = IERC20(qpullT).balanceOf(pm);
        assertEq(IERC20(qpullT).balanceOf(treasuryT), 0, "the simulated donation was reverted");
        assertEq(IERC20(qpullT).balanceOf(adapterT), 0, "nothing left in the QPULL->WETH adapter");
        assertEq(IERC20(wethT).balanceOf(treasuryT), 0, "rehearsal WETH reverted");
        assertGt(pmQpull, 0, "the supply is in the pool");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "and routing locked after both rehearsals");
    }

    /// A leg-1 adapter that cannot sell (structurally bound correctly, so every preflight read passes) now aborts the
    /// run in simulation, before lockRouting freezes it.
    function test_E_brokenLeg1_abortsBeforeLockRouting() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        this.preflightExt(deployer);
        vm.mockCallRevert(
            adapterT, abi.encodeWithSelector(ISwapAdapter.swapExactIn.selector), abi.encodeWithSignature("Error(string)", "leg1 down")
        );
        vm.expectRevert(bytes("leg1 down"));
        this.goLiveExt(deployer);
        assertFalse(Treasury(payable(treasuryT)).routingLocked(), "routing was never frozen");
        assertFalse(QpullLiquidityLock(lockT).seeded(), "and nothing was seeded");
    }

    /// On a resume after live trading the Treasury holds a WETH tax backlog of at least one slice, which makes
    /// convert() skip leg 1. The rehearsal parks that backlog for the simulation, so it still runs leg 1 and a tax
    /// backlog cannot fail the recovery.
    function test_E_resumeWithWethBacklog_stillRehearsesLeg1() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        _sendPlan(p, 1 << TX_LOCK_ROUTING); // seeded, not locked
        address taxpayer = makeAddr("taxBacklog");
        vm.deal(taxpayer, 3 ether);
        vm.startPrank(taxpayer);
        ILaunchWeth(wethT).deposit{ value: 3 ether }();
        IERC20(wethT).transfer(treasuryT, 3 ether); // 3 slices of maxWethConvertPerCall
        vm.stopPrank();
        vm.recordLogs();
        _resume(_env(), deployer);
        (uint256[] memory ins, uint256 n) = _converted(vm.getRecordedLogs());
        assertEq(n, 2, "two rehearsed convert() calls");
        assertEq(ins[1], Treasury(payable(treasuryT)).convertThreshold(), "leg 1 ran despite the backlog");
        assertEq(IERC20(wethT).balanceOf(treasuryT), 3 ether, "the backlog is untouched after the rehearsal");
        assertTrue(Treasury(payable(treasuryT)).routingLocked(), "resume locked routing");
    }

    // ── the NFT must be wired to the hook being launched ────────────────────────────────────────────────────

    bytes constant NFT_NOT_WIRED =
        bytes("go-live: NFTCollection.taxHook() != HOOK (the NFT is not wired to this hook: the launch transfer lock would not apply)");

    /// NFTCollection.setTaxHook is write-once, so a foreign binding can only come from a redone deploy. The test reaches
    /// that state by writing the storage slot the public getter reads.
    function _rebindNftHook(address to) internal {
        stdstore.target(nftT).sig("taxHook()").checked_write(to);
        assertEq(ILaunchNft(nftT).taxHook(), to, "premise: the NFT now names a different hook");
    }

    /// Fresh go-live: an NFT never wired to any hook (Deploy's setTaxHook missing) is refused before anything is sent.
    function test_freshGoLive_refusesAnUnwiredNft() public {
        Opts memory o = _opts(QPULL_HI);
        o.nftHookMode = 1;
        _deploy(o);
        _setEnv(BUCKET);
        assertEq(ILaunchNft(nftT).taxHook(), address(0), "premise: unwired");
        _expectPreflightRevert(NFT_NOT_WIRED);
        assertFalse(QpullLiquidityLock(lockT).seeded(), "nothing seeded");
    }

    /// Fresh go-live: an NFT still bound to an older hook (a redone deploy) is refused; the correctly wired world passes.
    function test_freshGoLive_refusesAForeignHookBinding() public {
        _deploy(_opts(QPULL_LO));
        _setEnv(BUCKET);
        this.preflightExt(deployer); // wired to HOOK: passes
        _rebindNftHook(makeAddr("hookFromAnAbortedDeploy"));
        _expectPreflightRevert(NFT_NOT_WIRED);
    }

    /// Every GoLiveMainnetResume path re-checks the binding: seed failed with routing locked, seeded with routing
    /// unlocked, and the finished launch (read-only verify).
    function test_everyResumePath_refusesAForeignHookBinding() public {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        Plan memory p = _plan();
        uint256[3] memory masks = [uint256(1 << 5), uint256((1 << 0) | (1 << 1)), uint256(0)];
        string[3] memory states = ["unseeded + routing locked", "seeded + routing unlocked", "seeded + routing locked"];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            _sendPlan(p, masks[i]);
            bool seeded = QpullLiquidityLock(lockT).seeded();
            bool locked = Treasury(payable(treasuryT)).routingLocked();
            assertTrue(seeded || locked, string.concat("premise: a resume state: ", states[i]));
            _resume(_env(), deployer); // the correctly wired launch resumes (or verifies) cleanly
            vm.revertToState(snap);
            snap = vm.snapshotState();
            _sendPlan(p, masks[i]);
            _rebindNftHook(makeAddr("hookFromAnAbortedDeploy"));
            vm.expectRevert(NFT_NOT_WIRED);
            this.resumeExt(deployer);
            vm.revertToState(snap);
        }
    }
}
