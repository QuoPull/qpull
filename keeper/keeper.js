#!/usr/bin/env node
/*
 * QPULL keeper: sends the protocol's periodic transactions and posts the drand beacons they consume.
 *
 * Jobs, in tick order: the health watch (both signers' gas, host clock); the re-check of any send that timed out
 * (reads only); the voided-period alarm (BEFORE any
 * settlement or convert moves a vault, so a closed period is judged on the vault as its window left it); index
 * Super Rare passes; post each pack cohort's reveal beacon once drand publishes it; the one-time opening draw,
 * then the daily raffle draw; the weekly leaderboard distribute; the weekly holder draw; Treasury.convert
 * (opt-in, primary only); the QuoPods re-settle sweep; the expired-claim sweep. After the jobs, a `heartbeat:` line every HEALTH_INTERVAL_S.
 *
 * Invariants this file keeps:
 *  - CONFIG. `.env` is read from this script's directory, never the working directory. The clock (genesis,
 *    dayLength, revealDelay, LIFE_DAYS) comes from PackRegistry and the oracle from the contracts' drand().
 *    GENESIS / REVEAL_DELAY / DAY_LENGTH / ORACLE in .env may only ASSERT those values; a mismatch exits FATAL.
 *    Convert is configured the same way: the tokens and adapters come from the Treasury, the QPULL/WETH pool
 *    key from QpullWethAdapter.poolKey(), the sell-tax schedule and launchTime from that key's hook. QPULL,
 *    WETH, WETH_QUOTRON_ADAPTER and QPULL_POOL_* in .env may only assert them. A blank value is UNSET.
 *  - BEACONS BEFORE DRAWS. A raffle draw (opening or daily) is never fired until every beacon it consumes is
 *    on-chain: the reveal round of each cohort in its sweep window that still has live packs, AND its draw
 *    round. The engine enforces the reveal half itself: PackRegistry._drawCore reverts
 *    RevealPending(cohortDay, revealRound) before popping anything, so an early draw loses nothing but does
 *    not settle, and a daily draw's window is one day. If a simulation still reverts RevealPending (an RPC
 *    node behind the one that saw the beacon), the keeper posts THAT round and retries next tick; it is not a
 *    convert-style failure and is not escalated as one (handleRevealPending).
 *  - SIMULATE, THEN SEND. A simulated revert means "not callable now" and is logged when its reason changes.
 *    A transport failure (HTTP error, timeout) or a method missing from an ABI is thrown, never read as a skip.
 *    LIMIT: ethers maps EVERY JSON-RPC error object returned for eth_call (a rate limit, "header not found")
 *    to CALL_EXCEPTION, so such an error cannot be told apart from a revert without data and fire() reports
 *    it as "not callable now". Jobs whose correctness depends on the difference do not use isRevertError.
 *  - NO-OP BACKOFF. Engines do not latch a period that took a no-pay branch, so a no-op is detected from its
 *    outcome (the flag did not flip) and the keeper stands down instead of re-sending (fireOnce).
 *  - VOID IS A LOSS. A period missed for its whole settlement window rolls its pot forward, but that period's
 *    participants are never paid. Outages are therefore alarmed (runVoidWatch), not shrugged off.
 *  - A SEND NEVER BLOCKS THE LOOP. tx.wait() is bounded by SEND_WAIT_TIMEOUT_MS: a transaction the RPC acknowledged
 *    but never included is an ERROR with its hash and nonce, the signer's nonce is re-read, and that job does not
 *    send again while the transaction is still pending (TIMED-OUT SENDS); once it lands, its nonce is used or the
 *    RPC drops it, the job re-simulates. A transaction replaced at its nonce by another sender on the same
 *    key is logged as REPLACED, not as reverted. The loop's liveness is the `heartbeat:` line, which only a
 *    completed tick writes.
 *  - NEVER A SILENT STALL. A convert that cannot run, a signer running out of gas, caps left unarmed after
 *    go-live, cap reads that keep failing and a convert that has not succeeded for hours while tax is pending
 *    are all logged at ERROR level, rate-limited but repeated (README "Alarms" lists each cadence).
 *  - CONVERT FAILS CLOSED. No floor, no send. With the spot guard on (CONVERT_PRICE_DEVIATION_BPS > 0) and
 *    CONVERT_SPOT_UNAVAILABLE=hold (the default, by the owner's choice), a Quotron price check that is unavailable
 *    (VIEW_QUOTER not set, or its reference quote failing) HOLDS the convert and alarms. So does a CONFIGURED
 *    QPULL_QUOTER that cannot give the donated-QPULL leg a reference quote for ANY reason: its quote fails, it
 *    quotes on a different PoolManager than the adapter, or the QPULL/WETH pool binding cannot be read or is
 *    wrong (spotHold; a cause that will not clear by itself is ERROR at once). The one unguarded leg is donated
 *    QPULL with no QPULL_QUOTER configured at all (that quoter is optional): its floor comes from bisection, and
 *    the keeper says so hourly. Bisection probes run pinned to the block the spot guard checked, and a probe
 *    that cannot be read twice aborts the bisection (no floor), never guesses "too high".
 *
 * Run it as a long-lived process under a supervisor (systemd, pm2, docker restart=always):
 *   node keeper.js              loop every INTERVAL_SECONDS
 *   node keeper.js --failsafe   the permissionless jobs only (no convert); run a second copy anywhere
 *   node keeper.js --once       ONE manual diagnostic pass. NOT a scheduling mode and NOT a dry run: it sends
 *                               real beacon and draw transactions, keeps no backoff or idempotency state
 *                               between runs and takes no lock (see README "Run"). It NEVER sends convert(),
 *                               whatever ENABLE_CONVERT, VIEW_QUOTER or the spot guard say: with
 *                               ENABLE_CONVERT=true it derives the floors and simulates convert(), exactly as
 *                               ENABLE_CONVERT=simulate does, and reports "Nothing sent".
 */
import { ethers } from "ethers";
import dotenv from "dotenv";
import { fileURLToPath } from "node:url";
import {
  KNOWN_ERRORS, REVERT_HINTS, isRevertError, decodeRevertData, revealPendingOf, revertReason, describeRevert,
  classifyConvertRevert, reasonName,
} from "./reverts.js";

// ENTRY. Loading this file RUNS THE KEEPER, however it is launched. Whether it runs must never depend on
// process.argv: pm2's fork mode loads the app through its own wrapper (argv[1] is the wrapper, not this
// file) and `node keeper` has no ".js", and an argv-based "am I main?" check silently never started the loop
// under either, while the supervisor still showed the process online.
// The ONE exception is explicit: an importer that sets KEEPER_IMPORT_ONLY=1 in the process environment BEFORE
// importing (the offline tests of the functions below) gets a module that never loads .env, never builds a
// signer and never starts the loop. .env cannot set it (the decision is made before .env is read), and it
// is announced on stderr, so an inherited KEEPER_IMPORT_ONLY=1 is visible in the supervisor's log.
// A harness MUST set process.env.KEEPER_IMPORT_ONLY = "1" in its own process before `await import(...)`:
// a guard that only inspects its own environment does not hold, because this file loads keeper/.env itself.
const IMPORT_ONLY = process.env.KEEPER_IMPORT_ONLY === "1";
if (IMPORT_ONLY) {
  console.error(`${new Date().toISOString()} keeper.js: KEEPER_IMPORT_ONLY=1, loaded as a library; `
    + "the keeper is NOT running. Unset KEEPER_IMPORT_ONLY to run it.");
}

// `import "dotenv/config"` read ${cwd}/.env, and cron runs with cwd=$HOME, so a cron entry exited on
// "Missing config" every minute. Resolve next to this file. DOTENV_CONFIG_PATH still overrides explicitly.
const ENV_PATH = process.env.DOTENV_CONFIG_PATH || fileURLToPath(new URL("./.env", import.meta.url));
if (!IMPORT_ONLY) dotenv.config({ path: ENV_PATH });
const { relayList, beaconSubmitData } = await import("./beacon.js");

