// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LaunchGuards } from "./LaunchGuards.sol";

/// @dev Quotron's canonical View quoter (the one keeper.js prices convert leg 2 with).
interface ISeedViewQuoter {
    function quoteBuyExactEth(uint256 ethIn, address payer)
        external
        view
        returns (uint256 quotronOut, uint256 feeBps, uint256 feeWeth, uint256 poolWethIn);
}

/// @dev Quotron's canonical ETH router, as the protocol already uses it (QuotronRouterAdapter).
interface ISeedQuotronRouter {
    function buyExactEth(uint256 minQuotronOut, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 quotronOut);
    function quotron() external view returns (address);
}

/// @dev What the seed routing reads off NFTCollection: who holds the seed bucket, and how big it can be.
interface ISeedNftLedger {
    function launched() external view returns (bool);
    function seedTreasury() external view returns (address);
    function seedReserve() external view returns (uint256);
    function totalMinted() external view returns (uint256);
    function mintPrice() external view returns (uint256);
    function SEED_BPS() external view returns (uint256);
    function RESERVE_CAP() external view returns (uint256);
    function reserveMinted() external view returns (bool);
    function taxHook() external view returns (address);
}

interface ISeedRaffle {
    function vault() external view returns (address);
    function openingDone() external view returns (bool);
    function packs() external view returns (address);
    function claimManager() external view returns (address);
}

interface ISeedVault {
    function quotron() external view returns (address);
    function freeBalance() external view returns (uint256);
    function unclaimedReserve() external view returns (uint256);
    function controller() external view returns (address);
}

/// @dev The write-once launch graph the seed destination is bound through (NFT -> hook -> registry -> engine).
interface ISeedHook {
    function nft() external view returns (address);
    function packRegistry() external view returns (address);
}

interface ISeedPackRegistry {
    function engine() external view returns (address);
}

interface ISeedClaimManager {
    function engineVault(address engine) external view returns (address);
    function enginesLocked() external view returns (bool);
}

