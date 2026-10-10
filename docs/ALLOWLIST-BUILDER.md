# Allowlist builder

Turns your eligibility inputs into the two things the mint needs:

1. a merkle **root** you put onchain with `setAllowlistRoot(root)`, and
2. `web/allowlist.json`, the per-wallet **proofs** the site serves to `allowlistMint` and `delegatedAllowlistMint`.

The tool is just the transform. You supply the addresses.

## Run it

```bash
node tools/build-allowlist.js                 # uses tools/allowlist.config.json, writes web/allowlist.json
node tools/build-allowlist.js --dry-run       # print the root + count, write nothing
node tools/build-allowlist.js my.config.json  # a different config
node tools/build-allowlist.js --out /tmp/x.json
```

## Inputs (in `tools/allowlist.config.json`)

- **`wallets`**: addresses you curate by hand.
- **`walletsFiles`**: text / csv / json address lists (one address per line, or the first CSV column, or a JSON array). Paths are relative to the config file.
- **`collections`**: gated projects. For each, either:
  - **`holdersFile`**: an address list you exported (from Alchemy, Reservoir, OpenSea, Dune, the project's own snapshot). Simplest and works for any chain, or
  - an **onchain snapshot**: set `address`, `standard` (`erc721` or `erc20`), `minBalance`, optional `rpc` (defaults to `chain.rpc`), `fromBlock`, `toBlock`, `chunk`. The tool replays `Transfer` logs to compute current holders.
- **`exclude`**: addresses to drop (burn address, team, etc.).
- **`output`**: where to write (default `../web/allowlist.json`).

See `tools/allowlist.config.example.json` for every field.

## Onchain snapshot caveat

Replaying logs needs an RPC that still serves that history. Robinhood Chain's public RPC prunes old blocks, so a from-genesis scan there will report skipped windows. For a full snapshot use an **archival RPC**, or just export a **`holdersFile`**. If the gated project lives on another chain (most do), point that collection's `rpc` at that chain and set `fromBlock` to its deploy block.

## Correctness

Leaf = `keccak256(abi.encodePacked(address))`, commutative sorted-pair hashing, matching the contract's OpenZeppelin `MerkleProof` check exactly. The builder re-walks every generated proof against the root before writing (a written file is a verified file), and `test/AllowlistMerkle.t.sol` cross-checks a fixture against the real onchain library.

## After building

1. Copy the printed **merkle root**.
2. Set it on the NFT: `setAllowlistRoot(<root>)` (owner only).
3. Deploy `web/allowlist.json` with the site. Proofs are public, not secrets.
4. A wallet not in the file is simply "not eligible", never an error.
