// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { SeedRaffleVault } from "../script/SeedRaffleVault.s.sol";
import { GoLiveHarness } from "./regression/GoLiveLpEthUnchecked.t.sol";

interface ISRLNft {
    function seedTreasury() external view returns (address);
    function seedReserve() external view returns (uint256);
    function taxHook() external view returns (address);
}

interface ISRLPacks {
    function engine() external view returns (address);
}

/// A View quoter stand-in consistent with the LaunchWorld Quotron router mock (1 wei ETH -> 1000 wei QUOTRON).
contract SRLQuoter {
    function quoteBuyExactEth(uint256 ethIn, address) external pure returns (uint256, uint256, uint256, uint256) {
        return (ethIn * 1000, 0, 0, 0);
    }
}

/// The REAL script body with its env seam pointed at storage.
contract SRLSeedRunner is SeedRaffleVault {
    mapping(bytes32 => address) internal a;
    mapping(bytes32 => uint256) internal u;
    mapping(bytes32 => bool) internal isSet;

    function setA(string memory k, address v) external {
        a[keccak256(bytes(k))] = v;
        isSet[keccak256(bytes(k))] = true;
    }

    function setU(string memory k, uint256 v) external {
        u[keccak256(bytes(k))] = v;
        isSet[keccak256(bytes(k))] = true;
    }

    function _envAddress(string memory k) internal view override returns (address) {
        require(isSet[keccak256(bytes(k))], string.concat("test env unset: ", k));
        return a[keccak256(bytes(k))];
    }

    function _envUint(string memory k) internal view override returns (uint256) {
        require(isSet[keccak256(bytes(k))], string.concat("test env unset: ", k));
        return u[keccak256(bytes(k))];
    }

    function _envOrUint(string memory k, uint256 d) internal view override returns (uint256) {
        return isSet[keccak256(bytes(k))] ? u[keccak256(bytes(k))] : d;
    }

    function runExt(address me) external returns (uint256) {
        return _run(me);
    }
}

