#!/usr/bin/env node
/*
 * QuoPull allowlist builder
 * -------------------------
 * Turns your eligibility inputs into the two things the mint needs:
 *   1. a merkle ROOT you put on-chain with setAllowlistRoot(root), and
 *   2. web/allowlist.json  -> per-wallet proofs the site serves to allowlistMint / delegatedAllowlistMint.
 *      With "target": "pods" in the config, the same tree feeds the QuoPods sale: the root goes into the pods
 *      deploy config (allowlistRoot), the file is web/pods-allowlist.json. Same leaf, same pair hash.
 *
 * Inputs (you supply these; the tool just transforms them) come from a config file:
 *   - wallets:      specific addresses you curate by hand.
 *   - walletsFiles: text/csv/json files of addresses (one per line, or first CSV column, or a JSON array).
 *   - collections:  gated projects. Either point at a holdersFile you exported, OR let the tool
 *                   snapshot current holders on-chain by replaying Transfer logs.
 *
 * LEAF ENCODING must match the contract exactly: leaf = keccak256(abi.encodePacked(address)),
 * pair hash = OpenZeppelin commutative keccak256 (sort the two 32-byte nodes, then hash the concat).
 * A lone node at an odd layer is carried up unchanged (merkletreejs sortPairs convention). Every
 * generated proof is re-walked against the root before writing, so a file that is written is a file
 * that verifies on-chain.
 *
 * Usage:
 *   node tools/build-allowlist.js [config.json] [--dry-run] [--out path]
 *   (defaults to tools/allowlist.config.json)
 */
"use strict";

const fs = require("fs");
const path = require("path");

// ---- resolve ethers: prefer a local install, fall back to the keeper's copy ----
let ethers;
try { ethers = require("ethers"); }
catch (_) {
  try { ethers = require(path.join(__dirname, "..", "keeper", "node_modules", "ethers")); }
  catch (e) {
    console.error("Could not load ethers. Run `npm i ethers` in tools/, or keep keeper/node_modules in place.");
    process.exit(1);
  }
}
const { getAddress, isAddress, solidityPackedKeccak256, keccak256, concat, JsonRpcProvider, id } = ethers;

// ---- merkle primitives (must mirror OpenZeppelin MerkleProof) ----
// leaf = keccak256(abi.encodePacked(address))
function leafOf(addr) { return solidityPackedKeccak256(["address"], [getAddress(addr)]); }
// commutative pair hash: keccak256(min(a,b) ++ max(a,b))
function hashPair(a, b) {
  const [lo, hi] = a.toLowerCase() <= b.toLowerCase() ? [a, b] : [b, a];
  return keccak256(concat([lo, hi]));
}
function buildLayers(leaves) {
  let layer = leaves.slice();
  const layers = [layer];
  while (layer.length > 1) {
    const next = [];
    for (let i = 0; i < layer.length; i += 2) {
      if (i + 1 === layer.length) next.push(layer[i]);     // odd node -> carry up
      else next.push(hashPair(layer[i], layer[i + 1]));
    }
    layer = next;
    layers.push(layer);
  }
  return layers;
}
function proofFor(layers, index) {
  const proof = [];
  let idx = index;
  for (let l = 0; l < layers.length - 1; l++) {
    const layer = layers[l];
    const sib = idx ^ 1;
    if (sib < layer.length) proof.push(layer[sib]);        // no sibling => this node was carried
    idx = idx >> 1;
  }
  return proof;
}
// the exact on-chain check: walk the proof commutatively and compare to root
function processProof(leaf, proof) {
  return proof.reduce((h, p) => hashPair(h, p), leaf);
}

