// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Treasury } from "../src/Treasury.sol";
import { ISwapAdapter } from "../src/interfaces/ISwapAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBlacklistERC20 } from "./mocks/MockBlacklistERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice A swap adapter whose fill rate is settable MID-SEQUENCE, so the invariant campaign can fuzz
///         real slippage. Like the shared MockSwapAdapter it keeps the input token and mints the output —
///         so whatever the swap did NOT deliver stays visible as the adapter's own balance. That is what
///         makes "less swap slippage" measurable rather than hand-waved: the shortfall is a balance
///         somewhere, never an untracked disappearance.
contract SlippageSwapAdapter is ISwapAdapter {
    uint256 public fillBps = 10_000; // 10_000 = 1:1, lower = slippage retained by the "pool"

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * fillBps) / 10_000;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * fillBps) / 10_000;
        require(amountOut >= minOut, "slippage");
        IMintable(tokenOut).mint(to, amountOut);
    }
}

/// @notice The treasury-split handler: fuzzed buy-tax (QPULL) and sell-tax (WETH) arrivals, keeper
///         convert() calls with and without slippage floors, per-call cap/threshold retuning, adapter
///         slippage changes, and per-vault QUOTRON blacklisting (the stuck-slice path).
/// @dev    Around every SUCCESSFUL convert it reconstructs, from balance deltas only, the exact figures
///         the contract computed internally: `wethOut` (team slice + the WETH consumed by the QUOTRON
///         leg) and each vault's `share` (balance delta plus owed delta, which is share-invariant across
///         the send-succeeded and send-blacklisted branches). Those feed the split-conservation
///         invariants, so no assertion depends on reading the contract's internal locals.
contract TreasurySplitHandler is Test {
    Treasury public immutable treasury;
    MockERC20 public immutable qpull;
    MockERC20 public immutable weth;
    MockBlacklistERC20 public immutable quotron;
    SlippageSwapAdapter public immutable qpullWeth;
    SlippageSwapAdapter public immutable wethQuotron;
    address public immutable owner;
    address public immutable team;
    address[3] public vaults; // 0 = raffle/prize, 1 = holder, 2 = leaderboard

    uint256 internal constant BPS = 10_000;
    uint256 internal constant TEAM_BPS = 2000;
    uint256 internal constant RAFFLE_BPS = 6125;
    uint256 internal constant HOLDER_BPS = 625;
    uint256 internal constant LEADERBOARD_BPS = 1250;
    uint256 internal constant PRIZE_BPS = 8000;

    // ─── ghost ledgers ────────────────────────────────────────────────────────
    uint256 public measuredTeamWeth;
    uint256 public expectedTeamWeth;
    uint256[3] public measuredShare;
    uint256[3] public expectedShare;
    uint256 public converts;
    uint256 public reverts;

    uint256 internal constant MAX_TAX = 500_000e18;

    constructor(
        Treasury treasury_,
        MockERC20 qpull_,
        MockERC20 weth_,
        MockBlacklistERC20 quotron_,
        SlippageSwapAdapter qpullWeth_,
        SlippageSwapAdapter wethQuotron_,
        address owner_,
        address team_,
        address[3] memory vaults_
    ) {
        treasury = treasury_;
        qpull = qpull_;
        weth = weth_;
        quotron = quotron_;
        qpullWeth = qpullWeth_;
        wethQuotron = wethQuotron_;
        owner = owner_;
        team = team_;
        vaults = vaults_;
    }

    // ─── actions ──────────────────────────────────────────────────────────────

    /// QPULL arriving at the Treasury. The hook takes every tax in WETH, so this models a QPULL
    /// DONATION (the only way QPULL reaches the Treasury now); it keeps convert() leg 1 under the invariant.
    function taxBuy(uint256 amountSeed) external {
        qpull.mint(address(treasury), bound(amountSeed, 0, MAX_TAX));
    }

    /// Sell-side tax: with the V4 hook, exact-in sells pay the tax in WETH.
    function taxSell(uint256 amountSeed) external {
        weth.mint(address(treasury), bound(amountSeed, 0, MAX_TAX));
    }

    /// The keeper's normal batched conversion.
    function convert() external {
        _convert(0, 0);
    }

    /// The same call with off-chain slippage floors attached — most of these revert, which is the point:
    /// a reverted convert must leave the split ledger untouched (atomic rollback).
    function convertWithFloor(uint256 wethFloorSeed, uint256 quotronFloorSeed) external {
        _convert(bound(wethFloorSeed, 0, MAX_TAX), bound(quotronFloorSeed, 0, MAX_TAX));
    }

    /// Pool-sized per-call ceilings and the min-batch gate, deliberately re-tuned mid-run.
    function setCaps(uint256 qpullCapSeed, uint256 wethCapSeed, uint256 thresholdSeed) external {
        vm.startPrank(owner);
        treasury.setMaxConvertPerCall(bound(qpullCapSeed, 1, 2 * MAX_TAX));
        treasury.setMaxWethConvertPerCall(bound(wethCapSeed, 1, 2 * MAX_TAX));
        treasury.setConvertThreshold(bound(thresholdSeed, 0, MAX_TAX));
        vm.stopPrank();
    }

    /// Move the adapters' fill rate so conversions lose real value to slippage.
    function setSlippage(uint256 legSeed, uint256 bpsSeed) external {
        uint256 bps = bound(bpsSeed, 3000, 10_000);
        if (bound(legSeed, 0, 1) == 0) qpullWeth.setFillBps(bps);
        else wethQuotron.setFillBps(bps);
    }

    /// QUOTRON per-address blacklist on ONE prize vault: its slice must be owed back to
    /// IT, never redistributed to a sibling game, and never lost.
    function blacklistVault(uint256 vaultSeed, bool on) external {
        quotron.setBlacklisted(vaults[bound(vaultSeed, 0, 2)], on);
    }

    // ─── internals ────────────────────────────────────────────────────────────

    function _convert(uint256 minWethOut, uint256 minQuotronOut) internal {
        uint256 teamBefore = weth.balanceOf(team);
        uint256 legInBefore = weth.balanceOf(address(wethQuotron));
        uint256[3] memory owedPlusBalBefore;
        for (uint256 i; i < 3; ++i) {
            owedPlusBalBefore[i] = quotron.balanceOf(vaults[i]) + treasury.quotronOwed(vaults[i]);
        }

        try treasury.convert(minWethOut, minQuotronOut) {
            ++converts;
        } catch {
            ++reverts;
            return;
        }

        // wethOut is the WETH the batch actually processed: the team slice plus the prize slice the
        // QUOTRON leg consumed. Reconstructed from balances, never read from the contract.
        uint256 teamDelta = weth.balanceOf(team) - teamBefore;
        uint256 wethOut = teamDelta + (weth.balanceOf(address(wethQuotron)) - legInBefore);
        measuredTeamWeth += teamDelta;
        expectedTeamWeth += (wethOut * TEAM_BPS) / BPS;

        // Each vault's share: (balance + owed) after minus before. Equal to the contract's own `share`
        // whether the send landed or was blacklisted into quotronOwed.
        uint256[3] memory share;
        uint256 splittable;
        for (uint256 i; i < 3; ++i) {
            share[i] = (quotron.balanceOf(vaults[i]) + treasury.quotronOwed(vaults[i])) - owedPlusBalBefore[i];
            splittable += share[i];
            measuredShare[i] += share[i];
        }
        uint256 toHolder = (splittable * HOLDER_BPS) / PRIZE_BPS;
        uint256 toLeaderboard = (splittable * LEADERBOARD_BPS) / PRIZE_BPS;
        expectedShare[0] += splittable - toHolder - toLeaderboard; // raffle takes the remainder
        expectedShare[1] += toHolder;
        expectedShare[2] += toLeaderboard;
    }
}

