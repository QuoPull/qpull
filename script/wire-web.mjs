#!/usr/bin/env node
/*
 * wire-web.mjs: a dev helper that rewires the site's contract addresses from deploy logs.
 *
 * Rewires the address vars in web/index.html and web/delegate.html from deploy logs. Run the deploy with the
 * console output captured (for example `forge script ... --broadcast | tee /tmp/quopull-deploy.log`), then:
 *
 *     node script/wire-web.mjs /tmp/quopull-deploy.log [/tmp/quopull-golive.log ...]
 *
 * It reads every `export NAME=0x...` line (plus the two console lines some scripts print instead of an export:
 * `SWAP ROUTER (site buy/sell): 0x...`, printed by Deploy.s.sol on mainnet and GoLiveTestnet on testnet for the one
 * site router both chains deploy, src/periphery/QpullSwapRouter.sol, and Deploy.s.sol's `LeaderboardReg  0x...`),
 * maps each to the matching web var through WEB_VAR_EXPORTS in tools/check-web-wiring.mjs (imported, so the rewire
 * and the pre-deploy check read logs identically), and replaces only the address inside `var VAR="0x..."`.
 * On a line it CHANGES, the trailing // comment's provenance is rewritten to `wired from <log> on <date>`: a
 * descriptive comment ("daily raffle") is kept, but a comment naming an old run (a date, "GoLiveTestnet run ...",
 * "pre-QpullSwapRouter", an earlier "wired from") is replaced, so a rewired address never keeps a comment
 * describing the address it replaced. Lines it does not change keep their comment untouched. Testnet (DeployTestnet) and mainnet (DeployNFT / Deploy.s.sol) export
 * names are both understood, e.g. QPULL_TOKEN or QPULL, RAFFLE_VAULT or PRIZE_VAULT, NFT or NFT_ADDRESS.
 * If two logs give one var different addresses it refuses to write anything.
 * WEB_PATH=<file> limits the rewire to that one page.
 * It never touches keeper/.env (that holds your key) — paste the same export block there yourself.
 *
 * PRE-DEPLOY CHECK. Rewiring addresses is not the same as a mainnet-ready site: the CHAIN object, the
 * CSP connect-src, visible chain text and delegate.html's LOCKED switch are not touched by this tool. Before
 * every Vercel deploy of web/ for chain 4663, run
 *
 *     node script/wire-web.mjs --check --deploy-log nft.log --deploy-log deploy.log [--address ROUTER=0x...] [--all] [--allow-unlocked]
 *
 * which runs tools/check-web-wiring.mjs and exits non-zero, printing every problem, if any published page still
 * carries testnet wiring or a wired address the logs do not prove.
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const CHECK = new URL("../tools/check-web-wiring.mjs", import.meta.url).href;

if (process.argv[2] === "--check") {
  const { main } = await import(CHECK);
  process.exit(await main(process.argv.slice(3)));
}

const logs = process.argv.slice(2);
if (!logs.length || logs.some((a) => a.startsWith("-"))) {
  console.error("usage: node script/wire-web.mjs <deploy-log-file> [more-log-files...]\n       node script/wire-web.mjs --check [check flags]");
  process.exit(1);
}
for (const f of logs) if (!existsSync(f)) { console.error("no such log file:", f); process.exit(1); }

const { WEB_VAR_EXPORTS, parseDeployLogs } = await import(CHECK);
const { byVar, conflicts } = parseDeployLogs(logs);

if (conflicts.length) {
  console.error("REFUSING to rewire: the logs give these vars more than one address. Pass only the logs of ONE deploy.");
  for (const c of conflicts) { console.error(`  ${c.webVar}:`); for (const x of c.values) console.error(`    ${x.addr}  <- ${x.src}`); }
  process.exit(1);
}
if (!Object.keys(byVar).length) {
  console.error("No `export NAME=0x...` line for any web var found in", logs.join(", "),
    "\nDeploy with the console output captured, e.g. `... --broadcast | tee " + logs[0] + "`");
  process.exit(1);
}

// The trailing comment on a rewired address line. Keep what describes the VARIABLE, drop what describes a RUN.
const PROVENANCE = /(\b20\d\d-\d\d-\d\d\b|\bwired from\b|\bGoLive\w*\s+run\b|\bDeploy\w*\s+run\b|\bpre-QpullSwapRouter\b|\(TESTNET address\))/i;
function rewriteProvenance(html, webVar, src) {
  const day = new Date().toISOString().slice(0, 10);
  // src reads like `export NFT= (logs/deploy.log:51)`: keep the log file's basename and line
  const m = /\(([^()]*)\)\s*$/.exec(String(src || ""));
  const base = (m ? m[1] : String(src || "log")).split(/[\\/]/).pop();
  const note = `wired from ${base} on ${day}`;
  const lineRe = new RegExp(`^(.*var\\s+${webVar}\\s*=\\s*"0x[0-9a-fA-F]{40}"\\s*;?)([ \\t]*//(.*))?$`, "m");
  return html.replace(lineRe, (_all, decl, _c, comment) => {
    let keep = (comment || "").trim();
    // a comment that is only provenance goes; a descriptive one keeps its text minus any earlier provenance suffix
    keep = keep.replace(/\s*\(wired from [^)]*\)\s*$/i, "").trim();
    if (PROVENANCE.test(keep)) keep = "";
    return `${decl} // ${keep ? keep + " " : ""}(${note})`;
  });
}

