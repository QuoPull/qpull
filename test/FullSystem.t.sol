// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { QPULLToken } from "../src/QPULLToken.sol";
import { Treasury } from "../src/Treasury.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { HolderDrawEngine } from "../src/HolderDrawEngine.sol";
import { LeaderboardEngine } from "../src/LeaderboardEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";

/// Capstone: deploy the whole protocol, wire it, and drive the real pipeline end to end.
/// A buy (as QpullTaxHook reports it: 4% fee to the Treasury + pack/leaderboard records) feeds the
/// Treasury conversion that funds the vaults; a live daily raffle draw pays a winner who claims.
/// The standalone trade-based jackpot is gone: its 6.25% tax share now funds the WEEKLY HOLDER DRAW
/// (HolderDrawEngine), so this suite also proves the holder jackpot is tax-funded end to end — the
/// 6.25% arrives in the holder vault on convert() and a holder draw pays out of exactly those funds.
/// The swap-side mechanics of the buy itself (fee take, gate, attribution) are tested against the
/// REAL V4 PoolManager in test/QpullTaxHook.t.sol; here a pranked hook address stands in.
contract FullSystemTest is Test {
    // externals
    MockERC20 quotron;
    MockERC20 weth;
    MockSwapAdapter qpullWeth;
    MockSwapAdapter wethQuotron;
    MockDrandOracle oracle;
    MockNFT nft;

    // core
    QPULLToken token;
    Treasury treasury;
    BaseVault prizeVault;
    BaseVault holderVault;
    BaseVault leaderboardVault;
    ClaimManager claimMgr;
    PackRegistry packs;
    LeaderboardRegistry leaderboardReg;
    RaffleEngine raffle;
    HolderDrawEngine holderEng;
    LeaderboardEngine leaderboardEng;

    address hook = makeAddr("hook"); // stands in for QpullTaxHook (sole recorder + fee sender)
    address team = makeAddr("team");
    address alice = makeAddr("alice");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)
    uint256 constant WEEK = 7 days; // HolderDrawEngine.WEEK() (real value)
    uint256 constant K = 3;

    // holder-draw pot bounds
    uint256 constant HOLDER_POT_CAP = 1_000e18;
    /// `type(uint256).max` was never a usable potCap -- `cur * (BPS + MAX_ADJ_BPS)` overflows and
    /// panics, bricking setPotCap from construction, so the engines now reject it. Largest bandable value.
    uint256 constant UNCAPPED = type(uint256).max / 12_500;
    uint256 constant HOLDER_POT_CEILING = 1_000e18;

    function setUp() public {
        vm.warp(GENESIS);

        quotron = new MockERC20();
        weth = new MockERC20();
        qpullWeth = new MockSwapAdapter(1e18, 1e18);
        wethQuotron = new MockSwapAdapter(1e18, 1e18);
        oracle = new MockDrandOracle(GENESIS, 30);
        nft = new MockNFT();

        token = new QPULLToken(1_000_000e18, address(this));
        treasury = new Treasury(address(token), address(weth), address(quotron), address(this));
        prizeVault = new BaseVault(address(quotron), address(this));
        holderVault = new BaseVault(address(quotron), address(this));
        leaderboardVault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        leaderboardReg = new LeaderboardRegistry(GENESIS, address(this));
        raffle = new RaffleEngine(
            address(oracle),
            address(packs),
            address(prizeVault),
            address(claimMgr),
            GENESIS,
            K,
            1,
            UNCAPPED,
            1000, // capBps: 10%/day of the vault (REQUIRED, no default)
            address(this)
        );
        // The holder draw is bound to its own dedicated vault — the SAME vault the Treasury routes the
        // 6.25% holder share into, so the weekly draw pays out of the accumulated trade tax.
        holderEng = new HolderDrawEngine(
            address(oracle),
            address(nft),
            address(holderVault),
            address(claimMgr),
            GENESIS,
            HOLDER_POT_CAP,
            HOLDER_POT_CEILING,
            1, // minPot (> 0)
            address(this)
        );
        leaderboardEng = new LeaderboardEngine(
            address(leaderboardReg),
            address(leaderboardVault),
            address(claimMgr),
            GENESIS,
            1,
            UNCAPPED,
            address(this)
        );

        // ── wiring (mirrors Deploy.s.sol) ──
        packs.setRecorder(hook);
        packs.setEngine(address(raffle));
        leaderboardReg.setRecorder(hook);

        prizeVault.setController(address(claimMgr));
        holderVault.setController(address(claimMgr));
        leaderboardVault.setController(address(claimMgr));

        claimMgr.setEngine(address(raffle), address(prizeVault));
        claimMgr.setEngine(address(holderEng), address(holderVault));
        claimMgr.setEngine(address(leaderboardEng), address(leaderboardVault));

        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
        // Routing arg order (positional): prize, holder, leaderboard, team. The 6.25% "holder" slot
        // is what used to be the standalone jackpot slot; the split math is unchanged.
        treasury.setRouting(address(prizeVault), address(holderVault), address(leaderboardVault), team);
        treasury.setConvertThreshold(0);
        // The per-call caps ship fail-CLOSED (0 = NotConfigured); arm them (go-live step 1).
        // type(uint256).max is rejected onchain; a large finite value keeps "uncapped" intent.
        treasury.setMaxConvertPerCall(type(uint256).max / 2);
        treasury.setMaxWethConvertPerCall(type(uint256).max / 2);
        treasury.setKeeper(address(this), true); // convert() is keeper-gated
    }

    /// A DEX buy as the rest of the system sees it: the Treasury receives 4% and the pack + leaderboard registries are
    /// notified with the gross volume. NOTE: the real hook takes the buy tax in WETH; this fixture still
    /// delivers it as QPULL, which is exactly the shape of a QPULL DONATION, so it keeps convert() LEG 1 exercised. Sells and
    /// the standalone jackpot no longer exist as registry records.
    function _buy(address who, uint256 amount) internal {
        uint256 fee = (amount * 400) / 10_000;
        token.transfer(address(treasury), fee); // the hook's take() -> treasury
        token.transfer(who, amount - fee); // the swapper's post-fee delivery
        vm.startPrank(hook);
        packs.recordBuy(who, amount);
        leaderboardReg.recordBuy(who, amount);
        vm.stopPrank();
    }

    /// A DEX sell: the 4% arrives in WETH (exact-in sells pay the unspecified output currency), which
    /// convert() sweeps alongside swapped QPULL. Sells record NOTHING game-side under the current hook.
    function _sell(address who, uint256 amount) internal {
        who; // sells carry no game-side record any more
        weth.mint(address(treasury), (amount * 400) / 10_000); // the hook's take() in WETH
    }

    /// Give `n` distinct owners `MIN_HOLD` passes each (sequential ids), all minted at the current time
    /// so they are eligible for week-0's draw (ownerSince <= the freeze instant snapDeadline(0)).
    function _seedHolders(uint256 n) internal {
        uint256 hold = holderEng.MIN_HOLD();
        uint256 id = 1;
        for (uint256 o; o < n; ++o) {
            address owner = vm.addr(5000 + o);
            for (uint256 h; h < hold; ++h) {
                nft.set(id, owner, 0);
                ++id;
            }
        }
    }

    function test_fullPipeline_buyToTaxToConvertToDrawToClaim() public {
        // ── 1. a buy: 4% to the treasury + pack/leaderboard records ──
        _buy(alice, 100e18);

        assertEq(token.balanceOf(alice), 96e18, "buyer receives 96% (4% fee)");
        assertEq(token.balanceOf(address(treasury)), 4e18, "4% tax routed to treasury");
        assertEq(packs.nextPackId(), 11, "10 raffle tickets minted (100/10)");
        assertEq(leaderboardReg.points(0, alice), 100e18, "leaderboard points = gross buy");

        // ── 2. Treasury converts tax → prize inventory ──
        treasury.convert(0, 0);

        // 4 QPULL → 4 WETH → team 0.8 (20%), prize 3.2 → 3.2 QUOTRON split 2.45/0.25/0.5
        assertEq(weth.balanceOf(team), 0.8e18, "team 20%");
        assertEq(quotron.balanceOf(address(prizeVault)), 2.45e18, "raffle vault 61.25%");
        assertEq(quotron.balanceOf(address(holderVault)), 0.25e18, "holder vault 6.25%");
        assertEq(quotron.balanceOf(address(leaderboardVault)), 0.5e18, "leaderboard vault 12.5%");

        // ── 3. run the one-time OPENING raffle draw (sweeps accumulation cohorts [0,1]) ──
        // RaffleEngine is two-phase now: runOpeningDraw(false) must run once before any daily runDraw().
        // Alice is the sole buyer, so every opening winner is alice.
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("draw")); // drawRound(ACCUM_DAYS-1)
        vm.warp(GENESIS + 2 * DAY + 1); // currentDay() >= ACCUM_DAYS (2)
        raffle.runOpeningDraw(false);

        uint256 nClaims = claimMgr.nextClaimId();
        assertGt(nClaims, 0, "prizes written");
        assertLe(prizeVault.unclaimedReserve(), 2.45e18, "solvency: reserved <= pot");

        // ── 4. winner claims ──
        (, address recip, uint256 amount,,) = claimMgr.claims(1);
        assertEq(recip, alice, "sole buyer wins");
        uint256 before = quotron.balanceOf(alice);
        vm.prank(alice);
        claimMgr.claim(1);
        assertEq(quotron.balanceOf(alice), before + amount, "prize paid in QUOTRON");
    }

    function test_sellFeeSweptByConvert_noGameRecords() public {
        _buy(alice, 100e18); // alice now holds QPULL + has tickets/points
        uint256 packsAfterBuy = packs.nextPackId();
        uint256 ptsAfterBuy = leaderboardReg.points(0, alice);

        _sell(alice, 50e18);

        // sell records nothing game-side (no tickets, no points, no jackpot — the jackpot game is gone)
        assertEq(packs.nextPackId(), packsAfterBuy, "no new raffle tickets on sell");
        assertEq(leaderboardReg.points(0, alice), ptsAfterBuy, "no leaderboard points on sell");
        assertEq(weth.balanceOf(address(treasury)), 2e18, "sell fee arrives as WETH");

        // convert() sweeps BOTH: 4 QPULL -> 4 WETH, + 2 WETH held = 6 WETH total;
        // team 1.2 (20%), prize 4.8 -> QUOTRON split 61.25/6.25/12.5 of the 80%
        treasury.convert(0, 0);
        assertEq(weth.balanceOf(team), 1.2e18, "team gets 20% of swapped AND hook-fee WETH");
        assertEq(quotron.balanceOf(address(prizeVault)), 3.675e18, "raffle vault 61.25% of 6");
        assertEq(quotron.balanceOf(address(holderVault)), 0.375e18, "holder vault 6.25% of 6");
        assertEq(quotron.balanceOf(address(leaderboardVault)), 0.75e18, "leaderboard vault 12.5% of 6");
    }

    /// THE HOLDER-JACKPOT-IS-TAX-FUNDED capstone. Trade tax (a buy + a sell) routes its 6.25% holder
    /// share into the holder vault on convert(), and the weekly HolderDrawEngine then pays five winners
    /// out of exactly those funds — proving the removed standalone jackpot's tax share now flows end to
    /// end into the holder draw, with no seed and no other funding path.
    function test_holderDrawIsTaxFundedEndToEnd() public {
        // ── 1. trade tax accrues: a 10_000 buy (400 QPULL fee) + a 10_000 sell (400 WETH fee) ──
        _buy(alice, 10_000e18);
        _sell(alice, 10_000e18);

        // The holder vault starts EMPTY — the draw has no seed; every wei it pays must come from tax.
        assertEq(quotron.balanceOf(address(holderVault)), 0, "holder vault unseeded before convert");

        // ── 2. convert routes the 6.25% holder share into the holder vault ──
        // buy leg: 400 QPULL -> 400 WETH; sell leg: 400 WETH held -> 800 WETH total processed.
        // team 160 (20%); prize 640 WETH -> 640 QUOTRON; holder = 640 * 625/8000 = 50 QUOTRON.
        treasury.convert(0, 0);
        uint256 holderFunded = quotron.balanceOf(address(holderVault));
        assertEq(holderFunded, 50e18, "6.25% holder share reached the holder vault via convert()");
        assertEq(holderVault.freeBalance(), holderFunded, "all of it is free (unreserved) pot");

        // ── 3. seat >= 5 eligible holders, each holding MIN_HOLD passes, minted before the freeze ──
        _seedHolders(10); // 10 owners * 4 passes = 40 ids, all ownerSince == GENESIS <= snapDeadline(0)

        // ── 4. run week-0's draw during week 1, once the settling beacon reveals ──
        vm.warp(GENESIS + WEEK + 1);
        assertEq(holderEng.currentPeriod(), 1, "in week 1, week-0 is drawable");
        oracle.setBeacon(holderEng.drawRound(0), keccak256("holder-beacon"));

        uint256 firstClaim = claimMgr.nextClaimId();
        holderEng.runDraw(0);
        assertTrue(holderEng.drawn(0), "week-0 holder draw ran off tax funding");

        uint256 newClaims = claimMgr.nextClaimId() - firstClaim;
        assertEq(newClaims, 5, "five holder winners seated");

        // flat share = pot/5; the vault reserved exactly 5 shares against the tax-funded pot
        uint256 share = holderFunded / 5;
        assertEq(holderVault.unclaimedReserve(), 5 * share, "5 * share reserved from the tax pot");

        // ── 5. each winner pulls its share out of the tax-funded holder vault ──
        uint256 paidOut;
        for (uint256 id = firstClaim + 1; id <= claimMgr.nextClaimId(); ++id) {
            (address vault, address recip, uint256 amt,, bool settled) = claimMgr.claims(id);
            assertEq(vault, address(holderVault), "paid from the holder vault");
            assertEq(amt, share, "flat pot/5 share");
            assertFalse(settled, "unsettled before claim");
            uint256 bBefore = quotron.balanceOf(recip);
            vm.prank(recip);
            claimMgr.claim(id);
            assertEq(quotron.balanceOf(recip), bBefore + amt, "winner paid in QUOTRON from tax funds");
            paidOut += amt;
        }
        assertEq(paidOut, 5 * share, "the whole reserved pot was paid to holders");
        assertEq(holderVault.unclaimedReserve(), 0, "no reservation left after all claims");
    }

    function test_tokenIsCleanErc20() public {
        // the money token has NO transfer hooks, NO tax, NO owner (all tax logic lives in the V4 hook) - a plain
        // transfer moves the full amount, always
        _buy(alice, 100e18);
        address bob = makeAddr("bob");
        vm.prank(alice);
        token.transfer(bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18, "no tax on plain transfer");
    }
}