const log = (...a) => console.log(new Date().toISOString(), ...a);
const logError = (...a) => console.error(new Date().toISOString(), "ERROR", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── PURE DECISION LOGIC ─────────────────────────────────────────────────────────────────────────────
//    No provider, no key, no module state. Exported so the rules that decide what is posted and fired can
//    be exercised directly: with KEEPER_IMPORT_ONLY=1 set, `import("./keeper.js")` loads this file without
//    loading .env or running main(). Without it, importing this file runs the keeper (see ENTRY above).

export const MAINNET_CHAIN_ID = 4663n;
/// Basis points. The one spelling used for every ratio in this file.
export const BPS = 10_000n;

/// RaffleEngine.ACCUM_DAYS is `internal constant` (no getter exists; calling one reverts with empty data),
/// so it is mirrored. It is in day units, so it compresses with dayLength and serves every chain.
export const RAFFLE_ACCUM_DAYS = 2n;

/// HolderDrawEngine.WINNERS (`uint256 internal constant WINNERS = 5`, src/HolderDrawEngine.sol) has no getter;
/// mirrored for the void alarm's "had value" test.
export const HOLDER_WINNERS = 5n;

/// A key copied blank from .env.example (`KEY=`) is UNSET. Never "" and never Number("") === 0.
export function envValue(v) {
  if (v === undefined || v === null) return undefined;
  const s = String(v).trim();
  return s === "" ? undefined : s;
}

/// What is wrong with a private-key value, WITHOUT echoing it. ethers includes the raw input in the
/// error it throws for a malformed key, and that error used to reach stderr (journald, the pm2 log).
export function privateKeyProblem(name, raw) {
  const v = envValue(raw);
  if (v === undefined) return null;
  if (/^(0x)?[0-9a-fA-F]{64}$/.test(v)) return null;
  return `${name} is not a 32-byte hex private key (it is ${v.length} characters; expected 64 hex digits, `
    + "optionally 0x-prefixed). Its value is not printed.";
}

/// Revert decoding and classification live in reverts.js (shared with keeper-testnet.js) and are
/// re-exported here unchanged: KNOWN_ERRORS, REVERT_HINTS, isRevertError, decodeRevertData, revealPendingOf,
/// revertReason, describeRevert, classifyConvertRevert.
export {
  KNOWN_ERRORS, REVERT_HINTS, isRevertError, decodeRevertData, revealPendingOf, revertReason, describeRevert,
  classifyConvertRevert,
};

/// Reverts only leg 1 (QpullWethAdapter, the QPULL/WETH pool's QpullTaxHook) can raise. The QUOTRON leg also
/// swaps through a v4 PoolManager (Quotron's router and hook), so generic PoolManager errors, Slippage,
/// MinOutRequired and UnsupportedPath are NOT evidence of either leg.
const LEG1_ONLY_REVERTS = new Set([
  "PoolKeyUnset", "NotPoolManager", "PartialFill", "SwapTooLarge", "RecordOutOfGas", "NotCanonicalPool", "Gated",
  "BuyCooldown", "EarlyBuyTooLarge",
]);
/// Is this convert() revert attributable to leg 1? A hook revert arrives wrapped (WrappedError), and its target
/// decides when the QPULL/WETH hook address is known: only that hook's own revert is leg 1.
export function isLeg1Revert(reason, qpullHook) {
  const s = String(reason);
  const targets = [...s.matchAll(/\(wrapped: [^()]* on (0x[0-9a-fA-F]{40})\)/g)].map((m) => m[1]);
  if (targets.length && qpullHook) return targets.some((t) => sameAddr(t, qpullHook));
  return LEG1_ONLY_REVERTS.has(reasonName(s));
}

export const ORACLE_SELECTORS = Object.freeze({
  submitBeacon: ethers.id("submitBeacon(uint64,bytes,bytes)").slice(2, 10), // BlsDrandOracle
  setBeacon: ethers.id("setBeacon(uint64,bytes32)").slice(2, 10), // MockDrandOracle (testnet only)
  isAvailable: ethers.id("isAvailable(uint64)").slice(2, 10),
  randomness: ethers.id("randomness(uint64)").slice(2, 10),
  roundAt: ethers.id("roundAt(uint256)").slice(2, 10),
});

/// Byte-aligned search for a 4-byte selector in runtime bytecode (the dispatcher pushes each one whole).
export function codeHasSelector(code, selectorHex) {
  const c = String(code || "").toLowerCase();
  const s = String(selectorHex).replace(/^0x/, "").toLowerCase();
  const base = c.startsWith("0x") ? 2 : 0;
  for (let i = c.indexOf(s, base); i >= 0; i = c.indexOf(s, i + 1)) {
    if ((i - base) % 2 === 0) return true;
  }
  return false;
}

/// Which beacon interface an oracle speaks, from its BYTECODE rather than from a probe call. A probe
/// staticCall "succeeds" against an address with no code (an EOA returns empty data, and submitBeacon has no
/// return value to fail decoding), and an RPC hiccup without revert data looked like a present selector, so
/// the old probe classified 0x...dEaD as "bls" and cached it forever.
///   bls   submitBeacon + the IDrandOracle reads (BlsDrandOracle)
///   mock  setBeacon + the IDrandOracle reads (MockDrandOracle: unverified randomness, testnet only)
///   none  anything else, including no code at all
/// On Robinhood mainnet (4663) ONLY a plain "bls" oracle is acceptable.
export function classifyOracleCode(code, chainId) {
  const hex = typeof code === "string" ? code.toLowerCase() : "";
  if (hex === "" || hex === "0x") {
    return { iface: "none", acceptable: false, reason: "there is no contract code at this address" };
  }
  const has = (k) => codeHasSelector(hex, ORACLE_SELECTORS[k]);
  const reads = has("isAvailable") && has("randomness") && has("roundAt");
  const submit = has("submitBeacon");
  const set = has("setBeacon");
  const mainnet = chainId != null && BigInt(chainId) === MAINNET_CHAIN_ID;
  if (!reads || (!submit && !set)) {
    return {
      iface: "none",
      acceptable: false,
      reason: "the bytecode does not implement IDrandOracle with submitBeacon(uint64,bytes,bytes) or setBeacon(uint64,bytes32)",
    };
  }
  if (submit && !set) return { iface: "bls", acceptable: true, reason: null };
  if (mainnet) {
    return {
      iface: submit ? "bls" : "mock",
      acceptable: false,
      reason: "it exposes setBeacon (a settable, unverified oracle) on Robinhood mainnet; only BlsDrandOracle is acceptable on chainId 4663",
    };
  }
  return { iface: submit ? "bls" : "mock", acceptable: true, reason: null };
}

/// The oracle the keeper posts to MUST be the one the contracts read. `readings` are the drand()
/// values of every configured contract; ORACLE from .env may only assert the result.
/// Returns { address } (null when no configured contract needs an oracle), or { fatal }.
export function resolveOracleAddress(readings, envOracle) {
  const norm = (a) => {
    try {
      return ethers.getAddress(String(a));
    } catch {
      return null; // not an address: reported as fatal by the callers below
    }
  };
  const env = envValue(envOracle) ?? null;
  if (env && !norm(env)) return { fatal: `ORACLE=${env} in .env is not a valid address` };
  if (!readings.length) {
    return {
      address: null,
      note: env ? "ORACLE is set but no contract that reads an oracle is configured; ignoring it" : null,
    };
  }
  for (const r of readings) {
    const a = norm(r.address);
    if (!a || a === ethers.ZeroAddress) return { fatal: `${r.label} returned ${r.address}, not an oracle address` };
  }
  const first = norm(readings[0].address);
  if (readings.some((r) => norm(r.address) !== first)) {
    return {
      fatal: "the contracts disagree about the oracle ("
        + readings.map((r) => `${r.label}=${norm(r.address)}`).join(", ")
        + "). Beacons posted to one are invisible to the others; this deployment is mis-wired",
    };
  }
  if (env && norm(env) !== first) {
    return {
      fatal: `ORACLE=${norm(env)} in .env, but ${readings.map((r) => r.label).join(" and ")} read ${first}. `
        + "Beacons posted to the .env address would never be seen by any draw. Remove ORACLE or correct it",
    };
  }
  return { address: first };
}

/// Problems with the clock read from PackRegistry, and with any .env value that tries to assert it.
/// `chain` = { genesis, dayLength, revealDelay } as bigints. Empty array = OK.
export function clockProblems(chain, env = {}) {
  const out = [];
  const { genesis, dayLength, revealDelay } = chain;
  if (!(genesis > 0n)) out.push(`PackRegistry.genesis() is ${genesis}`);
  if (!(dayLength > 0n)) out.push(`PackRegistry.dayLength() is ${dayLength}`);
  if (!(revealDelay > 0n && revealDelay < dayLength)) {
    out.push(`PackRegistry.revealDelay() is ${revealDelay}, outside (0, dayLength=${dayLength})`);
  }
  const assertEnv = (name, raw, actual, zeroMeansUnset) => {
    const s = envValue(raw);
    if (s === undefined || (zeroMeansUnset && s === "0")) return;
    if (!/^\d+$/.test(s)) {
      out.push(`${name}=${s} in .env is not a whole number of seconds`);
      return;
    }
    if (BigInt(s) !== actual) {
      out.push(`${name}=${s} in .env, but PackRegistry says ${actual}. The clock always comes from the chain; `
        + `an .env value may only assert it. Remove ${name} from .env or correct it`);
    }
  };
  assertEnv("GENESIS", env.GENESIS, genesis, true); // "0" was the old "unset" sentinel
  assertEnv("REVEAL_DELAY", env.REVEAL_DELAY, revealDelay, false);
  assertEnv("DAY_LENGTH", env.DAY_LENGTH, dayLength, false);
  return out;
}

/// The cohorts a raffle draw on `drawDay` can pop from. Mirrors PackRegistry._drawCore:
/// from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0, to = drawDay - 1.
export function drawWindowCohorts(drawDay, lifeDays) {
  const d = BigInt(drawDay);
  const life = BigInt(lifeDays);
  if (d === 0n) return [];
  const from = d > life ? d - life : 0n;
  const out = [];
  for (let c = from; c <= d - 1n; c++) out.push(c);
  return out;
}

/// The timestamp PackRegistry._mintPacks seals cohort `c` to: roundAt(genesis + (c+1)*dayLength + revealDelay).
export function cohortRevealTimestamp(cohort, clock) {
  return clock.genesis + (BigInt(cohort) + 1n) * clock.dayLength + clock.revealDelay;
}

/// Every beacon a raffle draw may consume. Before popping anything, PackRegistry._drawCore checks
/// that every cohort in the sweep window with live packs has its tier round on the oracle, and otherwise the
/// whole draw reverts RevealPending(cohortDay, revealRound): nothing is popped, spent or latched, so an early
/// draw loses nothing, but it does not settle either. (An earlier engine popped first, and _payWinners then
/// skipped a winner whose round was unposted after its ticket was spent; that path is gone.) The keeper still
/// gates first, so a draw is sent once its beacons are on-chain: the reveal round of every cohort in the sweep
/// window that can still yield a winner (revealNeeded filters the cohorts that provably cannot), plus the draw
/// round. A RevealPending that comes back anyway goes to handleRevealPending, which posts the round it names.
///   opening:  drawDay = RAFFLE_ACCUM_DAYS, drawRound = raffle.drawRound(RAFFLE_ACCUM_DAYS - 1)
///   daily:    drawDay = target,            drawRound = raffle.drawRound(target)
/// Returns reveal TIMESTAMPS (mapped to rounds by the oracle's own roundAt, exactly as PackRegistry does)
/// and the draw round.
export function raffleDrawBeaconPlan({ drawDay, lifeDays, clock, drawRound, drawLabel }) {
  return {
    reveals: drawWindowCohorts(drawDay, lifeDays).map((c) => ({
      label: `cohort ${c} reveal`,
      cohort: c,
      ts: cohortRevealTimestamp(c, clock),
    })),
    draw: { label: drawLabel || `draw beacon for drawDay ${drawDay}`, round: BigInt(drawRound) },
  };
}

/// Does a draw need cohort `cohort`'s reveal beacon? `today` and `size` MUST be read at the same block.
/// A CLOSED cohort (cohort < today) with no live packs never yields a winner: PackRegistry.recordBuy mints only
/// into `_today()`, and a closed cohort's live set only shrinks as packs are drawn or ripped. So its reveal is
/// not needed, and skipping it keeps one unpostable round of an EMPTY cohort from holding a whole day's draw.
/// Any cohort with live packs, and today's still-open cohort, stays a hard gate.
export function revealNeeded({ cohort, today, size }) {
  return !(BigInt(cohort) < BigInt(today) && BigInt(size) === 0n);
}

/// Fire only when every needed beacon is on-chain. `entries` = [{ label, round, status }] where status is
/// what ensureBeacon returned: "available" | "pending" | "failed" | "unusable".
export function beaconGate(entries) {
  const missing = entries.filter((e) => e.status !== "available");
  return {
    ready: entries.length > 0 && missing.length === 0,
    missing,
    failing: missing.filter((e) => e.status !== "pending"),
  };
}

/// Has drand certainly published `round`? `roundAtNow` = oracle.roundAt(now), a CEIL (the first round at or
/// after now), so round R publishes when roundAtNow first reaches R+1. `marginRounds` more periods cover relay
/// propagation and a host clock running slightly ahead (3 rounds = 9s on quicknet).
export function isRoundPublished(round, roundAtNow, marginRounds = 1n) {
  return BigInt(round) + BigInt(marginRounds) < BigInt(roundAtNow);
}

/// A fetch that failed for a round the clock says is out. Every relay answering "not yet" (HTTP 404, or 425 Too Early
/// as api.drand.sh / api2 / api3 do: beacon.js notPublished) within `graceRounds` of publication is a lagging
/// relay or a fast host clock: "pending", not an error. Anything else is "failed".
export function beaconFetchVerdict({ round, roundAtNow, notPublished, graceRounds }) {
  return notPublished && BigInt(round) + BigInt(graceRounds) >= BigInt(roundAtNow) ? "pending" : "failed";
}

/// Cohorts the standalone reveal job keeps posted on chain-day `today`: the last `depth` closed cohorts.
export function revealJobCohorts(today, depth) {
  const t = BigInt(today);
  const n = BigInt(depth);
  if (t === 0n) return [];
  const from = t > n ? t - n : 0n;
  const out = [];
  for (let c = from; c <= t - 1n; c++) out.push(c);
  return out;
}

/// Periods whose settlement window has CLOSED, newest first: period p settles only during p+1, so the newest
/// closed one is current-2. Stops below `minPeriod`. The raffle passes RAFFLE_ACCUM_DAYS, because
/// runDraw(d) reverts BadDay for d < ACCUM_DAYS and the opening never writes drawn[], so those days are
/// never a daily-draw period and must not be reported as voided.
export function closedPeriods(current, depth, minPeriod = 0n) {
  const out = [];
  const cur = BigInt(current);
  for (let k = 0n; k < BigInt(depth); k++) {
    const p = cur - 2n - k;
    if (p < BigInt(minPeriod)) break;
    out.push(p);
  }
  return out;
}

/// Void-watch verdict for a closed, unsettled holder week, mirroring HolderDrawEngine.runDraw's no-pay
/// branches. The vault is read at CHECK time, not during the window, so this is a best effort:
///   empty   the collection is not launched or too small to seat WINNERS: nothing could ever be paid
///   no-pay  the pot (free balance capped by potCapAt) is below minPotAt, or no eligible holder could be seated
///   value   the week could have paid and did not: a real PERIOD VOIDED
/// `filled` is previewDraw(week).filled, or null when it could not be read (the alarm then stands).
export function holderVoidVerdict({ launched, totalMinted, free, capForWeek, minPotForWeek, filled }) {
  if (!launched || BigInt(totalMinted) < HOLDER_WINNERS) return { kind: "empty" };
  let pot = BigInt(free);
  if (pot > BigInt(capForWeek)) pot = BigInt(capForWeek);
  if (pot < BigInt(minPotForWeek) || pot / HOLDER_WINNERS === 0n) {
    return {
      kind: "no-pay",
      detail: `the holder vault's free balance ${free}, capped at potCapAt ${capForWeek}, is ${pot}: below `
        + `minPotAt ${minPotForWeek} (read now; the vault ships unseeded and fills from convert)`,
    };
  }
  if (filled !== null && filled !== undefined && BigInt(filled) === 0n) {
    return { kind: "no-pay", detail: "no eligible holder could be seated (previewDraw filled 0)" };
  }
  return { kind: "value" };
}

/// RaffleEngine.bucketBps(0), the Common bucket (`public pure`, mirrored like ACCUM_DAYS): runDraw's no-pay test
/// is `(pot * bucketBps(0)) / BPS < winnersPerDayAt(day)`.
export const RAFFLE_COMMON_BUCKET_BPS = 1000n;

/// Same shape for a closed, undrawn raffle day, mirroring RaffleEngine.runDraw's no-pay branch:
///   pot = min(free * capBpsAt(day) / BPS, potCapAt(day)); no-pay when pot < minPotAt(day) or the Common bucket
///   cannot pay winnersPerDayAt(day) winners 1 wei each. The vault is read at CHECK time (best effort, as above).
/// `live` is PackRegistry.liveCount(day) read now. Closed cohorts only shrink, so live > 0 now proves the window
/// had paid tickets; live == 0 is "empty" (a window that held only free entries is not alarmed: not computable
/// here without replaying the free block).
export function raffleVoidVerdict({ live, free, capBps, capForDay, minPotForDay, winnersForDay }) {
  if (BigInt(live) === 0n) return { kind: "empty" };
  let pot = (BigInt(free) * BigInt(capBps)) / BPS;
  if (pot > BigInt(capForDay)) pot = BigInt(capForDay);
  if (pot < BigInt(minPotForDay) || (pot * RAFFLE_COMMON_BUCKET_BPS) / BPS < BigInt(winnersForDay)) {
    return {
      kind: "no-pay",
      detail: `the raffle vault's free balance ${free} at ${capBps} bps, capped at potCapAt ${capForDay}, is a pot of `
        + `${pot}: below minPotAt ${minPotForDay} or too small for ${winnersForDay} winners (read now)`,
    };
  }
  return { kind: "value" };
}

/// Same shape for a closed, undistributed leaderboard week (LeaderboardEngine.distribute's no-pay branches).
export function leaderboardVoidVerdict({ boardCount, totalPoints, free, capForWeek, minPotForWeek }) {
  if (BigInt(boardCount) === 0n || BigInt(totalPoints) === 0n) return { kind: "empty" };
  let pot = BigInt(free);
  if (pot > BigInt(capForWeek)) pot = BigInt(capForWeek);
  if (pot === 0n || pot < BigInt(minPotForWeek)) {
    return {
      kind: "no-pay",
      detail: `the leaderboard vault's free balance ${free}, capped at potCapAt ${capForWeek}, is ${pot}: below `
        + `minPotAt ${minPotForWeek} (read now)`,
    };
  }
  return { kind: "value" };
}

/// Did period `period`'s settlement window (period+1) close BEFORE this keeper first read the engine's current
/// period `firstLook`? Such a period's vault verdict is read long after its window, so it is not evidence of
/// what the window held: a week that was no-pay while the vault was unseeded reads as "value" once it is funded.
export function closedBeforeWatch(period, firstLook) {
  return firstLook !== null && firstLook !== undefined && BigInt(period) + 2n <= BigInt(firstLook);
}

/// The spot guard needs CONVERT_PRICE_MIN_SAMPLES earlier samples, one per tick, all younger than
/// CONVERT_PRICE_MAX_AGE_S. A tick takes INTERVAL_SECONDS plus its own run time, so the age limit must cover
/// that many ticks with room to spare, or the guard warms up forever and convert never sends. Twice the bare
/// minimum is the floor.
export function spotMaxAgeFloorS(intervalS, minSamples) {
  return 2 * Number(intervalS) * Number(minSamples);
}

/// What is wrong with the Treasury keeper role, read-only. Nothing binds the role to CONVERT_PK onchain.
export function convertRoleProblems({ convertAddress, drawAddress, splitConfigured, convertIsKeeper, drawIsKeeper, keeperCount }) {
  const out = [];
  if (!convertIsKeeper) {
    out.push({
      fatal: true,
      msg: `the convert signer ${convertAddress} does NOT hold the Treasury keeper role. Every convert() reverts `
        + "NotKeeper: tax never converts, the prize vaults never fund, and the draws void under minPot. "
        + `Owner fix: Treasury.setKeeper(${convertAddress}, true).`,
    });
  }
  if (splitConfigured && convertAddress !== drawAddress && drawIsKeeper) {
    out.push({
      fatal: false,
      msg: `the DRAW key ${drawAddress} also holds the Treasury keeper role, so the privilege split is not in `
        + `effect. Owner fix: Treasury.setKeeper(${drawAddress}, false).`,
    });
  }
  if (convertIsKeeper && keeperCount !== undefined && BigInt(keeperCount) !== 1n) {
    out.push({
      fatal: false,
      msg: `Treasury.keeperCount() is ${keeperCount}, expected 1 (the convert key only). Review KeeperSet events.`,
    });
  }
  return out;
}

// ── PURE CONVERT MATH ───────────────────────────────────────────────────────────────────────────────

/// Floor `x` by `slippageBps`.
export function withSlippage(x, slippageBps) {
  return (BigInt(x) * (BPS - BigInt(slippageBps))) / BPS;
}

/// The hook's sell tax at `now`, mirroring QpullTaxHook._taxBps(false) exactly. Every
/// input is read from the HOOK (launchTime, SELL_STEP(), SELL_DECAY(), SELL_TAX_START_BPS, SELL_STEP_BPS,
/// TAX_BPS) and `now` is the timestamp of the block the quote was simulated at. The old mirror stepped from
/// PackRegistry.genesis on the host clock, and nothing ties go-live to genesis.
export function sellTaxBpsAt({ launchTime, now, sellStep, sellDecay, startBps, stepBps, floorBps }) {
  const lt = BigInt(launchTime);
  const t = BigInt(now);
  const floor = BigInt(floorBps);
  if (lt === 0n || t >= lt + BigInt(sellDecay)) return floor;
  if (t < lt) throw new RangeError(`block timestamp ${t} is before the hook's launchTime ${lt}`);
  if (BigInt(sellStep) === 0n) throw new RangeError("the hook's SELL_STEP() is 0");
  const decay = ((t - lt) / BigInt(sellStep)) * BigInt(stepBps);
  return decay >= BigInt(startBps) - floor ? floor : BigInt(startBps) - decay;
}

/// What a TAXED exact-in sell of gross WETH output G pays the seller: G - fee, fee = floor(G * t / BPS)
/// (QpullTaxHook.afterSwap, exact-in SELL branch, the one fee branch that rounds down; the others round up).
export function exemptSellNet(gross, taxBps) {
  const g = BigInt(gross);
  return g - (g * BigInt(taxBps)) / BPS;
}

/// The v4 quoter simulates leg 1 as a normal TAXED exact-in sell, but convert() sells through the
/// fee-EXEMPT QpullWethAdapter at 0%. The pool math is identical (the hook takes its fee from the output
/// AFTER the swap), so the exempt output is the taxed sell's gross G. Recover it EXACTLY: G - floor(G*t/BPS)
/// is non-decreasing in G with steps of 0 or 1, so each quote has one or two preimages. Return the SMALLEST,
/// so the floor built on it can never exceed the real exempt output, even at 0 slippage.
export function grossUpForExemptSell(taxedOut, taxBps) {
  const q = BigInt(taxedOut);
  const t = BigInt(taxBps);
  if (t < 0n || t >= BPS) throw new RangeError(`sell tax ${t} bps is outside [0, ${BPS})`);
  if (q <= 0n) return 0n;
  let g = (q * BPS) / (BPS - t);
  for (let i = 0; exemptSellNet(g, t) > q; i++) { if (i > 20_000) throw new Error("grossUpForExemptSell: no convergence"); g--; }
  for (let i = 0; exemptSellNet(g, t) < q; i++) { if (i > 20_000) throw new Error("grossUpForExemptSell: no convergence"); g++; }
  while (g > 0n && exemptSellNet(g - 1n, t) === q) g--;
  return g;
}

/// The keeper's WETH dust floor against the Treasury's per-call WETH cap: min(MIN_WETH_CONVERT, cap). A FULL
/// maxWethConvertPerCall slice is never dust, whatever MIN_WETH_CONVERT says: otherwise a cap set below the
/// floor (plausible, since the cap is sized to the shallow QUOTRON pool) would skip every tick as "dust" while
/// the backlog grew without limit.
export function wethDustFloor(minWethConvert, maxWethConv) {
  const m = BigInt(minWethConvert);
  const c = BigInt(maxWethConv);
  return m < c ? m : c;
}

/// Mirror of Treasury.convert()'s sizing (src/Treasury.sol, convert), plus the keeper-side dust floor.
///   skip/nothing  no QPULL leg and no WETH: convert() would revert BelowThreshold
///   skip/dust     WETH-only sweep whose UNCAPPED WETH balance is below wethDustFloor: not worth
///                 its gas. Never bisected. Because the floor is at most the cap, a skip/dust always means
///                 wethHeld < MIN_WETH_CONVERT: no convertible backlog is ever waiting behind it.
///   convert       qpullLeg says whether leg 1 (QPULL -> WETH) runs. Buy AND sell tax arrive as WETH,
///                 so the WETH-only sweep is the NORMAL path and the QPULL leg only sells QPULL someone DONATED
///                 to the Treasury (at or above convertThreshold).
export function convertPlan({ qpullBal, wethHeld, threshold, maxConv, maxWethConv, minWethConvert }) {
  const qb = BigInt(qpullBal);
  const wh = BigInt(wethHeld);
  const qpullLeg = qb > 0n && qb >= BigInt(threshold) && wh < BigInt(maxWethConv);
  const qpullIn = qpullLeg ? (qb > BigInt(maxConv) ? BigInt(maxConv) : qb) : 0n;
  const subThresholdQpull = qb > 0n && qb < BigInt(threshold);
  if (!qpullLeg && wh === 0n) return { action: "skip", why: "nothing", qpullLeg, qpullIn, subThresholdQpull };
  if (!qpullLeg) {
    const dustFloor = wethDustFloor(minWethConvert, maxWethConv);
    if (wh < dustFloor) {
      return { action: "skip", why: "dust", qpullLeg, qpullIn, wethOut: wh, dustFloor, subThresholdQpull };
    }
  }
  return { action: "convert", qpullLeg, qpullIn, subThresholdQpull };
}

/// The WETH leg 2 is sized from: every WETH held plus the FLOORED leg-1 output, capped at maxWethConvertPerCall.
/// Treasury.convert() reads wethOut from the ACTUAL post-leg-1 balance, and leg 1 may land anywhere down to
/// minWeth, so sizing from the optimistic quote could leave leg 2 with less input than its floor assumed.
export function leg2Basis({ wethHeld, qpullLeg, minWeth, maxWethConv }) {
  const w = BigInt(wethHeld) + (qpullLeg ? BigInt(minWeth) : 0n);
  return w > BigInt(maxWethConv) ? BigInt(maxWethConv) : w;
}

/// Treasury.convert(): teamWeth = wethOut * TEAM_BPS / BPS (floor); the prize leg swaps the rest.
export function prizeWethOf(wethOut, teamBps) {
  const w = BigInt(wethOut);
  return w - (w * BigInt(teamBps)) / BPS;
}

export function median(values) {
  const s = values.map(BigInt).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  if (!s.length) return null;
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2n;
}

/// Without this guard the floor is pure spot: both the quoter and bisection price off the pool state at the
/// read, so a price pushed down just before it lowers the floor one for one. Independent bound: compare a
/// fixed-size reference quote taken NOW against the median of the reference quotes of earlier ticks, and
/// hold if it is worse by more than maxDevBps. Only the downside is checked (a better price makes the floor
/// tighter, never looser). `samples` excludes the current block's sample.
///   { ok: true }                                     within tolerance (or maxDevBps = 0: disabled)
///   { ok: false, warming: true, have, need }         not enough history yet
///   { ok: false, median, devBps }                    current rate is devBps below the median
export function spotGuard(samples, current, { maxDevBps, minSamples }) {
  if (BigInt(maxDevBps) === 0n) return { ok: true, disabled: true };
  if (samples.length < Number(minSamples)) return { ok: false, warming: true, have: samples.length, need: Number(minSamples) };
  const med = median(samples);
  const cur = BigInt(current);
  if (med === null || med === 0n) return { ok: true, median: med };
  const least = (med * (BPS - BigInt(maxDevBps))) / BPS;
  if (cur >= least) return { ok: true, median: med };
  return { ok: false, median: med, devBps: ((med - cur) * BPS) / med };
}

const sameAddr = (a, b) => {
  try {
    return ethers.getAddress(String(a)) === ethers.getAddress(String(b));
  } catch {
    return false;
  }
};

/// The .env ASSERTIONS about the Treasury's own configuration. Blank values are unset.
export function treasuryEnvProblems({ qpull, weth, wethQuotron }, env = {}) {
  const out = [];
  const check = (name, raw, actual, what) => {
    const v = envValue(raw);
    if (v === undefined) return;
    if (!sameAddr(v, actual)) {
      out.push(`${name}=${v} in .env, but ${what} is ${actual}. The keeper reads it from the Treasury; `
        + `an .env value may only assert it. Remove ${name} or correct it`);
    }
  };
  check("QPULL", env.QPULL, qpull, "Treasury.qpull()");
  check("WETH", env.WETH, weth, "Treasury.weth()");
  check("WETH_QUOTRON_ADAPTER", env.WETH_QUOTRON_ADAPTER, wethQuotron, "Treasury.wethQuotron()");
  return out;
}

/// Checks that the quoted PoolKey is the adapter's own pool: the key is read verbatim from
/// QpullWethAdapter.poolKey(), and it must be the adapter's own sorted QPULL/WETH pair, on a hook that serves
/// that key, runs on the adapter's PoolManager and exempts that adapter. QPULL_POOL_FEE / _TICK_SPACING / _HOOK
/// in .env may only assert it. Empty array = OK.
export function poolBindingProblems(b, env = {}) {
  const out = [];
  const [lo, hi] = BigInt(b.treasuryQpull) < BigInt(b.treasuryWeth)
    ? [b.treasuryQpull, b.treasuryWeth] : [b.treasuryWeth, b.treasuryQpull];
  if (!sameAddr(b.adapterQpull, b.treasuryQpull) || !sameAddr(b.adapterWeth, b.treasuryWeth)) {
    out.push(`QpullWethAdapter ${b.adapter} trades ${b.adapterQpull}/${b.adapterWeth}, not the Treasury's `
      + `${b.treasuryQpull}/${b.treasuryWeth}`);
  }
  if (!sameAddr(b.key.currency0, lo) || !sameAddr(b.key.currency1, hi)) {
    out.push(`the adapter's pool key currencies ${b.key.currency0}/${b.key.currency1} are not the sorted QPULL/WETH pair`);
  }
  if (sameAddr(b.key.hooks, ethers.ZeroAddress)) out.push("the adapter's pool key has no hook");
  if (!sameAddr(b.hookExemptSender, b.adapter)) {
    out.push(`the pool hook ${b.key.hooks} exempts ${b.hookExemptSender}, not the adapter ${b.adapter}`);
  }
  if (!sameAddr(b.hookPoolManager, b.adapterPoolManager)) {
    out.push(`the pool hook runs on PoolManager ${b.hookPoolManager}, the adapter on ${b.adapterPoolManager}`);
  }
  if (BigInt(b.hookFee) !== BigInt(b.key.fee) || BigInt(b.hookTickSpacing) !== BigInt(b.key.tickSpacing)) {
    out.push(`the hook's canonical fee/tickSpacing ${b.hookFee}/${b.hookTickSpacing} differ from the adapter's key `
      + `${b.key.fee}/${b.key.tickSpacing}`);
  }
  if (!(BigInt(b.key.tickSpacing) > 0n)) out.push(`the adapter's pool key tickSpacing is ${b.key.tickSpacing}`);
  if (!(BigInt(b.sellStep) > 0n)) out.push("the hook's SELL_STEP() is 0");
  const num = (name, raw, actual) => {
    const v = envValue(raw);
    if (v === undefined) return;
    if (!/^-?\d+$/.test(v) || BigInt(v) !== BigInt(actual)) {
      out.push(`${name}=${v} in .env, but QpullWethAdapter.poolKey() says ${actual}. The key is read from the `
        + `adapter; remove ${name} or correct it`);
    }
  };
  num("QPULL_POOL_FEE", env.QPULL_POOL_FEE, b.key.fee);
  num("QPULL_POOL_TICK_SPACING", env.QPULL_POOL_TICK_SPACING, b.key.tickSpacing);
  const hookEnv = envValue(env.QPULL_POOL_HOOK);
  if (hookEnv !== undefined && !sameAddr(hookEnv, b.key.hooks)) {
    out.push(`QPULL_POOL_HOOK=${hookEnv} in .env, but QpullWethAdapter.poolKey().hooks is ${b.key.hooks}. `
      + "Remove QPULL_POOL_HOOK or correct it");
  }
  return out;
}

// ── CONFIG (process environment, after .env) ────────────────────────────────────────────────────────
//    Every knob is parsed here, once. A malformed value is a FATAL CONFIG error at startup, printed by NAME.
const CONFIG_ERRORS = [];
const cfg = (k) => envValue(process.env[k]);
function envUint(name, def, { min = 0n, max } = {}) {
  const raw = cfg(name);
  if (raw === undefined) return BigInt(def);
  if (!/^\d+$/.test(raw)) {
    CONFIG_ERRORS.push(`${name}=${raw} is not a whole number`);
    return BigInt(def);
  }
  const v = BigInt(raw);
  if (v < BigInt(min) || (max !== undefined && v > BigInt(max))) {
    CONFIG_ERRORS.push(`${name}=${raw} is outside [${min}, ${max ?? "no limit"}]`);
    return BigInt(def);
  }
  return v;
}

/// An address knob that is set must be an address. A malformed one used to reach ethers as an ENS name
/// and fail on every call; now it is a FATAL CONFIG at startup, by name.
function envAddress(name) {
  const raw = cfg(name);
  if (raw === undefined) return undefined;
  if (!ethers.isAddress(raw)) {
    CONFIG_ERRORS.push(`${name}=${raw} is not a valid address (40 hex digits, 0x-prefixed; mixed case must be the checksum)`);
    return undefined;
  }
  return ethers.getAddress(raw);
}
function envBool(name, def) {
  const v = (cfg(name) ?? String(def)).toLowerCase();
  if (v === "true") return true;
  if (v === "false") return false;
  CONFIG_ERRORS.push(`${name}=${v} must be true or false`);
  return def;
}

const ONCE = process.argv.includes("--once");
const FAILSAFE = process.argv.includes("--failsafe");

const RPC_URL = cfg("RPC_URL");
const KEEPER_PK = cfg("KEEPER_PK");
const CONVERT_PK = cfg("CONVERT_PK"); // optional second signer; see the privilege split below
const ORACLE = cfg("ORACLE"); // optional ASSERTION: the oracle is resolved from the contracts' drand()
const TREASURY = envAddress("TREASURY");
const RAFFLE_ENGINE = envAddress("RAFFLE_ENGINE");
const LEADERBOARD_ENGINE = envAddress("LEADERBOARD_ENGINE");
const HOLDER_ENGINE = envAddress("HOLDER_ENGINE");
const PACK_REGISTRY = envAddress("PACK_REGISTRY");
const NFT_COLLECTION = envAddress("NFT_COLLECTION");
const CLAIM_MANAGER = envAddress("CLAIM_MANAGER"); // optional: otherwise resolved from an engine's claimManager()
const MULTICALL3 = envAddress("MULTICALL3") ?? "0xcA11bde05977b3631167028862bE2a173976CA11";
// QuoPods. Optional: absent until the pods ship, and every pods job no-ops without them.
const POD_STAKING = envAddress("POD_STAKING");
const POD_MINT = envAddress("POD_MINT");
const POD_LOCK = envAddress("POD_LOCK"); // QuoPodLiquidityLock: its collectFees pays the 0.3% swap fee to pods
const ENABLE_SWEEP = envBool("ENABLE_SWEEP", true);
const INTERVAL_SECONDS = Number(envUint("INTERVAL_SECONDS", 60, { min: 1n }));
// Convert: "false" (default), "true", or "simulate" (quote and simulate convert() every tick, send nothing).
const CONVERT_MODE = (() => {
  const v = (cfg("ENABLE_CONVERT") ?? "false").toLowerCase();
  if (v === "true") return "on";
  if (v === "false") return "off";
  if (v === "simulate") return "simulate";
  CONFIG_ERRORS.push(`ENABLE_CONVERT=${v} must be true, false or simulate`);
  return "off";
})();
/// --once NEVER sends convert() (a single pass has no spot history, no stall tracking and no failure streak, and
/// with VIEW_QUOTER unset it used to send on bisection floors). ENABLE_CONVERT=true under --once therefore reports
/// the floors and the convert() simulation exactly as ENABLE_CONVERT=simulate does, and sends nothing.
const CONVERT_REPORT_ONLY = CONVERT_MODE === "simulate" || (ONCE && CONVERT_MODE === "on");
const REPORT_TAG = CONVERT_MODE === "simulate" ? "simulate" : "--once";
const REPORT_WHY = CONVERT_MODE === "simulate" ? "ENABLE_CONVERT=simulate" : "--once never sends convert(); run the loop to send";
// Leg 2 (WETH -> QUOTRON) is quoted by Quotron's live View quoter (RH mainnet 0xb8960fdC8A0Be155d196C2795b75747763562df2).
// It is also the Quotron price check of the spot guard: under CONVERT_SPOT_UNAVAILABLE=hold, unset means HOLD.
const VIEW_QUOTER = envAddress("VIEW_QUOTER");
// Leg 1 (QPULL -> WETH) is quoted by a v4 quoter for the QPULL/WETH pool. OPTIONAL: the hook takes every tax in
// WETH, so the leg only sells QPULL donated to the Treasury, and without a quoter its floor comes from bisection.
const QPULL_QUOTER = envAddress("QPULL_QUOTER");
const CONVERT_SLIPPAGE = envUint("CONVERT_SLIPPAGE_BPS", 100, { max: 9999n }); // floor on BOTH legs
// WETH dust floor:
// convert()'s threshold gates only the QPULL leg. The WETH leg's guard is `wethHeld == 0`, which blocks a ZERO
// balance but not a DUST one, so a naive keeper fires the full fee-charging WETH->QUOTRON swap on a few wei.
// The contract deliberately keeps no second threshold, so the floor lives here. QUOTRON's fee is PROPORTIONAL,
// so batching never amortises it: the real cost of a dust convert is gas, which is ours.
// It is clamped to the Treasury's maxWethConvertPerCall at run time (wethDustFloor): a full slice is never dust.
const MIN_WETH_CONVERT = envUint("MIN_WETH_CONVERT_WEI", "10000000000000000"); // 0.01 WETH
const PRICE_DEV_BPS = envUint("CONVERT_PRICE_DEVIATION_BPS", 500, { max: 9999n }); // 0 disables the spot guard
const PRICE_WINDOW = Number(envUint("CONVERT_PRICE_WINDOW", 15, { min: 1n, max: 1000n }));
const PRICE_MIN_SAMPLES = Number(envUint("CONVERT_PRICE_MIN_SAMPLES", 5, { min: 1n, max: 1000n }));
// Unset, the age limit is derived from the tick interval, so a slow INTERVAL_SECONDS still warms the guard.
const PRICE_MAX_AGE_FLOOR_S = spotMaxAgeFloorS(INTERVAL_SECONDS, PRICE_MIN_SAMPLES);
const PRICE_MAX_AGE_S = Number(envUint("CONVERT_PRICE_MAX_AGE_S", Math.max(1800, PRICE_MAX_AGE_FLOOR_S), { min: 60n }));
if (PRICE_DEV_BPS !== 0n && CONVERT_MODE !== "off" && !FAILSAFE && PRICE_MAX_AGE_S < PRICE_MAX_AGE_FLOOR_S) {
  CONFIG_ERRORS.push(`CONVERT_PRICE_MAX_AGE_S=${PRICE_MAX_AGE_S} is below 2 x INTERVAL_SECONDS (${INTERVAL_SECONDS}) x `
    + `CONVERT_PRICE_MIN_SAMPLES (${PRICE_MIN_SAMPLES}) = ${PRICE_MAX_AGE_FLOOR_S}. The spot guard would age out its own `
    + "history before it had enough samples, and convert would never send. Raise it, or unset it to derive it");
}
// What the spot guard does when its price check is unavailable (the owner chose fail closed as the default):
//   hold (default, fail closed)  leg 2: VIEW_QUOTER not set, or its reference quote failed this tick -> HOLD.
//                                leg 1: a CONFIGURED QPULL_QUOTER that gives no reference quote -> HOLD, whatever
//                                the cause: the quote fails, the quoter is on a different PoolManager than the
//                                adapter, the QPULL/WETH pool binding cannot be read or is wrong, the pool is not
//                                initialized.
//   proceed                      convert on floors from the pool state alone (quoted or bisected), unguarded.
// Donated QPULL with no QPULL_QUOTER configured at all is never guarded (that quoter is optional), and the keeper
// says so hourly.
const SPOT_UNAVAILABLE = (() => {
  const v = (cfg("CONVERT_SPOT_UNAVAILABLE") ?? "hold").toLowerCase();
  if (v === "hold" || v === "proceed") return v;
  CONFIG_ERRORS.push(`CONVERT_SPOT_UNAVAILABLE=${v} must be hold or proceed`);
  return "hold";
})();
const PRICE_REF_WETH = envUint("CONVERT_PRICE_REF_WETH_WEI", MIN_WETH_CONVERT > 0n ? MIN_WETH_CONVERT : 10n ** 16n, { min: 1n });
const PRICE_REF_QPULL = envUint("CONVERT_PRICE_REF_QPULL_WEI", 1000n * 10n ** 18n, { min: 1n });
const CONVERT_FAIL_ALARM = Number(envUint("CONVERT_FAIL_ALARM", 3, { min: 1n }));
const CONVERT_STALL_ALARM_S = Number(envUint("CONVERT_STALL_ALARM_H", 6, { min: 1n })) * 3600;
// Gas floors for BOTH hot signers.
const KEEPER_GAS_FLOOR = envUint("KEEPER_GAS_FLOOR_WEI", "20000000000000000"); // 0.02 ETH
const CONVERT_GAS_FLOOR = envUint("CONVERT_GAS_FLOOR_WEI", "5000000000000000"); // 0.005 ETH
const HEALTH_INTERVAL_S = Number(envUint("HEALTH_INTERVAL_S", 300, { min: 30n })); // health watch AND heartbeat cadence
const CLOCK_SKEW_WARN_S = envUint("CLOCK_SKEW_WARN_S", 60, { min: 1n }); // host clock behind OR ahead of the latest block
// QuoPods: how often to re-settle every pod, and how many ids per transaction.
const POD_POKE_INTERVAL_S = Number(envUint("POD_POKE_INTERVAL_S", 4 * 60 * 60, { min: 60n }));
const POD_POKE_BATCH = Number(envUint("POD_POKE_BATCH", 50, { min: 1n, max: 500n }));
// QuoPods: how often to collect the locked pool's swap fees (WETH half to pods, QPOD half burned).
const POD_FEE_INTERVAL_S = Number(envUint("POD_FEE_INTERVAL_S", 6 * 60 * 60, { min: 300n }));
// How long fire() waits for a sent transaction's receipt. ethers 6 tx.wait() has no timeout by default, so a
// transaction the RPC acknowledged and never included froze the serial loop (every draw, beacon, convert and alarm)
// with nothing logged. Robinhood Chain includes a transaction in about a second; 2 minutes only trips on a lost one.
const SEND_WAIT_TIMEOUT_MS = Number(envUint("SEND_WAIT_TIMEOUT_MS", 120_000, { min: 1000n, max: 3_600_000n }));
const ALARM_REPEAT_S = Number(envUint("ALARM_REPEAT_S", 900, { min: 60n }));
// Beacons.
const DRAND_MARGIN_ROUNDS = envUint("DRAND_MARGIN_ROUNDS", 3, { min: 1n, max: 1000n });
const DRAND_GRACE_ROUNDS = envUint("DRAND_GRACE_ROUNDS", 40, { min: 0n, max: 100_000n });
// Validated here and passed to beacon.js explicitly (beacon.js alone falls back to its default on a bad value).
const DRAND_TIMEOUT_MS = Number(envUint("DRAND_TIMEOUT_MS", 10_000, { min: 100n, max: 300_000n }));
// Transient RPC failures at startup are retried with backoff for up to this long before FATAL.
const STARTUP_RETRY_S = Number(envUint("STARTUP_RETRY_S", 600));
const NOOP_BASE_S = Number(envUint("NOOP_BACKOFF_BASE_S", 60, { min: 1n })); // see NO-OP BACKOFF
const NOOP_MAX_S = Math.max(NOOP_BASE_S, Number(envUint("NOOP_BACKOFF_MAX_S", 1800, { min: 1n })));
const SWEEP_INTERVAL_S = Number(envUint("SWEEP_INTERVAL_S", 3600, { min: 60n })); // see EXPIRED-CLAIM SWEEP
const SWEEP_MAX_PER_TICK = Number(envUint("SWEEP_MAX_PER_TICK", 10, { min: 1n }));
const VOID_BACKSCAN = Number(envUint("VOID_BACKSCAN", 14, { min: 1n })); // see VOIDED-PERIOD ALARM
if (PRICE_MIN_SAMPLES > PRICE_WINDOW) {
  CONFIG_ERRORS.push(`CONVERT_PRICE_MIN_SAMPLES=${PRICE_MIN_SAMPLES} exceeds CONVERT_PRICE_WINDOW=${PRICE_WINDOW}`);
}
for (const [name, value] of [["KEEPER_PK", KEEPER_PK], ["CONVERT_PK", CONVERT_PK]]) {
  const p = privateKeyProblem(name, value);
  if (p) CONFIG_ERRORS.push(p);
}
const RETIRED_ENV = { SELL_DECAY_SECS: "the sell-tax schedule is read from the pool hook (SELL_STEP/SELL_DECAY/launchTime)" };

let CHAIN_ID = null; // bigint, set in main()

if (!IMPORT_ONLY && (!RPC_URL || !KEEPER_PK)) {
  console.error(`Missing config: set RPC_URL and KEEPER_PK in ${ENV_PATH}`);
  process.exit(1);
}

// cacheTimeout -1: ethers otherwise answers an identical read from a 250 ms cache, and that includes the
// pending nonce. After a failed send the nonce is re-read, but a send inside 250 ms of the
// previous one got the STALE count back and failed "nonce has already been used" (found on a
// pods fork rehearsal: collectFees 202 ms after a reverted pokeMany).
const provider = RPC_URL ? new ethers.JsonRpcProvider(RPC_URL, undefined, { cacheTimeout: -1 }) : null;
// PRIVILEGE SPLIT. Both signers are unavoidably HOT: an autonomous keeper signs unattended every tick, so
// its key lives on the server. What we CAN remove is privilege. Of everything this keeper calls, only
// Treasury.convert() is gated (onlyKeeper); submitBeacon, registerSuperRare, runDraw, distribute,
// runOpeningDraw and sweepExpired are permissionless.
//
//   drawWallet     KEEPER_PK   registered NOWHERE, holds only gas, online every tick. A stolen draw key
//                              gains nothing: every call it makes is already open to any address.
//   convertWallet  CONVERT_PK  the ONLY address in Treasury.setKeeper (checked at startup and before every
//                              convert). setKeeper stays rotatable after lockRouting, so it can be revoked.
//
// CONVERT_PK is optional: unset, convert falls back to the draw key and the keeper says so at startup.
function makeWallet(name, pk) {
  if (!pk || !provider || privateKeyProblem(name, pk)) return null; // a malformed key is in CONFIG_ERRORS
  try {
    return new ethers.Wallet(pk.startsWith("0x") ? pk : `0x${pk}`, provider);
  } catch {
    CONFIG_ERRORS.push(`${name} is 64 hex digits but not a valid secp256k1 private key. Its value is not printed.`);
    return null;
  }
}
const drawWallet = makeWallet("KEEPER_PK", KEEPER_PK);
const convertWallet = CONVERT_PK ? makeWallet("CONVERT_PK", CONVERT_PK) : drawWallet;

if (!IMPORT_ONLY && CONFIG_ERRORS.length) {
  for (const p of CONFIG_ERRORS) console.error(`FATAL CONFIG: ${p}`);
  process.exit(1);
}

// Every permissionless job signs with the draw key. Imported without a key (tests), every binding is
// read-only on the provider and any send fails loudly; run as a program, main() cannot start without KEEPER_PK.
//
// NONCES. A bare ethers.Wallet asks the provider for eth_getTransactionCount(pending) on every send, and
// ethers 6 AbstractProvider caches IDENTICAL requests for cacheTimeout (250 ms). When one tick sends two txs back to
// back and the first is mined instantly (tx.wait() returns inside those 250 ms), the second send reads the CACHED
// nonce and fails "nonce has already been used": reproduced on anvil (bare Wallet: 1 of 3 sends ok; NonceManager:
// 3 of 3). It cost reveal beacons and holder beacons on real ticks. So every signer is wrapped in ONE
// ethers.NonceManager, which counts locally from the first read; fire() resets it after a failed send so a
// transaction that never left (or was dropped) cannot leave a nonce gap behind. When both jobs sign for ONE address
// they must share ONE NonceManager, or the two counters collide.
// "One address" is compared by ADDRESS. The old test was object identity (convertWallet === drawWallet), which
// only holds when CONVERT_PK is unset: CONVERT_PK set to the same key as KEEPER_PK builds a second Wallet object, and
// two managers then counted nonces for one account (every switch between a draw and a convert cost a "nonce too low"
// rejection). The same-address case is still announced at startup (the privilege split is not in effect).
const drawSigner = drawWallet ? new ethers.NonceManager(drawWallet) : null;
const signsAsDrawKey = !!convertWallet && !!drawWallet && convertWallet.address === drawWallet.address;
const convertSigner = signsAsDrawKey ? drawSigner : (convertWallet ? new ethers.NonceManager(convertWallet) : null);
const wallet = drawSigner ?? provider;
const convertRunner = convertSigner ?? provider;
let testAddresses = null; // IMPORT_ONLY harnesses only: stands in for the signer addresses
const drawAddress = () => drawWallet?.address ?? testAddresses?.draw ?? null;
const convertAddress = () => convertWallet?.address ?? testAddresses?.convert ?? drawAddress();

// ── RATE-LIMITED ALARMS ─────────────────────────────────────────────────────────────────────────────
//    An alarm is printed when its signature changes, and repeated every ALARM_REPEAT_S (or `repeatS`) while it
//    holds. clearAlarm prints a recovery line once. So a condition that persists is never silent, and a
//    per-tick condition is not a line every 60 seconds.
const alarms = new Map(); // key -> { sig, at }
function alarm(key, sig, message, { level = "error", repeatS = ALARM_REPEAT_S } = {}) {
  const now = Date.now() / 1000;
  const prev = alarms.get(key);
  if (prev && prev.sig === sig && now - prev.at < repeatS) return;
  alarms.set(key, { sig, at: now });
  (level === "error" ? logError : log)(message);
}
function clearAlarm(key, recovered) {
  if (alarms.delete(key) && recovered) log(recovered);
}

// ── CONTRACTS ───────────────────────────────────────────────────────────────────────────────────────
const oracleAbi = [
  "function submitBeacon(uint64,bytes,bytes) external",
  "function isAvailable(uint64) view returns (bool)",
  "function roundAt(uint256) view returns (uint64)",
];
const mockOracleAbi = ["function setBeacon(uint64,bytes32) external"];
const drandGetterAbi = ["function drand() view returns (address)"];
const raffleAbi = [
  "function runDraw(uint32) external",
  "function runOpeningDraw(bool forgoIfUnderfunded) external",
  "function drawn(uint32) view returns (bool)", // read back after a send: the no-pay branches never set it
  "function currentDay() view returns (uint32)",
  "function drawRound(uint32) view returns (uint64)",
  "function openingCapBps() view returns (uint256)",
  "function openingDone() view returns (bool)",
  "function openingMinPot() view returns (uint256)",
  "function vault() view returns (address)",
  "function packs() view returns (address)",
  // the scheduled (N-1) values runDraw(day) reads: the void watch's no-pay verdict
  "function capBpsAt(uint256) view returns (uint256)",
  "function potCapAt(uint256) view returns (uint256)",
  "function minPotAt(uint256) view returns (uint256)",
  "function winnersPerDayAt(uint256) view returns (uint256)",
];

const prizeVaultAbi = ["function freeBalance() view returns (uint256)"];
const leaderboardAbi = [
  "function distribute(uint256) external",
  "function registry() view returns (address)",
  "function currentWeek() view returns (uint256)",
  "function distributed(uint256) view returns (bool)", // same: distribute() leaves it false on a no-pay miss
  "function vault() view returns (address)",
  "function potCapAt(uint256) view returns (uint256)",
  "function minPotAt(uint256) view returns (uint256)",
];
const treasuryAbi = ["function convert(uint256,uint256) external"];
// Read-only role views.
const treasuryRoleAbi = [
  "function isKeeper(address) view returns (bool)",
  "function keeperCount() view returns (uint256)",
];
const boardAbi = [
  "function boardCount(uint256) view returns (uint256)",
  "function totalPoints(uint256) view returns (uint256)",
];

let oracle = null; // resolved from the contracts' drand() at startup (resolveOracle)
const raffle = RAFFLE_ENGINE && new ethers.Contract(RAFFLE_ENGINE, raffleAbi, wallet);
const leaderboard = LEADERBOARD_ENGINE && new ethers.Contract(LEADERBOARD_ENGINE, leaderboardAbi, wallet);
// HolderDrawEngine (Option C): O(1) beacon-derived weekly draw, no snapshot step.
const holderAbi = [
  "function runDraw(uint256) external",
  "function currentPeriod() view returns (uint256)",
  "function drawRound(uint256) view returns (uint64)",
  "function drawn(uint256) view returns (bool)",
  "function vault() view returns (address)",
  "function potCapAt(uint256) view returns (uint256)",
  "function minPotAt(uint256) view returns (uint256)",
  "function previewDraw(uint256) view returns (uint256[5] won, address[5] winner, uint256 filled)",
];
const holder = HOLDER_ENGINE && new ethers.Contract(HOLDER_ENGINE, holderAbi, wallet);
/// QuoPods. `pokeMany` is PERMISSIONLESS, so this belongs in failsafe alongside the draws.
const podStakingAbi = [
  "function pokeMany(uint256[] calldata podIds)",
  "function activePods() view returns (uint256)",
  "function totalEffective() view returns (uint256)",
];
const podMintAbi = ["function totalMinted() view returns (uint256)", "function failed() view returns (bool)"];
const podStaking = POD_STAKING && new ethers.Contract(POD_STAKING, podStakingAbi, wallet);
const podLockAbi = ["function collectFees() returns (uint256 wethToPods, uint256 qpodBurned)", "function seeded() view returns (bool)"];
const podLock = POD_LOCK && new ethers.Contract(POD_LOCK, podLockAbi, wallet);
const podMint = POD_MINT && new ethers.Contract(POD_MINT, podMintAbi, provider);
// the ONE privileged binding: convert() is onlyKeeper, so it signs with the convert key
const treasury = TREASURY && new ethers.Contract(TREASURY, treasuryAbi, convertRunner);
const treasuryRole = TREASURY && new ethers.Contract(TREASURY, treasuryRoleAbi, provider);

// convert() configuration and quoting: all read-only (provider).
const treasuryViewAbi = [
  "function convertThreshold() view returns (uint256)",
  "function maxConvertPerCall() view returns (uint256)",
  "function maxWethConvertPerCall() view returns (uint256)",
  "function qpull() view returns (address)",
  "function weth() view returns (address)",
  "function qpullWeth() view returns (address)",
  "function wethQuotron() view returns (address)",
  "function TEAM_BPS() view returns (uint256)",
];
const erc20BalAbi = ["function balanceOf(address) view returns (uint256)"];
// Quotron View quoter: mirrors the router's buyExactEth (the fee is per-payer, so quote AS the adapter).
const viewQuoterAbi = [
  "function quoteBuyExactEth(uint256 ethIn, address payer) view returns (uint256 quotronOut, uint256 feeBps, uint256 feeWeth, uint256 poolWethIn)",
];
// v4 quoter (leg 1). quoteExactInputSingle is non-view by design; call it with staticCall.
const v4QuoterAbi = [
  "function quoteExactInputSingle((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) returns (uint256 amountOut, uint256 gasEstimate)",
  "function poolManager() view returns (address)",
];
const qpullAdapterAbi = [
  "function poolKey() view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
  "function poolKeySet() view returns (bool)",
  "function poolManager() view returns (address)",
  "function qpull() view returns (address)",
  "function weth() view returns (address)",
];
const taxHookAbi = [
  "function launchTime() view returns (uint256)",
  "function SELL_STEP() view returns (uint256)",
  "function SELL_DECAY() view returns (uint256)",
  "function SELL_TAX_START_BPS() view returns (uint256)",
  "function SELL_STEP_BPS() view returns (uint256)",
  "function TAX_BPS() view returns (uint256)",
  "function canonicalFee() view returns (uint24)",
  "function canonicalTickSpacing() view returns (int24)",
  "function exemptSender() view returns (address)",
  "function poolManager() view returns (address)",
];
const treasuryView = TREASURY && new ethers.Contract(TREASURY, treasuryViewAbi, provider);
const viewQuoter = VIEW_QUOTER && new ethers.Contract(VIEW_QUOTER, viewQuoterAbi, provider);
const qpullQuoter = QPULL_QUOTER && new ethers.Contract(QPULL_QUOTER, v4QuoterAbi, provider);

// Super Rare auto-entry index (spec §16). registerSuperRare is permissionless + idempotent (it re-verifies
// rarityOf==3 on-chain and skips already-indexed ids), so the keeper can safely (re)build the index. This
// is MANDATORY: without it every Super Rare's daily auto-entry silently resolves to 0.
const nftAbi = [
  "function totalMinted() view returns (uint256)",
  "function rarityOf(uint256) view returns (uint8)",
  "function revealRound() view returns (uint64)",
  "function launched() view returns (bool)", // the holder void alarm reads it
];
const packRegAbi = [
  "function registerSuperRare(uint256[]) external",
  "function superRareCount() view returns (uint256)",
  "function srIndexed(uint256) view returns (bool)",
  // clock + cohorts, all read from the chain (loadChainClock, runCohortReveals, the raffle beacon gate)
  "function dayLength() view returns (uint256)",
  "function revealDelay() view returns (uint256)",
  "function genesis() view returns (uint256)",
  "function LIFE_DAYS() view returns (uint32)",
  "function RIP_XP_WINDOW() view returns (uint32)",
  "function today() view returns (uint32)",
  "function cohortSize(uint32) view returns (uint256)",
  "function liveCount(uint32) view returns (uint256)",
];
const nft = NFT_COLLECTION && new ethers.Contract(NFT_COLLECTION, nftAbi, wallet);
const packReg = PACK_REGISTRY && new ethers.Contract(PACK_REGISTRY, packRegAbi, wallet);
const SR_CHUNK = 100; // ids per registerSuperRare tx (the ~2% SR set is tiny; one tx usually suffices)

/// Exported for the ABI-coverage check: every method this file calls on a contract must be declared here.
export const ABIS = Object.freeze({
  oracleAbi, mockOracleAbi, drandGetterAbi, raffleAbi, prizeVaultAbi, leaderboardAbi, treasuryAbi,
  treasuryRoleAbi, boardAbi, holderAbi, treasuryViewAbi, erc20BalAbi, viewQuoterAbi, v4QuoterAbi,
  qpullAdapterAbi, taxHookAbi, nftAbi, packRegAbi,
});

// ── CHAIN-DERIVED CONFIG ────────────────────────────────────────────────────────────────────────────
//    Set once by loadChainClock / resolveOracle at startup. Every value comes from the contracts.
let DAY = 0n;
let genesis = 0n;
let revealDelay = 0n;
let LIFE_DAYS = 0n; // PackRegistry.LIFE_DAYS
let RIP_XP_WINDOW = 0n; // PackRegistry.RIP_XP_WINDOW
const chainClock = () => ({ genesis, dayLength: DAY, revealDelay });

// ── STARTUP: THE CLOCK AND THE ORACLE COME FROM THE CONTRACTS ───────────────────────────────────────

/// A read at startup is retried with backoff (2s doubling to 60s) for up to STARTUP_RETRY_S before
/// the caller declares FATAL. A rate limit or a 5xx at boot is not a config error, and a fast FATAL exit
/// loop trips systemd's StartLimitBurst / pm2's max_restarts and leaves the keeper down. A wrong address
/// keeps failing and still ends FATAL, just later. A method missing from an ABI (TypeError) is a bug: thrown now.
async function readAtStartup(label, fn) {
  const until = Date.now() + STARTUP_RETRY_S * 1000;
  let wait = 2000;
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (e instanceof TypeError) throw e;
      if (Date.now() + wait > until) throw e;
      logError(`startup: ${label} failed (attempt ${attempt}: ${e.shortMessage || e.message}); retrying in `
        + `${wait / 1000}s, for up to STARTUP_RETRY_S=${STARTUP_RETRY_S}s in all`);
      await sleep(wait);
      wait = Math.min(wait * 2, 60_000);
    }
  }
}

