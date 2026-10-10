// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseVault } from "../../src/BaseVault.sol";
import { LaunchGuards } from "../../script/LaunchGuards.sol";
import { SeedRaffleVault } from "../../script/SeedRaffleVault.s.sol";

interface IQuotron404 {
    function nftBalanceOf(address owner) external view returns (uint256);
    function erc721TransferExempt(address target) external view returns (bool);
}

/// NFTCollection's seed ledger, at a 3,500-pass sell-out with the 25-pass reserve latched: paid passes are bounded to
/// [3475, 3499], so the seed bucket is [2.60625 ETH - 3475 wei, 2.62425 ETH].
contract SRNftLedger {
    bool public launched = true;
    address public seedTreasury;
    uint256 public seedReserve;
    uint256 public totalMinted = 3500;
    uint256 public mintPrice = 0.0075 ether;
    uint256 public constant SEED_BPS = 1000;
    uint256 public constant RESERVE_CAP = 25;
    bool public reserveMinted = true;
    address public taxHook; // the write-once hook binding the seed destination is proven through

    constructor(address s) {
        seedTreasury = s;
    }

    function setSeedReserve(uint256 v) external {
        seedReserve = v;
    }

    function setTaxHook(address h) external {
        taxHook = h;
    }
}

/// Stand-ins for the launch graph: hook.nft / hook.packRegistry, PackRegistry.engine.
contract SRHook {
    address public nft;
    address public packRegistry;

    constructor(address n, address r) {
        nft = n;
        packRegistry = r;
    }
}

contract SRPacks {
    address public engine;

    function setEngine(address e) external {
        engine = e;
    }
}

contract SRRaffle {
    address public vault;
    address public packs;
    address public claimManager;
    bool public openingDone;

    constructor(address v, address p, address cm) {
        vault = v;
        packs = p;
        claimManager = cm;
    }
}

/// Answers vault() only: an engine-shaped contract with no openingDone().
contract SRNotARaffle {
    address public vault;
    address public packs;
    address public claimManager;

    constructor(address v, address p, address cm) {
        vault = v;
        packs = p;
        claimManager = cm;
    }
}

