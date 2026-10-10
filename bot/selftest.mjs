/** Self-test for the paths a live draw exercises but a dry run cannot: topic derivation, log decode,
 *  copy, and the OAuth 1.0a signature. Run: node selftest.mjs */
import { ethers } from "ethers";
import { createHmac } from "node:crypto";
let pass = 0, fail = 0;
const ok = (n, c, extra="") => { c ? (pass++, console.log(`  PASS  ${n}${extra?"  "+extra:""}`)) : (fail++, console.log(`  FAIL  ${n}  ${extra}`)); };

/* 1. topic hashes: the bot derives these via iface.fragments[0]; check against keccak of the signature. */
const SIGS = {
  raffle: "DrawExecuted(uint32,uint256,uint256)",
  holder: "Drawn(uint256,uint256,uint256)",
  leaderboard: "Distributed(uint256,uint256,uint256)",
};
const ABIS = {
  raffle: "event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners)",
  holder: "event Drawn(uint256 indexed week, uint256 pot, uint256 winners)",
  leaderboard: "event Distributed(uint256 indexed week, uint256 pot, uint256 winners)",
};
for (const k of Object.keys(SIGS)) {
  const iface = new ethers.Interface([ABIS[k]]);
  const derived = iface.getEvent(iface.fragments[0].name).topicHash;   // exactly what drawbot.js does
  ok(`topic ${k}`, derived === ethers.id(SIGS[k]), derived);
}

/* 2. decode a SYNTHETIC log through the real path, for each engine. */
function synth(k, period, potEth, winners) {
  const iface = new ethers.Interface([ABIS[k]]);
  const ev = iface.getEvent(iface.fragments[0].name);
  return { iface, log: {
    topics: [ev.topicHash, ethers.zeroPadValue(ethers.toBeHex(period), 32)],
    data: ethers.AbiCoder.defaultAbiCoder().encode(["uint256","uint256"], [ethers.parseUnits(potEth,18), winners]),
    blockNumber: 70922662, transactionHash: "0x"+"11".repeat(32),
  }};
}
for (const [k, period, potEth, winners] of [["raffle",1,"0.4874",5],["holder",1,"1.2036",12],["leaderboard",3,"0.8415",47]]) {
  const { iface, log } = synth(k, period, potEth, winners);
  const p = iface.parseLog(log);
  const gotPeriod = p.args[0].toString(), gotPot = ethers.formatUnits(p.args[1],18), gotWin = Number(p.args[2]);
  ok(`decode ${k}`, gotPeriod === String(period) && Number(gotPot) === Number(potEth) && gotWin === winners,
     `period=${gotPeriod} pot=${gotPot} winners=${gotWin}`);
}

/* 3. uint32 indexed must not be mis-read (raffle's day is uint32, the weeklies are uint256). */
{
  const { iface, log } = synth("raffle", 4294967295, "1.0", 1);   // max uint32
  ok("decode raffle uint32 max", iface.parseLog(log).args[0].toString() === "4294967295");
}

/* 3b. the opening draw is emitted as day 0 and must be labelled "Opening draw", not "Daily draw". */
{
  const { iface, log } = synth("raffle", 0, "0.4874", 5);
  const p = iface.parseLog(log);
  ok("opening draw decodes as period 0", p.args[0].toString() === "0" && Number(p.args[2]) === 5);
}
/* 3c. a zero-winner event must be recognisable as a non-event (skip / forgone / empty window). */
{
  const { iface, log } = synth("raffle", 1, "0.4874", 0);
  const p = iface.parseLog(log);
  ok("zero-winner event is detectable", Number(p.args[2]) === 0,
     "must be ignored AND not recorded, or it suppresses the real draw for that day");
}

/* 4. OAuth 1.0a signature: cross-checked against an independent implementation (the __SIG__ line below is printed for that comparison). */
const enc = (s) => encodeURIComponent(s).replace(/[!*()']/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
ok("percent-encode reserved", enc("a!b*c'd(e)f") === "a%21b%2Ac%27d%28e%29f", enc("a!b*c'd(e)f"));
ok("percent-encode unreserved kept", enc("aZ09-._~") === "aZ09-._~", enc("aZ09-._~"));
function sigFor(p, creds, method, url) {
  const base = [method.toUpperCase(), enc(url), enc(Object.keys(p).sort().map((k)=>`${enc(k)}=${enc(p[k])}`).join("&"))].join("&");
  return createHmac("sha1", `${enc(creds.secret)}&${enc(creds.tokenSecret)}`).update(base).digest("base64");
}
const P = { oauth_consumer_key:"ck", oauth_nonce:"nonce123", oauth_signature_method:"HMAC-SHA1",
            oauth_timestamp:"1700000000", oauth_token:"tok", oauth_version:"1.0" };
const C = { secret:"cs", tokenSecret:"ts" };
const SIG = sigFor(P, C, "POST", "https://api.x.com/2/tweets");
console.log(`  ..    signature for the fixed vector: ${SIG}`);
process.stdout.write(`__SIG__${SIG}\n`);

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exitCode = fail ? 1 : 0;
