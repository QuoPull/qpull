/*
 * Single-round beacon submitter (real drand path, MOCK_ORACLE=false).
 *
 * Fetches drand quicknet round <round>, decompresses it to the EIP-2537 128-byte G1 encoding, and
 * prints a ready `cast send` for BlsDrandOracle.submitBeacon(round, sig, comp). Signing stays in cast +
 * your keystore account — this script NEVER sees a private key.
 *
 * Usage:
 *   ORACLE=0x.. RPC=$RPC node keeper/submit-beacon.js <round>
 *   node keeper/submit-beacon.js <round> <oracleAddr>
 */
import { beaconSubmitData } from "./beacon.js";

const round = process.argv[2];
const oracle = process.argv[3] || process.env.ORACLE || "$ORACLE";
const rpc = process.env.RPC || "$RPC";
const account = process.env.KEEPER_ACCOUNT || "deployer";

if (!round || !/^\d+$/.test(round)) {
  console.error("usage: node keeper/submit-beacon.js <round> [oracleAddr]");
  process.exit(1);
}

const { sig, comp } = await beaconSubmitData(Number(round));
console.log(`round: ${round}`);
console.log(`sig  : ${sig}`);
console.log(`comp : ${comp}\n`);
console.log("# submit it (uses your keystore account — no key in this script):");
console.log(`cast send ${oracle} "submitBeacon(uint64,bytes,bytes)" ${round} ${sig} ${comp} --rpc-url ${rpc} --account ${account}`);
