// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IQuotronRouter } from "../../src/interfaces/IQuotronRouter.sol";

interface IRouterView {
    function quotron() external view returns (address);
}

interface IViewQuoter {
    function quoteBuyExactEth(uint256 ethIn, address payer)
        external
        view
        returns (uint256 quotronOut, uint256 feeBps, uint256 feeWeth, uint256 poolWethIn);
}

/// @notice THE SIZING CANARY. `*_MIN_POT` is denominated in QUOTRON base units, but every wei that has to
///         clear it arrives as ETH — the mint's prize seed, and tax at a fixed percentage of ETH volume.
///         The two sides are in different currencies, so a QUOTRON price move silently rescales the floor
///         relative to the money meant to clear it, with no edit to any file and no error at deploy.
///
///         That is not hypothetical. The testnet deploys carry `minPot = 1e18`, and at the time of writing
///         one QUOTRON is ~2.67 ETH (total supply 1,411), so that placeholder is 2.67 ETH per engine. Copied
///         to mainnet it puts the floor above the day-one pot: the opening raffle draw waits indefinitely
///         (`runOpeningDraw(false)` reverts `PotBelowOpeningFloor`, and keeper.js passes false on purpose)
///         and every daily draw in the meantime takes the void-on-miss branch and pays nobody.
///
/// @dev    WHY THIS TEST FAILING IS NOT NECESSARILY A CODE REGRESSION. It reads the LIVE Quotron pool, so a
///         large enough market move breaks it without anyone touching the repo. That is the intent: this is
///         a canary for drift, and the failure message says to re-derive rather than to go hunting for a
///         bug. Override the candidate floors via env to test a different set.
///
///         Values under test come from docs/MAINNET-POT-SIZING.md. Keep them in sync.
contract PotSizingForkTest is Test {
    address constant ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;
    address constant VIEW_QUOTER = 0xb8960fdC8A0Be155d196C2795b75747763562df2;

    // Full sellout is 3,475 sellable at 0.0075 ETH = 26.06 ETH gross; SEED_BPS = 1000 sends 10% to
    // `seedTreasury`. That seed funds the DAILY RAFFLE ONLY -- holder and leaderboard start at zero and
    // accumulate over their first 7-day period instead, which is why only the raffle is checked against it.
    uint256 constant SEED_ETH = 2.6 ether;
    uint256 constant RAFFLE_CAP_BPS = 1000; // the daily pot is 10% OF THE VAULT, so the vault needs 10x
    uint256 constant BPS = 10_000;

    // Share of ETH trade volume that reaches each vault: 4% tax, 20% of it to team, the rest split
    // 6125/625/1250 of 8000. Raffle 2.45%, holder 0.25%, leaderboard 0.50%.
    uint256 constant RAFFLE_BPS_OF_VOLUME = 245;
    uint256 constant HOLDER_BPS_OF_VOLUME = 25;
    uint256 constant LEADER_BPS_OF_VOLUME = 50;

    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    function _floors() internal view returns (uint256 raffle, uint256 holder, uint256 leader) {
        raffle = vm.envOr("RAFFLE_MIN_POT", uint256(0.01 ether));
        holder = vm.envOr("HOLDER_MIN_POT", uint256(0.01 ether));
        leader = vm.envOr("LEADERBOARD_MIN_POT", uint256(0.02 ether));
    }

    /// QUOTRON that `ethIn` buys at the live price, net of Quotron's own fee (the quoter applies it).
    function _quote(uint256 ethIn) internal view returns (uint256 out) {
        (out,,,) = IViewQuoter(VIEW_QUOTER).quoteBuyExactEth(ethIn, address(this));
    }

    /// THE ONE THAT MATTERS. The seed is the raffle's whole balance at the opening draw in the worst case
    /// (zero launch volume), and the opening pot is RAFFLE_CAP_BPS of it. If that does not clear the floor,
    /// the raffle cannot open on its own funding.
    function test_seedAloneOpensTheRaffle() public {
        vm.createSelectFork(RPC);
        (uint256 raffleMinPot,,) = _floors();

        uint256 seedQuotron = _quote(SEED_ETH);
        uint256 openingPot = (seedQuotron * RAFFLE_CAP_BPS) / BPS;

        emit log_string("--- raffle opening, funded by the seed alone (zero launch volume) ---");
        emit log_named_uint("seed ETH                   ", SEED_ETH);
        emit log_named_uint("  -> QUOTRON at live price ", seedQuotron);
        emit log_named_uint("opening pot (10% of vault) ", openingPot);
        emit log_named_uint("RAFFLE_MIN_POT under test  ", raffleMinPot);
        emit log_named_uint("headroom (x1e18 = 1.0x)    ", (openingPot * 1e18) / raffleMinPot);

        assertGt(seedQuotron, 0, "live quoter returned nothing - pool moved or the quoter address is wrong");
        assertGe(
            openingPot,
            raffleMinPot,
            "SIZING DRIFT: the prize seed no longer clears RAFFLE_MIN_POT at the live QUOTRON price. "
            "This is a market move, not a code regression. Re-derive per docs/MAINNET-POT-SIZING.md: "
            "pick the pot you want in ETH, divide by the live QUOTRON price, and set the floor to that."
        );
    }

    /// Holder and leaderboard are NOT seeded. Each gets one 7-day period of tax before its first draw, and
    /// their pot is the WHOLE free balance (no fraction), so the question is purely whether a week of
    /// plausible volume clears the floor. WEEK1_VOLUME_ETH is the assumption on trial — override it to see
    /// where your own expectation lands.
    function test_weeklyEnginesClearTheirFloorsOnFirstWeekVolume() public {
        vm.createSelectFork(RPC);
        (, uint256 holderMinPot, uint256 leaderMinPot) = _floors();
        uint256 volume = vm.envOr("WEEK1_VOLUME_ETH", uint256(50 ether));

        uint256 holderPot = _quote((volume * HOLDER_BPS_OF_VOLUME) / BPS);
        uint256 leaderPot = _quote((volume * LEADER_BPS_OF_VOLUME) / BPS);

        emit log_string("--- weekly engines, first 7-day period, no seed ---");
        emit log_named_uint("assumed week-1 volume (ETH)", volume);
        emit log_named_uint("holder pot (0.25% of vol)  ", holderPot);
        emit log_named_uint("  HOLDER_MIN_POT           ", holderMinPot);
        emit log_named_uint("leaderboard pot (0.50%)    ", leaderPot);
        emit log_named_uint("  LEADERBOARD_MIN_POT      ", leaderMinPot);

        assertGe(holderPot, holderMinPot, "holder draw voids its first week at this volume - lower HOLDER_MIN_POT");
        assertGe(
            leaderPot, leaderMinPot, "leaderboard voids its first week at this volume - lower LEADERBOARD_MIN_POT"
        );
    }

    /// The quoter is a view on the same pool the adapter trades against, but a quote is not a fill. Prove
    /// the number the sizing rests on survives contact with a real swap through the real router.
    function test_liveQuoteMatchesARealFill() public {
        vm.createSelectFork(RPC);
        address quotron = IRouterView(ROUTER).quotron();

        uint256 ethIn = 0.1 ether;
        uint256 quoted = _quote(ethIn);

        vm.deal(address(this), ethIn);
        IQuotronRouter(ROUTER).buyExactEth{ value: ethIn }(1, address(this), block.timestamp + 300);
        uint256 filled = IERC20(quotron).balanceOf(address(this));

        emit log_named_uint("quoted QUOTRON out", quoted);
        emit log_named_uint("filled QUOTRON out", filled);

        assertGt(filled, 0, "real buy through the real router returned nothing");
        // 1% tolerance: the quote is taken a block earlier and the pool has its own dynamic fee.
        assertApproxEqRel(filled, quoted, 0.01e18, "quote and fill disagree - the sizing input is unreliable");
    }

    /// Reports the QUOTRON price at which the recommended floors stop working, so the margin is a number
    /// somebody can watch rather than a vibe. Asserts nothing; this one is for the launch operator.
    function test_report_breakEvenQuotronPrice() public {
        vm.createSelectFork(RPC);
        (uint256 raffleMinPot,,) = _floors();

        uint256 perQuotronWei = (SEED_ETH * 1e18) / _quote(SEED_ETH); // ETH per whole QUOTRON
        // Breaks when (SEED_ETH / price) * capBps / BPS < minPot  =>  price > SEED_ETH * capBps / (BPS * minPot)
        uint256 breakEvenWei = (SEED_ETH * RAFFLE_CAP_BPS * 1e18) / (BPS * raffleMinPot);

        emit log_string("--- how much room before the sizing breaks ---");
        emit log_named_uint("QUOTRON price now (wei ETH)", perQuotronWei);
        emit log_named_uint("breaks above (wei ETH)     ", breakEvenWei);
        emit log_named_uint("margin (x1e18 = 1.0x)      ", (breakEvenWei * 1e18) / perQuotronWei);
        emit log_string("Re-derive the floors if that margin gets close to 1.0x.");
    }
}
