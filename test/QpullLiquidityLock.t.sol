// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta
} from "../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice Minimal PoolManager stand-in for the lock's NEW logic (access control + one-shot latch + settle).
///         The seed mechanics themselves (unlock -> modifyLiquidity -> settle) are the same sequence as the
///         proven V4LiquidityHelper in test/fork/QpullWethPoolFork.t.sol and are exercised end-to-end on real
///         v4 by the go-live path (GoLiveTestnet / GoLiveMainnet, which seed ONLY through this lock; the old
///         self-owned LiquiditySeeder was deleted from GoLiveTestnet because a
///         deployer-owned position is removable); here we only need a deterministic manager that drives the
///         unlock callback and reports what the add owes.
contract StubPM {
    uint128 public lastLiquidity;
    int128 public owe0; // amount the add "owes" for currency0 (positive; charged as negative delta)
    int128 public owe1;
    bool public rejectRemove = true; // assert the lock never asks to remove

    function setOwe(int128 a0, int128 a1) external {
        owe0 = a0;
        owe1 = a1;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    uint160 public initializedAt; // 0 until the lock creates the pool
    bool public rejectSecondInit = true;

    function initialize(PoolKey memory, uint160 sqrtPriceX96) external returns (int24) {
        // v4 reverts on a second initialize of the same pool id; model that, because the lock now relies on
        // it (creation and seeding are one transaction, and a retry must not create a second pool).
        require(!(rejectSecondInit && initializedAt != 0), "stub: pool already initialized");
        initializedAt = sqrtPriceX96;
        return 0;
    }

    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory p, bytes calldata)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        require(!(rejectRemove && p.liquidityDelta < 0), "stub: lock tried to REMOVE");
        lastLiquidity = uint128(uint256(p.liquidityDelta));
        // The add owes tokens -> negative deltas to the caller (the lock pays them in _settle).
        callerDelta = _delta(-owe0, -owe1);
        feesAccrued = _delta(0, 0);
    }

    function sync(Currency) external { }
    function settle() external payable returns (uint256) {
        return 0;
    }
    function take(Currency c, address to, uint256 amt) external {
        IERC20(Currency.unwrap(c)).transfer(to, amt);
    }

    function _delta(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap(int256((uint256(uint128(a0)) << 128) | uint256(uint128(a1))));
    }
}

