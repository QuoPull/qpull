// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { HookMiner } from "../script/HookMiner.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice Proves the real launch path: HookMiner finds a salt whose CREATE2 address carries exactly
///         the hook's flag bits, and deploying at that address through the deterministic CREATE2 deployer
///         satisfies the hook's own BadFlags self-check. If the miner and the constructor ever disagreed,
///         `_deploy` in Deploy.s.sol would revert at launch — this catches that here.
contract HookMinerTest is Test {
    // the canonical deterministic CREATE2 deployer (Foundry pre-deploys it locally too)
    address constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // = REQUIRED_FLAGS (0x1ACC)

    function test_mineAndDeployThroughCreate2() public {
        MockERC20 qpull = new MockERC20();
        MockERC20 weth = new MockERC20();
        MockNFT nft = new MockNFT();
        MockRecorder rec = new MockRecorder();

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: makeAddr("pm"),
            qpull: address(qpull),
            weth: address(weth),
            fee: 3000,
            tickSpacing: 60,
            treasury: makeAddr("treasury"),
            packRegistry: address(rec),
            leaderboardRegistry: address(rec),
            nft: address(nft),
            exemptSender: makeAddr("adapter"),
            initializer: address(this),
            earlyBuyCapWei: type(uint256).max // throttle not under test here
        });

        bytes memory initCode = abi.encodePacked(type(QpullTaxHook).creationCode, abi.encode(hc));
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2, FLAGS, initCode);

        assertEq(uint160(predicted) & ((1 << 14) - 1), FLAGS, "mined address carries exactly the flags");

        // Deploy through the real CREATE2 deployer with the mined salt. If the constructor's BadFlags
        // check disagreed with the miner, this call would revert.
        (bool ok, bytes memory ret) = CREATE2.call(abi.encodePacked(salt, initCode));
        assertTrue(ok, "CREATE2 deploy succeeded");
        address deployed = address(uint160(bytes20(ret)));
        assertEq(deployed, predicted, "deployed at the predicted address");
        assertEq(QpullTaxHook(deployed).REQUIRED_FLAGS(), FLAGS, "hook constant matches miner target");
        assertEq(uint256(FLAGS), 0x1ACC, "the WETH-tax flag set (BEFORE_SWAP 7 and its return delta 3 included)");
        assertEq(QpullTaxHook(deployed).exemptSender(), hc.exemptSender, "constructor ran, immutables set");
    }

    /// The TESTNET deploy path (DeployTestnet.s.sol) mines the SUBCLASS creation code, so its salt differs from the
    /// mainnet one. Prove that path also lands a 0x1ACC address the subclass constructor accepts. The creation code
    /// comes from the artifact, so this test does not pull every testnet subclass into its compilation unit.
    function test_mineAndDeployTestnetSubclassThroughCreate2() public {
        MockNFT nft = new MockNFT();
        MockRecorder rec = new MockRecorder();
        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: makeAddr("pm"),
            qpull: address(new MockERC20()),
            weth: address(new MockERC20()),
            fee: 3000,
            tickSpacing: 60,
            treasury: makeAddr("treasury"),
            packRegistry: address(rec),
            leaderboardRegistry: address(rec),
            nft: address(nft),
            exemptSender: makeAddr("adapter"),
            initializer: address(this),
            earlyBuyCapWei: 0.25 ether
        });
        bytes memory initCode =
            abi.encodePacked(vm.getCode("TestnetShortClock.sol:QpullTaxHookTestnet"), abi.encode(hc));
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2, FLAGS, initCode);
        assertEq(uint160(predicted) & HookMiner.FLAG_MASK, 0x1ACC, "testnet subclass mined to 0x1ACC");
        (bool ok, bytes memory ret) = CREATE2.call(abi.encodePacked(salt, initCode));
        assertTrue(ok, "testnet subclass CREATE2 deploy succeeded (BadFlags accepted the mined address)");
        address deployed = address(uint160(bytes20(ret)));
        assertEq(deployed, predicted, "deployed at the predicted address");
        assertEq(QpullTaxHook(deployed).GATE_DURATION(), 15 minutes, "and it is the short-clock subclass");
    }
}
