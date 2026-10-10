/*
 * Turnkey real-beacon prep for a raffle draw (MOCK_ORACLE=false testnet pass, or mainnet).
 *
 * READ-ONLY on-chain (ethers, no key): works out EVERY drand round the draw for `day` needs — the
 * reveal round of each live cohort in the window (so tierOf() resolves) PLUS the draw round (winner
 * selection) — reading the rounds straight from the contracts (engine.drawRound / oracle.roundAt), so
 * there is no round math to get wrong. It fetches each beacon from drand quicknet, skips any already
 * on-chain, and prints ready `cast send` commands. Signing stays in cast + your keystore — no key here.
 *
 * A beacon that isn't published yet (you're too early in the draw window) is reported, not fetched:
 * the draw's reveal round only publishes ~REVEAL_LAG (1h) into the draw window. Wait, then re-run.
 *
 * Usage:
 *   RPC=$RPC ORACLE=$ORACLE RAFFLE_ENGINE=$RAFFLE_ENGINE PACK_REGISTRY=$PACK_REGISTRY \
 *     node keeper/prep-draw.js <day>
 */
import { ethers } from "ethers";
import { beaconSubmitData } from "./beacon.js";

const DAY = 86400n; // matches PackRegistry/RaffleEngine DAY (1 days)
const LIFE_DAYS = 7n; // ticket lifetime in daily draws (PackRegistry.LIFE_DAYS)

const dayArg = process.argv[2];
if (!dayArg || !/^\d+$/.test(dayArg)) {
  console.error("usage: RPC=.. ORACLE=.. RAFFLE_ENGINE=.. PACK_REGISTRY=.. node keeper/prep-draw.js <day>");
  process.exit(1);
}
const D = BigInt(dayArg);

const { RPC, ORACLE, RAFFLE_ENGINE, PACK_REGISTRY } = process.env;
const account = process.env.KEEPER_ACCOUNT || "deployer";
for (const [k, v] of Object.entries({ RPC, ORACLE, RAFFLE_ENGINE, PACK_REGISTRY })) {
  if (!v) { console.error(`missing env ${k}`); process.exit(1); }
}

const provider = new ethers.JsonRpcProvider(RPC);
const engine = new ethers.Contract(RAFFLE_ENGINE, ["function drawRound(uint32) view returns (uint64)"], provider);
const packs = new ethers.Contract(PACK_REGISTRY, [
  "function genesis() view returns (uint256)",
  "function revealDelay() view returns (uint256)",
  "function cohortSize(uint32) view returns (uint256)",
], provider);
const oracle = new ethers.Contract(ORACLE, [
  "function roundAt(uint256) view returns (uint64)",
  "function isAvailable(uint64) view returns (bool)",
], provider);

const genesis = await packs.genesis();
const revealDelay = await packs.revealDelay();

// Rounds this draw depends on, deduped: reveal round of every LIVE cohort in [max(0,day-7) .. day-1],
// plus the draw round. Cohorts with no live tickets can't win, so their reveal beacon isn't needed.
const rounds = new Map(); // round(string) -> label
const from = D > LIFE_DAYS ? D - LIFE_DAYS : 0n;
for (let C = from; C <= D - 1n; C++) {
  const size = await packs.cohortSize(Number(C));
  if (size === 0n) continue;
  const ts = genesis + (C + 1n) * DAY + revealDelay; // == PackRegistry._mintPacks reveal timestamp
  const rr = await oracle.roundAt(ts); // authoritative: the contract computes the round
  rounds.set(rr.toString(), `reveal · cohort ${C} (${size} live)`);
}
const dr = await engine.drawRound(Number(D));
rounds.set(dr.toString(), `draw · day ${D}`);

console.log(`Draw for day ${dayArg} depends on ${rounds.size} drand round(s):\n`);
let pending = 0;
for (const [r, label] of rounds) {
  if (await oracle.isAvailable(r)) { console.log(`# round ${r} — ${label}: already on-chain ✓`); continue; }
  let sig, comp;
  try {
    ({ sig, comp } = await beaconSubmitData(Number(r)));
  } catch (e) {
    pending++;
    console.log(`# round ${r} — ${label}: NOT PUBLISHED YET (${e.message})`);
    console.log(`#   -> the beacon publishes ~1h into the draw window; wait, then re-run this.\n`);
    continue;
  }
  console.log(`# round ${r} — ${label}`);
  console.log(`cast send ${ORACLE} "submitBeacon(uint64,bytes,bytes)" ${r} ${sig} ${comp} --rpc-url ${RPC} --account ${account}\n`);
}

if (pending) {
  console.log(`# ${pending} beacon(s) not yet published — submit the ready ones, then re-run for the rest.`);
} else {
  console.log(`# all beacons ready. After submitting them, run the draw:`);
  console.log(`cast send ${RAFFLE_ENGINE} "runDraw(uint32)" ${dayArg} --rpc-url ${RPC} --account ${account}`);
}
