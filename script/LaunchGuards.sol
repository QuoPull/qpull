// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IDrandOracle } from "../src/interfaces/IDrandOracle.sol";

/// @dev The two reads the quicknet check needs. MockDrandOracle has neither getter, so it fails closed here.
interface IQuicknetSchedule {
    function drandGenesis() external view returns (uint256);
    function drandPeriod() external view returns (uint256);
}

/// @dev Quotron's canonical ETH router exposes its pool key; the protocol only reads the two currencies.
interface IRouterPoolKey {
    function poolKey()
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

/// @title  LaunchGuards: the pre-broadcast checks the mainnet launch scripts share
///
/// @notice Deploy.s.sol, DeployNFT.s.sol and GoLiveMainnet.s.sol each take external addresses and launch
///         timing from env. Every one of those inputs lands in an immutable or a write-once binding, so a
///         wrong value is permanent. These checks run in simulation, before anything is broadcast, and are
///         kept in one place so the three scripts cannot drift apart on what "valid" means.
library LaunchGuards {
    /// @notice Robinhood Chain mainnet.
    uint256 internal constant RH_MAINNET = 4663;

    // The live externals on RH mainnet, verified on-chain 2026-09-07 (router.poolKey() currency0 = WETH,
    // currency1 = QUOTRON). Pinned so a stale testnet value (the testnet setup uses a MockERC20 QUOTRON)
    // can never pass the mainnet preflight.
    address internal constant RH_QUOTRON = 0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F;
    address internal constant RH_QUOTRON_ROUTER = 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice drand quicknet schedule (BlsDrandOracle's constructor refuses anything else).
    uint256 internal constant DRAND_QUICKNET_GENESIS = 1_692_803_367;
    uint256 internal constant DRAND_QUICKNET_PERIOD = 3;

    /// @notice How far ahead of the Deploy run GENESIS may be. The raise can run up to LAUNCH_BACKSTOP (30
    ///         days) after Deploy, so this is generous; a GENESIS typed in milliseconds is ~1000x past it.
    uint256 internal constant MAX_GENESIS_LEAD = 60 days;

    /// @notice The oracle must be the real time-locked quicknet BlsDrandOracle, checked BEFORE the raise
    ///         binds it as an NFTCollection immutable. A codeless address locks 100% of the mint ETH
    ///         (finalizeLaunch reverts on roundAt forever, and withdrawProceeds needs `launched`). A
    ///         MockDrandOracle lets anyone post future beacons, so rarity becomes attacker-chosen; it has no
    ///         drandGenesis()/drandPeriod() getters, so it fails here.
    function requireQuicknetOracle(address oracle) internal view {
        require(oracle != address(0), "launch: DRAND_ORACLE unset");
        require(oracle.code.length > 0, "launch: DRAND_ORACLE has no code");
        (bool okG, bytes memory g) = oracle.staticcall(abi.encodeCall(IQuicknetSchedule.drandGenesis, ()));
        require(
            okG && g.length == 32 && abi.decode(g, (uint256)) == DRAND_QUICKNET_GENESIS,
            "launch: DRAND_ORACLE is not a quicknet BlsDrandOracle (drandGenesis)"
        );
        (bool okP, bytes memory p) = oracle.staticcall(abi.encodeCall(IQuicknetSchedule.drandPeriod, ()));
        require(
            okP && p.length == 32 && abi.decode(p, (uint256)) == DRAND_QUICKNET_PERIOD,
            "launch: DRAND_ORACLE is not a quicknet BlsDrandOracle (drandPeriod)"
        );
        try IDrandOracle(oracle).roundAt(block.timestamp) returns (uint64 r) {
            require(r > 0, "launch: DRAND_ORACLE.roundAt(now) returned round 0");
        } catch {
            revert("launch: DRAND_ORACLE.roundAt(now) reverts");
        }
    }

    /// @notice QUOTRON, QUOTRON_ROUTER, WETH and POOL_MANAGER are bound into immutables (Treasury, the three
    ///         vaults, both adapters, the hook). On RH mainnet they must be the pinned live contracts. On every
    ///         chain they must have code, and the router's own pool key and its quotron()/weth() getters must name
    ///         exactly the {WETH, QUOTRON} pair, which ties the QUOTRON input to the router input through state
    ///         neither env value controls.
    function requireExternals(address quotron, address router, address weth, address poolManager)
        internal
        view
    {
        if (block.chainid == RH_MAINNET) {
            require(quotron == RH_QUOTRON, "launch: QUOTRON is not the pinned RH mainnet QUOTRON");
            require(router == RH_QUOTRON_ROUTER, "launch: QUOTRON_ROUTER is not the pinned RH mainnet router");
            require(weth == RH_WETH, "launch: WETH is not the pinned RH mainnet WETH");
            require(poolManager == RH_POOL_MANAGER, "launch: POOL_MANAGER is not the pinned RH mainnet PoolManager");
        }
        require(quotron.code.length > 0, "launch: QUOTRON has no code");
        require(router.code.length > 0, "launch: QUOTRON_ROUTER has no code");
        require(weth.code.length > 0, "launch: WETH has no code");
        require(poolManager.code.length > 0, "launch: POOL_MANAGER has no code");
        (address c0, address c1,,,) = IRouterPoolKey(router).poolKey();
        (address lo, address hi) = weth < quotron ? (weth, quotron) : (quotron, weth);
        require(c0 == lo && c1 == hi, "launch: QUOTRON_ROUTER.poolKey() is not the {WETH, QUOTRON} pool");
        // The live router also names both tokens directly (fork-verified, test/fork/ConvertSplitFork.t.sol).
        require(_addressGetter(router, "quotron()") == quotron, "launch: QUOTRON_ROUTER.quotron() != QUOTRON");
        require(_addressGetter(router, "weth()") == weth, "launch: QUOTRON_ROUTER.weth() != WETH");
    }

    /// @dev A getter that must exist and return exactly one address word; anything else reads as address(0).
    function _addressGetter(address target, string memory sig) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    /// @notice Checked at deploy. GENESIS feeds five immutable clocks, and the constructors only reject 0
    ///         and cross-check equality, which a consistently wrong value passes. It must be the planned
    ///         go-live: in the future and within MAX_GENESIS_LEAD.
    /// @dev    The third require is REDUNDANT against a genuine NFTCollection and is kept only as a statement of
    ///         the launch-order intent (GENESIS >= the finalizeLaunch() timestamp). NFTCollection only ever sets
    ///         revealBoundAt to block.timestamp (finalizeLaunch and advanceRevealFallback), so it is always a past
    ///         or current time, and `genesis > block.timestamp` above already implies `genesis >= revealBoundAt`.
    ///         It can fire only for an NFT_ADDRESS that is not NFTCollection bytecode (a test stub reporting a
    ///         future revealBoundAt). It is 0 until finalizeLaunch, so it also says nothing when Deploy runs before
    ///         the raise closes; the documented order is finalizeLaunch -> Deploy -> GoLiveMainnet.
    function requireDeployGenesis(uint256 genesis, uint256 revealBoundAt) internal view {
        require(genesis > block.timestamp, "launch: GENESIS must be the planned go-live, in the future");
        require(
            genesis <= block.timestamp + MAX_GENESIS_LEAD,
            "launch: GENESIS is more than 60 days out (unix SECONDS, not milliseconds)"
        );
        require(genesis >= revealBoundAt, "launch: GENESIS is before NFTCollection.finalizeLaunch()"); // redundant, see @dev
    }
}
