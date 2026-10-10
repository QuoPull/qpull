// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { OwnershipBase } from "../../script/TransferOwnership.s.sol";

interface ISafeProxyFactory141 {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function createChainSpecificProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @dev The factory entry points the Safe UI and SDKs also use: the two L2 variants exist only on SafeProxyFactory 1.5.0,
///      createProxyWithCallback only on 1.4.1 (selectors read from both factories' bytecode on 4663, read-only).
interface ISafeProxyFactoryVariants {
    function createProxyWithNonceL2(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function createChainSpecificProxyWithNonceL2(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function createProxyWithCallback(address singleton, bytes memory initializer, uint256 saltNonce, address callback)
        external
        returns (address proxy);
}

/// @dev A no-op IProxyCreationCallback for SafeProxyFactory 1.4.1 createProxyWithCallback.
contract NoopProxyCreationCallback {
    function proxyCreated(address, address, bytes calldata, uint256) external { }
}

interface ISafeVersion {
    function VERSION() external view returns (string memory);
}

interface ISafe141 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
    function isOwner(address owner) external view returns (bool);
    function addOwnerWithThreshold(address owner, uint256 threshold) external;
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;
    function changeThreshold(uint256 threshold) external;
    function masterCopy() external view returns (address);
}

/// Exposes the pin TransferOwnership and VerifyOwnership both run (via _checkSafe), with the creation inputs
/// (SAFE_SETUP_INITIALIZER, SAFE_SALT_NONCE) supplied per test through the env seam.
contract SafePinHarness is OwnershipBase {
    bytes internal init_;
    uint256 internal nonce_;

    function setCreation(bytes memory initializer, uint256 saltNonce) external {
        init_ = initializer;
        nonce_ = saltNonce;
    }

    function _envBytes(string memory key) internal view override returns (bytes memory) {
        require(keccak256(bytes(key)) == keccak256("SAFE_SETUP_INITIALIZER"), key);
        return init_;
    }

    function _envUint(string memory key) internal view override returns (uint256) {
        require(keccak256(bytes(key)) == keccak256("SAFE_SALT_NONCE"), key);
        return nonce_;
    }

    function check(address safe) external view {
        _checkSafeCode(safe);
    }
}

/// Delegatecalled by Safe.setup, writes two addresses into OwnerManager's `owners` mapping (slot 2) without
/// linking them into the owner list (a hidden-owner setup).
contract HiddenOwnerPlanter {
    function plant(address a, address b) external {
        assembly {
            mstore(0x00, a)
            mstore(0x20, 2)
            sstore(keccak256(0x00, 0x40), 1)
            mstore(0x00, b)
            mstore(0x20, 2)
            sstore(keccak256(0x00, 0x40), 1)
        }
    }
}

/// A contract that answers the Safe shape queries but is not a Safe.
contract LookalikeSafe {
    address[] internal _owners;

    constructor(address[] memory o) {
        _owners = o;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

/// @notice The Safe pin in TransferOwnership, against REAL Safe
///         1.4.1 and 1.5.0 contracts on a read-only fork of RH mainnet (4663). Nothing is broadcast: the Safes are created
///         inside the fork. The canonical addresses and code hashes were verified read-only on 4663 (and matched on
///         Ethereum and Arbitrum One) before being pinned.
contract SafePinForkTest is Test {
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    address constant FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a; // the non-L2 singleton
    address constant FACTORY_150 = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address constant SAFE_L2_150 = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
    address constant SAFE_150 = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b; // the non-L2 singleton
    address constant SENTINEL = address(0x1);

    bytes constant PROXY_REFUSED = bytes("own: SAFE is not a canonical Safe 1.4.1 / 1.5.0 proxy (runtime codehash)");
    bytes constant SINGLETON_REFUSED = bytes("own: SAFE's singleton is not the canonical SafeL2 1.4.1 or SafeL2 1.5.0");
    bytes constant MODULE_REFUSED = bytes("own: SAFE has an enabled module (it can act without the owners' threshold)");

    SafePinHarness h;
    address[] owners;

    function _setUpFork() internal {
        vm.createSelectFork(RPC);
        assertEq(block.chainid, 4663, "RH mainnet fork");
        h = new SafePinHarness();
        for (uint256 i; i < 3; ++i) owners.push(makeAddr(string.concat("signer", vm.toString(i))));
    }

    function _init() internal view returns (bytes memory) {
        address[] memory o = owners;
        return abi.encodeCall(ISafe141.setup, (o, 2, address(0), "", address(0), address(0), 0, payable(address(0))));
    }

    /// Enable `module` by writing ModuleManager's `modules` linked list (storage slot 1, same layout in 1.4.1 and 1.5.0).
    function _enableModule(address safe, address module) internal {
        vm.store(safe, keccak256(abi.encode(module, uint256(1))), bytes32(uint256(uint160(SENTINEL))));
        vm.store(safe, keccak256(abi.encode(SENTINEL, uint256(1))), bytes32(uint256(uint160(module))));
        assertTrue(ISafe141(safe).isModuleEnabled(module), "premise: the module is enabled");
    }

    function test_fork_canonicalSafeL2_passes_andEveryOtherShapeIsRefused() public {
        _setUpFork();

        // (1) a canonical SafeL2 1.4.1 proxy, 2-of-3, no modules: passes
        address safe = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_L2_141, _init(), 0x51A7E);
        assertEq(ISafe141(safe).getThreshold(), 2, "premise: a real 2-of-3 Safe");
        h.setCreation(_init(), 0x51A7E);
        h.check(safe);

        // (2) the same proxy code pointing at the NON-L2 singleton: refused
        address nonL2 = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_141, _init(), 0x51A7F);
        vm.expectRevert(SINGLETON_REFUSED);
        h.check(nonL2);

        // (3) a lookalike that answers getOwners/getThreshold: refused on code
        address fake = address(new LookalikeSafe(owners));
        vm.expectRevert(PROXY_REFUSED);
        h.check(fake);

        // (4) the canonical Safe with a module enabled: a module executes without the owners' threshold, so refused
        _enableModule(safe, makeAddr("module"));
        vm.expectRevert(MODULE_REFUSED);
        h.check(safe);

        // (5) off 4663 the pin does not apply (it was verified on 4663 only)
        vm.chainId(46_630);
        h.check(fake);
    }

    /// The owner chose to allow Safe 1.5.0 too: a SafeL2 1.5.0 proxy from the canonical 1.5.0 factory passes; its non-L2 twin and a 1.5.0
    /// Safe with a module are refused, exactly like 1.4.1.
    function test_fork_safeL2_150_passes_nonL2_andModule_refused() public {
        _setUpFork();
        assertEq(ISafeVersion(SAFE_L2_150).VERSION(), "1.5.0", "premise: the 1.5.0 L2 singleton");
        assertEq(ISafeVersion(SAFE_150).VERSION(), "1.5.0", "premise: the 1.5.0 non-L2 singleton");
        assertEq(ISafeVersion(SAFE_L2_141).VERSION(), "1.4.1", "premise: the 1.4.1 L2 singleton");

        address safe = ISafeProxyFactory141(FACTORY_150).createProxyWithNonce(SAFE_L2_150, _init(), 0x150A);
        assertEq(ISafe141(safe).getThreshold(), 2, "premise: a real 2-of-3 Safe 1.5.0");
        assertEq(ISafe141(safe).getOwners().length, 3, "premise: three signers");
        assertEq(ISafeVersion(safe).VERSION(), "1.5.0", "premise: the proxy runs 1.5.0");
        h.setCreation(_init(), 0x150A);
        h.check(safe);

        address nonL2 = ISafeProxyFactory141(FACTORY_150).createProxyWithNonce(SAFE_150, _init(), 0x150B);
        assertEq(nonL2.codehash, safe.codehash, "premise: same 1.5.0 proxy code, different singleton");
        vm.expectRevert(SINGLETON_REFUSED);
        h.check(nonL2);

        _enableModule(safe, makeAddr("module150"));
        vm.expectRevert(MODULE_REFUSED);
        h.check(safe);
    }

    /// A 1.4.1 Safe migrated to 1.5.0 keeps the 1.4.1 proxy code and points slot 0 at the 1.5.0 singleton; the pin checks
    /// proxy and singleton independently, so it passes. The reverse (a 1.5.0 proxy on the 1.4.1 L2 singleton) passes too.
    /// A proxy pointed at a singleton address that is not one of the two pinned L2 singletons is refused.
    function test_fork_crossVersionProxies_andUnknownSingleton() public {
        _setUpFork();
        address migrated = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_L2_141, _init(), 0xC0DE1);
        vm.store(migrated, bytes32(0), bytes32(uint256(uint160(SAFE_L2_150))));
        assertEq(ISafeVersion(migrated).VERSION(), "1.5.0", "premise: the 1.4.1 proxy now runs 1.5.0");
        h.setCreation(_init(), 0xC0DE1); // created from the 1.4.1 L2 singleton: the creation check recomputes with the creation singleton
        h.check(migrated);

        address reverse = ISafeProxyFactory141(FACTORY_150).createProxyWithNonce(SAFE_L2_141, _init(), 0xC0DE2);
        assertEq(ISafeVersion(reverse).VERSION(), "1.4.1", "premise: the 1.5.0 proxy runs 1.4.1");
        h.setCreation(_init(), 0xC0DE2);
        h.check(reverse);

        // slot 0 pointed at an arbitrary contract (here the 1.5.0 factory): not a pinned singleton
        vm.store(reverse, bytes32(0), bytes32(uint256(uint160(FACTORY_150))));
        vm.expectRevert(SINGLETON_REFUSED);
        h.check(reverse);
    }

