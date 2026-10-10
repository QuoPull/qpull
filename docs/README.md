# Documentation

Start with the walkthrough. The contract source is always authoritative; these documents explain why it is shaped
the way it is.

| Document | What it covers |
|---|---|
| [PROTOCOL-WALKTHROUGH.md](PROTOCOL-WALKTHROUGH.md) | The whole protocol in plain language, end to end: what a player does, what happens onchain, and every number that matters. |
| [DESIGN-SPEC.md](DESIGN-SPEC.md) | The original design specification, revised to match what was built. Code comments that say "spec §N" point here. |
| [DEPLOYMENTS.md](DEPLOYMENTS.md) | Every mainnet contract address on Robinhood Chain (4663), and how they were checked against this source. |
| [LIQUIDITY-LOCK-SPEC.md](LIQUIDITY-LOCK-SPEC.md) | The liquidity lock: why the pool's liquidity can never be removed, and how the pool was created and seeded in one transaction. |
| [PLEDGE-ENTRY-SPEC.md](PLEDGE-ENTRY-SPEC.md) | How Art Passes enter the daily draw for free: Super Rares automatically, other tiers by a daily pledge. |
| [MAINNET-POT-SIZING.md](MAINNET-POT-SIZING.md) | How the minimum pot and pot cap of each game were sized against the live QUOTRON price. |
| [GAS-CEILING-TEST.md](GAS-CEILING-TEST.md) | A testnet plan for observing the chain's per-transaction gas clamp in a mined block. |
| [ALLOWLIST-BUILDER.md](ALLOWLIST-BUILDER.md) | The tool that turns eligibility inputs into a merkle root and per-wallet proofs. |

Images used by the main README are in [`assets/`](assets). The QuoPull art, logo and social images are all rights
reserved; see [`../ART-LICENSE.md`](../ART-LICENSE.md).
