#!/usr/bin/env bash
# ============================================================================
# QPULL §13.2 — Is the BLS12-381 (EIP-2537) precompile set live on Robinhood Chain?
#
# WHY a raw eth_call and not a forge fork test: a forked forge test executes the
# precompile in your LOCAL revm, whose behaviour is set by `evm_version`, NOT by the
# remote chain. That gives false positives/negatives for precompile presence. The only
# faithful test is an eth_call sent to the REAL RPC node, executed remotely. That is this.
#
# This is the BLOCKING unknown: it decides the drand oracle architecture (on-chain BLS
# verification vs. a permissionless relayer + on-chain challenge window).
#
# Requires: curl, jq, and RH_RPC_URL (in the environment or in ./.env).
# ============================================================================
set -uo pipefail

[ -f .env ] && set -a && . ./.env && set +a
: "${RH_RPC_URL:?set RH_RPC_URL (Robinhood Chain RPC) in the environment or ./.env}"

call() { # $1=to  $2=data(hex)
  local to="$1" data="$2"
  [ "${data:0:2}" = "0x" ] || data="0x${data}"
  curl -s -X POST "$RH_RPC_URL" -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$to\",\"data\":\"$data\"},\"latest\"]}"
}
zeros() { printf '0%.0s' $(seq 1 "$1"); }   # $1 = count of hex chars

echo "RPC: $RH_RPC_URL"
echo

# --- G1ADD @ 0x0b : inf + inf = inf. input 256 bytes(0) -> expect 128 bytes(0) ---
echo "[G1ADD 0x0b]  inf + inf"
resp=$(call "0x000000000000000000000000000000000000000b" "0x$(zeros 512)")
res=$(echo "$resp" | jq -r '.result // empty'); err=$(echo "$resp" | jq -r '.error.message // empty')
if   [ -n "$err" ]; then echo "  error: $err"
elif [ -z "$res" ] || [ "$res" = "0x" ]; then echo "  ABSENT   (empty return = no precompile at this address)"
elif [ "$res" = "0x$(zeros 256)" ]; then echo "  PRESENT  (returned the point at infinity, 128 zero bytes)"
else echo "  UNEXPECTED: $res"; fi
echo

# --- PAIRING @ 0x0f : empty input => 1 (true). the precompile drand actually needs ---
echo "[PAIRING 0x0f]  empty input  (drand-critical)"
resp=$(call "0x000000000000000000000000000000000000000f" "0x")
res=$(echo "$resp" | jq -r '.result // empty'); err=$(echo "$resp" | jq -r '.error.message // empty')
if   [ -n "$err" ]; then echo "  error: $err   (strict impls may reject empty input — itself informative)"
elif [ -z "$res" ] || [ "$res" = "0x" ]; then echo "  ABSENT   (empty return)"
elif [ "${res: -2}" = "01" ]; then echo "  PRESENT  (empty pairing product returned true)"
else echo "  UNEXPECTED: $res"; fi
echo

echo "-------------------------------------------------------------------------"
echo "VERDICT"
echo "  BOTH present  -> native drand BLS verification is viable on-chain (spec §6)."
echo "                   Deploy BlsDrandOracle."
echo "  Either ABSENT -> §13.2 fallback: permissionless relayer + on-chain challenge window."
echo "                   Deploy RelayerDrandOracle. Same IDrandOracle interface — no other code changes."
