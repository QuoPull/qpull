// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "../script/Deploy.s.sol";

/// Quotron canonical ETH router stand-in: the three reads LaunchGuards.requireExternals makes.
contract DP1Router {
    address public quotron;
    address public weth;

    constructor(address q, address w) {
        quotron = q;
        weth = w;
    }

    function poolKey() external view returns (address, address, uint24, int24, address) {
        (address a, address b) = weth < quotron ? (weth, quotron) : (quotron, weth);
        return (a, b, 0x800000, 60, address(0));
    }
}

/// The two NFTCollection reads Deploy's preflight makes.
contract DP1Nft {
    address public drand;
    uint256 public revealBoundAt;

    constructor(address d) {
        drand = d;
    }

    function setRevealBoundAt(uint256 t) external {
        revealBoundAt = t;
    }
}

/// @notice Deploy.s.sol's pre-broadcast checks (convert threshold, GENESIS, oracle, externals, keeper, bands, pool key),
///         exercised through the REAL `_preflight` with a hand-built config. `_cfg` is plain env reads.
contract DeployPreflightTest is Test, Deploy {
    uint256 constant NOW = 1_800_000_000;
    address me = makeAddr("deployer");

    function preflightExt(Ext memory e) external view {
        _preflight(e, me);
    }

    function tickSpacingExt(uint256 v) external pure returns (int24) {
        return _tickSpacing(v);
    }

    function feeExt(uint256 v) external pure returns (uint24) {
        return _u24(v);
    }

    function _good() internal returns (Ext memory e) {
        vm.warp(NOW);
        e.quotron = deployCode("MockERC20.sol:MockERC20");
        e.weth = deployCode("MockERC20.sol:MockERC20");
        e.poolManager = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        e.quotronRouter = address(new DP1Router(e.quotron, e.weth));
        e.oracle = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        e.nft = address(new DP1Nft(e.oracle));
        e.team = makeAddr("team");
        e.keeper = makeAddr("convertKeeper");
        e.genesis = NOW + 3 days;
        e.convertThreshold = 1000e18;
        e.earlyBuyCapWei = 0.25 ether;
    }

    function _expect(Ext memory e, bytes memory reason) internal {
        vm.expectRevert(reason);
        this.preflightExt(e);
    }

    function test_goodConfigPasses() public {
        this.preflightExt(_good());
    }

    /// CONVERT_THRESHOLD is required and at least one whole QPULL, so dust QPULL cannot be used to grief convert().
    function test_convertThresholdMustBeAtLeastOneQpull() public {
        Ext memory e = _good();
        bytes memory reason = bytes("deploy: CONVERT_THRESHOLD must be >= 1e18 QPULL (dust-QPULL convert grief)");
        e.convertThreshold = 0;
        _expect(e, reason);
        e.convertThreshold = 1e18 - 1;
        _expect(e, reason);
        e.convertThreshold = 1e18;
        this.preflightExt(e);
    }

    /// GENESIS in the future, not in milliseconds, not before finalizeLaunch.
    function test_genesisBounds() public {
        Ext memory e = _good();
        e.genesis = NOW;
        _expect(e, bytes("launch: GENESIS must be the planned go-live, in the future"));
        e.genesis = (NOW + 3 days) * 1000; // milliseconds
        _expect(e, bytes("launch: GENESIS is more than 60 days out (unix SECONDS, not milliseconds)"));
        e.genesis = NOW + 3 days;
        // Reachable only through this stub: a real NFTCollection's revealBoundAt is always <= block.timestamp, so
        // the "in the future" require above already implies it (see LaunchGuards.requireDeployGenesis @dev).
        DP1Nft(e.nft).setRevealBoundAt(NOW + 4 days);
        _expect(e, bytes("launch: GENESIS is before NFTCollection.finalizeLaunch()"));
    }

    /// Only the quicknet oracle the NFT was built against.
    function test_oracleMustBeQuicknetAndTheNftsOwn() public {
        Ext memory e = _good();
        address realOracle = e.oracle;
        e.oracle = deployCode("MockDrandOracle.sol:MockDrandOracle", abi.encode(NOW, uint256(3)));
        _expect(e, bytes("launch: DRAND_ORACLE is not a quicknet BlsDrandOracle (drandGenesis)"));
        e.oracle = makeAddr("codelessOracle");
        _expect(e, bytes("launch: DRAND_ORACLE has no code"));
        e.oracle = deployCode("BlsDrandOracle.sol:BlsDrandOracle", abi.encode(uint256(1_692_803_367), uint256(3)));
        assertTrue(e.oracle != realOracle, "a second, real oracle");
        _expect(e, bytes("deploy: DRAND_ORACLE != the oracle the NFT was built against -- set it to NFTCollection.drand()"));
    }

    /// Externals must be real and mutually consistent; on 4663 they are pinned.
    function test_externals() public {
        Ext memory e = _good();
        address q = e.quotron;
        e.quotron = deployCode("MockERC20.sol:MockERC20"); // a stale QUOTRON the router does not trade
        _expect(e, bytes("launch: QUOTRON_ROUTER.poolKey() is not the {WETH, QUOTRON} pool"));
        e.quotron = q;
        e.quotronRouter = makeAddr("codelessRouter");
        _expect(e, bytes("launch: QUOTRON_ROUTER has no code"));
        e.quotronRouter = address(new DP1Router(q, e.weth));
        this.preflightExt(e);
        vm.chainId(4663);
        _expect(e, bytes("launch: QUOTRON is not the pinned RH mainnet QUOTRON"));
    }

    /// The keeper is required and is never the deployer; the early-buy cap is required.
    function test_keeperAndEarlyBuyCap() public {
        Ext memory e = _good();
        e.keeper = me;
        _expect(e, bytes("deploy: KEEPER must be the convert keeper, not the deployer"));
        e.keeper = makeAddr("convertKeeper");
        e.earlyBuyCapWei = 0;
        _expect(e, bytes("deploy: EARLY_BUY_CAP_WEI must be > 0"));
    }

    // ── ticket price and early-buy cap magnitude bands on 4663 ──────────────────────────────────────────────

    bytes constant TICKET_BAND =
        bytes("deploy: TICKET_PRICE_WETH is outside [1e14, 1e17] wei on 4663 (a unit slip?); to launch with it anyway set ACCEPT_TICKET_PRICE_WETH to exactly that value");
    bytes constant CAP_BAND =
        bytes("deploy: EARLY_BUY_CAP_WEI is outside [1e16, 5e18] wei on 4663 (a unit slip?); to launch with it anyway set ACCEPT_EARLY_BUY_CAP_WEI to exactly that value");

    /// A config that passes every OTHER 4663 check: stand-ins etched at the pinned RH externals (code is all the pins and
    /// the router reads need), the real quicknet oracle and the launch values.
    function _goodMainnet() internal returns (Ext memory e) {
        e = _good();
        vm.chainId(4663);
        vm.etch(0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F, e.quotron.code); // RH QUOTRON
        vm.etch(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, e.weth.code); // RH WETH
        vm.etch(0x8366a39CC670B4001A1121B8F6A443A643e40951, e.poolManager.code); // RH PoolManager
        address router = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18; // RH Quotron ETH router
        vm.etch(router, e.quotronRouter.code);
        vm.store(router, bytes32(uint256(0)), bytes32(uint256(uint160(0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F))));
        vm.store(router, bytes32(uint256(1)), bytes32(uint256(uint160(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73))));
        e.quotron = 0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F;
        e.weth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        e.poolManager = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        e.quotronRouter = router;
        e.ticketPrice = 0.003 ether; // the launch ticket price
        e.earlyBuyCapWei = 0.25 ether; // the launch early-buy cap
    }

    function test_launchValuesPass_onMainnet() public {
        this.preflightExt(_goodMainnet());
    }

    /// Both band edges are inclusive; one wei outside either edge is refused, and so is a 1000x slip either way.
    function test_ticketPriceBand_edgesAndSlips() public {
        Ext memory e = _goodMainnet();
        e.ticketPrice = 1e14;
        this.preflightExt(e);
        e.ticketPrice = 1e17;
        this.preflightExt(e);
        e.ticketPrice = 1e14 - 1;
        _expect(e, TICKET_BAND);
        e.ticketPrice = 1e17 + 1;
        _expect(e, TICKET_BAND);
        e.ticketPrice = 3 ether; // 0.003 typed as 3
        _expect(e, TICKET_BAND);
        e.ticketPrice = 3e12; // 1000x low
        _expect(e, TICKET_BAND);
    }

    function test_earlyBuyCapBand_edgesAndSlips() public {
        Ext memory e = _goodMainnet();
        e.earlyBuyCapWei = 1e16;
        this.preflightExt(e);
        e.earlyBuyCapWei = 5e18;
        this.preflightExt(e);
        e.earlyBuyCapWei = 1e16 - 1;
        _expect(e, CAP_BAND);
        e.earlyBuyCapWei = 5e18 + 1;
        _expect(e, CAP_BAND);
        e.earlyBuyCapWei = 250 ether; // 0.25 typed as 250
        _expect(e, CAP_BAND);
    }

    /// The override admits exactly the declared out-of-band value, and nothing else.
    function test_explicitOverride_acceptsOnlyThatExactValue() public {
        Ext memory e = _goodMainnet();
        e.ticketPrice = 0.2 ether;
        e.acceptTicketPrice = 0.2 ether + 1;
        _expect(e, TICKET_BAND);
        e.acceptTicketPrice = 0.2 ether;
        this.preflightExt(e);

        e.earlyBuyCapWei = 6 ether;
        e.acceptEarlyBuyCap = 5 ether;
        _expect(e, CAP_BAND);
        e.acceptEarlyBuyCap = 6 ether;
        this.preflightExt(e);
    }

    /// Off 4663 the bands do not apply (testnet and local rehearsals keep their own values).
    function test_bandsOnlyOnMainnet() public {
        Ext memory e = _good();
        e.ticketPrice = 3 ether;
        e.earlyBuyCapWei = 250 ether;
        this.preflightExt(e);
    }

    /// The QPULL pool key inputs (tick spacing and fee) are range-checked before the casts.
    function test_poolKeyInputBounds() public {
        assertEq(this.tickSpacingExt(60), int24(60));
        assertEq(this.tickSpacingExt(32_767), int24(32_767));
        vm.expectRevert(bytes("deploy: QPULL_POOL_TICK_SPACING must be in [1, 32767]"));
        this.tickSpacingExt(0);
        vm.expectRevert(bytes("deploy: QPULL_POOL_TICK_SPACING must be in [1, 32767]"));
        this.tickSpacingExt(32_768);
        assertEq(this.feeExt(3000), uint24(3000));
        vm.expectRevert(bytes("deploy: QPULL_POOL_FEE must be a static fee <= 1000000 (not the Quotron 0x800000)"));
        this.feeExt(8_388_608);
    }
}
