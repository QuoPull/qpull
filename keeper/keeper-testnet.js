#!/usr/bin/env node
/*
 * QPULL TESTNET keeper, MockDrandOracle edition (short-clock RH testnet). This is a
 * testnet crutch that fakes what real drand + a mainnet keeper do for free. Never for mainnet.
 *
 * On mainnet, drand publishes the random beacons itself and only the *draws* need triggering. On this
 * testnet we run a MockDrandOracle whose beacons must be POSTED (setBeacon), so the keeper fakes drand
 * by posting the exact rounds the contracts ask for — pack reveal rounds (so tierOf resolves) and the
 * draw rounds for each game. REVEAL beacons (pack cohorts and the NFT rarity reveal) wait for the round's
 * scheduled time (oracle gen + (round-1) x per), exactly as real drand does, even though the mock would accept
 * a future round: so packs get their real "sealed -> reveals" moment and a cohort never reveals while its buy
 * day is still open. That time is compared with the CHAIN's clock (the pending block's timestamp where the
 * node serves one, else the latest block's), not the host clock: the contracts judge the buy day by block time, and a
 * local chain can run minutes behind the wall clock. DRAW-round beacons are still posted as soon as the draw is due,
 * since the mock serves any round on demand; that only shortens the REVEAL_LAG wait before a draw can run.
 *
 * GUARD RAILS. This file REFUSES Robinhood mainnet (chainId 4663): run keeper.js there. It sends
 * Treasury.convert() only with TREASURY set AND ENABLE_CONVERT=true, and its convert floor search reads reverts with
 * keeper.js's classification (reverts.js): only a known slippage revert means "floor too high"; any other failure,
 * including an RPC error, stops the search and nothing is sent that tick.
 *
 * DRAW_MODE (env):
 *   manual (DEFAULT) — keeper posts beacons and PRINTS
 *                      a ready `cast send` for every draw that's callable right now. YOU run the draws +
 *                      do the UI actions (buy / rip / claim). This is the "get the feel" mode.
 *   auto            — keeper also sends the draws / distribute itself. Hands-off, mainnet-like runtime.
 *                      You still do buy / rip / claim in the UI.
 *
 * SAFE BY DESIGN: every send is staticCall-simulated first; anything not callable this tick (wrong
 * window, already drawn) is skipped silently. A call that simulated cleanly and then reverts while its transaction
 * is built (a draw window that closed in between) is logged once by its decoded error name. A sent
 * transaction is waited on for at most SEND_WAIT_TIMEOUT_MS; one that times out is remembered, and its job does not send
 * again while it is still pending (keeper.js TIMED-OUT SENDS). A transaction replaced at its nonce by another sender on
 * the same key is logged as REPLACED, not as reverted. Void-on-miss: a missed run just rolls
 * the pot forward, never a loss — so this bot need not be bulletproof.
 *
 * Run:  node keeper-testnet.js            (loop every INTERVAL_SECONDS)
 *       node keeper-testnet.js --once     (single pass)
 *       DRAW_MODE=auto node keeper-testnet.js
 *
 * Loading this file runs the keeper, except with KEEPER_IMPORT_ONLY=1 set in the process environment before the import
 * (offline tests only, as in keeper.js): then it loads no .env, builds no signer, never starts main(), and says so on
 * stderr.
 */
import { ethers } from "ethers";
import { beaconSubmitData } from "./beacon.js";
import { classifyConvertRevert, describeRevert, isRevertError, revertReason } from "./reverts.js";

// Same switch as keeper.js. dotenv/config is imported dynamically so the import-only mode never reads a .env; for a real
// run it still loads right after the imports above and before any config is read, as the static import did.
const IMPORT_ONLY = process.env.KEEPER_IMPORT_ONLY === "1";
if (IMPORT_ONLY) {
  console.error(`${new Date().toISOString()} keeper-testnet.js: KEEPER_IMPORT_ONLY=1, loaded as a library; `
    + "the keeper is NOT running. Unset KEEPER_IMPORT_ONLY to run it.");
} else {
  await import("dotenv/config");
}

const MAINNET_CHAIN_ID = 4663n; // Robinhood Chain mainnet (keeper.js MAINNET_CHAIN_ID): this file refuses it

const {
  RPC_URL,
  KEEPER_PK,
  ORACLE,
  PACK_REGISTRY,
  NFT_COLLECTION,
  RAFFLE_ENGINE,
  HOLDER_ENGINE,
  LEADERBOARD_ENGINE,
  INTERVAL_SECONDS = "15",
  DRAW_MODE = "manual", // "manual" (print draw cmds) | "auto" (send them)
  DEPLOYER_ACCOUNT = "deployer", // keystore name used in the printed `cast send` draw commands
  TREASURY = "", // OPTIONAL. Set it AND ENABLE_CONVERT=true and the keeper runs Treasury.convert() so the prize
  //                vaults actually fund. Without both, convert never runs, every vault sits at zero, and all three
  //                engines take their no-burn branch forever -- which is precisely the state this deployment was in.
  ENABLE_CONVERT = "false", // "true" is the ONLY value that sends convert(). Anything else (false, blank, or
  //                           keeper.js's "simulate") leaves convert off, so a TREASURY copied from another .env
  //                           cannot start converts by itself.
  SEND_WAIT_TIMEOUT_MS = "120000", // As in keeper.js: a sent transaction with no receipt after this long is logged at
  //                                  ERROR with its hash and nonce and abandoned, so one dropped transaction cannot
  //                                  freeze every later job. The nonce is re-read on the next send.
  REAL_ORACLE = "", // "1"/"0" to force the beacon strategy; blank auto-detects from the oracle's bytecode
  DRAND_GRACE_ROUNDS = "40", // real-oracle path only, keeper.js's rule (beaconFetchVerdict): every relay answering 404 or
  //                            425 ("not yet") for a due round is silent while that round is at most this many rounds
  //                            behind the round due now (40 = about 2 minutes on quicknet); past that it is logged.
  CONVERT_SLIPPAGE_BPS = "300", // haircut applied to the measured quote to absorb drift between the
  //                               eth_call quote and the tx landing (another buy moves the pool).
  CONVERT_QUOTE_TTL_S = "300", // re-quote at most this often. A quote is ~20 eth_calls that each simulate
  //                             a full V4 swap; quoting every tick rate-limited the RPC (HTTP 429) and
  //                             took the keeper's other reads down with it. The slippage haircut is what
  //                             absorbs pool drift inside the TTL, and a floor that stops being reachable
  //                             just fails fire()'s staticCall and invalidates the cache.
  NOOP_BACKOFF_BASE_S = "60", // first stand-down after a draw that confirmed but consumed nothing
  NOOP_BACKOFF_MAX_S = "120", // ceiling on the doubling; a funded retry is never later than this. IT MUST
  //                             STAY WELL UNDER THE SHORTEST PERIOD. The first value here was 900s, sized
  //                             for a mainnet week -- on the 600s testnet clock that let a single
  //                             stand-down outlive the window, so funding a vault mid-period was simply
  //                             missed and the week voided. At 120s a 600s period still gets ~6 attempts.
  //                             The mainnet keeper can afford a far larger cap; this file cannot.
  // ── REHEARSAL FLAGS (both default off; neither touches a contract) ─────────────────────────────────
  // Two contract paths have never executed onchain because this keeper is too thorough: it posts every
  // pack's reveal beacon before any draw can miss one, and it posts a draw beacon and calls runDraw in
  // the SAME tick. Each flag withholds exactly one of those so the untested path can be observed once.
  SKIP_REVEALS = "0", // withhold PACK reveal beacons. With the engine's reveal guard (PackRegistry._drawCore) this
  //                     NO LONGER reaches WinnerSkipped stage 0: every raffle draw whose window holds a live
  //                     cohort reverts RevealPending(cohortDay, revealRound) before popping anything, and the
  //                     draw is logged as not callable with that reason. So the flag now rehearses the guard
  //                     itself (a fresh deploy is needed: an older engine still pops and skips).
  //                     The NFT rarity-reveal round is still posted -- the SR index, pledges and the
  //                     holder draw all need it, and withholding it would test something else by accident.
  PAUSE_DRAWS = "0", // post the raffle draw beacon but do NOT call runDraw, leaving a window in which
  //                    previewDraw(day) is readable against the same beacon the draw will use. That view
  //                    claims preview == draw; with the keeper in its normal mode the two are one tx apart
  //                    and the claim cannot be checked. Affects the daily raffle only.
} = process.env;

