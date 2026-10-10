// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Treasury } from "../src/Treasury.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { QuotronRouterAdapter } from "../src/adapters/QuotronRouterAdapter.sol";
import { NonRenounceableOwnable2Step } from "../src/utils/NonRenounceableOwnable2Step.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { OwnershipBase } from "../script/TransferOwnership.s.sol";

/// @notice Stands in for a Gnosis Safe: answers the shape questions the migration preflight asks, and can
///         execute calls so it is able to ACCEPT ownership. The real Safe 1.4.1 singleton, its proxy factory
///         and MultiSend are all deployed on Robinhood Chain (checked, on both 4663 and 46630), which is why
///         a Safe is the destination at all.
contract MockSafe {
    address[] internal _owners;
    uint256 internal _threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        _owners = owners_;
        _threshold = threshold_;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    /// One MultiSend batch: every accept in a single signing ceremony, all-or-nothing.
    function execBatch(address[] calldata tos, bytes[] calldata datas) external {
        require(tos.length == datas.length, "len");
        for (uint256 i; i < tos.length; ++i) {
            (bool ok,) = tos[i].call(datas[i]);
            require(ok, "safe: batched call failed");
        }
    }
}

/// @title  The ownership handover, as an executable runbook
///
/// @notice Launch requires `owner() == Timelock+multisig on every ownable contract`. This file turns that
///         requirement into executable steps against the real contracts (stage the transfers, accept them
///         in one Safe batch, check the deployer keeps nothing), so the handover is a tested procedure rather
///         than a checkbox.
///
/// @dev    The representative set is deliberate rather than exhaustive: Treasury (non-renounceable, and the
///         holder of the only same-block incident lever), PackRegistry (non-renounceable, and the live
///         ticket-price re-peg), and ClaimManager -- which was once PLAIN Ownable2Step and is
///         now non-renounceable too, because its setEngine / lockEngines wiring must survive until it is locked.
contract OwnershipMigrationTest is Test {
    Treasury treasury;
    PackRegistry packs;
    ClaimManager claims;
    MockSafe safe;

    address deployer = address(this);
    uint256 constant GENESIS = 1_800_000_000;

    function setUp() public {
        MockERC20 qpull = new MockERC20();
        MockERC20 weth = new MockERC20();
        MockERC20 quotron = new MockERC20();
        MockDrandOracle oracle = new MockDrandOracle(GENESIS, 3);

        treasury = new Treasury(address(qpull), address(weth), address(quotron), deployer);
        packs = new PackRegistry(address(oracle), 3e15, GENESIS, 1 hours, deployer);
        claims = new ClaimManager(deployer);

        // 2-of-3, the chosen launch shape: no single key can act, and one spare signer means losing a key
        // is survivable. That second property is load-bearing -- all thirteen instances are
        // NonRenounceableOwnable2Step, so an owner stuck below its own threshold could never hand off.
        address[] memory owners = new address[](3);
        for (uint256 i; i < 3; ++i) owners[i] = makeAddr(string.concat("signer", vm.toString(i)));
        safe = new MockSafe(owners, 2);
    }

    function _all() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = address(treasury);
        a[1] = address(packs);
        a[2] = address(claims);
    }

    function _stage() internal {
        treasury.transferOwnership(address(safe));
        packs.transferOwnership(address(safe));
        claims.transferOwnership(address(safe));
    }

    function _acceptAll() internal {
        address[] memory tos = _all();
        bytes[] memory datas = new bytes[](3);
        for (uint256 i; i < 3; ++i) datas[i] = abi.encodeWithSignature("acceptOwnership()");
        safe.execBatch(tos, datas);
    }

    // ── the handshake ────────────────────────────────────────────────────────

    /// STAGING MOVES NOTHING. This is the property the whole migration's safety rests on: a wrong
    /// destination costs a re-stage, never control, because Ownable2Step leaves `owner()` untouched until
    /// the DESTINATION accepts -- and the destination is a contract the deployer key cannot sign for.
    function test_stagingTransfersNoOwnership() public {
        _stage();
        address[] memory a = _all();
        for (uint256 i; i < 3; ++i) {
            assertEq(OwnableLike(a[i]).owner(), deployer, "owner must not move on staging");
            assertEq(OwnableLike(a[i]).pendingOwner(), address(safe), "but the transfer is staged");
        }
    }

    /// A staged-but-unaccepted transfer looks IDENTICAL to a finished migration from the deployer's side.
    /// That is exactly why the gate checks the destination, not the origin.
    function test_onlyTheDestinationCanAccept() public {
        _stage();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        Treasury(address(treasury)).acceptOwnership();
        assertEq(treasury.owner(), deployer, "still the deployer's");
    }

    /// The whole migration in ONE signing ceremony, all-or-nothing.
    function test_oneBatchedAcceptCompletesTheMigration() public {
        _stage();
        _acceptAll();
        address[] memory a = _all();
        for (uint256 i; i < 3; ++i) {
            assertEq(OwnableLike(a[i]).owner(), address(safe), "migrated");
            assertEq(OwnableLike(a[i]).pendingOwner(), address(0), "no transfer left pending");
        }
    }

    /// A tampered pendingOwner takes the WHOLE batch down rather than half-migrating the protocol.
    function test_aTamperedStageRevertsTheWholeBatch() public {
        _stage();
        packs.transferOwnership(makeAddr("elsewhere")); // one leg re-pointed after staging
        vm.expectRevert(); // the Safe's accept on that leg fails, so the batch fails
        _acceptAll();
        assertEq(treasury.owner(), deployer, "nothing migrated: all-or-nothing");
    }

    // ── what must still work afterwards ──────────────────────────────────────

    /// THE POINT OF NOT USING A TIMELOCK. These are the duties that made a uniform "Timelock+multisig" gate
    /// the wrong answer: keeper rotation is the only same-block incident lever, and the ticket price is a
    /// live peg against ETH. Both must remain executable by the new owner, in one transaction.
    function test_theLiveDutiesStillWorkFromTheSafe() public {
        _stage();
        _acceptAll();

        address newKeeper = makeAddr("convertWallet");
        address[] memory tos = new address[](1);
        bytes[] memory datas = new bytes[](1);
        tos[0] = address(treasury);
        datas[0] = abi.encodeCall(Treasury.setKeeper, (newKeeper, true));
        safe.execBatch(tos, datas);
        assertTrue(treasury.isKeeper(newKeeper), "keeper rotation still works, same block");
        assertEq(treasury.keeperCount(), 1, "and is countable");

        tos[0] = address(packs);
        datas[0] = abi.encodeCall(PackRegistry.setTicketPrice, (3e15 + 1e14));
        vm.warp(block.timestamp + 2 days); // clear the setter's own cooldown
        safe.execBatch(tos, datas);
        assertEq(packs.ticketPrice(), 3e15 + 1e14, "the live re-peg still works");
    }

    /// And the deployer must lose them.
    function test_theDeployerLosesEverythingAfterwards() public {
        _stage();
        _acceptAll();
        vm.expectRevert();
        treasury.setKeeper(makeAddr("x"), true);
        vm.expectRevert();
        packs.setTicketPrice(4e15);
        vm.expectRevert();
        claims.setEngine(makeAddr("e"), makeAddr("v"));
    }

    /// ONE BASE NOW. Treasury and PackRegistry cannot be renounced -- their owners have permanently live
    /// duties, so an orphaned owner would brick them. ClaimManager used to be plain Ownable2Step and COULD be
    /// renounced, justified as "spent once lockEngines has fired"; but that justification is
    /// order-dependent (a renounce before lockEngines bricks every engine's payouts), so it now refuses too.
    function test_renounceabilityIsPreservedThroughTheMigration() public {
        _stage();
        _acceptAll();
        address[] memory tos = new address[](1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("renounceOwnership()");

        tos[0] = address(treasury);
        vm.expectRevert(); // NonRenounceableOwnable2Step.OwnershipCannotBeRenounced, bubbled by the Safe
        safe.execBatch(tos, datas);
        tos[0] = address(packs);
        vm.expectRevert();
        safe.execBatch(tos, datas);
        tos[0] = address(claims); // no longer renounceable
        vm.expectRevert();
        safe.execBatch(tos, datas);
        assertEq(claims.owner(), address(safe), "ClaimManager keeps its owner");
    }

    /// The four contracts that used to be renounceable refuse a renounce BEFORE their write-once
    /// wiring lands, the window in which one renounce call from a compromised deployer key would brick them.
    function test_wiringContractsCannotBeRenouncedBeforeWiring() public {
        LeaderboardRegistry reg = new LeaderboardRegistry(GENESIS, deployer);
        QuotronRouterAdapter qra = new QuotronRouterAdapter(makeAddr("router"), makeAddr("weth"), makeAddr("quotron"), deployer);
        ClaimManager fresh = new ClaimManager(deployer);

        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        fresh.renounceOwnership();
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        reg.renounceOwnership();
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        qra.renounceOwnership();
        assertEq(fresh.owner(), deployer);
        assertEq(reg.owner(), deployer);
        assertEq(qra.owner(), deployer);
    }

    /// The two SHAPE invariants the migration preflight enforces, asserted here so a future edit that
    /// loosens either has to argue with a test rather than with a comment.
    ///
    /// They are invariants, not preferences: `threshold >= 2` because a 1-of-N is a single key wearing a
    /// contract, and `owners > threshold` because a 2-of-2 that loses one key can never act again -- and
    /// none of the thirteen instances can be renounced or transferred by anyone else, so that state is
    /// permanent. The preflight originally demanded `threshold >= 3`, which was a policy recommendation
    /// hardcoded as a safety check and would have rejected the 2-of-3 actually chosen.
    function test_theSafeShapeInvariants() public {
        address[] memory three = new address[](3);
        for (uint256 i; i < 3; ++i) three[i] = makeAddr(string.concat("s", vm.toString(i)));

        MockSafe oneOfThree = new MockSafe(three, 1);
        assertEq(oneOfThree.getThreshold(), 1, "a 1-of-N is a single key: the preflight must refuse it");

        address[] memory two = new address[](2);
        two[0] = three[0];
        two[1] = three[1];
        MockSafe twoOfTwo = new MockSafe(two, 2);
        assertEq(
            twoOfTwo.getOwners().length,
            twoOfTwo.getThreshold(),
            "a 2-of-2 has no spare signer: losing one key would be permanent"
        );

        // and the chosen shape satisfies both
        assertGe(safe.getThreshold(), 2, "no single signer can act");
        assertGt(safe.getOwners().length, safe.getThreshold(), "a spare signer exists");
    }
}

