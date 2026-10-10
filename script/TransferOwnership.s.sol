// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { Treasury } from "../src/Treasury.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";

interface IOwn2 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @dev Safe 1.4.1 / 1.5.0 `setup`, the call a SafeProxyFactory makes on a new proxy (same signature in both versions).
interface ISafeSetup {
    function setup(
        address[] memory owners,
        uint256 threshold,
        address to,
        bytes memory data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/// @dev SafeProxyFactory 1.4.1 / 1.5.0: the proxy init code it CREATE2s (the singleton address is appended).
interface ISafeProxyFactoryCode {
    function proxyCreationCode() external view returns (bytes memory);
}

/// @dev Safe's SafeToL2Setup helper: the one delegatecall target the Safe UI puts in `setup` on an L2.
interface ISafeToL2Setup {
    function setupToL2(address l2Singleton) external;
}

/// @dev The write-once, non-Ownable bindings the gate verifies. Declared as a minimal read surface rather than
///      importing every contract, which keeps this script (and every test that imports it) cheap to compile.
interface ILockOpener {
    function opener() external view returns (address);
}

interface ILeaderboardRegistryRoles {
    function recorder() external view returns (address);
    function xpRecorder() external view returns (address);
}

interface IPackRegistryRoles {
    function recorder() external view returns (address);
    function engine() external view returns (address);
    function nft() external view returns (address);
    function leaderboard() external view returns (address);
}

interface IEngineBound {
    function vault() external view returns (address);
}

interface ILeaderboardEngineBound {
    function registry() external view returns (address);
    function vault() external view returns (address);
    function claimManager() external view returns (address);
}

interface IHolderEngineBound {
    function nft() external view returns (address);
    function vault() external view returns (address);
    function claimManager() external view returns (address);
}

interface IClaimManagerBindings {
    function engineVault(address engine) external view returns (address);
    function enginesLocked() external view returns (bool);
    function engineCount() external view returns (uint256);
}

interface IControlled {
    function controller() external view returns (address);
}

interface ITreasuryBound {
    function treasury() external view returns (address);
}

interface INftBindings {
    function taxHook() external view returns (address);
    function renderer() external view returns (address);
}

interface IRendererLock {
    function locked() external view returns (bool);
}

/// @title  OWNERSHIP HANDOVER: the procedure behind the launch's ownership gate
///
/// @notice The launch's ownership gate was first written as `owner() == Timelock+multisig on every ownable contract`.
///         This script stages those transfers, and VerifyOwnership checks the result.
///
///         ONE SAFE, NO TIMELOCK, and that is a deliberate reversal of the gate's own wording:
///           - The engines' economic knobs are ALREADY delayed in bytecode. Every one writes prev* plus an
///             *EffectiveDay/Week of period+1, is read through xAt(period), and carries a band, a cooldown
///             and an N-1 period guard. A TimelockController on top is double-delay, not defence.
///           - A 48h delay would SILENTLY disable the opening retune. RaffleEngine's opening setters are a
///             bare `if (d < ACCUM_DAYS)`, so past the window they succeed and discard the opening half.
///           - It would also destroy the only same-block incident lever. Treasury.setKeeper is deliberately
///             not lock-gated, and OpenZeppelin's TimelockController has ONE global minDelay with no
///             per-selector granularity, so "fast keeper, slow caps" is unreachable without new code.
///
/// @dev    TWO ENTRY POINTS, run with --tc:
///           TransferOwnership   deployer key, --broadcast. Stages every transfer. Moves no ownership:
///                               Ownable2Step leaves owner() untouched until the DESTINATION accepts, and
///                               the destination is a Safe this key cannot sign for.
///           VerifyOwnership     KEYLESS, no broadcast. THE GATE. Re-runnable by anyone, forever.
///
///         The accept is one MultiSend batch of acceptOwnership() calls signed in the Safe: one ceremony,
///         so a tampered pendingOwner reverts the whole batch loudly instead of half-migrating.
///
///         ADDRESSES ARE DERIVED, NOT TYPED, wherever the chain can supply them. The root is HOOK, which is
///         entirely immutable, so a wrong HOOK fails closed rather than migrating the wrong protocol. The
///         DEPLOYER is derived too: it is the liquidity lock's immutable `opener` (the lock is the hook's
///         `initializer`). Only the two engines the graph cannot reach are read from env
///         (LEADERBOARD_ENGINE, HOLDER_ENGINE), and BOTH the preflight and the gate cross-check each against
///         the ClaimManager's frozen engine->vault map and against its own immutables, so a decoy, an orphan
///         from an aborted deploy, or a duplicate cannot stand in for a live engine. The KEEPER is an env
///         input and is pinned: it must be the Treasury's one and only keeper.
///
///         The gate also verifies the write-once, NON-Ownable roles that ownership alone does not cover
///         (registry recorders and engine, the xpRecorder, vault controllers, the frozen ClaimManager map, the
///         adapters' treasury, the NFT's tax hook and renderer lock), because a handover that completes with
///         any of those pointing somewhere else is not a finished launch.
///
///         SAFE_OWNERS_HASH = keccak256(abi.encode(SAFE, getOwners(), getThreshold())). It binds the Safe's
///         ADDRESS as well as its signer set, so a lookalike contract returning the same owners at a different
///         address does not match.
///
///         HOW THE SAFE WAS CREATED (on 4663): SAFE_SETUP_INITIALIZER and SAFE_SALT_NONCE, both copied from the
///         Safe's creation transaction (the factory call's `initializer` and `saltNonce` arguments), let both entry points
///         recompute the Safe's CREATE2 address and read the setup that actually ran. A setup whose delegatecall target is
///         anything but nothing or Safe's canonical SafeToL2Setup is refused: that delegatecall can plant owners that
///         getOwners() never lists and that a VerifyOwnership PASS without this check could not see.
///
///         THIS CHECK FAILS CLOSED, PERMANENTLY, ON ANY OWNER OR THRESHOLD CHANGE AFTER CREATION. The owners and threshold the
///         setup declared must still be exactly getOwners() and getThreshold(). Adding, removing or swapping a signer
///         (a legitimate rotation included) or changing the threshold makes BOTH entry points refuse that Safe from then
///         on, with "own: SAFE's owners or threshold are not the ones its setup declared (changed since creation)": the
///         gate cannot tell a rotation from a change made to hide an owner, and there is no override. After the handover
///         that means VerifyOwnership can never PASS again for that Safe. So either keep the signer set and threshold
///         fixed from creation, or rotate by creating a NEW Safe with the final signers, moving ownership to it
///         (transferOwnership from the old Safe, one acceptOwnership batch from the new one), and re-proving with
///         VerifyOwnership against the new SAFE, SAFE_OWNERS_HASH, SAFE_SETUP_INITIALIZER and SAFE_SALT_NONCE.
///         test/fork/SafePinFork.t.sol (signerRotation_andThresholdChange_failClosed) pins this on real 1.4.1 and 1.5.0 Safes.
///
///         PassArtRenderer is DELIBERATELY EXCLUDED from the transfer. It is plain single-step `Ownable` (a typo
///         there is instantly permanent, with no pending-owner safety net) and its owner is provably powerless
///         once `lock()` has run, which NFTCollection's constructor requires (NFTCollection.sol, RendererNotLocked).
///         Both entry points assert `NFTCollection.renderer().locked()` instead.
abstract contract OwnershipBase is Script {
    uint256 internal constant N = 13;

    // ── The canonical Safe v1.4.1 and v1.5.0 deployments, pinned on Robinhood Chain mainnet (4663) ───────────────
    // v1.4.1, verified read-only on 2026-09-13 with eth_getCode against rpc.mainnet.chain.robinhood.com: the SafeL2
    // 1.4.1 singleton, the Safe 1.4.1 singleton and SafeProxyFactory 1.4.1 all have code at their canonical addresses,
    // and each keccak256(code) is byte-identical to the same address on Ethereum mainnet (1) and Arbitrum One (42161).
    // v1.5.0, verified the same way on 2026-09-14: SafeL2 1.5.0 0xEdd1...7C7e (VERSION() "1.5.0",
    // codehash 0x1801...72dc), Safe 1.5.0 0xFf51...a44b (non-L2, codehash 0xdda0...20f2) and SafeProxyFactory 1.5.0
    // 0x14F2...5e7b (codehash 0x967d...4529) have code on 4663 identical to Ethereum (1) and Arbitrum One (42161),
    // and the factory's proxyCreationCode hashes to 0x941b...7e12 on all three.
    // Those addresses are CREATE2 outputs of the Safe singleton factory, so the address alone commits to the
    // init code. Each proxy codehash is keccak256 of the runtime that factory's proxyCreationCode() deploys (an
    // eth_call create on 4663). A proxy keeps its singleton in storage slot 0, so the runtime code, and the hash, are
    // the same for every proxy of that factory version, whatever singleton it points at.
    // The required shape: a SafeL2 (1.4.1 or 1.5.0) proxy with no modules.
    address internal constant SAFE_L2_141_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 internal constant SAFE_L2_141_SINGLETON_CODEHASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    bytes32 internal constant SAFE_PROXY_141_CODEHASH = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    address internal constant SAFE_L2_150_SINGLETON = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
    bytes32 internal constant SAFE_L2_150_SINGLETON_CODEHASH =
        0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc;
    bytes32 internal constant SAFE_PROXY_150_CODEHASH = 0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f;
    address internal constant SAFE_SENTINEL_MODULES = address(0x1);

    // ── How the Safe was CREATED ───────────────────────────────────────────────────────────────────────────────────────
    // Safe.setup DELEGATECALLs its `to` with `data`, and that code can write the owners mapping without linking the
    // entries into the owner list: getOwners() and getThreshold() still show the declared 2-of-3, no module is enabled,
    // every codehash is canonical, and yet the planted addresses can sign (checkNSignatures only needs owners[signer] != 0).
    // No read of the live Safe can see them. The creation inputs can: the Safe's address is the CREATE2 output of the
    // factory over keccak256(initializer) and the salt nonce, so recomputing it from SAFE_SETUP_INITIALIZER and
    // SAFE_SALT_NONCE proves exactly which setup ran, and the setup's `to` must then be nothing or Safe's own
    // SafeToL2Setup. All values below were read on 4663 with eth_getCode / eth_call on 2026-09-14 (read-only):
    //   SafeProxyFactory 1.4.1 0x4e1D...ec67: proxyCreationCode() is 486 bytes, keccak 0x1856...af5f
    //   SafeProxyFactory 1.5.0 0x14F2...5e7b: proxyCreationCode() is 438 bytes, keccak 0x941b...7e12
    //   Safe 1.4.1 (non-L2) 0x4167...461a VERSION() "1.4.1", codehash 0x1fe2...e1c4; Safe 1.5.0 (non-L2) 0xFf51...a44b
    //     VERSION() "1.5.0", codehash 0xdda0...20f2 (creation singletons: the Safe UI creates an L2 Safe from the non-L2
    //     singleton and switches it with SafeToL2Setup)
    //   SafeToL2Setup 1.4.1 0xBD89...dc54 and 1.5.0 0x900C...D82a: 820 bytes each, one external function setupToL2(address)
    //     (selector 0xfe51f643), exactly ONE SSTORE (slot 0, the singleton), no DELEGATECALL / CREATE / SELFDESTRUCT, a
    //     ChangedMasterCopy(address) LOG1; the two runtimes differ only in the embedded own address and the metadata hash.
    address internal constant SAFE_PROXY_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    bytes32 internal constant SAFE_PROXY_CREATION_CODE_141_HASH =
        0x1856e0ee08399d74e0ea0b03adca210aeade6f748969ac023cdcb4dd62dcaf5f;
    address internal constant SAFE_PROXY_FACTORY_150 = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    bytes32 internal constant SAFE_PROXY_CREATION_CODE_150_HASH =
        0x941b3e88811b2f33b8e26783c7407d2e978404581a21c9f07abf2cad9cb87e12;
    address internal constant SAFE_141_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    bytes32 internal constant SAFE_141_SINGLETON_CODEHASH = 0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;
    address internal constant SAFE_150_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
    bytes32 internal constant SAFE_150_SINGLETON_CODEHASH = 0xdda019cbd7c867a533a2a86e5c53434fdc50b13122b5a5ddb4a8df61b31c20f2;
    address internal constant SAFE_TO_L2_SETUP_141 = 0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54;
    bytes32 internal constant SAFE_TO_L2_SETUP_141_CODEHASH =
        0x2f25df28caf984366ee584e13241707e85dcd5a6ea0c14267928dafc1fd6274b;
    address internal constant SAFE_TO_L2_SETUP_150 = 0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a;
    bytes32 internal constant SAFE_TO_L2_SETUP_150_CODEHASH =
        0xf6034d841bcbff8912aa55526b0f1609212536aaf60bb16f5e8a269a4ab38f18;

    struct OS {
        address safe;
        address deployer; // derived: QpullLiquidityLock(hook.initializer()).opener()
        address keeper; // env KEEPER, pinned against the Treasury
        address hook;
        address treasury;
        address[N] inst;
        string[N] name;
        bool[N] skip; // testnet-only; see _validateSkips
    }

    /// @dev The env seam. Production reads the process environment; a test overrides these to supply per-test
    ///      values, because vm.setEnv writes one process-wide environment that concurrent tests would race on.
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function _envBytes32(string memory key) internal view virtual returns (bytes32) {
        return vm.envBytes32(key);
    }

    function _envBytes(string memory key) internal view virtual returns (bytes memory) {
        return vm.envBytes(key);
    }

    function _envUint(string memory key) internal view virtual returns (uint256) {
        return vm.envUint(key);
    }

    function _load() internal view returns (OS memory s) {
        s.safe = _envAddress("SAFE");
        s.hook = _envAddress("HOOK");
        s.keeper = _envAddress("KEEPER");

        QpullTaxHook h = QpullTaxHook(s.hook);
        // Derived, not typed: VerifyOwnership must run with no key at all, and a gate that trusts a DEPLOYER env
        // it was handed can be pointed at any address that is not a keeper.
        s.deployer = ILockOpener(h.initializer()).opener();
        s.treasury = h.treasury();
        Treasury t = Treasury(s.treasury);
        PackRegistry p = PackRegistry(address(h.packRegistry()));

        s.inst[0] = s.treasury;
        s.inst[1] = address(h.packRegistry());
        s.inst[2] = address(h.leaderboardRegistry());
        s.inst[3] = address(h.nft());
        s.inst[4] = t.prizeVault();
        s.inst[5] = t.holderVault();
        s.inst[6] = t.leaderboardVault();
        s.inst[7] = address(t.qpullWeth());
        s.inst[8] = address(t.wethQuotron());
        s.inst[9] = p.engine(); // RaffleEngine, reached through the registry it is write-once bound to
        s.inst[10] = address(RaffleEngine(p.engine()).claimManager()); // and the ClaimManager it is bound to
        s.inst[11] = _envAddress("LEADERBOARD_ENGINE"); // cross-checked in _checkGraph
        s.inst[12] = _envAddress("HOLDER_ENGINE"); // cross-checked in _checkGraph

        s.name[0] = "Treasury";
        s.name[1] = "PackRegistry";
        s.name[2] = "LeaderboardRegistry";
        s.name[3] = "NFTCollection";
        s.name[4] = "prizeVault";
        s.name[5] = "holderDrawVault";
        s.name[6] = "leaderboardVault";
        s.name[7] = "QpullWethAdapter";
        s.name[8] = "QuotronRouterAdapter";
        s.name[9] = "RaffleEngine";
        s.name[10] = "ClaimManager";
        s.name[11] = "LeaderboardEngine";
        s.name[12] = "HolderDrawEngine";

        // THE TESTNET FIXTURE HATCH. DeployTestnet substitutes mocks for pieces that have no testnet
        // counterpart, and a mock that is not Ownable cannot be migrated at all. That is not hypothetical:
        // the first live rehearsal died here, on a MockSwapAdapter, with routing already locked -- so the
        // adapter could not be replaced and the whole handover was unreachable. Rather than loosen the gate
        // for everyone, name the offenders explicitly and let _validateSkips prove they are harmless.
        address[] memory skips = vm.envOr("NOT_OWNABLE", ",", new address[](0));
        for (uint256 k; k < skips.length; ++k) {
            bool found;
            for (uint256 i; i < N; ++i) {
                if (s.inst[i] == skips[k]) {
                    s.skip[i] = true;
                    found = true;
                }
            }
            // A typo in this list must not silently migrate everything as if the list were empty.
            require(found, "own: NOT_OWNABLE names an address that is not in the migration set");
        }
    }

    /// @dev THE THREE GUARDS THAT KEEP THE HATCH FROM BEING A BACK DOOR. Without these it is simply
    ///      "type an address here to leave it with the deployer", which is the precise failure this whole
    ///      script exists to prevent. Called by BOTH entry points -- the permanent gate has to re-prove it,
    ///      because a gate that trusts an env var it was handed is not a gate.
    function _validateSkips(OS memory s) internal view {
        uint256 skipped;
        for (uint256 i; i < N; ++i) {
            if (!s.skip[i]) continue;
            ++skipped;
            // (2) IT MUST GENUINELY HAVE NO OWNER. This is the load-bearing guard. If the contract answers
            //     owner(), it is Ownable and it migrates -- no exceptions, no judgement call, no env var.
            (bool ok, bytes memory ret) = s.inst[i].staticcall(abi.encodeWithSignature("owner()"));
            require(
                !(ok && ret.length == 32),
                string.concat("own: ", s.name[i], " DOES have owner() -- it must migrate, not be skipped")
            );
            console2.log(string.concat("  SKIPPED (not Ownable): ", s.name[i]), s.inst[i]);
        }
        // (1) NEVER ON MAINNET. A testnet affordance refused outright on 4663 regardless of env.
        require(
            skipped == 0 || block.chainid != 4663,
            "own: NOT_OWNABLE is FORBIDDEN on mainnet (chainid 4663) -- every instance must migrate"
        );
        // (3) NOT ALL OF THEM. A hatch that can empty the set turns the gate into a no-op that prints PASS.
        require(skipped < N, "own: NOT_OWNABLE cannot cover the whole migration set");
    }

    /// @dev The destination. The gate proves `owner() == $SAFE`, and $SAFE is an env value the gate itself
    ///      supplies, so the caller must also declare the exact Safe, signer set and threshold, hashed. That hash
    ///      comes from a human reading the Safe's own UI, a different source from the address.
    function _checkSafe(OS memory s) internal view {
        require(s.safe.code.length > 0, "own: SAFE has no code (not a deployed Safe)");
        require(s.safe != s.deployer, "own: SAFE is the deployer");
        _checkSafeCode(s.safe);
        uint256 threshold = ISafe(s.safe).getThreshold();
        address[] memory owners = ISafe(s.safe).getOwners();
        // THE INVARIANT IS "NO SINGLE KEY", NOT A PARTICULAR SHAPE.
        require(threshold >= 2, "own: SAFE threshold must be at least 2 (a 1-of-N is a single key)");
        // And losing ONE key must not lock the protocol out forever: nine of these instances are
        // NonRenounceableOwnable2Step, so an owner below its own threshold can never hand off.
        require(
            owners.length > threshold, "own: SAFE has no spare signer (losing one key would be permanent)"
        );
        require(
            keccak256(abi.encode(s.safe, owners, threshold)) == _envBytes32("SAFE_OWNERS_HASH"),
            "own: SAFE address/owners/threshold do not match SAFE_OWNERS_HASH (wrong Safe, or it changed)"
        );
    }

    /// @dev SAFE_OWNERS_HASH binds the Safe's address and signer set but not its CODE, so the code is checked here.
    ///      On 4663 the destination must be a canonical Safe proxy (runtime codehash of the 1.4.1 or the 1.5.0
    ///      SafeProxyFactory) whose singleton is the canonical SafeL2 1.4.1 or SafeL2 1.5.0 (address and codehash),
    ///      with NO enabled module: a Safe module executes transactions without the owners' threshold, so a module is
    ///      a single key the threshold checks below cannot see. The proxy version and the singleton version are
    ///      checked independently, deliberately: both proxies are the same minimal delegatecall proxy (singleton in
    ///      slot 0, answering masterCopy()), and a 1.4.1 Safe upgraded to 1.5.0 by Safe's own migration keeps its
    ///      1.4.1 proxy code while pointing at the 1.5.0 singleton. Non-L2 singletons and every other version stay
    ///      refused. Off 4663 (testnet rehearsals, local tests) the pins do not apply: they were verified on 4663
    ///      only. `virtual` solely so the OwnershipEngineEnvUnchecked harness can run the rest of the gate on chain
    ///      id 4663 against a mock Safe; test/fork/SafePinFork.t.sol exercises this function against real Safes on a
    ///      4663 fork.
    function _checkSafeCode(address safe) internal view virtual {
        if (block.chainid != 4663) return;
        require(
            safe.codehash == SAFE_PROXY_141_CODEHASH || safe.codehash == SAFE_PROXY_150_CODEHASH,
            "own: SAFE is not a canonical Safe 1.4.1 / 1.5.0 proxy (runtime codehash)"
        );
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeWithSignature("masterCopy()"));
        address singleton = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
        require(
            singleton == SAFE_L2_141_SINGLETON || singleton == SAFE_L2_150_SINGLETON,
            "own: SAFE's singleton is not the canonical SafeL2 1.4.1 or SafeL2 1.5.0"
        );
        require(
            singleton == SAFE_L2_141_SINGLETON
                ? singleton.codehash == SAFE_L2_141_SINGLETON_CODEHASH
                : singleton.codehash == SAFE_L2_150_SINGLETON_CODEHASH,
            "own: the SafeL2 singleton on this chain does not carry the canonical code"
        );
        (bool okM, bytes memory mods) = safe.staticcall(
            abi.encodeWithSignature("getModulesPaginated(address,uint256)", SAFE_SENTINEL_MODULES, uint256(10))
        );
        require(okM, "own: SAFE did not answer getModulesPaginated");
        (address[] memory modules,) = abi.decode(mods, (address[], address));
        require(modules.length == 0, "own: SAFE has an enabled module (it can act without the owners' threshold)");
        // Hidden owners planted by the setup delegatecall are invisible to every read above.
        _checkSafeCreation(safe);
    }

    /// @dev Proves how the Safe was created, from two PUBLIC inputs read off its creation transaction, the factory
    ///      call that created it. Any of these entry points (decode the creation transaction's input with the matching
    ///      signature):
    ///        createProxyWithNonce(address,bytes,uint256)                  0x1688f0b9  1.4.1 and 1.5.0
    ///        createChainSpecificProxyWithNonce(address,bytes,uint256)     0xec9e80bb  1.4.1 and 1.5.0
    ///        createProxyWithNonceL2(address,bytes,uint256)                0x4662f9d6  1.5.0 only, same salt as the non-L2 form
    ///        createChainSpecificProxyWithNonceL2(address,bytes,uint256)   0x1a334b0b  1.5.0 only, same salt as the non-L2 form
    ///        createProxyWithCallback(address,bytes,uint256,address)       0xd18af54d  1.4.1 only, four arguments
    ///      then:
    ///        SAFE_SETUP_INITIALIZER  the exact `initializer` bytes (the second argument, the ABI-encoded setup(...) call)
    ///        SAFE_SALT_NONCE         the `saltNonce` (the third argument); for createProxyWithCallback, the derived
    ///                                uint256(keccak256(abi.encodePacked(saltNonce, callback))) instead
    ///      Then: (1) SAFE is the CREATE2 address a pinned factory derives from those inputs and a pinned creation
    ///      singleton, so this initializer, and no other, is what ran; (2) it is a canonically encoded setup(...) call;
    ///      (3) its delegatecall target is nothing, or Safe's canonical SafeToL2Setup switching to a pinned SafeL2
    ///      singleton, neither of which can write an owner; (4) the owners and threshold it declared are still the
    ///      Safe's owners and threshold, so no owner change since creation is left unproven. (4) FAILS CLOSED: any owner
    ///      or threshold change after creation, a legitimate signer rotation included, refuses this Safe permanently
    ///      (see the contract notice); there is no override.
    function _checkSafeCreation(address safe) internal view {
        bytes memory init = _envBytes("SAFE_SETUP_INITIALIZER");
        uint256 saltNonce = _envUint("SAFE_SALT_NONCE");
        require(
            _isFactoryCreatedFrom(safe, init, saltNonce),
            "own: SAFE is not the address a pinned Safe 1.4.1 / 1.5.0 factory creates from SAFE_SETUP_INITIALIZER and SAFE_SALT_NONCE"
        );
        require(
            init.length >= 4 && bytes4(init) == ISafeSetup.setup.selector,
            "own: SAFE_SETUP_INITIALIZER is not a Safe setup(...) call"
        );
        (
            address[] memory owners,
            uint256 threshold,
            address to,
            bytes memory data,
            address fallbackHandler,
            address paymentToken,
            uint256 payment,
            address paymentReceiver
        ) = abi.decode(_afterSelector(init), (address[], uint256, address, bytes, address, address, uint256, address));
        require(
            keccak256(init)
                == keccak256(
                    abi.encodeCall(
                        ISafeSetup.setup,
                        (owners, threshold, to, data, fallbackHandler, paymentToken, payment, payable(paymentReceiver))
                    )
                ),
            "own: SAFE_SETUP_INITIALIZER is not a canonically encoded setup(...) call"
        );
        if (to == address(0)) {
            require(data.length == 0, "own: SAFE setup carries delegatecall data with no target");
        } else {
            require(
                (to == SAFE_TO_L2_SETUP_141 && to.codehash == SAFE_TO_L2_SETUP_141_CODEHASH)
                    || (to == SAFE_TO_L2_SETUP_150 && to.codehash == SAFE_TO_L2_SETUP_150_CODEHASH),
                "own: SAFE was set up with a delegatecall to a contract other than Safe's canonical SafeToL2Setup (it can plant hidden owners)"
            );
            require(
                keccak256(data) == keccak256(abi.encodeCall(ISafeToL2Setup.setupToL2, (SAFE_L2_141_SINGLETON)))
                    || keccak256(data) == keccak256(abi.encodeCall(ISafeToL2Setup.setupToL2, (SAFE_L2_150_SINGLETON))),
                "own: SAFE's SafeToL2Setup call is not setupToL2(canonical SafeL2 1.4.1 or 1.5.0 singleton)"
            );
        }
        require(
            threshold == ISafe(safe).getThreshold() && keccak256(abi.encode(owners)) == keccak256(abi.encode(ISafe(safe).getOwners())),
            "own: SAFE's owners or threshold are not the ones its setup declared (changed since creation): the gate cannot rule out hidden owners"
        );
    }

    /// @dev CREATE2(factory, keccak256(keccak256(initializer) ++ saltNonce [++ chainid]), keccak256(proxyCreationCode ++
    ///      singleton)) for both pinned factories, both salt forms and the four pinned creation singletons.
    function _isFactoryCreatedFrom(address safe, bytes memory init, uint256 saltNonce) internal view returns (bool) {
        bytes32 initHash = keccak256(init);
        bytes32[2] memory salts = [
            keccak256(abi.encodePacked(initHash, saltNonce)),
            keccak256(abi.encodePacked(initHash, saltNonce, block.chainid))
        ];
        address[2] memory factories = [SAFE_PROXY_FACTORY_141, SAFE_PROXY_FACTORY_150];
        bytes32[2] memory creationHashes = [SAFE_PROXY_CREATION_CODE_141_HASH, SAFE_PROXY_CREATION_CODE_150_HASH];
        address[4] memory singletons = [SAFE_L2_141_SINGLETON, SAFE_141_SINGLETON, SAFE_L2_150_SINGLETON, SAFE_150_SINGLETON];
        bytes32[4] memory singletonHashes =
            [SAFE_L2_141_SINGLETON_CODEHASH, SAFE_141_SINGLETON_CODEHASH, SAFE_L2_150_SINGLETON_CODEHASH, SAFE_150_SINGLETON_CODEHASH];
        for (uint256 f; f < 2; ++f) {
            bytes memory pc = ISafeProxyFactoryCode(factories[f]).proxyCreationCode();
            require(keccak256(pc) == creationHashes[f], "own: a pinned SafeProxyFactory returned an unexpected proxyCreationCode");
            for (uint256 i; i < 4; ++i) {
                bytes32 codeHash = keccak256(abi.encodePacked(pc, uint256(uint160(singletons[i]))));
                for (uint256 k; k < 2; ++k) {
                    if (vm.computeCreate2Address(salts[k], codeHash, factories[f]) == safe) {
                        require(
                            singletons[i].codehash == singletonHashes[i],
                            "own: the Safe's creation singleton on this chain does not carry the canonical code"
                        );
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// @dev `b` without its 4-byte selector (memory bytes cannot be sliced).
    function _afterSelector(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + 4];
        }
    }

    /// @dev THE GRAPH. Called by BOTH entry points. Every instance must exist and be distinct; the two env-typed
    ///      engines must be the ones the frozen ClaimManager map actually pays through; and the write-once,
    ///      non-Ownable roles must name the protocol's own contracts.
    function _checkGraph(OS memory s) internal view {
        for (uint256 i; i < N; ++i) {
            require(s.inst[i] != address(0), string.concat("own: zero address for ", s.name[i]));
            require(s.inst[i].code.length > 0, string.concat("own: no code at ", s.name[i]));
            // Distinctness is checked even for a skipped entry: a duplicate means the derivation or an env
            // value is wrong, whether or not the address happens to be Ownable.
            for (uint256 j = i + 1; j < N; ++j) {
                require(s.inst[i] != s.inst[j], "own: duplicate instance in the migration set");
            }
        }
        _checkEngines(s);
        _checkWriteOnceRoles(s);
    }

    /// @dev LEADERBOARD_ENGINE / HOLDER_ENGINE are typed from env. Unchecked, orphan engines from an aborted Deploy
    ///      (or any contract a stranger deploys owned by the Safe) would pass both the preflight and the gate while
    ///      the LIVE engines stayed with the deployer. ClaimManager's
    ///      engine->vault map is frozen (enginesLocked) and is exactly the set of engines that can ever register a
    ///      claim, so an engine is live iff the map binds it to its vault; each engine's own immutables must
    ///      then point back at the same vault, ClaimManager and registry/NFT.
    function _checkEngines(OS memory s) internal view {
        QpullTaxHook h = QpullTaxHook(s.hook);
        Treasury t = Treasury(s.treasury);
        IClaimManagerBindings cm = IClaimManagerBindings(s.inst[10]);
        require(cm.enginesLocked(), "own: ClaimManager engines are not locked");
        require(cm.engineCount() == 3, "own: ClaimManager does not bind exactly three engines");

        address raffle = s.inst[9];
        require(cm.engineVault(raffle) == t.prizeVault(), "own: RaffleEngine is not bound to the prize vault");
        require(IEngineBound(raffle).vault() == t.prizeVault(), "own: RaffleEngine.vault != Treasury.prizeVault");
        require(address(RaffleEngine(raffle).packs()) == s.inst[1], "own: RaffleEngine.packs != PackRegistry");

        address lb = s.inst[11];
        require(
            cm.engineVault(lb) == t.leaderboardVault(),
            "own: LEADERBOARD_ENGINE is not the engine ClaimManager binds to the leaderboard vault"
        );
        ILeaderboardEngineBound lbe = ILeaderboardEngineBound(lb);
        require(lbe.vault() == t.leaderboardVault(), "own: LEADERBOARD_ENGINE.vault != Treasury.leaderboardVault");
        require(lbe.claimManager() == s.inst[10], "own: LEADERBOARD_ENGINE.claimManager != ClaimManager");
        require(
            lbe.registry() == address(h.leaderboardRegistry()), "own: LEADERBOARD_ENGINE.registry != hook registry"
        );

        address he = s.inst[12];
        require(
            cm.engineVault(he) == t.holderVault(),
            "own: HOLDER_ENGINE is not the engine ClaimManager binds to the holder vault"
        );
        IHolderEngineBound hde = IHolderEngineBound(he);
        require(hde.vault() == t.holderVault(), "own: HOLDER_ENGINE.vault != Treasury.holderVault");
        require(hde.claimManager() == s.inst[10], "own: HOLDER_ENGINE.claimManager != ClaimManager");
        require(hde.nft() == address(h.nft()), "own: HOLDER_ENGINE.nft != hook.nft");
    }

    /// @dev The write-once roles that Ownable2Step does not cover.
    function _checkWriteOnceRoles(OS memory s) internal view {
        QpullTaxHook h = QpullTaxHook(s.hook);
        IPackRegistryRoles p = IPackRegistryRoles(s.inst[1]);
        require(p.recorder() == s.hook, "own: PackRegistry.recorder != HOOK");
        require(p.engine() == s.inst[9], "own: PackRegistry.engine != RaffleEngine");
        require(p.nft() == address(h.nft()), "own: PackRegistry.nft != hook.nft");
        require(p.leaderboard() == s.inst[2], "own: PackRegistry.leaderboard != LeaderboardRegistry");
        ILeaderboardRegistryRoles lr = ILeaderboardRegistryRoles(s.inst[2]);
        require(lr.recorder() == s.hook, "own: LeaderboardRegistry.recorder != HOOK");
        require(lr.xpRecorder() == s.inst[1], "own: LeaderboardRegistry.xpRecorder != PackRegistry");
        require(IControlled(s.inst[4]).controller() == s.inst[10], "own: prizeVault.controller != ClaimManager");
        require(IControlled(s.inst[5]).controller() == s.inst[10], "own: holderDrawVault.controller != ClaimManager");
        require(IControlled(s.inst[6]).controller() == s.inst[10], "own: leaderboardVault.controller != ClaimManager");
        require(ITreasuryBound(s.inst[7]).treasury() == s.treasury, "own: QpullWethAdapter.treasury != Treasury");
        require(ITreasuryBound(s.inst[8]).treasury() == s.treasury, "own: QuotronRouterAdapter.treasury != Treasury");
        INftBindings nft = INftBindings(s.inst[3]);
        require(nft.taxHook() == s.hook, "own: NFTCollection.taxHook != HOOK");
        require(IRendererLock(nft.renderer()).locked(), "own: NFTCollection.renderer is not locked");
    }

    /// @dev The keeper is PINNED. `keeperCount == 1` alone admits any single key,
    ///      and the old deployer check trusted an env DEPLOYER. Now: KEEPER is a keeper, it is the only one, and it
    ///      is neither the (derived) deployer nor the Safe.
    function _checkKeeper(OS memory s) internal view {
        Treasury t = Treasury(s.treasury);
        require(s.keeper != s.deployer, "own: KEEPER is the deployer");
        require(s.keeper != s.safe, "own: KEEPER is the Safe");
        require(!t.isKeeper(s.deployer), "own: deployer is STILL a Treasury keeper");
        require(t.isKeeper(s.keeper), "own: KEEPER is not a Treasury keeper");
        require(t.keeperCount() == 1, "own: Treasury must have EXACTLY ONE keeper");
    }

    /// @dev Everything that must hold BEFORE a single transfer is staged. All view; a revert here fails the
    ///      simulation, so a bad destination costs a re-run and never a broadcast.
    function _preflight(OS memory s) internal view {
        _checkSafe(s);
        _validateSkips(s);
        _checkGraph(s);
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) continue;
            // Probe owner() rather than calling it straight, so a target with no such function names itself.
            (bool ok, bytes memory ret) = s.inst[i].staticcall(abi.encodeWithSignature("owner()"));
            require(
                ok && ret.length == 32,
                string.concat("own: ", s.name[i], " has no owner() -- not Ownable (a testnet mock?)")
            );
            require(
                abi.decode(ret, (address)) == s.deployer,
                string.concat("own: not deployer-owned: ", s.name[i])
            );
        }

        // THE LAUNCH MUST BE FINISHED. Handing over mid-launch strands steps that require the deployer:
        // GoLiveMainnet's own preflight demands `Treasury.owner() == msg.sender`.
        Treasury t = Treasury(s.treasury);
        require(t.routingLocked(), "own: routing not locked -- go-live has not finished");
        require(QpullTaxHook(s.hook).launchTime() != 0, "own: pool not created -- go-live has not finished");

        // KEEPER HYGIENE, BEFORE the owner moves. After the handover this becomes a multisig ceremony.
        _checkKeeper(s);
    }

    function _report(OS memory s) internal view {
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) {
                console2.log(string.concat("  ", s.name[i]), s.inst[i], "NOT OWNABLE (testnet mock)");
                continue;
            }
            console2.log(
                string.concat("  ", s.name[i]),
                s.inst[i],
                IOwn2(s.inst[i]).owner() == s.safe ? "OWNED BY SAFE" : "pending"
            );
        }
    }
}