const skipReveals = SKIP_REVEALS === "1";
const pauseDraws = PAUSE_DRAWS === "1";
const convertOn = String(ENABLE_CONVERT).trim().toLowerCase() === "true";

if (!IMPORT_ONLY && (!RPC_URL || !KEEPER_PK)) {
  console.error("Missing config: set RPC_URL and KEEPER_PK (a funded throwaway testnet key) in .env");
  process.exit(1);
}
const SEND_WAIT_MS = /^\d+$/.test(String(SEND_WAIT_TIMEOUT_MS).trim()) ? Number(String(SEND_WAIT_TIMEOUT_MS).trim()) : NaN;
if (!(SEND_WAIT_MS >= 1000 && SEND_WAIT_MS <= 3_600_000)) {
  console.error(`Bad config: SEND_WAIT_TIMEOUT_MS=${SEND_WAIT_TIMEOUT_MS} must be a whole number of milliseconds in [1000, 3600000]`);
  process.exit(1);
}
const DRAND_GRACE = /^\d+$/.test(String(DRAND_GRACE_ROUNDS).trim()) ? BigInt(String(DRAND_GRACE_ROUNDS).trim()) : -1n;
if (!(DRAND_GRACE >= 0n && DRAND_GRACE <= 100_000n)) {
  console.error(`Bad config: DRAND_GRACE_ROUNDS=${DRAND_GRACE_ROUNDS} must be a whole number of rounds in [0, 100000]`);
  process.exit(1);
}

const AUTO = DRAW_MODE === "auto";
const ACCUM_DAYS = 2n; // RaffleEngine.ACCUM_DAYS (internal constant — mirrored here)

// Imported with KEEPER_IMPORT_ONLY=1 (no RPC_URL or KEEPER_PK), there is no provider and no signer: every contract
// binding below is then unusable, and a harness passes its own stubs to the exported functions.
const provider = RPC_URL ? new ethers.JsonRpcProvider(RPC_URL) : null;
const keeperWallet = KEEPER_PK ? new ethers.Wallet(KEEPER_PK, provider) : null;
// ONE NonceManager for every send. A bare Wallet reads eth_getTransactionCount(pending) per send, and
// ethers 6 caches an identical request for 250 ms: when a tick sends two txs back to back and the first mines
// instantly, the second reuses the cached nonce and fails "nonce has already been used" (reproduced on anvil:
// bare Wallet 1 of 3 ok, NonceManager 3 of 3). It lost reveal and holder beacons.
// fire() resets it after a failed send so a tx that never left cannot leave a nonce gap.
const wallet = keeperWallet ? new ethers.NonceManager(keeperWallet) : null;
const KEEPER_ADDRESS = keeperWallet?.address ?? null;

const oracleAbi = [
  "function setBeacon(uint64,bytes32) external",            // MockDrandOracle only
  "function submitBeacon(uint64,bytes,bytes) external",     // BlsDrandOracle only (real drand)
  "function isAvailable(uint64) view returns (bool)",
  "function roundAt(uint256) view returns (uint64)",
  "function drandGenesis() view returns (uint256)",
  "function drandPeriod() view returns (uint256)",
  "function gen() view returns (uint256)",
  "function per() view returns (uint256)",
];
const packAbi = [
  "function nextPackId() view returns (uint256)",
  "function packs(uint256) view returns (address owner,uint64 revealRound,uint32 cohortDay,bool spent)",
];
// Super Rare auto-entry index (spec §16). registerSuperRare is permissionless + idempotent, so the keeper
// posts it as plumbing (like beacons) in BOTH manual and auto modes — without it every SR's daily auto-entry
// silently resolves to 0. Reads (rarityOf/totalMinted) come off the NFT; the register write hits PackRegistry.
const nftAbi = [
  "function totalMinted() view returns (uint256)",
  "function rarityOf(uint256) view returns (uint8)",
  "function revealRound() view returns (uint64)",
];
const packRegAbi = [
  "function registerSuperRare(uint256[]) external",
  "function superRareCount() view returns (uint256)",
  "function srIndexed(uint256) view returns (bool)",
];
// The engines' custom errors are declared in their ABIs so a revert decodes by name (a runDraw whose window
// closed between its simulation and its send used to log "unknown custom error"). fire() also decodes a send-time
// revert through reverts.js, which knows the same errors.
const raffleAbi = [
  // PackRegistry._drawCore's reveal guard, bubbled by runDraw/runOpeningDraw. Declared so ethers decodes it by name.
  "error RevealPending(uint32 cohortDay, uint64 revealRound)",
  "error AlreadyDrawn()", "error BadDay()", "error OutsideWindow()", "error OpeningPending()",
  "error OpeningAlreadyDone()", "error Accumulating()", "error TooSoonToForgo()",
  "error PotBelowOpeningFloor(uint256 pot, uint256 floor)",
  "function runOpeningDraw(bool forgoIfUnderfunded) external",
  "function openingCapBps() view returns (uint256)",
  "function runDraw(uint32) external",
  "function currentDay() view returns (uint32)",
  "function drawRound(uint32) view returns (uint64)",
  "function openingDone() view returns (bool)",
  "function drawn(uint32) view returns (bool)",
  "function minPot() view returns (uint256)", // NOTE: this is the value in force NEXT period, not the opening's
  // runOpeningDraw no longer reads the live/scheduled minPot. It reads `openingMinPot`, a
  // snapshot frozen at construction and retunable only while currentDay() < ACCUM_DAYS -- i.e. provably
  // before its beacon reveals. Gating the keeper on the WRONG value would skip a payable opening (if the
  // live minPot drifted above the snapshot) or, worse, fire one the contract then FORGOES.
  "function openingMinPot() view returns (uint256)",
  "function vault() view returns (address)", // the raffle's prize vault (IVault, immutable)
];
// Opening-draw gate reads the prize vault's freeBalance() — never the raw token balance: freeBalance excludes
// unclaimedReserve and is exactly what RaffleEngine snapshots as the pot (IVault natspec).
const vaultAbi = ["function freeBalance() view returns (uint256)"];
// Option C: the O(supply) snapshot step is gone. The draw reads live ownership at runDraw time via the
// NFT's ownerSince stamp, so there is no snapshot()/snapComplete() to call any more.
const holderAbi = [
  "error AlreadyDrawn()", "error OutsideWindow()", // decoded by name, as above
  "function runDraw(uint256) external",
  "function currentPeriod() view returns (uint256)",
  "function drawRound(uint256) view returns (uint64)",
  "function drawn(uint256) view returns (bool)",
];
const leaderboardAbi = [
  "error AlreadyDistributed()", "error OutsideWindow()", // decoded by name, as above
  "function distribute(uint256) external",
  "function currentWeek() view returns (uint256)",
  "function distributed(uint256) view returns (bool)",
];