/// The clock: genesis, dayLength and revealDelay are ALWAYS read from PackRegistry; .env may only assert them.
/// A wrong clock derives the wrong cohort reveal rounds. The engine is not fooled (it reverts
/// RevealPending for the real round and pops nothing), but the keeper would post rounds no pack is sealed to
/// and hold each draw on them: a draw held on a round that publishes after its window voids that day.
/// Refuses to run on a mismatch, or on a read that still fails after STARTUP_RETRY_S.
async function loadChainClock() {
  if (!packReg) {
    logError("*** FATAL CONFIG: PACK_REGISTRY is not set. The keeper's clock (genesis, dayLength, revealDelay) "
      + "and every cohort reveal round come from PackRegistry; it cannot run without it. ***");
    return false;
  }
  let chain;
  let life;
  let ripWindow;
  try {
    const [g, d, rd, l, rw] = await readAtStartup(`reading the clock from PACK_REGISTRY=${PACK_REGISTRY}`, () => Promise.all([
      packReg.genesis(), packReg.dayLength(), packReg.revealDelay(), packReg.LIFE_DAYS(), packReg.RIP_XP_WINDOW(),
    ]));
    chain = { genesis: BigInt(g), dayLength: BigInt(d), revealDelay: BigInt(rd) };
    life = BigInt(l);
    ripWindow = BigInt(rw);
  } catch (e) {
    logError(`*** FATAL CONFIG: could not read the clock from PACK_REGISTRY=${PACK_REGISTRY} `
      + `(${e.shortMessage || e.message}). Either the RPC is down or the address is not a PackRegistry. ***`);
    return false;
  }
  const problems = clockProblems(chain, { GENESIS: process.env.GENESIS, REVEAL_DELAY: process.env.REVEAL_DELAY, DAY_LENGTH: process.env.DAY_LENGTH });
  if (!(life > 0n)) problems.push(`PackRegistry.LIFE_DAYS() is ${life}`);
  if (problems.length) {
    for (const p of problems) logError(`*** FATAL CONFIG: ${p}. ***`);
    return false;
  }
  if (raffle) {
    // The cohort reveal rounds are computed from THIS registry, so it must be the raffle's own.
    try {
      const paired = await readAtStartup("reading RAFFLE_ENGINE.packs()", () => raffle.packs());
      if (ethers.getAddress(paired) !== ethers.getAddress(PACK_REGISTRY)) {
        logError(`*** FATAL CONFIG: RAFFLE_ENGINE.packs() is ${paired} but PACK_REGISTRY=${PACK_REGISTRY}. ***`);
        return false;
      }
    } catch (e) {
      logError(`*** FATAL CONFIG: could not read RAFFLE_ENGINE.packs() (${e.shortMessage || e.message}). ***`);
      return false;
    }
  }
  genesis = chain.genesis;
  DAY = chain.dayLength;
  revealDelay = chain.revealDelay;
  LIFE_DAYS = life;
  RIP_XP_WINDOW = ripWindow;
  log(`clock from PackRegistry: genesis=${genesis} dayLength=${DAY}s revealDelay=${revealDelay}s `
    + `LIFE_DAYS=${LIFE_DAYS} RIP_XP_WINDOW=${RIP_XP_WINDOW}`);
  return true;
}

/// The oracle is whatever the contracts read (drand() on every configured raffle, registry, holder
/// engine and NFT). They must agree, and ORACLE in .env may only assert the result.
async function resolveOracle() {
  const sources = [
    ["RAFFLE_ENGINE", RAFFLE_ENGINE],
    ["PACK_REGISTRY", PACK_REGISTRY],
    ["HOLDER_ENGINE", HOLDER_ENGINE],
    ["NFT_COLLECTION", NFT_COLLECTION],
  ].filter(([, a]) => a);
  const readings = [];
  for (const [label, addr] of sources) {
    try {
      const a = await readAtStartup(`reading drand() from ${label}`,
        () => new ethers.Contract(addr, drandGetterAbi, provider).drand());
      readings.push({ label: `${label}.drand()`, address: a });
    } catch (e) {
      logError(`*** FATAL CONFIG: could not read drand() from ${label}=${addr} (${e.shortMessage || e.message}). `
        + "Either the RPC is down or the address is not this protocol's contract. ***");
      return false;
    }
  }
  const r = resolveOracleAddress(readings, ORACLE);
  if (r.fatal) {
    logError(`*** FATAL CONFIG: ${r.fatal}. ***`);
    return false;
  }
  if (r.note) log(r.note);
  if (!r.address) return true;
  oracle = new ethers.Contract(r.address, oracleAbi, wallet);
  log(`oracle ${r.address} (from ${readings.map((x) => x.label).join(", ")}${ORACLE ? "; ORACLE in .env matches" : ""})`);
  try {
    await oracleInterface();
  } catch (e) {
    logError(`oracle: could not read its bytecode at startup (${e.shortMessage || e.message}); re-checked on every beacon`);
  }
  return true;
}

// Simulate, then send. Returns true only if a tx was broadcast and confirmed.
//  - A simulated revert returns false: not callable now. Its reason is logged when it changes for `name`
//    (so a permanent revert is visible once, without a line per tick), or handed to `onRevert`.
//  - A transport failure or a method missing from the ABI is thrown, never "not callable".
//  - A JSON-RPC error object on the eth_call (rate limit, "header not found") reaches here as CALL_EXCEPTION
//    and cannot be told apart from a revert without data (see isRevertError): it returns false and is logged
//    as "not callable now (reverted without data)", once per change of reason. Nothing is latched on it:
//    the next tick simulates again.
//  - A sent transaction that has no receipt after SEND_WAIT_TIMEOUT_MS returns false with an ERROR naming its hash and
//    nonce, exactly like a failed send: the nonce is re-read and nothing is latched. Its { hash, nonce, from }
//    is remembered under `name`, and while that transaction is still pending the job does not send again (see
//    TIMED-OUT SENDS below): `onHeld` is called and false is returned without a simulation.
//  - A transaction REPLACED by another one at its nonce (ethers TRANSACTION_REPLACED: another process or a manual send
//    on the same key) is logged as replaced, never as reverted. It returns true only when the replacement is this same
//    call ("repriced") and succeeded.
const lastRevert = new Map(); // name -> last logged revert reason
const sendCounts = { sent: 0, confirmed: 0, failed: 0, timedOut: 0, replaced: 0 }; // since the last heartbeat line
/// The default handling of a simulated revert: log it when its reason changes for `name`.
function noteRevert(name, reason) {
  if (lastRevert.get(name) === reason) return;
  if (lastRevert.size > 1000) lastRevert.clear();
  lastRevert.set(name, reason);
  log(`${name}: not callable now (${reason})`);
}

// ── TIMED-OUT SENDS ──────────────────────────────────────────────────────────────────────────────────
//    A timeout cannot tell a slow transaction from a dropped one. Before this, the next tick's simulation (which reads
//    the latest block) still passed while the first transaction was pending, so fire() sent the call again; when the
//    RPC still counted the first one as pending, the copy took the next nonce, and if the first then landed the copy
//    reverted on chain (a draw) or converted a second slice on a floor quoted before the first landed (a convert).
//    So a timed-out transaction is remembered per job name, and the job holds while it is still pending. The record
//    is dropped once the transaction is mined, once its nonce is used by anything, or once the RPC no longer knows
//    it AND nothing is pending at its nonce (then a new send reuses that nonce and cannot land twice). A record is
//    checked on the job's next attempt and at the start of every tick (runTimedOutSends), so a job that is not
//    attempted again (a beacon round that is now on-chain, a claim that is now settled) does not keep a stale one.
//    LIMIT: an RPC behind a load balancer can answer from a node that has not seen the transaction; the keeper then
//    reads it as dropped and sends again, and if the other node's copy lands first, one duplicate can revert.
const timedOutSends = new Map(); // job name -> { hash, nonce, from, at, held, provider }
let convertLandedLate = false; // a timed-out convert landed and succeeded later: runConvert books it (see there)

