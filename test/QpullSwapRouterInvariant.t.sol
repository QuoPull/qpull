// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { QpullSwapRouter } from "../src/periphery/QpullSwapRouter.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { QpullSwapRouterFixture } from "./QpullSwapRouter.t.sol";

/// @notice The stateful handler: interleaves buys and sells (from EOAs and from contract wallets relaying for a signer),
///         stray ETH / WETH / QPULL pushed at the router, deadline failures, slippage failures and price-limit (partial
///         fill) failures, and time. Every router call is wrapped in try/catch, and every property is checked right after
///         the call that could break it; a broken property is RECORDED (not reverted), so the invariant functions see it
///         even though forge discards reverted handler calls.
contract RouterHandler is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TAX_BPS = 400;
    uint256 internal constant NORMAL_BUY_MAX = 1 ether;
    uint256 internal constant NORMAL_SELL_MAX = 3000e18;
    uint256 internal constant HUGE_BUY = 1_000_000 ether; // beyond the pool's price range: must partially fill
    uint256 internal constant HUGE_SELL = 1_000_000e18;

    QpullSwapRouter internal immutable router;
    IERC20 internal immutable qpull;
    MockWETH internal immutable weth;
    PackRegistry internal immutable packs;
    LeaderboardRegistry internal immutable board;
    QpullTaxHook internal immutable hook;
    address internal immutable treasury;

    address[4] internal signers;
    address[2] internal wallets; // contract wallets: msg.sender differs from the signer (tx.origin)
    address internal stranger;

    // ── ghosts ──
    uint256 public ghostStrayEth; // ETH forced into the router and not yet swept
    uint256 public ghostStrayWeth;
    uint256 public ghostStrayQpull;
    uint256 public ghostFees; // WETH the Treasury must hold: the sum of every validated fee
    uint256 public ghostCredit; // the ETH value of every successful buy (credit goes to its signer)
    uint256 public maxWeekTouched;
    uint256 public violations;
    string public lastViolation;
    // call counters (logged by the suite)
    uint256 public buysOk;
    uint256 public sellsOk;
    uint256 public relayedOk;
    uint256 public expiredSeen;
    uint256 public slippageSeen;
    uint256 public partialFillSeen;
    uint256 public straysSent;
    uint256 public straySweeps;

    constructor(QpullSwapRouter r, IERC20 q, MockWETH w, PackRegistry p, LeaderboardRegistry b, address t) {
        router = r;
        qpull = q;
        weth = w;
        packs = p;
        board = b;
        hook = QpullTaxHook(r.hook());
        treasury = t;
        for (uint256 i; i < 4; ++i) signers[i] = makeAddr(string.concat("signer", vm.toString(i)));
        for (uint256 i; i < 2; ++i) {
            wallets[i] = makeAddr(string.concat("contractWallet", vm.toString(i)));
            vm.etch(wallets[i], hex"00"); // has code, accepts plain ETH (STOP)
        }
        stranger = makeAddr("strayer");
    }

    function _flag(string memory why) internal {
        ++violations;
        lastViolation = why;
    }

    function walletAt(uint256 i) external view returns (address) {
        return wallets[i];
    }

    // ── helpers ──

    function _week() internal returns (uint256 w) {
        w = board.currentWeek();
        if (w > maxWeekTouched) maxWeekTouched = w;
    }

    function _routerMatchesStrays(string memory tag) internal {
        if (
            address(router).balance != ghostStrayEth || weth.balanceOf(address(router)) != ghostStrayWeth
                || qpull.balanceOf(address(router)) != ghostStrayQpull
        ) _flag(string.concat(tag, ": router balances differ from the unswept strays"));
    }

    function _routerEmpty(string memory tag) internal {
        if (address(router).balance != 0 || weth.balanceOf(address(router)) != 0 || qpull.balanceOf(address(router)) != 0) {
            _flag(string.concat(tag, ": router not empty after a successful swap"));
        }
    }

    /// The hook's sell rate at this instant (QpullTaxHook._taxBps(false)), recomputed independently.
    function _sellBps() internal view returns (uint256) {
        uint256 lt = hook.launchTime();
        if (block.timestamp >= lt + hook.SELL_DECAY()) return TAX_BPS;
        uint256 decay = ((block.timestamp - lt) / hook.SELL_STEP()) * hook.SELL_STEP_BPS();
        uint256 start = hook.SELL_TAX_START_BPS();
        return decay >= start - TAX_BPS ? TAX_BPS : start - decay;
    }

    function _deadline(uint8 mode) internal view returns (uint256) {
        if (mode % 4 == 3) return block.timestamp - 1; // expired
        return block.timestamp + (mode % 4) * 60; // now, +1 min, +2 min
    }

    // ── actions ──

    /// A buy of up to 1 ETH. floorMode: 0 floor 1, 1 floor == the exact simulated output, 2 output + 1 (Slippage),
    /// 3 max (Slippage). deadlineMode 3 is expired. relay: msg.sender is a contract wallet, tx.origin a signer.
    function buy(uint256 who, uint256 valueSeed, uint8 floorMode, uint8 deadlineMode, bool relay) external {
        address signer = signers[who % 4];
        address sender = relay ? wallets[who % 2] : signer;
        uint256 value = bound(valueSeed, 1e12, NORMAL_BUY_MAX);
        uint256 deadline = _deadline(deadlineMode);
        vm.deal(sender, sender.balance + value);

        uint256 floor = 1;
        if (floorMode % 4 != 0) {
            uint256 snap = vm.snapshotState();
            vm.prank(sender, signer);
            uint256 sim;
            try router.buy{ value: value }(1, block.timestamp) returns (uint256 o) {
                sim = o;
            } catch {
                sim = 0;
            }
            vm.revertToState(snap);
            if (sim == 0) {
                _flag("buy: a normal-size buy failed in simulation");
                return;
            }
            floor = floorMode % 4 == 1 ? sim : (floorMode % 4 == 2 ? sim + 1 : type(uint256).max);
        }
        bool expectExpired = deadlineMode % 4 == 3;
        bool expectSlippage = !expectExpired && floorMode % 4 >= 2;

        uint256 w = _week();
        uint256 senderQ0 = qpull.balanceOf(sender);
        uint256 senderW0 = weth.balanceOf(sender);
        uint256 senderE0 = sender.balance;
        uint256 t0 = weth.balanceOf(treasury);
        uint256 tq0 = qpull.balanceOf(treasury);
        uint256 id0 = packs.nextPackId();
        uint256 sp0 = board.points(w, signer);
        uint256 wp0 = board.points(w, sender);
        uint256 total0 = board.totalPoints(w);

        vm.prank(sender, signer);
        try router.buy{ value: value }(floor, deadline) returns (uint256 out) {
            if (expectExpired || expectSlippage) {
                _flag("buy: succeeded where a revert was required");
                return;
            }
            ++buysOk;
            if (relay) ++relayedOk;
            if (ghostStrayEth + ghostStrayWeth + ghostStrayQpull != 0) ++straySweeps;
            _routerEmpty("buy");
            if (out < floor) _flag("buy: output below the floor");
            if (qpull.balanceOf(sender) - senderQ0 != out + ghostStrayQpull) _flag("buy: caller QPULL != output + stray QPULL");
            if (weth.balanceOf(sender) - senderW0 != ghostStrayEth + ghostStrayWeth) _flag("buy: caller WETH != stray ETH + WETH");
            if (senderE0 - sender.balance != value) _flag("buy: caller spent other than msg.value");
            uint256 fee = weth.balanceOf(treasury) - t0;
            if (fee != (value * TAX_BPS + BPS - 1) / BPS) _flag("buy: Treasury WETH fee != ceil(4% of the ETH in)");
            if (qpull.balanceOf(treasury) != tq0) _flag("buy: the Treasury received QPULL (tax must be WETH)");
            ghostFees += fee;
            // credit: to the signer only, equal to the ETH spent
            if (board.points(w, signer) - sp0 != value) _flag("buy: signer points != ETH spent");
            if (board.totalPoints(w) - total0 != value) _flag("buy: total points != ETH spent");
            if (relay && board.points(w, sender) != wp0) _flag("buy: the relaying contract wallet got points");
            uint256 id1 = packs.nextPackId();
            if (id1 > id0) {
                (address o0,,,) = packs.packs(id0);
                (address o1,,,) = packs.packs(id1 - 1);
                if (o0 != signer || o1 != signer) _flag("buy: packs not minted to tx.origin");
            }
            ghostCredit += value;
            (ghostStrayEth, ghostStrayWeth, ghostStrayQpull) = (0, 0, 0);
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (expectExpired) {
                if (sel != QpullSwapRouter.Expired.selector) _flag("buy: expired deadline did not revert Expired");
                else ++expiredSeen;
            } else if (expectSlippage) {
                if (sel != QpullSwapRouter.Slippage.selector) _flag("buy: floor above output did not revert Slippage");
                else ++slippageSeen;
            } else {
                _flag("buy: a normal buy reverted");
            }
            if (sender.balance != senderE0 || qpull.balanceOf(sender) != senderQ0 || weth.balanceOf(treasury) != t0) {
                _flag("buy: a reverted buy moved funds");
            }
            _routerMatchesStrays("reverted buy");
        }
    }

    /// A sell of up to 3,000 QPULL, from an EOA or a contract wallet (which receives the ETH). Same floor and deadline
    /// modes as buy.
    function sell(uint256 who, uint256 amountSeed, uint8 floorMode, uint8 deadlineMode, bool relay) external {
        address signer = signers[who % 4];
        address sender = relay ? wallets[who % 2] : signer;
        uint256 amount = bound(amountSeed, 1e15, NORMAL_SELL_MAX);
        qpull.transfer(sender, amount);
        vm.prank(sender);
        qpull.approve(address(router), amount);
        uint256 deadline = _deadline(deadlineMode);

        uint256 floor = 1;
        if (floorMode % 4 != 0) {
            uint256 snap = vm.snapshotState();
            vm.prank(sender, signer);
            uint256 sim;
            try router.sell(amount, 1, block.timestamp) returns (uint256 o) {
                sim = o;
            } catch {
                sim = 0;
            }
            vm.revertToState(snap);
            if (sim == 0) {
                _flag("sell: a normal-size sell failed in simulation");
                return;
            }
            floor = floorMode % 4 == 1 ? sim : (floorMode % 4 == 2 ? sim + 1 : type(uint256).max);
        }
        bool expectExpired = deadlineMode % 4 == 3;
        bool expectSlippage = !expectExpired && floorMode % 4 >= 2;

        uint256 w = _week();
        uint256 senderQ0 = qpull.balanceOf(sender);
        uint256 senderE0 = sender.balance;
        uint256 t0 = weth.balanceOf(treasury);
        uint256 tq0 = qpull.balanceOf(treasury);
        uint256 id0 = packs.nextPackId();
        uint256 total0 = board.totalPoints(w);
        uint256 bps = _sellBps();

        vm.prank(sender, signer);
        try router.sell(amount, floor, deadline) returns (uint256 ethOut) {
            if (expectExpired || expectSlippage) {
                _flag("sell: succeeded where a revert was required");
                return;
            }
            ++sellsOk;
            if (relay) ++relayedOk;
            if (ghostStrayEth + ghostStrayWeth + ghostStrayQpull != 0) ++straySweeps;
            _routerEmpty("sell");
            if (ethOut < floor) _flag("sell: output below the floor");
            if (sender.balance - senderE0 != ethOut + ghostStrayEth + ghostStrayWeth) {
                _flag("sell: caller ETH != output + stray ETH + WETH");
            }
            if (qpull.balanceOf(sender) + amount != senderQ0 + ghostStrayQpull) {
                _flag("sell: caller QPULL != -amount + stray QPULL");
            }
            uint256 fee = weth.balanceOf(treasury) - t0;
            uint256 gross = ethOut + fee;
            // fee == floor(gross * bps / BPS): fee * BPS <= gross * bps < (fee + 1) * BPS
            if (fee * BPS > gross * bps || (fee + 1) * BPS <= gross * bps) _flag("sell: Treasury WETH fee != floor(rate x gross)");
            if (gross > BPS && fee == 0) _flag("sell: an untaxed sell");
            if (qpull.balanceOf(treasury) != tq0) _flag("sell: the Treasury received QPULL (tax must be WETH)");
            if (packs.nextPackId() != id0 || board.totalPoints(w) != total0) _flag("sell: a sell earned credit");
            ghostFees += fee;
            (ghostStrayEth, ghostStrayWeth, ghostStrayQpull) = (0, 0, 0);
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (expectExpired) {
                if (sel != QpullSwapRouter.Expired.selector) _flag("sell: expired deadline did not revert Expired");
                else ++expiredSeen;
            } else if (expectSlippage) {
                if (sel != QpullSwapRouter.Slippage.selector) _flag("sell: floor above output did not revert Slippage");
                else ++slippageSeen;
            } else {
                _flag("sell: a normal sell reverted");
            }
            if (sender.balance != senderE0 || qpull.balanceOf(sender) != senderQ0 || weth.balanceOf(treasury) != t0) {
                _flag("sell: a reverted sell moved funds");
            }
            _routerMatchesStrays("reverted sell");
        }
        // leave no approval behind for the next action on this sender
        vm.prank(sender);
        qpull.approve(address(router), 0);
    }

    /// A swap far beyond the pool's price range, both directions: the extreme price limit stops it early, and the whole
    /// call reverts (the hook's PartialFill for a buy, surfaced as v4's WrappedError; the router's own for a sell).
    function oversized(uint256 who, bool isBuy) external {
        address signer = signers[who % 4];
        uint256 e0 = signer.balance;
        uint256 q0 = qpull.balanceOf(signer);
        uint256 t0 = weth.balanceOf(treasury);
        if (isBuy) {
            vm.deal(signer, e0 + HUGE_BUY);
            vm.prank(signer, signer);
            try router.buy{ value: HUGE_BUY }(1, block.timestamp) {
                _flag("oversized buy: filled beyond the range");
            } catch (bytes memory err) {
                if (err.length < 4 || bytes4(err) != CustomRevert.WrappedError.selector) {
                    _flag("oversized buy: not the hook's wrapped revert");
                } else {
                    ++partialFillSeen;
                }
            }
            if (signer.balance != e0 + HUGE_BUY) _flag("oversized buy: moved ETH");
            vm.deal(signer, e0);
        } else {
            qpull.transfer(signer, HUGE_SELL);
            vm.prank(signer);
            qpull.approve(address(router), HUGE_SELL);
            vm.prank(signer, signer);
            try router.sell(HUGE_SELL, 1, block.timestamp) {
                _flag("oversized sell: filled beyond the range");
            } catch (bytes memory err) {
                if (err.length < 4 || bytes4(err) != QpullSwapRouter.PartialFill.selector) {
                    _flag("oversized sell: not PartialFill");
                } else {
                    ++partialFillSeen;
                }
            }
            if (qpull.balanceOf(signer) != q0 + HUGE_SELL) _flag("oversized sell: moved QPULL");
            vm.prank(signer);
            qpull.approve(address(router), 0);
        }
        if (weth.balanceOf(treasury) != t0) _flag("oversized: the Treasury balance moved");
        _routerMatchesStrays("oversized");
    }

    /// Anyone pushes value at the router: ETH forced in, a WETH transfer, a QPULL transfer.
    function stray(uint8 kind, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 5 ether);
        if (kind % 3 == 0) {
            vm.deal(address(router), address(router).balance + amount); // forced ETH (selfdestruct / coinbase shape)
            ghostStrayEth += amount;
        } else if (kind % 3 == 1) {
            vm.deal(stranger, amount);
            vm.startPrank(stranger);
            weth.deposit{ value: amount }();
            weth.transfer(address(router), amount);
            vm.stopPrank();
            ghostStrayWeth += amount;
        } else {
            qpull.transfer(address(router), amount);
            ghostStrayQpull += amount;
        }
        ++straysSent;
        _routerMatchesStrays("stray");
    }

    /// Time passes (the sell tax steps down across its 48h decay, weeks roll for the board).
    function warp(uint256 secsSeed) external {
        vm.warp(block.timestamp + bound(secsSeed, 1, 13 hours));
    }
}