const oracle = ORACLE && new ethers.Contract(ORACLE, oracleAbi, wallet);
const packs = PACK_REGISTRY && new ethers.Contract(PACK_REGISTRY, packAbi, provider);
const packReg = PACK_REGISTRY && new ethers.Contract(PACK_REGISTRY, packRegAbi, wallet); // write path (registerSuperRare)
const nft = NFT_COLLECTION && new ethers.Contract(NFT_COLLECTION, nftAbi, provider);
const SR_CHUNK = 100; // ids per registerSuperRare tx (the ~2% SR set is tiny; one tx usually suffices)
const raffle = RAFFLE_ENGINE && new ethers.Contract(RAFFLE_ENGINE, raffleAbi, wallet);
const treasuryAbi = [
  "function convert(uint256,uint256) external",
  "function isKeeper(address) view returns (bool)",
  // Which legs convert() will actually run, mirrored from Treasury.convert
  "function convertThreshold() view returns (uint256)",
  "function maxWethConvertPerCall() view returns (uint256)",
  "function qpull() view returns (address)",
  "function weth() view returns (address)",
];
const erc20Abi = ["function balanceOf(address) view returns (uint256)"];
const treasury = TREASURY && new ethers.Contract(TREASURY, treasuryAbi, wallet);
const holder = HOLDER_ENGINE && new ethers.Contract(HOLDER_ENGINE, holderAbi, wallet);
const leaderboard = LEADERBOARD_ENGINE && new ethers.Contract(LEADERBOARD_ENGINE, leaderboardAbi, wallet);

const log = (...a) => console.log(new Date().toISOString(), ...a);
const logError = (...a) => console.error(new Date().toISOString(), "ERROR", ...a);

let oracleGen = 0n;
let oraclePer = 3n;
let lastPackId = 0n;                 // highest pack id already scanned (cursor, cheap incremental reads)
const revealRounds = new Set();      // distinct pack reveal rounds seen (string) — beacon posted once available

// ── TIMED-OUT SENDS (port of keeper.js; see the full rationale there). A timeout cannot tell a slow transaction from a
//    dropped one, and the next tick's simulation still passes while the first is pending, so a re-send could take the
//    next nonce and revert once the first lands. The timed-out transaction is remembered per job name, and the job
//    holds while it is pending. The record is dropped once it is mined, its nonce is used, or the RPC no longer knows
//    it and nothing is pending at its nonce. Checked on the job's next attempt and at the start of every tick.
const timedOutSends = new Map(); // job name -> { hash, nonce, from, at, held, provider }

// keeper.js timedOutSendVerdict, the same rule (kept identical; the offline harness compares the two).
function timedOutSendVerdict({ nonce, seen, latestCount, pendingCount }) {
  if (seen && seen.blockNumber != null) return "landed";
  if (BigInt(latestCount) > BigInt(nonce)) return "consumed";
  if (seen || BigInt(pendingCount) > BigInt(nonce)) return "pending";
  return "dropped";
}

// null (no record), { held: true } while still pending (logged once per record), or { held: false, verdict } after
// dropping the record. A failed read throws and keeps the record.
async function settleTimedOutSend(name) {
  const rec = timedOutSends.get(name);
  if (!rec) return null;
  const prov = rec.provider ?? provider;
  const seen = await prov.getTransaction(rec.hash);
  const [latestCount, pendingCount] = await Promise.all([
    prov.getTransactionCount(rec.from, "latest"), prov.getTransactionCount(rec.from, "pending"),
  ]);
  const verdict = timedOutSendVerdict({ nonce: rec.nonce, seen, latestCount, pendingCount });
  const ago = Math.round(Date.now() / 1000 - rec.at);
  if (verdict === "pending") {
    if (!rec.held) {
      rec.held = true;
      log(`${name}: NOT sent again: transaction ${rec.hash} (nonce ${rec.nonce}), which timed out ${ago}s `
        + "ago, is still pending. This job sends nothing until it lands, its nonce is used, or the RPC drops it.");
    }
    return { held: true, verdict };
  }
  timedOutSends.delete(name);
  const receipt = verdict === "dropped" ? null : await prov.getTransactionReceipt(rec.hash);
  if (receipt) {
    log(`${name}: transaction ${rec.hash} (nonce ${rec.nonce}), which timed out ${ago}s ago,landed late in `
      + `block ${receipt.blockNumber} and ${receipt.status === 1 ? "succeeded" : "REVERTED"}. The job simulates again.`);
    return { held: false, verdict: "landed", receipt };
  }
  log(`${name}: transaction ${rec.hash} (nonce ${rec.nonce}), which timed out ${ago}s ago,`
    + (verdict === "dropped"
      ? "is no longer known to the RPC and nothing is pending at its nonce: it was dropped. The job simulates again and may send."
      : `never landed: nonce ${rec.nonce} is used by another transaction. The job simulates again.`));
  return { held: false, verdict, receipt: null };
}

async function settleTimedOutSends() {
  for (const name of [...timedOutSends.keys()]) await settleTimedOutSend(name);
}

// keeper.js replacementStartBlock / waitable: ethers 6.17 builds a Contract method send's response without a start block,
// so its wait() never detects a replacement. Waiting on tx.replaceableTransaction(block read before the send) turns
// detection back on; a failed read leaves it off and the send goes ahead.
async function replacementStartBlock(prov) {
  try {
    return await prov.getBlockNumber();
  } catch {
    return null;
  }
}
const waitable = (tx, startBlock) => (startBlock !== null && typeof tx.replaceableTransaction === "function"
  ? tx.replaceableTransaction(startBlock) : tx);