interface OwnableLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}


/// @notice A contract with code and no owner(): what DeployTestnet's mocks look like to the migration.
contract NotOwnable {
    uint256 public x;
}

/// @dev Exposes the hatch's guard on a hand-built instance set, so the MAINNET bar can be tested at all --
///      it is unreachable from a testnet dry run, which is the only place the hatch is ever used.
contract SkipHarness is OwnershipBase {
    function check(address[] calldata inst, bool[] calldata skip) external view {
        OS memory s;
        for (uint256 i; i < N; ++i) {
            s.inst[i] = inst[i];
            s.skip[i] = skip[i];
            s.name[i] = "inst";
        }
        _validateSkips(s);
    }
}

/// @title  The testnet fixture hatch, and the three things that stop it being a back door
///
/// @notice This exists because the FIRST live handover rehearsal died mid-procedure: DeployTestnet
///         substitutes a MockSwapAdapter for QuotronRouterAdapter, the mock was not Ownable, and by then
///         routing was locked so it could not be replaced. The mock has since been given the same base as
///         the contract it stands in for, so a fresh deploy migrates all thirteen -- but a hatch was still
///         needed for the deployment already on chain, and a hatch is exactly the kind of thing that
///         quietly becomes "leave this one with the deployer" if nobody tests it.
contract OwnershipSkipHatchTest is Test {
    SkipHarness h;
    address[] inst;
    bool[] mask;

    function setUp() public {
        h = new SkipHarness();
        for (uint256 i; i < 13; ++i) {
            inst.push(address(uint160(0xBEEF0000 + i)));
            mask.push(false);
        }
    }

    /// The legitimate case: a mock with no owner(), on a testnet.
    function test_aNonOwnableInstanceMayBeSkippedOffMainnet() public {
        inst[8] = address(new NotOwnable());
        mask[8] = true;
        vm.chainId(46_630);
        h.check(inst, mask); // no revert
    }

    /// GUARD 1 -- THE ONE THAT PROTECTS THE LAUNCH. Identical inputs, mainnet chain id, refused outright.
    /// On 4663 every one of the thirteen is a real Ownable contract, so this costs nothing there and closes
    /// the only path by which a testnet affordance could reach the real handover.
    function test_theHatchIsForbiddenOnMainnet() public {
        inst[8] = address(new NotOwnable());
        mask[8] = true;
        vm.chainId(4663);
        vm.expectRevert(bytes("own: NOT_OWNABLE is FORBIDDEN on mainnet (chainid 4663) -- every instance must migrate"));
        h.check(inst, mask);
    }

    /// GUARD 2 -- the load-bearing one. If it answers owner(), it migrates. No env var, no judgement call.
    /// This is what bounds the hatch's blast radius to "things that could never have been migrated anyway".
    function test_anOwnableInstanceCanNeverBeSkipped() public {
        inst[8] = address(new ClaimManager(address(this)));
        mask[8] = true;
        vm.chainId(46_630);
        vm.expectRevert(bytes("own: inst DOES have owner() -- it must migrate, not be skipped"));
        h.check(inst, mask);
    }

    /// GUARD 3 -- a hatch that can empty the set turns the permanent gate into a no-op that prints PASS.
    function test_theHatchCannotSwallowTheWholeSet() public {
        for (uint256 i; i < 13; ++i) {
            inst[i] = address(new NotOwnable());
            mask[i] = true;
        }
        vm.chainId(46_630);
        vm.expectRevert(bytes("own: NOT_OWNABLE cannot cover the whole migration set"));
        h.check(inst, mask);
    }
}