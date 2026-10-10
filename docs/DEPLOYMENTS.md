# Deployments

QuoPull runs on **Robinhood Chain mainnet, chain id 4663**. Explorer: <https://robinhoodchain.blockscout.com>.

## How these addresses were checked

Each address below was checked against the chain on 2026-10-10:

1. it has contract code on chain 4663;
2. its runtime bytecode matches a build of this repository (`forge build`: solc 0.8.26, `via_ir`, optimizer 200 runs,
   `evm_version = "prague"`, `bytecode_hash = "none"`), with the constructor immutables masked out;
3. the immutable wiring read from the contracts (for example `QpullTaxHook.treasury()`, `RaffleEngine.vault()`,
   `NFTCollection.renderer()`) points at the other addresses in this file.

Owner, keeper and other wallet addresses are intentionally not listed here.

## Token, pool and treasury

Deployed by `script/Deploy.s.sol` on 2026-09-21 (blocks 68995558 to 68995907).

| Contract | Address | Source |
|---|---|---|
| QPULL token | [`0x648bF8A42D4546FDB9c840cB6eD78379e80bb0Dd`](https://robinhoodchain.blockscout.com/address/0x648bF8A42D4546FDB9c840cB6eD78379e80bb0Dd) | `src/QPULLToken.sol` |
| Tax hook (Uniswap v4 hook on the QPULL/WETH pool) | [`0x3536e961b166254e678ddF9f602cbc94D9009Acc`](https://robinhoodchain.blockscout.com/address/0x3536e961b166254e678ddF9f602cbc94D9009Acc) | `src/hooks/QpullTaxHook.sol` |
| Liquidity lock (permanent, no remove path) | [`0x44B61a265B4097460326e2B6F54575Aa3f36c668`](https://robinhoodchain.blockscout.com/address/0x44B61a265B4097460326e2B6F54575Aa3f36c668) | `src/QpullLiquidityLock.sol` |
| Swap router (the site's buy and sell path) | [`0xDc22999A6D351A1a352244c981297Ef98FBd5E03`](https://robinhoodchain.blockscout.com/address/0xDc22999A6D351A1a352244c981297Ef98FBd5E03) | `src/periphery/QpullSwapRouter.sol` |
| Treasury | [`0x920F5EB39614CE49A7FAD4115F2073819c0e49E8`](https://robinhoodchain.blockscout.com/address/0x920F5EB39614CE49A7FAD4115F2073819c0e49E8) | `src/Treasury.sol` |
| WETH adapter (Treasury convert, untaxed sender) | [`0x4EAa09ecD37FCd27301d74e10032b25271A04787`](https://robinhoodchain.blockscout.com/address/0x4EAa09ecD37FCd27301d74e10032b25271A04787) | `src/adapters/QpullWethAdapter.sol` |
| Quotron router adapter | [`0x3992181C787ca159A26Af47ade183Fca301D2c18`](https://robinhoodchain.blockscout.com/address/0x3992181C787ca159A26Af47ade183Fca301D2c18) | `src/adapters/QuotronRouterAdapter.sol` |

## Packs, draws and claims

Deployed by `script/Deploy.s.sol` on 2026-09-21.

| Contract | Address | Source |
|---|---|---|
| Pack registry | [`0x6f43970503692B8CC01eD555AB0495C04ABB5bD8`](https://robinhoodchain.blockscout.com/address/0x6f43970503692B8CC01eD555AB0495C04ABB5bD8) | `src/PackRegistry.sol` |
| Raffle engine (daily raffle) | [`0xD0845C29d63553c34eD65E6FAC2b92BfAEF5FCB3`](https://robinhoodchain.blockscout.com/address/0xD0845C29d63553c34eD65E6FAC2b92BfAEF5FCB3) | `src/RaffleEngine.sol` |
| Raffle vault | [`0x41E3ff80643324d73094457DB8Ab84e3c03814BC`](https://robinhoodchain.blockscout.com/address/0x41E3ff80643324d73094457DB8Ab84e3c03814BC) | `src/BaseVault.sol` |
| Leaderboard registry | [`0x1953810E50145eA88ffe3ee734f662aebF5780ec`](https://robinhoodchain.blockscout.com/address/0x1953810E50145eA88ffe3ee734f662aebF5780ec) | `src/LeaderboardRegistry.sol` |
| Leaderboard engine (weekly board) | [`0xbc2aE4e263b565b6B3E6449FcDd9A45f53C31673`](https://robinhoodchain.blockscout.com/address/0xbc2aE4e263b565b6B3E6449FcDd9A45f53C31673) | `src/LeaderboardEngine.sol` |
| Leaderboard vault | [`0x0199E675290b718fAA40F6023dA84001374346EF`](https://robinhoodchain.blockscout.com/address/0x0199E675290b718fAA40F6023dA84001374346EF) | `src/BaseVault.sol` |
| Holder draw engine (weekly holder draw) | [`0xFAdDA86eC16ceC391ee5519E7D14D51dc5A5Bc60`](https://robinhoodchain.blockscout.com/address/0xFAdDA86eC16ceC391ee5519E7D14D51dc5A5Bc60) | `src/HolderDrawEngine.sol` |
| Holder draw vault | [`0xb986d75E9cc2A91DCa4c2A67c614814498641A6D`](https://robinhoodchain.blockscout.com/address/0xb986d75E9cc2A91DCa4c2A67c614814498641A6D) | `src/BaseVault.sol` |
| Claim manager (pull-based prize claims) | [`0xC5F3098b2fd814AE7534b156b3bdba2D7fE978eC`](https://robinhoodchain.blockscout.com/address/0xC5F3098b2fd814AE7534b156b3bdba2D7fE978eC) | `src/ClaimManager.sol` |

## Art Pass and randomness

Deployed on 2026-09-17 (UTC) by `script/DeployOracle.s.sol` (block 65083901), `script/DeployPassArt.s.sol`
(block 65085275) and `script/DeployNFT.s.sol` (block 65088427).

| Contract | Address | Source |
|---|---|---|
| Art Pass collection (`QuoPull`, 3,500 passes) | [`0xE423E4565EC9196f5B3e1319Aa7175a82A00D858`](https://robinhoodchain.blockscout.com/address/0xE423E4565EC9196f5B3e1319Aa7175a82A00D858) | `src/NFTCollection.sol` |
| Onchain art renderer (`tokenURI`) | [`0x9120aFC176d7c1C203E8B436dF7618F462975dCa`](https://robinhoodchain.blockscout.com/address/0x9120aFC176d7c1C203E8B436dF7618F462975dCa) | `src/nft/PassArtRenderer.sol` |
| Drand beacon oracle (BLS12-381 verified) | [`0x9056699c00c414dAFA256CcDe8ee1756EcD23A0E`](https://robinhoodchain.blockscout.com/address/0x9056699c00c414dAFA256CcDe8ee1756EcD23A0E) | `src/oracle/BlsDrandOracle.sol` |

The renderer reads the artwork from 21 SSTORE2 data contracts written by the same `DeployPassArt` run
(`src/utils/SSTORE2.sol`). The artwork itself is all rights reserved: see `ART-LICENSE.md`.

## External contracts QuoPull uses

These are not deployed by this repository. They are listed so the wiring above can be followed.

| Contract | Address |
|---|---|
| Uniswap v4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| WETH | [`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`](https://robinhoodchain.blockscout.com/address/0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73) |
| QUOTRON (the prize token) | [`0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F`](https://robinhoodchain.blockscout.com/address/0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F) |
| QUOTRON mirror NFT | [`0x027ACa2794E44f24950D81227DcD516FfBB49d6e`](https://robinhoodchain.blockscout.com/address/0x027ACa2794E44f24950D81227DcD516FfBB49d6e) |
| Quotron router | [`0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18`](https://robinhoodchain.blockscout.com/address/0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18) |
| Quotron view quoter (used by the keeper and the vault seed script) | [`0xb8960fdC8A0Be155d196C2795b75747763562df2`](https://robinhoodchain.blockscout.com/address/0xb8960fdC8A0Be155d196C2795b75747763562df2) |
| delegate.xyz v2 registry (delegated allowlist mint) | [`0x00000000000000447e69651d841bD8D104Bed493`](https://robinhoodchain.blockscout.com/address/0x00000000000000447e69651d841bD8D104Bed493) |
| Multicall3 (batched reads on the site) | [`0xcA11bde05977b3631167028862bE2a173976CA11`](https://robinhoodchain.blockscout.com/address/0xcA11bde05977b3631167028862bE2a173976CA11) |

## Not deployed

QuoPods is a separate product and is not part of this repository or of the deployments above.