// Simulate, then send. Returns true only if a tx was broadcast and confirmed (or replaced by this same call, which
// succeeded).
const sendNoted = new Map(); // name -> last logged "not callable at send" reason (logged once per change)
async function fire(name, contract, method, args) {
  if (timedOutSends.has(name)) {
    // Pending: hold. Just landed: this attempt ends, the next tick simulates against what it left. Dropped or
    // consumed: it cannot land twice, so this attempt goes on.
    const s = await settleTimedOutSend(name);
    if (s && (s.held || s.verdict === "landed")) return false;
  }
  try {
    await contract[method].staticCall(...args);
  } catch {
    return false; // not callable this tick — normal; skip silently
  }
  let tx = null;
  let result = false;
  const startBlock = await replacementStartBlock(contract.runner?.provider ?? provider);
  try {
    tx = await contract[method](...args);
    log(`${name}: sent ${tx.hash} (nonce ${tx.nonce})`);
    const rc = await waitable(tx, startBlock).wait(1, SEND_WAIT_MS); // bounded, so a dropped tx cannot freeze the loop
    log(`${name}: confirmed (block ${rc.blockNumber})`);
    sendNoted.delete(name);
    return true;
  } catch (e) {
    const reason = !tx && isRevertError(e) ? revertReason(e) : null;
    if (tx && ethers.isError(e, "TIMEOUT")) {
      timedOutSends.set(name, {
        hash: tx.hash, nonce: tx.nonce, from: tx.from, at: Date.now() / 1000, held: false,
        provider: contract.runner?.provider ?? provider,
      });
      logError(`${name}: transaction ${tx.hash} (nonce ${tx.nonce}, from ${tx.from}) did NOT confirm within `
        + `SEND_WAIT_TIMEOUT_MS=${SEND_WAIT_MS} ms; stopped waiting so the other jobs run. The nonce is re-read on the `
        + "next send, and this job does not send again while that transaction is still pending: it simulates again "
        + "once it lands, its nonce is used, or the RPC no longer has it. A transaction that lands late, after the RPC "
        + "stopped reporting it, can still make one duplicate of this call revert on chain (gas spent). If this "
        + "repeats, the RPC is dropping transactions.");
    } else if (tx && ethers.isError(e, "TRANSACTION_REPLACED")) {
      // Before the receipt branch: this error carries the REPLACEMENT's receipt, not a revert of this call.
      const ok = e.receipt?.status === 1;
      const sameCall = e.reason === "repriced";
      logError(`${name}: transaction ${tx.hash} (nonce ${tx.nonce}) was REPLACED (${e.reason}) by ${e.hash} in block `
        + `${e.receipt?.blockNumber}, which ${ok ? "succeeded" : "reverted"}. `
        + (sameCall
          ? `The replacement sends this same call, so it ${ok ? "went through" : "did not go through"}. `
          : "The replacement is a different transaction, so this call did not run. ")
        + "Another sender used this key's nonce (a second keeper on the same key, or a manual send).");
      result = sameCall && ok;
    } else if (tx && e?.receipt) {
      logError(`${name}: transaction ${tx.hash} REVERTED on chain in block ${e.receipt.blockNumber} (gas was spent)`);
    } else if (reason && reason !== "reverted without data") {
      // The staticCall ran against the latest block, and the send's gas estimate runs against the next one. A
      // draw whose window closes in between (OutsideWindow) reverts here. Nothing was broadcast: not callable this
      // tick, named once per change of reason instead of a "send FAILED ... unknown custom error" line every time.
      if (sendNoted.get(name) !== reason) {
        sendNoted.set(name, reason);
        log(`${name}: not callable this tick (${describeRevert(reason)}): it simulated cleanly, then reverted when the `
          + "transaction was built one block later. Nothing was sent.");
      }
    } else {
      log(`${name}: send FAILED: ${e.shortMessage || e.message}`);
    }
    // NonceManager counts the nonce before broadcasting; re-read it from the chain after any failed send. Every write
    // binding in this file runs on `wallet`, so the contract's runner IS that NonceManager.
    try { if (typeof contract.runner?.reset === "function") contract.runner.reset(); } catch { /* local state only */ }
    return result;
  }
}

// Post a mock beacon for `round` if not already on-chain (with fresh randomness). With `waitForRoundTime` (the
// reveal paths) only once the round's scheduled time has come (see roundDue): the mock would store a future round,
// real drand never publishes one early.
// ── BEACONS: mock vs real drand.
//    MockDrandOracle lets the keeper INVENT a beacon for any round, including rounds that do not exist yet.
//    That is what hid the short clock's reveal mismatch for so long -- not any gate or delay in this file,
//    but simply that a mock will store a beacon for a round drand has not reached.
//    BlsDrandOracle cannot: a round's signature is published by drand at that round's time and not before,
//    and submitBeacon verifies it against the quicknet public key. So under a real oracle the keeper WAITS,
//    and a "missing" beacon for a future round is correct behaviour, not a failure.
//
//    Which oracle we are talking to is detected from the deployed bytecode (the selector appears in the
//    dispatch table) rather than configured, so a keeper pointed at the wrong .env cannot silently pick the
//    wrong strategy. REAL_ORACLE=1/0 overrides if detection is ever wrong.
const SUBMIT_SELECTOR = ethers.id("submitBeacon(uint64,bytes,bytes)").slice(2, 10);

// keeper.js beaconFetchVerdict, the same rule (kept identical; the offline harness compares the two): a failed fetch
// is "pending" only when every relay answered "not yet" (beacon.js notPublished) and the round is at most `graceRounds`
// behind `roundAtNow`; anything else is "failed".
function beaconFetchVerdict({ round, roundAtNow, notPublished, graceRounds }) {
  return notPublished && BigInt(round) + BigInt(graceRounds) >= BigInt(roundAtNow) ? "pending" : "failed";
}
let realOracle = null; // resolved on first use

async function usingRealOracle() {
  if (realOracle !== null) return realOracle;
  if (REAL_ORACLE === "1" || REAL_ORACLE === "0") {
    realOracle = REAL_ORACLE === "1";
  } else {
    const code = await provider.getCode(ORACLE);
    realOracle = code.includes(SUBMIT_SELECTOR);
  }
  log(`oracle ${ORACLE} detected as ${realOracle ? "REAL BlsDrandOracle (drand quicknet)" : "MockDrandOracle"}`);
  return realOracle;
}

// The chain's clock for this tick, read once per tick (tick() clears it). Earlier, the
// reveal gate compared with Date.now(), and a chain whose clock differs from the host's (the local anvil ran about
// 636 s behind) moved the gate by that gap: a reveal beacon posted before its round time on chain, which is the early-reveal
// symptom, or held back. Now: the PENDING block's timestamp when the node serves a pending block (anvil does, and it
// tracks the chain clock between blocks, so a quiet local chain does not stall the gate), else the latest block's
// timestamp; the host clock only when the latest block cannot be read (said once per tick).
let tickChainNow = null; // bigint seconds, or null = not read yet this tick
async function chainNowS() {
  if (tickChainNow !== null) return tickChainNow;
  try {
    const latest = await provider.getBlock("latest");
    let s = BigInt(latest.timestamp);
    try {
      const p = await provider.send("eth_getBlockByNumber", ["pending", false]);
      if (p?.timestamp != null && p?.number != null && BigInt(p.number) >= BigInt(latest.number)) s = BigInt(p.timestamp);
    } catch { /* this node serves no pending block: the latest block's time stands */ }
    tickChainNow = s;
  } catch (e) {
    tickChainNow = BigInt(Math.floor(Date.now() / 1000));
    log(`reveal gate: could not read the chain's latest block (${e.shortMessage || e.message}); using the host clock this tick`);
  }
  return tickChainNow;
}

// A round is due once its drand time has passed: gen + (round - 1) x per, the oracle's own schedule (read at
// startup from drandGenesis/drandPeriod or gen/per), judged on the chain's clock (chainNowS). The mock accepts any
// round, so without this gate the keeper posted a cohort's reveal beacon 156 s early, while that cohort's buy day was
// still open, which real drand cannot.
async function roundDue(round) {
  if (!oraclePer || oraclePer <= 0n) return true; // schedule unknown: fall back to posting (logged at startup)
  const at = oracleGen + (BigInt(round) - 1n) * oraclePer;
  return (await chainNowS()) >= at;
}