/// @notice STEP 7: stage every transfer. Deployer key, --broadcast. Ownership does not move here.
contract TransferOwnership is OwnershipBase {
    function run() external {
        OS memory s = _load();
        _preflight(s);
        vm.startBroadcast();
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) continue;
            // Idempotent: forge broadcasts sequentially and can stop midway. A re-run skips what already
            // points at the Safe instead of reverting.
            if (IOwn2(s.inst[i]).pendingOwner() != s.safe) IOwn2(s.inst[i]).transferOwnership(s.safe);
        }
        vm.stopBroadcast();
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) continue;
            require(
                IOwn2(s.inst[i]).pendingOwner() == s.safe,
                string.concat("own: pendingOwner not staged for ", s.name[i])
            );
        }
        console2.log("STAGED. Now execute ONE MultiSend batch of acceptOwnership() from the Safe:");
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) continue;
            console2.log(string.concat("  to ", s.name[i]), s.inst[i], "data 0x79ba5097");
        }
    }
}

/// @notice STEP 9: THE GATE. Keyless, no broadcast, re-runnable by anyone forever. This, not the transfer,
///         is what ticks the checklist: a staged transfer that was never accepted looks identical to a
///         finished migration from the deployer's side.
contract VerifyOwnership is OwnershipBase {
    function run() external view {
        OS memory s = _load();
        _checkSafe(s);
        _validateSkips(s); // the gate re-proves the hatch rather than trusting the env it was handed
        _checkGraph(s); // ...and the engines and write-once roles, rather than trusting LEADERBOARD/HOLDER_ENGINE
        for (uint256 i; i < N; ++i) {
            if (s.skip[i]) continue;
            require(IOwn2(s.inst[i]).owner() == s.safe, string.concat("own: NOT migrated: ", s.name[i]));
            require(
                IOwn2(s.inst[i]).pendingOwner() == address(0),
                string.concat("own: a transfer is still pending on ", s.name[i])
            );
        }
        require(Treasury(s.treasury).routingLocked(), "own: routing not locked");
        _checkKeeper(s);
        console2.log("OWNERSHIP GATE: PASS. All", N, "instances owned by the Safe, no pending transfers.");
        _report(s);
    }
}
