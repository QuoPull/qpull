#!/usr/bin/env node
/*
 * check-web-wiring.mjs  (pre-deploy gate for the static site in web/)
 *
 * Fails loudly when a page about to be published for MAINNET (chain 4663) still carries testnet wiring.
 * Run it before EVERY Vercel deploy of web/, and treat a non-zero exit as "do not deploy":
 *
 *     node tools/check-web-wiring.mjs                         # the pages Vercel will publish (web/.vercelignore applied,
 *                                                             # every *.html under web/, subdirectories included)
 *     node tools/check-web-wiring.mjs --all                   # every web/**.html, ignoring .vercelignore
 *     node tools/check-web-wiring.mjs web/index.html          # just these files
 *     node tools/check-web-wiring.mjs --deploy-log nft.log --deploy-log deploy.log --deploy-log golive.log
 *                                                             # ALSO require every wired address to equal what the
 *                                                             # deploy logs printed (the positive proof, see below)
 *     node tools/check-web-wiring.mjs --deploy-log ... --address ROUTER=0x...
 *                                                             # supply an address by hand (prefer the log line). It is
 *                                                             # printed as "claimed by hand, not proven by a deploy log"
 *                                                             # (a WARN), never as proven
 *     node tools/check-web-wiring.mjs --allow-unlocked        # delegate.html is MEANT to open delegation (LOCKED = false)
 *     node tools/check-web-wiring.mjs --allow-unwired         # PRE-LAUNCH mainnet delegate.html: NFT = 0x0 with
 *                                                             # LOCKED = true is published on purpose (see below)
 *     node tools/check-web-wiring.mjs --address NFT=$X --allow-unlocked
 *                                                             # DELEGATION-ONLY delegate.html before DeployNFT (see below)
 *     node script/wire-web.mjs --check [same flags]           # identical, from the rewire helper
 *
 * DELEGATION-ONLY delegate.html (the launch step, chosen by the owner, that publishes delegation before DeployNFT).
 * Delegation opens BEFORE the NFT exists: delegate.html is wired for chain 4663 to the PRECOMPUTED NFT address
 * X = CREATE(NFT deployer, nonce 0) and published with LOCKED = false, while web/.vercelignore publishes only
 * delegate.html and docs.html. No deploy log can prove X yet, so the exact invocation, from the repo root, is:
 *
 *     X=0x...          # `cast compute-address <nft deployer> --nonce 0`, recomputed independently by a second person
 *     node tools/check-web-wiring.mjs --address NFT=$X --allow-unlocked
 *
 * It must exit 0. The NFT line then reads "claimed by hand, not proven by a deploy log" (in the log summary, as a WARN on
 * the page and in the closing note): the tool only checks that the page carries the address you typed; the second
 * person's recomputation of X is the only proof there is. Never add --allow-unwired (it is refused with
 * --allow-unlocked anyway). Do NOT pass the one-line `export NFT_ADDRESS=` file that this launch step feeds to
 * script/wire-web.mjs (nft-precomputed.log) as --deploy-log: a file whose every line is a bare `export NAME=0x...`
 * carries no deploy output, so the check FAILs it as "not a deploy log" instead of treating it as proof. Once DeployNFT
 * has landed at X, re-run with its tee'd output and no --address:
 *
 *     node tools/check-web-wiring.mjs --deploy-log nft.log --allow-unlocked
 *
 * PRE-LAUNCH delegate.html (--allow-unwired). Before DeployNFT has run there is no NFT address to prove, but the
 * delegation page is still published for chain 4663 with NFT = 0x0 and LOCKED = true: it then only explains the
 * mint and cannot send anything (LIVE = false). Without this flag that page always FAILs ("zero address" and "not
 * proven"). With it, and ONLY on delegate.html with LOCKED = true on the target chain, a zero-address var is a WARN
 * and needs no proof. Everything else stays strict: a NON-zero address still has to be proven, a deploy log that
 * does name an NFT still FAILs a zero page ("wire it"), any other page with a zero address still FAILs, and the
 * flag is refused together with --allow-unlocked and on a delegate.html whose LOCKED is false. Drop the flag as
 * soon as DeployNFT has run: from then on pass its log (export NFT_ADDRESS=) instead.
 *
 * What it looks for, per page (every finding prints file:line and the exact text it matched):
 *   FAIL  CHAIN object: chainId / chainIdHex other than the target, or a chainName that says testnet
 *   FAIL  a testnet / devnet / local host in the CSP connect-src, or in any URL in the markup or a script string
 *   FAIL  CHAIN.rpcUrls host missing from connect-src (every chain read would be blocked by the CSP)
 *   FAIL  a contract address our own scripts deployed on another chain (read from broadcast/<Script>/<chainId>/),
 *         plus any address in --testnet-addresses; a zero address in a wired var (unwired page; WARN only for the
 *         pre-launch delegate.html under --allow-unwired, see above)
 *   FAIL  with --deploy-log / --address: a wired var whose address differs from the logs, a wired var NO log proves
 *         (so a partial comparison can never pass quietly), or two logs that disagree about one var
 *   FAIL  a --deploy-log whose every non-blank line is a bare `export NAME=0x...` (a hand-written address file, not a
 *         script's output; its addresses are listed as claimed by hand)
 *   WARN  a wired var whose only source is --address (or such a bare file): "claimed by hand, not proven by a deploy log"
 *   FAIL  delegate.html LOCKED = false (unless --allow-unlocked), and ALWAYS when that page is not on the target chain
 *   FAIL  visible page text OR a user-visible attribute (title, alt, aria-label, placeholder, meta description and
 *         og:/twitter: content) naming a testnet ("testnet", 46630, 0xB626, 31337), or the pre-mainnet demo disclaimer
 *   FAIL  a published page loading a file (img/script/link src, fetch('...')) that web/.vercelignore excludes
 *   FAIL  web/allowlist.json missing, excluded from the deploy, or carrying the same root as allowlist.testnet.json
 *   FAIL  a file under web/art/reveal or web/art/ipfs that web/.vercelignore would publish (legacy per-pass
 *         metadata that labels real pass ids with tiers the chain does not have); WARN for any other published file
 *         under web/art/ that no published page loads by its exact path
 *   WARN  a script string that mentions "testnet" without being a URL (check it is only reachable on a testnet build)
 *   FAIL  on chain 4663 with NO --deploy-log / --address: every wired contract address (nothing proves it is mainnet's)
 *   WARN  a link to an excluded page; "before mainnet" copy; 'unsafe-inline' in script-src (required by the inline app script)
 *
 * Exit 0 = clean, 1 = findings, 2 = usage or I/O error. Read-only: it never writes a file and makes no network call.
 *
 * Address notes. Only CREATE/CREATE2 records count as "deployed on another chain" (forge also stores the callee of a
 * CALL in contractAddress, which would flag shared contracts such as the canonical PoolManager). Local anvil runs
 * (broadcast/.../31337) are ignored, because a fork rehearsal with the mainnet deployer creates contracts at the real
 * mainnet addresses. The repo keeps only broadcast run-latest.json files, so on a fresh clone the broadcast scan
 * cannot see addresses from EARLIER testnet deploys: --deploy-log is the positive proof, and on chain 4663 a page
 * that wires contract addresses fails without it.
 *
 * Deploy logs. The mainnet flow prints addresses across three scripts, under different names than the testnet flow:
 *   DeployNFT.s.sol     export NFT_ADDRESS=            (DeployMint.s.sol: export NFT_ADDR=)
 *   Deploy.s.sol        export QPULL= / PRIZE_VAULT= / LEADERBOARD_VAULT= / HOLDER_VAULT= / HOOK= / ... and the
 *                       console lines "LeaderboardReg  0x..." (its export block has no LEADERBOARD_REG line) and
 *                       "SWAP ROUTER (site buy/sell): 0x..." (QpullSwapRouter: the site's own
 *                       buy/sell router, deployed on BOTH chains)
 *   GoLiveTestnet       the same "SWAP ROUTER (site buy/sell): 0x..." line on testnet (DeployTestnet does not deploy it)
 * WEB_VAR_EXPORTS below lists every accepted name per web var. script/wire-web.mjs imports it, so the rewire and the
 * check cannot drift apart. Router lines are matched by that exact phrase or `export ROUTER=`, never by a bare
 * "ROUTER" substring: `export QUOTRON_ROUTER=` is Quotron's canonical ETH router, not the site's swap router.
 * On chain 4663 index.html's ROUTER is proven like every other address, from the Deploy.s.sol log that carries that
 * line (strict). --address ROUTER=0x... still works but is a hand-typed claim, not a deploy's proof.
 */
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve, relative, basename, sep, posix } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");

