// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  HookMiner — CREATE2 salt search for Uniswap-V4 hook addresses
/// @notice V4 dispatches hook callbacks by inspecting the LOW 14 BITS of the hook's ADDRESS, so the
///         hook must be deployed at an address whose flag bits are exactly the callbacks it implements.
///         Foundry scripts broadcast `new C{salt: s}(...)` through the deterministic CREATE2 deployer,
///         so the address is a pure function of (deployer, salt, initcode) — this library brute-forces
///         a salt whose resulting address carries exactly `flags`. ~16k keccaks expected; script-time
///         only, never deployed.
library HookMiner {
    /// @dev The canonical deterministic CREATE2 deployer Foundry scripts broadcast through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    uint256 internal constant MAX_LOOP = 500_000;

    error NoSaltFound();

    /// @param deployer  the CREATE2 deployer the script will broadcast through
    /// @param flags     the exact low-14-bit pattern the hook address must carry
    /// @param initCode  type(Hook).creationCode ++ abi.encode(constructor args)
    function find(address deployer, uint160 flags, bytes memory initCode)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 s; s < MAX_LOOP; ++s) {
            hookAddress = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(s), initCodeHash)))
                )
            );
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(s));
            }
        }
        revert NoSaltFound();
    }
}