async function setBeacon(round, { label = "beacon", waitForRoundTime = false } = {}) {
  if (!oracle) return false;
  round = BigInt(round);
  if (await oracle.isAvailable(round)) return false;

  if (!(await usingRealOracle())) {
    if (waitForRoundTime && !(await roundDue(round))) return false; // not due on the chain's clock yet; a later tick posts it
    const rnd = ethers.hexlify(ethers.randomBytes(32));
    return fire(`${label} setBeacon(${round})`, oracle, "setBeacon", [round, rnd]);
  }

  // Real path. Do not even ask drand for a round that cannot exist yet -- roundAt(now) is the newest round
  // the chain's own schedule says is due, and asking earlier just earns a 404 every tick.
  const due = await oracle.roundAt(BigInt(Math.floor(Date.now() / 1000)));
  if (round > due) return false; // not published yet; a later tick will get it. Silent: this is the normal state.

  let data;
  try {
    data = await beaconSubmitData(Number(round));
  } catch (e) {
    // Every relay answering 404 or 425 ("too early") is a round a few seconds from publishing; a later tick
    // gets it. Bounded as keeper.js bounds it: silent only within DRAND_GRACE_ROUNDS of the round due now. A relay
    // list that answers 404 for every round (a wrong path, an unknown chain hash) or a host clock far ahead is a real
    // fault and is logged every tick.
    if (beaconFetchVerdict({ round, roundAtNow: due, notPublished: !!e?.notPublished, graceRounds: DRAND_GRACE }) !== "pending") {
      log(`${label} drand fetch for round ${round} failed: ${e.message}`);
    }
    return false;
  }
  return fire(`${label} submitBeacon(${round})`, oracle, "submitBeacon", [round, data.sig, data.comp]);
}

// A draw the user should run in manual mode: print a ready cast command (once per tick it's callable).
function printDrawCmd(name, addr, sig, args) {
  const a = args.join(" ");
  log(`READY  ${name} — run:`);
  console.log(
    `   cast send ${addr} "${sig}" ${a} --rpc-url ${RPC_URL} --account ${DEPLOYER_ACCOUNT}`,
  );
}

// Send a draw (auto) or print its command (manual), but only if it simulates cleanly right now.
// Returns true only when a draw was sent and confirmed (auto mode).
async function draw(name, contract, addr, method, sig, args) {
  try {
    await contract[method].staticCall(...args);
  } catch (e) {
    // not callable this tick. RevealPending is worth one line: it is the engine's reveal guard (see SKIP_REVEALS).
    if (e?.revert?.name === "RevealPending") {
      log(`${name}: not callable -- RevealPending(cohort ${e.revert.args[0]}, round ${e.revert.args[1]}): that cohort's`
        + " reveal beacon is not posted, so the engine refuses to pop anything");
    }
    return false;
  }
  if (AUTO) return fire(name, contract, method, args);
  printDrawCmd(name, addr, sig, args);
  return false;
}

// ── NO-OP BACKOFF. HolderDrawEngine and LeaderboardEngine deliberately DO NOT set their idempotency flag
//    on a miss -- an empty vault, a sub-minPot pot, an empty board, nothing seated -- so that a late
//    top-up can still pay inside the window (HolderDrawEngine.runDraw and LeaderboardEngine.distribute, both
//    "do NOT mark drawn" / "distributed"). That is correct, and it is exactly what makes the naive guard
//    `if (await holder.drawn(target)) return` useless here: the flag the guard reads is the one the engine
//    refuses to write. draw()'s staticCall cannot see it either, because the call SUCCEEDS -- it just does
//    nothing. Result on this deployment: ~6 no-op sends a minute, 2,433 keeper txs, for weeks.
//
//    Do NOT fix this by copying the engines' conditions in here. There are five of them across the two
//    contracts, they are deliberate, and a keeper-side copy would drift from them silently. Detect the
//    no-op from its OUTCOME instead: if the flag did not flip, the call did nothing, whatever the reason.
//    The key carries the target period, so a new period always gets an immediate attempt, and a vault
//    funded mid-window is picked up within NOOP_BACKOFF_MAX_S.
const NOOP_BASE_S = Math.max(1, Number(NOOP_BACKOFF_BASE_S));
const NOOP_MAX_S = Math.max(NOOP_BASE_S, Number(NOOP_BACKOFF_MAX_S));
const noopUntil = new Map(); // "holder:64" => { until: epochSeconds, step }

const noopHolding = (key) => {
  const e = noopUntil.get(key);
  return !!e && Date.now() / 1000 < e.until;
};

function noopNote(key, label) {
  const step = (noopUntil.get(key)?.step ?? 0) + 1;
  const wait = Math.min(NOOP_BASE_S * 2 ** (step - 1), NOOP_MAX_S);
  noopUntil.set(key, { until: Date.now() / 1000 + wait, step });
  log(`${label}: confirmed but ${key} was NOT consumed -- the engine took a no-burn branch (empty vault,`
    + ` sub-minPot pot, empty board, or nothing seated). Standing down ${wait}s; the period will retry.`);
}

// Send, then re-read the idempotency flag. Skips entirely while a stand-down is in force.
async function drawOnce(name, contract, addr, method, sig, args, key, consumed) {
  if (noopHolding(key)) return;
  const sent = await draw(name, contract, addr, method, sig, args);
  // Only a CONFIRMED send can be a no-op. A draw that did not simulate (RevealPending, a beacon not posted yet,
  // outside its window) sent nothing, and standing down on it would delay the retry for no reason.
  if (!AUTO || !sent) return;
  if (await consumed()) noopUntil.delete(key);
  else noopNote(key, name);
}

// ── pack reveals: read each pack's reveal round DIRECTLY on-chain (no event scan — queryFilter over a
//    large block range fails on this RPC, which silently killed reveals) and post its beacon so the pack
//    reveals. Incremental: only reads packs newer than the cursor. A round is posted once its scheduled
//    drand time has passed (setBeacon's roundDue gate), never on the tick it is first seen.
async function doReveals() {
  if (!oracle || !packs) return;
  try {
    const nextId = await packs.nextPackId(); // ids are 1..nextId-1
    let scanned = lastPackId;
    for (let id = lastPackId + 1n; id < nextId; id++) {
      try { const p = await packs.packs(id); revealRounds.add(p.revealRound.toString()); scanned = id; }
      catch (_) { break; } // a failed read is retried next tick instead of being skipped past for good
    }
    lastPackId = scanned;
  } catch (e) {
    log(`reveal scan: ${e.shortMessage || e.message}`);
  }
  if (skipReveals) {
    log(`SKIP_REVEALS: withholding ${revealRounds.size} pack reveal beacon(s) -- every raffle draw over a live`
      + " cohort now reverts RevealPending (the engine's reveal guard) instead of reaching WinnerSkipped stage 0");
  } else {
    for (const round of revealRounds) {
      // setBeacon no-ops if the beacon is already available, or if the round's time has not come yet
      if (await oracle.isAvailable(BigInt(round))) { revealRounds.delete(round); continue; }
      await setBeacon(BigInt(round), { label: "reveal", waitForRoundTime: true });
    }
  }
  // The NFT collection's ONE rarity-reveal round (set at finalizeLaunch) is separate from the pack reveal
  // rounds; post it so rarityOf resolves — the Super Rare index, pledges, and the holder draw all need it.
  if (nft) {
    try {
      const rr = await nft.revealRound();
      if (rr !== 0n) await setBeacon(rr, { label: "nft-reveal", waitForRoundTime: true });
    } catch (e) { log(`nft reveal: ${e.shortMessage || e.message}`); }
  }
}