// ---- address ingestion helpers ----
function normalize(list, bag, label) {
  let ok = 0, bad = 0;
  for (const raw of list) {
    const a = String(raw || "").trim();
    if (!a) continue;
    if (!isAddress(a)) { bad++; continue; }
    bag.add(getAddress(a).toLowerCase());
    ok++;
  }
  if (label) console.log(`  ${label}: ${ok} valid${bad ? `, ${bad} skipped (not an address)` : ""}`);
  return { ok, bad };
}
function readAddressFile(file) {
  const text = fs.readFileSync(file, "utf8");
  const trimmed = text.trim();
  if (trimmed.startsWith("[") || trimmed.startsWith("{")) {
    const j = JSON.parse(trimmed);
    if (Array.isArray(j)) return j.map(x => (typeof x === "string" ? x : (x && (x.address || x.owner || x.wallet)) || ""));
    if (Array.isArray(j.addresses)) return j.addresses;
    if (j.proofs) return Object.keys(j.proofs);
    return Object.keys(j);
  }
  // text / csv: the FIRST address-shaped token on each line. Handles a leading rank/index column,
  // extra columns, and a header row (no address -> skipped). A plain one-address-per-line file still works.
  const ADDR = /^0x[0-9a-fA-F]{40}$/;
  return trimmed.split(/\r?\n/).map(line => {
    const tok = line.split(/[\s,;]+/).find(t => ADDR.test(t.trim()));
    return tok ? tok.trim() : "";
  });
}

// ---- on-chain holder snapshot via Transfer logs ----
async function snapshotHolders(col, defaultRpc) {
  const rpcUrl = col.rpc || defaultRpc;
  if (!rpcUrl) throw new Error(`collection ${col.name || col.address}: no rpc set and no chain.rpc`);
  const standard = (col.standard || "erc721").toLowerCase();
  if (standard !== "erc721" && standard !== "erc20") {
    throw new Error(`collection ${col.name || col.address}: standard "${standard}" needs a holdersFile (only erc721/erc20 scan on-chain)`);
  }
  const provider = new JsonRpcProvider(rpcUrl);
  const TRANSFER = id("Transfer(address,address,uint256)");
  const latest = col.toBlock === "latest" || col.toBlock == null ? await provider.getBlockNumber() : Number(col.toBlock);
  const from = Number(col.fromBlock || 0);
  const chunk = Number(col.chunk || 5000);
  const minBal = BigInt(col.minBalance == null ? 1 : col.minBalance);
  const ZERO = "0x0000000000000000000000000000000000000000";

  console.log(`  snapshotting ${col.name || col.address} (${standard}) blocks ${from}..${latest} on ${rpcUrl}`);

  const owners = new Map();  // erc721: tokenId -> owner
  const bal = new Map();     // erc20:  owner  -> bigint balance
  let scanned = 0, gaps = 0;

  for (let start = from; start <= latest; start += chunk) {
    const end = Math.min(start + chunk - 1, latest);
    let logs;
    try {
      logs = await provider.getLogs({ address: getAddress(col.address), topics: [TRANSFER], fromBlock: start, toBlock: end });
    } catch (e) {
      // RPC range limit or pruned history: shrink once, then skip the window with a warning
      try {
        const mid = Math.floor((start + end) / 2);
        const a = await provider.getLogs({ address: getAddress(col.address), topics: [TRANSFER], fromBlock: start, toBlock: mid });
        const b = await provider.getLogs({ address: getAddress(col.address), topics: [TRANSFER], fromBlock: mid + 1, toBlock: end });
        logs = a.concat(b);
      } catch (e2) {
        gaps++;
        console.warn(`    ! blocks ${start}..${end} unavailable (${(e2.shortMessage || e2.message || "").slice(0, 60)}); skipped`);
        continue;
      }
    }
    for (const lg of logs) {
      const t = lg.topics;
      if (standard === "erc721") {
        if (t.length < 4) continue; // erc20 Transfer (value in data) sneaking in; ignore
        const to = getAddress("0x" + t[2].slice(26));
        const tokenId = t[3];
        owners.set(tokenId, to);
      } else { // erc20
        const fromA = getAddress("0x" + t[1].slice(26));
        const toA = getAddress("0x" + t[2].slice(26));
        const val = BigInt(lg.data === "0x" ? 0 : lg.data);
        if (fromA !== ZERO) bal.set(fromA, (bal.get(fromA) || 0n) - val);
        if (toA !== ZERO) bal.set(toA, (bal.get(toA) || 0n) + val);
      }
    }
    scanned++;
  }

  const holders = new Set();
  if (standard === "erc721") {
    const counts = new Map();
    for (const owner of owners.values()) {
      if (owner === ZERO) continue;
      counts.set(owner, (counts.get(owner) || 0n) + 1n);
    }
    for (const [owner, c] of counts) if (c >= minBal) holders.add(owner.toLowerCase());
  } else {
    for (const [owner, b] of bal) if (b >= minBal && b > 0n) holders.add(owner.toLowerCase());
  }
  console.log(`    -> ${holders.size} holders (minBalance ${minBal})${gaps ? `, ${gaps} block window(s) skipped` : ""}`);
  if (gaps) console.warn(`    ! history was incomplete on this RPC. For a full snapshot use an archival RPC or a holdersFile.`);
  return holders;
}

