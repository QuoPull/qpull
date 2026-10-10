/**
 * qpull-drawbot: watches the three prize engines and posts ONE summary per draw to X.
 *
 * READ-ONLY BY CONSTRUCTION. It creates no wallet, signs nothing, and never reads KEEPER_PK or
 * CONVERT_PK. If this process is compromised the worst it can do is post text.
 *
 * WHY SUMMARY, NOT PER-WINNER: per-winner posting is 400+/month (the leaderboard pays every point
 * holder at once), which needs a paid X tier and reads as a spam feed. One post per draw is ~38/month.
 *
 * Flags: --once (single pass, then exit)   --backfill (announce past draws too, respecting state)
 *        --dry (force DRY_RUN on, whatever the env says)
 */
import { ethers } from "ethers";
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, renameSync, unlinkSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import "dotenv/config";

const ONCE = process.argv.includes("--once");
const BACKFILL = process.argv.includes("--backfill");
const env = (k, d) => { const v = process.env[k]; return v === undefined || v.trim() === "" ? d : v.trim(); };
const DRY = process.argv.includes("--dry") || env("DRY_RUN", "true") !== "false";
const RPC = env("RPC_URL");
const POLL_S = Number(env("POLL_SECONDS", "120"));
const STATE_FILE = env("STATE_FILE", "./state.json");
const EXPLORER = "https://robinhoodchain.blockscout.com";
/** This RPC rejects wide eth_getLogs ranges; 100k is the measured ceiling. */
const CHUNK = 100_000;

const log = (m) => console.log(`${new Date().toISOString()} ${m}`);

/* ── the three engines, and the ONE event each that means "a draw paid out" ────────────────────── */
const SOURCES = [
  { key: "raffle", addr: env("RAFFLE_ENGINE"), abi: "event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners)",
    period: "day", label: "Daily draw",
    roll: "a tier with no winner is never redistributed" },
  { key: "holder", addr: env("HOLDER_ENGINE"), abi: "event Drawn(uint256 indexed week, uint256 pot, uint256 winners)",
    period: "week", label: "Holder draw",
    roll: "a slot that could not be paid rolls forward" },
  { key: "leaderboard", addr: env("LEADERBOARD_ENGINE"), abi: "event Distributed(uint256 indexed week, uint256 pot, uint256 winners)",
    period: "week", label: "Leaderboard",
    roll: "points held outside the top 25 stay in the vault and roll forward" },
];

/** The claim digest watches ClaimManager.Claimed. Claims are NOT posted individually: a leaderboard
 *  week pays every point holder, so per-claim posting is ~300/month and reads as a spam feed. Instead
 *  each completed day gets ONE summary. */
const CLAIM_MANAGER = env("CLAIM_MANAGER");
const CLAIM_ABI = "event Claimed(uint256 indexed id, address indexed recipient, uint256 amount)";
/** Day key in Phoenix time, so the digest boundary matches the 9am draw boundary the protocol uses. */
const dayKey = (tsSeconds) => new Intl.DateTimeFormat("en-CA", {
  year: "numeric", month: "2-digit", day: "2-digit", timeZone: "America/Phoenix",
}).format(new Date(tsSeconds * 1000));

/* ── state: which draws we already announced. Keyed by engine+period, so a re-scan of the same
      blocks can never double-post, and a lost lastBlock only costs a re-scan, not a duplicate. ── */
function loadState() {
  if (!existsSync(STATE_FILE)) return { lastBlock: 0, posted: {}, claims: {}, digested: {} };
  try { const st = JSON.parse(readFileSync(STATE_FILE, "utf8")); st.claims ??= {}; st.digested ??= {}; return st; }
  catch (e) { log(`state file unreadable (${e.message}), starting fresh`); return { lastBlock: 0, posted: {}, claims: {}, digested: {} }; }
}
function saveState(s) {
  const tmp = `${STATE_FILE}.tmp`;
  writeFileSync(tmp, JSON.stringify(s, null, 2));
  renameSync(tmp, STATE_FILE); // atomic: a crash mid-write cannot corrupt the state
}