    // ── hidden owners planted by the setup delegatecall ───────────────────────────────────────────────────

    address constant SAFE_TO_L2_SETUP_141 = 0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54;
    address constant SAFE_TO_L2_SETUP_150 = 0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a;

    bytes constant CREATION_REFUSED =
        bytes("own: SAFE is not the address a pinned Safe 1.4.1 / 1.5.0 factory creates from SAFE_SETUP_INITIALIZER and SAFE_SALT_NONCE");
    bytes constant SETUP_TARGET_REFUSED =
        bytes("own: SAFE was set up with a delegatecall to a contract other than Safe's canonical SafeToL2Setup (it can plant hidden owners)");
    bytes constant OWNERS_CHANGED_REFUSED =
        bytes("own: SAFE's owners or threshold are not the ones its setup declared (changed since creation): the gate cannot rule out hidden owners");

    function _initWith(address to, bytes memory data) internal view returns (bytes memory) {
        address[] memory o = owners;
        return abi.encodeCall(ISafe141.setup, (o, 2, to, data, address(0), address(0), 0, payable(address(0))));
    }

    /// The hidden-owner attack, on both factory versions: a canonical SafeL2 proxy, 2-of-3, no module, whose setup
    /// delegatecalled a planter. Every earlier pin still passes on the live shape (codehashes, singleton, modules,
    /// declared owners); the creation check refuses it.
    function test_fork_hiddenOwnerSetup_refused_141_and_150() public {
        _setUpFork();
        address hA = makeAddr("hiddenA");
        address hB = makeAddr("hiddenB");
        address[2] memory factories = [FACTORY_141, FACTORY_150];
        address[2] memory l2 = [SAFE_L2_141, SAFE_L2_150];
        for (uint256 i; i < 2; ++i) {
            HiddenOwnerPlanter planter = new HiddenOwnerPlanter();
            bytes memory init = _initWith(address(planter), abi.encodeCall(HiddenOwnerPlanter.plant, (hA, hB)));
            address safe = ISafeProxyFactory141(factories[i]).createProxyWithNonce(l2[i], init, 0x4242 + i);
            assertEq(ISafe141(safe).getOwners().length, 3, "premise: getOwners lists only the three declared signers");
            assertEq(ISafe141(safe).getThreshold(), 2, "premise: 2-of-3");
            assertTrue(ISafe141(safe).isOwner(hA) && ISafe141(safe).isOwner(hB), "premise: two hidden owners were planted");
            assertFalse(ISafe141(safe).isModuleEnabled(address(planter)), "premise: no module");
            h.setCreation(init, 0x4242 + i);
            vm.expectRevert(SETUP_TARGET_REFUSED);
            h.check(safe);
        }
    }

