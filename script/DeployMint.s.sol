// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { MockDrandOracle } from "../test/mocks/MockDrandOracle.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";

/// @notice PHASE 1 of the 2-phase TESTNET launch: deploy the randomness oracle + the NFT (the raise) and OPEN the
///         mint. The trading/raffle system is deployed SEPARATELY in phase 2 (DeployTestnet with
///         NFT_ADDR/ORACLE_ADDR), only AFTER the mint is closed (finalizeLaunch) — so the game clock (genesis)
///         starts at LAUNCH, not here, and the swap/pool cannot open until the mint closes (the hook enforces
///         `nft.launched()`). Run phase 2 back-to-back with go-live so genesis ≈ pool-init time.
///         TESTNET ONLY: it derives recipients from the deployer, roots the allowlist at the deployer and
///         opens the mint in the same broadcast, all of which freeze. Mainnet uses DeployNFT.s.sol.
contract DeployMint is Script {
    function run() external {
        require(block.chainid != 4663, "DeployMint is testnet-only; mainnet (4663) uses DeployNFT.s.sol");
        uint256 mintPrice = vm.envOr("MINT_PRICE_WEI", uint256(0.0075 ether)); // launch price: 0.0075 ETH
        uint256 revealDelay = vm.envOr("REVEAL_DELAY", uint256(1 hours));
        uint256 genesis = vm.envOr("GENESIS", block.timestamp); // oracle genesis (NFT rarity rounds)
        // Defaults to the settable MockDrandOracle (so the keeper can post beacons on the short clock and
        // packs/passes reveal in seconds). MOCK_ORACLE=false deploys the real quicknet BlsDrandOracle.
        bool mockOracle = vm.envOr("MOCK_ORACLE", true);
        // Fully on-chain art: deploy + chunk the renderer FIRST (script/DeployPassArt.s.sol) and pass it here.
        // No baseURI / setBaseURI any more — the reveal is on-chain via tokenURI.
        address renderer = vm.envAddress("RENDERER_ADDR");
        address me = msg.sender;

        vm.startBroadcast();
        address oracle = mockOracle
            ? address(new MockDrandOracle(genesis, 3))
            : address(new BlsDrandOracle(1_692_803_367, 3));
        NFTCollection nft = new NFTCollection(mintPrice, oracle, revealDelay, renderer, me);
        // 3 distinct (setRecipients requires it). Env-overridable so a dress rehearsal can exercise the REAL decision. These three freeze
        // PERMANENTLY at the first mint (setRecipients guards on `mintStart != 0 || totalMinted > 0`)
        // and `withdrawProceeds` is permissionless and pays exactly them forever, through the only ETH
        // exits in the contract -- no rescue, no sweep, no owner override. Leaving them hardcoded meant
        // the rehearsal skipped the one launch input that cannot be corrected. Defaults preserve the old
        // deployer-derived behaviour, so an unset env changes nothing. setRecipients also probes that
        // each destination can actually receive ETH.
        nft.setRecipients(
            vm.envOr("LP_TREASURY", me),
            vm.envOr("SEED_TREASURY", address(uint160(me) + 1)),
            vm.envOr("TEAM_WALLET", address(uint160(me) + 2))
        );
        nft.setMintOpen(true); // kill switch on (pass-9: orthogonal to the phase — a mint needs both)
        // pass-11: START the tiered mint (real-time windows: GTD 4h / overflow 4h / public 48h). Single-leaf
        // allowlist root = the deployer, so it mints in GTD/overflow with an empty proof; public opens at
        // start + 8h automatically. For the SHORT-clock testnet flow use DeployTestnet (NFTCollectionTestnet).
        nft.setAllowlistRoot(keccak256(abi.encodePacked(me)));
        nft.openAllowlistMint();
        vm.stopBroadcast();

        console2.log("PHASE 1 (mint) deployed. Mint is OPEN. When ready to launch: finalizeLaunch() then phase 2.");
        console2.log("  NFT   ", address(nft));
        console2.log("  Oracle", oracle);
        console2.log("  Public mint auto-closes at (unix)", nft.publicMintClosesAt());
        console2.log("  After that: ALL minting reverts and finalizeLaunch() is permissionless.");
        console2.log(string.concat("export NFT_ADDR=", vm.toString(address(nft))));
        console2.log(string.concat("export ORACLE_ADDR=", vm.toString(oracle)));
    }
}