// ---- holder snapshot by reading current owners (ownerOf over the id range) ----
// The right method for a non-enumerable ERC721 on a pruning RPC: reads LIVE state, so no log
// history is needed. Sparse / burned ids just revert and are skipped.
async function snapshotHoldersOwnerOf(col, defaultRpc) {
  const rpcUrl = col.rpc || defaultRpc;
  if (!rpcUrl) throw new Error(`collection ${col.name || col.address}: no rpc set and no chain.rpc`);
  const provider = new JsonRpcProvider(rpcUrl);
  const c = new ethers.Contract(getAddress(col.address), ["function ownerOf(uint256) view returns (address)"], provider);
  const idStart = Number(col.idStart == null ? 1 : col.idStart);
  const idEnd = Number(col.idEnd == null ? 10000 : col.idEnd);
  const conc = Number(col.concurrency || 40);
  const minBal = BigInt(col.minBalance == null ? 1 : col.minBalance);
  const block = await provider.getBlockNumber();

  console.log(`  reading owners of ${col.name || col.address} via ownerOf, ids ${idStart}..${idEnd} @ block ${block}`);
  const counts = new Map();
  let hits = 0, gaps = 0, id = idStart;
  async function worker() {
    while (id <= idEnd) {
      const cur = id++;
      try { const o = (await c.ownerOf(cur)).toLowerCase(); counts.set(o, (counts.get(o) || 0n) + 1n); hits++; }
      catch (_) { gaps++; }
    }
  }
  await Promise.all(Array.from({ length: conc }, () => worker()));

  // rank by balance so an optional topHolders cut keeps the largest holders
  let ranked = [...counts.entries()].filter(([, c]) => c >= minBal).sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : (a[0] < b[0] ? -1 : 1)));
  const topN = col.topHolders == null ? null : Number(col.topHolders);
  if (topN != null && ranked.length > topN) {
    const cutoff = ranked[topN - 1][1];
    if (col.tiesInclusive) {
      // keep everyone whose balance >= the Nth-place balance, so no tied wallet is dropped on address order
      const before = ranked.length;
      ranked = ranked.filter(([, c]) => c >= cutoff);
      const extra = ranked.length - topN;
      console.log(`    top ${topN} + ties: kept ${ranked.length} (cutoff ${cutoff} token(s); ${extra} extra wallet(s) tied at the cutoff, none dropped)`);
    } else {
      const tieAtCut = ranked[topN] && ranked[topN][1] === cutoff;
      ranked = ranked.slice(0, topN);
      console.log(`    top ${topN} holders kept; #${topN} holds ${cutoff} token(s)${tieAtCut ? " (NOTE: wallets tied at the cutoff were dropped to hold exactly " + topN + ")" : ""}`);
    }
  }
  const holders = new Set(ranked.map(([o]) => o));
  console.log(`    -> ${hits} tokens, ${counts.size} holders with >= ${minBal}${topN != null ? `, kept ${holders.size}` : ""} (${gaps} ids empty/burned)`);
  if (hits > 0 && id > idEnd) {
    // warn if the top of the range was still minting (idEnd may be too low)
    // (cheap heuristic: caller should widen idEnd if the collection is larger)
  }
  return { holders, block };
}