contract QpullLiquidityLockTest is Test {
    StubPM pm;
    MockERC20 qpull;
    MockERC20 weth;
    QpullLiquidityLock lock;

    address opener = address(this); // the deployer/initializer that seeds once
    address stranger = makeAddr("stranger");
    address hook = makeAddr("hook");

    uint128 constant LIQ = 1e21;
    uint160 constant SQRTP = 79_228_162_514_264_337_593_543_950_336; // 2**96, price 1:1
    /// seed() refuses if more than MAX_RESIDUAL_BPS (50) of either pre-funded
    /// side is left behind, because the lock has NO withdrawal path and anything not consumed is stranded
    /// FOREVER. GoLiveMainnet.s.sol already asserted this, but `_assertSeeded` is `internal view` and so
    /// runs in simulation only -- the check now lives in the bytecode instead.
    /// These fixtures previously funded 1e24 per side while the stub pulled ~4e20, i.e. they modelled a seed
    /// that stranded 99.96% of the launch capital and called it a pass. Fund what the stub actually takes.
    int128 constant OWE0 = 4e20; // tokens the add pulls for each side
    int128 constant OWE1 = 3e20;
    uint256 constant FUND0 = uint256(uint128(OWE0)); // pre-fund EXACTLY what the seed consumes
    uint256 constant FUND1 = uint256(uint128(OWE1));

    /// What the opener DECLARES it funded the lock with, in (qpull, weth) order. seed() bands the pool's
    /// actual charge against these; currency0 is whichever of the two tokens sorts lower.
    function _expQ() internal view returns (uint256) {
        return uint256(uint128(address(qpull) < address(weth) ? OWE0 : OWE1));
    }

    function _expW() internal view returns (uint256) {
        return uint256(uint128(address(qpull) < address(weth) ? OWE1 : OWE0));
    }

    function setUp() public {
        pm = new StubPM();
        qpull = new MockERC20();
        weth = new MockERC20();
        lock = new QpullLiquidityLock(
            IPoolManager(address(pm)), address(qpull), address(weth), 3000, 60, hook, opener
        );
        pm.setOwe(OWE0, OWE1);
        // fund the lock with the launch liquidity to seed
        // fund each side with what its currency will owe; qpullIs0 decides which side is which
        bool q0 = address(qpull) < address(weth);
        qpull.mint(address(lock), q0 ? FUND0 : FUND1);
        weth.mint(address(lock), q0 ? FUND1 : FUND0);
    }

    // ── the ONE entrypoint works: seeds once, latches, pays from the lock's balance ──
    function test_seed_addsLiquidity_andLatches() public {
        assertFalse(lock.seeded());
        uint256 q0 = qpull.balanceOf(address(lock));
        uint256 w0 = weth.balanceOf(address(lock));

        lock.seed(SQRTP, LIQ, _expQ(), _expW());

        assertTrue(lock.seeded(), "latched");
        assertEq(pm.lastLiquidity(), LIQ, "liquidity added");
        // the lock paid the owed amounts into the manager (currency0 = lower address of {qpull,weth})
        (address c0, address c1) =
            address(qpull) < address(weth) ? (address(qpull), address(weth)) : (address(weth), address(qpull));
        uint256 owe0 = uint256(uint128(OWE0));
        uint256 owe1 = uint256(uint128(OWE1));
        assertEq(IERC20(c0).balanceOf(address(pm)), owe0, "currency0 paid to manager");
        assertEq(IERC20(c1).balanceOf(address(pm)), owe1, "currency1 paid to manager");
        // any leftover stays LOCKED in the lock (no path out) - just confirm it did not vanish
        assertEq(qpull.balanceOf(address(lock)) + IERC20(address(qpull)).balanceOf(address(pm)), q0, "no qpull leaked");
        assertEq(weth.balanceOf(address(lock)) + IERC20(address(weth)).balanceOf(address(pm)), w0, "no weth leaked");
    }

    // ── one-shot: a second seed can never run ──
    function test_seed_isOneShot() public {
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        vm.expectRevert(QpullLiquidityLock.AlreadySeeded.selector);
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
    }

    // ── seed(0) is rejected: a no-op seed would latch and strand the pre-funded tokens ──
    function test_seed_rejectsZeroLiquidity() public {
        vm.expectRevert(QpullLiquidityLock.ZeroLiquidity.selector);
        lock.seed(SQRTP, 0, _expQ(), _expW());
        assertFalse(lock.seeded(), "a rejected seed must not latch");
    }

    // ── opener-only: no one else can trigger the seed ──
    function test_seed_onlyOpener() public {
        vm.prank(stranger);
        vm.expectRevert(QpullLiquidityLock.NotOpener.selector);
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
    }

    // ── the unlock callback is pool-manager-only (no one can drive it directly) ──
    function test_unlockCallback_onlyPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(QpullLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback(abi.encode(LIQ));
    }

    // ── the CORE GUARANTEE, at the ABI level: the lock exposes NO way to remove/withdraw/collect. Any such
    //    call reverts because the function simply does not exist on the contract (empty returndata / revert).
    //    This is belt-and-suspenders for the source-level fact that there is no negative-liquidity path. ──
    function test_noRemoveOrWithdrawSelectorsExist() public {
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        address L = address(lock);
        string[7] memory sigs = [
            "removeLiquidity(uint128)",
            "withdraw(uint256)",
            "withdrawAll()",
            "collect()",
            "collectFees()",
            "unlockAndRemove(uint128)",
            "sweep(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = L.call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, string.concat("unexpected removal path present: ", sigs[i]));
        }
        // and after seeding, the position liquidity the lock created is still recorded (never reduced here)
        assertEq(pm.lastLiquidity(), LIQ, "liquidity intact");
    }

    // ── constructor rejects zero wiring ──
    function test_constructor_rejectsZero() public {
        vm.expectRevert(QpullLiquidityLock.ZeroAddress.selector);
        new QpullLiquidityLock(IPoolManager(address(pm)), address(0), address(weth), 3000, 60, hook, opener);
    }

    // ── full-range ticks are aligned to tickSpacing ──
    function test_fullRangeTicksAligned() public view {
        int24 ts = 60;
        int24 expected = int24((int256(887_272) / int256(ts)) * int256(ts));
        assertEq(lock.tickUpper(), expected);
        assertEq(lock.tickLower(), -expected);
    }
    // ── seed consumption band + constructor checks ───────────────────────────

    /// The zero-address sweep missed tickSpacing_, which is DIVIDED BY in the constructor. Zero panics; a
    /// negative value makes maxUsable negative, so tickLower > tickUpper -- an invalid range that would only
    /// surface at seed(), by which point the lock already custodies 100% of supply and has no way out.
    function test_ctor_rejectsBadTickSpacing() public {
        vm.expectRevert(QpullLiquidityLock.BadTickSpacing.selector);
        new QpullLiquidityLock(IPoolManager(address(pm)), address(qpull), address(weth), 3000, 0, hook, opener);
        vm.expectRevert(QpullLiquidityLock.BadTickSpacing.selector);
        new QpullLiquidityLock(IPoolManager(address(pm)), address(qpull), address(weth), 3000, -60, hook, opener);
        // the upper bound: v4 refuses tickSpacing > type(int16).max at initialize (TickSpacingTooLarge), so a lock
        // built with it could be funded and never seed
        vm.expectRevert(QpullLiquidityLock.BadTickSpacing.selector);
        new QpullLiquidityLock(IPoolManager(address(pm)), address(qpull), address(weth), 3000, 32_768, hook, opener);
        QpullLiquidityLock atMax =
            new QpullLiquidityLock(IPoolManager(address(pm)), address(qpull), address(weth), 3000, 32_767, hook, opener);
        assertEq(atMax.tickUpper(), int24((int256(887_272) / 32_767) * 32_767), "32767 constructs, range aligned");
    }

    /// A mis-sized seed strands launch capital PERMANENTLY, because this contract has no withdrawal path by
    /// design. GoLiveMainnet asserted this already, but `_assertSeeded` is `internal view` and runs in
    /// SIMULATION only, so a real broadcast was unprotected. The bound is now in the bytecode -- and it is a
    /// bound on what the pool CHARGED, not on what happens to be left in this contract afterwards.
    function test_seedRefusesWhenItUnderConsumes() public {
        // declare far more than the stub will charge: exactly the mis-sizing the guard exists to catch
        uint256 declaredQ = 1e24;
        vm.expectRevert(
            abi.encodeWithSelector(
                QpullLiquidityLock.SeedConsumptionOutOfBand.selector, address(qpull), _expQ(), declaredQ
            )
        );
        lock.seed(SQRTP, LIQ, declaredQ, _expW());
        assertFalse(lock.seeded(), "a refused seed must not latch");
    }

    /// The other half of the band. Consuming MORE than was declared means the declaration did not describe
    /// the add that happened, so the opener's sizing is not to be trusted -- refuse rather than latch.
    function test_seedRefusesWhenItOverConsumes() public {
        uint256 declaredW = _expW() / 2; // the stub charges double what we claim to have funded
        vm.expectRevert(
            abi.encodeWithSelector(
                QpullLiquidityLock.SeedConsumptionOutOfBand.selector, address(weth), _expW(), declaredW
            )
        );
        lock.seed(SQRTP, LIQ, _expQ(), declaredW);
    }

    /// Rounding dust inside the 50 bps band is fine on both sides: a real full-range add never charges the
    /// declared amount to the wei.
    function test_seedToleratesDustWithinTheBand() public {
        uint256 fortyBps = 40; // inside MAX_RESIDUAL_BPS (50), on both the high and the low side
        lock.seed(SQRTP, LIQ, _expQ() + (_expQ() * fortyBps) / 10_000, _expW() - (_expW() * fortyBps) / 10_000);
        assertTrue(lock.seeded(), "a seed within the band must latch");
    }

    /// THE REGRESSION THIS SHAPE EXISTS FOR, AND THE REASON THE MEASUREMENT IS CONSUMPTION.
    ///
    /// The first version of this guard compared the post-add `balanceOf(this)` against a pre-add snapshot of
    /// the SAME balance. That is a test of a number any third party can move. The lock's address is public
    /// from the transaction that deploys it, the seed lands several blocks later, and a plain ERC-20 transfer
    /// in between inflated the snapshot while the pool still charged exactly the same amount -- so the
    /// leftover simply WAS the donation. Roughly 0.5% of the WETH side (about 0.106 ETH against a 21 ETH
    /// launch, ~$250) reverted the seed for good: 100% of supply and all of the WETH were already inside a
    /// contract that cannot hand them back, a larger `liquidity` would need QPULL that does not exist, and
    /// `initialize` cannot be repeated. A ~$250 transfer destroyed the launch.
    ///
    /// What the pool CHARGES is not donatable. This test sends the lock twenty times the tolerance on BOTH
    /// sides, immediately before the seed, and the seed must still succeed.
    function test_seedIsImmuneToAnUnsolicitedDonationBeforeIt() public {
        uint256 donationQ = (_expQ() * 1000) / 10_000; // 10%: twenty times the 50 bps band
        uint256 donationW = (_expW() * 1000) / 10_000;
        vm.prank(stranger);
        qpull.mint(address(lock), donationQ);
        vm.prank(stranger);
        weth.mint(address(lock), donationW);

        lock.seed(SQRTP, LIQ, _expQ(), _expW());

        assertTrue(lock.seeded(), "a donation must not be able to refuse the seed");
        // the donation is locked in here forever, exactly as it was before this guard existed -- harmless
        assertEq(qpull.balanceOf(address(lock)), donationQ, "donated QPULL stays locked");
        assertEq(weth.balanceOf(address(lock)), donationW, "donated WETH stays locked");
    }

    /// Under-funding is NOT the donation case and must still fail: the settle transfer runs out of balance.
    function test_seedRevertsIfTheLockWasUnderFunded() public {
        QpullLiquidityLock l2 =
            new QpullLiquidityLock(IPoolManager(address(pm)), address(qpull), address(weth), 3000, 60, hook, opener);
        qpull.mint(address(l2), _expQ() / 2);
        weth.mint(address(l2), _expW() / 2);
        vm.prank(opener);
        vm.expectRevert(); // SafeERC20: the lock cannot pay what the add costs
        l2.seed(SQRTP, LIQ, _expQ(), _expW());
        assertFalse(l2.seeded(), "a reverted seed must not latch");
    }

    /// A declaration of zero makes the band vacuous; one above type(uint128).max is unsatisfiable, because a
    /// v4 BalanceDelta is a pair of int128 -- and it would overflow the tolerance arithmetic. Both refuse.
    /// (The fifth type(uint256).max fail-open in this codebase; it does not get to be the sixth.)
    function test_seedRejectsDegenerateDeclarations() public {
        vm.expectRevert(QpullLiquidityLock.BadExpectedInput.selector);
        lock.seed(SQRTP, LIQ, 0, _expW());
        vm.expectRevert(QpullLiquidityLock.BadExpectedInput.selector);
        lock.seed(SQRTP, LIQ, _expQ(), 0);
        vm.expectRevert(QpullLiquidityLock.BadExpectedInput.selector);
        lock.seed(SQRTP, LIQ, type(uint256).max, _expW());
        vm.expectRevert(QpullLiquidityLock.BadExpectedInput.selector);
        lock.seed(SQRTP, LIQ, _expQ(), uint256(type(uint128).max) + 1);
        assertFalse(lock.seeded(), "none of those may latch");
    }

    /// The revert must unwind the one-shot latch too, so the opener can retry with a corrected size. If
    /// `seeded` survived a failed seed the lock would be bricked holding 100% of supply -- strictly worse
    /// than the problem the guard was added to prevent.
    function test_failedSeedDoesNotLatchAndCanBeRetried() public {
        vm.expectRevert();
        lock.seed(SQRTP, LIQ, 1e24, _expW()); // declared QPULL far above what the stub charges
        assertFalse(lock.seeded(), "a refused seed must NOT latch");

        // correct the declaration to what the add really costs and the retry succeeds
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        assertTrue(lock.seeded(), "retry after correcting the size succeeds");
    }

    /// The consumed amounts are reported back in (qpull, weth) order regardless of which token sorts first,
    /// so the band is applied to the right side of an asymmetric add. OWE0 != OWE1 makes this observable.
    function test_consumptionIsMappedToTheRightToken() public {
        // declaring the two sides SWAPPED must fail; declaring them correctly must pass
        vm.expectRevert();
        lock.seed(SQRTP, LIQ, _expW(), _expQ());
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        assertTrue(lock.seeded());
    }

    // ── helpers for the boundary + sort-order fixtures ───────────────────────

    /// Set the stub's per-currency charge in (qpull, weth) terms, doing the sort itself.
    function _setOweFor(uint256 qpullOwe, uint256 wethOwe) internal {
        bool q0 = address(qpull) < address(weth);
        pm.setOwe(
            int128(uint128(q0 ? qpullOwe : wethOwe)), int128(uint128(q0 ? wethOwe : qpullOwe))
        );
    }

    /// A fresh, generously funded lock — funding above the charge is harmless now that the band measures
    /// consumption, which is the whole point of the fix.
    function _freshLock() internal returns (QpullLiquidityLock l) {
        l = new QpullLiquidityLock(
            IPoolManager(address(pm)), address(qpull), address(weth), 3000, 60, hook, opener
        );
        qpull.mint(address(l), 1e24);
        weth.mint(address(l), 1e24);
    }

    // ── the pool is created BY the seed, in the same transaction ─────────────

    /// The empty-pool price walk. A v4 pool with zero liquidity has a price ANY address can move to an
    /// arbitrary value for gas alone (SwapMath charges nothing at zero liquidity, and PoolManager creates no
    /// settlement obligation for a zero delta), and every token amount an add costs is a pure function of
    /// that price. So the consumption band -- which is otherwise unmovable by strangers -- was still hostage
    /// to a number a stranger controlled, for the five transactions between `initialize` and `seed`. The lock
    /// now creates the pool ITSELF, in the same transaction as the add. There is no window.
    function test_seed_createsThePoolInTheSameTransaction() public {
        assertEq(pm.initializedAt(), 0, "no pool before the seed");
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        assertEq(pm.initializedAt(), SQRTP, "the seed created the pool at the price it was given");
        assertEq(pm.lastLiquidity(), LIQ, "and added the liquidity in the same call");
    }

    /// A failed seed must leave NO pool behind either, or the retry hits "already initialized" and the launch
    /// is bricked with 100% of supply already inside the lock. The revert unwinds creation too.
    function test_seed_failedSeedLeavesNoPoolAndCanRetry() public {
        vm.expectRevert();
        lock.seed(SQRTP, LIQ, 1e24, _expW()); // declared QPULL far above the charge
        assertEq(pm.initializedAt(), 0, "a reverted seed must not leave a pool behind");
        lock.seed(SQRTP, LIQ, _expQ(), _expW());
        assertEq(pm.initializedAt(), SQRTP, "the retry creates it");
    }

    function test_seed_rejectsZeroPrice() public {
        vm.expectRevert(QpullLiquidityLock.BadExpectedInput.selector);
        lock.seed(0, LIQ, _expQ(), _expW());
        assertFalse(lock.seeded());
    }

    // ── the band edge is EXACTLY 50 bps, pinned from both sides ──────────────

    /// Without this pair, MAX_RESIDUAL_BPS was pinned only to roughly [41, 3333]: setting it to 3000 left
    /// every test green while making ~7 ETH and ~300M QPULL silently strandable on the shipped launch. The
    /// tolerate/refuse tests both sat far from the edge, which is the classic shape of a test that measures
    /// nothing. Charge exactly the declared amount minus exactly 50 bps: accepted.
    function test_bandAcceptsExactlyFiftyBpsUnder() public {
        uint256 expQ = _expQ();
        uint256 tol = (expQ * 50) / 10_000;
        _setOweFor(expQ - tol, _expW());
        lock.seed(SQRTP, LIQ, expQ, _expW());
        assertTrue(lock.seeded(), "exactly 50 bps under is inside the band");
    }

    /// One wei past the edge: refused. This half is what kills a widened constant.
    function test_bandRefusesOneWeiPastFiftyBps() public {
        uint256 expQ = _expQ();
        uint256 tol = (expQ * 50) / 10_000;
        _setOweFor(expQ - tol - 1, _expW());
        QpullLiquidityLock l = _freshLock();
        vm.expectRevert(
            abi.encodeWithSelector(
                QpullLiquidityLock.SeedConsumptionOutOfBand.selector, address(qpull), expQ - tol - 1, expQ
            )
        );
        l.seed(SQRTP, LIQ, expQ, _expW());
    }

    /// The same edge on the over-charge side and on the WETH leg, so neither bound nor either token is
    /// pinned by accident. Two tests, not one: a successful seed CREATES the pool, and the stub refuses a
    /// second initialize exactly as v4 does — which is itself the property the atomic seed relies on.
    function test_bandAcceptsExactlyFiftyBpsOverOnTheWethLeg() public {
        uint256 expW = _expW();
        uint256 tol = (expW * 50) / 10_000;
        _setOweFor(_expQ(), expW + tol);
        weth.mint(address(lock), tol); // the lock must hold what the add now charges
        lock.seed(SQRTP, LIQ, _expQ(), expW);
        assertTrue(lock.seeded(), "exactly 50 bps over is inside the band");
    }

    function test_bandRefusesOneWeiPastFiftyBpsOverOnTheWethLeg() public {
        uint256 expW = _expW();
        uint256 tol = (expW * 50) / 10_000;
        _setOweFor(_expQ(), expW + tol + 1);
        QpullLiquidityLock l = _freshLock();
        vm.expectRevert(
            abi.encodeWithSelector(
                QpullLiquidityLock.SeedConsumptionOutOfBand.selector, address(weth), expW + tol + 1, expW
            )
        );
        l.seed(SQRTP, LIQ, _expQ(), expW);
    }

    // ── the reversed sort order is real code, not dead code ──────────────────

    /// Foundry deploys the two mocks at CREATE addresses that make `qpull < weth` true in every other test in
    /// this file, permanently, so the `qpullIs0 == false` arm of unlockCallback's (qpull, weth) mapping never
    /// executed: deleting the ternary outright left all 468 tests green. Which token sorts lower on mainnet
    /// depends on the deployer's nonce and is pinned nowhere, and getting it wrong bands 21e18 against 1e27.
    /// Force the inverted order with vm.etch and exercise the other arm.
    function test_consumptionMappingHoldsWhenWethSortsFirst() public {
        address hiQpull = address(0xfFFF000000000000000000000000000000000FFF);
        MockERC20 template = new MockERC20();
        vm.etch(hiQpull, address(template).code);
        assertTrue(hiQpull > address(weth), "fixture must invert the sort order");

        QpullLiquidityLock l = new QpullLiquidityLock(
            IPoolManager(address(pm)), hiQpull, address(weth), 3000, 60, hook, opener
        );
        // currency0 is now WETH (charged OWE0); currency1 is QPULL (charged OWE1)
        pm.setOwe(OWE0, OWE1);
        uint256 qCharge = uint256(uint128(OWE1));
        uint256 wCharge = uint256(uint128(OWE0));
        MockERC20(hiQpull).mint(address(l), qCharge);
        weth.mint(address(l), wCharge);

        // declaring them the way the OTHER sort order would must fail, on the QPULL leg
        vm.expectRevert(
            abi.encodeWithSelector(
                QpullLiquidityLock.SeedConsumptionOutOfBand.selector, hiQpull, qCharge, wCharge
            )
        );
        l.seed(SQRTP, LIQ, wCharge, qCharge);

        l.seed(SQRTP, LIQ, qCharge, wCharge);
        assertTrue(l.seeded(), "the reversed-order arm maps consumption correctly");
    }
}