    /// The Safe UI's L2 shape: created from the NON-L2 singleton with setup delegatecalling Safe's own SafeToL2Setup,
    /// which switches the singleton to SafeL2. Passes for 1.4.1 and 1.5.0, through both factory entry points.
    function test_fork_safeToL2SetupShape_passes_141_and_150() public {
        _setUpFork();
        bytes memory init141 =
            _initWith(SAFE_TO_L2_SETUP_141, abi.encodeWithSignature("setupToL2(address)", SAFE_L2_141));
        address s141 = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_141, init141, 0x12A);
        assertEq(ISafe141(s141).masterCopy(), SAFE_L2_141, "premise: SafeToL2Setup switched it to SafeL2 1.4.1");
        h.setCreation(init141, 0x12A);
        h.check(s141);

        bytes memory init150 =
            _initWith(SAFE_TO_L2_SETUP_150, abi.encodeWithSignature("setupToL2(address)", SAFE_L2_150));
        address s150 = ISafeProxyFactory141(FACTORY_150).createChainSpecificProxyWithNonce(SAFE_150, init150, 0x15B);
        assertEq(ISafe141(s150).masterCopy(), SAFE_L2_150, "premise: SafeToL2Setup switched it to SafeL2 1.5.0");
        h.setCreation(init150, 0x15B); // the chain-specific salt form is recomputed too
        h.check(s150);
    }