/// Where a transaction that timed out stands now. `seen` = provider.getTransaction(hash), null when the node does not
/// know it; `latestCount` / `pendingCount` = getTransactionCount(from, "latest" / "pending"), read AFTER `seen`.
///   "landed"    mined
///   "consumed"  not mined, but its nonce is used (a replacement, another send at that nonce, or it was mined between
///               the two reads): it can never land now
///   "pending"   the node still holds it unmined, or some transaction is still pending at its nonce: a send now could
///               take the next nonce and land as a duplicate
///   "dropped"   the node no longer knows it and nothing is pending at its nonce: a new send reuses that nonce
export function timedOutSendVerdict({ nonce, seen, latestCount, pendingCount }) {
  if (seen && seen.blockNumber != null) return "landed";
  if (BigInt(latestCount) > BigInt(nonce)) return "consumed";
  if (seen || BigInt(pendingCount) > BigInt(nonce)) return "pending";
  return "dropped";
}

/// Re-check the timed-out transaction remembered for `name`, if any. Returns null (no record), or
/// { held: true } while it is still pending (logged once per record), or { held: false, verdict, receipt } after
/// dropping the record. A read that fails throws (a transport failure is never read as "gone"), and the record stays.
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
        + "ago, is still pending. This job sends nothing until it lands, its nonce is used, or the RPC drops it "
        + "(said once; the heartbeat line lists it while it holds).");
    }
    return { held: true, verdict };
  }
  timedOutSends.delete(name);
  const receipt = verdict === "dropped" ? null : await prov.getTransactionReceipt(rec.hash);
  if (receipt) {
    log(`${name}: transaction ${rec.hash} (nonce ${rec.nonce}), which timed out ${ago}s ago,landed late in `
      + `block ${receipt.blockNumber} and ${receipt.status === 1 ? "succeeded" : "REVERTED"}. The job simulates again.`);
    if (name === "treasury.convert" && receipt.status === 1) convertLandedLate = true;
    return { held: false, verdict: "landed", receipt };
  }
  log(`${name}: transaction ${rec.hash} (nonce ${rec.nonce}), which timed out ${ago}s ago,`
    + (verdict === "dropped"
      ? "is no longer known to the RPC and nothing is pending at its nonce: it was dropped. The job simulates again and may send."
      : `never landed: nonce ${rec.nonce} is used by another transaction. The job simulates again.`));
  return { held: false, verdict, receipt: null };
}

/// Tick job: re-check every remembered timed-out transaction, so a job that is not attempted again drops its record.
async function runTimedOutSends() {
  for (const name of [...timedOutSends.keys()]) await settleTimedOutSend(name);
}

/// The block to start replacement scanning from, read BEFORE a send (a transaction cannot land earlier), or null.
/// ethers 6.17 turns replacement detection OFF for Contract method sends: ContractTransactionResponse is built without a
/// start block, so its wait() never throws TRANSACTION_REPLACED and a replaced transaction just runs into the timeout
/// (checked on a local anvil). Waiting on tx.replaceableTransaction(startBlock), the object ethers' own
/// signer.sendTransaction returns, turns it back on. A failed read only leaves it off; the send goes ahead.
async function replacementStartBlock(prov) {
  try {
    return await prov.getBlockNumber();
  } catch {
    return null;
  }
}
const waitable = (tx, startBlock) => (startBlock !== null && typeof tx.replaceableTransaction === "function"
  ? tx.replaceableTransaction(startBlock) : tx);

async function fire(name, contract, method, args, { onRevert, onHeld } = {}) {
  const fn = contract.getFunction(method); // throws if `method` is not in this contract's ABI
  if (timedOutSends.has(name)) {
    // A pending one holds the job; one that has just landed ends this attempt (the next tick simulates against the
    // state it left). "dropped" and "consumed" cannot land twice, so this attempt goes on.
    const s = await settleTimedOutSend(name);
    if (s && (s.held || s.verdict === "landed")) {
      if (onHeld) onHeld(s);
      return false;
    }
  }
  try {
    await fn.staticCall(...args);
  } catch (e) {
    if (!isRevertError(e)) throw e;
    const reason = revertReason(e);
    if (onRevert) onRevert(reason, e);
    else noteRevert(name, reason);
    return false;
  }
  lastRevert.delete(name);
  let tx = null;
  let result = false;
  const startBlock = await replacementStartBlock(contract.runner?.provider ?? provider);
  try {
    tx = await fn(...args);
    sendCounts.sent++;
    log(`${name}: sent ${tx.hash} (nonce ${tx.nonce})`);
    // Bounded. Without a timeout, a transaction the RPC acknowledged and never included waited here forever
    // and every later job of every later tick with it (tick() is serial), with nothing logged.
    const rc = await waitable(tx, startBlock).wait(1, SEND_WAIT_TIMEOUT_MS);
    sendCounts.confirmed++;
    log(`${name}: confirmed (block ${rc.blockNumber})`);
    return true;
  } catch (e) {
    if (tx && ethers.isError(e, "TIMEOUT")) {
      sendCounts.timedOut++;
      timedOutSends.set(name, {
        hash: tx.hash, nonce: tx.nonce, from: tx.from, at: Date.now() / 1000, held: false,
        provider: contract.runner?.provider ?? provider,
      });
      logError(`${name}: transaction ${tx.hash} (nonce ${tx.nonce}, from ${tx.from}) did NOT confirm within `
        + `SEND_WAIT_TIMEOUT_MS=${SEND_WAIT_TIMEOUT_MS} ms. The RPC acknowledged it but has not included it. Stopped `
        + "waiting so the other jobs keep running, and the signer's nonce is re-read from the chain. This job does not "
        + "send again while that transaction is still pending: it simulates again once it lands, its nonce is used, or "
        + "the RPC no longer has it. A timeout cannot tell a slow transaction from a dropped one, so a transaction "
        + "that lands late, after the RPC stopped reporting it, can still make one duplicate of this call revert on "
        + "chain (gas spent). If this repeats, the RPC is dropping transactions: check RPC_URL.");
    } else if (tx && ethers.isError(e, "TRANSACTION_REPLACED")) {
      // Checked BEFORE the receipt branch: this error carries the REPLACEMENT's receipt, which says nothing about
      // whether this call reverted.
      sendCounts.replaced++;
      const ok = e.receipt?.status === 1;
      const sameCall = e.reason === "repriced";
      logError(`${name}: transaction ${tx.hash} (nonce ${tx.nonce}) was REPLACED (${e.reason}) by ${e.hash} in block `
        + `${e.receipt?.blockNumber}, which ${ok ? "succeeded" : "reverted"}. `
        + (sameCall
          ? `The replacement sends this same call, so it ${ok ? "went through" : "did not go through"}. `
          : "The replacement is a different transaction, so this call did not run. ")
        + "Another sender used this key's nonce: a second keeper process on the same key (a --failsafe copy needs its "
        + `own key) or a manual send.${sameCall && ok ? "" : " The next tick simulates this call again."}`);
      result = sameCall && ok;
    } else if (tx && e?.receipt) {
      sendCounts.failed++;
      logError(`${name}: transaction ${tx.hash} (nonce ${tx.nonce}) REVERTED on chain in block ${e.receipt.blockNumber} `
        + "(the state changed after its simulation; gas was spent)");
    } else {
      sendCounts.failed++;
      // A send whose gas estimate reverts carries the revert data; name it.
      const why = isRevertError(e) ? revertReason(e) : null;
      const named = why && why !== "reverted without data";
      const msg = String(e.shortMessage || e.message);
      logError(`${name}: send FAILED: ${named ? msg.replace(" (unknown custom error)", "") : msg}`
        + `${named ? ` (${describeRevert(why)})` : ""}`);
    }
    // Re-read the nonce from the chain next time. NonceManager bumps its count before broadcasting,
    // so a send that failed before it left would otherwise leave a gap every later send waits behind. After a
    // send timeout the pending count decides: a dropped transaction's nonce is reused, a live one is skipped.
    try { if (typeof contract.runner?.reset === "function") contract.runner.reset(); } catch { /* reset is local */ }
    return result;
  }
}

// ── NO-OP BACKOFF ───────────────────────────────────────────────────────────────────────────────────
//    RaffleEngine, HolderDrawEngine and LeaderboardEngine deliberately do NOT set their idempotency flag
//    when a period takes a no-pay branch (empty vault, sub-minPot pot, empty board, nothing seated), so a
//    late top-up can still pay inside the window. The simulation of such a call SUCCEEDS, so neither fire()
//    nor a drawn()/distributed() guard can tell it apart from a paying call; left alone the keeper re-sends
//    it every tick, for real gas. So the no-op is detected from its OUTCOME: if the flag did not flip after
//    a confirmed send, stand down with exponential backoff.
//
//    Do NOT fix this by copying the engines' conditions into the keeper: there are five of them across three
//    contracts and a keeper-side copy drifts silently. The key carries the target period, so a new period
//    always gets an immediate attempt. NOOP_MAX_S must stay well under the shortest period, or one stand-down
//    outlives the window it is waiting on and the period voids.
const noopUntil = new Map(); // "holder:64" => { until, step }

const noopHolding = (key) => {
  const e = noopUntil.get(key);
  return !!e && Date.now() / 1000 < e.until;
};

function noopNote(key, label) {
  const step = (noopUntil.get(key)?.step ?? 0) + 1;
  const wait = Math.min(NOOP_BASE_S * 2 ** (step - 1), NOOP_MAX_S);
  noopUntil.set(key, { until: Date.now() / 1000 + wait, step });
  log(`${label}: confirmed but ${key} was NOT consumed -- the engine took a no-pay branch (empty vault,`
    + ` sub-minPot pot, empty board, or nothing seated). Standing down ${wait}s; the period will retry.`);
}

/// Send, then re-read the idempotency flag. Skips entirely while a stand-down is in force. `opts` go to fire().
async function fireOnce(name, contract, method, args, key, consumed, opts = {}) {
  if (noopHolding(key)) return false;
  const sent = await fire(name, contract, method, args, opts);
  if (!sent) return false;
  if (await consumed()) { noopUntil.delete(key); return true; }
  noopNote(key, name);
  return false;
}

// ── BEACONS ─────────────────────────────────────────────────────────────────────────────────────────
//    Which interface the oracle speaks is read from its BYTECODE (classifyOracleCode). Only an acceptable
//    result is cached. An unacceptable one (no code, neither interface, or a settable mock on mainnet) is
//    re-checked and re-alarmed on every tick, and an RPC failure is thrown, never cached.
let oracleIfaceCache = null;
let tickNo = 0; // incremented by tick(); rate-limits the oracle alarm to one line per tick
let oracleAlarmTick = -1;

async function oracleInterface() {
  if (oracleIfaceCache) return oracleIfaceCache;
  const code = await provider.getCode(oracle.target); // an RPC failure throws: nothing is cached
  const cls = classifyOracleCode(code, CHAIN_ID);
  if (cls.acceptable) {
    oracleIfaceCache = cls;
    log(`oracle beacon interface: ${cls.iface}${cls.iface === "mock"
      ? " (MockDrandOracle: randomness is NOT verified; testnet only)" : " (BlsDrandOracle)"}`);
    return cls;
  }
  if (oracleAlarmTick !== tickNo) {
    oracleAlarmTick = tickNo;
    logError(`*** FATAL: oracle ${oracle.target} is unusable (${cls.iface}): ${cls.reason}. No beacon can be `
      + "posted, so the opening draw, every daily raffle draw, the holder draw and every pack reveal are blocked. "
      + "This repeats every tick until it is fixed. ***");
  }
  return cls;
}

// A beacon that fails verification on-chain came from a relay that lied or garbled it: try the next relay.
const BEACON_VERIFY_REVERTS = new Set(["InvalidBeacon", "BadCompressedForm", "CompressionMismatch", "BadSigLength"]);

/// Make `round` available on-chain if it can be. Returns:
///   "available"  on-chain now
///   "pending"    drand has not published it yet, every relay still answers 404 or 425 inside DRAND_GRACE_ROUNDS of
///                publication, or our post is confirmed but not yet visible to this RPC, or an earlier post of this
///                round that timed out is still pending or has just landed (TIMED-OUT SENDS)
///   "failed"     publishable but the fetch or the post failed (logged)
///   "unusable"   the oracle cannot accept beacons at all (alarmed by oracleInterface)
/// A round that is not due yet is never fetched, and is silent. Only a DUE round that fails logs.
async function ensureBeacon(round, label) {
  if (!oracle) throw new Error(`ensureBeacon(${label}): no oracle was resolved at startup`);
  const r = BigInt(round);
  const what = label ? `${label} (round ${r})` : `round ${r}`;
  // Classify FIRST (cached once acceptable, so this is free in steady state): against an address with no code,
  // isAvailable returns empty data and throws a decode error that would hide the real cause.
  const cls = await oracleInterface();
  if (!cls.acceptable) return "unusable";
  if (await oracle.isAvailable(r)) return "available";
  // A real drand round cannot be posted before it publishes (the fetch 404s). The mock would accept a future
  // round, which is how early reveals once hid a draw-before-reveal bug on testnet, so the same schedule applies to both.
  const roundNow = await oracle.roundAt(BigInt(Math.floor(Date.now() / 1000)));
  if (!isRoundPublished(r, roundNow, DRAND_MARGIN_ROUNDS)) return "pending";
  let sent;
  // An earlier post of this round that timed out and is still pending (or has just landed) is "pending", not "failed".
  let held = false;
  const onHeld = () => { held = true; };
  if (cls.iface === "mock") {
    // No signature to verify: derive the value from the round so a restart reproduces it.
    const rnd = ethers.keccak256(ethers.solidityPacked(["string", "uint64"], ["qpull-mock-beacon", r]));
    const mock = new ethers.Contract(oracle.target, mockOracleAbi, wallet);
    sent = await fire(`setBeacon ${what}`, mock, "setBeacon", [r, rnd], { onHeld });
  } else {
    let relays = relayList({ failsafe: FAILSAFE });
    sent = false;
    while (relays.length) {
      let data;
      try {
        data = await beaconSubmitData(r, { relays, timeoutMs: DRAND_TIMEOUT_MS });
      } catch (e) {
        if (beaconFetchVerdict({ round: r, roundAtNow: roundNow, notPublished: !!e.notPublished, graceRounds: DRAND_GRACE_ROUNDS }) === "pending") {
          return "pending";
        }
        logError(`beacon ${what}: drand fetch/format failed — ${e.message}`);
        return "failed";
      }
      let verifyFailure = null;
      sent = await fire(`submitBeacon ${what}`, oracle, "submitBeacon", [r, data.sig, data.comp], {
        onRevert: (reason) => {
          if (BEACON_VERIFY_REVERTS.has(reasonName(reason))) verifyFailure = reason;
          else noteRevert(`submitBeacon ${what}`, reason);
        },
        onHeld,
      });
      if (!verifyFailure) break;
      logError(`beacon ${what}: relay ${data.relay} served a beacon the oracle rejects (${describeRevert(verifyFailure)}); `
        + "trying the next relay");
      relays = relays.slice(relays.indexOf(data.relay) + 1);
    }
  }
  if (await oracle.isAvailable(r)) return "available";
  return sent || held ? "pending" : "failed";
}