// web var name -> every `export NAME=` that carries that address, testnet (DeployTestnet) and mainnet
// (DeployNFT / DeployMint / Deploy.s.sol) spellings both. Shared with script/wire-web.mjs (imported, not copied).
export const WEB_VAR_EXPORTS = {
  NFT: ["NFT", "NFT_ADDRESS", "NFT_ADDR"],
  QPULL: ["QPULL_TOKEN", "QPULL"],
  WETH: ["WETH"],
  HOOK: ["HOOK", "QPULL_POOL_HOOK"],
  POOL_MANAGER: ["POOL_MANAGER"],
  PACK_REGISTRY: ["PACK_REGISTRY"],
  RAFFLE_ENGINE: ["RAFFLE_ENGINE"],
  HOLDER_ENGINE: ["HOLDER_ENGINE"],
  LEADER_ENGINE: ["LEADERBOARD_ENGINE"],
  CLAIM_MANAGER: ["CLAIM_MANAGER"],
  LEADERBOARD: ["LEADERBOARD_REG"],
  RAFFLE_VAULT: ["RAFFLE_VAULT", "PRIZE_VAULT"],
  LEADER_VAULT: ["LEADER_VAULT", "LEADERBOARD_VAULT"],
  HOLDER_VAULT: ["HOLDER_VAULT"],
  ROUTER: ["ROUTER"],
};
// export name -> web var (derived; kept for callers that want the flat view)
export const WEB_VAR_MAP = Object.fromEntries(
  Object.entries(WEB_VAR_EXPORTS).flatMap(([v, names]) => names.map((n) => [n, v])));

// Addresses some script prints as a plain console line instead of an export. Exact phrases only.
const CONSOLE_LINES = [
  { webVar: "ROUTER", re: /\bSWAP ROUTER \(site buy\/sell\):[ \t]*(0x[0-9a-fA-F]{40})(?![0-9a-fA-F])/g,
    what: 'QpullSwapRouter "SWAP ROUTER (site buy/sell):" line' },
  { webVar: "LEADERBOARD", re: /^[ \t]*LeaderboardReg[ \t]+(0x[0-9a-fA-F]{40})[ \t]*\r?$/gm,
    what: 'Deploy.s.sol "LeaderboardReg" line' },
];

const NON_MAINNET_HOST = /(^|[.-])(testnet|sepolia|goerli|holesky|devnet|staging)([.-]|$)|^localhost$|^127\.0\.0\.1$|^0\.0\.0\.0$|^\[?::1\]?$/i;
// The non-mainnet host, visible-text and chainName checks are the MAINNET gate: they exist to stop a testnet
// build shipping for 4663. `--chain <other>` used to run them anyway, so a correctly testnet-wired page could never
// pass. For any other target they are replaced by the reverse check: the page must not carry MAINNET wiring, and
// where the target is a known chain its CHAIN.chainName must name it.
const RH_MAINNET_CHAIN = 4663;
const MAINNET_HOST = /(^|\.)mainnet\.chain\.robinhood\.com$/i;
const CHAIN_PROFILES = {
  46630: { name: /\btestnet\b/i, nameWhat: 'a Robinhood Chain Testnet name (it must contain "Testnet")' },
};
const NON_MAINNET_TEXT = [
  { re: /testnet/i, what: 'the word "testnet"', level: "FAIL" },
  { re: /\b46630\b/, what: "testnet chain id 46630", level: "FAIL" },
  { re: /\b0xb626\b/i, what: "testnet chain id hex 0xB626", level: "FAIL" },
  { re: /\b31337\b/, what: "local anvil chain id 31337", level: "FAIL" },
  { re: /\bdemo interface\b|\bpending mainnet\b/i, what: 'the pre-mainnet demo disclaimer ("Demo interface" / "pending mainnet")', level: "FAIL" },
  { re: /\bbefore mainnet\b/i, what: 'a "before mainnet" note (fine before launch, stale once mainnet is live)', level: "WARN" },
];
// attributes a user reads (tooltip, alt text, screen reader label, placeholder); meta content is added per tag
const VISIBLE_ATTRS = new Set(["title", "alt", "aria-label", "aria-description", "aria-roledescription", "aria-placeholder", "placeholder", "label"]);

function usage(msg) {
  if (msg) console.error("check-web-wiring: " + msg);
  console.error("usage: node tools/check-web-wiring.mjs [--all] [--chain 4663] [--web web] [--broadcast broadcast]\n" +
    "         [--deploy-log FILE]... [--address NAME=0x...]... [--testnet-addresses FILE] [--allow-unlocked | --allow-unwired]\n" +
    "         [page.html ...]");
  return 2;
}

function parseArgs(argv) {
  const o = { all: false, chain: 4663, web: join(ROOT, "web"), broadcast: join(ROOT, "broadcast"), deployLogs: [],
    addresses: [], testnetAddrFiles: [], allowUnlocked: false, allowUnwired: false, files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = () => { if (i + 1 >= argv.length) throw new Error(a + " needs a value"); return argv[++i]; };
    if (a === "--all") o.all = true;
    else if (a === "--chain") o.chain = Number(v());
    else if (a === "--web") o.web = resolve(v());
    else if (a === "--broadcast") o.broadcast = resolve(v());
    else if (a === "--deploy-log") o.deployLogs.push(resolve(v()));
    else if (a === "--address") o.addresses.push(parseAddressFlag(v()));
    else if (a === "--testnet-addresses") o.testnetAddrFiles.push(resolve(v()));
    else if (a === "--allow-unlocked") o.allowUnlocked = true;
    else if (a === "--allow-unwired") o.allowUnwired = true;
    else if (a === "-h" || a === "--help") throw new Error("");
    else if (a.startsWith("--")) throw new Error("unknown flag " + a);
    else o.files.push(resolve(a));
  }
  if (!Number.isInteger(o.chain) || o.chain <= 0) throw new Error("--chain must be a positive integer");
  // An unwired page must stay informational, and LOCKED = false is exactly the switch that stops it being one.
  if (o.allowUnwired && o.allowUnlocked)
    throw new Error("--allow-unwired cannot be combined with --allow-unlocked: an unwired pre-launch delegate.html must keep LOCKED = true");
  return o;
}

