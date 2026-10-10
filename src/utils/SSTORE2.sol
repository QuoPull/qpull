// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  SSTORE2
/// @notice Store immutable blobs as the *runtime code* of throwaway contracts and read them back with
///         `EXTCODECOPY`. Writing costs the one-time code-deposit (~200 gas/byte); reads are a cheap copy.
/// @dev    Minimal MIT reimplementation of the well-known 0xSequence/Solady pattern (Solmate's is AGPL, so
///         not vendored here). The stored blob is prefixed with a single `STOP` (0x00) byte so the storage
///         contract can never be invoked; reads skip that byte. A blob is capped at 24,575 bytes (the
///         24,576 runtime-code limit minus the STOP prefix), callers chunk anything larger.
library SSTORE2 {
    uint256 internal constant DATA_OFFSET = 1; // leading STOP byte

    error DeploymentFailed();

    /// @notice Deploy a storage contract whose runtime code is `0x00 || data` and return its address.
    function write(bytes memory data) internal returns (address pointer) {
        // Creation code: an 11-byte preamble that copies everything after itself into memory and RETURNs it
        // as the new contract's runtime code, followed by the runtime (STOP prefix + data).
        //   60 0B  PUSH1 0x0B  (offset past this 11-byte preamble)
        //   59     MSIZE       (0)
        //   81     DUP2
        //   38     CODESIZE
        //   03     SUB         (codeSize - 11)
        //   80     DUP1
        //   92     SWAP3
        //   59     MSIZE
        //   39     CODECOPY
        //   F3     RETURN
        bytes memory creation = abi.encodePacked(
            hex"60_0B_59_81_38_03_80_92_59_39_F3",
            hex"00", // STOP: the stored contract can never be called
            data
        );
        assembly {
            pointer := create(0, add(creation, 0x20), mload(creation))
        }
        if (pointer == address(0)) revert DeploymentFailed();
    }

    /// @notice Read the full blob written to `pointer` (excludes the STOP prefix).
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 codeSize = pointer.code.length;
        if (codeSize <= DATA_OFFSET) return "";
        uint256 size = codeSize - DATA_OFFSET;
        assembly {
            data := mload(0x40)
            // reserve word-aligned space: 32 (length slot) + roundUp(size)
            mstore(0x40, add(data, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            mstore(data, size)
            extcodecopy(pointer, add(data, 0x20), DATA_OFFSET, size)
        }
    }
}
