// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { QpullV4Quoter } from "../src/periphery/QpullV4Quoter.sol";
import { IPoolManager } from "../src/interfaces/IPoolManager.sol";

/// @notice Deploy the OPTIONAL v4 quoter the keeper can use to guard `Treasury.convert()`'s QPULL->WETH leg (leg 1), and
///         print the `QPULL_QUOTER` line to paste into `keeper/.env`.
///
/// @dev    OFF THE LAUNCH CRITICAL PATH. The tax arrives as WETH on buys and sells, so the normal
///         convert is a WETH-only sweep that needs only `VIEW_QUOTER` (Quotron's View quoter, REQUIRED: with the
///         keeper's default spot guard and CONVERT_SPOT_UNAVAILABLE=hold, an unset VIEW_QUOTER holds every convert).
///         Leg 1 only ever sells QPULL someone DONATED to the Treasury. Without `QPULL_QUOTER` that leg's floor comes
///         from bisection, unguarded; with it, that leg is guarded (keeper/.env.example and keeper/README.md).
///         If used, run it AFTER GoLiveMainnet.s.sol has created the pool: a quote is meaningless until the pool
///         exists; the deploy itself has no dependency beyond the PoolManager address.
///
///         WHY IT IS A SEPARATE SCRIPT rather than part of the launch. `QPULL_QUOTER` is keeper
///         configuration, not protocol: nothing on-chain references this address, no contract is bound to
///         it, and redeploying it later changes nothing except a line in an env file. Folding it into
///         GoLiveMainnet would put a non-protocol deploy inside the one irreversible script.
///
///         WHY IT EXISTS AT ALL: there is no canonical Uniswap v4 Quoter on Robinhood Chain, Quotron's View
///         quoter is a different interface priced for their pool, and this repo vendors only `v4-core`.
///
///         Env: POOL_MANAGER (RH mainnet 0x8366a39CC670B4001A1121B8F6A443A643e40951).
contract DeployQuoter is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        require(poolManager.code.length > 0, "deploy-quoter: POOL_MANAGER has no code -- wrong chain or typo");

        vm.startBroadcast();
        QpullV4Quoter quoter = new QpullV4Quoter(IPoolManager(poolManager));
        vm.stopBroadcast();

        require(address(quoter.poolManager()) == poolManager, "deploy-quoter: binding mismatch");

        console2.log("");
        console2.log("QpullV4Quoter deployed:", address(quoter));
        console2.log("  bound PoolManager:   ", poolManager);
        console2.log("");
        console2.log("Paste into keeper/.env:");
        console2.log("  QPULL_QUOTER=%s", address(quoter));
        console2.log("");
        console2.log("It is OPTIONAL: it guards only convert leg 1 (donated QPULL). VIEW_QUOTER stays REQUIRED.");
        console2.log("Dry run (never sends): run the keeper loop with ENABLE_CONVERT=simulate until the log shows");
        console2.log("'simulation SUCCEEDS; spot guard clear'; only then set ENABLE_CONVERT=true (--once never sends).");
        console2.log("A quote of 0, or a leg-1 HOLD naming the pool binding, means the key is wrong: the keeper reads");
        console2.log("the pool key from the chain (QPULL_POOL_* in keeper/.env are optional assertions; leave them unset).");
    }
}