// One-time (idempotent) build of the Super Rare auto-entry index. Discovers the SR ids by reading rarityOf
// OFF-CHAIN over 1..totalMinted (so only the ~2% SR set is sent as calldata), then registers any not yet
// indexed, in chunks. Runs FIRST each tick so SRs are indexed before the first daily draw's freeze; a
// registration after a draw's freeze only counts from the NEXT day.
let srIds = null; // the discovered SR token ids, set only once EVERY id 1..totalMinted has been read
let srScan = null; // { total, next, found }: a scan in progress. Kept across ticks, so a failed read resumes
let srDone = false; // every discovered SR is indexed on-chain
async function runRegisterSR() {
  if (srDone || !nft || !packReg) return;
  const rr = await nft.revealRound();
  if (rr === 0n) return; // finalizeLaunch not called yet: no rarities to read
  if ((await ensureBeacon(rr, "collection reveal")) !== "available") return; // not published yet, or logged
  if (srIds === null) {
    // Past this point NO minted id can legitimately revert rarityOf: ids are exactly 1..totalMinted and never
    // burned (NFTCollection.totalMinted NatSpec), revealRound is set, and its beacon is on-chain, which rules
    // out NoToken, "not revealed" and the oracle's unavailable revert. So ANY error is transient (a rate limit,
    // a node lagging the beacon) and is never read as "not a Super Rare": the scan stops, nothing is cached,
    // and it resumes at the failed id next tick. isRevertError cannot be used here: ethers reports a JSON-RPC
    // error on eth_call as a revert. Resuming, not restarting, keeps a rate-limited RPC from looping forever.
    if (!srScan) srScan = { total: await nft.totalMinted(), next: 1n, found: [] };
    for (; srScan.next <= srScan.total; srScan.next++) {
      const id = srScan.next;
      let rarity;
      try {
        rarity = await nft.rarityOf(id);
      } catch (e) {
        logError(`registerSuperRare: rarityOf(${id}) failed although the collection reveal beacon is on-chain `
          + `(${isRevertError(e) ? `revert or JSON-RPC error: ${revertReason(e)}` : e.shortMessage || e.message}). `
          + `Super Rare set NOT cached; the scan resumes at id ${id} of ${srScan.total} next tick.`);
        return;
      }
      if (Number(rarity) === 3) srScan.found.push(id);
    }
    srIds = srScan.found;
    log(`registerSuperRare: discovered ${srIds.length} Super Rare(s) across ${srScan.total} passes`);
    srScan = null;
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

// ── COHORT REVEALS ────────────────────────────────────────────────────────────────────────────────
//    Each pack cohort's reveal round is posted as soon as drand publishes it, whether or not the opening has
//    run. Nothing else posts them on mainnet (web/ never calls submitBeacon), and ripping a pack, rip XP and
//    every draw that sweeps the cohort all need it. Depth covers every cohort that is still drawable
//    (LIFE_DAYS + 1) plus the rip-XP window. The draw gate in runRaffle re-checks its own rounds regardless.
const revealDone = new Set(); // cohort ids whose reveal round is on-chain, or which provably need none
async function runCohortReveals() {
  if (!packReg || !oracle) return;
  if (!(await oracleInterface()).acceptable) return; // alarmed once per tick by oracleInterface
  // today and every cohortSize are read at ONE block, so "closed and empty" is a consistent fact (revealNeeded).
  const blockTag = await provider.getBlockNumber();
  const today = BigInt(await packReg.today({ blockTag }));
  for (const c of revealJobCohorts(today, LIFE_DAYS + 1n + RIP_XP_WINDOW)) {
    const key = c.toString();
    if (revealDone.has(key)) continue;
    const size = await packReg.cohortSize(Number(c), { blockTag });
    if (!revealNeeded({ cohort: c, today, size })) {
      revealDone.add(key); // closed and empty: it can never gain a pack
      continue;
    }
    const round = await oracle.roundAt(cohortRevealTimestamp(c, chainClock()));
    if ((await ensureBeacon(round, `cohort ${c} reveal`)) === "available") revealDone.add(key);
  }
}

// Opening-draw funding pre-check. runOpeningDraw(false) never forgoes: an underfunded opening reverts
// PotBelowOpeningFloor and latches nothing. This mirrors the contract's own arithmetic so the log names the
// real cause ("fund the vault") instead of a bare revert. The contract compares POT = free * openingCapBps
// / BPS to openingMinPot, so it needs free >= floor * BPS / capBps (about 10x the floor at 1000 bps).
let prizeVault = null; // resolved once; raffle.vault() is immutable
async function openingWillPay() {
  try {
    if (!prizeVault) prizeVault = new ethers.Contract(await raffle.vault(), prizeVaultAbi, provider);
    const [floor, capBps, free] = await Promise.all([
      raffle.openingMinPot(), raffle.openingCapBps(), prizeVault.freeBalance(),
    ]);
    if (capBps === 0n) {
      logError("runOpeningDraw: openingCapBps is 0, so the opening can never pay; refusing to fire");
      return false;
    }
    const pot = (free * capBps) / BPS;
    if (pot >= floor) return true;
    log(
      `runOpeningDraw: opening POT below the floor (${ethers.formatEther(pot)} < ${ethers.formatEther(floor)} QUOTRON; ` +
        `vault holds ${ethers.formatEther(free)} at ${capBps} bps). WAITING. Fund the prize vault (~10x ` +
        "RAFFLE_MIN_POT at a 1000 bps cap), and if convert should already be funding it, check the convert " +
        "lines in this log (a convert key without the Treasury keeper role funds nothing).",
    );
    return false;
  } catch (e) {
    logError(`runOpeningDraw: could not read vault/floor (${e.shortMessage || e.message}); skipping, never firing blind`);
    return false;
  }
}

const holdNoted = new Map(); // draw name -> last logged "waiting" signature
/// Post every beacon a raffle draw consumes, then report whether ALL of them are onchain.
async function raffleBeaconsReady(name, drawDay, drawRound) {
  const plan = raffleDrawBeaconPlan({ drawDay, lifeDays: LIFE_DAYS, clock: chainClock(), drawRound, drawLabel: "draw beacon" });
  // One block for today and every cohort size, so an empty CLOSED cohort is skipped on a consistent read.
  const blockTag = await provider.getBlockNumber();
  const today = BigInt(await packReg.today({ blockTag }));
  const entries = [];
  for (const rv of plan.reveals) {
    const size = await packReg.cohortSize(Number(rv.cohort), { blockTag });
    if (!revealNeeded({ cohort: rv.cohort, today, size })) continue;
    const round = await oracle.roundAt(rv.ts); // the exact call PackRegistry._mintPacks made
    entries.push({ label: rv.label, round, status: await ensureBeacon(round, rv.label) });
  }
  entries.push({ label: plan.draw.label, round: plan.draw.round, status: await ensureBeacon(plan.draw.round, plan.draw.label) });
  const gate = beaconGate(entries);
  if (gate.ready) {
    holdNoted.delete(name);
    return true;
  }
  const list = (xs) => xs.map((e) => `${e.label} round ${e.round} [${e.status}]`).join(", ");
  if (gate.failing.length) {
    logError(`${name}: HOLDING, not fired. Beacons it consumes could not be posted: ${list(gate.failing)}. `
      + "The engine refuses the draw until they are on-chain (a missing draw round reverts \"unavailable\", a "
      + "missing reveal RevealPending), and a daily draw can only settle during the day after its own: if these "
      + "stay unpostable past that, the day VOIDS.");
  } else {
    const sig = list(gate.missing);
    if (holdNoted.get(name) !== sig) {
      holdNoted.set(name, sig);
      log(`${name}: waiting for drand to publish ${sig}; fires once they are on-chain`);
    }
  }
  return false;
}

/// RevealPending fallback. The engine's RevealPending names a cohort whose tier round it cannot see, although
/// raffleBeaconsReady found every needed round on-chain (normally: an RPC node behind the one that answered
/// isAvailable, or a post not yet visible everywhere). Nothing was popped, spent or latched, so this is NOT a
/// failure: post the round the ENGINE named (its number, not this keeper's derivation) and let the next tick
/// retry the draw. Two things are loud: the engine naming a different round than this keeper derives for that
/// cohort (a keeper clock bug), and the engine still naming a round this RPC reads as on-chain after
/// REVEAL_DISAGREE_TICKS ticks in a row (the RPC is inconsistent, and the draw's window is running out).
/// "In a row" is per runRaffle pass: a pass on which a draw is not simulated (its beacons are not all on-chain as
/// this RPC reads them, it is settled, the opening is underfunded, a read threw) ends that draw's streak
/// (endRevealPendingStreaks), so non-consecutive RevealPending ticks never add up to the ERROR.
const REVEAL_DISAGREE_TICKS = 3;
const revealPendingStreak = new Map(); // draw name -> { key, n }
const revealPendingAttempts = new Set(); // draw names fireRaffleDraw simulated during the current runRaffle pass
async function handleRevealPending(name, p) {
  const label = `cohort ${p.cohort} reveal (named by the engine's RevealPending)`;
  revealDone.delete(p.cohort.toString()); // the reveal job re-checks this cohort too
  let derived = null;
  try {
    derived = BigInt(await oracle.roundAt(cohortRevealTimestamp(p.cohort, chainClock())));
  } catch (e) {
    if (e instanceof TypeError) throw e;
    derived = null; // the cross-check is advisory; the engine's own round is posted regardless
  }
  if (derived !== null && derived !== p.round) {
    alarm(`reveal-round-mismatch:${p.cohort}`, `${p.round}:${derived}`, `*** ${name}: the engine's RevealPending names `
      + `round ${p.round} for cohort ${p.cohort}, but this keeper derives round ${derived} for it (roundAt(genesis + `
      + "(cohort+1)*dayLength + revealDelay) from PACK_REGISTRY). Its reveal job has been posting the wrong round. "
      + "Posting the engine's round now; investigate the clock this keeper read at startup. ***");
  }
  const status = await ensureBeacon(p.round, label);
  const key = `${p.cohort}:${p.round}`;
  const prev = revealPendingStreak.get(name);
  const n = status === "available" && prev?.key === key ? prev.n + 1 : status === "available" ? 1 : 0;
  revealPendingStreak.set(name, { key, n });
  if (n >= REVEAL_DISAGREE_TICKS) {
    alarm(`reveal-pending:${name}`, `disagree:${key}`, `*** ${name}: the engine has reverted RevealPending(cohort `
      + `${p.cohort}, round ${p.round}) for ${n} ticks in a row while this RPC reads that round as on-chain. The `
      + "RPC's nodes disagree about the oracle's state (check RPC_URL, or use a non-load-balanced endpoint). The "
      + "draw keeps retrying every tick; a daily draw voids if this lasts past its window. ***");
    return;
  }
  alarm(`reveal-pending:${name}`, `${key}:${status}`, `${name}: not fired this tick: the engine reverted `
    + `RevealPending(cohort ${p.cohort}, round ${p.round}), so that cohort's reveal is not on-chain as the engine sees `
    + `it (nothing was popped). Posting it: ${status}. The draw retries next tick.`, { level: "info", repeatS: 600 });
}

/// Fire a raffle draw, decoding RevealPending into handleRevealPending instead of a bare "not callable" line.
async function fireRaffleDraw(name, method, args, once = null) {
  // A no-op stand-down simulates nothing, so it is not an attempt (endRevealPendingStreaks then ends the streak).
  if (once && noopHolding(once.key)) return false;
  revealPendingAttempts.add(name);
  let pending = null;
  const onRevert = (reason, e) => {
    pending = revealPendingOf(e);
    if (!pending) noteRevert(name, reason);
  };
  const sent = once
    ? await fireOnce(name, raffle, method, args, once.key, once.consumed, { onRevert })
    : await fire(name, raffle, method, args, { onRevert });
  if (pending) {
    await handleRevealPending(name, pending);
  } else if (revealPendingStreak.delete(name)) {
    clearAlarm(`reveal-pending:${name}`, `${name}: no longer reverts RevealPending`);
  }
  return sent;
}

/// End the RevealPending streak of every draw fireRaffleDraw did not simulate during this runRaffle pass, so
/// REVEAL_DISAGREE_TICKS really counts consecutive ticks (the streak used to reset only inside
/// fireRaffleDraw, so a tick that returned before firing kept it alive and the ERROR could fire on three
/// non-consecutive RevealPending ticks).
function endRevealPendingStreaks() {
  for (const name of [...revealPendingStreak.keys()]) {
    if (revealPendingAttempts.has(name)) continue;
    revealPendingStreak.delete(name);
    clearAlarm(`reveal-pending:${name}`, `${name}: not attempted this tick, so its RevealPending streak restarts`);
  }
  revealPendingAttempts.clear();
}

async function runRaffle() {
  if (!raffle) return;
  revealPendingAttempts.clear();
  try {
    await runRaffleDraws();
  } finally {
    endRevealPendingStreaks(); // also when a read threw: that tick was not an attempt either
  }
}

async function runRaffleDraws() {
  // Every raffle path needs beacons, and drawRound() itself calls the oracle: an unusable oracle is reported
  // by name (oracleInterface) instead of as an opaque revert from the engine.
  if (!(await oracleInterface()).acceptable) return;
  const day = BigInt(await raffle.currentDay()); // a day is drawn during the NEXT day (currentDay == day+1)

  // The one-time opening must run before ANY daily draw: runDraw reverts OpeningPending until openingDone.
  if (!(await raffle.openingDone())) {
    if (day < RAFFLE_ACCUM_DAYS) return; // still inside the accumulation window
    const ready = await raffleBeaconsReady("raffle.runOpeningDraw", RAFFLE_ACCUM_DAYS,
      await raffle.drawRound(RAFFLE_ACCUM_DAYS - 1n));
    if (!ready) return;
    if (await openingWillPay()) {
      // false: NEVER consent to forgoing the opening. Only a human, deliberately, after the grace day.
      await fireRaffleDraw("raffle.runOpeningDraw", "runOpeningDraw", [false]);
    }
    return; // no daily draw is possible until the opening settles
  }

  // runDraw(d) runs during currentDay == d+1 and reverts BadDay for d < RAFFLE_ACCUM_DAYS.
  if (day < RAFFLE_ACCUM_DAYS + 1n) return;
  const target = day - 1n;
  // Settled already: skip the beacon work. (This guard cannot see a no-pay branch, which leaves drawn false;
  // fireOnce handles that.)
  if (await raffle.drawn(target)) return;
  const ready = await raffleBeaconsReady(`raffle.runDraw(${target})`, target, await raffle.drawRound(target));
  if (!ready) return;
  await fireRaffleDraw("raffle.runDraw", "runDraw", [target], { key: `raffle:${target}`, consumed: () => raffle.drawn(target) });
}

async function runLeaderboard() {
  if (!leaderboard) return;
  const week = await leaderboard.currentWeek();
  if (week < 1n) return;
  const lbTarget = week - 1n; // deterministic — no beacon
  await fireOnce("leaderboard.distribute", leaderboard, "distribute", [lbTarget], `leaderboard:${lbTarget}`,
    () => leaderboard.distributed(lbTarget));
}

async function runHolder() {
  if (!holder) return;
  if (!(await oracleInterface()).acceptable) return; // alarmed once per tick by oracleInterface
  const period = await holder.currentPeriod();
  if (period < 1n) return;
  const target = period - 1n; // week w is drawable during period w+1
  if (await holder.drawn(target)) return; // settled already (cannot see a no-pay branch: fireOnce handles it)
  if ((await ensureBeacon(await holder.drawRound(target), `holder week ${target} draw beacon`)) !== "available") return;
  await fireOnce("holder.runDraw", holder, "runDraw", [target], `holder:${target}`, () => holder.drawn(target));
}

/// QuoPods: re-settle every pod on a schedule.
///
/// WHY THIS JOB EXISTS AT ALL. A pod's weight is read live at settlement and then held until the next one.
/// `QuoPodStaking._settle` banks the interval that just ended at the weight that was IN FORCE for it, and
/// only then re-reads the world and sets the weight going forward. So between settlements a pod earns at a
/// stale weight, and the one direction nobody volunteers to fix is stale-HIGH: sell the NFTs that set your
/// tier, never touch the pod, and it keeps paying at the old tier until somebody settles it. Claiming
/// settles you, but it banks the inflated interval first, so "claim once at the end" collects all of it.
///
/// `poke` is permissionless precisely so anyone can correct this, but in practice nobody does: the corrector
/// pays a whole transaction and captures roughly one five-hundredth of the benefit, which is a free-rider
/// problem, not an incentive. Without this job the protocol's "your tier is re-read live" claim quietly
/// degrades to "re-read whenever the owner feels like it", and an owner only feels like it when the news is
/// good. The exposure is then unbounded in time; with this job it is POD_POKE_INTERVAL_S.
///
/// Deliberately NOT clever: it sweeps every minted pod rather than trying to detect which ones drifted.
/// `tierOf` and `scoreOf` do recompute live, so a staleness filter is possible and would cut gas, but it
/// means reimplementing `_rawWeight`'s banding off-chain and that is a drift risk in the one job whose whole
/// purpose is to stop state drifting. Poking a pod that did not need it is harmless.
let lastPodPoke = 0;
let podSaleFailedLogged = false;
async function runPodPokes() {
  if (!podStaking || !podMint) return;
  const now = Date.now();
  if (now - lastPodPoke < POD_POKE_INTERVAL_S * 1000) return;

  // A FAILED sale (closed under its floor) leaves pods that can never stake (stake() reverts MintFailed),
  // but pokeMany does not check that, so without this the sweep would pay gas every interval forever.
  try {
    if (await podMint.failed()) {
      if (!podSaleFailedLogged) { log("pods: the sale missed its floor; the re-settle sweep is off for good"); podSaleFailedLogged = true; }
      lastPodPoke = now;
      return;
    }
  } catch (e) {
    logError(`pods: could not read failed() (${e.shortMessage || e.message}); skipping this sweep`);
    return;
  }

  let minted;
  try {
    minted = Number(await podMint.totalMinted());
  } catch (e) {
    logError(`pods: could not read totalMinted (${e.shortMessage || e.message}); skipping this sweep`);
    return;
  }
  if (minted === 0) { lastPodPoke = now; return; } // sale never filled, or has not opened

  // Ids are 1..minted and the pod NFT has no burn, so every one of these resolves. That matters:
  // `pokeMany` calls `ownerOf` per id, so a single missing id would revert the WHOLE batch.
  let sent = 0;
  let failed = 0;
  let batches = 0;
  for (let from = 1; from <= minted; from += POD_POKE_BATCH) {
    const ids = [];
    for (let id = from; id < from + POD_POKE_BATCH && id <= minted; ++id) ids.push(id);
    const label = `pods.pokeMany(${ids[0]}..${ids[ids.length - 1]})`;
    // Each batch is its own send AND its own failure. Letting one throw escape would abort the rest of
    // the sweep and leave lastPodPoke unmoved, so the next tick would restart from batch one: a retry
    // storm on anything persistently broken, which is the opposite of what a timed sweep is for.
    batches++;
    try {
      if (await fire(label, podStaking, "pokeMany", await withHeadroom(podStaking, "pokeMany", [ids]))) sent++;
      else failed++; // fire() already logged why: a simulated revert, a failed send or a timeout
    } catch (e) {
      failed++;
      logError(`${label} failed: ${e.shortMessage || e.message}`);
    }
  }
  // Always advance the clock, even on failures. A sweep that cannot run is reported, not retried at tick
  // speed; the next one comes round on the normal interval.
  lastPodPoke = now;
  if (batches) {
    // It used to say "re-settled N pods" whatever happened, so a batch that reverted still read as done.
    log(`pods: poke sweep over ${minted} pods, ${sent} of ${batches} batches confirmed${failed ? `, ${failed} did not` : ""}`);
  }
}

/// Gas headroom for the pods sends. pokeMany and collectFees both run QuoPodStaking._accrue, which does real work
/// only when time has passed since the last accrual. An estimate taken in the same second as the previous batch
/// sees none of that work, and the send can land a second later and need it: on a fork rehearsal a
/// batch estimated at 608,079 gas needed 617,565 and reverted out of gas. Unused gas is not charged, so a 25%
/// margin costs nothing. A call that would revert falls back to plain args, so fire() still names the revert.
async function withHeadroom(contract, method, args) {
  try {
    const est = await contract.getFunction(method).estimateGas(...args);
    return [...args, { gasLimit: est + est / 4n }];
  } catch {
    return args;
  }
}

/// QuoPods: collect the locked pool's 0.3% swap fee. PERMISSIONLESS and idempotent, so it belongs in failsafe
/// too: the WETH half streams to staked pods, the QPOD half is burned, and nothing about it depends on who
/// calls it or when. Until someone calls it the fees simply wait, credited to the locked position.
let lastPodFeeCollect = 0;
async function runPodFeeCollect() {
  if (!podLock) return;
  const now = Date.now();
  if (now - lastPodFeeCollect < POD_FEE_INTERVAL_S * 1000) return;
  lastPodFeeCollect = now; // advance first: a broken collect is reported once per interval, not every tick
  try {
    if (!(await podLock.seeded())) return; // no pool yet, nothing to collect
    if (await fire("pods.collectFees", podLock, "collectFees", await withHeadroom(podLock, "collectFees", []))) {
      log("pods: swap fees collected");
    }
  } catch (e) {
    logError(`pods.collectFees failed: ${e.shortMessage || e.message}`);
  }
}

// ── CONVERT ─────────────────────────────────────────────────────────────────────────────────────────
//    Treasury.convert(minWethOut, minQuotronOut) swaps accumulated tax and splits it: 20% team + operations
//    as WETH, 80% bought as QUOTRON for the prize vaults. It is keeper-gated because its floors are only as good
//    as the keeper that computes them: a loose floor lets a sandwich drain the batch.
//
//    TAX IN WETH. The hook takes every tax in WETH, on buys and sells. So the normal convert is a WETH-only sweep:
//    leg 1 is skipped (qpullLeg false), minWethOut is ignored, and only leg 2 (WETH -> QUOTRON) needs a floor,
//    from Quotron's View quoter. Leg 1 (QPULL -> WETH) runs ONLY for QPULL donated to the Treasury at or above
//    convertThreshold. It needs the QPULL/WETH pool quoted: QPULL_QUOTER when set, bisection otherwise.
//
//    FLOORS, in order of preference, all fail CLOSED (no floor = no send):
//      1. quoters: leg 1 from QPULL_QUOTER on the key read from QpullWethAdapter.poolKey(), grossed up EXACTLY
//         by the hook's sell tax at the quote block (grossUpForExemptSell, sellTaxBpsAt); leg 2 from VIEW_QUOTER.
//      2. bisection, per leg (bisectLeg1 / bisectLeg2): only for a leg that runs and whose quoter is missing or
//         fails, plus one full retry (bisectConvertFloors) when a quoted convert() simulation reverts on a floor.
//         Never for a deliberate skip: dust, or nothing to convert.
//    Before any send, the spot guard compares a fixed-size reference quote at this block with the median of
//    earlier ticks' reference quotes (spotGuard). The quotes AND every bisection probe read that same block, so a
//    floor always comes from the pool state the guard checked.

let convertStatic = null; // { qpull, weth, teamBps, qpullToken, wethToken }: Treasury immutables and constants

/// The caps were just read at this block by runConvert, so they are passed in, not read twice.
async function readConvertState(blockTag, { maxConv, maxWethConv }) {
  if (!convertStatic) {
    const [q, w, team] = await Promise.all([treasuryView.qpull(), treasuryView.weth(), treasuryView.TEAM_BPS()]);
    convertStatic = {
      qpull: ethers.getAddress(q),
      weth: ethers.getAddress(w),
      teamBps: BigInt(team),
      qpullToken: new ethers.Contract(q, erc20BalAbi, provider),
      wethToken: new ethers.Contract(w, erc20BalAbi, provider),
    };
  }
  const bt = { blockTag };
  const [qpullBal, wethHeld, threshold, qpullWeth, wethQuotron] = await Promise.all([
    convertStatic.qpullToken.balanceOf(TREASURY, bt),
    convertStatic.wethToken.balanceOf(TREASURY, bt),
    treasuryView.convertThreshold(bt),
    treasuryView.qpullWeth(bt),
    treasuryView.wethQuotron(bt),
  ]);
  return { ...convertStatic, qpullBal, wethHeld, threshold, maxConv, maxWethConv, qpullWeth, wethQuotron };
}

/// The QPULL/WETH pool binding, read from the Treasury's adapter and the key's hook. Cached per adapter once
/// complete; launchTime is re-read until it is stamped (it is written exactly once, at pool initialization).
///   { binding }         usable
///   { unavailable }     not bound yet (no adapter, poolKeySet false): the QPULL leg cannot be quoted
///   { broken: [...] }   the binding is inconsistent, or a QPULL_POOL_* .env assertion disagrees with it. Only the
///                       QPULL leg (donated QPULL) uses this pool, so this disables THAT leg, never the WETH sweep.
const bindingCache = new Map();
async function resolvePoolBinding(st, blockTag) {
  if (sameAddr(st.qpullWeth, ethers.ZeroAddress)) return { unavailable: "Treasury.qpullWeth() is unset" };
  const adapterAddr = ethers.getAddress(st.qpullWeth);
  let b = bindingCache.get(adapterAddr);
  if (!b) {
    const a = new ethers.Contract(adapterAddr, qpullAdapterAbi, provider);
    if (!(await a.poolKeySet({ blockTag }))) {
      return { unavailable: `QpullWethAdapter ${adapterAddr} has no pool key yet (setPoolKey runs at go-live)` };
    }
    const [k, adapterPoolManager, adapterQpull, adapterWeth] = await Promise.all([
      a.poolKey({ blockTag }), a.poolManager(), a.qpull(), a.weth(),
    ]);
    const key = {
      currency0: ethers.getAddress(k[0]), currency1: ethers.getAddress(k[1]),
      fee: BigInt(k[2]), tickSpacing: BigInt(k[3]), hooks: ethers.getAddress(k[4]),
    };
    const hook = new ethers.Contract(key.hooks, taxHookAbi, provider);
    const [exempt, hookPm, fee, ts, sellStep, sellDecay, startBps, stepBps, floorBps] = await Promise.all([
      hook.exemptSender(), hook.poolManager(), hook.canonicalFee(), hook.canonicalTickSpacing(),
      hook.SELL_STEP(), hook.SELL_DECAY(), hook.SELL_TAX_START_BPS(), hook.SELL_STEP_BPS(), hook.TAX_BPS(),
    ]);
    const problems = poolBindingProblems({
      treasuryQpull: st.qpull, treasuryWeth: st.weth, adapter: adapterAddr, adapterQpull, adapterWeth,
      adapterPoolManager, key, hookExemptSender: exempt, hookPoolManager: hookPm, hookFee: fee,
      hookTickSpacing: ts, sellStep,
    }, process.env);
    if (problems.length) return { broken: problems };
    b = {
      adapter: adapterAddr,
      key,
      keyTuple: [key.currency0, key.currency1, Number(key.fee), Number(key.tickSpacing), key.hooks],
      zeroForOne: sameAddr(key.currency0, st.qpull), // selling QPULL for WETH
      poolManager: ethers.getAddress(adapterPoolManager),
      hook,
      schedule: { sellStep: BigInt(sellStep), sellDecay: BigInt(sellDecay), startBps: BigInt(startBps), stepBps: BigInt(stepBps), floorBps: BigInt(floorBps) },
      launchTime: 0n,
    };
    bindingCache.set(adapterAddr, b);
    log(`convert: QPULL/WETH pool key from QpullWethAdapter.poolKey(): fee=${key.fee} tickSpacing=${key.tickSpacing} `
      + `hook=${key.hooks}; sell tax ${b.schedule.startBps}->${b.schedule.floorBps} bps, -${b.schedule.stepBps} every `
      + `${b.schedule.sellStep}s over ${b.schedule.sellDecay}s from the hook's launchTime`);
  }
  if (b.launchTime === 0n) b.launchTime = BigInt(await b.hook.launchTime({ blockTag }));
  return { binding: b };
}

/// QPULL_QUOTER must quote on the adapter's PoolManager, or it describes a pool convert() never trades.
const quoterCheck = new Map(); // poolManager -> { ok } | { unavailable }
async function usableQpullQuoter(binding) {
  if (!qpullQuoter) return { unavailable: "QPULL_QUOTER is not set" };
  let c = quoterCheck.get(binding.poolManager);
  if (!c) {
    try {
      const pm = await qpullQuoter.poolManager();
      c = sameAddr(pm, binding.poolManager)
        ? { ok: true }
        : { unavailable: `QPULL_QUOTER ${QPULL_QUOTER} quotes on PoolManager ${pm}, but the adapter swaps on ${binding.poolManager}` };
      quoterCheck.set(binding.poolManager, c);
    } catch (e) {
      if (e instanceof TypeError) throw e;
      return { readFailed: true, unavailable: `could not read QPULL_QUOTER.poolManager() (${e.shortMessage || e.message})` };
    }
  }
  return c;
}

/// Leg 1 at `block`: the exempt WETH output of selling `qpullIn`, and its floor.
/// Every { unavailable } carries a stable `code` (an alarm signature must not embed per-call text):
///   no-binding | no-launch | no-quoter | quoter-pm   the quote is not possible here (configuration or state)
///   quoter-failed                                    the quoter is configured and usable, but its call failed
async function quoteLeg1(pool, qpullIn, block) {
  if (!pool?.binding) {
    return { code: "no-binding", unavailable: pool?.unavailable ?? (pool?.broken ? `the pool binding is wrong (${pool.broken.join("; ")})` : "the QPULL/WETH pool binding is unavailable") };
  }
  const b = pool.binding;
  if (b.launchTime === 0n) return { code: "no-launch", unavailable: "the pool hook's launchTime() is 0 (the pool is not initialized)" };
  const q = await usableQpullQuoter(b);
  if (!q.ok) return { code: !qpullQuoter ? "no-quoter" : q.readFailed ? "quoter-failed" : "quoter-pm", unavailable: q.unavailable };
  let outWeth;
  try {
    [outWeth] = await qpullQuoter.quoteExactInputSingle.staticCall(b.keyTuple, b.zeroForOne, qpullIn, "0x", { blockTag: block.number });
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return { code: "quoter-failed", unavailable: `QPULL_QUOTER failed: ${isRevertError(e) ? describeRevert(revertReason(e)) : e.shortMessage || e.message}` };
  }
  // The tax the quote was charged is the hook's rate at THIS block's timestamp, from the hook's launchTime.
  const taxBps = sellTaxBpsAt({ launchTime: b.launchTime, now: BigInt(block.timestamp), ...b.schedule });
  const untaxed = grossUpForExemptSell(outWeth, taxBps);
  return { outWeth, taxBps, untaxed, minWeth: withSlippage(untaxed, CONVERT_SLIPPAGE) };
}

/// Leg 2 at `blockTag`: QUOTRON bought with `prizeWeth`, quoted as the adapter (the router's fee is per payer).
async function quoteLeg2(prizeWeth, wethQuotronAdapter, blockTag) {
  if (!viewQuoter) return { code: "no-quoter", unavailable: "VIEW_QUOTER is not set" };
  try {
    const [out] = await viewQuoter.quoteBuyExactEth(prizeWeth, wethQuotronAdapter, { blockTag });
    return { out, minQuotron: withSlippage(out, CONVERT_SLIPPAGE) };
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return { code: "quoter-failed", unavailable: `VIEW_QUOTER failed: ${isRevertError(e) ? describeRevert(revertReason(e)) : e.shortMessage || e.message}` };
  }
}

// SPOT GUARD HISTORY. One fixed-size reference quote per leg per tick (distinct blocks), newest last.
const spotHistory = { leg1: [], leg2: [] };
const SPOT_LABEL = Object.freeze({ leg1: "QPULL->WETH", leg2: "WETH->QUOTRON" });
const ONE = 10n ** 18n;
function pushSpot(series, block, rate) {
  const nowS = Date.now() / 1000;
  const s = spotHistory[series];
  if (s.length && s[s.length - 1].block >= block) return; // same (or older) block: not a new sample
  s.push({ block, at: nowS, rate });
  while (s.length > PRICE_WINDOW || (s.length && nowS - s[0].at > PRICE_MAX_AGE_S)) s.shift();
}
function priorRates(series, block) {
  const nowS = Date.now() / 1000;
  return spotHistory[series].filter((x) => x.block < block && nowS - x.at <= PRICE_MAX_AGE_S).map((x) => x.rate);
}

/// This block's fixed-size reference quote for one leg:
///   null                  that leg's reference quoter is NOT CONFIGURED (VIEW_QUOTER unset or Treasury.wethQuotron()
///                         unset for leg 2; QPULL_QUOTER unset for leg 1): spotHold holds leg 2 under hold, and
///                         says hourly that leg 1 is unguarded (the one documented exception)
///   { failed, config }    the quoter IS configured, but no reference could be taken at this block. `config` is true
///                         for a configuration fault that will not clear by itself (a QPULL_QUOTER on another
///                         PoolManager, a wrong pool binding: spotHold alarms it at ERROR at once), false for a cause
///                         that can (a failed call or read, a pool not bound or not initialized yet: ERROR after
///                         CONVERT_FAIL_ALARM ticks in a row)
///   { rate }              untaxed WETH-wei per 1e18 QPULL (leg 1) or QUOTRON-wei per 1e18 WETH (leg 2)
/// A configured QPULL_QUOTER on a different PoolManager (quoter-pm), a pool
/// binding that could not be read, a wrong binding and an uninitialized pool all used to return null here, which
/// spotHold read as "not configured": the leg ran unguarded on a bisection floor under hold. They are failures now.
async function referenceQuote(series, st, pool, block) {
  if (series === "leg2") {
    if (!viewQuoter || sameAddr(st.wethQuotron, ethers.ZeroAddress)) return null;
    const r = await quoteLeg2(PRICE_REF_WETH, st.wethQuotron, block.number);
    return r.out !== undefined ? { rate: (r.out * ONE) / PRICE_REF_WETH } : { failed: r.unavailable, config: false };
  }
  if (!qpullQuoter) return null;
  if (!pool?.binding) {
    const why = pool?.broken
      ? `the QPULL/WETH pool binding is wrong (${pool.broken.join("; ")})`
      : pool?.unavailable ?? "the QPULL/WETH pool binding is unavailable";
    // A wrong binding stays wrong until someone fixes it; an unreadable or not-yet-bound one can clear by itself.
    return { failed: why, config: !!pool?.broken };
  }
  const r = await quoteLeg1(pool, PRICE_REF_QPULL, block);
  if (r.untaxed !== undefined) return { rate: (r.untaxed * ONE) / PRICE_REF_QPULL };
  // quoter-pm stays until someone re-points QPULL_QUOTER; quoter-failed (a call or read at this block) and no-launch
  // (the pool is initialized at go-live) can clear by themselves.
  return { failed: r.unavailable, config: r.code === "quoter-pm" };
}

const guardOpts = () => ({ maxDevBps: PRICE_DEV_BPS, minSamples: PRICE_MIN_SAMPLES });

/// Take this block's reference quotes, judge them against history, then record them.
async function sampleSpot(st, pool, block) {
  const out = { leg1: null, leg2: null };
  if (PRICE_DEV_BPS === 0n) return out;
  for (const k of ["leg2", "leg1"]) {
    const q = await referenceQuote(k, st, pool, block);
    if (!q) continue;
    if (q.failed !== undefined) {
      out[k] = { failed: q.failed, config: !!q.config };
      continue;
    }
    out[k] = { rate: q.rate, verdict: spotGuard(priorRates(k, block.number), q.rate, guardOpts()) };
    pushSpot(k, block.number, q.rate);
  }
  return out;
}

/// After THIS keeper's convert lands, its own price impact is in the pool: leg 2's buy leaves fewer QUOTRON per
/// WETH, leg 1's sell less WETH per QPULL. Judged against the pre-convert median, that impact would read as
/// manipulation and hold every later convert until the median caught up. So take a reference quote right after
/// the convert for each leg that ran: within tolerance, it simply joins the history; beyond it, the history for
/// that leg restarts from the post-convert price (and re-warms for CONVERT_PRICE_MIN_SAMPLES - 1 more ticks).
/// A reference that cannot be read post-convert also restarts that leg's history. Neither ever loosens a floor:
/// a restarted guard HOLDS until it has its samples again.
async function reanchorSpotAfterConvert(st, pool, plan) {
  if (PRICE_DEV_BPS === 0n) return;
  let block = null;
  try {
    block = await latestBlock();
  } catch (e) {
    if (e instanceof TypeError) throw e;
  }
  for (const k of plan.qpullLeg ? ["leg1", "leg2"] : ["leg2"]) {
    let q;
    try {
      q = block ? await referenceQuote(k, st, pool, block) : { failed: "the latest block could not be read" };
    } catch (e) {
      if (e instanceof TypeError) throw e;
      q = { failed: e.shortMessage || e.message };
    }
    if (!q) continue; // no reference for this leg: there is no history to protect
    if (q.failed !== undefined) {
      spotHistory[k].length = 0;
      log(`convert: the ${SPOT_LABEL[k]} reference could not be read after this convert (${q.failed}); its spot `
        + "history restarts, so the guard re-warms before the next convert");
      continue;
    }
    const v = spotGuard(priorRates(k, block.number), q.rate, guardOpts());
    if (!v.ok && !v.warming) {
      spotHistory[k].length = 0;
      log(`convert: this convert moved the ${SPOT_LABEL[k]} reference price ${v.devBps} bps below its median; its spot `
        + `history restarts from the post-convert price (the guard re-warms for ${Math.max(PRICE_MIN_SAMPLES - 1, 0)} `
        + "more tick(s)), so the keeper's own price impact is not read as manipulation");
    }
    pushSpot(k, block.number, q.rate);
  }
}

/// null when the legs this convert runs are clear to send; otherwise { code, message }, the reason to hold this
/// tick. `code` is stable across ticks (an alarm signature), `message` carries the numbers.
function spotHold(plan, spot) {
  if (PRICE_DEV_BPS === 0n) return null;
  for (const k of plan.qpullLeg ? ["leg1", "leg2"] : ["leg2"]) {
    const label = SPOT_LABEL[k];
    const s = spot[k];
    if (!s) {
      // The owner's choice: the Quotron price check (leg 2, which carries ALL tax as WETH) fails CLOSED when it
      // is unavailable, and "not configured" is unavailable. Without it the leg-2 floor comes from the pool state at
      // this block alone (VIEW_QUOTER unset means bisection), which a price pushed down just before the read lowers
      // one for one. Donated QPULL (leg 1) keeps its documented exception: QPULL_QUOTER is optional.
      if (k === "leg2" && SPOT_UNAVAILABLE === "hold") {
        return {
          code: "unconfigured:leg2",
          message: "the WETH->QUOTRON price check is unavailable: VIEW_QUOTER is not set (or Treasury.wethQuotron() is "
            + "unset), so the spot guard cannot check the Quotron price. Holding (fail closed, "
            + "CONVERT_SPOT_UNAVAILABLE=hold). Fix: set VIEW_QUOTER=0xb8960fdC8A0Be155d196C2795b75747763562df2 (RH "
            + "mainnet). CONVERT_SPOT_UNAVAILABLE=proceed converts on bisection floors without the check",
        };
      }
      alarm(`convert:spot-unguarded:${k}`, "unguarded",
        `convert: the ${label} spot guard is NOT in force (no reference quote: ${k === "leg2" ? "VIEW_QUOTER not set, CONVERT_SPOT_UNAVAILABLE=proceed" : "QPULL_QUOTER is not set; it is optional, and only QPULL donated to the Treasury uses this leg"}). `
          + "Floors come from the pool state at this block alone.", { level: "info", repeatS: 3600 });
      continue;
    }
    clearAlarm(`convert:spot-unguarded:${k}`);
    if (s.failed !== undefined) {
      // The owner's choice: the reference quoter is CONFIGURED but no reference could be taken. Leg 2
      // carries all tax, and whoever can make that quote revert at a block would otherwise remove both the quoted
      // floor and this guard in the same tick. For leg 1 a configured QPULL_QUOTER is a promise that donated QPULL
      // is guarded, so a quoter on the wrong PoolManager or an unreadable or wrong pool binding breaks it exactly
      // like a failing quote. Default: fail closed.
      if (SPOT_UNAVAILABLE === "proceed") {
        alarm(`convert:spot-failed:${k}`, "proceed", `convert: the ${label} reference quote failed (${s.failed}); `
          + "CONVERT_SPOT_UNAVAILABLE=proceed, so this convert is NOT spot-guarded", { level: "info", repeatS: 3600 });
        continue;
      }
      if (s.config) {
        return {
          code: `misconfigured:${k}`,
          message: `the ${label} price check is unavailable although ${k === "leg1" ? "QPULL_QUOTER" : "VIEW_QUOTER"} is `
            + `configured: ${s.failed}. This does not clear by itself. Holding (fail closed, CONVERT_SPOT_UNAVAILABLE=hold)`
            + (k === "leg1"
              ? `: convert() must sell the ${plan.qpullIn} QPULL-wei donated to the Treasury first, so it waits until `
                + "this is fixed or the WETH backlog reaches maxWethConvertPerCall (the Treasury then skips the QPULL "
                + "leg). Fix the cause above (QPULL_QUOTER must be a quoter on the adapter's PoolManager), or unset "
                + "QPULL_QUOTER (the donated-QPULL leg then runs unguarded on bisection floors), or set "
                + "CONVERT_SPOT_UNAVAILABLE=proceed"
              : ". CONVERT_SPOT_UNAVAILABLE=proceed converts without the guard"),
        };
      }
      return {
        code: `unavailable:${k}`,
        message: `the ${label} reference quote failed at this block (${s.failed}), so the spot guard cannot check the `
          + "price. Holding (fail closed; CONVERT_SPOT_UNAVAILABLE=proceed converts without the guard while the check is unavailable)",
      };
    }
    clearAlarm(`convert:spot-failed:${k}`);
    const v = s.verdict;
    if (v.ok) continue;
    if (v.warming) {
      return { code: `warming:${k}`, message: `the ${label} spot guard is collecting history (${v.have}/${v.need} reference quotes)` };
    }
    return {
      code: `deviation:${k}`,
      message: `the ${label} reference price is ${v.devBps} bps below its median of the last ${PRICE_WINDOW} ticks `
        + `(now ${s.rate}, median ${v.median}; CONVERT_PRICE_DEVIATION_BPS=${PRICE_DEV_BPS}). Possible manipulation `
        + "just before this read; holding until the price and the median agree",
    };
  }
  return null;
}

/// Report a hold (or its end). A reference quote that keeps failing escalates to ERROR after CONVERT_FAIL_ALARM
/// ticks in a row; an unconfigured Quotron price check, and a configured quoter that cannot give a reference for a
/// reason that will not clear by itself (misconfigured:), are ERROR at once (config faults, not transients);
/// warm-up and deviation holds stay at info (the stall alarm covers a hold that never ends).
let spotUnavailableStreak = 0;
function noteSpotHold(hold) {
  if (!hold) {
    spotUnavailableStreak = 0;
    clearAlarm("convert:spot-hold");
    return;
  }
  const unavailable = hold.code.startsWith("unavailable:");
  spotUnavailableStreak = unavailable ? spotUnavailableStreak + 1 : 0;
  const loud = hold.code.startsWith("unconfigured:") || hold.code.startsWith("misconfigured:")
    || (unavailable && spotUnavailableStreak >= CONVERT_FAIL_ALARM);
  alarm("convert:spot-hold", `${hold.code}:${loud}`,
    `${loud ? "*** " : ""}convert: HOLDING, not sent: ${hold.message}`
      + `${loud ? `${unavailable ? ` (${spotUnavailableStreak} ticks in a row)` : ""} ***` : ""}`,
    { level: loud ? "error" : "info", repeatS: loud ? ALARM_REPEAT_S : 600 });
}

// ── floor bisection ──
// convert(minWeth, minQuotron) reverts when the pool cannot meet the floors, so the largest floor whose
// staticCall still succeeds IS the current output, to within the search precision. Read-only: every probe is
// a staticCall. It infers price from revert behaviour, so it is a FALLBACK, not a replacement for the quoters.
class BisectAbort extends Error {
  constructor(message, kind) {
    super(message);
    this.kind = kind;
  }
}
const MAX_PROBE = 1n << 200n;
const PROBE_CONFIRM_DELAY_MS = 300; // > ethers' default perform cacheTimeout of 250ms

/// One convert() simulation. kind: floor | abort | unknown (see classifyConvertRevert) | transport (the eth_call
/// itself failed: HTTP error, timeout; nothing was learned about convert()).
/// `blockTag` pins the simulation to one block. Every bisection probe passes the block the spot guard checked
/// (probes used to run at "latest", so the ~20-45 calls of one search could each see a
/// different pool, and a price pushed down AFTER the guard's reference read, during the search, lowered the floor
/// with no check). Pinned, the floor comes from the same state the guard vetted, and a price pushed down after that
/// block by more than CONVERT_SLIPPAGE_BPS makes the send's own simulation (at latest) revert on the floor instead.
/// Unpinned (undefined) is the report-only simulation, which mirrors the live preflight at latest.
async function convertProbe(w, q, blockTag = undefined) {
  try {
    await (blockTag === undefined ? treasury.convert.staticCall(w, q) : treasury.convert.staticCall(w, q, { blockTag }));
    return { ok: true };
  } catch (e) {
    if (e instanceof TypeError) throw e;
    if (!isRevertError(e)) return { ok: false, kind: "transport", reason: e.shortMessage || e.message };
    const reason = revertReason(e);
    return { ok: false, kind: classifyConvertRevert(reason), reason };
  }
}

/// The largest x in [1, 2^200] that `probe(x)` accepts, to ~0.5%. Returns { value } or { value: 0n, reason, kind }
/// (probe(1) itself failed); throws BisectAbort when a later probe cannot be judged. `probe` resolves to
/// { ok: true } or { ok: false, kind: floor | abort | unknown | transport, reason }.
/// ONLY a "floor" answer means "too high". Treating anything else as "too high" LOOSENS the floor: it lowers
/// `hi`, so the search converges on a smaller minimum output than the pool really delivers. An unknown answer (a
/// revert this file cannot name, or a revert WITHOUT data, which is also what ethers makes of a JSON-RPC error on
/// eth_call such as a rate limit or "header not found") says nothing about the floor. So unknown and transport
/// answers are re-probed once, and a second non-answer ABORTS the bisection: no floor, no convert, reported by
/// settleBisectionFailure and escalated after CONVERT_FAIL_ALARM attempts like every other convert failure.
async function maxFeasible(probe, seed) {
  // ethers caches an identical request, its error included, for cacheTimeout (250ms), so wait that out or the
  // "confirmation" is the cached failure.
  const confirmed = async (x, r) => {
    if (r.ok || (r.kind !== "unknown" && r.kind !== "transport")) return r;
    await sleep(PROBE_CONFIRM_DELAY_MS);
    return probe(x);
  };
  const first = await confirmed(1n, await probe(1n));
  if (!first.ok) return { value: 0n, reason: first.reason, kind: first.kind };
  const tooHigh = async (x) => {
    const r = await confirmed(x, await probe(x));
    if (r.ok) return false;
    if (r.kind === "floor") return true;
    // abort, transport, or unknown twice: nothing was learned about x, so no floor may be derived from this search
    throw new BisectAbort(r.reason, r.kind);
  };
  let lo = 1n;
  let hi = seed > 1n ? seed : 1n << 40n;
  while (!(await tooHigh(hi))) {
    lo = hi;
    hi <<= 2n;
    // A floor that is never refused is not being enforced: this leg is not running. Never send that "floor".
    if (hi > MAX_PROBE) return { value: 0n, kind: "abort", reason: "convert() accepted every floor up to 2^200 (the leg did not run)" };
  }
  while (hi - lo > lo / 200n + 1n) { // ~0.5% precision
    const mid = (lo + hi) / 2n;
    if (await tooHigh(mid)) hi = mid; else lo = mid;
  }
  return { value: lo };
}

let lastOutW = 0n; // seeds only; never a floor by themselves
let lastOutQ = 0n;
/// Each leg is bisected ONLY when that leg runs AND its own quoter cannot price it. A WETH-only sweep
/// never probes leg 1 (convert() ignores minWethOut then, so every probe would "succeed" up to 2^200) and
/// never touches lastOutW. Leg 1 is probed with minQuotronOut = 1, so leg 2 refuses only when it cannot run at
/// all (its router's own error, a revert without data): a failure is attributed to leg 1 only by isLeg1Revert.
///   { minWeth }                 a floor the next call can satisfy
///   { zeroLeg1: true, reason }  leg 1 cannot deliver 1 wei of WETH: dust QPULL
///   { failed, kind }            convert() cannot run for a reason no leg-1 floor fixes (kind: abort, unknown or
///                               transport; settleBisectionFailure decides which leg, if any, to blame)
/// `blockTag`: the block every probe is pinned to (the one the spot guard checked; see convertProbe).
async function bisectLeg1(blockTag) {
  try {
    const r = await maxFeasible((w) => convertProbe(w, 1n, blockTag), lastOutW);
    if (r.value === 0n) return r.kind === "floor" ? { zeroLeg1: true, reason: r.reason } : { failed: r.reason, kind: r.kind };
    lastOutW = r.value;
    const minWeth = withSlippage(r.value, CONVERT_SLIPPAGE);
    return minWeth === 0n ? { zeroLeg1: true, reason: `leg 1 yields ${r.value} wei, which floors to 0` } : { minWeth };
  } catch (e) {
    if (e instanceof BisectAbort) return { failed: e.message, kind: e.kind };
    throw e;
  }
}

/// Leg 2's floor by bisection, with leg 1 pinned at `minWeth` (0 on a WETH-only sweep), every probe at `blockTag`.
///   { minQuotron } | { failed, kind }
async function bisectLeg2(minWeth, blockTag) {
  try {
    const r = await maxFeasible((q) => convertProbe(minWeth, q, blockTag), lastOutQ);
    if (r.value === 0n) return { failed: r.reason, kind: r.kind };
    lastOutQ = r.value;
    const minQuotron = withSlippage(r.value, CONVERT_SLIPPAGE);
    return minQuotron === 0n
      ? { failed: `the prize WETH buys only ${r.value} wei of QUOTRON, which floors to 0`, kind: "floor" }
      : { minQuotron };
  } catch (e) {
    if (e instanceof BisectAbort) return { failed: e.message, kind: e.kind };
    throw e;
  }
}

/// Both floors by bisection (the retry after quoted floors failed to simulate), pinned to `blockTag`.
async function bisectConvertFloors(plan, blockTag) {
  let minWeth = 0n;
  if (plan.qpullLeg) {
    const b1 = await bisectLeg1(blockTag);
    if (!b1.minWeth) return { ...b1, leg: 1 };
    minWeth = b1.minWeth;
  }
  const b2 = await bisectLeg2(minWeth, blockTag);
  if (b2.minQuotron === undefined) return { ...b2, leg: 2 };
  return { minWeth, minQuotron: b2.minQuotron };
}

// Convert failures are reported, and repeated ones escalate. NotKeeper is a configuration fault.
let convertFailStreak = 0;
function noteConvertFailure(reason) {
  convertFailStreak++;
  if (reasonName(reason) === "NotKeeper") {
    alarm("convert:notkeeper", "NotKeeper", `*** FATAL CONFIG: convert() reverts NotKeeper for ${convertAddress()}. `
      + `Owner fix: Treasury.setKeeper(${convertAddress()}, true). ***`, { repeatS: 600 });
    return;
  }
  const persistent = convertFailStreak >= CONVERT_FAIL_ALARM;
  logError(`${persistent ? "*** " : ""}convert: convert() did not go through: ${describeRevert(reason)} `
    + `(${convertFailStreak} attempt(s) in a row)`
    + (persistent ? ". Tax is not converting, so the prize vaults are not being funded. ***" : ""));
}
function noteConvertSuccess() {
  if (convertFailStreak) log(`convert: recovered after ${convertFailStreak} failed attempt(s)`);
  convertFailStreak = 0;
  clearAlarm("convert:notkeeper");
}

/// The dust-donation grief (fixed by configuration, by the owner's choice). The Treasury holds QPULL at or above
/// convertThreshold, so convert() must sell it first, and that sale cannot produce a usable floor.
function qpullLegBlocked(st, plan, cause, { dust }) {
  alarm("convert:qpull-leg", `${dust}:${st.qpullBal}:${st.threshold}`,
    `*** convert: BLOCKED BY THE QPULL LEG. The Treasury holds ${st.qpullBal} QPULL-wei (convertThreshold `
      + `${st.threshold}), so convert() must sell ${plan.qpullIn} of it first, and that sale cannot be priced or run: `
      + `${cause}. Tax arrives as WETH, so this QPULL was DONATED. Until it clears, convert() runs only once the WETH `
      + `backlog reaches maxWethConvertPerCall (${st.maxWethConv}), so prize funding comes in capped lumps. `
      + (dust
        ? `This is the dust-QPULL grief. Owner fix: Treasury.setConvertThreshold to a value above ${st.qpullBal} `
          + "(deploy guidance: at least 1e18, sized so an exempt sell of the threshold quotes well above 0 wei). ***"
        : "Fix the cause above (pool binding, quoter or adapter). ***"),
    { repeatS: ALARM_REPEAT_S });
}

// "No successful convert in N hours while tax is pending".
let convertPendingSince = null; // epoch seconds of the first tick with convertible tax since the last success
let lastConvertOkAt = null;
function trackPending(st, pending) {
  const nowS = Date.now() / 1000;
  if (!pending) {
    convertPendingSince = null;
    clearAlarm("convert:stall", "convert: nothing pending any more; the stall alarm is clear");
    return;
  }
  if (convertPendingSince === null) convertPendingSince = nowS;
  const waited = nowS - convertPendingSince;
  if (waited >= CONVERT_STALL_ALARM_S) {
    alarm("convert:stall", "stall",
      `*** convert: NO SUCCESSFUL CONVERT for ${(waited / 3600).toFixed(1)}h while tax is pending (WETH ${st.wethHeld} wei, `
        + `QPULL ${st.qpullBal} wei${lastConvertOkAt ? `; last success ${new Date(lastConvertOkAt * 1000).toISOString()}` : "; none since startup"}). `
        + "The prize vaults and the team + operations stream are not being funded. "
        + (CONVERT_MODE === "simulate" ? "ENABLE_CONVERT=simulate sends nothing: set it to true once the simulation succeeds. ***" : "See the convert lines above. ***"),
      { repeatS: 3600 });
  }
}

/// Derive both floors for this plan at `block`, each from its quoter, or by bisection when that quoter cannot
/// price it. Alarms and returns null when no safe floor exists.
async function deriveFloors(st, plan, pool, block) {
  let minWeth = 0n;
  const sources = [];
  if (plan.qpullLeg) {
    if (pool?.broken) {
      // A wrong binding disables ONLY this leg (never bisected: the keeper cannot vouch for a pool
      // its own checks reject). The WETH-only sweep never touches this pool and keeps running.
      qpullLegBlocked(st, plan, `the QPULL/WETH pool binding is wrong (${pool.broken.join("; ")})`, { dust: false });
      return null;
    }
    const q1 = await quoteLeg1(pool, plan.qpullIn, block);
    if (q1.unavailable) {
      // Said once per cause, not every tick, and it no longer claims that nothing converts.
      // A live convert with the guard on and CONVERT_SPOT_UNAVAILABLE=hold reaches this with QPULL_QUOTER configured
      // only when this leg's reference quote at this block succeeded (spotHold holds otherwise) and the quote at
      // this slice's size did not: the guard is in force, and the bisection runs at the block it checked.
      alarm("convert:leg1-quote", q1.code,
        `convert: the QPULL leg is needed (${plan.qpullIn} QPULL-wei donated to the Treasury, at or above convertThreshold) `
          + `but it cannot be quoted: ${q1.unavailable}. Deriving its floor by bisection. Tax itself arrives as WETH and `
          + "converts without this leg; only QPULL donated to the Treasury uses it.", { level: "info", repeatS: 86_400 });
      const b1 = await bisectLeg1(block.number);
      if (!b1.minWeth) return settleBisectionFailure(st, plan, { ...b1, leg: 1 }, pool);
      minWeth = b1.minWeth;
      sources.push("leg 1 by bisection");
    } else if (q1.minWeth === 0n) {
      qpullLegBlocked(st, plan, `an exempt sell of ${plan.qpullIn} QPULL-wei quotes 0 usable WETH (taxed quote ${q1.outWeth} wei at ${q1.taxBps} bps, floors to 0)`, { dust: true });
      return null;
    } else {
      clearAlarm("convert:leg1-quote");
      minWeth = q1.minWeth;
      sources.push(`leg 1 quoted at ${q1.taxBps} bps sell tax`);
    }
  }
  const basis = leg2Basis({ wethHeld: st.wethHeld, qpullLeg: plan.qpullLeg, minWeth, maxWethConv: st.maxWethConv });
  const prizeWeth = prizeWethOf(basis, st.teamBps);
  if (prizeWeth === 0n) {
    // Unreachable: a WETH-only sweep holds at least 1 wei (convertPlan), prizeWethOf(1) is 1, and a QPULL leg here
    // has minWeth > 0.
    logError(`convert: the prize leg would swap 0 WETH (basis ${basis}); skipping`);
    return null;
  }
  let minQuotron;
  const q2 = await quoteLeg2(prizeWeth, st.wethQuotron, block.number);
  if (q2.unavailable) {
    alarm("convert:leg2-quote", q2.code, `convert: WETH->QUOTRON cannot be quoted (${q2.unavailable}); deriving its floor by bisection`,
      { level: "info", repeatS: 3600 });
    const b2 = await bisectLeg2(minWeth, block.number);
    if (b2.minQuotron === undefined) return settleBisectionFailure(st, plan, { ...b2, leg: 2 }, pool);
    minQuotron = b2.minQuotron;
    sources.push("leg 2 by bisection");
  } else if (q2.minQuotron === 0n) {
    alarm("convert:leg2-zero", "zero", `convert: ${prizeWeth} prize WETH-wei quotes ${q2.out} QUOTRON-wei, which floors to 0. `
      + "Waiting for more tax (if this repeats, raise MIN_WETH_CONVERT_WEI, and check that maxWethConvertPerCall is "
      + "not set too small to buy any QUOTRON).", { level: "info" });
    return null;
  } else {
    clearAlarm("convert:leg2-zero");
    clearAlarm("convert:leg2-quote");
    minQuotron = q2.minQuotron;
    sources.push("leg 2 quoted");
  }
  const bisected = sources.some((x) => x.includes("bisection"));
  if (bisected) log(`convert: floors ${ethers.formatEther(minWeth)} WETH / ${ethers.formatEther(minQuotron)} QUOTRON (${sources.join(", ")})`);
  return { minWeth, minQuotron, source: bisected ? "bisection" : "quoters", detail: sources.join(", ") };
}

/// Report a bisection that found no floor. Always returns null.
/// "BLOCKED BY THE QPULL LEG" is reserved for a leg-1 floor failure (dust) and for reverts only
/// leg 1 can raise (isLeg1Revert). An RPC failure, a revert without data or the QUOTRON router's own error is
/// reported as a convert failure, by kind, and escalates like any other.
function settleBisectionFailure(st, plan, b, pool) {
  if (b.zeroLeg1) {
    qpullLegBlocked(st, plan, `bisection: convert() cannot deliver even 1 wei of WETH from leg 1 (${b.reason})`, { dust: true });
    return null;
  }
  if (reasonName(b.failed) === "NotKeeper") {
    noteConvertFailure("NotKeeper");
    return null;
  }
  if (plan.qpullLeg && b.leg === 1 && b.kind !== "transport" && isLeg1Revert(b.failed, pool?.binding?.key.hooks)) {
    qpullLegBlocked(st, plan, `bisection: ${describeRevert(b.failed)}`, { dust: false });
    return null;
  }
  const why = {
    transport: "the RPC failed twice in a row",
    unknown: "a probe answered twice with a revert that says nothing about the floor (an unnamed error, or no revert "
      + "data, which is also how a JSON-RPC error such as a rate limit reads), so the search was aborted, not guessed",
    floor: "the swap cannot meet even a minimal floor",
  }[b.kind] ?? "convert() cannot run";
  noteConvertFailure(`no floor could be derived by bisection (probing leg ${b.leg}; ${why}): ${describeRevert(b.failed)}`);
  return null;
}

async function latestBlock() {
  const block = await provider.getBlock("latest");
  if (!block) throw new Error("the RPC returned no latest block");
  return block;
}

/// Has go-live happened? True once the QPULL/WETH pool hook's launchTime() is stamped (write-once, so a true is
/// cached for good). Re-checked at most every 5 minutes while false; a failed read counts as "not known yet".
let poolLiveSeen = false;
let poolLiveNextCheckS = 0;
async function poolIsLive(blockTag) {
  if (poolLiveSeen) return true;
  const nowS = Date.now() / 1000;
  if (nowS < poolLiveNextCheckS) return false;
  poolLiveNextCheckS = nowS + 300;
  try {
    const adapterAddr = await treasuryView.qpullWeth({ blockTag });
    if (sameAddr(adapterAddr, ethers.ZeroAddress)) return false;
    const adapter = new ethers.Contract(adapterAddr, qpullAdapterAbi, provider);
    if (!(await adapter.poolKeySet({ blockTag }))) return false;
    const k = await adapter.poolKey({ blockTag });
    poolLiveSeen = BigInt(await new ethers.Contract(k[4], taxHookAbi, provider).launchTime({ blockTag })) !== 0n;
    return poolLiveSeen;
  } catch (e) {
    if (e instanceof TypeError) throw e;
    return false;
  }
}

let thresholdZeroWarned = false;
let capReadFailStreak = 0;
let onceConvertNoted = false;
async function runConvert() {
  if (!treasury) return;
  // ENABLE_CONVERT defaults to "false": convert is the one privileged call, and it needs the convert key's role,
  // armed caps and working quoters before it may send. But caps armed + converting disabled is, with certainty,
  // a misconfiguration (convert() reverts NotConfigured until the owner arms BOTH caps, which is GoLiveMainnet
  // step 1): tax accrues as WETH in the Treasury, no QUOTRON is bought, the prize vaults stay empty and every
  // draw voids under minPot. Say so LOUDLY, every tick.
  if (CONVERT_MODE === "off") {
    try {
      const [mc, mw] = await Promise.all([treasuryView.maxConvertPerCall(), treasuryView.maxWethConvertPerCall()]);
      // Caps alone do not prove go-live. DeployTestnet arms 1-wei placeholder caps (its in-deploy lockRouting
      // needs both armed), so a testnet stack read "caps armed" from deploy until go-live and raised this alarm
      // falsely. Alarm only when the pool is ALSO live (the hook's launchTime is stamped).
      if (mc !== 0n && mw !== 0n && (await poolIsLive())) {
        logError(
          "*** MISCONFIGURED: the pool is live and the Treasury convert caps are armed, but ENABLE_CONVERT is false. " +
            "No tax is being converted to QUOTRON, so the prize vaults will never fund and every draw will void " +
            "under minPot. Set ENABLE_CONVERT=simulate to see the floors and a convert() simulation without " +
            "sending anything, then ENABLE_CONVERT=true. ***",
        );
      }
    } catch {
      // read failure: stay quiet rather than cry wolf on an unreachable Treasury
    }
    return;
  }
  const block = await latestBlock();
  const blockTag = block.number;
  // Both per-call caps ship as 0 = "not configured" and convert() reverts
  // NotConfigured until the owner arms BOTH (GoLive step 1). Every path below fails CLOSED.
  let maxConv;
  let maxWethConv;
  try {
    [maxConv, maxWethConv] = await Promise.all([treasuryView.maxConvertPerCall({ blockTag }), treasuryView.maxWethConvertPerCall({ blockTag })]);
  } catch (e) {
    if (e instanceof TypeError) throw e;
    // This returns before trackPending, so a read that keeps failing (a wrong TREASURY, an RPC that
    // refuses block-pinned eth_call) would never reach the stall alarm. It escalates on its own instead.
    capReadFailStreak++;
    const loud = capReadFailStreak >= CONVERT_FAIL_ALARM;
    alarm("convert:caps-read", loud ? "loud" : "quiet", loud
      ? `*** convert: the Treasury convert caps could not be read for ${capReadFailStreak} ticks in a row `
        + `(${e.shortMessage || e.message}). Convert is NOT running and cannot see whether tax is pending. Check `
        + `TREASURY=${TREASURY} and the RPC (a node that refuses block-pinned eth_call fails here too). ***`
      : `convert: cap read failed (${e.shortMessage || e.message}); skipping this tick (draws still run)`,
    { level: loud ? "error" : "info" });
    return;
  }
  if (capReadFailStreak) {
    capReadFailStreak = 0;
    clearAlarm("convert:caps-read", "convert: the Treasury convert caps are readable again");
  }
  if (maxConv === 0n || maxWethConv === 0n) {
    // Before go-live this is expected (info, hourly). Once the pool hook's launchTime is stamped, swaps are paying
    // tax that convert() cannot touch: ERROR.
    const live = await poolIsLive(blockTag);
    alarm("convert:caps", `${maxConv}:${maxWethConv}:${live}`, live
      ? `*** convert: caps NOT ARMED (maxConvertPerCall=${maxConv}, maxWethConvertPerCall=${maxWethConv}) although the `
        + "QPULL/WETH pool is LIVE (its hook's launchTime is set). Treasury.convert() reverts NotConfigured, so all tax "
        + "sits unconverted: no prize funding and no team + operations WETH. Owner fix: GoLive step 1 "
        + "(setMaxConvertPerCall and setMaxWethConvertPerCall). ***"
      : `convert: caps NOT ARMED (maxConvertPerCall=${maxConv}, maxWethConvertPerCall=${maxWethConv}). `
        + "Treasury.convert() reverts NotConfigured until the owner sets BOTH (GoLive step 1); skipping (draws still run)",
    { level: live ? "error" : "info", repeatS: live ? ALARM_REPEAT_S : 3600 });
    return;
  }
  clearAlarm("convert:caps");
  // The dust floor is clamped to the cap (wethDustFloor), so a cap below MIN_WETH_CONVERT_WEI no
  // longer stalls convert. The two settings still disagree, and the operator should fix the keeper's side.
  if (maxWethConv < MIN_WETH_CONVERT) {
    alarm("convert:dust-cap", `${maxWethConv}`,
      `*** convert: Treasury.maxWethConvertPerCall (${maxWethConv} wei) is BELOW MIN_WETH_CONVERT_WEI (${MIN_WETH_CONVERT} `
        + "wei). The keeper clamps its dust floor to the cap, so full slices still convert, but the settings disagree. "
        + `Fix: set MIN_WETH_CONVERT_WEI to at most ${maxWethConv} (README "Convert"). ***`, { repeatS: 3600 });
  } else {
    clearAlarm("convert:dust-cap", "convert: MIN_WETH_CONVERT_WEI is no longer above maxWethConvertPerCall");
  }
  // convert() is onlyKeeper. Checked BEFORE quoting, so a missing Treasury.setKeeper is named as the cause.
  // A failed READ of the role is not a reason to skip the tick: the convert() simulation below
  // reverts NotKeeper by name if the role really is missing.
  try {
    if (!(await treasuryRole.isKeeper(convertAddress(), { blockTag }))) {
      noteConvertFailure("NotKeeper");
      return;
    }
    clearAlarm("convert:role-read");
  } catch (e) {
    if (e instanceof TypeError) throw e;
    alarm("convert:role-read", "read", `convert: could not read Treasury.isKeeper (${e.shortMessage || e.message}); `
      + "continuing, the convert() simulation reports NotKeeper if the role is missing", { level: "info" });
  }

  const st = await readConvertState(blockTag, { maxConv, maxWethConv });
  // The Treasury-level assertions (QPULL, WETH, WETH_QUOTRON_ADAPTER) describe every convert: a mismatch stops ALL
  // of them.
  const envProblems = treasuryEnvProblems(st, process.env);
  if (envProblems.length) {
    alarm("convert:config", envProblems.join(" | "), `*** FATAL CONFIG (convert disabled until fixed): ${envProblems.join(". ")}. ***`);
    return;
  }
  clearAlarm("convert:config");
  // The QPULL/WETH pool only serves leg 1 (donated QPULL). A binding READ failure leaves leg 1 unquotable (with
  // QPULL_QUOTER configured, the spot guard then HOLDS a convert that needs leg 1: referenceQuote), and a WRONG
  // binding (including a stale QPULL_POOL_* assertion, e.g. QPULL_POOL_HOOK from before the hook re-mine)
  // disables leg 1 with its own repeated ERROR. Neither stops the WETH-only sweep.
  let pool;
  try {
    pool = await resolvePoolBinding(st, blockTag);
  } catch (e) {
    if (e instanceof TypeError) throw e;
    pool = {
      readFailed: true,
      unavailable: `could not read the QPULL/WETH pool binding (${isRevertError(e) ? revertReason(e) : e.shortMessage || e.message})`,
    };
  }
  if (pool.broken) {
    alarm("convert:binding", pool.broken.join(" | "),
      `*** CONFIG: the QPULL/WETH pool binding is wrong, so the QPULL leg is DISABLED until it is fixed: `
        + `${pool.broken.join(". ")}. Only QPULL donated to the Treasury uses that leg; tax arrives as WETH and `
        + "WETH-only sweeps continue. ***");
  } else if (pool.binding) {
    clearAlarm("convert:binding", "convert: the QPULL/WETH pool binding checks out again; the QPULL leg is re-enabled");
  }
  if (st.threshold === 0n && !thresholdZeroWarned) {
    thresholdZeroWarned = true;
    logError("convert: Treasury.convertThreshold() is 0. Any QPULL donated to the Treasury, even 1 wei, forces the "
      + "QPULL leg and can block convert() (the dust-QPULL grief). Owner fix: setConvertThreshold(>= 1e18).");
  }

  const plan = convertPlan({ ...st, minWethConvert: MIN_WETH_CONVERT }); // pure over `st`; the spot sample does not feed it
  if (convertLandedLate) {
    // TIMED-OUT SENDS: a convert that did not confirm in time landed later and succeeded (runTimedOutSends or fire
    // logged it). Book it as the success it was and re-anchor the spot history on the post-convert price, as
    // convertSucceeded does for a convert confirmed in time, BEFORE this tick's sample is judged against the median.
    convertLandedLate = false;
    noteConvertSuccess();
    lastConvertOkAt = Date.now() / 1000;
    await reanchorSpotAfterConvert(st, pool, plan);
  }
  const spot = await sampleSpot(st, pool, block);
  if (plan.subThresholdQpull) {
    alarm("convert:subthreshold", `${st.qpullBal}`, `convert: ${st.qpullBal} QPULL-wei (donated) sits below convertThreshold `
      + `${st.threshold} and waits; WETH converts without it`, { level: "info", repeatS: 86_400 });
  }
  if (plan.action === "skip") {
    // A deliberate skip is final for this tick. It is never handed to bisection.
    // "Pending" is judged on the UNCAPPED balance against MIN_WETH_CONVERT, not on the skip itself. wethDustFloor
    // guarantees a dust skip has wethHeld < MIN_WETH_CONVERT (so this is false today); written out so the stall
    // alarm can never again be silenced by a skip while a real backlog waits.
    trackPending(st, st.wethHeld >= MIN_WETH_CONVERT);
    if (plan.why === "dust") {
      alarm("convert:dust", "dust", `convert: WETH ${plan.wethOut} wei is below the ${plan.dustFloor} wei dust floor `
        + "(MIN_WETH_CONVERT_WEI, capped at maxWethConvertPerCall) and there is no QPULL leg; waiting for more tax",
      { level: "info", repeatS: 86_400 });
    }
    return;
  }
  clearAlarm("convert:dust");
  trackPending(st, true);
  if (ONCE && CONVERT_MODE === "on" && !onceConvertNoted) {
    onceConvertNoted = true;
    log("convert: --once NEVER sends convert(), whatever ENABLE_CONVERT, VIEW_QUOTER or the spot guard say. It reports "
      + "the floors and a convert() simulation instead, exactly like ENABLE_CONVERT=simulate. Run the loop to send.");
  }
  // TIMED-OUT SENDS: an earlier convert is still pending (runTimedOutSends checked it this tick and said so once).
  // Deriving floors now would spend the bisection calls on a send fire() refuses; trackPending above keeps counting.
  if (timedOutSends.get("treasury.convert")?.held) return;

  await attemptConvert(st, plan, pool, block, spot, { retry: true });
}

async function convertSucceeded(st, plan, pool) {
  noteConvertSuccess();
  lastConvertOkAt = Date.now() / 1000;
  trackPending(st, false);
  await reanchorSpotAfterConvert(st, pool, plan); // our own price impact is not manipulation
}

async function attemptConvert(st, plan, pool, block, spot, { retry }) {
  // In report-only mode (ENABLE_CONVERT=simulate, or --once with true) the floors and the simulation
  // are still reported while the guard holds (a warming guard would otherwise hide them for the first ticks); a
  // live run holds BEFORE deriving floors, which spares the bisection calls a held tick would waste.
  const hold = spotHold(plan, spot);
  if (!CONVERT_REPORT_ONLY) {
    noteSpotHold(hold);
    if (hold) return;
  }
  const floors = await deriveFloors(st, plan, pool, block);
  if (!floors) return;
  const label = `${ethers.formatEther(floors.minWeth)} WETH / ${ethers.formatEther(floors.minQuotron)} QUOTRON `
    + `(${floors.detail}; ${plan.qpullLeg ? `QPULL leg ${plan.qpullIn} wei` : "WETH-only sweep"})`;
  if (CONVERT_REPORT_ONLY) {
    // The ONLY convert() call in report-only mode is this staticCall. Nothing below it runs, so nothing is sent.
    const p = await convertProbe(floors.minWeth, floors.minQuotron);
    log(`convert [${REPORT_TAG}]: floors ${label}; convert() simulation ${p.ok ? "SUCCEEDS" : `REVERTS ${describeRevert(p.reason)}`}; `
      + `spot guard ${hold ? `HOLDING (${hold.message}), so a live run would NOT send this tick` : "clear"}. `
      + `Nothing sent (${REPORT_WHY}).`);
    return;
  }
  let revertedWith = null;
  let held = false;
  const sent = await fire("treasury.convert", treasury, "convert", [floors.minWeth, floors.minQuotron], {
    onRevert: (reason) => { revertedWith = reason; },
    onHeld: () => { held = true; },
  });
  if (sent) {
    log(`convert: converted with floors ${label}`);
    await convertSucceeded(st, plan, pool);
    return;
  }
  // An earlier convert that timed out is still pending, or has just landed (fire said which, once): not a failure.
  // The stall alarm keeps counting (trackPending ran before this), so a convert stuck for hours still pages.
  if (held) return;
  if (revertedWith === null) {
    noteConvertFailure("the send failed (see the line above)");
    return;
  }
  // A quoted floor that the simulation refuses is logged by name, then retried ONCE with bisection
  // floors at a fresh block, re-checked by the spot guard. Any other revert is reported as it is.
  const kind = classifyConvertRevert(revertedWith);
  if (retry && floors.detail.includes("quoted") && kind !== "abort") {
    logError(`convert: the quoted floors ${label} do not simulate (${describeRevert(revertedWith)}); retrying with bisection floors`);
    const block2 = await latestBlock();
    const spot2 = await sampleSpot(st, pool, block2);
    const hold2 = spotHold(plan, spot2);
    noteSpotHold(hold2);
    if (hold2) return;
    const full = await bisectConvertFloors(plan, block2.number); // pinned to the block spot2 just vetted
    if (full.minQuotron === undefined) { settleBisectionFailure(st, plan, full, pool); return; }
    const b = full;
    log(`convert: floors derived by bisection: ${ethers.formatEther(b.minWeth)} WETH / ${ethers.formatEther(b.minQuotron)} QUOTRON`);
    let again = null;
    let held2 = false;
    const sent2 = await fire("treasury.convert", treasury, "convert", [b.minWeth, b.minQuotron], {
      onRevert: (r) => { again = r; },
      onHeld: () => { held2 = true; },
    });
    if (sent2) {
      log(`convert: converted with bisection floors ${ethers.formatEther(b.minWeth)} WETH / ${ethers.formatEther(b.minQuotron)} QUOTRON`);
      await convertSucceeded(st, plan, pool);
      return;
    }
    if (held2) return;
    noteConvertFailure(again ?? "the send failed (see the line above)");
    return;
  }
  noteConvertFailure(revertedWith);
}

// ── EXPIRED-CLAIM SWEEP ─────────────────────────────────────────────────────────────────────────────
//    `ClaimManager.sweepExpired(id)` is the ONLY path that releases a vault reservation once a claim's
//    30-day deadline passes, and this job is the only caller.
//
//    WHY IT MATTERS: `freeBalance() = balance - unclaimedReserve`, and every engine sizes its pot off
//    freeBalance. A prize nobody claims therefore subtracts from the pot FOREVER, not just until its
//    deadline: pots drift down, cross `minPot`, and the draws start taking their no-pay branch, which looks
//    exactly like "no one is playing". A winner CLAIMING does not help (claim() drops balance and
//    unclaimedReserve together); only sweepExpired returns value to the pot.
//
//    SCAN SHAPE. Ids are 1..nextClaimId, assigned in ascending order, and all three engines stamp
//    `uint64(block.timestamp + CLAIM_WINDOW)` with the SAME 30-day constant -- so deadlines are
//    monotonically non-decreasing in id, and the expired claims are always a PREFIX. That is what makes
//    this cheap: stop at the first unexpired claim and the scan never walks the whole table. `sweepCursor`
//    then advances past the contiguous settled prefix so the work per tick tends to zero.
//    IF CLAIM_WINDOW EVER BECOMES PER-ENGINE OR VIRTUAL, THE EARLY STOP BELOW IS WRONG -- it is guarded by
//    a monotonicity check that logs and keeps scanning rather than silently skipping claims.
// ENABLE_SWEEP, MULTICALL3 and CLAIM_MANAGER are parsed (and validated) with the other knobs in CONFIG.
const SWEEP_READ_CHUNK = 200; // ids per multicall aggregate3

const claimManagerAbi = [
  "function nextClaimId() view returns (uint256)",
  "function claims(uint256) view returns (address vault, address recipient, uint256 amount, uint64 deadline, bool settled)",
  "function sweepExpired(uint256) external",
];
// Declared as deployed: Multicall3.aggregate3 is payable, not view (the selector is the same either way). This file
// only ever calls it through staticCall on a read-only provider, so nothing is sent.
const multicall3Abi = [
  "function aggregate3((address target,bool allowFailure,bytes callData)[]) payable returns ((bool success,bytes returnData)[])",
];

let claimManager = null;
let multicall = null;
let sweepCursor = 1n;
let sweepNextRun = 0; // epoch seconds; 0 = run on the first tick

/// Resolve the ClaimManager once. Env wins; otherwise ask an engine, which is authoritative because the
/// engine is the thing that registers into it.
let claimManagerUnresolved = false; // latch so the warning below is printed once, not every tick
async function resolveClaimManager() {
  if (claimManager) return claimManager;
  if (claimManagerUnresolved) return null;
  let addr = CLAIM_MANAGER || "";
  if (!addr) {
    // Bound to its own ABI: the engine contracts above do not declare claimManager(), and calling an
    // undeclared method is a TypeError, not a revert.
    const lookupAbi = ["function claimManager() view returns (address)"];
    // RaffleEngine, HolderDrawEngine and LeaderboardEngine all declare `IClaimManager public immutable
    // claimManager`, so on a correct deploy this read has no revert path, and a failure is an RPC error or a
    // wrong address. Neither may latch the sweeper off: ethers reports a JSON-RPC error on eth_call as a
    // revert (isRevertError), so no error of any kind is read as "this engine has no ClaimManager".
    const failures = [];
    for (const [label, eng] of [["RAFFLE_ENGINE", RAFFLE_ENGINE], ["HOLDER_ENGINE", HOLDER_ENGINE],
      ["LEADERBOARD_ENGINE", LEADERBOARD_ENGINE]]) {
      if (!eng) continue;
      try {
        const a = await new ethers.Contract(eng, lookupAbi, provider).claimManager();
        if (a && a !== ethers.ZeroAddress) { addr = a; break; }
      } catch (e) {
        failures.push(`${label}: ${isRevertError(e) ? revertReason(e) : e.shortMessage || e.message}`);
      }
    }
    if (!addr && failures.length) {
      // Not latched: retried on the next sweep run (every SWEEP_INTERVAL_S), and reported every time.
      logError("claim sweeper: could not resolve a ClaimManager this run, retrying next run. claimManager() "
        + `failed on ${failures.join("; ")}. Expired prizes stay reserved until it resolves; set CLAIM_MANAGER `
        + "in .env to skip this lookup.");
      return null;
    }
  }
  if (!addr || addr === ethers.ZeroAddress) {
    claimManagerUnresolved = true;
    logError("claim sweeper: DISABLED — could not resolve a ClaimManager from CLAIM_MANAGER or any engine's "
      + "claimManager(). Expired prizes will stay reserved and every pot will shrink permanently. Set "
      + "CLAIM_MANAGER in .env.");
    return null;
  }
  claimManager = new ethers.Contract(addr, claimManagerAbi, wallet);
  log(`claim sweeper: ClaimManager ${addr}`);
  return claimManager;
}

/// Read a contiguous id range. Uses Multicall3 when present (RH has the canonical deployment) and falls
/// back to plain calls, because a sweeper that dies without a multicall is worse than a slow one.
async function readClaims(cm, ids) {
  if (multicall === null) {
    // An RPC failure here propagates and is retried next run, rather than disabling multicall for good.
    const code = await provider.getCode(MULTICALL3);
    multicall = code && code !== "0x" ? new ethers.Contract(MULTICALL3, multicall3Abi, provider) : false;
  }
  if (multicall) {
    const calls = ids.map((id) => [cm.target, true, cm.interface.encodeFunctionData("claims", [id])]);
    const res = await multicall.aggregate3.staticCall(calls);
    return res.map((r, i) => {
      if (!r[0] || r[1] === "0x") return null;
      const d = cm.interface.decodeFunctionResult("claims", r[1]);
      return { id: ids[i], deadline: d[3], settled: d[4], amount: d[2] };
    });
  }
  const out = [];
  for (const id of ids) {
    try {
      const d = await cm.claims(id);
      out.push({ id, deadline: d[3], settled: d[4], amount: d[2] });
    } catch (e) { out.push(null); } // an unreadable row stops the cursor here; it is re-read next run
  }
  return out;
}

async function runSweepExpired() {
  if (!ENABLE_SWEEP) return;
  const nowS = Math.floor(Date.now() / 1000);
  if (nowS < sweepNextRun) return;
  sweepNextRun = nowS + SWEEP_INTERVAL_S;

  const cm = await resolveClaimManager();
  if (!cm) return; // resolveClaimManager has already logged why

  const last = await cm.nextClaimId();
  if (last < sweepCursor) return; // nothing registered past the cursor yet

  const now = BigInt(nowS);
  const expired = [];
  let cursorCandidate = sweepCursor;
  let cursorStillContiguous = true;
  let prevDeadline = 0n;
  let monotonic = true; // deadlines ascend with id -> expired claims are a prefix -> we may stop early
  let stop = false;
  let capped = false;

  for (let start = sweepCursor; start <= last && !stop; start += BigInt(SWEEP_READ_CHUNK)) {
    const ids = [];
    for (let i = start; i <= last && ids.length < SWEEP_READ_CHUNK; i++) ids.push(i);
    const rows = await readClaims(cm, ids);
    for (const r of rows) {
      if (!r) { cursorStillContiguous = false; continue; }
      if (r.settled) {
        if (cursorStillContiguous) cursorCandidate = r.id + 1n;
        continue;
      }
      cursorStillContiguous = false;
      if (monotonic && r.deadline < prevDeadline) {
        // Deadlines went backwards, so expired claims are NOT a prefix and stopping early would skip real
        // work. Give up the optimisation for this run and walk the whole range instead.
        monotonic = false;
        log(`claim sweeper: deadlines not monotonic at id ${r.id} — scanning the full range this pass.`);
      }
      prevDeadline = r.deadline;
      if (r.deadline < now) {
        expired.push(r);
        if (expired.length >= SWEEP_MAX_PER_TICK) { capped = true; stop = true; break; }
      } else if (monotonic) {
        stop = true; // first live claim, and deadlines ascend: nothing above this id can be expired
        break;
      }
    }
  }

  sweepCursor = cursorCandidate;
  // More expired claims are waiting behind the per-tick cap; come back on the next tick, not in an hour.
  if (capped) sweepNextRun = 0;
  if (!expired.length) return;

  let freed = 0n;
  let swept = 0;
  let held = 0; // candidates whose earlier sweep timed out and is still pending or has just landed (TIMED-OUT SENDS)
  for (const r of expired) {
    // One id per tx by design: sweepExpired takes a single id, and a failure on one claim must not take
    // the rest of the batch down with it.
    const onHeld = () => { held++; };
    if (await fire(`claimManager.sweepExpired(${r.id})`, cm, "sweepExpired", [r.id], { onHeld })) { freed += r.amount; swept++; }
  }
  if (swept) {
    log(`claim sweeper: released ${ethers.formatUnits(freed, 18)} QUOTRON back to free balance `
      + `(${swept} expired claim${swept === 1 ? "" : "s"}); cursor now ${sweepCursor}.`);
  } else if (held === expired.length) {
    // Every candidate is waiting on its own earlier transaction, each already reported: not a refusal.
  } else {
    // A claim can race the winner's own claim(), so one refusal is normal. EVERY candidate refusing means the
    // sweeper is doing nothing, which is the failure this job exists to prevent: say so.
    logError(`claim sweeper: ${expired.length} claim(s) read as expired but NONE could be swept `
      + `(ids ${expired.map((e) => e.id).join(", ")}). Reserve is still locked; check ClaimManager state.`);
  }
}

// ── VOIDED-PERIOD ALARM ─────────────────────────────────────────────────────────────────────────────
//    Every engine can only settle a period during the NEXT one: runDraw(d) requires currentDay()==d+1, and
//    distribute(W) requires currentWeek()==W+1. Miss that window and the period is VOID FOREVER -- the pot
//    rolls forward, but the people who earned that period's board seats or tickets are never paid. Nothing
//    reverts and no event says so, and the next period runs normally, so a keeper with zero errors in its
//    log can be sitting on a dead week.
//
//    So: look back at the windows that have closed. A period that could have paid and whose flag is still false
//    is reported loudly, once per process. One that closed with nothing payable (below minPot, nobody seated)
//    gets a quieter line. It repairs nothing; it makes the loss visible the same day.
//
//    WHEN THE VAULT IS READ. The holder and leaderboard verdicts read the vault NOW. That is
//    evidence about a window only when now is right after it closed, and only before anything else moves the
//    vault. So this job runs FIRST in the tick, before this tick's settlements (a draw of the next period drains
//    the vault) and before convert (which fills it). And a period whose window had ALREADY closed when this keeper
//    first looked at the engine (a restart, or recovery after an outage) is never called PERIOD VOIDED or "not a
//    keeper fault" on a vault read long after it: it is reported as UNVERIFIED instead, in one line per engine.
const seenVoid = new Set(); // keys evaluated to a verdict; never re-read
const voidErrNoted = new Map(); // key or engine -> last logged read error
const voidFirstLook = new Map(); // engine label -> the current period at this keeper's first successful read
let boardReg = null;
const vaultCache = new Map(); // engine address -> vault contract

/// `beforeWatch`: this period's window closed before this keeper first read the engine (closedBeforeWatch). Its
/// "value" verdict is pushed onto `unverified` for the caller's one aggregated line instead of PERIOD VOIDED.
async function checkVoided(label, key, classify, wasSettled, { beforeWatch = false, unverified = null } = {}) {
  if (seenVoid.has(key)) return;
  try {
    if (await wasSettled()) { seenVoid.add(key); voidErrNoted.delete(key); return; }
    const v = await classify();
    seenVoid.add(key);
    voidErrNoted.delete(key);
    if (v.kind === "empty") return;
    if (v.kind === "no-pay") {
      if (beforeWatch) {
        log(`void watch: ${label} closed unpaid before this keeper started watching, and nothing is payable from the `
          + `vault NOW: ${v.detail}. Not verified against its window.`);
      } else {
        log(`void watch: ${label} closed unpaid with nothing payable: ${v.detail}. Not a keeper fault; the pot rolls forward.`);
      }
      return;
    }
    if (beforeWatch && unverified) {
      unverified.push(label);
      return;
    }
    logError(`*** PERIOD VOIDED: ${label} closed its settlement window UNPAID and can never be settled. `
      + "Participants of that period get nothing; the pot rolls forward to whoever wins next. Causes: a keeper "
      + "outage across the window, a pot below minPot for the whole window, or (raffle) beacons that could "
      + "not be posted -- check this log around that period. ***");
  } catch (e) {
    // NOT marked seen, so it is re-read on every tick until it can be evaluated. Logged once per error.
    const msg = isRevertError(e) ? `revert ${revertReason(e)}` : e.shortMessage || e.message;
    if (voidErrNoted.get(key) !== msg) {
      voidErrNoted.set(key, msg);
      logError(`void watch: could not evaluate ${label} (${msg}); retrying every tick until it can be read`);
    }
  }
}

async function engineVault(engine) {
  let v = vaultCache.get(engine.target);
  if (!v) {
    v = new ethers.Contract(await engine.vault(), prizeVaultAbi, provider);
    vaultCache.set(engine.target, v);
  }
  return v;
}

// How many closed periods to examine on EVERY pass. Periods already evaluated are skipped (seenVoid), so the
// steady-state cost is the newest period plus any whose read failed; a keeper that was down comes up with its
// dead periods reported, and a read that failed is retried rather than dropped after the first pass.

function noteVoidEngineError(engine, e) {
  const msg = e.shortMessage || e.message;
  if (voidErrNoted.get(engine) !== msg) {
    voidErrNoted.set(engine, msg);
    logError(`void watch (${engine}): ${msg}; retrying every tick`);
  }
}

/// The engine's current period, remembered the first time it is read (closedBeforeWatch compares against it).
function firstLook(engine, current) {
  if (!voidFirstLook.has(engine)) voidFirstLook.set(engine, BigInt(current));
  return voidFirstLook.get(engine);
}

/// One line per engine for the periods that closed unsettled before this keeper watched, and that the vault could
/// pay NOW. The keeper cannot tell those apart from no-pay periods, so it does not claim either.
function reportUnverified(engine, contractName, unverified) {
  if (!unverified.length) return;
  logError(`*** void watch: ${unverified.join(", ")} closed UNSETTLED before this keeper started watching `
    + `${engine}. The vault could pay them NOW, but it is read now, not in their windows, so this keeper cannot tell `
    + "a VOIDED period (nobody settled it, e.g. a keeper outage) from a NO-PAY one (the vault was below minPot then, "
    + `e.g. before it was seeded). Check ${contractName}'s events for each: a settlement event with 0 winners inside `
    + "the window means the engine refused to pay (no-pay); no event at all means nobody called it (voided). ***");
}

async function runVoidWatch() {
  // Raffle: day d is drawable during d+1, so the last CLOSED window belongs to day (currentDay - 2). Days
  // below RAFFLE_ACCUM_DAYS are the opening's and are never daily-draw periods.
  // The raffle gets the same two treatments as the weekly engines. A day whose
  // pot was below minPot (runDraw's no-pay branch) is a "no-pay" line, not PERIOD VOIDED, and a day whose window
  // closed before this keeper first read the engine goes to the one aggregated UNSETTLED line.
  if (raffle && packReg) {
    const unverified = [];
    try {
      const day = BigInt(await raffle.currentDay());
      const first = firstLook("raffle", day);
      const openingDone = await raffle.openingDone();
      for (const d of closedPeriods(day, VOID_BACKSCAN, RAFFLE_ACCUM_DAYS)) {
        const why = openingDone ? "" : " (the opening draw has still NOT run, so runDraw reverted OpeningPending)";
        await checkVoided(`raffle day ${d}${why}`, `raffle:${d}`,
          async () => {
            const live = await packReg.liveCount(d);
            if (live === 0n) return { kind: "empty" };
            const vault = await engineVault(raffle);
            const [free, capBps, capForDay, minPotForDay, winnersForDay] = await Promise.all([
              vault.freeBalance(), raffle.capBpsAt(d), raffle.potCapAt(d), raffle.minPotAt(d), raffle.winnersPerDayAt(d),
            ]);
            return raffleVoidVerdict({ live, free, capBps, capForDay, minPotForDay, winnersForDay });
          },
          async () => raffle.drawn(d),
          { beforeWatch: closedBeforeWatch(d, first), unverified });
      }
      voidErrNoted.delete("raffle");
    } catch (e) {
      noteVoidEngineError("raffle", e);
    }
    reportUnverified("the raffle", "RaffleEngine (DrawExecuted)", unverified);
  }
  // Leaderboard: same shape on weeks. Here too, a sub-minPot week is a "no-pay" line.
  if (leaderboard) {
    const unverified = [];
    try {
      const wk = await leaderboard.currentWeek();
      const first = firstLook("leaderboard", wk);
      if (!boardReg) boardReg = new ethers.Contract(await leaderboard.registry(), boardAbi, provider);
      for (const w of closedPeriods(wk, VOID_BACKSCAN)) {
        await checkVoided(`leaderboard week ${w}`, `lb:${w}`,
          async () => {
            const [boardCount, totalPoints] = await Promise.all([boardReg.boardCount(w), boardReg.totalPoints(w)]);
            if (boardCount === 0n || totalPoints === 0n) return { kind: "empty" };
            const vault = await engineVault(leaderboard);
            const [free, capForWeek, minPotForWeek] = await Promise.all([
              vault.freeBalance(), leaderboard.potCapAt(w), leaderboard.minPotAt(w),
            ]);
            return leaderboardVoidVerdict({ boardCount, totalPoints, free, capForWeek, minPotForWeek });
          },
          async () => leaderboard.distributed(w),
          { beforeWatch: closedBeforeWatch(w, first), unverified });
      }
      voidErrNoted.delete("leaderboard");
    } catch (e) {
      noteVoidEngineError("leaderboard", e);
    }
    reportUnverified("the leaderboard", "LeaderboardEngine (Distributed)", unverified);
  }
  // Holder: eligibility is derived from the NFT at draw time. A launched collection is not enough:
  // the vault ships unseeded, and runDraw also takes a no-pay branch below minPot or with nobody seated.
  if (holder && nft) {
    const unverified = [];
    try {
      const per = await holder.currentPeriod();
      const first = firstLook("holder", per);
      for (const w of closedPeriods(per, VOID_BACKSCAN)) {
        await checkVoided(`holder week ${w}`, `hd:${w}`,
          async () => {
            const [launched, totalMinted] = await Promise.all([nft.launched(), nft.totalMinted()]);
            if (!launched || totalMinted < HOLDER_WINNERS) return { kind: "empty" };
            const vault = await engineVault(holder);
            const [free, capForWeek, minPotForWeek] = await Promise.all([
              vault.freeBalance(), holder.potCapAt(w), holder.minPotAt(w),
            ]);
            let filled = null;
            try {
              filled = (await holder.previewDraw(w)).filled; // reverts if the week's beacon was never posted
            } catch (e) {
              if (e instanceof TypeError) throw e;
              filled = null; // unknown: the alarm stands
            }
            return holderVoidVerdict({ launched, totalMinted, free, capForWeek, minPotForWeek, filled });
          },
          async () => holder.drawn(w),
          { beforeWatch: closedBeforeWatch(w, first), unverified });
      }
      voidErrNoted.delete("holder");
    } catch (e) {
      noteVoidEngineError("holder", e);
    }
    reportUnverified("the holder draw", "HolderDrawEngine (Drawn / Voided)", unverified);
  }
}

// ── HEALTH WATCH ────────────────────────────────────────────────────────────────────────────────────
//    Both signers are hot and both pay gas. The draw key running dry stops beacons, draws and the sweep; the
//    convert key running dry stops convert(), which funds the prize vaults AND the team + operations stream
//    that tops the keys up. Neither failure is loud on its own until a period voids, so each key has a floor.
//    Also warns when the host clock is BEHIND or AHEAD of the chain's latest block: beacon posting is timed off the
//    host clock. Behind, every reveal and draw is late. Ahead, the keeper asks drand for rounds that have
//    not published: they read as "pending" for DRAND_GRACE_ROUNDS and then page as failed fetches.
let healthNextRun = 0;
function watchedSigners() {
  const out = [];
  const draw = drawAddress();
  const conv = convertAddress();
  // The convert key is watched whenever convert is enabled, including ENABLE_CONVERT=simulate (it sends nothing
  // then, but go-live flips simulate to true, and an unfunded key should be found first).
  const converting = !FAILSAFE && CONVERT_MODE !== "off";
  if (draw) {
    const shared = converting && conv === draw;
    out.push({
      label: shared ? "draw key (KEEPER_PK, also signing convert)" : "draw key (KEEPER_PK)",
      address: draw,
      floor: shared && CONVERT_GAS_FLOOR > KEEPER_GAS_FLOOR ? CONVERT_GAS_FLOOR : KEEPER_GAS_FLOOR,
      floorVar: "KEEPER_GAS_FLOOR_WEI",
      consequence: "When it runs dry, beacons, draws, distribute and the claim sweep stop, and periods void.",
    });
  }
  if (converting && conv && conv !== draw) {
    out.push({
      label: "convert key (CONVERT_PK)",
      address: conv,
      floor: CONVERT_GAS_FLOOR,
      floorVar: "CONVERT_GAS_FLOOR_WEI",
      consequence: "When it runs dry, convert() stops: the prize vaults and the team + operations WETH stream stop funding.",
    });
  }
  return out;
}

async function runHealth() {
  if (!provider) return;
  const nowS = Date.now() / 1000;
  if (nowS < healthNextRun) return;
  healthNextRun = nowS + HEALTH_INTERVAL_S;
  for (const s of watchedSigners()) {
    const key = `balance:${s.address}`;
    let bal;
    try {
      bal = await provider.getBalance(s.address);
    } catch (e) {
      alarm(`${key}:read`, "read", `balance watch: could not read the ${s.label} balance (${e.shortMessage || e.message})`,
        { level: "info", repeatS: 3600 });
      continue;
    }
    clearAlarm(`${key}:read`);
    if (bal < s.floor) {
      alarm(key, "low", `*** LOW BALANCE: the ${s.label} ${s.address} holds ${ethers.formatEther(bal)} ETH, below its `
        + `floor of ${ethers.formatEther(s.floor)} ETH (${s.floorVar}). ${s.consequence} Top it up `
        + "with native ETH from the operations wallet (top-ups are manual). ***", { repeatS: 3600 });
    } else {
      clearAlarm(key, `balance watch: the ${s.label} is back above its floor (${ethers.formatEther(bal)} ETH)`);
    }
  }
  try {
    const b = await provider.getBlock("latest");
    const behind = BigInt(b.timestamp) - BigInt(Math.floor(Date.now() / 1000));
    if (behind > CLOCK_SKEW_WARN_S) {
      alarm("clock-skew", "behind", `host clock: ${behind}s BEHIND the chain's latest block. Beacon posting waits for `
        + "the host clock, so every reveal and draw is late by that much. Fix NTP on this host.", { level: "info", repeatS: 3600 });
    } else if (-behind > CLOCK_SKEW_WARN_S) {
      // A block timestamp can only trail real time, so this is either a fast host clock or a chain that has
      // produced no block for that long; the line names both.
      alarm("clock-skew", "ahead", `host clock: ${-behind}s AHEAD of the chain's latest block (block ${b.number}). If this `
        + "host's clock is fast, the keeper asks drand for rounds before they publish: the relays answer 404 or 425 "
        + `("too early"), the round reads as pending for up to DRAND_GRACE_ROUNDS (${DRAND_GRACE_ROUNDS}) rounds, and `
        + "after that each fetch is logged as a failure. A chain that has produced no block for that long reads the "
        + "same way; if blocks are arriving, fix NTP on this host.", { level: "info", repeatS: 3600 });
    } else {
      clearAlarm("clock-skew", "host clock: back in step with the chain");
    }
  } catch {
    // the skew check is advisory; the balance lines above already report an unreachable RPC
  }
}

// ── FAILSAFE MODE (--failsafe) ──────────────────────────────────────────────────────────────────────
//    Every draw in this protocol is permissionless: runDraw, runOpeningDraw, distribute, submitBeacon and
//    sweepExpired carry no access control. Only `Treasury.convert` is onlyKeeper. That only pays off if a
//    SECOND process exists to exercise it. --failsafe runs every permissionless job and skips convert, so any
//    key with gas can run it, on another machine, alongside the primary. A primary outage then costs gas,
//    not a voided period. It asks the drand relays in the reverse order of the primary.

// ── HEARTBEAT ────────────────────────────────────────────────────────────────────────────────────────
//    A healthy keeper is quiet for long stretches, so "the log went quiet" cannot tell a stuck loop from a calm day.
//    The heartbeat can: one `heartbeat:` line every HEALTH_INTERVAL_S, written only AFTER a tick has run every job.
//    A loop that is stuck anywhere stops writing it. README "Monitoring" alerts on its absence.
let heartbeatNextRun = 0; // epoch seconds; 0 = the first completed tick writes one
const startedAtS = Date.now() / 1000;
function heartbeat(tickMs, jobErrors) {
  const nowS = Date.now() / 1000;
  if (nowS < heartbeatNextRun) return;
  heartbeatNextRun = nowS + HEALTH_INTERVAL_S;
  const holding = [...timedOutSends].filter(([, r]) => r.held).map(([n, r]) => `${n} (${r.hash}, nonce ${r.nonce})`);
  log(`heartbeat: tick ${tickNo} completed in ${(tickMs / 1000).toFixed(1)}s${jobErrors ? ` (${jobErrors} job error(s))` : ""}; `
    + `up ${Math.round(nowS - startedAtS)}s; since the last heartbeat ${sendCounts.sent} tx sent, ${sendCounts.confirmed} `
    + `confirmed, ${sendCounts.failed} failed, ${sendCounts.timedOut} not confirmed within SEND_WAIT_TIMEOUT_MS, `
    + `${sendCounts.replaced} replaced; `
    + (holding.length ? `holding ${holding.length} job(s) behind a timed-out transaction still pending: ${holding.join(", ")}; ` : "")
    + `next heartbeat after ${HEALTH_INTERVAL_S}s`);
  sendCounts.sent = 0; sendCounts.confirmed = 0; sendCounts.failed = 0; sendCounts.timedOut = 0; sendCounts.replaced = 0;
}

async function tick() {
  tickNo++;
  const t0 = Date.now();
  let jobErrors = 0;
  // runVoidWatch runs BEFORE every job that moves a vault (the settlements drain it, convert fills it, the claim
  // sweep frees reserve), so a period whose window just closed is judged on the vault as that window left it.
  // runTimedOutSends (reads only, and a no-op unless a send timed out) runs before every job that sends.
  const jobs = FAILSAFE
    ? [runHealth, runTimedOutSends, runVoidWatch, runRegisterSR, runCohortReveals, runRaffle, runLeaderboard, runHolder, runPodPokes, runPodFeeCollect, runSweepExpired]
    : [runHealth, runTimedOutSends, runVoidWatch, runRegisterSR, runCohortReveals, runRaffle, runLeaderboard, runHolder, runPodPokes, runPodFeeCollect, runConvert, runSweepExpired];
  for (const job of jobs) {
    try {
      await job();
    } catch (e) {
      jobErrors++;
      logError(`tick error in ${job.name}: ${e.shortMessage || e.message}`);
    }
  }
  heartbeat(Date.now() - t0, jobErrors);
}

/// Read-only: does the convert signer actually hold the Treasury keeper role?
async function checkConvertRole() {
  if (!treasuryRole || FAILSAFE) return;
  try {
    const [convertIsKeeper, drawIsKeeper, keeperCount] = await Promise.all([
      treasuryRole.isKeeper(convertAddress()),
      treasuryRole.isKeeper(drawAddress()),
      treasuryRole.keeperCount(),
    ]);
    const problems = convertRoleProblems({
      convertAddress: convertAddress(),
      drawAddress: drawAddress(),
      splitConfigured: !!CONVERT_PK,
      convertIsKeeper,
      drawIsKeeper,
      keeperCount,
    });
    for (const p of problems) {
      if (p.fatal) logError(`*** FATAL CONFIG: ${p.msg} ***`);
      else log(`WARNING: ${p.msg}`);
    }
    if (!problems.some((p) => p.fatal)) log(`convert key ${convertAddress()} holds the Treasury keeper role`);
  } catch (e) {
    logError(`could not read the Treasury keeper role at startup (${e.shortMessage || e.message}); `
      + "runConvert re-checks it before every convert");
  }
}

async function main() {
  const net = await provider.getNetwork();
  CHAIN_ID = net.chainId;
  log(`QPULL keeper online — chainId ${CHAIN_ID}, draw key ${drawAddress()}, config ${ENV_PATH}`);
  for (const [name, why] of Object.entries(RETIRED_ENV)) {
    if (cfg(name) !== undefined) log(`WARNING: ${name} is set in .env but is no longer read: ${why}. Remove it.`);
  }
  // Refuse to run half-blind. A wrong clock gates the draws on reveal rounds no pack uses: the engine reverts
  // RevealPending and pops nothing, but a draw held on a round that publishes after its window voids that
  // day. A wrong oracle gets every beacon posted where no contract reads it, so no draw ever runs.
  if (!(await loadChainClock())) process.exit(1);
  if (!(await resolveOracle())) process.exit(1);
  log(`drand relays, in order: ${relayList({ failsafe: FAILSAFE }).join(", ")}`);
  log(`a sent transaction is waited on for up to SEND_WAIT_TIMEOUT_MS=${SEND_WAIT_TIMEOUT_MS} ms; a "heartbeat:" line `
    + `follows a completed tick every HEALTH_INTERVAL_S=${HEALTH_INTERVAL_S}s (alert on its absence, README "Monitoring")`);
  if (FAILSAFE) {
    log("FAILSAFE MODE — running only the PERMISSIONLESS jobs (beacons, opening + daily raffle, holder, "
      + "leaderboard, QuoPods re-settle sweep, expired-claim sweep, void watch, gas watch). Treasury.convert is SKIPPED: it is the one "
      + "onlyKeeper call, so this process needs no privilege and can be run by anyone, anywhere, alongside the primary.");
    log("This instance does NOT fund the prize vaults. If the PRIMARY keeper is down, draws keep running but "
      + "the pots stop growing, and once the vaults drain the engines will void on minPot. Failsafe buys time; "
      + "it is not a replacement for the primary.");
  } else if (CONVERT_PK) {
    log(`convert key ${convertAddress()} (the only address that needs Treasury.setKeeper)`);
    if (convertAddress() === drawAddress()) {
      log("*** CONVERT_PK resolves to the SAME address as KEEPER_PK: the privilege split is not in effect (both jobs "
        + "share one nonce counter, so they do not collide; set a different CONVERT_PK to separate them) ***");
    }
  } else {
    log(
      "convert key: NOT SET — falling back to the draw key, so the constantly-online key also holds the " +
        "only privilege in the system. Set CONVERT_PK to separate them.",
    );
  }
  if (!FAILSAFE) {
    log(`convert mode: ENABLE_CONVERT=${CONVERT_MODE === "on" ? "true" : CONVERT_MODE === "off" ? "false" : "simulate"}`
      + `${ONCE && CONVERT_MODE === "on" ? " (--once: floors and simulation reported, convert() NEVER sent)" : ""}; `
      + `slippage ${CONVERT_SLIPPAGE} bps; WETH dust floor ${MIN_WETH_CONVERT} wei; spot guard `
      + (PRICE_DEV_BPS === 0n
        ? "DISABLED (CONVERT_PRICE_DEVIATION_BPS=0)"
        : `${PRICE_DEV_BPS} bps vs the median of ${PRICE_WINDOW} ticks (at least ${PRICE_MIN_SAMPLES}, none older than `
          + `${PRICE_MAX_AGE_S}s); price check unavailable (VIEW_QUOTER unset or failing, or a configured QPULL_QUOTER `
          + `that gives no reference quote): ${SPOT_UNAVAILABLE === "hold" ? "HOLDS, fail closed (CONVERT_SPOT_UNAVAILABLE=hold)" : "proceeds UNGUARDED (CONVERT_SPOT_UNAVAILABLE=proceed)"}`));
    if (CONVERT_MODE !== "off" && PRICE_DEV_BPS !== 0n && SPOT_UNAVAILABLE === "hold" && !VIEW_QUOTER) {
      logError("*** convert: VIEW_QUOTER is NOT set, so the Quotron price check is unavailable and every convert HOLDS "
        + "(fail closed, CONVERT_SPOT_UNAVAILABLE=hold). Set VIEW_QUOTER (RH mainnet "
        + "0xb8960fdC8A0Be155d196C2795b75747763562df2). The draws are unaffected. ***");
    }
    await checkConvertRole();
  }
  if (ONCE) {
    // A single pass starts with empty backoff, idempotency, sweep-cursor and void-alarm state and takes
    // no lock. Scheduled every minute it re-sends no-op draws every run (real gas), overlaps itself on one
    // nonce, and repeats every alarm. It is for a human watching one pass, not for cron. It is not a dry run.
    log("--once: ONE manual pass. It sends real beacon and draw transactions (never convert()). Do NOT schedule this (cron, timers): it keeps no "
      + "backoff or idempotency state between runs and takes no lock. Run `node keeper.js` under a supervisor instead.");
    await tick();
    return;
  }
  const ms = INTERVAL_SECONDS * 1000;
  while (true) {
    await tick();
    await sleep(ms);
  }
}

/// Exposed for an offline harness that drives the jobs against a fake JSON-RPC endpoint (no key, no chain).
/// The harness must set process.env.KEEPER_IMPORT_ONLY = "1" before importing; without it, importing this
/// file starts the keeper.
export const __test = Object.freeze({
  loadChainClock, resolveOracle, runRegisterSR, runCohortReveals, runRaffle, runHolder, runVoidWatch,
  resolveClaimManager, runConvert, runHealth, tick, bisectConvertFloors, bisectLeg1, bisectLeg2, ensureBeacon, fire,
  runPodPokes, runPodFeeCollect,
  settleTimedOutSend, runTimedOutSends,
  timedOutSends: () => new Map([...timedOutSends].map(([n, r]) => [n, { ...r, provider: undefined }])),
  resetTimedOutSends: () => { timedOutSends.clear(); convertLandedLate = false; },
  convertLandedLate: () => convertLandedLate,
  sendCounts: () => ({ ...sendCounts }),
  heartbeat: (tickMs = 0, jobErrors = 0) => { heartbeatNextRun = 0; heartbeat(tickMs, jobErrors); },
  signers: () => ({ drawSigner, convertSigner, signsAsDrawKey }),
  sendWaitTimeoutMs: () => SEND_WAIT_TIMEOUT_MS,
  resetHeartbeat: () => { heartbeatNextRun = 0; },
  reanchorSpotAfterConvert, spotHold, noteSpotHold, settleBisectionFailure, watchedSigners, maxFeasible,
  handleRevealPending, fireRaffleDraw, attemptConvert, BisectAbort, referenceQuote, sampleSpot, convertProbe,
  deriveFloors, readClaims,
  convertFlags: () => ({ ONCE, CONVERT_MODE, CONVERT_REPORT_ONLY, SPOT_UNAVAILABLE, PRICE_DEV_BPS, VIEW_QUOTER: VIEW_QUOTER ?? null, QPULL_QUOTER: QPULL_QUOTER ?? null }),
  revealPendingStreak: () => new Map(revealPendingStreak),
  resetRevealPending: () => { revealPendingStreak.clear(); revealPendingAttempts.clear(); revealDone.clear(); },
  setChainId: (id) => { CHAIN_ID = id == null ? null : BigInt(id); },
  useAddresses: (a) => { if (IMPORT_ONLY) testAddresses = a; },
  configErrors: () => [...CONFIG_ERRORS],
  alarms,
  spotHistory,
  resetConvert: () => {
    convertStatic = null; bindingCache.clear(); quoterCheck.clear(); spotHistory.leg1.length = 0;
    spotHistory.leg2.length = 0; lastOutW = 0n; lastOutQ = 0n; convertFailStreak = 0; convertPendingSince = null;
    alarms.clear(); lastRevert.clear(); capReadFailStreak = 0; spotUnavailableStreak = 0; poolLiveSeen = false;
    poolLiveNextCheckS = 0; onceConvertNoted = false;
  },
  resetVoidWatch: () => { seenVoid.clear(); voidErrNoted.clear(); voidFirstLook.clear(); },
  setPendingSince: (s) => { convertPendingSince = s; },
});

if (!IMPORT_ONLY) {
  main().catch((e) => {
    console.error(`${new Date().toISOString()} FATAL:`, e?.stack ?? e);
    process.exit(1);
  });
}
