// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

// Real vendored Uniswap v4 core (tag v4.0.0).
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

// Real protocol contracts.
import { V4LpBase } from "./utils/V4LpBase.sol";
import { QPULLToken } from "../src/QPULLToken.sol";
import { Treasury } from "../src/Treasury.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice END-TO-END raise → launch → trade, against the REAL PoolManager:
///           1. the NFT mint RAISES ETH and auto-splits it 80% LP / 10% seed / 10% team;
///           2. finalizeLaunch + withdrawProceeds pull the LP bucket to the launcher;
///           3. that raised ETH (wrapped to WETH, paired with QPULL) SEEDS the canonical QPULL/WETH
///              V4 pool created WITH the tax hook;
///           4. a public buy is taxed 4% to the Treasury, and the first-hour NFT-holder gate applies.
///         This is the single proof that the whole raise-to-launch-to-trade pipeline actually works.
contract RaiseToLaunchTest is Test, V4LpBase {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // add+remove LP gate (0x1ACC)
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant MINT_PRICE = 1 ether;
    uint256 constant N = 40; // 40 NFTs -> 40 ETH raised -> 32 ETH LP

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    QPULLToken qpull;
    MockWETH weth;
    MockERC20 quotron;
    MockDrandOracle oracle;
    NFTCollection nft;
    Treasury treasury;
    QpullWethAdapter adapter;
    QpullTaxHook hook;
    MockRecorder rec;

    address hookAddr = address(uint160((0xE2E << 16) | FLAGS));
    address seedTreasury = makeAddr("seedTreasury");
    address team = makeAddr("team");
    address alice = makeAddr("alice"); // mints 1 -> a first-hour-eligible holder
    address minter = makeAddr("minter"); // mints the rest -> provides the raise
    address sniper = makeAddr("sniper"); // holds no NFT
    bool qpullIs0;
    V4PoolKey key;

    receive() external payable { } // this contract is the lpTreasury — it receives the raised LP ETH

    function test_raiseToLaunchToTaxedTrade() public {
        _deployCore();
        uint256 lpEth = _raiseViaMint();
        _seedPoolWithRaise(lpEth);
        _tradesAreTaxedAndGated();
    }

    function _deployCore() internal {
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager))); // this contract IS the hook's initializer, so it is the LP
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        weth = new MockWETH();
        quotron = new MockERC20();
        qpull = new QPULLToken(1e27, address(this)); // deployer holds supply, to pair against the LP WETH
        qpullIs0 = address(qpull) < address(weth);
        oracle = new MockDrandOracle(block.timestamp, 3);
        treasury = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        rec = new MockRecorder();
        PassArtRenderer _rndr = new PassArtRenderer(address(this)); _rndr.lock(); // a locked renderer is required
        nft = new NFTCollection(MINT_PRICE, address(oracle), 1 hours, address(_rndr), address(this));
        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: address(manager),
            qpull: address(qpull),
            weth: address(weth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            treasury: address(treasury),
            packRegistry: address(rec),
            leaderboardRegistry: address(rec),
            nft: address(nft),
            exemptSender: address(adapter),
            initializer: address(this),
            // throttle not under test here: this suite buys 1 ether inside the gate window
            earlyBuyCapWei: type(uint256).max
        });
        deployCodeTo("src/hooks/QpullTaxHook.sol:QpullTaxHook", abi.encode(hc), hookAddr);
        hook = QpullTaxHook(hookAddr);

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });
    }

    /// 1-2. Raise ETH via the NFT mint, then pull the frozen buckets. Returns the LP ETH the launcher holds.
    function _raiseViaMint() internal returns (uint256 lpEth) {
        nft.setRecipients(address(this), seedTreasury, team); // THIS = lpTreasury
        nft.setAllowlistRoot(keccak256("raise")); // any non-zero root; this raise uses the open path
        nft.setMintOpen(true);
        // start the mint (one-shot), then warp past GTD + overflow into the PUBLIC window, where the
        // open mint() path is live and the per-wallet cap is PUBLIC_CAP.
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt());

        vm.deal(alice, MINT_PRICE);
        vm.prank(alice);
        nft.mint{ value: MINT_PRICE }(); // alice becomes a holder

        // spread the raise across distinct wallets (NFTCollection caps mints at PUBLIC_CAP = 20)
        for (uint256 i; i < N - 1; ++i) {
            address m = address(uint160(uint256(uint160(minter)) + i + 1));
            vm.deal(m, MINT_PRICE);
            vm.prank(m);
            nft.mint{ value: MINT_PRICE }();
        }
        assertEq(nft.totalMinted(), N, "raise: N minted");

        nft.finalizeLaunch(); // seals rarity, moves no ETH

        uint256 lpBefore = address(this).balance;
        uint256 seedBefore = seedTreasury.balance;
        uint256 teamBefore = team.balance;
        nft.withdrawProceeds(); // pays each frozen bucket independently

        lpEth = address(this).balance - lpBefore;
        assertEq(lpEth, (N * MINT_PRICE * 8000) / 10_000, "LP bucket = 80% of the raise");
        assertEq(seedTreasury.balance - seedBefore, (N * MINT_PRICE * 1000) / 10_000, "seed bucket = 10%");
        assertEq(team.balance - teamBefore, (N * MINT_PRICE * 1000) / 10_000, "team bucket = 10%");
    }

    /// 3. Create the canonical hooked pool and seed it with the raised ETH (wrapped) + QPULL.
    function _seedPoolWithRaise(uint256 lpEth) internal {
        _initializePool(key, SQRT_1_1); // the go-live action — stamps launchTime, opens the gate
        assertEq(hook.launchTime(), block.timestamp, "launch stamped at pool creation");

        weth.deposit{ value: lpEth }(); // wrap the raised LP ETH -> WETH (this contract now holds it)
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);

        uint256 pmWethBefore = weth.balanceOf(address(manager));
        // LP is gated to the initializer (tx.origin): prank so the protocol's seed passes
        _addLiquidity(key, -887_220, 887_220, 10e18);
        uint256 pmWethAdded = weth.balanceOf(address(manager)) - pmWethBefore;
        assertGt(pmWethAdded, 0, "pool funded with WETH sourced from the raise");
        assertLe(pmWethAdded, lpEth, "the LP came from the raised ETH, nothing else");
    }

    /// 4. A public buy is taxed 4%; the first-hour gate lets holders in and keeps non-holders out.
    function _tradesAreTaxedAndGated() internal {
        vm.deal(alice, 5 ether);
        vm.deal(sniper, 5 ether);
        vm.prank(alice);
        weth.deposit{ value: 5 ether }();
        vm.prank(sniper);
        weth.deposit{ value: 5 ether }();
        vm.prank(alice);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.prank(sniper);
        weth.approve(address(swapRouter), type(uint256).max);

        bool buyZeroForOne = !qpullIs0; // WETH in, QPULL out

        // FIRST HOUR: the non-holder is gated; the holder buys and is taxed.
        vm.expectRevert(); // Gated, wrapped by v4-core's hook-revert bubbling
        _swap(sniper, buyZeroForOne, -1 ether);

        uint256 wethBefore = weth.balanceOf(address(treasury));
        uint256 qpullBefore = qpull.balanceOf(address(treasury));
        _swap(alice, buyZeroForOne, -1 ether);
        uint256 feeAfterAlice = weth.balanceOf(address(treasury));
        // the tax is WETH, ceil(4%) of the WETH spent
        assertEq(feeAfterAlice - wethBefore, 0.04 ether, "holder buy taxed 4% to the Treasury, in WETH");
        assertEq(qpull.balanceOf(address(treasury)), qpullBefore, "no QPULL fee");

        // AFTER the gate: anyone buys, still taxed.
        vm.warp(block.timestamp + hook.GATE_DURATION() + 1); // the 1-hour gate
        _swap(sniper, buyZeroForOne, -1 ether);
        assertGt(weth.balanceOf(address(treasury)), feeAfterAlice, "post-gate buy adds more tax");
    }

    function _swap(address who, bool zeroForOne, int256 amt) internal {
        vm.prank(who, who); // msg.sender AND tx.origin = the trader (the gate reads tx.origin)
        swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amt, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