    /// Wrong creation inputs, a trailing-byte (non-canonical) initializer, a SafeToL2Setup call to a singleton that
    /// is not a pinned SafeL2 (refused earlier, by the singleton pin), and an owner change since creation.
    function test_fork_wrongInputs_nonCanonicalInit_ownerChange_refused() public {
        _setUpFork();
        address safe = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_L2_141, _init(), 0xABC);

        h.setCreation(_init(), 0xABD); // wrong salt nonce
        vm.expectRevert(CREATION_REFUSED);
        h.check(safe);

        owners.push(makeAddr("signer3"));
        h.setCreation(_initWith(address(0), ""), 0xABC); // an initializer for a different owner set
        vm.expectRevert(CREATION_REFUSED);
        h.check(safe);
        owners.pop();

        // a Safe created with junk appended to a valid setup call: the factory and setup accept it, the gate does not
        bytes memory junk = bytes.concat(_init(), hex"00");
        address junkSafe = ISafeProxyFactory141(FACTORY_141).createProxyWithNonce(SAFE_L2_141, junk, 0xABE);
        h.setCreation(junk, 0xABE);
        vm.expectRevert(bytes("own: SAFE_SETUP_INITIALIZER is not a canonically encoded setup(...) call"));
        h.check(junkSafe);

