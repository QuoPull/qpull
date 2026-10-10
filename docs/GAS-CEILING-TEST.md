# GAS-CEILING-TEST: observe the ArbOS 32,000,000 per-tx clamp in a mined block

Robinhood Chain testnet, chainId 46630. This is a prepared, read-only test plan. Nothing here has been
broadcast. You sign and send every state-changing command yourself with `--account deployer`. No private key
is ever handled by anyone but you.

Do NOT run the deploy or the burn against mainnet. Testnet only.

---

## 1. What this proves, and what each outcome means

The real per-transaction gas ceiling on Robinhood Chain is **32,000,000**. That number has been read three ways
already:

- from consensus state: `ArbGasInfo.getMaxTxGasLimit()` at `0x…006C` returns `0x1e84800` = 32,000,000,
- confirmed as an ArbOS >= 50 clamp branch: `ArbSys.arbOSVersion()` = 116, minus the +55 offset = ArbOS 61,
- observed to bite in `eth_estimateGas` (Nitro's messageGasEstimationMode).

Nitro source shows the commit path (real block production) takes the same clamp branch, because only
`messageEthcallMode` is exempt. But nobody has ever watched the clamp fire in an actually mined block. That is
the single remaining gap. This transaction closes it.

The method: deploy a contract whose honest work needs about **38,000,000 gas**, then call it in a transaction
that explicitly asks for **`--gas-limit 40000000`**. The requested limit (40M) sits above the clamp (32M). The
honest workload (38M) also sits above the clamp but below the requested limit. So the workload can only complete
if the transaction is actually granted more than 32,000,000 gas of execution.

Three outcomes are possible, and each one is unambiguous:

- **Rejected at submission** (never mined): the sequencer enforces the cap at ingress. Clamp confirmed at the
  mempool layer.
- **Mined, but failed, having burned about 32,000,000 gas**: ArbOS clamped the execution to 32M mid-run, the
  burner ran out of gas and reverted. Clamp confirmed in block production. **This is the expected result.**
- **Mined, succeeded, having burned about 38,000,000 gas**: the transaction was granted the full requested
  budget. The 32M ceiling does NOT apply to block production. **This would REFUTE the clamp and overturn the
  case for the holder-draw design (ownership clocks stamped by the NFT instead of a holder snapshot loop).** See
  section 4 for how loudly that matters.

---

## 2. The gas-burner contract

### 2.1 What it does

It reads one 256-bit number `N` from the first 32 bytes of calldata (there is no function selector, calldata IS
the number) and runs a countdown loop `N` times. Each iteration is pure arithmetic. There is no `GAS` opcode, no
`gasleft()` check, no early return, no storage, and no memory: the contract has **no way to self-limit**. It
either completes exactly `N` iterations and halts, or it is killed mid-loop when the gas it was handed runs out.
That is precisely the property this test needs: the only thing that can stop it short of `N` is an external gas
ceiling.

### 2.2 Exact runtime bytecode (18 bytes)

```
0x6000355b8015601057600190036003565b00
```

### 2.3 Annotated disassembly

Verified with `cast disassemble` (Foundry 1.7.1). Calldata layout: bytes `[0,32)` = `N`, the iteration count.

```
pc  bytes   opcode         stack after            note
00  60 00   PUSH1 0x00     [0x00]
02  35      CALLDATALOAD   [N]                     N = calldata[0:32]
03  5b      JUMPDEST       [N]                     loop:  <- back-edge target, pc 0x03
04  80      DUP1           [N, N]
05  15      ISZERO         [N, N==0]
06  60 10   PUSH1 0x10     [N, N==0, 0x10]
08  57      JUMPI          [N]                     if N==0 jump to end (pc 0x10)
09  60 01   PUSH1 0x01     [N, 1]
0b  90      SWAP1          [1, N]
0c  03      SUB            [N-1]                   top - next = N - 1
0d  60 03   PUSH1 0x03     [N-1, 0x03]
0f  56      JUMP           [N-1]                   back to loop (pc 0x03)
10  5b      JUMPDEST       []                      end:
11  00      STOP           []                      halt, success
```

Readable equivalent:

```solidity
// Equivalent behavior. The shipped artifact is the hand-written bytecode above,
// not this Solidity (a compiler would add a selector dispatcher and bounds checks
// that this raw loop deliberately omits).
contract GasBurner {
    fallback() external {
        uint256 n;
        assembly { n := calldataload(0) }   // N = first word of calldata
        while (n != 0) {                     // no gas check anywhere in this loop
            unchecked { n -= 1; }
        }
        // falls off the end -> STOP, success
    }
}
```

### 2.4 Measured gas per iteration

The loop body executed each pass is `JUMPDEST(1) DUP1(3) ISZERO(3) PUSH1(3) JUMPI(10) PUSH1(3) SWAP1(3) SUB(3)
PUSH1(3) JUMP(8)` = **40 gas per iteration**, exactly. This was verified two ways on a local anvil (Foundry
1.7.1), by injecting the runtime and reading real receipt `gasUsed` values:

| N        | measured gasUsed | note                                    |
|----------|------------------|-----------------------------------------|
| 1,000    | 61,179           |                                         |
| 2,000    | 101,179          | delta 40,000 over 1,000 iters = 40/iter |
| 500,000  | 20,021,191       |                                         |
| 700,000  | 28,021,191       | delta 8,000,000 over 200,000 = 40/iter  |

The exact cost model (also verified) is:

```
gasUsed(N) = 21,000 (intrinsic) + calldata_cost + 27 (fixed exec: PUSH/CALLDATALOAD + exit iteration) + 40 * N
```

`calldata_cost` is just the standard 16-per-nonzero-byte, 4-per-zero-byte cost of the single 32-byte word.

### 2.5 Deploy (init) bytecode (30 bytes)

Standard copy-and-return preamble in front of the runtime:

```
0x6012600c60003960126000f36000355b8015601057600190036003565b00
```

Preamble disassembly: `PUSH1 0x12` (len 18), `PUSH1 0x0c` (offset 12), `PUSH1 0x00`, `CODECOPY`, `PUSH1 0x12`,
`PUSH1 0x00`, `RETURN`. Verified on anvil: deploying this init code returns runtime code exactly equal to
`0x6000355b8015601057600190036003565b00`, and the deploy itself costs **57,058 gas**.

### 2.6 Sizing the argument for this test

Target: honest demand comfortably above the 32M clamp and comfortably below the 40M requested limit. Chosen
`N = 950,000`:

```
gasUsed(950,000) = 21,000 + 164 + 27 + 40 * 950,000 = 38,021,191 gas
```

That is 19% above the 32,000,000 clamp (so a clamp cannot be mistaken for noise) and 5% below the 40,000,000
requested limit (so, absent a clamp, the work provably fits and the transaction succeeds). The 32-byte calldata
word for `N = 950,000` is:

```
0x00000000000000000000000000000000000000000000000000000000000e7ef0
```

**Local end-to-end proof of both outcomes** (anvil, real transactions, real receipts):

| run                              | gas-limit  | measured gasUsed | status        |
|----------------------------------|------------|------------------|---------------|
| N=950,000, unclamped             | 40,000,000 | 38,021,191       | 0x1 success   |
| N=950,000, capped at 32M (mimics ArbOS clamp) | 32,000,000 | 32,000,000       | 0x0 FAILED    |

The second row is the local stand-in for what ArbOS does on the real chain: hand the transaction only 32M, and
the 38M workload dies exactly at the ceiling with a failed status. The real testnet run below turns that
simulation into an on-chain fact.

---

## 3. The exact commands

Run these one at a time, in order. Each is copy-pasteable.

Environment:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
```

```bash
export RPC=https://rpc.testnet.chain.robinhood.com   # chainId 46630
```

Step 1: deploy the burner. Options come before `--create` (Foundry 1.7.1 argument ordering). Deploy is about
57k gas, far under the ceiling, so no explicit gas-limit is needed:

```bash
cast send --rpc-url "$RPC" --account deployer --create 0x6012600c60003960126000f36000355b8015601057600190036003565b00
```

Step 2: copy the `contractAddress` printed in that receipt into `BURNER`:

```bash
export BURNER=<paste the contractAddress from the deploy receipt>
```

Step 3 (optional pre-flight): confirm the burner behaves normally under the ceiling. This runs 1,000 iterations,
should succeed, and should report `gasUsed` = 61,179:

```bash
cast send "$BURNER" --data 0x00000000000000000000000000000000000000000000000000000000000003e8 --rpc-url "$RPC" --account deployer --gas-limit 100000
```

Step 4: the actual test. Demand 40,000,000 gas for a 38,021,191-gas workload. The explicit `--gas-limit` is
mandatory: without it, `cast` calls `eth_estimateGas` first, and estimation already applies the clamp, so it
would cap or error and you would never get a 40M request onto the wire. Passing `--gas-limit` skips estimation
and forces the 40M ask:

```bash
cast send "$BURNER" --data 0x00000000000000000000000000000000000000000000000000000000000e7ef0 --rpc-url "$RPC" --account deployer --gas-limit 40000000
```

If the transaction is mined-and-reverted, `cast` may print a "transaction reverted" line and exit non-zero. That
is not a mistake on your side, it is one of the expected outcomes. The transaction hash is printed regardless;
copy it for section 5.

---

## 4. What each outcome proves

**Outcome A: the transaction is rejected at submission and never mines.**
`cast` returns an RPC error and no transaction hash lands on chain. Expected error text is a submission-time gas
complaint from the sequencer, wording depends on the node build, plausible forms include:
`-32000: gas limit too high`, `intrinsic gas greater than provided`, or `tx gas limit 40000000 exceeds max ...`.
Any submission-time rejection that names the gas limit proves the cap is enforced at ingress. Clamp CONFIRMED.

**Outcome B (expected): the transaction mines, fails, and shows gasUsed near 32,000,000.**
`status` = 0 (failed), `gasUsed` approximately 32,000,000. ArbOS handed the execution only 32M gas even though
40M was requested and 38M was needed, so the loop ran out of gas partway and reverted. This is the clamp firing
in real block production. Clamp CONFIRMED. This is the result every prior line of evidence predicts.

**Outcome C (would REFUTE everything): the transaction mines, succeeds, and shows gasUsed near 38,021,191.**
`status` = 1 (success), `gasUsed` between roughly 38,000,000 and 38,050,000. This means the transaction was
granted more than 32,000,000 gas of execution in a mined block. If you see this, STOP. The 32,000,000 ceiling
does NOT apply to block production. Every downstream conclusion built on the 32M ceiling, including the
conclusion that a HolderDrawEngine snapshot loop bricks at mint velocity, and the design built on it, is then based on a
false premise and must be re-derived from scratch. Do not proceed with any launch decision that assumes the
ceiling until this is resolved. Say so loudly to the team.

---

## 5. Read the result afterward

Using the transaction hash from step 4:

```bash
cast receipt <TX_HASH> --rpc-url "$RPC"
```

Just the two fields that decide it:

```bash
cast receipt <TX_HASH> gasUsed --rpc-url "$RPC"
```

```bash
cast receipt <TX_HASH> status --rpc-url "$RPC"
```

Mapping observed `gasUsed` and `status` to the conclusion:

| observed gasUsed              | status        | conclusion                                                             |
|-------------------------------|---------------|------------------------------------------------------------------------|
| no receipt (rejected at send) | n/a           | Outcome A. Cap enforced at ingress. Clamp CONFIRMED.                    |
| approximately 32,000,000      | 0 (false)     | Outcome B. Clamp fired mid-execution. Clamp CONFIRMED. Expected.       |
| 38,000,000 to 38,050,000      | 1 (true)      | Outcome C. Full budget granted. Clamp REFUTED. Escalate immediately.   |
| between 32M and 38M           | 0 (false)     | Unexpected. Some other limit is biting. Investigate before concluding. |

---

## 6. Expected cost in testnet ETH

You pay for gas actually consumed, not for the requested limit, so a reverted 40M-request transaction that burns
32M costs 32M worth of gas, not 40M.

Live gas price at authoring, read with:

```bash
cast gas-price --rpc-url "$RPC"
```

returned **10,000,000 wei** (0.01 gwei). This price floats, re-check it before you run. Working at that price:

- Deploy: 57,058 gas x 10,000,000 wei = 570,580,000,000 wei = **0.00000057 ETH**.
- Burn, Outcome B (clamp holds, about 32,000,000 gas): 32,000,000 x 10,000,000 = 320,000,000,000,000 wei =
  **0.00032 ETH**.
- Burn, Outcome C (refuted, about 38,021,191 gas): 38,021,191 x 10,000,000 = 380,211,910,000,000 wei =
  **0.00038 ETH**.

Total, deploy plus the single burn, worst case (Outcome C, the most gas): 38,078,249 gas =
**about 0.00038 ETH**. If the price drifts back to the 0.0127 gwei seen in an earlier reading, the worst case is
about 0.00048 ETH. Budget **0.001 testnet ETH** and you are covered with wide margin, including the optional
pre-flight call.
