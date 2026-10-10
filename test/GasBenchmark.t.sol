// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { console2 } from "forge-std/console2.sol";
import { PledgeFloodBase } from "./NFTIntegration.t.sol";

/// @notice Measures the ACTUAL gas of the daily draw's selection loop against the Robinhood Chain block
///         ceiling. Two open questions depend on these numbers and nothing else:
///
///         (1) RaffleEngine: `MAX_K = 200` carries a "one-block-safe, ~120-140k
///             gas/winner" comment, but the old `PackRegistry.SAFE_FREE_K = 150` said anything above 150
///             shipped WITHOUT a confirmed margin when the virtual free-entry block is active. Nothing ever
///             read SAFE_FREE_K (since removed), so `winnersPerDay` may legally sit in (150, 200].
///             Is that range safe?
///
///         (2) Invalid pledges: one candidate prunes them out of `wb`, which adds an O(pledgeList) pass
///             to every draw. The alternative (terminal void) costs nothing but leaves q > 0. The prune is
///             only takeable if the headroom measured here absorbs it.
///
/// @dev    Assertion-light on purpose: these are measurements, not invariants. The only hard assert is
///         against the chain ceiling, with margin. Run with `-vv` to read the table.
contract GasBenchmarkTest is PledgeFloodBase {
    /// Robinhood Chain (Arbitrum Orbit L2) per-block gas ceiling, measured for the holder-draw work.
    uint256 constant RH_BLOCK_CEILING = 32_000_000;
    /// Leave real headroom: a draw that needs more than half a block is not "one-block-safe" in practice.
    uint256 constant SAFE_FRACTION_BPS = 5000;

    function _measureDrawFrom(uint256 k, bytes32 beacon) internal returns (uint256 used) {
        uint256 before = gasleft();
        vm.prank(address(engine));
        packs.drawFrom(beacon, D, k);
        used = before - gasleft();
    }

    /// @notice Q1 — does the (150, 200] band RaffleEngine allows actually fit in a block?
    function test_gas_drawFrom_acrossK() public {
        _srs(9);                       // full Super Rare set
        _pledgeRares(honest, HONEST_BASE, 90); // 90 Rares pledged, weight 4 each
        _warpToDraw();

        console2.log("=== drawFrom gas vs k (free block ACTIVE, 9 SR + 90 pledged Rares) ===");
        console2.log("RH block ceiling:", RH_BLOCK_CEILING);
        uint256[4] memory ks = [uint256(50), 100, 150, 200];
        uint256 last;
        for (uint256 i; i < ks.length; ++i) {
            uint256 used = _measureDrawFrom(ks[i], keccak256(abi.encode("k", ks[i])));
            console2.log("  k =", ks[i]);
            console2.log("    gas used      :", used);
            console2.log("    gas per winner:", used / ks[i]);
            console2.log("    % of a block  :", (used * 100) / RH_BLOCK_CEILING);
            last = used;
        }
        // The hard gate: k = MAX_K must fit comfortably, since RaffleEngine permits it.
        assertLt(last, (RH_BLOCK_CEILING * SAFE_FRACTION_BPS) / 10_000, "k=200 exceeds half a block");
    }

    /// THE DECIDING MEASUREMENT for prune vs terminal void. `_pickVirtual` validates a pledged copy
    /// LAZILY — only copies it actually rolls, bounded by MAX_REJECTS_PER_SEAT * k. An eager `wb` prune must
    /// validate EVERY entry: two external NFT calls plus two SLOADs each, unbounded in pledgeList size.
    /// So the prune may cost MORE than the rejection sampling it replaces. Measure, do not estimate.
    function test_gas_pruneWalkCost() public {
        _srs(9);
        _warpToPledgeDay();
        console2.log("=== cost of ONE eager prune walk over pledgeList ===");
        console2.log("(an isolated k=200 draw needs ~30M before refunds, so real headroom is ~1.5M to 2.7M, not ~6.6M)");
        uint256[4] memory rares = [uint256(25), 50, 100, 200];
        uint256 planted;
        for (uint256 i; i < rares.length; ++i) {
            _pledgeRares(honest, HONEST_BASE + planted, rares[i] - planted);
            planted = rares[i];
            uint256 snap = vm.snapshotState();
            _warpToDraw();
            uint256 freeze = GENESIS + (uint256(D) + 1) * DAY;
            uint256 before = gasleft();
            packs.pruneWalk(D, freeze);
            uint256 used = before - gasleft();
            console2.log("  pledged Rares:", rares[i]);
            console2.log("    pledgeList copies (weight 4):", rares[i] * 4);
            console2.log("    PRUNE WALK gas             :", used);
            console2.log("    gas per copy               :", used / (rares[i] * 4));
            vm.revertToState(snap);
        }
    }

    /// @notice Q2: how does cost scale with the pledge list? This is the surface a `wb` prune
    ///         would have to walk on every draw, so its slope is the prune's per-draw price.
    function test_gas_drawFrom_pledgeScaling() public {
        _srs(9);
        _warpToPledgeDay();
        console2.log("=== drawFrom gas vs pledged-Rare count at k = 200 ===");
        // grow the pledge population and re-measure
        uint256[4] memory counts = [uint256(25), 50, 100, 200];
        uint256 base = HONEST_BASE;
        uint256 planted;
        for (uint256 i; i < counts.length; ++i) {
            uint256 add = counts[i] - planted;
            _pledgeRares(honest, base + planted, add);
            planted = counts[i];
            uint256 snap = vm.snapshotState();
            _warpToDraw();
            uint256 used = _measureDrawFrom(200, keccak256(abi.encode("p", counts[i])));
            console2.log("  pledged Rares:", counts[i]);
            console2.log("    pledge copies (weight 4):", counts[i] * 4);
            console2.log("    gas used                :", used);
            vm.revertToState(snap);
        }
    }

    /// @notice The pathological case: a large flood inflates `pledgeList` with entries that are all invalid
    ///         at draw time. This is the population a `wb` prune would remove, so it bounds the
    ///         prune's worst-case cost AND shows what the current code pays to reject them one seat at a time.
    function test_gas_drawFrom_underFlood() public {
        _srs(9);
        _pledgeRares(honest, HONEST_BASE, 50);
        _flood(200); // 200 Rares pledged then handed off: 800 invalid copies in pledgeList
        _warpToDraw();
        uint256 used = _measureDrawFrom(200, keccak256("flood"));
        console2.log("=== drawFrom gas at k=200 UNDER FLOOD (50 honest + 200 flooded Rares) ===");
        console2.log("  pledgeList copies:", uint256(250 * 4));
        console2.log("  gas used         :", used);
        console2.log("  % of a block     :", (used * 100) / RH_BLOCK_CEILING);
        assertLt(used, RH_BLOCK_CEILING, "flooded draw exceeds a whole block");
    }

    /// @notice Q3 - what does a FULL-CAP BUY actually cost, and is `MAX_TICKETS_CEILING = 200` safe?
    ///
    ///         `maxTicketsPerBuy` exists for exactly one reason: gas (PackRegistry:129-134 --
    ///         an earlier cap of 1000 needed ~73M and large buys reverted). But the 100 that ships is justified
    ///         by a "~73k gas/pack" CODE COMMENT, and nothing in this repo ever measured it. That number is
    ///         load-bearing twice over: it sets how much a buyer can mint per transaction, and it decides
    ///         whether the setter's 200 ceiling is reachable or a trap that bricks every large buy.
    ///
    ///         Measure the slope, then say what actually fits. Reported per-pack is TOTAL/n, which overstates
    ///         at small n because the fixed per-CALL cost amortises; the marginal slope is what extrapolates.
    function test_gas_recordBuy_acrossCap() public {
        uint256[5] memory ns = [uint256(1), uint256(50), uint256(100), uint256(150), uint256(200)];
        uint256[5] memory used;

        for (uint256 i; i < 5; ++i) {
            packs.setMaxTicketsPerBuy(ns[i]);
            address b = makeAddr(string(abi.encodePacked("capbuyer", i)));
            vm.prank(token);
            uint256 before = gasleft();
            packs.recordBuy(b, ns[i] * TICKET);
            used[i] = before - gasleft();
            console2.log("packs / total gas / gas-per-pack", ns[i], used[i], used[i] / ns[i]);
        }

        // Marginal cost of one more pack, across the widest clean span (50 -> 200) so the fixed per-call
        // cost cancels instead of being smeared into the per-pack figure.
        uint256 slope = (used[4] - used[1]) / (ns[4] - ns[1]);
        uint256 overhead = used[1] - slope * ns[1];
        console2.log("MARGINAL gas per pack", slope);
        console2.log("fixed per-call overhead", overhead);
        console2.log("the code comment claims", uint256(73_000));

        // What the chain can actually take. The mint is not the whole transaction: a real buy is a
        // Uniswap v4 swap + tax split + hook bookkeeping, and recordBuy runs INSIDE it.
        console2.log("packs that fit 32M (mint alone, no swap)", (RH_BLOCK_CEILING - overhead) / slope);
        console2.log("packs that fit half a block (real-buy headroom)",
            ((RH_BLOCK_CEILING * SAFE_FRACTION_BPS / 10_000) - overhead) / slope);
        console2.log("full-cap buy at 100 (shipping value)", overhead + slope * 100);
        console2.log("full-cap buy at 200 (MAX_TICKETS_CEILING)", overhead + slope * 200);

        // The one hard assert: the setter's own ceiling must be REACHABLE. If a 200-pack buy cannot fit in
        // half a block then setMaxTicketsPerBuy(200) is a loaded gun -- it passes its bounds check and then
        // reverts every large buy, the same failure as the earlier 1000 cap.
        assertLt(overhead + slope * 200, RH_BLOCK_CEILING * SAFE_FRACTION_BPS / 10_000,
            "MAX_TICKETS_CEILING=200 does not fit half a block: the setter can brick large buys");
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// @notice THE deciding measurement for RaffleEngine's `MAX_K = 200`. The benchmark above times `drawFrom` in
///         isolation, which is precisely the O(k) cost the `MAX_K = 200` comment leaves out. The comment's
///         own estimate is "~120-140k gas/winner" for the PAYOUT loop. If both are real, k = 200 would be
///         200 * (140k + 33k) = ~34.6M, i.e. OVER a 32M block. This measures the whole `runDraw` in one
///         transaction — selection loop, payout loop, tier reads, vault reserves and claim registration —
///         so the question is settled by a number rather than by adding two estimates together.
contract RaffleEndToEndGasTest is Test {
    PackRegistry packs;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;

    address token = makeAddr("token");
    address buyer = makeAddr("buyer");
    address pledger = makeAddr("pledger");
    address flooder = makeAddr("flooder");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days;
    uint256 constant POT = 1_000_000e18;
    uint256 constant RH_BLOCK_CEILING = 32_000_000;

    function _build(uint256 k) internal {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        quotron = new MockERC20();
        nft = new MockNFT();
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr),
            GENESIS, k, 1, POT,
            1000, /* capBps: 10%/day of the vault (REQUIRED, no default) */ address(this)
        );
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        quotron.mint(address(vault), POT);

        // deep paid pool in cohort 0 so k winners are all drawable
        for (uint256 i; i < 20; ++i) {
            vm.prank(token);
            packs.recordBuy(buyer, 500 * TICKET); // 500 tickets each
        }
        // Super Rares + pledged Rares so the VIRTUAL free-entry block is active during the daily draw
        uint256[] memory srs = new uint256[](9);
        for (uint256 i; i < 9; ++i) { nft.set(1 + i, pledger, 3); srs[i] = 1 + i; }
        packs.registerSuperRare(srs);
    }

    function _bootstrapOpening() internal {
        (, uint64 rr,,) = packs.packs(1);
        oracle.setBeacon(rr, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw(false);
    }

    function _pledge(uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { nft.set(100 + i, pledger, 2); ids[i] = 100 + i; }
        vm.prank(pledger);
        packs.pledge(ids);
    }

    /// @dev Pledge-flood fixture: pledge `n` Rares and then move every one of them away, so each
    ///      weight-expanded copy sitting in pledgeList is INVALID at draw time. In an earlier version that was
    ///      the one attacker-controllable gas term in runDraw: an invalid copy triggered a REJECTION ROLL,
    ///      up to six per free seat at ~9-10k gas each, which the all-valid benchmark never exercised.
    function _floodPledges(uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.set(5000 + i, flooder, 2); // Rare: weight 4, the heaviest copy count per pass
            ids[i] = 5000 + i;
        }
        vm.prank(flooder);
        packs.pledge(ids);
        for (uint256 i; i < n; ++i) {
            nft.set(5000 + i, address(uint160(0xF10D0000 + i)), 2); // moved on: the copies are now invalid
        }
    }

    function _runDayDraw(uint32 day) internal returns (uint256 used) {
        oracle.setBeacon(raffle.drawRound(day), keccak256(abi.encode("day", day)));
        vm.warp(GENESIS + (uint256(day) + 1) * DAY + 2 hours);
        uint256 before = gasleft();
        raffle.runDraw(day);
        used = before - gasleft();
    }

    function _bench(uint256 k) internal returns (uint256) {
        _build(k);
        _bootstrapOpening();       // currentDay() == 2
        _pledge(90);               // pledges land on day 2, before its freeze
        uint256 used = _runDayDraw(2);
        console2.log("  k =", k);
        console2.log("    FULL runDraw gas :", used);
        console2.log("    gas per winner   :", used / k);
        console2.log("    %% of a 32M block :", (used * 100) / RH_BLOCK_CEILING);
        return used;
    }

    function test_gas_runDraw_endToEnd_k150() public {
        console2.log("=== FULL runDraw (selection + payout + claims), free block ACTIVE ===");
        uint256 used = _bench(150); // the old (never enforced, removed) PackRegistry.SAFE_FREE_K
        assertLt(used, RH_BLOCK_CEILING, "k=150 exceeds a block");
    }

    /// An all-valid-pledge fixture leaves out the rejection-roll term a pledge flood added when invalid copies
    /// re-rolled, and that term ate into the headroom against Robinhood Chain's 32M per-transaction clamp.
    /// Terminal voids remove it structurally, and this pins that as a measurement rather than an argument:
    /// with one terminal roll per seat, a flooded copy makes
    /// a seat VOID, and a void seat skips the payout and the claim registration entirely. So flooding can only
    /// make the draw CHEAPER. Both halves run against identical state via a snapshot, so the numbers compare.
    function test_aPledgeFloodCannotRaiseTheWorstCase() public {
        _build(200); // RaffleEngine.MAX_K
        _bootstrapOpening(); // currentDay() == 2
        _pledge(90); // the honest, all-valid fixture the original measurement used

        uint256 snap = vm.snapshotState();
        uint256 clean = _runDayDraw(2);
        vm.revertToState(snap);

        _floodPledges(400); // 1600 invalid copies on top, so most seats roll into the flood region
        uint256 flooded = _runDayDraw(2);

        console2.log("=== pledge flood: K=200, all-valid vs pledge-flooded ===");
        console2.log("    all-valid  runDraw gas :", clean);
        console2.log("    flooded    runDraw gas :", flooded);
        console2.log("    %% of a 32M block (max):", ((clean > flooded ? clean : flooded) * 100) / RH_BLOCK_CEILING);

        assertLt(flooded, RH_BLOCK_CEILING, "a flooded draw still fits a block");
        assertLe(
            flooded,
            clean,
            "with terminal voids a flood can only VOID seats, never add rolls, so it cannot raise the worst case"
        );
    }

    /// Measured inside one test transaction (warm, dirty storage, gasleft delta), so this
    /// understates a real draw by ~3M; the same shape as its own transaction needs ~29.5M before refunds. The cold,
    /// pre-refund gate against the 32M per-tx limit is test/RunDrawIsolatedGas.t.sol.
    function test_gas_runDraw_endToEnd_k200() public {
        console2.log("=== FULL runDraw at MAX_K, the value RaffleEngine actually permits ===");
        uint256 used = _bench(200); // RaffleEngine.MAX_K
        assertLt(used, RH_BLOCK_CEILING, "k=200 (MAX_K) exceeds a 32M block");
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────

import { PoolManager } from "v4-core/PoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { V4LpBase } from "./utils/V4LpBase.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { QPULLToken } from "../src/QPULLToken.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";

/// @notice The BUY-WITH-PACK-MINT gas model the web pins buys with (base + perPack * packs), measured on the
///         0x1ACC hook through the site's router, QpullSwapRouter (the owner's choice; it replaced
///         TestnetSwapRouter). The old model (347,000 + 71,995/pack) predates the beforeSwap callback.
///
///         The measured call is the whole buy as the site sends it on both chains: QpullSwapRouter.buy{value}(minOut,
///         deadline) from the buyer's EOA, i.e. WETH.deposit + PoolManager.unlock + swap + the hook's beforeSwap and
///         afterSwap (fee take, gate, throttle, both registry records) + the router's settle, take-to-caller with the
///         caller-side balance check, and its stray-balance reads, into the REAL PackRegistry and LeaderboardRegistry
///         at the mainnet ticket price (0.003 ETH).
///
///         ROWS (run with --isolate; each measured buy is its own transaction):
///           table rows   a FRESH wallet's first buy of the week, exact multiples of the ticket price, on a day whose
///                        cohort already exists (a warm-up buy by another wallet runs first); inside and past the gate.
///           first mint   the day's FIRST minting buy (it creates the day's cohortLive array length and its
///                        cohortMinTicketPrice slot), isolated against the same day's second fresh-wallet buy.
///           worst case   every zero-to-non-zero write one buy can reach, together: (C) the launch's first buy, a
///                        holder's first gated buy on the day's first mint and the week's first board entry, with the
///                        Treasury's WETH balance at zero and a sub-ticket remainder banked; (E) past the gate, a
///                        fresh wallet evicting the minimum of a FULL 25-entry board on the day's first mint, the
///                        Treasury's WETH at zero (a convert drained it) and a remainder banked. The model base is
///                        the larger.
///
///         CAVEATS (read before copying numbers): (1) gas is execution gas of the router call only: no 21,000 intrinsic,
///         no calldata, and on Robinhood Chain (Arbitrum Orbit) no L1 data component, all of which a receipt adds;
///         (2) run WITHOUT --isolate the whole test is one transaction, so slots touched by earlier buys are WARM;
///         (3) MockWETH stands in for WETH (RH's WETH is a proxy: a DELEGATECALL on deposit, withdraw and transfer);
///         (4) the per-pack slope is taken across 10 -> max packs so the fixed cost cancels.
contract BuyGasBenchmarkTest is Test, V4LpBase {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 constant TP = 0.003 ether; // mainnet ticket price
    uint256 constant CAP = 0.25 ether; // mainnet EARLY_BUY_CAP_WEI
    uint256 constant SUNDAY = 1_800_144_000; // a Sunday 00:00 UTC: week 0 spans days 0-6

    PoolManager manager;
    QPULLToken qpullT;
    MockWETH wethT;
    MockNFT passes;
    PackRegistry packsR;
    LeaderboardRegistry board;
    QpullSwapRouter router;
    address hookAddr = address(uint160((0x6A5 << 16) | FLAGS));
    address treasury = makeAddr("treasury");
    uint256 nextPass = 10_000;

    function setUp() public {
        vm.warp(SUNDAY);
        manager = new PoolManager(address(this));
        _initLp(IV4PoolManager(address(manager)));
        qpullT = new QPULLToken(1e27, address(this));
        wethT = new MockWETH();
        passes = new MockNFT();
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        packsR = new PackRegistry(address(oracle), TP, block.timestamp, 1 hours, address(this));
        board = new LeaderboardRegistry(block.timestamp, address(this));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpullT),
                    weth: address(wethT),
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: treasury,
                    packRegistry: address(packsR),
                    leaderboardRegistry: address(board),
                    nft: address(passes),
                    exemptSender: makeAddr("exemptAdapter"),
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
            hookAddr
        );
        packsR.setRecorder(hookAddr);
        board.setRecorder(hookAddr);
        bool q0 = address(qpullT) < address(wethT);
        V4PoolKey memory key = V4PoolKey({
            currency0: V4Currency.wrap(q0 ? address(qpullT) : address(wethT)),
            currency1: V4Currency.wrap(q0 ? address(wethT) : address(qpullT)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IV4Hooks(hookAddr)
        });
        vm.deal(address(this), 1e25);
        wethT.deposit{ value: 1e25 }();
        _initializePool(key, SQRT_1_1); // stamps launchTime: the 1-hour gate opens now
        _addLiquidity(key, -887_220, 887_220, 1e24);
        router = new QpullSwapRouter(address(manager), address(wethT), address(qpullT), hookAddr, 3000, 60);
    }

    function _wallet(string memory tag, bool holder) internal returns (address w) {
        w = makeAddr(tag);
        if (holder) passes.set(nextPass++, w, 0);
    }

    function _buy(address who, uint256 value) internal returns (uint256 used, uint256 lastCall, uint256 minted) {
        vm.deal(who, value);
        uint256 id0 = packsR.nextPackId();
        vm.prank(who, who);
        uint256 before = gasleft();
        router.buy{ value: value }(1, block.timestamp + 600);
        used = before - gasleft();
        lastCall = vm.lastCallGas().gasTotalUsed;
        minted = packsR.nextPackId() - id0;
    }

    /// Zero the Treasury's WETH, as a convert() that swept the whole balance leaves it.
    function _drainTreasury() internal {
        uint256 b = wethT.balanceOf(treasury);
        if (b != 0) {
            vm.prank(treasury);
            wethT.transfer(makeAddr("convertSink"), b);
        }
    }

    function _table(string memory title, uint256[4] memory ns, bool holders) internal returns (uint256 base, uint256 slope) {
        // warm-up: another wallet's buy earlier the same day, so the cohort exists (not the day's first mint)
        _buy(_wallet(string.concat(title, "-warmup"), holders), TP);
        console2.log(title);
        uint256[4] memory used;
        for (uint256 i; i < 4; ++i) {
            address b = _wallet(string.concat(title, "-buyer", vm.toString(i)), holders);
            (uint256 u, uint256 lc, uint256 minted) = _buy(b, ns[i] * TP);
            assertEq(minted, ns[i], "the buy minted exactly G / ticketPrice packs");
            used[i] = lc;
            console2.log("  packs / gas (gasleft delta) / lastCallGas.gasTotalUsed", ns[i], u, lc);
        }
        slope = (used[3] - used[1]) / (ns[3] - ns[1]);
        base = used[0] - slope * ns[0];
        console2.log("  per-pack slope (10 -> max), lastCallGas", slope);
        console2.log("  base (1-pack buy minus one slope), lastCallGas", base);
    }

    /// Past the 1-hour gate: no holder check, no throttle record. The steady-state buy.
    function test_gas_buyWithPackMint_pastGate() public {
        vm.warp(QpullTaxHook(hookAddr).launchTime() + QpullTaxHook(hookAddr).GATE_DURATION() + 1);
        (uint256 base, uint256 slope) = _table("=== buy + pack mint, 0x1ACC hook, PAST the gate ===", [uint256(1), 10, 50, 100], false);
        assertLt(base + slope * 100, 16_000_000, "a full 100-pack buy fits half a 32M block");
    }

    /// Inside the 1-hour gate: a pass holder's FIRST gated buy (holder check + a new throttle record). The per-buy cap
    /// (0.25 ETH at 0.003 ETH a ticket) bounds a gated buy to 83 packs, so the top point is 80.
    function test_gas_buyWithPackMint_insideGate_firstGatedBuy() public {
        (uint256 base, uint256 slope) = _table("=== buy + pack mint, 0x1ACC hook, INSIDE the gate ===", [uint256(1), 10, 50, 80], true);
        assertGt(base, 0, "measured");
        assertGt(slope, 0, "measured");
    }

    /// THE DAY'S FIRST MINTING BUY, isolated. Day 0 carries the warm-up (week slots and Treasury WETH exist), then on day 1
    /// (same week, past the gate) a fresh wallet's 1-pack buy creates the day's cohort; a second fresh wallet's 1-pack buy
    /// the same day is the comparison. Everything else is identical between the two.
    function test_gas_buyWithPackMint_firstMintingBuyOfTheDay_isolated() public {
        vm.warp(QpullTaxHook(hookAddr).launchTime() + QpullTaxHook(hookAddr).GATE_DURATION() + 1);
        _buy(_wallet("day0-warmup", false), TP);
        vm.warp(SUNDAY + 1 days + 1);
        assertEq(board.currentWeek(), 0, "premise: same week");
        (,, uint256 first,) = _row("day1-first", false, TP, 1);
        (,, uint256 second,) = _row("day1-second", false, TP, 1);
        console2.log("=== the day's FIRST minting buy vs the same day's second (1 pack, fresh wallets, past the gate) ===");
        console2.log("  first minting buy of the day, lastCallGas", first);
        console2.log("  second buy of the day,        lastCallGas", second);
        console2.log("  first-mint increment", first - second);
        assertGt(first, second, "the first mint of the day writes the new cohort slots");
    }

    function _row(string memory tag, bool holder, uint256 value, uint256 wantPacks)
        internal
        returns (address b, uint256 used, uint256 lastCall, uint256 minted)
    {
        b = _wallet(tag, holder);
        (used, lastCall, minted) = _buy(b, value);
        assertEq(minted, wantPacks, "packs minted");
    }

    /// WORST CASE (C), inside the gate: the launch's very first buy. First minting buy of day 0, the week's first board
    /// entry (totalPoints, boardCount, board slot, index, points all new), the Treasury's first WETH, a holder's first
    /// gated buy (throttle record), a fresh QPULL balance, and a 1-wei remainder banked. 1 pack.
    function test_gas_buyWithPackMint_worstCase_launchFirstBuy_insideGate() public {
        assertEq(wethT.balanceOf(treasury), 0, "premise: Treasury WETH is zero");
        assertEq(board.boardCount(0), 0, "premise: an empty board");
        (address b,, uint256 lc,) = _row("launch-first", true, TP + 1, 1);
        assertEq(packsR.bankedRemainder(b), 1, "premise: a remainder was banked");
        console2.log("=== WORST CASE (C): the launch's first buy, inside the gate, 1 pack + remainder ===");
        console2.log("  lastCallGas", lc);
    }

    /// WORST CASE (E), past the gate: a fresh wallet EVICTS the minimum of a full 25-entry board on the day's first mint,
    /// with the Treasury's WETH at zero and a 1-wei remainder banked. 1 pack.
    function test_gas_buyWithPackMint_worstCase_fullBoardEviction_firstMintOfDay() public {
        vm.warp(QpullTaxHook(hookAddr).launchTime() + QpullTaxHook(hookAddr).GATE_DURATION() + 1);
        for (uint256 i; i < 25; ++i) {
            _buy(_wallet(string.concat("board-", vm.toString(i)), false), TP); // 25 equal entries, day 0
        }
        assertEq(board.boardCount(0), 25, "premise: the board is full");
        vm.warp(SUNDAY + 2 days + 1);
        assertEq(board.currentWeek(), 0, "premise: same week");
        _drainTreasury();
        (address b,, uint256 lc,) = _row("evictor", false, TP + 1, 1); // TP + 1 wei of points beats every TP entry
        assertTrue(board.isOnBoard(0, b), "premise: it evicted the minimum");
        assertEq(board.boardCount(0), 25, "the board stayed full");
        console2.log("=== WORST CASE (E): full-board eviction, day's first mint, Treasury WETH zero, 1 pack + remainder ===");
        console2.log("  lastCallGas", lc);
    }
}
