// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NonceAwareDeploy } from "../utils/NonceAwareDeploy.sol";

import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../../src/QpullLiquidityLock.sol";
import { IPoolManager as ourIPM } from "../../src/interfaces/IPoolManager.sol";
import { LpSizing } from "../../script/LpSizing.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockNFT } from "../mocks/MockNFT.sol";
import { MockRecorder } from "../mocks/MockRecorder.sol";

/// @title  The launch seed against ROBINHOOD'S OWN DEPLOYED PoolManager
///
/// @notice `test/LaunchSeedIntegration.t.sol` proves this code against the PoolManager built from
///         `lib/v4-core`. That leaves exactly one question open, and it is the question the whole launch
///         turns on: **is the contract deployed at `0x8366a3…40951` the same core?** Its runtime is 24010
///         bytes; the vendored source builds to 17111 here under `via_ir`. The gap is explained by compiler
///         settings and every selector we call is present, but "explained" is not "proven", and the hook's
///         address encodes its callback flags — if that chain's flag layout differs, the mined hook is wired
///         to nothing and the mistake is unrecoverable, because the hook is immutable.
///
///         A fork settles it without a private key, without gas, and without broadcasting anything. This is
///         the SAME bytecode a mainnet transaction would execute against.
///
/// @dev    The hook's flags are now `0x1ACC` (the WETH tax added BEFORE_SWAP, bit 7, and BEFORE_SWAP_RETURNS_DELTA,
///         bit 3). Only bits 12, 6 and 2 were evidenced on that PoolManager, by the previous testnet deployment
///         of the OLD `0x1A44` hook (bit 12 by a non-zero `launchTime()`, bits 6 and 2 by four `TaxTaken`
///         events). Bits 7 and 3 are NOT covered by that evidence, nor by this file, which never swaps. The
///         fork evidence for them is test/fork/QpullWethPoolFork.t.sol, which swaps all four kinds through a
///         0x1ACC hook on this same PoolManager (both token orders, both sell rates, PartialFill included). A
///         fresh testnet deployment should still show the same live.
///         What this adds is bits 11 and 9, which nothing had ever exercised and which are now load-bearing:
///         11 carries the entire LP gate, 9 is what refuses every liquidity removal. A successful add does NOT
///         prove 11 fired — a bit the core ignored would mean the callback never ran and the add succeeded
///         anyway — so the gate is shown REFUSING someone, asserting on the inner selector.
///
///         The pair is two fresh mock ERC20s, so the pool id is one nobody has ever created. Nothing here
///         touches the live QPULL or the live QUOTRON pool; the fork is discarded when the test ends.
contract LaunchSeedForkTest is NonceAwareDeploy {
    using StateLibrary for IV4PoolManager;
    using PoolIdLibrary for V4PoolKey;

    /// The real one, from the builders manifest. Same address on testnet, and byte-for-byte identical code.
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant SUPPLY = 1_000_000_000e18; // the real launch numbers
    uint256 constant LP_ETH = 21 ether;
    uint256 constant MAX_RESIDUAL_BPS = 50;

    IV4PoolManager pm = IV4PoolManager(POOL_MANAGER);
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder rec;
    QpullTaxHook hook;
    QpullLiquidityLock lock;

    address hookAddr = address(uint160((0xF00D << 16) | FLAGS));
    address stranger = makeAddr("strangerLp");

    function setUp() public {
        vm.createSelectFork(RPC);
        // Guard the premise of the whole file: if there is no code here, every assertion below is vacuous.
        assertGt(POOL_MANAGER.code.length, 0, "no PoolManager at the manifest address on this fork");

        liqRouter = new PoolModifyLiquidityTest(pm);
        qpull = new MockERC20();
        weth = new MockERC20();
        nft = new MockNFT(); // launched() true by default; afterInitialize refuses otherwise
        rec = new MockRecorder();

        address predictedLock = _predictCreateAfterDeployCodeTo(1);
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: POOL_MANAGER,
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: makeAddr("treasury"),
                    packRegistry: address(rec),
                    leaderboardRegistry: address(rec),
                    nft: address(nft),
                    exemptSender: makeAddr("adapter"),
                    initializer: predictedLock,
                    earlyBuyCapWei: 0.25 ether
                })
            ),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);
        lock = new QpullLiquidityLock(
            ourIPM(POOL_MANAGER), address(qpull), address(weth), FEE, TICK_SPACING, hookAddr, address(this)
        );
        assertEq(address(lock), predictedLock, "the CREATE prediction the whole deploy rests on");
    }

    function _key() internal view returns (V4PoolKey memory) {
        bool q0 = address(qpull) < address(weth);
        return V4PoolKey({
            currency0: V4Currency.wrap(q0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(q0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });
    }

    function _seed() internal returns (uint160 sqrtP, uint128 liq) {
        qpull.mint(address(lock), SUPPLY);
        weth.mint(address(lock), LP_ETH);
        (sqrtP, liq) =
            LpSizing.sizeFor(address(qpull), SUPPLY, address(weth), LP_ETH, lock.tickLower(), lock.tickUpper());
        lock.seed(sqrtP, liq, SUPPLY, LP_ETH);
    }

    /// THE LAUNCH, on the real core. Creating the pool and seeding it in one call, with the sizing derived
    /// rather than typed, against the bytecode a mainnet transaction would actually run.
    function test_fork_atomicSeed_onRobinhoodsDeployedPoolManager() public {
        assertEq(hook.launchTime(), 0, "no pool before the seed");
        (uint160 sqrtP, uint128 liq) = _seed();

        PoolId id = _key().toId();
        (uint160 live,,,) = pm.getSlot0(id);
        assertEq(live, sqrtP, "the real PoolManager created the pool at the derived price");
        assertEq(hook.launchTime(), block.timestamp, "bit 12: afterInitialize fired on the REAL core");
        assertEq(pm.getLiquidity(id), liq, "the lock's position is the pool's whole liquidity");

        bytes32 posKey =
            Position.calculatePositionKey(address(lock), lock.tickLower(), lock.tickUpper(), bytes32(0));
        (uint128 posLiq,,) = pm.getPositionInfo(id, posKey);
        assertEq(posLiq, liq, "the position is keyed to the lock, and only the lock can ever touch it");

        // LpSizing's numbers, judged by the real core's own charge.
        uint256 qLeft = qpull.balanceOf(address(lock));
        uint256 wLeft = weth.balanceOf(address(lock));
        // Which token is currency0 changes which side rounds up, so record it: it is the only reason two
        // fixtures with identical inputs can report residuals that differ by a few thousand wei.
        emit log_named_string("QPULL is currency0", address(qpull) < address(weth) ? "true" : "false");
        emit log_named_uint("QPULL residual (wei)", qLeft);
        emit log_named_uint("WETH residual (wei)", wLeft);
        assertLe(qLeft, (SUPPLY * MAX_RESIDUAL_BPS) / 10_000, "QPULL stranded beyond dust");
        assertLe(wLeft, (LP_ETH * MAX_RESIDUAL_BPS) / 10_000, "WETH stranded beyond dust");
        assertTrue(lock.seeded(), "latched");
    }

    /// BIT 11, on the real core. Shown refusing, because a successful add proves nothing.
    function test_fork_bit11_beforeAddLiquidityFires() public {
        _seed();
        qpull.mint(stranger, 1e24);
        weth.mint(stranger, 1e24);
        vm.startPrank(stranger, stranger);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        bytes memory ret = _routerRevert(1e18);
        vm.stopPrank();
        assertTrue(
            _carries(ret, QpullTaxHook.LiquidityRestricted.selector),
            "bit 11 did NOT fire on the deployed PoolManager: the LP gate is not running"
        );
    }

    /// BIT 9, on the real core. This is the one the permanent no-removal rule rests on. The router holds no
    /// position, so a hook that never ran would surface as an arithmetic underflow instead — the selector
    /// assertion is what separates "refused by the hook" from "refused by the position math".
    function test_fork_bit9_beforeRemoveLiquidityFires() public {
        _seed();
        vm.startPrank(stranger, stranger);
        bytes memory ret = _routerRevert(-1e18);
        vm.stopPrank();
        assertTrue(
            _carries(ret, QpullTaxHook.LiquidityRemovalDisabled.selector),
            "bit 9 did NOT fire on the deployed PoolManager: liquidity removal is not actually blocked on this chain"
        );
    }

    function _routerRevert(int256 delta) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(liqRouter).call(
            abi.encodeWithSignature(
                "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)",
                _key(),
                IV4PoolManager.ModifyLiquidityParams(lock.tickLower(), lock.tickUpper(), delta, bytes32(0)),
                ""
            )
        );
        assertFalse(ok, "the call was supposed to revert");
    }

    /// v4-core nests a hook's revert inside CustomRevert.WrappedError, so search the returndata.
    function _carries(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3])
            {
                return true;
            }
        }
        return false;
    }
}