        // owners changed since creation (a real owner-authorised addOwnerWithThreshold, executed as the Safe itself)
        h.setCreation(_init(), 0xABC);
        h.check(safe);
        vm.prank(safe);
        ISafe141(safe).addOwnerWithThreshold(makeAddr("laterSigner"), 2);
        vm.expectRevert(OWNERS_CHANGED_REFUSED);
        h.check(safe);
    }

    /// The pinned SafeToL2Setup contracts on 4663 are the ones the gate expects (address and code), and creating a Safe
    /// through each writes ONLY the Safe's own setup slots plus the singleton: every storage write during creation is one
    /// of the singleton (slot 0), the owners list of exactly the declared signers (slot 2 entries), ownerCount (3),
    /// threshold (4), the modules sentinel (slot 1 entry) or the fallback handler slot. No other owners entry exists.
    function test_fork_safeToL2Setup_writesNothingButTheSingleton_141_and_150() public {
        _setUpFork();
        assertEq(SAFE_TO_L2_SETUP_141.codehash, 0x2f25df28caf984366ee584e13241707e85dcd5a6ea0c14267928dafc1fd6274b, "1.4.1 code");
        assertEq(SAFE_TO_L2_SETUP_150.codehash, 0xf6034d841bcbff8912aa55526b0f1609212536aaf60bb16f5e8a269a4ab38f18, "1.5.0 code");
        address[2] memory factories = [FACTORY_141, FACTORY_150];
        address[2] memory nonL2 = [SAFE_141, SAFE_150];
        address[2] memory l2 = [SAFE_L2_141, SAFE_L2_150];
        address[2] memory setups = [SAFE_TO_L2_SETUP_141, SAFE_TO_L2_SETUP_150];
        for (uint256 v; v < 2; ++v) {
            bytes memory init = _initWith(setups[v], abi.encodeWithSignature("setupToL2(address)", l2[v]));
            vm.record();
            address safe = ISafeProxyFactory141(factories[v]).createProxyWithNonce(nonL2[v], init, 0x5E7 + v);
            (, bytes32[] memory writes) = vm.accesses(safe);
            assertGt(writes.length, 0, "premise: creation writes were recorded");
            for (uint256 i; i < writes.length; ++i) {
                assertTrue(_isSetupSlot(writes[i]), "a creation write outside the Safe's setup slots");
            }
            assertEq(ISafe141(safe).masterCopy(), l2[v], "the one SafeToL2Setup effect");
            h.setCreation(init, 0x5E7 + v);
            h.check(safe);
        }
    }

    /// The creation-input recipe for the other factory entry points. SafeProxyFactory 1.5.0's
    /// createProxyWithNonceL2 and createChainSpecificProxyWithNonceL2 take the same three arguments and use the same
    /// salt as their non-L2 forms, so SAFE_SALT_NONCE is the call's own saltNonce. SafeProxyFactory 1.4.1's four-argument
    /// createProxyWithCallback salts with uint256(keccak256(abi.encodePacked(saltNonce, callback))), so SAFE_SALT_NONCE is
    /// that derived value, and the raw saltNonce is refused.
    function test_fork_l2AndCallbackFactoryEntryPoints_pass() public {
        _setUpFork();
        address a = ISafeProxyFactoryVariants(FACTORY_150).createProxyWithNonceL2(SAFE_L2_150, _init(), 0x1A2);
        assertEq(ISafe141(a).masterCopy(), SAFE_L2_150, "premise: a SafeL2 1.5.0 through createProxyWithNonceL2");
        h.setCreation(_init(), 0x1A2);
        h.check(a);

        bytes memory init150 =
            _initWith(SAFE_TO_L2_SETUP_150, abi.encodeWithSignature("setupToL2(address)", SAFE_L2_150));
        address b = ISafeProxyFactoryVariants(FACTORY_150).createChainSpecificProxyWithNonceL2(SAFE_150, init150, 0x1A3);
        assertEq(ISafe141(b).masterCopy(), SAFE_L2_150, "premise: the Safe UI shape through the chain-specific L2 call");
        h.setCreation(init150, 0x1A3);
        h.check(b);

        address[2] memory callbacks = [address(0), address(new NoopProxyCreationCallback())];
        for (uint256 i; i < 2; ++i) {
            uint256 raw = 0x1A4 + i;
            address c = ISafeProxyFactoryVariants(FACTORY_141).createProxyWithCallback(SAFE_L2_141, _init(), raw, callbacks[i]);
            assertEq(ISafe141(c).masterCopy(), SAFE_L2_141, "premise: a SafeL2 1.4.1 through createProxyWithCallback");
            h.setCreation(_init(), raw); // the call's own saltNonce is NOT the salt this entry point used
            vm.expectRevert(CREATION_REFUSED);
            h.check(c);
            h.setCreation(_init(), uint256(keccak256(abi.encodePacked(raw, callbacks[i]))));
            h.check(c);
        }
    }

    /// The creation check fails CLOSED on any owner or threshold change after creation, including a legitimate signer rotation
    /// (swapOwner executed by the Safe itself) and a threshold change, on 1.4.1 and 1.5.0. There is no override: the
    /// gate cannot tell a rotation from a change that hides an owner, so VerifyOwnership stays refused for that Safe.
    function test_fork_signerRotation_andThresholdChange_failClosed_141_and_150() public {
        _setUpFork();
        address[2] memory factories = [FACTORY_141, FACTORY_150];
        address[2] memory l2 = [SAFE_L2_141, SAFE_L2_150];
        for (uint256 v; v < 2; ++v) {
            address rotated = ISafeProxyFactory141(factories[v]).createProxyWithNonce(l2[v], _init(), 0x207 + v);
            h.setCreation(_init(), 0x207 + v);
            h.check(rotated);
            vm.prank(rotated);
            ISafe141(rotated).swapOwner(SENTINEL, owners[0], makeAddr(string.concat("rotatedIn", vm.toString(v))));
            assertEq(ISafe141(rotated).getOwners().length, 3, "premise: still three signers");
            assertEq(ISafe141(rotated).getThreshold(), 2, "premise: still 2-of-3");
            vm.expectRevert(OWNERS_CHANGED_REFUSED);
            h.check(rotated);

            address rethresholded = ISafeProxyFactory141(factories[v]).createProxyWithNonce(l2[v], _init(), 0x209 + v);
            h.setCreation(_init(), 0x209 + v);
            h.check(rethresholded);
            vm.prank(rethresholded);
            ISafe141(rethresholded).changeThreshold(3);
            vm.expectRevert(OWNERS_CHANGED_REFUSED);
            h.check(rethresholded);
        }
    }

    function _isSetupSlot(bytes32 w) internal view returns (bool) {
        if (w == bytes32(0) || w == bytes32(uint256(3)) || w == bytes32(uint256(4))) return true; // singleton, ownerCount, threshold
        if (w == keccak256("fallback_manager.handler.address")) return true;
        if (w == keccak256(abi.encode(SENTINEL, uint256(1)))) return true; // modules sentinel
        if (w == keccak256(abi.encode(SENTINEL, uint256(2)))) return true; // owners sentinel
        for (uint256 i; i < owners.length; ++i) {
            if (w == keccak256(abi.encode(owners[i], uint256(2)))) return true; // a declared owner's entry
        }
        return false;
    }
}