/* ── X API v2, OAuth 1.0a signed by hand (no dependency, ~40 lines) ────────────────────────────── */
const enc = (s) => encodeURIComponent(s).replace(/[!*()']/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
function oauthHeader(method, url, creds) {
  const p = {
    oauth_consumer_key: creds.key, oauth_nonce: randomBytes(16).toString("hex"),
    oauth_signature_method: "HMAC-SHA1", oauth_timestamp: String(Math.floor(Date.now() / 1000)),
    oauth_token: creds.token, oauth_version: "1.0",
  };
  // JSON body params are NOT part of the signature base for application/json requests.
  const base = [method.toUpperCase(), enc(url), enc(Object.keys(p).sort().map((k) => `${enc(k)}=${enc(p[k])}`).join("&"))].join("&");
  const signingKey = `${enc(creds.secret)}&${enc(creds.tokenSecret)}`;
  p.oauth_signature = createHmac("sha1", signingKey).update(base).digest("base64");
  return "OAuth " + Object.keys(p).sort().map((k) => `${enc(k)}="${enc(p[k])}"`).join(", ");
}
async function postTweet(text, creds) {
  const url = "https://api.x.com/2/tweets";
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: oauthHeader("POST", url, creds), "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`X ${res.status}: ${body.slice(0, 300)}`);
  return JSON.parse(body);
}

/** --check-x: prove the four credentials work, WITHOUT posting anything. Calls GET /2/users/me,
 *  which needs the same user-context OAuth a post needs. A 403 here almost always means the access
 *  token pair was minted before the app was set to Read and write: regenerate the pair. */
async function checkX(creds) {
  const missing = Object.entries({ X_API_KEY: creds.key, X_API_SECRET: creds.secret, X_ACCESS_TOKEN: creds.token, X_ACCESS_SECRET: creds.tokenSecret })
    .filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) { console.error(`  not set: ${missing.join(", ")}`); process.exit(1); }
  const url = "https://api.x.com/2/users/me";
  const res = await fetch(url, { headers: { Authorization: oauthHeader("GET", url, creds) } });
  const body = await res.text();
  if (!res.ok) {
    console.error(`  FAILED  HTTP ${res.status}: ${body.slice(0, 300)}`);
    if (res.status === 401) console.error("  401 = the four credentials do not form a valid pair. Re-copy all four.");
    if (res.status === 403) console.error("  403 = set the app to Read and write, then REGENERATE the access token pair.");
    process.exit(1);
  }
  const me = JSON.parse(body);
  console.log(`  OK  authenticated as @${me?.data?.username ?? "?"} (${me?.data?.name ?? ""})`);
  console.log("  credentials are valid for posting. Nothing was posted.");
}

/** The draw events carry the POT (what was available), NOT what was paid, and the two differ on
 *  EVERY engine for a different reason: the raffle never redistributes an unwon tier bucket; the
 *  leaderboard divides by ALL buyers' points so the top 25 receive only their share of them
 *  (LeaderboardEngine.sol:217); the holder draw rolls a slot it could not pay. Week 0 of the
 *  leaderboard announced 0.7049 when 0.2700 was actually distributed, a 2.6x overstatement.
 *
 *  An earlier version summed RaffleEngine.WinnerPaid, which no other engine emits, so the lookup
 *  found nothing for the weeklies and silently fell back to the pot. Every engine registers through
 *  ClaimManager, so summing ClaimRegistered in the draw's OWN transaction is exact for all three and
 *  needs no per-engine special case. It also yields the true winner count. */
const CLAIM_REG_ABI =
  "event ClaimRegistered(uint256 indexed id, address vault, address recipient, uint256 amount, uint64 deadline)";
async function paidTotal(provider, txHash) {
  try {
    const ci = new ethers.Interface([CLAIM_REG_ABI]);
    const topic = ci.getEvent("ClaimRegistered").topicHash;
    const rc = await provider.getTransactionReceipt(txHash);
    if (!rc) return null;
    const cm = CLAIM_MANAGER.toLowerCase();
    let sum = 0n, n = 0;
    for (const l of rc.logs) {
      if (l.address.toLowerCase() !== cm || l.topics[0] !== topic) continue;
      sum += ci.parseLog(l).args.amount;
      n++;
    }
    return n ? { sum, n } : null;   // null falls back to the pot rather than skipping the post
  } catch { return null; }
}

/* ── copy. No em dashes, "Quotron" spelled out, no promise of return. ──────────────────────────── */
const fmt = (wei) => {
  const s = Number(ethers.formatUnits(wei, 18));
  return s >= 1 ? s.toFixed(3) : s.toFixed(4);
};
/** A raw day index means nothing to a reader, so the daily draw is titled by its DATE (taken from
 *  the event's own block, in Phoenix time). The weeklies keep their week number, which is meaningful. */
/** X charges $0.200 per post CONTAINING A URL versus $0.015 without one, a 13x surcharge (checked on
 *  docs.x.com 2026-09-23). At ~38 posts/month that is $7.60 vs $0.57. INCLUDE_LINK=false drops the
 *  explorer link and keeps the post in the cheap bucket. Careful: a bare domain like quopull.fun may
 *  also be detected as a link, so do not "replace" the URL with one and expect the cheap rate. */
const INCLUDE_LINK = env("INCLUDE_LINK", "true") !== "false";
/** A draw older than this is recorded as seen but NOT posted. Without it, a bot that was down for
 *  three days restarts and fires three daily draws back to back: spam, and $0.60 in one burst. The
 *  draws still happened and are still onchain; announcing yesterday's as news helps nobody. */
const MAX_AGE_H = Number(env("MAX_AGE_HOURS", "18"));
function compose(src, periodId, pot, winners, txHash, tsSeconds, unclaimed = 0n) {
  const n = Number(winners);
  const who = n === 1 ? "1 winner" : `${n} winners`;
  // Formatted by hand: en-GB renders September as "Sept", which reads badly next to the other months.
  const when = tsSeconds ? (() => {
    const parts = new Intl.DateTimeFormat("en-US", { day: "numeric", month: "numeric", timeZone: "America/Phoenix" })
      .formatToParts(new Date(tsSeconds * 1000));
    const g = (t) => Number(parts.find((x) => x.type === t).value);
    return `${g("day")} ${["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][g("month") - 1]}`;
  })() : periodId;
  // The one-time opening sweep is emitted as day 0 (RaffleEngine.sol:537), not a real day index.
  const head = src.key === "raffle"
    ? `${periodId === "0" ? "Opening draw" : src.label}, ${when}`
    : `${src.label}, week ${periodId}`;
  const lines = [
    `${head}: ${fmt(pot)} Quotron to ${who}.`,
    ``,
  ];
  // Whatever was not distributed stays in the vault for the next period. Say where it went, with the
  // reason that actually applies to THIS engine, rather than let pot and payout look like a discrepancy.
  if (unclaimed > 0n) lines.push(`${fmt(unclaimed)} stayed in the vault: ${src.roll}.`, ``);
  lines.push(`Paid from the prize vault, funded by trading activity. Winners claim onchain.`);
  if (INCLUDE_LINK) lines.push(`${EXPLORER}/tx/${txHash}`);
  return lines.join("\n");
}

/** One line per CLOSED day. Deliberately plain: this is proof that prizes actually land, so it
 *  states the count and the total and nothing else. */
function composeDigest(dateKey, n, totalWei) {
  const [y, m, d] = dateKey.split("-").map(Number);
  const when = `${d} ${["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][m - 1]}`;
  const lines = [
    `${when}: ${n} ${n === 1 ? "prize" : "prizes"} claimed, ${fmt(totalWei)} Quotron paid out.`,
    ``,
    `Winners claim their own prizes. Nobody can claim for them.`,
  ];
  if (INCLUDE_LINK) lines.push(`${EXPLORER}/address/${CLAIM_MANAGER}`);
  return lines.join("\n");
}

/* ── main ──────────────────────────────────────────────────────────────────────────────────────── */
/** --sample: print what each engine's post will look like, using realistic numbers. Sends nothing.
 *  Use this to approve the copy BEFORE credentials go in, since no draw has run yet to replay. */
function sample() {
  const ex = [
    [SOURCES[0], "1", ethers.parseUnits("0.4874", 18), 5n, "0x" + "ab".repeat(32), 1790269200],
    [SOURCES[1], "1", ethers.parseUnits("1.2036", 18), 12n, "0x" + "cd".repeat(32)],
    [SOURCES[2], "1", ethers.parseUnits("0.8415", 18), 47n, "0x" + "ef".repeat(32)],
  ];
  for (const [src, id, pot, n, tx, ts] of ex) {
    const text = compose(src, id, pot, n, tx, ts);
    console.log(`--- ${src.key} (${[...text].length} chars of 280) ---\n${text}\n`);
  }
}

async function main() {
  if (process.argv.includes("--sample")) return sample();
  if (process.argv.includes("--test-post")) {
    // A one-off REAL post, to prove the whole path end to end. Deliberately NOT a sample draw: posting
    // results for a draw that did not happen puts false numbers on a public timeline, and a screenshot
    // of it outlives the correction. This says only what is true right now.
    const creds2 = { key: env("X_API_KEY"), secret: env("X_API_SECRET"), token: env("X_ACCESS_TOKEN"), tokenSecret: env("X_ACCESS_SECRET") };
    const text = [
      "Setup test.",
      "",
      "This account posts QuoPull draw results and daily claim totals automatically, straight from onchain events. Nothing here is written by hand.",
      "",
      "First live post at the 9am draw.",
    ].join("\n");
    console.log(`  posting (${[...text].length} chars):\n${text.split("\n").map(l => "    " + l).join("\n")}\n`);
    const r = await postTweet(text, creds2);
    const id = r?.data?.id;
    console.log(`  POSTED. id ${id}`);
    console.log(`  https://x.com/QuoPullBot/status/${id}`);
    return;
  }
  if (process.argv.includes("--check-x")) {
    return checkX({ key: env("X_API_KEY"), secret: env("X_API_SECRET"), token: env("X_ACCESS_TOKEN"), tokenSecret: env("X_ACCESS_SECRET") });
  }
  if (!RPC) { console.error("Missing RPC_URL"); process.exit(1); }
  const creds = { key: env("X_API_KEY"), secret: env("X_API_SECRET"), token: env("X_ACCESS_TOKEN"), tokenSecret: env("X_ACCESS_SECRET") };
  if (!DRY && !(creds.key && creds.secret && creds.token && creds.tokenSecret)) {
    console.error("DRY_RUN is false but the four X_* credentials are not all set. Refusing to start.");
    process.exit(1);
  }
  const live = SOURCES.filter((s) => s.addr);
  if (!live.length) { console.error("No engine addresses set (RAFFLE_ENGINE / HOLDER_ENGINE / LEADERBOARD_ENGINE)"); process.exit(1); }

  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  log(`drawbot online, chainId ${net.chainId}, watching ${live.map((s) => s.key).join(", ")}${DRY ? "  [DRY RUN, nothing is posted]" : ""}`);
  for (const s of live) s.iface = new ethers.Interface([s.abi]);
  const claimIface = CLAIM_MANAGER ? new ethers.Interface([CLAIM_ABI]) : null;
  log(claimIface ? "claim digest ON: one summary per closed day" : "claim digest off (CLAIM_MANAGER unset)");

  // PREFLIGHT the state path. On Railway STATE_FILE points into a mounted volume (/data/state.json);
  // if the volume is missing the directory does not exist and the first saveState throws a bare ENOENT
  // that reads like a code bug. Fail here instead, saying exactly what is wrong.
  {
    const dir = dirname(resolve(STATE_FILE));
    if (!existsSync(dir)) {
      console.error(`STATE_FILE is ${STATE_FILE} but its directory ${dir} does not exist.`);
      console.error(`On Railway this means the volume is not mounted there. Mount a volume at ${dir}, or set STATE_FILE to a path that exists.`);
      process.exit(1);
    }
    try { const probe = join(dir, ".writetest"); writeFileSync(probe, "x"); unlinkSync(probe); }
    catch (e) { console.error(`Cannot write to ${dir}: ${e.message}`); process.exit(1); }
    log(`state path OK: ${STATE_FILE}`);
  }

  const state = loadState();
  let head = await provider.getBlockNumber();
  if (!state.lastBlock) {
    state.lastBlock = BACKFILL ? Math.max(0, head - CHUNK * 25) : head;
    log(`no prior state: starting at block ${state.lastBlock}${BACKFILL ? " (backfill)" : ""}`);
    saveState(state); // anchor it now: pass() returns early when head == lastBlock and would not save
  }

  async function pass() {
    head = await provider.getBlockNumber();
    if (head <= state.lastBlock) return;
    for (const s of live) {
      const topic = s.iface.getEvent(s.iface.fragments[0].name).topicHash;
      for (let from = state.lastBlock + 1; from <= head; from += CHUNK) {
        const to = Math.min(from + CHUNK - 1, head);
        let logs = [];
        try { logs = await provider.getLogs({ address: s.addr, topics: [topic], fromBlock: from, toBlock: to }); }
        catch (e) { log(`getLogs ${s.key} ${from}-${to} failed: ${e.shortMessage || e.message}`); continue; }
        for (const l of logs) {
          const p = s.iface.parseLog(l);
          const periodId = p.args[0].toString();
          const stateKey = `${s.key}:${periodId}`;
          if (state.posted[stateKey]) continue;           // already announced, whatever the block range
          let ts = null;
          try { ts = (await provider.getBlock(l.blockNumber))?.timestamp ?? null; } catch { /* date is cosmetic */ }
          // A zero-winner DrawExecuted is a NON-EVENT, not a draw: the engine emits it for a forgone
          // opening, an empty ticket window, and a sub-minPot skip (RaffleEngine.sol:557, "retry when
          // funded"). That skip does NOT consume the day, so it can fire repeatedly and the real payout
          // for the same day comes later. Crucially we must NOT record it in `posted`, or the real draw
          // is suppressed as a duplicate and never announced at all.
          if (Number(p.args[2]) === 0) {
            log(`ignoring ${stateKey}: 0 winners (skip/forgone/empty window, not a payout). Not recorded.`);
            continue;
          }
          const ageH = ts ? (Date.now() / 1000 - ts) / 3600 : 0;
          if (MAX_AGE_H > 0 && ageH > MAX_AGE_H) {
            log(`skipping ${stateKey}: ${ageH.toFixed(1)}h old, past MAX_AGE_HOURS=${MAX_AGE_H} (recorded, not posted)`);
            state.posted[stateKey] = { block: l.blockNumber, tx: l.transactionHash, skipped: "too old", at: new Date().toISOString() };
            saveState(state);
            continue;
          }
          // Measured from the draw's own transaction, for EVERY engine. Never announce the pot.
          const measured = await paidTotal(provider, l.transactionHash);
          const amount = measured ? measured.sum : p.args[1];
          const winners = measured ? BigInt(measured.n) : p.args[2];
          const rolled = measured && p.args[1] > measured.sum ? p.args[1] - measured.sum : 0n;
          if (measured) log(`${stateKey}: pot ${p.args[1]}, actually registered ${measured.sum} to ${measured.n}`);
          const text = compose(s, periodId, amount, winners, l.transactionHash, ts, rolled);
          if (DRY) {
            log(`WOULD POST (${stateKey}):\n${text}\n`);
          } else {
            try {
              const r = await postTweet(text, creds);
              log(`posted ${stateKey} as ${r?.data?.id ?? "?"}`);
            } catch (e) { log(`POST FAILED ${stateKey}: ${e.message}`); continue; } // retried next pass
          }
          state.posted[stateKey] = { block: l.blockNumber, tx: l.transactionHash, at: new Date().toISOString() };
          saveState(state);
        }
      }
    }
    // ── claim digest ────────────────────────────────────────────────────────────────────────────
    if (claimIface) {
      const topic = claimIface.getEvent("Claimed").topicHash;
      for (let from = state.lastBlock + 1; from <= head; from += CHUNK) {
        const to = Math.min(from + CHUNK - 1, head);
        let logs = [];
        try { logs = await provider.getLogs({ address: CLAIM_MANAGER, topics: [topic], fromBlock: from, toBlock: to }); }
        catch (e) { log(`getLogs claims ${from}-${to} failed: ${e.shortMessage || e.message}`); continue; }
        for (const l of logs) {
          let ts = null;
          try { ts = (await provider.getBlock(l.blockNumber))?.timestamp ?? null; } catch { /* skip if unknown */ }
          if (!ts) continue;
          const k = dayKey(ts);
          const amt = claimIface.parseLog(l).args[2];
          const b = (state.claims[k] ??= { n: 0, wei: "0" });
          b.n += 1;
          b.wei = (BigInt(b.wei) + BigInt(amt)).toString();  // wei as a string: JSON cannot hold BigInt
        }
      }
      // Post a digest only for a day that has CLOSED, so the count is final.
      const today = dayKey(Math.floor(Date.now() / 1000));
      for (const k of Object.keys(state.claims).sort()) {
        if (k >= today || state.digested[k]) continue;
        const { n, wei } = state.claims[k];
        if (!n) { state.digested[k] = { skipped: "no claims" }; continue; }
        const text = composeDigest(k, n, BigInt(wei));
        if (DRY) {
          log(`WOULD POST (digest:${k}):\n${text}\n`);
        } else {
          try { const r = await postTweet(text, creds); log(`posted digest:${k} as ${r?.data?.id ?? "?"}`); }
          catch (e) { log(`POST FAILED digest:${k}: ${e.message}`); continue; }  // retried next pass
        }
        state.digested[k] = { n, wei, at: new Date().toISOString() };
        saveState(state);
      }
    }

    state.lastBlock = head;
    saveState(state);
  }

  await pass();
  if (ONCE) { log("--once: done"); return; }
  setInterval(() => { pass().catch((e) => log(`pass error: ${e.message}`)); }, POLL_S * 1000);
  log(`polling every ${POLL_S}s`);
}
/* Anything that escapes the caught paths (pass() is wrapped, getLogs and getBlock are wrapped) still
 * kills the process, and Node's default stderr dump carries no timestamp. On Railway that lands as a
 * bare "Deploy Crashed" with nothing in the bot's own log format to tie it to a poll, so the next
 * person debugging it is guessing. Log it the way every other line is logged, THEN exit so the restart
 * policy still applies: a bot that dies loudly is recoverable, one that dies silently is not. */
function fatal(kind, e) {
  log(`FATAL ${kind}: ${e && e.stack ? e.stack : e}`);
  process.exit(1);
}
process.on("unhandledRejection", (e) => fatal("unhandledRejection", e));
process.on("uncaughtException", (e) => fatal("uncaughtException", e));

main().catch((e) => fatal("main", e));