const pages = process.env.WEB_PATH ? [process.env.WEB_PATH] : ["web/index.html", "web/delegate.html"];
const wiredSomewhere = new Set();
for (const webPath of pages) {
  if (!existsSync(webPath)) { console.log(`WARN ${webPath} not found, skipped`); continue; }
  const before = readFileSync(webPath, "utf8");
  let html = before;
  const changed = [], stale = [];
  for (const webVar of Object.keys(WEB_VAR_EXPORTS)) {
    // replace only the quoted address after `var WEBVAR=`, keep any trailing comment
    const re = new RegExp(`(var\\s+${webVar}\\s*=\\s*")(0x[0-9a-fA-F]{40})(")`);
    const m = re.exec(html);
    if (!m) continue;
    wiredSomewhere.add(webVar);
    const want = byVar[webVar];
    if (!want) { stale.push(`${webVar} (still ${m[2]})`); continue; }
    if (m[2].toLowerCase() !== want.addr.toLowerCase()) {
      html = html.replace(re, `$1${want.addr}$3`);
      html = rewriteProvenance(html, webVar, want.src[0]);
      changed.push(`${webVar} <- ${want.addr}  (${want.src[0]})`);
    }
  }
  if (html !== before) writeFileSync(webPath, html);
  console.log(`${webPath}: rewired ${changed.length}`);
  changed.forEach((c) => console.log("  " + c));
  // ROUTER (QpullSwapRouter) comes from its `SWAP ROUTER (site buy/sell):` line: in the Deploy.s.sol log on mainnet, in
  // the GoLiveTestnet log on testnet (NOT in DeployTestnet's export block). Without that log the site keeps the
  // PREVIOUS run's router, which still HAS CODE so every liveness check passes and only an actual swap fails.
  // Bit us 2026-09-13. So a var the logs did not cover is named, never skipped quietly.
  if (stale.length) console.log(`  WARN not in these logs, left as they were: ${stale.join(", ")}`);
}
const unused = Object.keys(byVar).filter((v) => !wiredSomewhere.has(v));
if (unused.length) console.log("note: in the logs but no page wires it:", unused.join(", "));
console.log("\nDone. Hard-refresh the site (Cmd-Shift-R). Paste the SAME export block into keeper/.env for the keeper.");
console.log("Only addresses were rewired. Before any Vercel deploy for mainnet run: node script/wire-web.mjs --check --deploy-log <logs>");
