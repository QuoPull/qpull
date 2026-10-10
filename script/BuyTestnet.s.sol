// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// v4-core test router (vendored) — does unlock/swap/settle for us
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

/// @notice BUY / SNIPE (testnet, HELPER 2/3): buy QPULL on the curve with WETH. This ONE script is both the
///         real buy AND the snipe test — the outcome depends on WHO signs it:
///           * run from your DEPLOYER (NFT holder) wallet  -> succeeds; 4% tax to Treasury; tickets mint to you.
///           * run from your FRIEND (no NFT) wallet         -> reverts `Gated` (inside the holder gate window).
///         After the window the gate opens and anyone can buy. The window is the hook's GATE_DURATION(): 15 minutes
///         on the testnet subclass DeployTestnet builds, 1 hour on the mainnet hook (both measured from pool creation).
///
/// @dev    Run as the buyer: `forge script script/BuyTestnet.s.sol --rpc-url $RPC --account <buyer> --broadcast`
///         Env (from DeployTestnet output): POOL_MANAGER, QPULL_TOKEN, WETH, HOOK (+ POOL_FEE, POOL_TICK_SPACING).
///         BUY_ETH (default 0.01e18) = how much WETH to spend.
contract BuyTestnet is Script {
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    function run() external {
        // A testnet helper. On mainnet this would swap with no price limit (a sandwich target).
        require(block.chainid != 4663, "BuyTestnet is testnet-only (no price limit); never run it on mainnet (4663)");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address qpull = vm.envAddress("QPULL_TOKEN");
        address weth = vm.envAddress("WETH");
        address hook = vm.envAddress("HOOK");
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60))));
        uint256 buyEth = vm.envOr("BUY_ETH", uint256(0.01 ether));

        (address c0, address c1) = weth < qpull ? (weth, qpull) : (qpull, weth);
        bool zeroForOne = c0 == weth; // WETH in, QPULL out => a BUY

        vm.startBroadcast();
        PoolSwapTest router = new PoolSwapTest(IV4PoolManager(poolManager));
        IWETHDeposit(weth).deposit{ value: buyEth }(); // wrap testnet ETH -> mock WETH
        IERC20(weth).approve(address(router), type(uint256).max);
        router.swap(
            V4PoolKey(V4Currency.wrap(c0), V4Currency.wrap(c1), fee, tickSpacing, IV4Hooks(hook)),
            IV4PoolManager.SwapParams(
                zeroForOne, -int256(buyEth), zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopBroadcast();

        console2.log("BUY submitted. WETH spent (wei):", buyEth);
        console2.log("- If this REVERTED with Gated: the holder-gate snipe-block worked (non-holder, gate window open).");
        console2.log("- If it SUCCEEDED: 4% went to the Treasury, and QPULL + tickets minted to the signer.");
        console2.log("  (check tickets: packRegistry.liveCount / your pack balance on the explorer)");
    }
}