/// @notice Stateful invariants of QpullSwapRouter on the real vendored v4 PoolManager,
///         the real QpullTaxHook (0x1ACC), PackRegistry, LeaderboardRegistry, QPULLToken and a WETH9-shaped MockWETH, past
///         the 1-hour gate, run once per token order (64 runs x depth 100 each, set on the concrete contracts). Liquidity sits in [-6000, 6000] so an oversized swap reaches the
///         edge of the range and exercises the price-limit (partial fill) refusal, while every normal-size swap fills.
abstract contract QpullSwapRouterInvariantBase is QpullSwapRouterFixture {
    RouterHandler internal handler;

    function _range() internal pure override returns (int24, int24, uint256) {
        return (-6000, 6000, 1e24);
    }

    function setUp() public override {
        super.setUp();
        _pastGate();
        handler = new RouterHandler(router, qpull, weth, packs, board, treasury);
        qpull.transfer(address(handler), 5e26);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RouterHandler.buy.selector;
        selectors[1] = RouterHandler.sell.selector;
        selectors[2] = RouterHandler.oversized.selector;
        selectors[3] = RouterHandler.stray.selector;
        selectors[4] = RouterHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Every property checked after each call held: output >= floor, the caller received output plus every stray, the
    /// fee reached the Treasury in WETH at the exact rate, credit went to tx.origin only, and every expected revert
    /// (Expired, Slippage, PartialFill) happened and moved nothing.
    function invariant_everyCallKeptTheRouterProperties() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// Between calls the router holds exactly the strays pushed since the last successful swap, and nothing else; it
    /// never approves anything to anyone.
    function invariant_routerHoldsOnlyUnsweptStrays_andNoApprovals() public view {
        assertEq(address(router).balance, handler.ghostStrayEth(), "router ETH");
        assertEq(weth.balanceOf(address(router)), handler.ghostStrayWeth(), "router WETH");
        assertEq(qpull.balanceOf(address(router)), handler.ghostStrayQpull(), "router QPULL");
        assertEq(weth.allowance(address(router), address(manager)), 0, "router WETH approval");
        assertEq(qpull.allowance(address(router), address(manager)), 0, "router QPULL approval");
    }

    /// The Treasury holds exactly the WETH fees of the swaps that succeeded, and never any QPULL.
    function invariant_taxReachesTheTreasuryInWeth() public view {
        assertEq(weth.balanceOf(treasury), handler.ghostFees(), "Treasury WETH == sum of fees");
        assertEq(qpull.balanceOf(treasury), 0, "Treasury QPULL");
    }

    /// Game credit equals the ETH of the successful buys, and none of it ever lands on a contract wallet that relayed.
    function invariant_creditGoesToTxOriginOnly() public view {
        uint256 total;
        for (uint256 w; w <= handler.maxWeekTouched(); ++w) {
            total += board.totalPoints(w);
            for (uint256 i; i < 2; ++i) {
                assertEq(board.points(w, handler.walletAt(i)), 0, "a relaying contract wallet earned points");
            }
        }
        assertEq(total, handler.ghostCredit(), "total credit == ETH of successful buys");
    }

    function afterInvariant() external view {
        console2.log("buys ok / sells ok / relayed ok", handler.buysOk(), handler.sellsOk(), handler.relayedOk());
        console2.log("expired / slippage / partial fill", handler.expiredSeen(), handler.slippageSeen(), handler.partialFillSeen());
        console2.log("strays sent / swaps that swept strays", handler.straysSent(), handler.straySweeps());
    }
}

/// Inline config must sit on the concrete contract (forge does not carry it from the abstract base's functions).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail_on_revert = true
contract QpullSwapRouterInvariantQpullIs0Test is QpullSwapRouterInvariantBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail_on_revert = true
contract QpullSwapRouterInvariantWethIs0Test is QpullSwapRouterInvariantBase {
    function _qpullIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