// ---- main ----
(async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const outIdx = args.indexOf("--out");
  const outOverride = outIdx >= 0 ? args[outIdx + 1] : null;
  const cfgPath = path.resolve(args.find(a => !a.startsWith("--") && a !== outOverride) || path.join(__dirname, "allowlist.config.json"));

  if (!fs.existsSync(cfgPath)) {
    console.error(`Config not found: ${cfgPath}\nCopy tools/allowlist.config.json and fill in your wallets / collections.`);
    process.exit(1);
  }
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  const cfgDir = path.dirname(cfgPath);
  const rel = p => path.isAbsolute(p) ? p : path.resolve(cfgDir, p);
  const defaultRpc = cfg.chain && cfg.chain.rpc;

  console.log(`QuoPull allowlist builder`);
  console.log(`config: ${cfgPath}`);
  const bag = new Set();

  // 1. explicit wallets
  if (Array.isArray(cfg.wallets) && cfg.wallets.length) {
    console.log(`wallets (inline):`);
    normalize(cfg.wallets, bag, "inline");
  }
  // 2. wallet files
  for (const f of (cfg.walletsFiles || [])) {
    console.log(`wallets file: ${f}`);
    normalize(readAddressFile(rel(f)), bag, path.basename(f));
  }
  // 3. collections
  const snapshotBlocks = {};
  for (const col of (cfg.collections || [])) {
    console.log(`collection: ${col.name || col.address}`);
    const std = (col.standard || "erc721").toLowerCase();
    if (col.holdersFile) {
      normalize(readAddressFile(rel(col.holdersFile)), bag, `holdersFile ${path.basename(col.holdersFile)}`);
    } else if (std === "erc721-ownerof") {
      const { holders, block } = await snapshotHoldersOwnerOf(col, defaultRpc);
      snapshotBlocks[col.name || col.address] = block;
      normalize([...holders], bag, "snapshot");
    } else {
      const holders = await snapshotHolders(col, defaultRpc);
      normalize([...holders], bag, "snapshot");
    }
  }
  // 4. excludes
  if (Array.isArray(cfg.exclude) && cfg.exclude.length) {
    let removed = 0;
    for (const e of cfg.exclude) { if (isAddress(e) && bag.delete(getAddress(e).toLowerCase())) removed++; }
    console.log(`excluded: ${removed}`);
  }

  const addresses = [...bag].sort();
  if (addresses.length === 0) {
    console.error("\nNo eligible addresses. Fill in wallets / walletsFiles / collections in the config.");
    process.exit(1);
  }

  // 5. build the tree
  const leaves = addresses.map(leafOf);
  const layers = buildLayers(leaves);
  const root = layers[layers.length - 1][0];

  // 6. proofs + self-verify EVERY leaf against the root (this is the on-chain check, mirrored)
  const proofs = {};
  let failures = 0;
  for (let i = 0; i < addresses.length; i++) {
    const p = proofFor(layers, i);
    if (processProof(leaves[i], p) !== root) failures++;
    proofs[addresses[i]] = p;
  }
  if (failures) {
    console.error(`\nABORT: ${failures}/${addresses.length} proofs did not reproduce the root. Not writing.`);
    process.exit(1);
  }

  const out = {
    root,
    count: addresses.length,
    leafEncoding: "keccak256(abi.encodePacked(address))",
    generatedAt: new Date().toISOString(),
    snapshotBlocks: Object.keys(snapshotBlocks).length ? snapshotBlocks : undefined,
    proofs
  };

  console.log(`\n----------------------------------------------------------------`);
  console.log(`eligible wallets : ${addresses.length}`);
  console.log(`self-check       : PASS (every proof reproduces the root)`);
  console.log(`merkle root      : ${root}`);
  console.log(`----------------------------------------------------------------`);
  if (cfg.target === "pods") {
    console.log(`next: use this root as the pods mint's allowlistRoot at deploy. It is IMMUTABLE there, so the list is`);
    console.log(`      final BEFORE the deploy. Publish the file as web/pods-allowlist.json for the sale's first four hours.`);
  } else {
    console.log(`next: set this root on the NFT ->  setAllowlistRoot(${root})`);
  }

  if (dryRun) { console.log(`\n--dry-run: not writing any file.`); return; }

  const outPath = rel(outOverride || cfg.output || "../web/allowlist.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(`\nwrote ${addresses.length} proofs -> ${outPath}`);
})().catch(e => { console.error("\nBuild failed:", e.message); process.exit(1); });