// One-time (idempotent) build of the Super Rare auto-entry index. Discovers SR ids by reading rarityOf
// OFF-CHAIN over 1..totalMinted (only the ~2% SR set is sent as calldata), then registers any not yet
// indexed, in chunks. The keeper posts this itself in BOTH modes (it is plumbing, not a draw). Runs before
// the draws each tick so SRs are indexed before the first daily draw's freeze (a
// registration made after a draw's freeze only counts from the NEXT day).
let srIds = null; // cached discovered SR token ids
let srDone = false; // every discovered SR is indexed on-chain
async function doRegisterSR() {
  if (srDone || !nft || !packReg) return;
  try {
    if ((await nft.revealRound()) === 0n) return; // finalizeLaunch not called yet
    await nft.rarityOf.staticCall(1n); // reverts until the reveal beacon (posted in doReveals) is available
  } catch {
    return; // not revealed yet — retry next tick
  }
  if (srIds === null) {
    const total = await nft.totalMinted();
    const found = [];
    for (let id = 1n; id <= total; id++) {
      try { if (Number(await nft.rarityOf(id)) === 3) found.push(id); } catch { /* skip */ }
    }
    srIds = found;
    log(`registerSuperRare: discovered ${srIds.length} Super Rare(s) across ${total} passes`);
  }
  if (srIds.length === 0) { srDone = true; return; }
  if (Number(await packReg.superRareCount()) >= srIds.length) {
    srDone = true;
    log(`registerSuperRare: all ${srIds.length} Super Rare(s) indexed`);
    return;
  }
  const pending = [];
  for (const id of srIds) { if (!(await packReg.srIndexed(id))) pending.push(id); }
  for (let i = 0; i < pending.length; i += SR_CHUNK) {
    const chunk = pending.slice(i, i + SR_CHUNK);
    await fire(`registerSuperRare[${chunk.length}]`, packReg, "registerSuperRare", [chunk]);
  }
}

// Opening-draw gate. RaffleEngine.runOpeningDraw is VOID-ON-MISS: called at/after the window close with the
// vault below minPot it FORGOES the opening (openingDone = true, pays nobody, no retry) instead of deferring
// it. That forgo branch is a *successful* call, so the staticCall in draw() would happily let it through —
// and on a testnet the vault is often still unfunded when day first reaches ACCUM_DAYS, which would throw
// the opening away the instant the window closed. So mirror the contract's pot check off-chain and only
// fire once freeBalance() >= minPot. (The contract also voids when the potCap-bounded pot's Common bucket
// can't pay OPENING_WINNERS >= 1 wei each, i.e. pot < 50 wei; any real minPot dwarfs that, so minPot is the
// one check that matters.) Any read failure counts as "not funded": never fire on an unknown vault state.
let prizeVault = null; // IVault at raffle.vault() — immutable, so resolved once and cached
async function openingFunded() {
  try {
    if (!prizeVault) prizeVault = new ethers.Contract(await raffle.vault(), vaultAbi, provider);
    // Must mirror what runOpeningDraw actually reads (openingMinPot), NOT raffle.minPot(). Falls back
    // to minPot() only for an older deployment that lacks the getter, so an older testnet stack still runs.
    let openingFloor;
    try {
      openingFloor = await raffle.openingMinPot();
    } catch {
      openingFloor = await raffle.minPot();
      log("raffle.runOpeningDraw: openingMinPot() absent (older deploy), falling back to minPot()");
    }
    const free = await prizeVault.freeBalance();
    const minPot = openingFloor;
    // Same inversion the mainnet keeper carried: the contract compares POT (= free * openingCapBps / BPS)
    // to the floor, not the raw balance, so `free >= minPot` fires for every balance between 1x and 10x the
    // floor and the contract then takes the forgo branch, which SUCCEEDS. Mirror the contract's arithmetic.
    let capBps;
    try {
      capBps = await raffle.openingCapBps();
    } catch {
      log("raffle.runOpeningDraw: openingCapBps() absent (older deploy); refusing to fire blind");
      return false;
    }
    if (capBps === 0n) return false;
    const pot = (free * capBps) / 10_000n;
    if (pot >= minPot) return true;
    log(
      `raffle.runOpeningDraw: opening POT below minPot (${ethers.formatEther(pot)} < ${ethers.formatEther(minPot)} QUOTRON; ` +
        `vault holds ${ethers.formatEther(free)} at ${capBps} bps), ` +
        "waiting so the opening is not forgone — fund the prize vault to let it run",
    );
    return false;
  } catch (e) {
    log(`raffle.runOpeningDraw: could not read vault/minPot (${e.shortMessage || e.message}), skipping so the opening is not forgone`);
    return false;
  }
}

async function doRaffle() {
  if (!raffle) return;
  const day = await raffle.currentDay();
  if (!(await raffle.openingDone())) {
    if (day >= ACCUM_DAYS) {
      // Beacon is posted regardless (harmless on the mock; ready the moment the vault is funded), but the
      // draw itself is gated: see openingFunded() — an underfunded call forgoes the opening for good.
      await setBeacon(await raffle.drawRound(ACCUM_DAYS - 1n), { label: "raffle-open" });
      if (await openingFunded()) {
        // false: never consent to forgoing the opening from an automated caller.
        await draw("raffle.runOpeningDraw", raffle, RAFFLE_ENGINE, "runOpeningDraw", "runOpeningDraw(bool)", [false]);
      }
    }
    return;
  }
  if (day < 1n) return;
  const target = day - 1n; // a day is drawn during the NEXT day
  if (target < ACCUM_DAYS || (await raffle.drawn(target))) return;
  // The raffle has the SAME no-burn branches as the other two engines and needs the same stand-down:
  // RaffleEngine.sol:547 (sub-minPot, or a pot too small to pay a full field) and :556 (an empty ticket
  // window pops nothing) both emit DrawExecuted(day, pot, 0) and return WITHOUT setting drawn[day], so
  // `drawn(target)` above can never become true and the keeper re-sends every tick. It was missed when
  // holder and leaderboard were fixed, and with no live packs it is the loudest of the three.
  const key = `raffle:${target}`;
  if (noopHolding(key)) return; // standing down; do not re-post the beacon either
  await setBeacon(await raffle.drawRound(target), { label: "raffle" });
  if (pauseDraws) {
    log(`PAUSE_DRAWS: beacon for day ${target} is posted, runDraw withheld.`
      + ` previewDraw(${target}) is now readable against the beacon the draw will use.`);
    return;
  }
  await drawOnce("raffle.runDraw", raffle, RAFFLE_ENGINE, "runDraw", "runDraw(uint32)", [target],
    key, () => raffle.drawn(target));
}

async function doHolder() {
  if (!holder) return;
  const week = await holder.currentPeriod();
  // Option C: no snapshot step. Week w is drawable during period w+1; run it once, void-on-miss.
  if (week < 1n) return;
  const target = week - 1n;
  if (await holder.drawn(target)) return; // already run this week
  const key = `holder:${target}`;
  if (noopHolding(key)) return; // standing down after a no-burn miss; do not even post the beacon again
  await setBeacon(await holder.drawRound(target), { label: "holder" });
  await drawOnce("holder.runDraw", holder, HOLDER_ENGINE, "runDraw", "runDraw(uint256)", [target],
    key, () => holder.drawn(target));
}

async function doLeaderboard() {
  if (!leaderboard) return;
  const week = await leaderboard.currentWeek();
  if (week < 1n) return;
  const target = week - 1n;
  if (await leaderboard.distributed(target)) return;
  // no beacon — deterministic pro-rata split
  const key = `leaderboard:${target}`;
  await drawOnce("leaderboard.distribute", leaderboard, LEADERBOARD_ENGINE, "distribute", "distribute(uint256)",
    [target], key, () => leaderboard.distributed(target));
}

