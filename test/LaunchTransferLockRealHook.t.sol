// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { V4LpBase } from "./utils/V4LpBase.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice spec §16 launch transfer-lock, END TO END: the REAL NFTCollection wired (setTaxHook) to the REAL
///         0x1ACC QpullTaxHook on the real v4-core PoolManager, with no mock in between. LaunchTransferLock.t.sol
///         proves the NFT's lock logic against a MockTaxHook; AdvHookThrottle proves the hook writes the record.
///         This proves the two halves meet: with the exact-in buy fee taken in beforeSwap, BOTH
///         buy kinds must still write the gated-buy record the NFT reads, so a buyer's pass is stuck for the gate
///         window, a non-buyer's is not, and the lock lifts when the window closes.
///         Runs in both token orders (LaunchTransferLockRealHookFlippedTest).
contract LaunchTransferLockRealHookTest is Test, V4LpBase {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 constant MINT_PRICE = 0.1 ether;

    PoolManager manager;
    PoolSwapTest swapRouter;
    MockERC20 qpull;
    MockERC20 weth;
    NFTCollection nft;
    QpullTaxHook hook;
    address hookAddr = address(uint160((0x7A << 16) | FLAGS));
    address feeSink = makeAddr("feeSink");
    address alice = makeAddr("alice"); // exact-in buyer
    address bob = makeAddr("bob"); // exact-out buyer
    address carol = makeAddr("carol"); // holder who never buys
    address dave = makeAddr("dave"); // transfer target
    uint256 idAlice;
    uint256 idBob;
    uint256 idCarol;
    bool qpullIs0;
    V4PoolKey key;

    function _flipTokenOrder() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        if (_flipTokenOrder()) (qpull, weth) = (weth, qpull);
        qpullIs0 = address(qpull) < address(weth);

        // The real collection, minted and launched the production way.
        PassArtRenderer renderer = new PassArtRenderer(address(this));
        renderer.lock();
        nft = new NFTCollection(MINT_PRICE, address(new MockDrandOracle(block.timestamp, 3)), 1 hours, address(renderer), address(this));
        nft.setRecipients(makeAddr("lp"), makeAddr("seed"), makeAddr("team"));
        nft.setAllowlistRoot(keccak256("transfer-lock")); // non-zero root; this suite mints on the open path
        nft.setMintOpen(true);
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt());
        idAlice = _mint(alice);
        idBob = _mint(bob);
        idCarol = _mint(carol);
        nft.finalizeLaunch(); // afterInitialize refuses to open the pool until the mint is closed

        QpullWethAdapter adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: feeSink,
                    packRegistry: address(new MockRecorder()),
                    leaderboardRegistry: address(new MockRecorder()),
                    nft: address(nft), // the REAL collection: the gate reads its balanceOf
                    exemptSender: address(adapter),
                    initializer: address(this),
                    earlyBuyCapWei: 0.25 ether // the shipping cap
                })
            ),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);
        nft.setTaxHook(hookAddr); // the return leg of the wiring: the NFT's setter probes the real hook's interface

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IV4Hooks(hookAddr)
        });
        qpull.mint(address(this), 1e27);
        weth.mint(address(this), 1e27);
        _initializePool(key, SQRT_1_1); // stamps launchTime: the gate and the transfer-lock window open now
        _addLiquidity(key, -887_220, 887_220, 1e24);

        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : (i == 1 ? bob : carol);
            weth.mint(who, 10 ether);
            qpull.mint(who, 10 ether);
            vm.startPrank(who);
            weth.approve(address(swapRouter), type(uint256).max);
            qpull.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _mint(address who) internal returns (uint256 id) {
        vm.deal(who, MINT_PRICE);
        vm.prank(who);
        nft.mint{ value: MINT_PRICE }();
        id = nft.totalMinted(); // sequential ids: the newest id == the count
        assertEq(nft.ownerOf(id), who, "minted");
    }

    function _swap(address who, bool zeroForOne, int256 amt) internal {
        vm.prank(who, who); // msg.sender AND tx.origin = the holder
        swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amt, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _buyZfo() internal view returns (bool) {
        return !qpullIs0;
    }

    /// Inside the gate: an exact-in buy (kind A, fee in beforeSwap) and an exact-out buy (kind B, fee in afterSwap)
    /// each lock the buyer's pass; a holder who never bought still transfers; a SELL does not arm the lock.
    function test_bothBuyKindsLockThePass_realNftRealHook() public {
        assertLt(block.timestamp, hook.launchTime() + hook.GATE_DURATION(), "inside the gate window");

        _swap(alice, _buyZfo(), -int256(0.01 ether)); // A: exact-in buy
        _swap(bob, _buyZfo(), int256(0.01 ether)); // B: exact-out buy
        _swap(carol, !_buyZfo(), -int256(0.01 ether)); // C: a sell, which must NOT arm the lock
        assertGt(weth.balanceOf(feeSink), 0, "the buys were really taxed");

        vm.prank(alice);
        vm.expectRevert(NFTCollection.PassLockedDuringLaunch.selector);
        nft.transferFrom(alice, dave, idAlice);

        vm.prank(bob);
        vm.expectRevert(NFTCollection.PassLockedDuringLaunch.selector);
        nft.transferFrom(bob, dave, idBob);

        // POSITIVE CONTROL, same instant: the lock is about buying, not about the window alone.
        vm.prank(carol);
        nft.transferFrom(carol, dave, idCarol);
        assertEq(nft.ownerOf(idCarol), dave, "a non-buyer's pass moves inside the window");

        assertEq(nft.ownerOf(idAlice), alice, "exact-in buyer's pass stayed put");
        assertEq(nft.ownerOf(idBob), bob, "exact-out buyer's pass stayed put");
        assertFalse(nft.launchLockLifted(), "window still open");
    }

    /// The lock lifts for both buyers at launchTime + GATE_DURATION, and latches off.
    function test_lockLiftsWhenTheGateCloses_realNftRealHook() public {
        _swap(alice, _buyZfo(), -int256(0.01 ether));
        _swap(bob, _buyZfo(), int256(0.01 ether));

        vm.warp(hook.launchTime() + hook.GATE_DURATION());
        vm.prank(alice);
        nft.transferFrom(alice, dave, idAlice);
        vm.prank(bob);
        nft.transferFrom(bob, dave, idBob);
        assertEq(nft.ownerOf(idAlice), dave, "exact-in buyer free after the window");
        assertEq(nft.ownerOf(idBob), dave, "exact-out buyer free after the window");
        assertTrue(nft.launchLockLifted(), "lock latched off");
    }
}

contract LaunchTransferLockRealHookFlippedTest is LaunchTransferLockRealHookTest {
    function _flipTokenOrder() internal pure override returns (bool) {
        return true;
    }
}