/// @notice The prize seed against the LIVE chain (read-only fork of RH mainnet 4663; nothing is broadcast). The owner's
///         decision is that the mint's 10% prize seed funds the DAILY RAFFLE vault only, and no script did it. This runs
///         the REAL script/SeedRaffleVault.s.sol body through Quotron's canonical ETH router and View quoter into a real
///         BaseVault, with the NFT ledger and the raffle's vault() as stand-ins (the fork has no QuoPull deployment).
///
///         ERC-404. At 2026-09-13 prices the ~2.6 ETH seed buys MORE than one whole QUOTRON, so the buy crosses a whole
///         unit in the vault. test/fork/QuotronWholeUnitFork.t.sol showed real QUOTRON delivers whole units to a
///         BaseVault; BaseVault.onERC721Received accepts a 721 pushed by QUOTRON itself. This asserts the seed path
///         end to end: the buy lands, freeBalance rises by exactly what arrived (also with a reserve already owed), and
///         any 721s QUOTRON attributes to the vault never exceed its whole units.
contract SeedRaffleVaultForkTest is Test, SeedRaffleVault {
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
    uint256 constant SEED = 2.60625 ether;

    mapping(bytes32 => address) internal envA;
    mapping(bytes32 => uint256) internal envU;
    mapping(bytes32 => bool) internal envSet;

    BaseVault vault;
    SRRaffle raffle;
    SRNftLedger ledger;

    function _envAddress(string memory k) internal view override returns (address) {
        require(envSet[keccak256(bytes(k))], string.concat("test env unset: ", k));
        return envA[keccak256(bytes(k))];
    }

    function _envUint(string memory k) internal view override returns (uint256) {
        require(envSet[keccak256(bytes(k))], string.concat("test env unset: ", k));
        return envU[keccak256(bytes(k))];
    }

    function _envOrUint(string memory k, uint256 d) internal view override returns (uint256) {
        return envSet[keccak256(bytes(k))] ? envU[keccak256(bytes(k))] : d;
    }

    function _setA(string memory k, address v) internal {
        envA[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function _setU(string memory k, uint256 v) internal {
        envU[keccak256(bytes(k))] = v;
        envSet[keccak256(bytes(k))] = true;
    }

    function runExt(address me) external returns (uint256) {
        return _run(me);
    }

    SRPacks packsStub;

    /// This test contract stands in for the ClaimManager: it is the vault's controller (so the second seed below can
    /// reserve a prize) and answers the frozen engine->vault map the seed preflight reads.
    bool internal cmLocked = true;
    address internal boundEngine; // the one engine the stand-in ClaimManager map binds to the vault

    function enginesLocked() external view returns (bool) {
        return cmLocked;
    }

    function engineVault(address e) external view returns (address) {
        return e == boundEngine ? address(vault) : address(0);
    }

    function _fork(address me) internal {
        vm.createSelectFork(RPC);
        assertEq(block.chainid, 4663, "RH mainnet fork");
        vault = BaseVault(deployCode("BaseVault.sol:BaseVault", abi.encode(LaunchGuards.RH_QUOTRON, address(this))));
        vault.setController(address(this)); // Deploy.s.sol binds the ClaimManager; this contract plays it
        packsStub = new SRPacks();
        raffle = new SRRaffle(address(vault), address(packsStub), address(this));
        packsStub.setEngine(address(raffle));
        boundEngine = address(raffle);
        ledger = new SRNftLedger(me);
        ledger.setTaxHook(address(new SRHook(address(ledger), address(packsStub))));
        _setA("NFT_ADDRESS", address(ledger));
        _setA("RAFFLE_ENGINE", address(raffle));
        _setA("PRIZE_VAULT", address(vault));
        _setA("QUOTRON", LaunchGuards.RH_QUOTRON);
        _setA("QUOTRON_ROUTER", LaunchGuards.RH_QUOTRON_ROUTER);
        _setA("VIEW_QUOTER", RH_VIEW_QUOTER);
        _setU("SEED_ETH_WEI", SEED);
        vm.deal(me, 10 ether);
    }

    function test_fork_seedBuysQuotronIntoTheRaffleVault_freeBalanceRisesByWhatArrived() public {
        address me = msg.sender;
        assertEq(tx.origin, me, "the caller is the broadcaster");
        _fork(me);
        IERC20 q = IERC20(LaunchGuards.RH_QUOTRON);

        uint256 arrived = _run(me);
        emit log_named_uint("seed ETH in (wei)", SEED);
        emit log_named_uint("QUOTRON arrived in the raffle vault (wei)", arrived);
        assertGt(arrived, 0, "QUOTRON landed");
        assertEq(q.balanceOf(address(vault)), arrived, "a fresh vault holds exactly what arrived");
        assertEq(vault.freeBalance(), arrived, "and all of it is free (nothing owed)");
        assertEq(me.balance, 10 ether - SEED, "exactly SEED_ETH_WEI left the seed treasury");
        _logAndBoundNfts(q);

        // A second seed on top of a vault that already owes a prize: freeBalance still rises by exactly what arrived.
        vault.reserve(arrived / 3);
        uint256 free0 = vault.freeBalance();
        uint256 arrived2 = _run(me);
        assertEq(vault.freeBalance(), free0 + arrived2, "freeBalance rose by exactly what arrived, reserve untouched");
        assertEq(vault.unclaimedReserve(), arrived / 3, "the owed prize is still reserved");
        _logAndBoundNfts(q);
    }

    function _logAndBoundNfts(IERC20 q) internal view {
        uint256 bal = q.balanceOf(address(vault));
        uint256 n721 = IQuotron404(address(q)).nftBalanceOf(address(vault));
        bool exempt = IQuotron404(address(q)).erc721TransferExempt(address(vault));
        console2.log("vault QUOTRON wei / whole units", bal, bal / 1e18);
        console2.log("vault ERC-721 units attributed by QUOTRON", n721);
        console2.log("vault erc721TransferExempt", exempt);
        require(n721 <= bal / 1e18, "QUOTRON attributes more 721s to the vault than whole units");
    }

    /// Every binding the script checks refuses a wrong value on the live chain, before anything is sent.
    function test_fork_seedPreflight_refusals() public {
        address me = msg.sender;
        _fork(me);

        vm.expectRevert(bytes("seed: sender is not NFTCollection.seedTreasury (use --account / --sender)"));
        this.runExt(makeAddr("notTheSeedTreasury"));

        _setA("PRIZE_VAULT", makeAddr("otherVault"));
        vm.expectRevert(bytes("seed: PRIZE_VAULT != RaffleEngine.vault()"));
        this.runExt(me);
        _setA("PRIZE_VAULT", address(vault));

        _setA("VIEW_QUOTER", LaunchGuards.RH_QUOTRON_ROUTER);
        vm.expectRevert(bytes("seed: VIEW_QUOTER is not the pinned RH mainnet view quoter"));
        this.runExt(me);
        _setA("VIEW_QUOTER", RH_VIEW_QUOTER);

        _setU("SEED_ETH_WEI", 26.0625 ether); // one zero too many
        vm.expectRevert(bytes("seed: SEED_ETH_WEI is outside the mint's seed bucket (10% of the raise, bounded on-chain)"));
        this.runExt(me);
        _setU("SEED_ETH_WEI", SEED - 3476); // one wei under the low bound
        vm.expectRevert(bytes("seed: SEED_ETH_WEI is outside the mint's seed bucket (10% of the raise, bounded on-chain)"));
        this.runExt(me);
        _setU("SEED_ETH_WEI", SEED);

        ledger.setSeedReserve(SEED);
        vm.expectRevert(
            bytes("seed: the seed bucket is still in the NFT: run NFTCollection.withdrawProceeds() (permissionless after launch)")
        );
        this.runExt(me);
        ledger.setSeedReserve(0);

        _setU("SEED_SLIPPAGE_BPS", 1001);
        vm.expectRevert(bytes("seed: SEED_SLIPPAGE_BPS above 1000"));
        this.runExt(me);
    }

    /// An orphan engine/vault pair from an aborted Deploy broadcast passes every local
    /// check (a real BaseVault holding QUOTRON, engine.vault() == PRIZE_VAULT, the real NFT ledger and bucket), and is
    /// refused because the launch's write-once graph names a different engine. Every other break in the chain is
    /// refused by name too. Nothing is bought in any of these runs.
    function test_fork_seedPreflight_orphanPairAndBrokenBindingsRefused() public {
        address me = msg.sender;
        _fork(me);
        uint256 bal0 = me.balance;

        // (1) the orphan pair: its own vault (holding QUOTRON), its own registry, the right shapes everywhere
        BaseVault orphanVault =
            BaseVault(deployCode("BaseVault.sol:BaseVault", abi.encode(LaunchGuards.RH_QUOTRON, address(this))));
        SRPacks orphanPacks = new SRPacks();
        SRRaffle orphan = new SRRaffle(address(orphanVault), address(orphanPacks), address(this));
        orphanPacks.setEngine(address(orphan));
        _setA("RAFFLE_ENGINE", address(orphan));
        _setA("PRIZE_VAULT", address(orphanVault));
        vm.expectRevert(
            bytes(
                "seed: RAFFLE_ENGINE is not the live raffle (NFTCollection.taxHook().packRegistry().engine() differs): an orphan from an aborted deploy?"
            )
        );
        this.runExt(me);
        _setA("RAFFLE_ENGINE", address(raffle));
        _setA("PRIZE_VAULT", address(vault));

        // (2) the NFT is not wired to any hook yet (Deploy.s.sol never ran for this NFT)
        address hook = ledger.taxHook();
        ledger.setTaxHook(address(0));
        vm.expectRevert(
            bytes("seed: NFTCollection.taxHook is unset: Deploy.s.sol has not wired this launch (or NFT_ADDRESS is wrong)")
        );
        this.runExt(me);

        // (3) a hook built for a different NFT
        ledger.setTaxHook(address(new SRHook(makeAddr("otherNft"), address(packsStub))));
        vm.expectRevert(bytes("seed: NFTCollection.taxHook().nft() != NFT_ADDRESS"));
        this.runExt(me);
        ledger.setTaxHook(hook);

        // (4) the engine claims a different registry
        SRRaffle wrongPacks = new SRRaffle(address(vault), makeAddr("otherRegistry"), address(this));
        packsStub.setEngine(address(wrongPacks));
        _setA("RAFFLE_ENGINE", address(wrongPacks));
        vm.expectRevert(bytes("seed: RaffleEngine.packs() != the launch's PackRegistry"));
        this.runExt(me);

        // (5) the engine is bound to a claim manager that is not the vault's controller
        SRRaffle wrongCm = new SRRaffle(address(vault), address(packsStub), makeAddr("otherClaimManager"));
        packsStub.setEngine(address(wrongCm));
        _setA("RAFFLE_ENGINE", address(wrongCm));
        vm.expectRevert(bytes("seed: RaffleEngine.claimManager() != the raffle vault's controller"));
        this.runExt(me);
        packsStub.setEngine(address(raffle));
        _setA("RAFFLE_ENGINE", address(raffle));

        // (6) the claim manager's engine map is not frozen
        cmLocked = false;
        vm.expectRevert(bytes("seed: ClaimManager engines are not locked"));
        this.runExt(me);
        cmLocked = true;

        // (7) the live graph names an engine the frozen map does not bind to this vault
        SRRaffle unbound = new SRRaffle(address(vault), address(packsStub), address(this));
        packsStub.setEngine(address(unbound));
        _setA("RAFFLE_ENGINE", address(unbound));
        vm.expectRevert(bytes("seed: ClaimManager does not bind RAFFLE_ENGINE to its vault"));
        this.runExt(me);

        // (8) an engine-shaped contract that is not a RaffleEngine: openingDone() is read in preflight on purpose
        SRNotARaffle notRaffle = new SRNotARaffle(address(vault), address(packsStub), address(this));
        packsStub.setEngine(address(notRaffle));
        _setA("RAFFLE_ENGINE", address(notRaffle));
        boundEngine = address(notRaffle);
        vm.expectRevert(bytes("seed: RAFFLE_ENGINE has no openingDone(): not a RaffleEngine"));
        this.runExt(me);

        assertEq(me.balance, bal0, "no refused run spent anything");
    }

    /// The refusal for an unset VIEW_QUOTER (and QUOTRON_ROUTER) names the 4663 pin, and the named pin is the
    /// address the script enforces on this chain.
    function test_fork_missingViewQuoter_namesThePin() public {
        _fork(msg.sender);
        assertEq(
            _unsetEnvReason("VIEW_QUOTER"),
            "seed: env VIEW_QUOTER is not set (on RH mainnet 4663 it must be Quotron's View quoter 0xb8960fdC8A0Be155d196C2795b75747763562df2; the testnet stack has none and cannot run this step)"
        );
        assertEq(RH_VIEW_QUOTER, 0xb8960fdC8A0Be155d196C2795b75747763562df2, "the message names the enforced pin");
        assertGt(RH_VIEW_QUOTER.code.length, 0, "the pinned quoter has code on 4663");
        assertEq(
            _unsetEnvReason("QUOTRON_ROUTER"),
            "seed: env QUOTRON_ROUTER is not set (on RH mainnet 4663 it must be Quotron's ETH router 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18; the testnet stack has none and cannot run this step)"
        );
        assertEq(LaunchGuards.RH_QUOTRON_ROUTER, 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18, "and the router pin");
        assertEq(_unsetEnvReason("NFT_ADDRESS"), "seed: env NFT_ADDRESS is not set");
    }
}