// ── Treasury.convert(): tax QPULL -> WETH -> QUOTRON, split to the three prize vaults. WITHOUT THIS THE
//    VAULTS NEVER FUND and every draw takes its no-burn branch, which is what happened here: one Converted
//    event in the deployment's whole history, fired by hand from ExerciseTestnet.s.sol.
//
//    HOW THE MIN-OUTS ARE QUOTED, AND WHY NOT WITH A QUOTER CONTRACT.
//    convert(minWethOut, minQuotronOut) must be given real floors: QpullWethAdapter.sol:122 rejects a zero
//    minOut outright ("never swap unguarded"), and an unbounded floor on a live V4 pool is a free lunch for
//    anyone watching the mempool. The obvious answer -- deploy a quoter and ask it -- is WRONG HERE. The
//    QPULL/WETH pool carries QpullTaxHook, and what the hook charges depends on msg.sender: the adapter is
//    the hook's exemptSender, a quoter contract would not be. A quoter would therefore return a number the
//    real convert() can never hit, and every call would revert Slippage().
//
//    So quote the REAL function instead of modelling it. convert() reverts Slippage() when the measured
//    output falls under the floor, which makes "largest floor that still succeeds" exactly equal to the
//    output, and eth_call can ask that question for free. Bisect it. This costs ~12 eth_calls after the
//    first quote (the previous answer seeds the bracket), needs no contract, no extra dependency and no
//    quoter address, and is correct through the hook, the tax band, price impact and both adapters,
//    because it IS the call that will be sent. The same technique ports to keeper.js unchanged, which uses it
//    as its fallback floor when a quoter cannot price a leg.
//
//    KNOWN LIMIT on this deployment: a 10,000 QPULL slice (maxConvertPerCall) currently quotes at about
//    0.0000155 WETH, so a convert moves dust and the vaults cannot reach minPot (1 QUOTRON) from tax alone.
//    Convert being correct does not make the games payable here -- seed the vaults directly for that.
const SLIP_BPS = BigInt(CONVERT_SLIPPAGE_BPS);
const QUOTE_TTL_S = Number(CONVERT_QUOTE_TTL_S);
let lastOutWeth = 0n;
let lastOutQuotron = 0n;
let quoteCache = null; // { minW, minQ, at }

// One convert() simulation, read the way keeper.js reads it: { ok: true } or { ok: false, kind, reason } with
// kind "floor" (a known slippage revert: SwapShortfall, Slippage, SlippageExceeded, or the MockSwapAdapter's
// "slippage" string), "abort" or "unknown" (reverts.js classifyConvertRevert), or "transport" (the eth_call itself
// failed). The old probe returned false for EVERY failure, and the bisection read false as "floor too high": one RPC
// error on a fresh start collapsed the floor to about zero, and that floor was sent and reused for the quote TTL.
async function convertProbe(w, q) {
  try {
    await treasury.convert.staticCall(w, q);
    return { ok: true };
  } catch (e) {
    if (e instanceof TypeError) throw e;
    if (!isRevertError(e)) return { ok: false, kind: "transport", reason: e.shortMessage || e.message };
    const reason = revertReason(e);
    return { ok: false, kind: classifyConvertRevert(reason), reason };
  }
}

// Largest x for which probe(x) still succeeds, to ~0.5%. `seed` is the previous answer and only has to be
// in the right neighbourhood; the bracket widens or narrows from it either way. Returns:
//   { value }                     the largest accepted x
//   { value: 0n, failed }         probe(1) itself failed: convert cannot run at all right now (`failed` says why)
//   { value: null }               never refused up to 2^200 (ported from keeper.js): a floor the contract
//                                 never refuses is not being enforced, i.e. that leg is not running; never send it
//   { value: null, aborted }      a probe failed with anything but a floor revert: nothing was learned about the
//                                 floor, so the search stops instead of reading it as "too high"
const MAX_PROBE = 1n << 200n;
async function maxFeasible(probe, seed) {
  const first = await probe(1n);
  if (!first.ok) return { value: 0n, failed: first };
  let aborted = null;
  const tooHigh = async (x) => {
    const r = await probe(x);
    if (r.ok) return false;
    if (r.kind === "floor") return true;
    aborted = { ...r, at: x };
    return null;
  };
  let lo = 1n;
  let hi = seed > 1n ? seed : 1n << 40n;
  for (;;) {
    const t = await tooHigh(hi);
    if (t === null) return { value: null, aborted };
    if (t) break;
    lo = hi; hi <<= 2n;
    if (hi > MAX_PROBE) return { value: null };
  }
  while (hi - lo > lo / 200n + 1n) {
    const mid = (lo + hi) / 2n;
    const t = await tooHigh(mid);
    if (t === null) return { value: null, aborted };
    if (t) hi = mid; else lo = mid;
  }
  return { value: lo };
}

// A convert quote that found no floor, said once per change of cause (a steady "caps not armed" is one line, not one
// per tick). Cleared by a successful quote.
let convertNote = null;
function noteConvert(key, message) {
  if (convertNote === key) return;
  convertNote = key;
  log(message);
}

// The floor for one leg, or null (nothing is sent this tick). `label` names the leg in the log.
async function searchFloor(label, probe, seed) {
  const r = await maxFeasible(probe, seed);
  if (r.value === 0n) {
    // Not callable at all. BelowThreshold is the normal idle state (convertLegs already screens most of it): quiet.
    const f = r.failed;
    if (f.kind !== "transport" && String(f.reason).startsWith("BelowThreshold")) return null;
    noteConvert(`${label}:off:${f.reason}`, `convert: not callable right now (${label} at a 1 wei floor: `
      + `${f.kind === "transport" ? `RPC error: ${f.reason}` : describeRevert(f.reason)}); nothing sent`);
    return null;
  }
  if (r.value === null && r.aborted) {
    const a = r.aborted;
    noteConvert(`${label}:abort:${a.kind}:${a.reason}`, `convert: ${label} floor search STOPPED at probe ${a.at}: `
      + `${a.kind === "transport" ? `RPC error: ${a.reason}` : describeRevert(a.reason)} (${a.kind}). Only a slippage `
      + "revert means the floor is too high; anything else says nothing about it, so no floor is derived and nothing "
      + "is sent this tick (keeper.js classification)");
    return null;
  }
  if (r.value === null) {
    noteConvert(`${label}:unbounded`, `convert: ${label} accepted every floor up to 2^200, so it is not running; not converting`);
    return null;
  }
  return r.value;
}

// Which legs convert() runs this call, read exactly as Treasury.convert decides it: the QPULL
// leg runs only when qpull balance > 0, >= convertThreshold, and the WETH already held is under a full WETH slice.
// All buy and sell tax arrives as WETH, so on a normal stack the QPULL leg never runs and minWethOut is
// ignored by the contract: bisecting it "succeeded" at every probe up to 2^200, and the keeper logged and SENT a
// 6.4e42 WETH floor.
async function convertLegs() {
  const [qAddr, wAddr, threshold, wethCap] = await Promise.all([
    treasury.qpull(), treasury.weth(), treasury.convertThreshold(), treasury.maxWethConvertPerCall()]);
  const [qpullBal, wethHeld] = await Promise.all([
    new ethers.Contract(qAddr, erc20Abi, provider).balanceOf(TREASURY),
    new ethers.Contract(wAddr, erc20Abi, provider).balanceOf(TREASURY)]);
  const qpullLeg = qpullBal > 0n && qpullBal >= threshold && wethHeld < wethCap;
  return { qpullLeg, qpullBal, wethHeld };
}