// --address NAME=0x...  (NAME = a web var such as ROUTER, or any export name WEB_VAR_EXPORTS lists)
export function parseAddressFlag(s) {
  const m = /^([A-Z][A-Z0-9_]*)=(0x[0-9a-fA-F]{40})$/.exec(String(s).trim());
  if (!m) throw new Error(`--address expects NAME=0x<40 hex>, got "${s}"`);
  const webVar = m[1] in WEB_VAR_EXPORTS ? m[1] : WEB_VAR_MAP[m[1]];
  if (!webVar) throw new Error(`--address ${m[1]}: not a web var or known export name (${Object.keys(WEB_VAR_EXPORTS).join(", ")})`);
  return { name: m[1], webVar, addr: m[2] };
}

// ── line bookkeeping ─────────────────────────────────────────────────────────────────────────────
function lineIndex(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1);
  return (off) => { let lo = 0, hi = starts.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= off) lo = mid; else hi = mid - 1; } return lo + 1; };
}
const blank = (s) => s.replace(/[^\n]/g, " "); // keep newlines so offsets and line numbers survive

// ── a small JS lexer: strips comments (keeping offsets) and collects string literals ─────────────
// Regex literals are told apart from division by the previous significant token, which is enough for the
// ES5-style inline scripts in web/ (a regex such as /'/g must not open a string).
const REGEX_AFTER_WORD = new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]);
export function lexJs(src) {
  let out = "", i = 0, last = "", lastWord = "";
  const n = src.length, strings = [];
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === "/" && d === "/") { while (i < n && src[i] !== "\n") { out += " "; i++; } continue; }
    if (c === "/" && d === "*") {
      out += "  "; i += 2;
      while (i < n && !(src[i] === "*" && src[i + 1] === "/")) { out += src[i] === "\n" ? "\n" : " "; i++; }
      if (i < n) { out += "  "; i += 2; }
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const start = i; let val = ""; out += c; i++;
      while (i < n && src[i] !== c) {
        if (src[i] === "\\") { const two = src[i] + (src[i + 1] || ""); val += two; out += two; i += 2; continue; }
        if (src[i] === "\n" && c !== "`") break;
        val += src[i]; out += src[i]; i++;
      }
      if (i < n && src[i] === c) { out += c; i++; }
      strings.push({ value: val, start, end: i, tpl: c === "`" });
      last = "operand"; lastWord = "";
      continue;
    }
    if (c === "/") {
      const afterOperand = last === "operand" || last === ")" || last === "]" || last === "}";
      const wordAllowsRegex = last === "operand" && REGEX_AFTER_WORD.has(lastWord);
      if (!afterOperand || wordAllowsRegex) {
        out += c; i++; let inClass = false;
        while (i < n && src[i] !== "\n") {
          const ch = src[i];
          if (ch === "\\") { out += ch + (src[i + 1] || ""); i += 2; continue; }
          if (inClass) { if (ch === "]") inClass = false; }
          else if (ch === "[") inClass = true;
          else if (ch === "/") { out += ch; i++; break; }
          out += ch; i++;
        }
        while (i < n && /[a-z]/i.test(src[i])) { out += src[i]; i++; }
        last = "operand"; lastWord = "";
        continue;
      }
      out += c; i++; last = "/"; lastWord = ""; continue;
    }
    if (/[A-Za-z_$]/.test(c)) { let w = ""; while (i < n && /[\w$]/.test(src[i])) { w += src[i]; out += src[i]; i++; } last = "operand"; lastWord = w; continue; }
    if (/[0-9]/.test(c)) { while (i < n && /[\w.]/.test(src[i])) { out += src[i]; i++; } last = "operand"; lastWord = ""; continue; }
    if (/\s/.test(c)) { out += c; i++; continue; }
    out += c; last = c; lastWord = ""; i++;
  }
  return { code: out, strings };
}

// ── HTML split: inline scripts, CSP, markup with scripts/styles/comments blanked ─────────────────
function splitHtml(html) {
  const scripts = [], scriptSrcs = [];
  let markup = html.replace(/<!--[\s\S]*?-->/g, blank);
  markup = markup.replace(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi, (m, attrs, body, off) => {
    const sm = /\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(attrs);
    if (sm) scriptSrcs.push({ ref: sm[1] ?? sm[2] ?? sm[3], off });
    else scripts.push({ body, offset: off + m.indexOf(">") + 1 });
    return blank(m);
  });
  markup = markup.replace(/<style\b[^>]*>[\s\S]*?<\/style\s*>/gi, blank);
  let csp = null;
  const metaRe = /<meta\b[^>]*http-equiv\s*=\s*["']Content-Security-Policy["'][^>]*>/gi;
  for (const m of markup.matchAll(metaRe)) {
    const cm = /content\s*=\s*"([^"]*)"/i.exec(m[0]) || /content\s*=\s*'([^']*)'/i.exec(m[0]);
    if (cm) csp = { content: cm[1], offset: m.index };
  }
  // The CSP is judged directive by directive above; blank it so the generic URL scan does not report it twice.
  markup = markup.replace(metaRe, blank);
  const text = markup.replace(/<[^>]*>/g, blank); // visible text only
  return { scripts, scriptSrcs, csp, markup, text };
}

