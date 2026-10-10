// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { LaunchGuards } from "./LaunchGuards.sol";

/// @notice Phase-1 launch script (MAINNET path): deploy the NFT collection that funds the launch. Run BEFORE
///         the protocol (Deploy.s.sol). Sequence:
///           deploy the quicknet BlsDrandOracle -> THIS -> [reserveMint] -> setAllowlistRoot(root) ->
///           setMintOpen(true) -> openAllowlistMint() (the ONE start action; GTD -> overflow -> public then
///           advance by elapsed time) -> mint out -> finalizeLaunch() -> Deploy.s.sol -> GoLiveMainnet.s.sol
///         Do NOT call withdrawProceeds() before GoLiveMainnet: while the LP bucket is still in the NFT the
///         go-live anchors LP_ETH_WEI to nft.lpReserve() EXACTLY and withdraws it itself. After an early withdraw
///         the anchor falls back to a bound, where LP_ETH_WEI may sit up to (RESERVE_CAP - reserve) passes' LP
///         share below the true bucket.
///         The mint is self-closing: nothing mints past publicMintClosesAt, and finalizeLaunch() goes
///         permissionless after it, so the launch cannot stall on an absent owner. Deploy.s.sol wires the tax
///         hook into this collection (setTaxHook); there is no separate setNft step here.
///
/// @dev  DRAND_ORACLE must already be deployed and is checked here, before it is burned in as an
///       immutable: a codeless address would lock 100% of the mint ETH, and a mock oracle would make rarity
///       attacker-chosen.
///       RECIPIENTS. All three are frozen at the first mint and withdrawProceeds pays
///       exactly them, forever, so each is preflighted here, before the broadcast:
///         LP_TREASURY    MUST BE THE DEPLOYER KEY THAT RUNS GoLiveMainnet (the 80% LP bucket). The go-live wraps the
///                        LP bucket from that key's own balance and refuses to run unless NFTCollection.lpTreasury is
///                        the sender. Never QpullLiquidityLock (no receive(); setRecipients probes for that).
///         SEED_TREASURY  the 10% PRIZE SEED, and nothing else: a SEPARATE REGULAR WALLET (the owner's choice), distinct
///                        from the deployer key and from TEAM_WALLET, able to receive ETH, with NO CODE, and not a
///                        precompile or system address. That wallet later runs script/SeedRaffleVault.s.sol once, right
///                        after go-live and before the opening draw. OVERRIDE: if the owner deliberately uses a
///                        contract wallet (a Safe) instead, set SEED_TREASURY_ALLOW_CONTRACT=true. The override then
///                        REQUIRES code at SEED_TREASURY (so it cannot be left on for a plain key by accident), and the
///                        ETH probe still runs; SeedRaffleVault prints the calldata for a Safe to submit.
///         TEAM_WALLET    the 10% team + operations share.
///       NFTCollection.setRecipients re-checks distinctness and probes each with a zero-value call on-chain; this
///       preflight names the failure before anything is sent and probes the seed wallet with a real 1-wei value.
///
///       DELEGATION-ONLY LAUNCH: EXPECTED_NFT_ADDRESS. When holders are asked to delegate on
///       delegate.xyz BEFORE this script runs, they sign `delegateContract(hot, X)` against an address X that was
///       computed in advance as CREATE(deployer, nonce). Any transaction the deployer key sends first (a renderer
///       chunk, a gas top-up, a partial broadcast of this very script) moves the NFT to a different address, and
///       every scoped delegation then points at nothing. Set EXPECTED_NFT_ADDRESS=X and this script:
///         - REQUIRES DELEGATE_REGISTRY (the launch depends on it; on 4663 it must be the canonical delegate.xyz
///           v2 registry the delegation page writes to);
///         - REFUSES a deployer account that has code: an EIP-7702 delegated account can change its own nonce
///           through its delegate, so only a plain key keeps CREATE(deployer, nonce) predictable;
///         - if X has NO code: refuses to broadcast unless CREATE(deployer, current nonce) == X;
///         - if X HAS code (the RESUME PATH, e.g. the CREATE landed and setRecipients did not): proves X is this
///           deployer's own NFTCollection (created by it at a lower nonce, the exact runtime code for these env
///           immutables, owned by it with no pending transfer) and sends ONLY the missing setRecipients and/or
///           setDelegateRegistry. It never deploys a second NFT.
///       Broadcast with `--slow`, from a key that sends nothing else until this script has finished:
///         forge script script/DeployNFT.s.sol --rpc-url rh --account <deployer> --broadcast --slow
contract DeployNFT is Script {
    /// @dev A fixed, keyless address that only ever exists inside the simulation (the ETH probe's sender).
    address internal constant PROBE_FUNDER = address(uint160(uint256(keccak256("quopull.deploy-nft.seed-probe"))));
    /// @dev EVM and Arbitrum precompiles and system addresses all sit at or below this.
    uint160 internal constant MAX_SYSTEM_ADDRESS = 0xFFFF;
    /// @notice The canonical delegate.xyz v2 registry: the address web/delegate.html writes delegations to, with code
    ///         on Robinhood Chain mainnet (read-only eth_getCode, 2026-09-14: 10,046 bytes, keccak 0x9dec...1ba9).
    address internal constant DELEGATE_XYZ_V2 = 0x00000000000000447e69651d841bD8D104Bed493;
    /// @dev The resume path proves the NFT was created by this deployer by walking its CREATE nonces. A launch key
    ///      that has sent more transactions than this is not the fresh key the delegation-only launch requires.
    uint64 internal constant MAX_RESUME_NONCE_SCAN = 4096;

    struct Cfg {
        uint256 mintPrice;
        uint256 revealDelay;
        address oracle;
        address lpTreasury;
        address seedTreasury;
        address team;
        address renderer;
        address delegateRegistry;
        bool seedTreasuryAllowContract;
        address expectedNft; // EXPECTED_NFT_ADDRESS, optional (the delegation pin)
    }

    /// @dev The env seam. Production reads the process environment; test/DeployNFTPreflight.t.sol overrides these
    ///      (vm.setEnv is process-wide and tests run concurrently).
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envUint(string memory key) internal view virtual returns (uint256) {
        return vm.envUint(key);
    }

    function _envOrAddress(string memory key, address dflt) internal view virtual returns (address) {
        return vm.envOr(key, dflt);
    }

    function _envOrBool(string memory key, bool dflt) internal view virtual returns (bool) {
        return vm.envOr(key, dflt);
    }

    function run() external {
        _run(msg.sender);
    }

    function _cfg() internal view returns (Cfg memory c) {
        // ONE env name for each immutable across DeployNFT, DeployMint and DeployTestnet, and REQUIRED on the
        // mainnet path (vm.envOr defaulted silently on an immutable).
        c.mintPrice = _envUint("MINT_PRICE_WEI"); // launch price: 7500000000000000 (0.0075 ETH)
        c.revealDelay = _envUint("REVEAL_DELAY"); // >= 1 hour (NFTCollection.MIN_REVEAL_DELAY)
        c.oracle = _envAddress("DRAND_ORACLE");
        c.lpTreasury = _envAddress("LP_TREASURY");
        c.seedTreasury = _envAddress("SEED_TREASURY");
        c.team = _envAddress("TEAM_WALLET");
        // Fully on-chain art: deploy + chunk + lock the renderer first (script/DeployPassArt.s.sol).
        c.renderer = _envAddress("RENDERER_ADDR");
        // The delegate.xyz v2 registry is write-once and enables delegatedAllowlistMint;
        // if it is never wired, that mint path reverts DelegationDisabled at launch. Wired when the env is set
        // (RH-mainnet delegate.xyz v2 address), else delegation stays disabled deliberately.
        c.delegateRegistry = _envOrAddress("DELEGATE_REGISTRY", address(0));
        // The SEED_TREASURY contract-wallet override, see the contract @dev. Default false: SEED_TREASURY must be a regular wallet.
        c.seedTreasuryAllowContract = _envOrBool("SEED_TREASURY_ALLOW_CONTRACT", false);
        // The address published for the delegation campaign (see the contract @dev). Unset = no pin.
        c.expectedNft = _envOrAddress("EXPECTED_NFT_ADDRESS", address(0));
    }

    /// @dev Every check that needs only env and chain state, before anything is broadcast.
    function _preflight(Cfg memory c, address me) internal {
        // The real time-locked quicknet oracle, before the raise binds it forever.
        LaunchGuards.requireQuicknetOracle(c.oracle);
        // The LP bucket must land in the key that seeds it (GoLiveMainnet enforces the same equality).
        require(
            c.lpTreasury == me,
            "deploy-nft: LP_TREASURY must be the deployer key that runs GoLiveMainnet (use --account / --sender)"
        );
        require(c.team != address(0), "deploy-nft: TEAM_WALLET unset");
        require(c.team != c.lpTreasury, "deploy-nft: TEAM_WALLET must not be the deployer key (LP_TREASURY)");
        _preflightSeedTreasury(c);
    }

    /// @dev SEED_TREASURY is a separate regular wallet used only for the 10% prize seed.
    function _preflightSeedTreasury(Cfg memory c) internal {
        address seed = c.seedTreasury;
        require(seed != address(0), "deploy-nft: SEED_TREASURY unset");
        require(seed != c.lpTreasury, "deploy-nft: SEED_TREASURY must not be the deployer key (LP_TREASURY)");
        require(seed != c.team, "deploy-nft: SEED_TREASURY must not be TEAM_WALLET (the team + operations share)");
        require(
            uint160(seed) > MAX_SYSTEM_ADDRESS, "deploy-nft: SEED_TREASURY is a precompile or system address, not a wallet"
        );
        if (c.seedTreasuryAllowContract) {
            require(
                seed.code.length > 0,
                "deploy-nft: SEED_TREASURY_ALLOW_CONTRACT=true but SEED_TREASURY has no code (unset the override for a plain wallet)"
            );
        } else {
            // Also refuses an EIP-7702-delegated account (its code is the 0xef0100 designator): not a regular wallet.
            require(
                seed.code.length == 0,
                "deploy-nft: SEED_TREASURY has code; it must be a regular wallet (SEED_TREASURY_ALLOW_CONTRACT=true for a Safe)"
            );
        }
        // Can it receive ETH? withdrawProceeds pays it with a plain value call and restores the bucket on failure, so a
        // wallet that refuses ETH strands the prize seed in the NFT. Probe with a real 1-wei value, in simulation only:
        // the snapshot is reverted, and nothing here is inside a broadcast.
        uint256 snap = vm.snapshotState();
        vm.deal(PROBE_FUNDER, 1);
        vm.prank(PROBE_FUNDER);
        (bool ok,) = seed.call{ value: 1 }("");
        vm.revertToState(snap);
        require(ok, "deploy-nft: SEED_TREASURY cannot receive ETH (a 1-wei probe reverted)");
    }

    /// @dev The EXPECTED_NFT_ADDRESS pin (see the contract @dev). Returns true for the RESUME PATH: code already
    ///      sits at EXPECTED_NFT_ADDRESS, so the run finishes that NFT's configuration instead of deploying.
    function _preflightExpected(Cfg memory c, address me) internal view returns (bool resume) {
        require(
            c.delegateRegistry != address(0),
            "deploy-nft: EXPECTED_NFT_ADDRESS is set but DELEGATE_REGISTRY is not (a delegation-only launch needs the registry)"
        );
        if (block.chainid == LaunchGuards.RH_MAINNET) {
            require(
                c.delegateRegistry == DELEGATE_XYZ_V2,
                "deploy-nft: DELEGATE_REGISTRY is not the canonical delegate.xyz v2 registry the delegation page writes to"
            );
        }
        require(
            me.code.length == 0,
            "deploy-nft: the deployer account has code (an EIP-7702 delegate can move its nonce): use a plain key with no code"
        );
        if (c.expectedNft.code.length != 0) return true;
        uint64 nonce = vm.getNonce(me);
        address predicted = vm.computeCreateAddress(me, nonce);
        require(
            predicted == c.expectedNft,
            string.concat(
                "deploy-nft: EXPECTED_NFT_ADDRESS ",
                vm.toString(c.expectedNft),
                " is not the address this deploy would create (",
                vm.toString(predicted),
                " at deployer nonce ",
                vm.toString(uint256(nonce)),
                "): the deployer key sent a transaction first, or EXPECTED_NFT_ADDRESS is wrong. Nothing was sent."
            )
        );
    }

    /// @dev The resume path's proof that EXPECTED_NFT_ADDRESS is THIS deployer's NFTCollection, built from THIS env.
    ///      Returns which of the two configuration calls are still missing. Refuses anything it cannot finish safely.
    function _resumeChecks(Cfg memory c, address me) internal returns (bool needRecipients, bool needRegistry) {
        address target = c.expectedNft;
        // (1) created by this deployer: CREATE(me, n) for some n below its current nonce.
        uint64 nonce = vm.getNonce(me);
        require(nonce <= MAX_RESUME_NONCE_SCAN, "deploy-nft: resume: the deployer nonce is too high to scan for the NFT");
        bool created;
        for (uint64 i; i < nonce; ++i) {
            if (vm.computeCreateAddress(me, i) == target) {
                created = true;
                break;
            }
        }
        require(created, "deploy-nft: resume: EXPECTED_NFT_ADDRESS was not created by this deployer key");
        // (2) the exact NFTCollection runtime for these immutables, checked BEFORE any getter is called on it. Built in
        //     simulation only and reverted: the constructor's storage (owner) is not part of the runtime code, so the
        //     hashes match byte for byte. The four immutables are the only per-deploy bytes in the runtime.
        uint256 snap = vm.snapshotState();
        bytes32 refHash = address(new NFTCollection(c.mintPrice, c.oracle, c.revealDelay, c.renderer, me)).codehash;
        vm.revertToState(snap);
        require(
            target.codehash == refHash,
            "deploy-nft: resume: the code at EXPECTED_NFT_ADDRESS is not NFTCollection built with MINT_PRICE_WEI / DRAND_ORACLE / REVEAL_DELAY / RENDERER_ADDR"
        );
        NFTCollection nft = NFTCollection(target);
        // (3) still ours to configure.
        require(nft.owner() == me, "deploy-nft: resume: the NFT is not owned by this deployer key");
        require(nft.pendingOwner() == address(0), "deploy-nft: resume: the NFT has a pending ownership transfer");
        // (4) what is missing. A set value must already equal the env: recipients are re-pointable only before the
        //     mint and the registry is write-once, so a mismatch means the env is not what built this NFT.
        if (nft.lpTreasury() == address(0)) {
            require(
                nft.seedTreasury() == address(0) && nft.team() == address(0), "deploy-nft: resume: recipients half-set"
            );
            require(nft.mintStart() == 0 && nft.totalMinted() == 0, "deploy-nft: resume: the mint already started");
            needRecipients = true;
        } else {
            require(
                nft.lpTreasury() == me && nft.seedTreasury() == c.seedTreasury && nft.team() == c.team,
                "deploy-nft: resume: the NFT's recipients differ from LP_TREASURY / SEED_TREASURY / TEAM_WALLET"
            );
        }
        address reg = address(nft.delegateRegistry());
        if (reg == address(0)) {
            needRegistry = true;
        } else {
            require(
                reg == c.delegateRegistry,
                "deploy-nft: resume: the NFT is bound (write-once) to a different delegate registry than DELEGATE_REGISTRY"
            );
        }
    }

    function _run(address me) internal returns (address nftAddr) {
        Cfg memory c = _cfg();
        _preflight(c, me);
        bool resume = c.expectedNft != address(0) && _preflightExpected(c, me);

        NFTCollection nft;
        if (resume) {
            (bool needRecipients, bool needRegistry) = _resumeChecks(c, me);
            nft = NFTCollection(c.expectedNft);
            if (needRecipients || needRegistry) {
                vm.startBroadcast();
                if (needRecipients) nft.setRecipients(c.lpTreasury, c.seedTreasury, c.team);
                if (needRegistry) nft.setDelegateRegistry(c.delegateRegistry); // write-once
                vm.stopBroadcast();
            }
            console2.log("RESUME: EXPECTED_NFT_ADDRESS already holds this deployer's NFTCollection; nothing was deployed.");
            console2.log("  sent setRecipients      ", needRecipients);
            console2.log("  sent setDelegateRegistry", needRegistry);
        } else {
            vm.startBroadcast();
            nft = new NFTCollection(c.mintPrice, c.oracle, c.revealDelay, c.renderer, me);
            nft.setRecipients(c.lpTreasury, c.seedTreasury, c.team);
            if (c.delegateRegistry != address(0)) nft.setDelegateRegistry(c.delegateRegistry); // write-once
            // The mint is left CLOSED here: starting it is a deliberate, separate go-live action (see Next below).
            // THERE IS NO openPublicMint(). openAllowlistMint() stamps mintStart and the windows then run
            // GTD -> overflow -> public BY ELAPSED TIME, with no second call. The root is REQUIRED first
            // (openAllowlistMint reverts AllowlistRootUnset), because the GTD window would otherwise admit nobody.
            vm.stopBroadcast();
            if (c.expectedNft != address(0)) {
                require(address(nft) == c.expectedNft, "deploy-nft: the NFT did not land at EXPECTED_NFT_ADDRESS");
            }
        }
        nftAddr = address(nft);

        require(nft.seedTreasury() == c.seedTreasury && nft.lpTreasury() == me && nft.team() == c.team, "deploy-nft: recipients");
        if (c.expectedNft != address(0)) {
            require(address(nft.delegateRegistry()) == c.delegateRegistry, "deploy-nft: delegate registry not wired");
            console2.log("EXPECTED_NFT_ADDRESS matched: delegations signed against it point at this NFT");
        }
        console2.log("NFTCollection", nftAddr);
        console2.log("  mintPrice (wei, immutable)  ", nft.mintPrice());
        console2.log("  revealDelay (s, immutable)  ", nft.revealDelay());
        console2.log("  drand oracle (immutable)    ", address(nft.drand()));
        console2.log("  lpTreasury (= this deployer)", nft.lpTreasury());
        console2.log("  seedTreasury (10% prize seed)", nft.seedTreasury());
        console2.log("  team (10% team + operations)", nft.team());
        if (c.seedTreasuryAllowContract) {
            console2.log("NOTE: SEED_TREASURY_ALLOW_CONTRACT=true: the seed wallet is a contract; run SeedRaffleVault as a simulation and submit its calldata from it");
        }
        if (c.delegateRegistry == address(0)) {
            console2.log("DELEGATE_REGISTRY unset: delegatedAllowlistMint is DISABLED (set it before the mint to enable delegation)");
        }
        console2.log(
            "Next: [reserveMint] -> setAllowlistRoot(root) -> setMintOpen(true) -> openAllowlistMint() (the one start action)"
        );
        console2.log("Then: mint out -> finalizeLaunch() -> Deploy.s.sol with NFT_ADDRESS set -> GoLiveMainnet.s.sol");
        console2.log("      (do NOT call withdrawProceeds() first: GoLiveMainnet withdraws the LP bucket itself, exact anchor)");
        console2.log("      -> script/SeedRaffleVault.s.sol from SEED_TREASURY, before the opening draw");
        console2.log(string.concat("export NFT_ADDRESS=", vm.toString(nftAddr)));
    }
}