/// @title  SEED THE DAILY RAFFLE: the mint's 10% prize seed, as QUOTRON, into RaffleEngine's vault
///
/// @notice No other script routes the 10% seed bucket into the vaults. NFTCollection has no
///         split logic for it; withdrawProceeds pays the seed ETH to `seedTreasury` and that address decides where it
///         lands. OWNER DECISION: the prize seed funds the DAILY RAFFLE vault ONLY (docs/MAINNET-POT-SIZING.md: holder
///         and leaderboard start at zero and fill from tax). This is the smallest checkable path for that decision:
///         ONE call, `QUOTRON_ROUTER.buyExactEth{value: SEED_ETH_WEI}(minOut, RaffleEngine.vault(), deadline)`, sent
///         by whoever holds SEED_TREASURY. Nothing about who SEED_TREASURY must be changes.
///
///         WHEN: after the seed bucket has left the NFT (GoLiveMainnet's withdrawProceeds pays it; do NOT call
///         withdrawProceeds before go-live) and BEFORE the raffle's one-time opening draw
///         (genesis + 48h), which sizes its pot off the vault. Seeding after the opening still works; the seed then
///         funds daily draws, and the script says so. If the bucket is still in the NFT after go-live (seedReserve
///         != 0: the payout to SEED_TREASURY failed, and NFTCollection restored the bucket for a retry), the remedy is
///         to call NFTCollection.withdrawProceeds() again; it is permissionless once the mint is finalized.
///
///         WHO: SEED_TREASURY is a separate regular wallet used only for the prize seed (DeployNFT
///         preflights it: distinct from the deployer key and TEAM_WALLET, no code, receives ETH). This script refuses
///         any other sender.
///
///         RUN FROM THE SEED_TREASURY KEY:
///           forge script script/SeedRaffleVault.s.sol --rpc-url rh --account seedTreasury            (simulate)
///           forge script script/SeedRaffleVault.s.sol --rpc-url rh --account seedTreasury --broadcast
///         If SEED_TREASURY is a contract wallet (a Safe), run the simulation with `--sender <SEED_TREASURY>` and no
///         --broadcast: every check below runs against that sender, and the script prints the exact to / value / data
///         to submit from the Safe. Re-run the simulation immediately before signing; the floor is a live quote.
///
///         ENV (vm.envAddress / vm.envUint revert if unset):
///           NFT_ADDRESS        the NFTCollection: seedTreasury == sender, the seed bucket has been paid out, and the
///                              bounds on its size
///           RAFFLE_ENGINE      the daily raffle; its vault() is the destination. It must be THE LIVE
///                              engine of THIS launch, reached through write-once bindings no env value controls:
///                              NFTCollection.taxHook() (set by Deploy.s.sol) -> hook.nft() == NFT_ADDRESS ->
///                              hook.packRegistry().engine() == RAFFLE_ENGINE -> RaffleEngine.packs() == that registry;
///                              and the vault's controller is a ClaimManager whose frozen map binds RAFFLE_ENGINE to it.
///                              An orphan engine/vault pair left by an aborted Deploy broadcast fails every one of these.
///           PRIZE_VAULT        the Deploy export: must equal RaffleEngine.vault() (double entry for the destination)
///           QUOTRON, QUOTRON_ROUTER, VIEW_QUOTER   pinned on 4663 (VIEW_QUOTER = 0xb8960fdC8A0Be155d196C2795b75747763562df2)
///           SEED_ETH_WEI       wei of ETH to convert. Must lie inside the mint's seed bucket, bounded on-chain from
///                              totalMinted / mintPrice / the reserve latch (10% of what the mint raised)
///         OPTIONAL:
///           SEED_SLIPPAGE_BPS  floor below the VIEW_QUOTER quote, bps (default 100, at most 1000)
///
///         CHECKS, all in simulation before anything is sent: the externals and every binding above; the floor is
///         quote * (1 - slippage) and non-zero; after the buy, the vault's QUOTRON balance rose by at least the floor
///         and by exactly what the router reported, and its freeBalance() rose by exactly that same amount (nothing
///         the seed brought in is counted against unclaimedReserve).
///
///         ERC-404: SEED_ETH_WEI buys about one whole QUOTRON at 2026-09 prices, so the buy can cross a whole unit in
///         the vault. test/fork/QuotronWholeUnitFork.t.sol measured that real QUOTRON accepts whole units into
///         BaseVault, and BaseVault.onERC721Received accepts a 721 pushed by QUOTRON itself; the vault's accounting
///         reads the ERC-20 balance only. test/fork/SeedRaffleVaultFork.t.sol runs this exact body against the live
///         pool and asserts it.
contract SeedRaffleVault is Script {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_SLIPPAGE_BPS = 1000;
    uint256 internal constant DEADLINE = 15 minutes; // QuotronRouterAdapter's default deadline buffer
    /// @notice Quotron's View quoter on RH mainnet (keeper/.env.example VIEW_QUOTER, docs/MAINNET-POT-SIZING.md).
    address internal constant RH_VIEW_QUOTER = 0xb8960fdC8A0Be155d196C2795b75747763562df2;

    struct Seed {
        address nft;
        address raffle;
        address vault;
        address quotron;
        address router;
        address quoter;
        uint256 ethIn;
        uint256 slippageBps;
        uint256 bucketLo;
        uint256 bucketHi;
        uint256 quote;
        uint256 minOut;
        bool openingDone; // Read in _preflight, so an engine without openingDone() is refused by name
    }

    /// @dev The env seam (test/fork/SeedRaffleVaultFork.t.sol overrides these; vm.setEnv is process-wide).
    function _envAddress(string memory key) internal view virtual returns (address) {
        // Say which input is missing and why, instead of the bare cheatcode error.
        address a = vm.envOr(key, address(0));
        if (a == address(0)) revert(_unsetEnvReason(key));
        return a;
    }

    /// @dev The refusal for an unset address input. The two inputs that exist only on RH mainnet name their
    ///      4663 pin, so the operator does not have to look them up in keeper/.env.example.
    function _unsetEnvReason(string memory key) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(key));
        string memory why = " is not set";
        if (h == keccak256("VIEW_QUOTER")) {
            why =
                " is not set (on RH mainnet 4663 it must be Quotron's View quoter 0xb8960fdC8A0Be155d196C2795b75747763562df2; the testnet stack has none and cannot run this step)";
        } else if (h == keccak256("QUOTRON_ROUTER")) {
            why =
                " is not set (on RH mainnet 4663 it must be Quotron's ETH router 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18; the testnet stack has none and cannot run this step)";
        }
        return string.concat("seed: env ", key, why);
    }

    function _envUint(string memory key) internal view virtual returns (uint256) {
        return vm.envUint(key);
    }

    function _envOrUint(string memory key, uint256 dflt) internal view virtual returns (uint256) {
        return vm.envOr(key, dflt);
    }

    function run() external {
        _run(msg.sender);
    }

    /// @dev Internal so a test can run it with the broadcaster as msg.sender and tx.origin.
    function _run(address me) internal returns (uint256 arrived) {
        Seed memory s = _load();
        _preflight(s, me);
        _quote(s, me);

        IERC20 q = IERC20(s.quotron);
        uint256 bal0 = q.balanceOf(s.vault);
        uint256 free0 = ISeedVault(s.vault).freeBalance();
        uint256 reserve0 = ISeedVault(s.vault).unclaimedReserve();

        vm.startBroadcast();
        uint256 out = ISeedQuotronRouter(s.router).buyExactEth{ value: s.ethIn }(
            s.minOut, s.vault, block.timestamp + DEADLINE
        );
        vm.stopBroadcast();

        arrived = q.balanceOf(s.vault) - bal0;
        require(arrived >= s.minOut, "seed: the vault received less QUOTRON than the floor");
        require(arrived == out, "seed: the vault's QUOTRON delta != what the router reported");
        require(ISeedVault(s.vault).unclaimedReserve() == reserve0, "seed: the vault's unclaimedReserve moved");
        require(
            ISeedVault(s.vault).freeBalance() - free0 == arrived,
            "seed: the vault's freeBalance did not rise by exactly what arrived"
        );
        _report(s, me, arrived);
    }

    function _load() internal view returns (Seed memory s) {
        s.nft = _envAddress("NFT_ADDRESS");
        s.raffle = _envAddress("RAFFLE_ENGINE");
        s.vault = ISeedRaffle(s.raffle).vault();
        s.quotron = _envAddress("QUOTRON");
        s.router = _envAddress("QUOTRON_ROUTER");
        s.quoter = _envAddress("VIEW_QUOTER");
        s.ethIn = _envUint("SEED_ETH_WEI");
        s.slippageBps = _envOrUint("SEED_SLIPPAGE_BPS", DEFAULT_SLIPPAGE_BPS);
        require(_envAddress("PRIZE_VAULT") == s.vault, "seed: PRIZE_VAULT != RaffleEngine.vault()");
    }

    function _preflight(Seed memory s, address me) internal view {
        // The externals. On 4663 they are the pinned live contracts; everywhere they must agree with each other.
        if (block.chainid == LaunchGuards.RH_MAINNET) {
            require(s.quotron == LaunchGuards.RH_QUOTRON, "seed: QUOTRON is not the pinned RH mainnet QUOTRON");
            require(s.router == LaunchGuards.RH_QUOTRON_ROUTER, "seed: QUOTRON_ROUTER is not the pinned RH mainnet router");
            require(s.quoter == RH_VIEW_QUOTER, "seed: VIEW_QUOTER is not the pinned RH mainnet view quoter");
        }
        require(s.router.code.length > 0 && s.quoter.code.length > 0, "seed: QUOTRON_ROUTER / VIEW_QUOTER has no code");
        // A try/catch, so an address that has code but no quotron() (the testnet MockSwapAdapter stand-in, a wrong
        // paste) stops with this script's own message instead of a bare "EvmError: Revert" before the require prints.
        try ISeedQuotronRouter(s.router).quotron() returns (address rq) {
            require(rq == s.quotron, "seed: QUOTRON_ROUTER.quotron() != QUOTRON");
        } catch {
            revert(
                "seed: QUOTRON_ROUTER has no quotron(): not a Quotron router (the testnet stack has none; this step is proven by test/fork/SeedRaffleVaultFork.t.sol)"
            );
        }
        require(s.vault.code.length > 0, "seed: RaffleEngine.vault() has no code");
        try ISeedVault(s.vault).quotron() returns (address vq) {
            require(vq == s.quotron, "seed: the raffle vault does not hold QUOTRON");
        } catch {
            revert("seed: RaffleEngine.vault() has no quotron(): not a BaseVault");
        }

        // Who may run it, and whether the seed has arrived.
        ISeedNftLedger n = ISeedNftLedger(s.nft);
        require(n.seedTreasury() == me, "seed: sender is not NFTCollection.seedTreasury (use --account / --sender)");
        require(n.launched(), "seed: the mint is not finalized");

        // The destination belongs to THIS launch (see the ENV notice).
        _preflightLiveRaffle(s);
        require(
            n.seedReserve() == 0,
            "seed: the seed bucket is still in the NFT: run NFTCollection.withdrawProceeds() (permissionless after launch)"
        );

        // How much. The bucket is bounded from on-chain state alone, exactly as GoLiveMainnet bounds the LP bucket.
        (s.bucketLo, s.bucketHi) = _seedBucketBounds(n);
        require(s.ethIn != 0, "seed: SEED_ETH_WEI is 0");
        require(
            s.ethIn >= s.bucketLo && s.ethIn <= s.bucketHi,
            "seed: SEED_ETH_WEI is outside the mint's seed bucket (10% of the raise, bounded on-chain)"
        );
        require(me.balance >= s.ethIn, "seed: sender ETH < SEED_ETH_WEI (gas is on top)");
        require(s.slippageBps <= MAX_SLIPPAGE_BPS, "seed: SEED_SLIPPAGE_BPS above 1000");
    }

    /// @notice RAFFLE_ENGINE and PRIZE_VAULT are typed from a Deploy log, and an aborted
    ///         Deploy broadcast that was re-run leaves a matching orphan engine/vault pair whose every local check
    ///         passes (the vault holds QUOTRON, engine.vault() matches, the NFT and bucket are real). This walks the
    ///         write-once bindings from the NFT, which the operator cannot mistype: NFTCollection.taxHook (setTaxHook,
    ///         write-once, set by the live Deploy) -> hook.nft (immutable) and hook.packRegistry (immutable) ->
    ///         PackRegistry.engine (write-once) -> RaffleEngine.packs (immutable). TransferOwnership._checkEngines
    ///         applies the same kind of check to the two env-typed engines; this mirrors it on the vault controller too.
    function _preflightLiveRaffle(Seed memory s) internal view {
        address hook = ISeedNftLedger(s.nft).taxHook();
        require(
            hook != address(0) && hook.code.length > 0,
            "seed: NFTCollection.taxHook is unset: Deploy.s.sol has not wired this launch (or NFT_ADDRESS is wrong)"
        );
        require(ISeedHook(hook).nft() == s.nft, "seed: NFTCollection.taxHook().nft() != NFT_ADDRESS");
        address registry = ISeedHook(hook).packRegistry();
        require(
            ISeedPackRegistry(registry).engine() == s.raffle,
            "seed: RAFFLE_ENGINE is not the live raffle (NFTCollection.taxHook().packRegistry().engine() differs): an orphan from an aborted deploy?"
        );
        require(ISeedRaffle(s.raffle).packs() == registry, "seed: RaffleEngine.packs() != the launch's PackRegistry");
        address cm = ISeedVault(s.vault).controller();
        require(cm != address(0) && cm.code.length > 0, "seed: the raffle vault has no controller (not wired by Deploy)");
        require(ISeedRaffle(s.raffle).claimManager() == cm, "seed: RaffleEngine.claimManager() != the raffle vault's controller");
        require(ISeedClaimManager(cm).enginesLocked(), "seed: ClaimManager engines are not locked");
        require(
            ISeedClaimManager(cm).engineVault(s.raffle) == s.vault,
            "seed: ClaimManager does not bind RAFFLE_ENGINE to its vault"
        );
        // Read here, not only in the report, so an engine that is not a RaffleEngine is refused on purpose.
        try ISeedRaffle(s.raffle).openingDone() returns (bool done) {
            s.openingDone = done;
        } catch {
            revert("seed: RAFFLE_ENGINE has no openingDone(): not a RaffleEngine");
        }
    }

    /// @notice The seed bucket NFTCollection's mint split paid to seedTreasury, bounded from on-chain state.
    /// @dev    Each paid mint call adds floor(msg.value * SEED_BPS / BPS), so the total is at most
    ///         paid * price * SEED_BPS / BPS and at least that minus 1 wei per paid pass. A reserve latch widens the
    ///         paid count to [minted - RESERVE_CAP, minted - 1], as in GoLiveMainnet._lpBucketBounds.
    function _seedBucketBounds(ISeedNftLedger n) internal view returns (uint256 lo, uint256 hi) {
        uint256 minted = n.totalMinted();
        uint256 paidLo = minted;
        uint256 paidHi = minted;
        if (n.reserveMinted()) {
            uint256 cap = n.RESERVE_CAP();
            paidLo = minted > cap ? minted - cap : 0;
            paidHi = minted > 0 ? minted - 1 : 0;
        }
        uint256 price = n.mintPrice();
        uint256 seedBps = n.SEED_BPS();
        uint256 loGross = Math.mulDiv(paidLo * price, seedBps, BPS);
        lo = loGross > paidLo ? loGross - paidLo : 0;
        hi = Math.mulDiv(paidHi * price, seedBps, BPS);
    }

    /// @dev The floor, from the canonical view quoter, quoted for THIS payer (Quotron's fee is per payer).
    function _quote(Seed memory s, address me) internal view {
        (s.quote,,,) = ISeedViewQuoter(s.quoter).quoteBuyExactEth(s.ethIn, me);
        s.minOut = (s.quote * (BPS - s.slippageBps)) / BPS;
        require(s.minOut > 0, "seed: the quote floors to 0 QUOTRON (the router refuses minOut 0)");
    }

    function _report(Seed memory s, address me, uint256 arrived) internal view {
        console2.log("SEED -> DAILY RAFFLE VAULT");
        console2.log("  sender (NFTCollection.seedTreasury)          ", me);
        console2.log("  raffle vault (RaffleEngine.vault)            ", s.vault);
        console2.log("  seed ETH in (wei), SEED_ETH_WEI              ", s.ethIn);
        console2.log("  mint seed bucket, on-chain low bound (wei)   ", s.bucketLo);
        console2.log("  mint seed bucket, on-chain high bound (wei)  ", s.bucketHi);
        console2.log("  VIEW_QUOTER quote (QUOTRON wei)              ", s.quote);
        console2.log("  floor, minOut (QUOTRON wei)                  ", s.minOut);
        console2.log("  arrived in the vault = freeBalance rise (wei)", arrived);
        console2.log("  vault freeBalance now (QUOTRON wei)          ", ISeedVault(s.vault).freeBalance());
        if (s.openingDone) {
            console2.log("NOTE: the opening draw already ran; this seed funds the daily draws from here on.");
        }
        console2.log("For a Safe SEED_TREASURY, submit exactly: to / value / data");
        console2.log("  to   ", s.router);
        console2.log("  value", s.ethIn);
        console2.logBytes(
            abi.encodeCall(ISeedQuotronRouter.buyExactEth, (s.minOut, s.vault, block.timestamp + DEADLINE))
        );
        console2.log("  (the deadline above is simulation time + 15 minutes; rebuild it when you sign)");
    }
}
