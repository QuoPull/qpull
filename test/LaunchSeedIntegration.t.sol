// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NonceAwareDeploy } from "./utils/NonceAwareDeploy.sol";

// ─── the REAL Uniswap V4 core (vendored, tag v4.0.0) ─────────────────────────
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

// ─── ours ────────────────────────────────────────────────────────────────────
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { IPoolManager as ourIPM } from "../src/interfaces/IPoolManager.sol";
import { LpSizing } from "../script/LpSizing.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @title  The launch seed, against the REAL PoolManager
///
/// @notice Everything about the go-live that had never been executed against genuine v4 math. The lock's
///         own unit tests drive a StubPM that returns whatever charge the test told it to, so they can
///         prove the band's LOGIC and prove nothing at all about the NUMBERS. `script/LpSizing.sol`
///         computes the two values the whole launch consumes -- the pool's initial price and the liquidity
///         to seed -- and it had zero test coverage of any kind. If those numbers are more than 50 bps off
///         what a real full-range add costs, `seed` reverts, and on mainnet that is the launch stalling
///         with 100% of supply already inside a contract that has no way to give it back.
///
///         This exercises the production shape end to end on a real PoolManager: the hook is mined against
///         the lock's PREDICTED address, the lock is deployed at it, `LpSizing` derives the price and the
///         liquidity from the real launch amounts (21 ETH against 1e27 supply), and the lock creates the
///         pool and seeds it in one call.
///
/// @dev    It also settles the two liquidity flag bits that nothing had ever exercised. The hook's flags are now
///         `0x1ACC` (BEFORE_SWAP, bit 7, and BEFORE_SWAP_RETURNS_DELTA, bit 3, were added). Three of the seven
///         bits (12, 6 and 2) were evidenced on Robinhood's own PoolManager by the previous testnet deployment,
///         which ran the OLD `0x1A44` hook (bit 12 by a non-zero `launchTime()`, bits 6 and 2 by its `TaxTaken`
///         events). Bits 7 and 3 are NOT proven on Robinhood: test/QpullTaxHook.t.sol exercises them only
///         against vendored v4-core, and the fork suites plus a fresh testnet run are what prove them on that
///         chain. Bits 11 and 9 are not proven there either, and both are load-bearing now: 11 carries the
///         entire LP gate, and 9 is what makes the seeded liquidity unremovable. A successful ADD does not prove 11 fired -- if the bit were ignored the callback would
///         simply not run and the add would succeed anyway -- so the gate has to be shown REFUSING someone.
///         Proving them here against vendored v4-core does not prove them on Robinhood's deployed
///         PoolManager (24010 bytes there against 17111 built locally under via_ir), but it isolates the
///         question: if the testnet run then fails, the difference is that chain's core, not this code.
contract LaunchSeedIntegrationTest is NonceAwareDeploy {
    using StateLibrary for PoolManager;
    using PoolIdLibrary for V4PoolKey;

    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    /// The real launch numbers: 100% of supply against a 21 ETH LP bucket at sell-out.
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant LP_ETH = 21 ether;
    uint256 constant MAX_RESIDUAL_BPS = 50; // the lock's own band

    PoolManager manager;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder rec;
    QpullTaxHook hook;
    QpullLiquidityLock lock;

    address hookAddr = address(uint160((0x5EED << 16) | FLAGS));
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    function setUp() public {
        manager = new PoolManager(address(this));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        nft = new MockNFT(); // launched() is true by default; afterInitialize refuses otherwise
        rec = new MockRecorder();
        QpullWethAdapter adapter =
            new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));

        // THE PRODUCTION SHAPE. The hook must name the lock and the lock must name the hook: a cycle,
        // broken by predicting the lock's CREATE address, which depends only on (deployer, nonce) and never
        // on constructor arguments. deployCodeTo places the hook in between, and what that costs in nonces
        // is a property of the Foundry version (0 when this was written, 1 now), so it is MEASURED rather
        // than assumed: see test/utils/NonceAwareDeploy.sol. The assert below is the same one Deploy.s.sol makes.
        address predictedLock = _predictCreateAfterDeployCodeTo(1);
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: treasury,
                    packRegistry: address(rec),
                    leaderboardRegistry: address(rec),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: predictedLock, // a CONTRACT, not a key (the only address allowed to add liquidity)
                    earlyBuyCapWei: 0.25 ether
                })
            ),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);

        lock = new QpullLiquidityLock(
            ourIPM(address(manager)), address(qpull), address(weth), FEE, TICK_SPACING, hookAddr, address(this)
        );
        assertEq(address(lock), predictedLock, "the CREATE prediction that the whole deploy rests on");
        assertEq(hook.initializer(), address(lock), "the hook is bound to this lock, immutably");
    }

    /// The v4-core-typed twin of the lock's own `poolKey()`, for querying pool state.
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

    // ── THE LAUNCH ───────────────────────────────────────────────────────────

    /// The whole go-live, on real v4: derive the sizing, create the pool and seed it in one call, and
    /// check that what the pool actually charged matches what LpSizing said it would.
    function test_launch_atomicSeedWithDerivedSizing_onRealV4() public {
        qpull.mint(address(lock), SUPPLY);
        weth.mint(address(lock), LP_ETH);

        (uint160 sqrtP, uint128 liq) =
            LpSizing.sizeFor(address(qpull), SUPPLY, address(weth), LP_ETH, lock.tickLower(), lock.tickUpper());
        assertGt(liq, 0, "LpSizing produced no liquidity");

        assertEq(hook.launchTime(), 0, "no pool exists before the seed");
        lock.seed(sqrtP, liq, SUPPLY, LP_ETH);

        // 1. the pool was created BY the seed, at the derived price
        V4PoolKey memory key = _key();
        PoolId id = key.toId();
        (uint160 livePrice,,,) = manager.getSlot0(id);
        assertEq(livePrice, sqrtP, "pool created at the derived price");
        assertEq(hook.launchTime(), block.timestamp, "launchTime stamped when liquidity exists, not before");

        // 2. the position is the LOCK's, and it is the pool's entire liquidity
        assertEq(manager.getLiquidity(id), liq, "the lock's position is the pool's whole liquidity");
        bytes32 posKey =
            Position.calculatePositionKey(address(lock), lock.tickLower(), lock.tickUpper(), bytes32(0));
        (uint128 posLiq,,) = manager.getPositionInfo(id, posKey);
        assertEq(posLiq, liq, "the position is keyed to the lock");

        // 3. THE POINT OF THIS TEST: the derived numbers actually consumed the funded amounts. The lock's
        //    own band already refused anything worse than 50 bps, so reaching this line proves it -- but
        //    assert the residual directly too, so a regression reports the real number rather than a revert.
        uint256 qLeft = qpull.balanceOf(address(lock));
        uint256 wLeft = weth.balanceOf(address(lock));
        assertLe(qLeft, (SUPPLY * MAX_RESIDUAL_BPS) / 10_000, "QPULL stranded beyond dust");
        assertLe(wLeft, (LP_ETH * MAX_RESIDUAL_BPS) / 10_000, "WETH stranded beyond dust");
        emit log_named_string("QPULL is currency0", address(qpull) < address(weth) ? "true" : "false");
        emit log_named_uint("QPULL residual (wei)", qLeft);
        emit log_named_uint("WETH residual (wei)", wLeft);

        assertTrue(lock.seeded(), "latched");
    }

    /// The same derivation with the currency order INVERTED. Which of QPULL/WETH sorts lower on mainnet
    /// depends on the deployer's nonce and is pinned nowhere; getting it backwards inverts the launch price.
    function test_launch_derivedSizingHoldsWhenWethSortsFirst() public {
        address hiQpull = address(0xfFFF000000000000000000000000000000000FFF);
        MockERC20 template = new MockERC20();
        vm.etch(hiQpull, address(template).code);
        assertTrue(hiQpull > address(weth), "fixture must invert the sort order");

        // No +1 here, unlike script/Deploy.s.sol: there the hook goes through the CREATE2 factory, which is
        // a transaction and consumes a nonce, so the lock lands one later. `deployCodeTo` consumes none. The
        // offset is context-dependent, which is exactly why the production script ASSERTS it rather than
        // trusting it -- and why this assert is here too.
        address predicted = _predictCreateAfterDeployCodeTo(1);
        address hook2 = address(uint160((0x5EEE << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: hiQpull,
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: treasury,
                    packRegistry: address(rec),
                    leaderboardRegistry: address(rec),
                    nft: address(nft),
                    exemptSender: address(this),
                    initializer: predicted,
                    earlyBuyCapWei: 0.25 ether
                })
            ),
            hook2
        );
        QpullLiquidityLock l2 = new QpullLiquidityLock(
            ourIPM(address(manager)), hiQpull, address(weth), FEE, TICK_SPACING, hook2, address(this)
        );
        assertEq(address(l2), predicted, "prediction holds in the inverted order too");

        MockERC20(hiQpull).mint(address(l2), SUPPLY);
        weth.mint(address(l2), LP_ETH);
        (uint160 sqrtP, uint128 liq) =
            LpSizing.sizeFor(hiQpull, SUPPLY, address(weth), LP_ETH, l2.tickLower(), l2.tickUpper());

        l2.seed(sqrtP, liq, SUPPLY, LP_ETH);

        assertTrue(l2.seeded(), "the inverted-order launch seeds within the band");
        assertLe(MockERC20(hiQpull).balanceOf(address(l2)), (SUPPLY * MAX_RESIDUAL_BPS) / 10_000);
        assertLe(weth.balanceOf(address(l2)), (LP_ETH * MAX_RESIDUAL_BPS) / 10_000);
    }

    // ── THE TWO FLAG BITS NOTHING HAD EVER EXERCISED ─────────────────────────

    /// BIT 11 (`beforeAddLiquidity`). The gate has to be shown REFUSING someone: a successful add proves
    /// nothing, because a bit the core ignored would mean the callback never ran and the add succeeded
    /// anyway. A revert carrying `LiquidityRestricted` proves the callback executed.
    function test_bit11_beforeAddLiquidityFires_andRefusesEveryoneButTheLock() public {
        _seed();
        qpull.mint(stranger, 1e24);
        weth.mint(stranger, 1e24);
        vm.startPrank(stranger, stranger); // msg.sender AND tx.origin: neither is the lock
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        bytes memory ret = _expectRouterRevert(1e18);
        vm.stopPrank();
        assertTrue(
            _carries(ret, QpullTaxHook.LiquidityRestricted.selector),
            "bit 11 did not fire: no LiquidityRestricted in the revert"
        );
    }

    /// BIT 9 (`beforeRemoveLiquidity`). The permanent LP lock rests on it: if the bit does not
    /// invoke the hook, `LiquidityRemovalDisabled` is dead code and removal is possible.
    ///
    /// The router holds no position, so the two outcomes are distinguishable and that is the whole point:
    /// if the hook fires we get `LiquidityRemovalDisabled`, and if it does NOT we get an arithmetic
    /// underflow from the position math instead. Asserting on the selector separates them.
    function test_bit9_beforeRemoveLiquidityFires_forEveryone() public {
        _seed();
        vm.startPrank(stranger, stranger);
        bytes memory ret = _expectRouterRevert(-1e18);
        vm.stopPrank();
        assertTrue(
            _carries(ret, QpullTaxHook.LiquidityRemovalDisabled.selector),
            "bit 9 did not fire: removal was refused by the position math, not by the hook"
        );
    }

    /// And the identity the old gate trusted is refused too, not just a stranger.
    function test_bit9_removalIsRefusedForTheLockItselfAsWell() public {
        _seed();
        bytes memory ret = _expectRouterRevert(-1e18); // sender = this contract, the lock's opener
        assertTrue(_carries(ret, QpullTaxHook.LiquidityRemovalDisabled.selector), "no exception for anyone");
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _seed() internal {
        qpull.mint(address(lock), SUPPLY);
        weth.mint(address(lock), LP_ETH);
        (uint160 sqrtP, uint128 liq) =
            LpSizing.sizeFor(address(qpull), SUPPLY, address(weth), LP_ETH, lock.tickLower(), lock.tickUpper());
        lock.seed(sqrtP, liq, SUPPLY, LP_ETH);
    }

    /// Drive the router and hand back the raw revert data, so the assertion can be about WHICH error came
    /// out rather than merely that something reverted.
    function _expectRouterRevert(int256 delta) internal returns (bytes memory ret) {
        bool ok;
        // encodeWithSignature, not encodeCall: PoolModifyLiquidityTest overloads modifyLiquidity.
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

    /// v4-core wraps a hook's revert in CustomRevert.WrappedError, so the inner selector is nested in the
    /// returndata rather than being its first four bytes. Search for it.
    function _carries(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]
            ) return true;
        }
        return false;
    }
}