// Leg 1 is quoted with leg 2 held at its minimum, so the only thing that can fail is leg 1. Leg 2 is then
// quoted against leg 1's actual floor, so the pair is self-consistent: the values returned here are values
// the very next call can satisfy. When leg 1 does not run, minWethOut is 0 and only leg 2 is bisected.
async function quoteConvert() {
  const legs = await convertLegs();
  let minW = 0n;
  let outW = 0n;
  if (legs.qpullLeg) {
    outW = await searchFloor("leg 1 (QPULL->WETH)", (w) => convertProbe(w, 1n), lastOutWeth);
    if (outW === null) return null;
    minW = (outW * (10_000n - SLIP_BPS)) / 10_000n;
    lastOutWeth = outW;
  } else if (legs.wethHeld === 0n) {
    return null; // nothing to convert (convert() would revert BelowThreshold); normal, stay quiet
  }
  const outQ = await searchFloor("leg 2 (WETH->QUOTRON)", (q) => convertProbe(minW, q), lastOutQuotron);
  if (outQ === null) return null;
  lastOutQuotron = outQ;
  convertNote = null;
  return { minW, minQ: (outQ * (10_000n - SLIP_BPS)) / 10_000n, outW, outQ, legs };
}

let convertWarned = false;
async function doConvert() {
  if (!treasury || !convertOn) return; // TREASURY alone never sends convert(); main() says which is missing
  if (!convertWarned) {
    convertWarned = true;
    if (!(await treasury.isKeeper(KEEPER_ADDRESS))) {
      log(`convert: DISABLED -- ${KEEPER_ADDRESS} is not a Treasury keeper, so convert() reverts NotKeeper.`
        + ` The prize vaults will stay empty and every draw will no-op. Grant it with`
        + ` Treasury.setKeeper(${KEEPER_ADDRESS}, true) from the owner (the Safe on this deploy).`);
    }
  }
  const fresh = quoteCache && Date.now() / 1000 - quoteCache.at < QUOTE_TTL_S;
  if (!fresh) {
    const q = await quoteConvert();
    if (!q) { quoteCache = null; return; } // not convertible right now -- normal, stay quiet
    quoteCache = { minW: q.minW, minQ: q.minQ, at: Date.now() / 1000 };
    const leg1 = q.legs.qpullLeg
      ? `leg 1 ${ethers.formatEther(q.legs.qpullBal)} QPULL -> ${ethers.formatEther(q.outW)} WETH`
      : `leg 1 skipped (WETH-only sweep of ${ethers.formatEther(q.legs.wethHeld)} WETH held)`;
    log(`convert: quoted ${leg1} / ${ethers.formatEther(q.outQ)} QUOTRON,`
      + ` floors ${SLIP_BPS}bps under, reused for ${QUOTE_TTL_S}s`);
  }
  // A stale floor the pool has moved past simply fails fire()'s staticCall; drop the cache and re-quote.
  if (!(await fire("treasury.convert", treasury, "convert", [quoteCache.minW, quoteCache.minQ]))) {
    quoteCache = null;
  }
}

async function tick() {
  tickChainNow = null; // the reveal gate re-reads the chain's clock once per tick
  // settleTimedOutSends reads only, and is a no-op unless a send timed out; it runs before every job that sends.
  for (const job of [settleTimedOutSends, doConvert, doReveals, doRegisterSR, doRaffle, doHolder, doLeaderboard]) {
    try {
      await job();
    } catch (e) {
      log("tick error:", e.shortMessage || e.message);
    }
  }
}

async function main() {
  const net = await provider.getNetwork();
  // This is the MockDrandOracle testnet keeper. Pointed at Robinhood mainnet (for example through the mainnet
  // keeper/.env) it would post nothing useful and, with a key holding the Treasury keeper role, could convert on
  // floors it was never meant to derive there. Refuse before any other read or send.
  if (net.chainId === MAINNET_CHAIN_ID) {
    console.error(`${new Date().toISOString()} FATAL: keeper-testnet.js refuses to run on Robinhood Chain mainnet (chainId `
      + `${net.chainId}). It is the short-clock testnet keeper; run keeper.js on mainnet. Nothing was sent.`);
    process.exit(1);
  }
  if (oracle) {
    // gen()/per() are MockDrandOracle-ONLY: reading them against the real oracle reverted and killed the
    // keeper before its first tick. The roundAt() derivation below fixed that and still works, but the
    // comment that came with it ("BlsDrandOracle ... exposes no getter") was wrong: it declares
    // `uint256 public immutable drandGenesis` and `drandPeriod` (BlsDrandOracle.sol:50-51), so the
    // schedule can simply be READ. Ask each oracle for the names it actually has, exact reads first,
    // and keep the derivation as the last resort for any implementation that exposes neither.
    try {
      oracleGen = await oracle.drandGenesis();
      oraclePer = await oracle.drandPeriod();
    } catch {
    try {
      oracleGen = await oracle.gen();
      oraclePer = await oracle.per();
    } catch {
      const t = BigInt(Math.floor(Date.now() / 1000));
      const [r0, r1] = [await oracle.roundAt(t), await oracle.roundAt(t + 3600n)];
      oraclePer = 3600n / (BigInt(r1) - BigInt(r0));          // seconds per round
      oracleGen = t - (BigInt(r0) - 1n) * oraclePer;           // roundAt(t) = (t-gen)/per + 1
      log(`oracle exposes no schedule getter -- derived from roundAt()`);
    }
    }
  }
  log(`QPULL testnet keeper online — chainId ${net.chainId}, keeper ${KEEPER_ADDRESS}, mode ${DRAW_MODE}`);
  log(`oracle gen=${oracleGen} per=${oraclePer}s | interval ${INTERVAL_SECONDS}s | send wait ${SEND_WAIT_MS} ms`);
  if (TREASURY && !convertOn) {
    log(`convert: OFF. TREASURY is set, but keeper-testnet.js sends Treasury.convert() only with ENABLE_CONVERT=true `
      + `(it is ${JSON.stringify(ENABLE_CONVERT)}), so the prize vaults do not fund from tax until then.`);
  } else if (convertOn && !TREASURY) {
    log("convert: OFF. ENABLE_CONVERT=true, but TREASURY is not set.");
  } else if (convertOn) {
    log(`convert: ON (ENABLE_CONVERT=true, Treasury ${TREASURY}, floors ${SLIP_BPS} bps under the bisected output)`);
  }
  if (!AUTO) log("manual mode: I post beacons; I'll print `cast send` for each ready draw for YOU to run.");
  if (process.argv.includes("--once")) {
    await tick();
    return;
  }
  const ms = Number(INTERVAL_SECONDS) * 1000;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    await tick();
    await new Promise((r) => setTimeout(r, ms));
  }
}

/// For an offline harness only (KEEPER_IMPORT_ONLY=1 set before the import; without it, importing this file runs the
/// keeper). The functions take stub contracts whose `runner.provider` answers the reads.
export const __test = Object.freeze({
  fire, settleTimedOutSend, settleTimedOutSends, timedOutSendVerdict, beaconFetchVerdict,
  timedOutSends: () => new Map([...timedOutSends].map(([n, r]) => [n, { ...r, provider: undefined }])),
  resetTimedOutSends: () => { timedOutSends.clear(); },
  drandGraceRounds: () => DRAND_GRACE,
});

if (!IMPORT_ONLY) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
