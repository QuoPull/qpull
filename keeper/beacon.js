/*
 * drand-quicknet beacon fetch + formatting for BlsDrandOracle.submitBeacon.
 *
 * drand quicknet signatures are G1 points, published COMPRESSED (48 bytes). Our on-chain verifier
 * (EIP-2537 BLS12-381 pairing) needs the UNCOMPRESSED 128-byte encoding: for each of x,y a 64-byte
 * field = 16 zero bytes + 48-byte big-endian. We fetch the compressed sig from a drand HTTP relay and
 * decompress it with @noble/curves.
 *
 * TRUST. A relay is untrusted transport: submitBeacon verifies the BLS signature on-chain, so a wrong or
 * forged beacon REVERTS (fails safe, never mis-settles). What a relay CAN do is withhold, stall or answer for
 * the wrong round. So every request carries a timeout, the answer's round must be the round asked
 * for, the signature must decode to a valid G1 point, and a failing relay falls through to the next one.
 *
 * Relays: DRAND_RELAYS (comma-separated) or the public quicknet defaults below. DRAND_API (the old single
 * endpoint) is still honoured and tried first. keeper.js --failsafe asks in the REVERSE order, so a
 * primary and a failsafe copy do not share their first point of failure.
 * Env is read at CALL time, not import time, so a caller that loads .env after importing this file still works.
 */
import { bls12_381 } from "@noble/curves/bls12-381";

export const QUICKNET_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971";

/// Public relays serving the quicknet chain hash (League of Entropy / drand, and Cloudflare's mirror).
export const DEFAULT_RELAYS = Object.freeze([
  "https://api.drand.sh",
  "https://api2.drand.sh",
  "https://api3.drand.sh",
  "https://drand.cloudflare.com",
]);

export const DEFAULT_TIMEOUT_MS = 10_000;

/// The ordered relay list. Blank entries are ignored; duplicates and trailing slashes are removed.
export function relayList({ failsafe = false, env = process.env } = {}) {
  const clean = (u) => String(u).trim().replace(/\/+$/, "");
  const fromEnv = String(env.DRAND_RELAYS ?? "").split(",").map(clean).filter(Boolean);
  const legacy = clean(env.DRAND_API ?? "");
  const out = [];
  for (const u of [legacy, ...(fromEnv.length ? fromEnv : DEFAULT_RELAYS)]) {
    if (u && !out.includes(u)) out.push(u);
  }
  return failsafe ? out.reverse() : out;
}

/// The HTTP statuses a relay answers for a round it does not serve YET. Measured with live read-only
/// requests: drand.cloudflare.com answers 404, but api.drand.sh, api2.drand.sh and api3.drand.sh answer 425 Too Early
/// ("Requested future beacon"). Counting only 404 made notPublished false with the shipped relay list, so a round a
/// few seconds early (a lagging relay, a fast host clock) was reported as a failed fetch instead of "pending".
export const NOT_YET_PUBLISHED_STATUSES = Object.freeze([404, 425]);

/// Thrown when no relay produced a usable signature. `notPublished` is true only when EVERY relay answered with a
/// NOT_YET_PUBLISHED_STATUSES code (404 or 425), which is what a relay returns for a round it does not serve yet (so
/// the caller may call it "pending" while the round is fresh). A timeout, a 5xx, a wrong round or a bad point is
/// never notPublished.
export class DrandFetchError extends Error {
  constructor(message, { notPublished = false, failures = [] } = {}) {
    super(message);
    this.name = "DrandFetchError";
    this.notPublished = notPublished;
    this.failures = failures;
  }
}

// bigint field element -> EIP-2537 Fp: 16 zero bytes + 48-byte big-endian (64 bytes, 128 hex chars).
function fp(x) {
  return "00".repeat(16) + x.toString(16).padStart(96, "0");
}

// 48-byte compressed G1 sig (hex) -> 0x-prefixed 128-byte uncompressed (EIP-2537) hex.
export function toUncompressedSig(compressedHex) {
  const p = bls12_381.G1.ProjectivePoint.fromHex(compressedHex.replace(/^0x/, ""));
  p.assertValidity();
  const { x, y } = p.toAffine();
  return "0x" + fp(x) + fp(y);
}

/// Fetch round `round`'s compressed signature. Tries each relay in order and returns the first answer that
/// (a) is HTTP 200, (b) names the requested round, and (c) decodes to a valid G1 point.
/// Returns { signature, relay }. Throws DrandFetchError when every relay failed.
export async function fetchBeacon(round, { relays, timeoutMs, env = process.env } = {}) {
  const want = BigInt(round);
  const list = relays ?? relayList({ env });
  const ms = Number(timeoutMs ?? env.DRAND_TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS;
  const failures = [];
  let allNotYet = list.length > 0;
  for (const relay of list) {
    try {
      const res = await fetch(`${relay}/${QUICKNET_HASH}/public/${want}`, { signal: AbortSignal.timeout(ms) });
      if (!res.ok) {
        if (!NOT_YET_PUBLISHED_STATUSES.includes(res.status)) allNotYet = false;
        failures.push(`${relay}: HTTP ${res.status}`);
        continue;
      }
      allNotYet = false;
      const j = await res.json();
      let answered = null;
      try {
        answered = j?.round === undefined || j?.round === null ? null : BigInt(j.round);
      } catch {
        answered = null; // a non-integer round field: reported below as a wrong round
      }
      if (answered !== want) {
        failures.push(`${relay}: answered round ${j?.round}, not ${want}`);
        continue;
      }
      const sig = typeof j.signature === "string" ? j.signature.replace(/^0x/, "") : "";
      if (!/^[0-9a-fA-F]{96}$/.test(sig)) {
        failures.push(`${relay}: signature is not 48 bytes of hex`);
        continue;
      }
      try {
        toUncompressedSig(sig);
      } catch (e) {
        failures.push(`${relay}: signature is not a valid G1 point (${e.message})`);
        continue;
      }
      return { signature: sig, relay };
    } catch (e) {
      allNotYet = false;
      const timedOut = e?.name === "TimeoutError" || e?.name === "AbortError";
      failures.push(`${relay}: ${timedOut ? `no answer within ${ms}ms` : e.message}`);
    }
  }
  throw new DrandFetchError(
    `drand round ${want}: no relay returned it (${failures.join("; ") || "no relays configured"})`,
    { notPublished: allNotYet, failures },
  );
}

/// Back-compatible: the 48-byte compressed signature hex only.
export async function fetchCompressedSig(round, opts = {}) {
  return (await fetchBeacon(round, opts)).signature;
}

/// { round, sig, comp, relay } ready to pass to BlsDrandOracle.submitBeacon(round, sig, comp).
export async function beaconSubmitData(round, opts = {}) {
  const { signature, relay } = await fetchBeacon(round, opts);
  const sig = toUncompressedSig(signature); // 128-byte uncompressed, for the pairing
  const comp = "0x" + signature; // 48-byte compressed, drand's published form (stored)
  return { round, sig, comp, relay };
}