/// @notice The SeedRaffleVault graph check on the in-process launch world, no fork: a real NFTCollection raise, the real
///         GoLiveMainnet body, the real hook, PackRegistry, RaffleEngine, ClaimManager and BaseVaults, with a mock
///         QUOTRON and Quotron router. Before the fix, the orphan engine/vault pair an aborted Deploy broadcast leaves
///         behind passed every check and received the whole prize seed. Now it is
///         refused through the launch's write-once graph, the live pair still seeds, and an engine of the wrong kind
///         bound to the live leaderboard registry and vault is refused by the same graph check (PackRegistry.engine()
///         differs). The named openingDone() refusal for a non-raffle engine is exercised only by
///         test/fork/SeedRaffleVaultFork.t.sol (SRNotARaffle): in a real launch the registry's write-once engine is
///         always the RaffleEngine, so no in-process graph can reach it.
contract SeedRaffleVaultLiveGraphTest is GoLiveHarness {
    uint256 constant SEED = (PAID * PRICE * 1000) / 10_000; // the 10% seed bucket of the LaunchWorld raise

    SRLSeedRunner runner;
    address seedWallet;
    address liveRaffle;

    function _launch() internal {
        _deploy(_opts(QPULL_HI));
        _setEnv(BUCKET);
        _runGoLive();
        assertTrue(QpullLiquidityLock(lockT).seeded(), "premise: seeded by GoLiveMainnet");
        assertEq(ISRLNft(nftT).taxHook(), hookT, "premise: the NFT is wired to the launched hook (Deploy.s.sol shape)");
        liveRaffle = ISRLPacks(address(QpullTaxHook(hookT).packRegistry())).engine();
        seedWallet = ISRLNft(nftT).seedTreasury();
        assertEq(ISRLNft(nftT).seedReserve(), 0, "premise: go-live paid the seed bucket out");
        assertEq(seedWallet.balance, SEED, "premise: the seed wallet holds the bucket");

        runner = new SRLSeedRunner();
        runner.setA("NFT_ADDRESS", nftT);
        runner.setA("QUOTRON", quotronT);
        runner.setA("QUOTRON_ROUTER", routerT);
        runner.setA("VIEW_QUOTER", address(new SRLQuoter()));
        runner.setU("SEED_ETH_WEI", SEED);
        vm.deal(DEFAULT_SENDER, DEFAULT_SENDER.balance + 10 ether); // the broadcaster pays the buy in-process
    }

    /// The orphan pair (same constructor shapes as Deploy.s.sol, never wired) is refused before anything is bought.
    function test_orphanRaffleAndVault_refused() public {
        _launch();
        address oracle2 = deployCode("MockDrandOracle.sol:MockDrandOracle", abi.encode(worldT0, uint256(3)));
        vm.startPrank(deployer);
        address orphanVault = deployCode("BaseVault.sol:BaseVault", abi.encode(quotronT, deployer));
        address orphanClaims = deployCode("ClaimManager.sol:ClaimManager", abi.encode(deployer));
        address orphanPacks = deployCode(
            "PackRegistry.sol:PackRegistry", abi.encode(oracle2, uint256(3e15), worldGen, uint256(1 hours), deployer)
        );
        address orphanRaffle = deployCode(
            "RaffleEngine.sol:RaffleEngine",
            abi.encode(
                oracle2, orphanPacks, orphanVault, orphanClaims, worldGen, uint256(3), uint256(1), uint256(1000e18), uint256(1000), deployer
            )
        );
        vm.stopPrank();
        // it even holds QUOTRON already, like a vault a stray transfer reached
        (bool ok,) = quotronT.call(abi.encodeWithSignature("mint(address,uint256)", orphanVault, 1e18));
        assertTrue(ok, "premise: mock QUOTRON mint");

        runner.setA("RAFFLE_ENGINE", orphanRaffle);
        runner.setA("PRIZE_VAULT", orphanVault);
        uint256 live0 = IERC20(quotronT).balanceOf(prizeT);
        vm.expectRevert(
            bytes(
                "seed: RAFFLE_ENGINE is not the live raffle (NFTCollection.taxHook().packRegistry().engine() differs): an orphan from an aborted deploy?"
            )
        );
        runner.runExt(seedWallet);
        assertEq(IERC20(quotronT).balanceOf(orphanVault), 1e18, "the orphan vault received nothing");
        assertEq(IERC20(quotronT).balanceOf(prizeT), live0, "and nothing moved anywhere");
    }

    /// A LeaderboardEngine wired to the live leaderboard registry, the live leaderboard vault and the live ClaimManager,
    /// offered as RAFFLE_ENGINE with that vault as PRIZE_VAULT, is refused by the live-graph check: it is not
    /// NFTCollection.taxHook().packRegistry().engine(). (This is not the named openingDone() refusal; see the contract
    /// notice.)
    function test_leaderboardEngineAsRaffle_refusedByTheLiveGraph() public {
        _launch();
        address lbReg = address(QpullTaxHook(hookT).leaderboardRegistry());
        vm.prank(deployer);
        address lbEng = deployCode(
            "LeaderboardEngine.sol:LeaderboardEngine",
            abi.encode(lbReg, lbT, claimsT, worldGen, uint256(1), uint256(1000e18), deployer)
        );
        runner.setA("RAFFLE_ENGINE", lbEng);
        runner.setA("PRIZE_VAULT", lbT);
        vm.expectRevert(
            bytes(
                "seed: RAFFLE_ENGINE is not the live raffle (NFTCollection.taxHook().packRegistry().engine() differs): an orphan from an aborted deploy?"
            )
        );
        runner.runExt(seedWallet);
    }

    /// The live pair, reached through the same graph, passes and the seed lands in the live prize vault.
    function test_livePair_seedsTheLivePrizeVault() public {
        _launch();
        runner.setA("RAFFLE_ENGINE", liveRaffle);
        runner.setA("PRIZE_VAULT", prizeT);
        uint256 live0 = IERC20(quotronT).balanceOf(prizeT);
        uint256 arrived = runner.runExt(seedWallet);
        assertEq(arrived, SEED * 1000, "the whole seed bought at the mock rate");
        assertEq(IERC20(quotronT).balanceOf(prizeT), live0 + arrived, "into the live prize vault");
    }
}