/// @title  InvariantTreasurySplitTest
/// @notice INVARIANT 2 (TREASURY SPLIT CONSERVATION). Every unit of tax that enters the Treasury ends in
///         a prize vault or the team account, less swap slippage — nothing is created, nothing is
///         stranded. Stated per currency, because the tax arrives in two and passes through
///         two swap legs:
///           QPULL   : treasury balance + what the QPULL->WETH pool consumed
///           WETH    : treasury balance + team + what the WETH->QUOTRON pool consumed
///           QUOTRON : the three prize vaults + a treasury residual that is EXACTLY the owed total
///         plus the ratio checks: the team takes exactly 20% of every processed batch, and the prize
///         QUOTRON splits exactly 6125/625/1250 with no cross-vault leakage.
/// @dev    Routing is frozen with lockRouting() in setUp so the campaign runs against the launch posture
///         (destinations final), and QUOTRON is the blacklist mock so the stuck-slice path is fuzzed too.
contract InvariantTreasurySplitTest is Test {
    Treasury treasury;
    MockERC20 qpull;
    MockERC20 weth;
    MockBlacklistERC20 quotron;
    SlippageSwapAdapter qpullWeth;
    SlippageSwapAdapter wethQuotron;
    TreasurySplitHandler handler;

    address prizeVault = makeAddr("prizeVault");
    address holderVault = makeAddr("holderVault");
    address leaderboardVault = makeAddr("leaderboardVault");
    address team = makeAddr("team");

    function setUp() public {
        qpull = new MockERC20();
        weth = new MockERC20();
        quotron = new MockBlacklistERC20();
        qpullWeth = new SlippageSwapAdapter();
        wethQuotron = new SlippageSwapAdapter();

        treasury = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
        treasury.setRouting(prizeVault, holderVault, leaderboardVault, team);
        treasury.setConvertThreshold(0);
        // The per-call caps ship fail-CLOSED (0 = NotConfigured): arm them wide open here
        // as the launch posture; the handler's setCaps re-tunes them to pool-sized values mid-campaign.
        // type(uint256).max is rejected onchain; a large finite value keeps "uncapped" intent.
        treasury.setMaxConvertPerCall(type(uint256).max / 2);
        treasury.setMaxWethConvertPerCall(type(uint256).max / 2);
        treasury.lockRouting(address(qpullWeth), address(wethQuotron), prizeVault, holderVault, leaderboardVault, team); // launch posture, destinations final

        address[3] memory vaults = [prizeVault, holderVault, leaderboardVault];
        handler = new TreasurySplitHandler(
            treasury, qpull, weth, quotron, qpullWeth, wethQuotron, address(this), team, vaults
        );
        treasury.setKeeper(address(handler), true); // convert() is keeper-gated

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = TreasurySplitHandler.taxBuy.selector;
        selectors[1] = TreasurySplitHandler.taxSell.selector;
        selectors[2] = TreasurySplitHandler.convert.selector;
        selectors[3] = TreasurySplitHandler.convertWithFloor.selector;
        selectors[4] = TreasurySplitHandler.setCaps.selector;
        selectors[5] = TreasurySplitHandler.setSlippage.selector;
        selectors[6] = TreasurySplitHandler.blacklistVault.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Buy-side tax: every QPULL ever taxed is either still waiting in the Treasury or was consumed by
    /// the QPULL->WETH leg. None is stranded in the adapter allowance path or burned.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_qpullTaxIsConserved() public view {
        assertEq(
            qpull.totalSupply(),
            qpull.balanceOf(address(treasury)) + qpull.balanceOf(address(qpullWeth)),
            "QPULL tax created or stranded outside the treasury and the swap leg"
        );
    }

    /// Sell-side tax plus everything the first leg produced: it ends with the team, waits in the
    /// Treasury for the next slice, or was consumed by the WETH->QUOTRON leg.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_wethTaxIsConserved() public view {
        assertEq(
            weth.totalSupply(),
            weth.balanceOf(address(treasury)) + weth.balanceOf(team) + weth.balanceOf(address(wethQuotron)),
            "WETH tax created or stranded outside team, treasury and the swap leg"
        );
    }

    /// Converted prize inventory only ever lands in the three prize vaults or waits in the Treasury.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_quotronPrizeInventoryIsConserved() public view {
        assertEq(
            quotron.totalSupply(),
            quotron.balanceOf(prizeVault) + quotron.balanceOf(holderVault)
                + quotron.balanceOf(leaderboardVault) + quotron.balanceOf(address(treasury)),
            "QUOTRON created or stranded outside the prize vaults and the treasury"
        );
    }

    /// Nothing is silently stranded: any QUOTRON still sitting in the Treasury is EXACTLY the sum of the
    /// per-vault owed slices, so every retained wei is already earmarked back to the vault it belongs to.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_treasuryResidualIsExactlyOwed() public view {
        assertEq(
            quotron.balanceOf(address(treasury)),
            treasury.quotronOwed(prizeVault) + treasury.quotronOwed(holderVault)
                + treasury.quotronOwed(leaderboardVault),
            "treasury holds QUOTRON that is owed to nobody"
        );
    }

    /// The team takes exactly 20% of every processed batch and no more, cumulatively across the whole
    /// random sequence — no per-call rounding drift accumulates in either direction.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_teamTakesExactlyTwentyPercent() public view {
        assertEq(handler.measuredTeamWeth(), handler.expectedTeamWeth(), "team WETH drifted from the 20% cut");
    }

    /// The prize QUOTRON splits 6125/625/1250 of the 8000 prize bps on every batch, and a blacklisted
    /// vault's stuck slice stays credited to IT: no game is ever funded out of a sibling's share.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_prizeSplitRatiosHoldPerVault() public view {
        assertEq(handler.measuredShare(0), handler.expectedShare(0), "raffle share drifted from 61.25%");
        assertEq(handler.measuredShare(1), handler.expectedShare(1), "holder share drifted from 6.25%");
        assertEq(handler.measuredShare(2), handler.expectedShare(2), "leaderboard share drifted from 12.5%");
    }
}