// Every attribute of every tag in the (script/style/comment-blanked) markup, with its value offset.
function tagAttrs(markup) {
  const out = [];
  for (const t of markup.matchAll(/<([a-zA-Z][\w-]*)\b([^>]*)>/g)) {
    const tag = t[1].toLowerCase(), attrs = t[2], base = t.index + 1 + t[1].length;
    const list = [];
    for (const a of attrs.matchAll(/([^\s"'<>\/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g))
      list.push({ name: a[1].toLowerCase(), value: a[2] ?? a[3] ?? a[4] ?? "", off: base + a.index });
    out.push({ tag, attrs: list, off: t.index });
  }
  return out;
}

function cspSources(content, directive) {
  for (const part of content.split(";")) {
    const toks = part.trim().split(/\s+/);
    if (toks[0] && toks[0].toLowerCase() === directive) return toks.slice(1);
  }
  return null;
}
function hostOf(url) { try { return new URL(url).hostname.toLowerCase(); } catch { return null; } }

// ── known non-target deployments, from forge broadcast records ───────────────────────────────────
function collectBroadcastAddresses(dir, targetChain) {
  const other = new Map(), target = new Set();
  if (!existsSync(dir)) return { other, missing: true };
  const add = (addr, src, isTarget) => {
    if (typeof addr !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(addr)) return;
    const k = addr.toLowerCase();
    if (isTarget) { target.add(k); return; }
    if (!other.has(k)) other.set(k, []);
    other.get(k).push(src);
  };
  for (const script of readdirSync(dir)) {
    const sdir = join(dir, script); if (!statSync(sdir).isDirectory()) continue;
    for (const chain of readdirSync(sdir)) {
      const cdir = join(sdir, chain); if (!statSync(cdir).isDirectory() || !/^\d+$/.test(chain)) continue;
      // Local anvil (31337) runs are skipped: a fork rehearsal of the mainnet go-live with the mainnet deployer
      // creates contracts at the SAME addresses the real deploy will, so counting them would flag correct wiring.
      if (chain === "31337") continue;
      const isTarget = Number(chain) === targetChain;
      for (const f of readdirSync(cdir)) {
        if (!f.endsWith(".json")) continue;
        let j; try { j = JSON.parse(readFileSync(join(cdir, f), "utf8")); } catch { continue; }
        const src = `${relative(ROOT, cdir)}/${f}`;
        // ONLY creations. Forge also fills transactions[].contractAddress for a CALL (with the callee), so taking
        // every contractAddress would list the canonical PoolManager, Permit2 and every other shared contract a
        // script merely called, and flag correct mainnet wiring. Receipts carry contractAddress only on creation.
        for (const t of j.transactions || []) {
          if (/^CREATE2?$/.test(String(t.transactionType || ""))) add(t.contractAddress, src, isTarget);
          for (const ac of t.additionalContracts || []) add(ac.address, src, isTarget);
        }
        for (const r of j.receipts || []) add(r.contractAddress, src, isTarget);
      }
    }
  }
  for (const k of target) other.delete(k); // a genuine target-chain deployment that happens to share an address
  return { other, missing: false };
}

function readAddressList(file) {
  const s = readFileSync(file, "utf8"), set = new Set();
  for (const m of s.matchAll(/0x[0-9a-fA-F]{40}/g)) set.add(m[0].toLowerCase());
  return set;
}

// A file whose every non-blank line is a bare `export NAME=0x...` (or a # comment) is something a person wrote, for
// example the delegation-only launch step's `printf 'export NFT_ADDRESS=%s\n' "$X" > nft-precomputed.log`, which feeds the
// precomputed NFT address to script/wire-web.mjs. A forge script's tee'd output always carries more than that
// ("Script ran successfully.", "== Logs ==", the script's own console lines), so such a file is no deploy's proof.
const BARE_EXPORT_LINE = /^[ \t]*(?:export[ \t]+[A-Z][A-Z0-9_]*[ \t]*=[ \t]*["']?0x[0-9a-fA-F]{40}["']?[ \t]*;?|#.*)?[ \t]*\r?$/;
export function isBareExportFile(text) {
  const lines = String(text).split("\n");
  return lines.some((l) => /\bexport\b/.test(l)) && lines.every((l) => BARE_EXPORT_LINE.test(l));
}

/**
 * Read deploy logs (plus --address values) into web var -> address.
 * Returns { byVar: {webVar: {addr, src: [..], proven}}, conflicts: [{webVar, values: [{addr, src, hand}]}], otherExports }.
 * Every source for one web var must agree (an export, its alias, a console line, --address); if they do not, the
 * var is a conflict and has no value, so neither the check nor the rewire picks one silently.
 * `proven` is true when at least one agreeing source is a deploy log; a var known only from --address, or from a file in
 * opts.handFiles (bare export files, see isBareExportFile), is claimed by hand and `proven` is false.
 */
export function parseDeployLogs(files, extra = [], opts = {}) {
  const cand = {}, otherExports = new Set(), handFiles = opts.handFiles || new Set();
  const slot = (v) => (cand[v] ??= []);
  for (const f of files) {
    const text = readFileSync(f, "utf8"), lineOf = lineIndex(text), name = relative(process.cwd(), f) || f;
    const hand = handFiles.has(f), tag = hand ? ", a file of bare export lines: claimed by hand, not proven by a deploy log" : "";
    for (const m of text.matchAll(/(?<![\w$])export[ \t]+([A-Z][A-Z0-9_]*)[ \t]*=[ \t]*["']?(0x[0-9a-fA-F]{40})(?![0-9a-fA-F])/g)) {
      const v = WEB_VAR_MAP[m[1]];
      if (!v) { otherExports.add(m[1]); continue; }
      slot(v).push({ addr: m[2], src: `export ${m[1]}= (${name}:${lineOf(m.index)}${tag})`, hand, what: `export ${m[1]}= in ${name}:${lineOf(m.index)}` });
    }
    for (const c of CONSOLE_LINES)
      for (const m of text.matchAll(c.re)) slot(c.webVar).push({ addr: m[1], src: `${c.what} (${name}:${lineOf(m.index)}${tag})`, hand, what: `${c.what} in ${name}:${lineOf(m.index)}` });
  }
  for (const e of extra) slot(e.webVar).push({ addr: e.addr, src: `--address ${e.name}= (claimed by hand, not proven by a deploy log)`, hand: true, what: `--address ${e.name}=` });
  const byVar = {}, conflicts = [];
  for (const [v, list] of Object.entries(cand)) {
    const distinct = new Set(list.map((x) => x.addr.toLowerCase()));
    if (distinct.size === 1) byVar[v] = { addr: list[0].addr, src: list.map((x) => x.src), proven: list.some((x) => !x.hand), handFrom: list.filter((x) => x.hand).map((x) => x.what) };
    else conflicts.push({ webVar: v, values: list });
  }
  return { byVar, conflicts, otherExports: [...otherExports].sort() };
}

// ── .vercelignore (web/ is the Vercel project root), gitignore semantics ──────────────────────────
function globToRe(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } // "**/": any number of directories
        else { re += ".*"; i += 1; }                          // "**": anything
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return re;
}
// A pattern with no slash (other than a trailing one) matches at ANY depth ("index.html" also hides
// art/x/index.html); a leading or middle slash anchors it to web/; a trailing slash matches directories only;
// "!" re-includes; the last matching rule wins; nothing inside an excluded directory can be re-included.
export function makeIgnore(lines) {
  const rules = [];
  for (const raw of lines) {
    let l = raw.replace(/\s+$/, "");
    if (!l || l.startsWith("#")) continue;
    const negate = l.startsWith("!"); if (negate) l = l.slice(1);
    if (l.startsWith("\\")) l = l.slice(1);
    const dirOnly = l.endsWith("/"); l = l.replace(/\/+$/, "");
    const anchored = l.includes("/"); l = l.replace(/^\/+/, "");
    if (!l) continue;
    rules.push({ negate, dirOnly, re: new RegExp((anchored ? "^" : "^(?:.*/)?") + globToRe(l) + "$") });
  }
  const state = (p, isDir) => { let ig = false; for (const r of rules) if ((!r.dirOnly || isDir) && r.re.test(p)) ig = !r.negate; return ig; };
  return (rel) => {
    const parts = String(rel).split(sep).join("/").replace(/^(\.\/|\/)+/, "").split("/").filter(Boolean);
    if (!parts.length) return false;
    for (let i = 1; i < parts.length; i++) if (state(parts.slice(0, i).join("/"), true)) return true;
    return state(parts.join("/"), false);
  };
}
function vercelIgnored(webDir) {
  const f = join(webDir, ".vercelignore");
  if (!existsSync(f)) return () => false;
  return makeIgnore(readFileSync(f, "utf8").split(/\r?\n/));
}

function walkHtml(dir, base = dir, out = []) {
  for (const f of readdirSync(dir)) {
    if (f.startsWith(".") || f === "node_modules") continue;
    const p = join(dir, f), st = statSync(p);
    if (st.isDirectory()) walkHtml(p, base, out);
    else if (f.endsWith(".html")) out.push(relative(base, p).split(sep).join("/"));
  }
  return out;
}
// every file under dir (dotfiles and node_modules skipped, as Vercel's CLI skips them), as web/-relative paths
function walkFiles(dir, base = dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const f of readdirSync(dir)) {
    if (f.startsWith(".") || f === "node_modules") continue;
    const p = join(dir, f), st = statSync(p);
    if (st.isDirectory()) walkFiles(p, base, out);
    else out.push(relative(base, p).split(sep).join("/"));
  }
  return out;
}
// Legacy art that must never be published, in ANY deploy configuration: art/reveal holds 250 per-pass metadata
// files and images from an earlier design that name real pass ids as "Super rare" and so on, which the on-chain
// rarity does not match (a seller could point a buyer at the official site as proof), and art/ipfs is the old bundle.
export const NEVER_PUBLISH = [
  { re: /^art\/reveal\//, what: "art/reveal (legacy per-pass tier metadata and images that contradict the on-chain rarity)" },
  { re: /^art\/ipfs\//, what: "art/ipfs (the legacy IPFS metadata bundle)" },
];

// Local files a page needs at runtime (sub) or links to (link), as paths relative to web/.
function localRefs(pageRel, tags, scriptSrcs, scripts) {
  const refs = [];
  const SUB_TAGS = { img: "src", script: "src", source: "src", video: "src", audio: "src", track: "src", embed: "src", iframe: "src", input: "src" };
  for (const t of tags) {
    for (const a of t.attrs) {
      if (SUB_TAGS[t.tag] === a.name) refs.push({ ref: a.value, off: a.off, kind: "sub" });
      else if (t.tag === "link" && a.name === "href") {
        const rel = (t.attrs.find((x) => x.name === "rel") || { value: "" }).value.toLowerCase();
        refs.push({ ref: a.value, off: a.off, kind: /icon|stylesheet|preload|manifest/.test(rel) ? "sub" : "link" });
      } else if (t.tag === "a" && a.name === "href") refs.push({ ref: a.value, off: a.off, kind: "link" });
    }
  }
  for (const s of scriptSrcs) refs.push({ ref: s.ref, off: s.off, kind: "sub" });
  for (const sc of scripts) {
    const { code, strings } = lexJs(sc.body);
    const at = new Map(strings.map((s) => [s.start, s]));
    for (const m of code.matchAll(/\bfetch\s*\(\s*/g)) {
      const s = at.get(m.index + m[0].length);
      if (s == null || (s.tpl && s.value.includes("${"))) continue; // a template with a substitution names no path
      // Only a literal that is CONCATENATED ('art/' + name) is a prefix. Every literal used to be
      // marked prefix, so fetch("data.json") was judged as a directory "data.json/" with nothing under it and FAILed.
      const prefix = /^\s*\+/.test(code.slice(s.end));
      refs.push({ ref: s.value, off: sc.offset + m.index, kind: "sub", prefix });
    }
  }
  const out = [];
  for (const r of refs) {
    let ref = String(r.ref || "").trim();
    if (!ref || /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(ref) || /['"+]/.test(ref)) continue;
    ref = ref.replace(/[?#].*$/, "");
    if (!ref || ref === "/") continue;
    const p = ref.startsWith("/") ? posix.normalize(ref.slice(1)) : posix.normalize(posix.join(posix.dirname(pageRel), ref));
    if (p.startsWith("..") || p === ".") continue;
    out.push({ ...r, ref, path: p });
  }
  return out;
}

// ── the per-page check ───────────────────────────────────────────────────────────────────────────
function checkPage(file, ctx) {
  const html = readFileSync(file, "utf8");
  const lineOf = lineIndex(html);
  const findings = [], notes = [], seen = new Set();
  const push = (level, off, msg) => { const line = lineOf(off), key = level + line + msg; if (seen.has(key)) return; seen.add(key); findings.push({ level, line, msg }); };
  const { scripts, scriptSrcs, csp, markup, text } = splitHtml(html);
  const tags = tagAttrs(markup);
  const target = ctx.chain, targetHex = "0x" + target.toString(16);
  const mainnetTarget = target === RH_MAINNET_CHAIN, profile = CHAIN_PROFILES[target] || null;
  // a host the page must not use for this target: non-mainnet hosts on a 4663 page, mainnet hosts on any other
  const wrongHost = (h) => (mainnetTarget ? NON_MAINNET_HOST.test(h) : MAINNET_HOST.test(h));
  const wrongWhat = mainnetTarget ? "non-mainnet" : `mainnet (the target is chain ${target})`;

  // CSP connect-src, and the script-src 'unsafe-inline' warning
  let connect = null;
  if (csp) {
    connect = cspSources(csp.content, "connect-src");
    for (const s of connect || []) {
      const h = /^https?:\/\//i.test(s) ? hostOf(s) : (/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(s) ? s.toLowerCase() : null);
      if (h && wrongHost(h)) push("FAIL", csp.offset, `CSP connect-src allows a ${wrongWhat} host: ${s}`);
    }
    if ((cspSources(csp.content, "script-src") || []).includes("'unsafe-inline'"))
      push("WARN", csp.offset, "CSP script-src still allows 'unsafe-inline' (needed while the app script is inline: an HTML injection could run script)");
  }

  // URLs anywhere in the markup (attributes included, comments/scripts/styles excluded)
  for (const m of markup.matchAll(/https?:\/\/[^\s"'<>()]+/gi)) {
    const h = hostOf(m[0]);
    if (h && wrongHost(h)) push("FAIL", m.index, `${wrongWhat} URL in the markup: ${m[0]}`);
  }

  // visible text (the mainnet gate only: on a testnet target "testnet" and 46630 are the correct wiring)
  for (const { re, what, level } of (mainnetTarget ? NON_MAINNET_TEXT : [])) {
    const g = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    for (const m of text.matchAll(g)) {
      const ls = text.lastIndexOf("\n", m.index) + 1, le = text.indexOf("\n", m.index);
      push(level, m.index, `visible page text contains ${what}: "${text.slice(ls, le < 0 ? undefined : le).trim().replace(/\s+/g, " ").slice(0, 120)}"`);
    }
  }
  // user-visible attributes: tooltips, alt text, aria labels, placeholders, meta description / og: / twitter: content
  for (const t of tags) {
    const isMeta = t.tag === "meta" && !t.attrs.some((a) => a.name === "http-equiv");
    for (const a of t.attrs) {
      if (!(VISIBLE_ATTRS.has(a.name) || (isMeta && a.name === "content"))) continue;
      for (const { re, what, level } of (mainnetTarget ? NON_MAINNET_TEXT : []))
        if (re.test(a.value)) push(level, a.off, `user-visible <${t.tag} ${a.name}> contains ${what}: "${a.value.replace(/\s+/g, " ").slice(0, 120)}"`);
    }
  }

  let pageChain = null, lockedVal = null, lockedOff = 0, usesMainAllowlist = false;
  const pageVars = {}, zeroVars = [];
  for (const sc of scripts) {
    const { code, strings } = lexJs(sc.body);
    const at = (i) => sc.offset + i;

    // CHAIN object fields
    for (const m of code.matchAll(/\bchainIdHex\s*:\s*["'](0x[0-9a-fA-F]+)["']/g)) {
      const v = parseInt(m[1], 16);
      if (v !== target) push("FAIL", at(m.index), `CHAIN.chainIdHex is ${m[1]} (${v}), expected ${targetHex} (${target})`);
    }
    for (const m of code.matchAll(/\bchainId\s*:\s*(\d+)/g)) {
      const v = Number(m[1]); pageChain = pageChain ?? v;
      if (v !== target) push("FAIL", at(m.index), `CHAIN.chainId is ${v}, expected ${target}`);
    }
    const chainNames = new Set();
    for (const m of code.matchAll(/\bchainName\s*:\s*["']([^"']*)["']/g)) {
      chainNames.add(m[1]);
      if (mainnetTarget) { if (/testnet|devnet|local/i.test(m[1])) push("FAIL", at(m.index), `CHAIN.chainName is "${m[1]}"`); }
      else if (profile && !profile.name.test(m[1])) push("FAIL", at(m.index), `CHAIN.chainName is "${m[1]}", expected ${profile.nameWhat} for chain ${target}`);
    }
    for (const m of code.matchAll(/\brpcUrls\s*:\s*\[([^\]]*)\]/g)) {
      for (const u of m[1].matchAll(/["'](https?:\/\/[^"']+)["']/g)) {
        const h = hostOf(u[1]);
        if (connect && h && !connect.some((s) => hostOf(/^https?:/i.test(s) ? s : "https://" + s) === h))
          push("FAIL", at(m.index), `CHAIN.rpcUrls host ${h} is not in the CSP connect-src, so every chain read would be blocked`);
      }
    }

    // URLs and "testnet" in script strings
    for (const s of strings) {
      let urlHit = false;
      for (const u of s.value.matchAll(/https?:\/\/[^\s"'<>()]+/gi)) {
        const h = hostOf(u[0]);
        if (h && wrongHost(h)) { push("FAIL", at(s.start), `${wrongWhat} URL in a script string: ${u[0]}`); urlHit = true; }
      }
      if (mainnetTarget && !urlHit && /testnet/i.test(s.value) && !/^allowlist\.testnet\.json$/.test(s.value) && !chainNames.has(s.value))
        push("WARN", at(s.start), `script string mentions testnet: "${s.value.slice(0, 100)}" (confirm it only shows on a testnet build)`);
      if (s.value === "allowlist.json") usesMainAllowlist = true;
    }

    // wired addresses: var NAME = "0x..."
    for (const m of code.matchAll(/\bvar\s+([A-Za-z_$][\w$]*)\s*=\s*["'](0x[0-9a-fA-F]{40})["']/g)) {
      const [, name, addr] = m, k = addr.toLowerCase();
      pageVars[name] = { addr, off: at(m.index) };
      // judged after every script is read: LOCKED may sit below the address vars (--allow-unwired needs it)
      if (/^0x0{40}$/.test(k) && !/zero/i.test(name)) zeroVars.push({ name, off: at(m.index) });
    }
    // every address-shaped string, wherever it sits (arrays, objects, arguments)
    for (const s of strings) {
      if (!/^0x[0-9a-fA-F]{40}$/.test(s.value)) continue;
      const src = ctx.otherAddrs.get(s.value.toLowerCase());
      if (src) {
        const name = Object.keys(pageVars).find((n) => pageVars[n].addr.toLowerCase() === s.value.toLowerCase());
        push("FAIL", at(s.start), `${name ? name + " = " : ""}${s.value} is a contract our scripts deployed on another chain (${src[0]}${src.length > 1 ? ` and ${src.length - 1} more` : ""})`);
      }
    }

    const lk = /\bvar\s+LOCKED\s*=\s*(true|false)\b/.exec(code);
    if (lk) { lockedVal = lk[1] === "true"; lockedOff = at(lk.index); }
  }
  // addresses in the markup itself (links, data attributes)
  for (const m of markup.matchAll(/0x[0-9a-fA-F]{40}/g)) {
    const src = ctx.otherAddrs.get(m[0].toLowerCase());
    if (src) push("FAIL", m.index, `${m[0]} in the markup is a contract our scripts deployed on another chain (${src[0]})`);
  }

  // zero-address vars. FAIL (an unwired page), except the pre-launch delegate.html under --allow-unwired: LOCKED =
  // true on the target chain, so the page stays informational (LIVE = false) and cannot mint or delegate.
  const isDelegate = basename(file) === "delegate.html";
  const unwiredOk = ctx.allowUnwired && isDelegate && lockedVal === true && (pageChain === null || pageChain === target);
  const zeroAllowed = new Set();
  for (const z of zeroVars) {
    if (unwiredOk) {
      zeroAllowed.add(z.name);
      push("WARN", z.off, `${z.name} is the zero address, allowed by --allow-unwired: this pre-launch delegate.html stays ` +
        `informational (LIVE = false, LOCKED = true, nothing can be signed). Wire it and drop the flag once DeployNFT has run`);
    } else {
      push("FAIL", z.off, `${z.name} is the zero address (page not wired)` + (ctx.allowUnwired
        ? (isDelegate ? `; --allow-unwired is refused because LOCKED is ${lockedVal === null ? "missing" : lockedVal}${pageChain !== null && pageChain !== target ? ` and the page targets chain ${pageChain}` : ""}`
          : "; --allow-unwired applies only to delegate.html")
        : ""));
    }
  }

  // exact match against the deploy logs. Every wired var the map knows must be PROVEN, not just "not contradicted":
  // a var no log mentions is a FAIL, so feeding the wrong or an incomplete set of logs cannot pass. On mainnet (4663)
  // this is required even with no --deploy-log at all: the broadcast scan only knows the testnet deploys whose
  // run-latest.json this checkout still has, so an address from an older testnet deploy would otherwise pass.
  const deploy = ctx.deploy || (ctx.requireProof ? { byVar: {}, conflicted: new Set(), none: true } : null);
  let handClaimed = [];
  if (deploy) {
    const proven = [], hand = [], unmapped = [], noProof = [];
    for (const [webVar, have] of Object.entries(pageVars)) {
      if (!(webVar in WEB_VAR_EXPORTS)) { if (!/^0x0{40}$/i.test(have.addr)) unmapped.push(webVar); continue; }
      // --allow-unwired: a zero address has nothing to prove. But if a log DOES name this var, the contract exists
      // and the page must carry it, so fall through to the mismatch FAIL below.
      if (zeroAllowed.has(webVar) && !deploy.byVar[webVar] && !deploy.conflicted.has(webVar)) continue;
      if (deploy.conflicted.has(webVar)) {
        push("FAIL", have.off, `${webVar} = ${have.addr} cannot be proven: the deploy logs disagree about it (listed above)`); continue;
      }
      const want = deploy.byVar[webVar];
      if (!want && deploy.none) { noProof.push({ webVar, have }); continue; }
      if (!want) {
        push("FAIL", have.off, `${webVar} = ${have.addr} is not proven: no deploy log has ${WEB_VAR_EXPORTS[webVar].map((n) => "export " + n + "=").join(" / ")}` +
          `${CONSOLE_LINES.filter((c) => c.webVar === webVar).map((c) => " or the " + c.what).join("")}. Pass the log of the script that created it, or --address ${webVar}=0x...`);
        continue;
      }
      if (want.addr.toLowerCase() !== have.addr.toLowerCase())
        push("FAIL", have.off, `${webVar} is ${have.addr} but ${want.src[0]}${want.src.length > 1 ? ` (and ${want.src.length - 1} more)` : ""} says ${want.addr}`);
      else if (want.proven === false) {
        // The page matches an address someone TYPED (or wrote into a bare export file). Say exactly that.
        hand.push(webVar);
        push("WARN", have.off, `${webVar} = ${have.addr} is claimed by hand (${want.handFrom.join("; ")}), not proven by a deploy log.` +
          (isDelegate && webVar === "NFT" && target === RH_MAINNET_CHAIN
            ? " Accepted only for the delegation-only delegate.html before DeployNFT: the second person's recomputation of the address is the only proof. Once DeployNFT has run, re-check with --deploy-log <its log> and no --address"
            : " Pass the log of the script that deployed it instead"));
      }
      else proven.push(webVar);
    }
    if (noProof.length)
      push("FAIL", noProof[0].have.off, `${noProof.length} wired contract address(es) not proven, because no --deploy-log or --address was given ` +
        `(on chain ${target} each must match a deploy log): ${noProof.map((x) => x.webVar).join(", ")}`);
    if (Object.keys(pageVars).length && !deploy.none && (proven.length || !hand.length)) notes.push(`proven against the deploy logs: ${proven.join(", ") || "(none)"}`);
    if (hand.length) notes.push(`claimed by hand, not proven by a deploy log: ${hand.join(", ")}`);
    handClaimed = hand;
    if (unmapped.length) notes.push(`not covered by any deploy log (canonical constants, verify by hand): ${unmapped.join(", ")}`);
  }

  // files this page needs that the deploy excludes (a published page only)
  const loads = [];
  if (ctx.pageRel && !ctx.pageIgnored) {
    for (const r of localRefs(ctx.pageRel, tags, scriptSrcs, scripts)) {
      if (r.kind === "sub" && !r.prefix) loads.push(r.path);
      // A prefix fetch ('art/' + name) 404s only when NOTHING under that prefix is published. Asking whether the
      // directory itself is excluded was wrong once web/.vercelignore publishes art/final-*.svg out of an otherwise
      // excluded art/ (`art/*` + `!art/final-*.svg`). A prefix that ends mid-name ('art/final-' + x) is
      // served when any published file starts with it. A literal full path (not concatenated) is an ordinary file.
      const dirOf = r.path.replace(/\/+$/, "");
      const hit = r.prefix
        ? (r.ref.endsWith("/") ? (ctx.ignored(dirOf) || !ctx.publishedUnder(dirOf)) : !ctx.publishedPrefix(r.path))
        : ctx.ignored(r.path) || (!posix.extname(r.path) && ctx.ignored(r.path + ".html"));
      if (!hit) continue;
      // With vercel.json cleanUrls, /index.html is served as its directory ("/"), which a rewrite may map to
      // another page (web/vercel.json sends "/" to /delegate), so a LINK there is not necessarily dead.
      if (r.kind === "link" && ctx.cleanUrls && posix.basename(r.path) === "index.html") continue;
      if (r.kind === "sub") push("FAIL", r.off, `loads ${r.ref}${r.prefix ? "..." : ""}, which web/.vercelignore excludes, so it 404s on the published site`);
      else push("WARN", r.off, `links to ${r.ref}, which web/.vercelignore excludes (a dead link on the published site)`);
    }
  }

  // delegate.html interlock
  if (isDelegate) {
    if (lockedVal === null) push("FAIL", 0, "delegate.html: no `var LOCKED = true|false` found, the LOCKED interlock is missing");
    else if (lockedVal === false) {
      if (pageChain !== null && pageChain !== target)
        push("FAIL", lockedOff, `delegate.html: LOCKED = false on a chain ${pageChain} build`);
      else if (!ctx.allowUnlocked)
        push("FAIL", lockedOff, "delegate.html: LOCKED = false, so publishing opens delegation. Pass --allow-unlocked only if that is intended now");
    }
  }

  return { findings, notes, usesMainAllowlist, pageChain, loads, handClaimed };
}

export async function main(argv) {
  let o;
  try { o = parseArgs(argv); } catch (e) { return usage(e.message); }
  if (!existsSync(o.web)) return usage("web dir not found: " + o.web);

  const ignored = vercelIgnored(o.web);
  // what Vercel would upload (every file, not just pages), for prefix fetches and the art/ asset check
  let _pubFiles = null;
  const publishedFiles = () => (_pubFiles ??= walkFiles(o.web).filter((f) => !ignored(f)));
  const publishedUnder = (dir) => publishedFiles().some((f) => f.startsWith(dir + "/"));
  const publishedPrefix = (pre) => publishedFiles().some((f) => f.startsWith(pre));
  let cleanUrls = false;
  try { cleanUrls = !!JSON.parse(readFileSync(join(o.web, "vercel.json"), "utf8")).cleanUrls; } catch { /* no vercel.json */ }
  let pages, skipped = [];
  if (o.files.length) pages = o.files;
  else {
    const all = walkHtml(o.web).sort();
    pages = all.filter((f) => o.all || !ignored(f)).map((f) => join(o.web, f));
    skipped = o.all ? [] : all.filter((f) => ignored(f));
  }
  for (const p of pages) if (!existsSync(p)) return usage("no such page: " + p);

  const bc = collectBroadcastAddresses(o.broadcast, o.chain);
  const otherAddrs = bc.other;
  try {
    for (const f of o.testnetAddrFiles) for (const a of readAddressList(f)) if (!otherAddrs.has(a)) otherAddrs.set(a, [relative(process.cwd(), f)]);
  } catch (e) { return usage("cannot read --testnet-addresses: " + e.message); }
  let deploy = null;
  // A --deploy-log holding nothing but bare `export NAME=0x...` lines is a hand-written claim, not a deploy log
  const bareLogs = new Set();
  try { for (const f of o.deployLogs) if (isBareExportFile(readFileSync(f, "utf8"))) bareLogs.add(f); }
  catch (e) { return usage("cannot read --deploy-log: " + e.message); }
  if (o.deployLogs.length || o.addresses.length) {
    let parsed;
    try { parsed = parseDeployLogs(o.deployLogs, o.addresses, { handFiles: bareLogs }); } catch (e) { return usage("cannot read --deploy-log: " + e.message); }
    if (!Object.keys(parsed.byVar).length && !parsed.conflicts.length)
      return usage("no address the site uses was found in the deploy log(s) (`export NAME=0x...` lines; accepted names: " +
        Object.values(WEB_VAR_EXPORTS).flat().join(", ") + ")");
    deploy = { ...parsed, conflicted: new Set(parsed.conflicts.map((c) => c.webVar)) };
  }

  console.log(`check-web-wiring: target chain ${o.chain} (0x${o.chain.toString(16)})`);
  console.log(`pages: ${pages.map((p) => relative(ROOT, p)).join(", ") || "(none)"}` + (o.files.length ? "" : (o.all ? "  [--all]" : "  [web/.vercelignore applied]")));
  if (skipped.length) console.log(`not checked (excluded by web/.vercelignore, use --all to include): ${skipped.join(", ")}`);
  console.log(bc.missing
    ? `WARN  no broadcast dir at ${relative(ROOT, o.broadcast) || o.broadcast}: other-chain addresses come only from --testnet-addresses (${otherAddrs.size})`
    : `known other-chain contract addresses: ${otherAddrs.size} (from ${relative(ROOT, o.broadcast)}${o.testnetAddrFiles.length ? " + --testnet-addresses" : ""})`);

  let fails = 0, warns = 0, failPages = 0, anyMainAllowlist = false;
  const loadedByPublished = new Set(), handVars = new Set();
  if (deploy) {
    console.log("deploy logs: " + (o.deployLogs.map((f) => relative(process.cwd(), f)).join(", ") || "(none)") +
      (o.addresses.length ? `; --address ${o.addresses.map((a) => a.name).join(", ")}` : ""));
    for (const f of bareLogs) {
      fails++;
      console.log(`  FAIL  ${relative(process.cwd(), f)} is not a deploy log: every line is a bare \`export NAME=0x...\` with no script output around it ` +
        `(the shape of the nft-precomputed.log that the delegation-only launch step writes for script/wire-web.mjs), so it proves nothing. ` +
        `Pass the tee'd output of the script that deployed the contract (after DeployNFT: --deploy-log nft.log). Before DeployNFT, the ` +
        `delegation-only page is checked with --address NFT=<X> --allow-unlocked, which is reported as claimed by hand.`);
    }
    for (const [v, x] of Object.entries(deploy.byVar).sort())
      console.log(x.proven === false
        ? `  hand  ${v} = ${x.addr}  <- ${x.src.join("; ")}`
        : `  ok    ${v} = ${x.addr}  <- ${x.src.join("; ")}`);
    for (const c of deploy.conflicts) {
      fails++;
      console.log(`  FAIL  ${c.webVar}: the deploy logs disagree, so nothing is proven for it. Pass only the logs of ONE deploy:`);
      for (const x of c.values) console.log(`          ${x.addr}  <- ${x.src}`);
    }
    const missing = Object.keys(WEB_VAR_EXPORTS).filter((v) => !(v in deploy.byVar) && !deploy.conflicted.has(v));
    if (missing.length) console.log(`  note  no value in the logs for: ${missing.join(", ")} (a page that wires one of these fails below)`);
  }
  console.log("");

  for (const p of pages) {
    const relWeb = relative(o.web, p).split(sep).join("/");
    const inWeb = relWeb && !relWeb.startsWith("..");
    const { findings, notes, usesMainAllowlist, loads, handClaimed } = checkPage(p, { chain: o.chain, otherAddrs, deploy, allowUnlocked: o.allowUnlocked,
      allowUnwired: o.allowUnwired, requireProof: o.chain === 4663, ignored, publishedUnder, publishedPrefix, cleanUrls, pageRel: inWeb ? relWeb : null,
      pageIgnored: inWeb ? ignored(relWeb) : false });
    for (const l of loads || []) loadedByPublished.add(l);
    for (const v of handClaimed || []) handVars.add(v);
    anyMainAllowlist = anyMainAllowlist || usesMainAllowlist;
    const rel = relative(ROOT, p);
    const pf = findings.filter((f) => f.level === "FAIL").length;
    fails += pf; warns += findings.length - pf; if (pf) failPages++;
    console.log(rel + (findings.length ? "" : "  ok"));
    for (const f of findings.sort((a, b) => a.line - b.line)) console.log(`  ${f.level}  ${rel}:${f.line}  ${f.msg}`);
    for (const n of notes) console.log(`  info  ${n}`);
  }

  // allowlist files (the chain-scoped pair; one overwrote the other once)
  if (anyMainAllowlist || !o.files.length) {
    const mainFile = join(o.web, "allowlist.json"), test = join(o.web, "allowlist.testnet.json");
    const say = (lvl, msg) => { console.log(`  ${lvl}  ${msg}`); if (lvl === "FAIL") fails++; else warns++; };
    console.log(relative(ROOT, mainFile));
    if (!existsSync(mainFile)) say("FAIL", "web/allowlist.json is missing; mainnet pages load it for allowlist proofs");
    else {
      if (ignored("allowlist.json")) say("FAIL", "web/allowlist.json is excluded by web/.vercelignore, so the published pages cannot load proofs");
      let mj = null; try { mj = JSON.parse(readFileSync(mainFile, "utf8")); } catch (e) { say("FAIL", "web/allowlist.json does not parse: " + e.message); }
      if (mj) {
        const n = mj.proofs ? Object.keys(mj.proofs).length : 0;
        if (!mj.root || !n) say("FAIL", `web/allowlist.json has root=${mj.root || "(none)"} and ${n} proofs`);
        if (existsSync(test)) {
          try { const tj = JSON.parse(readFileSync(test, "utf8"));
            if (tj.root && mj.root && String(tj.root).toLowerCase() === String(mj.root).toLowerCase())
              say("FAIL", `web/allowlist.json has the SAME root as allowlist.testnet.json (${mj.root}): the testnet list overwrote the mainnet one`);
          } catch { /* a broken testnet file is not a mainnet problem */ }
        }
        if (mj.root && mj.proofs) console.log(`  ok    root ${mj.root}, ${n} proofs (compare against NFTCollection.allowlistRoot() on chain ${o.chain})`);
      }
    }
  }

  // Published assets under web/art. Judged by web/.vercelignore in every mode (--all only widens the PAGE scan;
  // what Vercel uploads is still decided by that file), and only when checking the whole site, not named pages.
  if (!o.files.length) {
    const say = (lvl, msg) => { console.log(`  ${lvl}  ${msg}`); if (lvl === "FAIL") fails++; else warns++; };
    const artFiles = walkFiles(join(o.web, "art"), o.web);
    const shipped = artFiles.filter((f) => !ignored(f));
    console.log(`${relative(ROOT, join(o.web, "art"))}/ (published assets)`);
    for (const n of NEVER_PUBLISH) {
      const hit = shipped.filter((f) => n.re.test(f));
      if (hit.length) say("FAIL", `${hit.length} file(s) under ${n.what} would be published by web/.vercelignore: ${hit.slice(0, 3).join(", ")}${hit.length > 3 ? ", ..." : ""}. Keep an \`${n.re.source.replace(/\\/g, "").replace(/^\^/, "")}\` line in web/.vercelignore`);
    }
    const other = shipped.filter((f) => !NEVER_PUBLISH.some((n) => n.re.test(f)) && !loadedByPublished.has(f));
    if (other.length) say("WARN", `${other.length} file(s) under art/ would be published that no published page loads by path: ${other.slice(0, 4).join(", ")}${other.length > 4 ? ", ..." : ""} (publish only what pages load: \`art/*\` plus \`!art/final-*.svg\`)`);
    if (!shipped.length || shipped.every((f) => loadedByPublished.has(f))) console.log(`  ok    ${shipped.length} art file(s) published${shipped.length ? ", each loaded by a published page" : ""}`);
  }

  console.log("");
  if (o.allowUnwired)
    console.log("note: --allow-unwired: a zero-address var was accepted ONLY on a delegate.html with LOCKED = true (a pre-launch,\n" +
      "      informational page). Every non-zero address still had to be proven. Drop the flag once DeployNFT has run.");
  if (!deploy) {
    if (o.chain === 4663)
      console.log("note: no --deploy-log, so every wired contract address above that is not proven FAILS. Pass the DeployNFT and Deploy logs\n" +
        "      (the Deploy.s.sol log also carries index.html's \"SWAP ROUTER (site buy/sell): 0x...\" line) before a mainnet deploy.");
    else console.log("note: addresses were checked against known other-chain deployments only. Pass --deploy-log to require an exact match.");
  }
  if (handVars.size)
    console.log(`note: ${[...handVars].join(", ")} ${handVars.size > 1 ? "are" : "is"} CLAIMED BY HAND, NOT PROVEN BY A DEPLOY LOG: the page matches an address that was typed\n` +
      "      (--address) or written into a bare export file, and nothing here shows a deploy created it. On chain 4663 that is accepted only\n" +
      "      for the delegation-only delegate.html before DeployNFT, where the second\n" +
      "      person's recomputation of the NFT address is the only proof. After DeployNFT, re-check with --deploy-log <its log> and no --address.");
  if (fails) {
    console.log(`RESULT: FAIL, ${fails} finding(s)${failPages ? ` in ${failPages} page(s)` : ""}${warns ? `, ${warns} warning(s)` : ""}. Do not deploy web/ for chain ${o.chain}.`);
    return 1;
  }
  console.log(`RESULT: PASS${warns ? ` with ${warns} warning(s) to read` : ""}.` +
    (handVars.size ? ` Claimed by hand, not proven by a deploy log: ${[...handVars].join(", ")}.` : ""));
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => { console.error(e && e.stack || e); process.exit(2); });
}
