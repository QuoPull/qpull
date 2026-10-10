# QPULL Keeper

A small bot that sends QPULL's periodic transactions. The draws and conversion **do not run themselves**:
something has to send each transaction inside its window. This is that something.

Two programs live here:
- **`keeper.js`**: the mainnet keeper (and any chain running the real `BlsDrandOracle`). Everything below is
  about this file unless it says otherwise.
- **`keeper-testnet.js`**: the short-clock testnet keeper for a `MockDrandOracle` deploy. It has its own
  config template, `.env.testnet.example`, and refuses to run on Robinhood mainnet (see
  [keeper-testnet.js](#keeper-testnetjs)).

Both programs decode reverts through `reverts.js` (the known custom errors and the convert floor classification).
Both import it at startup, so a copy of this folder without `reverts.js` crashes before any code runs
(`ERR_MODULE_NOT_FOUND`), and under a process manager that is a keeper that is down. Keep it next to `keeper.js` in
every copy, and give a symlinked harness folder a link for it too.

## Keys: two, and both are hot

An autonomous keeper signs unattended every tick, so its private key lives on the server. That is what
"hot" means, and no amount of care changes it. A hardware wallet or multisig needs a human per signature,
which is the opposite of autonomous. So do NOT plan to make the keeper cold. Plan to give it nothing worth
stealing.

Of everything this keeper calls, exactly ONE is privileged:

| call | gated |
|---|---|
| `submitBeacon` | no, anyone |
| `registerSuperRare` | no, anyone |
| `runDraw` (raffle + holder) | no, anyone |
| `distribute` | no, anyone |
| `runOpeningDraw` | no, anyone |
| `sweepExpired` | no, anyone |
| **`Treasury.convert`** | **yes, `onlyKeeper`** |

So run two keys:

- **`KEEPER_PK`, the draw key.** Registered NOWHERE. Online every tick. Holds only gas. If it is stolen the
  attacker gains nothing: every call it makes is already permissionless to any address on the chain.
- **`CONVERT_PK`, the convert key.** The ONLY address passed to `Treasury.setKeeper`, and the only key that
  signs `convert()`. `setKeeper` stays rotatable even after `lockRouting`, so it can be revoked and replaced.
  Nothing on-chain binds the role to this key, so the keeper checks it itself (read-only): at startup it reads
  `Treasury.isKeeper(<convert key>)`, `isKeeper(<draw key>)` and `keeperCount()`, and before every convert it
  re-reads `isKeeper`. A convert key without the role logs `FATAL CONFIG` with the exact `setKeeper` call.

`CONVERT_PK` is optional. Unset, convert signs with the draw key, and the keeper says at startup that the key
online every 60 seconds then also holds the only privilege in the system. Set to the same key as `KEEPER_PK`, it is
the same case: the keeper says the privilege split is not in effect, and both jobs sign through one nonce counter
(the keeper matches the two keys by address), so their transactions do not collide.

**What a stolen convert key can do:** call `convert()` with a chosen `minOut` and sandwich the swap. Bounded
per call by `maxConvertPerCall` / `maxWethConvertPerCall`, and revocable via `setKeeper`. That is all it can
do, and it is why the split is worth the second wallet.

**Both keys are watched for gas.** Every `HEALTH_INTERVAL_S` (default 300 s) the keeper reads each watched
signer's native-ETH balance and logs `*** LOW BALANCE` at ERROR level (repeated hourly) below its floor:
`KEEPER_GAS_FLOOR_WEI` (default 0.02 ETH) for the draw key, always, and `CONVERT_GAS_FLOOR_WEI` (default 0.005 ETH)
for the convert key whenever convert is enabled (`ENABLE_CONVERT=true`, and also `simulate`, which sends nothing
but is the step before `true`, so an unfunded convert key shows up first). With `ENABLE_CONVERT=false`, or under
`--failsafe`, the convert key is not watched. Top-ups are manual: the team + operations share of every convert
arrives as WETH at the Treasury's `team` recipient (in the intended setup a warm operations wallet, which pays for
the keeper and moves the team's own share on to a separate cold wallet), so unwrap some with `WETH.withdraw` and
send native ETH to whichever key is low.

**A malformed key never reaches the log.** `KEEPER_PK` / `CONVERT_PK` must be 64 hex digits, optionally
`0x`-prefixed. Anything else exits `FATAL CONFIG` naming the variable and its length, never its value.

## What it does each tick
In this order (`tick()` in `keeper.js`):
1. **Health watch** (every `HEALTH_INTERVAL_S`): the watched signers' balances, and an info line when the host
   clock is more than `CLOCK_SKEW_WARN_S` (default 60 s) behind or ahead of the chain's latest block. Then every
   transaction that timed out on an earlier tick is re-checked (reads only, and only when one exists; see guarantee
   4 below), so a job's record is dropped even when that job is not attempted again.
2. **Voided-period alarm**: reports any period whose settlement window closed unpaid. It runs before every job
   that moves a vault (the settlements drain it, convert fills it, the claim sweep frees reserve), so a period
   whose window just closed is judged on the vault as that window left it.
3. **`packRegistry.registerSuperRare`**: builds the Super Rare daily auto-entry index once the collection
   reveals (see [Super Rare index](#super-rare-index-registersuperrare)). **Mandatory.**
4. **Cohort reveal beacons**: posts each pack cohort's reveal round as soon as drand publishes it, whether or
   not the opening draw has run. Ripping a pack, rip XP and every draw that sweeps the cohort need it.
5. **`raffle.runOpeningDraw(false)`** once, then the daily **`raffle.runDraw`**: each fired only once every
   beacon the draw consumes is on-chain (see [Beacons](#beacons-drand-bls)). If the engine still reverts
   `RevealPending(cohortDay, revealRound)`, the keeper posts that round and retries on the next tick. The opening
   never forgoes: an underfunded opening waits and says "fund the prize vault".
6. **`leaderboard.distribute`**: pays out the closed week's leaderboard.
7. **`holder.runDraw`**: the weekly holder draw, after posting its draw beacon.
8. **`podStaking.pokeMany`** *(QuoPods; skipped entirely until `POD_STAKING` and `POD_MINT` are set)*: every
   `POD_POKE_INTERVAL_S` (default 4 h) it re-settles all minted pods in batches of `POD_POKE_BATCH`
   (default 50). A pod's tier is read live at settlement and then held, so between settlements it earns at a
   stale weight. Stale-low self-corrects because the owner wants it fixed; **stale-high does not** - sell the
   NFTs that set your tier, never touch the pod, and it keeps paying at the old one, because `_settle` banks
   the interval at the OLD weight before re-reading. `poke` is permissionless so anyone *could* correct it,
   but the corrector pays a whole transaction to capture about a five-hundredth of the benefit, which is a
   free-rider problem rather than an incentive. **`POD_POKE_INTERVAL_S` is therefore a risk setting, not a
   performance one**: it is exactly the window a pod can earn at an inflated weight. Permissionless, so
   failsafe runs it too. Each batch is isolated; one failure is logged and the sweep continues.
   **`podLock.collectFees`** *(QuoPods; skipped until `POD_LOCK` is set and the lock is seeded)*: every
   `POD_FEE_INTERVAL_S` (default 6 h) it collects the locked pool's 0.3% swap fee. The WETH half streams to
   staked pods through `QuoPodStaking.fundRevenue`, the QPOD half is burned. Permissionless and idempotent,
   so failsafe runs it too; skipping it only delays the payout, the fees wait credited to the position.
9. **`treasury.convert`** *(primary keeper only, opt-in)*: converts accumulated tax into prizes. **Off by
   default**, see [Convert](#convert).
10. **`claimManager.sweepExpired`** (every `SWEEP_INTERVAL_S`, default hourly): returns expired, unclaimed
   prizes to the pots. Without it every pot shrinks permanently.
11. **Heartbeat** (every `HEALTH_INTERVAL_S`, default 300 s): once every job above has run, one `heartbeat:` info
   line with the tick's duration and the transactions sent, confirmed, failed, not confirmed in time and replaced
   since the previous heartbeat, plus every job still holding behind a timed-out transaction that is pending. A
   tick that never finishes writes none (see [Monitoring](#monitoring)).

A draw that would take a no-pay branch (empty vault, pot below `minPot`, nothing seated) simulates cleanly, so
the keeper detects it from the outcome (the period's flag did not flip) and backs off exponentially
(`NOOP_BACKOFF_BASE_S`, `NOOP_BACKOFF_MAX_S`) instead of re-sending every tick.

## What it guarantees, and what it does not
1. **Simulate, then send.** Every transaction is `staticCall`-simulated first. A simulated revert means "not
   callable now" and is skipped (its reason is logged by name when it changes), and the next tick simulates
   again. A transport failure (HTTP error, timeout) or a method missing from an ABI is an error and is logged.
   **Limit:** a JSON-RPC error returned for the `eth_call` itself (a rate limit, "header not found") cannot be
   told apart from a revert without data, because ethers reports both as `CALL_EXCEPTION`. A simulation that
   passes can still fail on-chain if state moves before the transaction lands; that costs gas. If state moves
   before the transaction is even built, its gas estimate reverts and nothing is sent: `send FAILED` names the
   decoded error (for example `OutsideWindow` for a draw whose window just closed).
2. **No draw before its beacons.** A raffle draw pops winners and resolves each winner's tier from its cohort's
   reveal beacon. The engine now refuses to pop anything while a cohort in the draw's window that has live packs
   has no reveal on the oracle: `runDraw` and `runOpeningDraw` revert `RevealPending(cohortDay, revealRound)` and
   latch nothing (`PackRegistry._drawCore`), for every caller. The keeper still posts first: it fires only
   once the reveal round of every such cohort and the draw round are on-chain, and says why it is holding. (A
   closed cohort with no live packs is skipped, exactly as the engine skips it.) Posting first matters because
   a daily draw can only settle during the following day. If a simulation reverts `RevealPending` anyway (an RPC
   node behind the one that saw the beacon), the keeper posts **the round the engine named** and retries on the
   next tick, at info level. It is ERROR only when the engine names a round the keeper derives differently for
   that cohort, or keeps naming a round this RPC reads as posted for 3 ticks in a row. A tick on which that draw
   is not simulated (a beacon missing as this RPC reads it, the day already settled, an underfunded opening, a
   read before the simulation that failed) ends the streak, so RevealPending on non-consecutive ticks never adds
   up to the ERROR. A transport error thrown by the draw simulation itself neither counts toward the streak nor
   ends it. Because a tick that is not simulated resets the count, an intermittently lagging load-balanced RPC
   shows up as alternating `waiting for drand` and `RevealPending` info lines (and beacon send failures), not as
   this ERROR.
3. **A missed window is a real loss.** If no one settles a period inside its window, the pot rolls forward,
   but that period's participants are never paid. The keeper logs `PERIOD VOIDED` for a period that could have
   paid. A raffle day or holder/leaderboard week that closed below `minPot` (the raffle: its pot, a share of the
   vault capped at `potCapAt`, below `minPotAt` or too small for the day's winners; the holder draw: also nobody
   seated) gets a quieter `closed unpaid with nothing payable` line instead. These verdicts read the vault at
   check time, which is right after the window closes and before anything in that tick moves the vault.
   **After a restart** the keeper cannot know what a vault held in a window that closed while it was not
   running, so for those periods it never claims `PERIOD VOIDED` (or "not a keeper fault"): raffle days and
   holder and leaderboard weeks the vault could pay NOW are listed once per engine in a `closed UNSETTLED before
   this keeper started watching` ERROR line, with how to tell a void from a no-pay period from the engine's
   events. **Limits:** that line is printed again after every restart for the same periods (up to
   `VOID_BACKSCAN` back), because the keeper keeps no state on disk; and the verdicts do not read events or
   historical state (the Robinhood RPC's `eth_getLogs` range limit and archive `eth_call` support are
   unverified). A raffle window that held only free entries (Super Rare autos, pledges) and no paid packs reads
   as empty and is not alarmed.
   Run it under a supervisor, and run a `--failsafe` copy elsewhere (see [Run](#run)).
4. **Nothing stalls silently.** Convert failures, a convert that cannot be priced or keeps holding, no
   successful convert for `CONVERT_STALL_ALARM_H` (default 6) hours while tax is pending, convert caps that cannot
   be read or are still unarmed after go-live, low gas on a watched key, and an unusable oracle are all logged at
   ERROR level and repeated while they hold, each on its own cadence (see [Alarms](#alarms)). A sent transaction
   is waited on for at most `SEND_WAIT_TIMEOUT_MS` (default 120 s): one the RPC acknowledged but never included is
   an ERROR naming its hash and nonce, and the signer's nonce is re-read from the chain, so a dropped transaction no
   longer freezes every later job. A timeout cannot tell a slow transaction from a dropped one, so the keeper
   remembers it: that job sends nothing while the transaction is still pending (one `NOT sent again` line, and the
   heartbeat lists it while it holds), and simulates again once it lands, its nonce is used, or the RPC no longer
   has it and nothing is pending at its nonce. **Limit:** a transaction that lands late after the RPC stopped
   reporting it (a load-balanced RPC answering from a node that never saw it) can still make one duplicate of that
   call revert on chain, which costs gas and nothing else. A transaction replaced at its nonce by another sender on
   the same key is logged as `was REPLACED`, never as reverted. The keeper cannot alarm when its own
   process is down or stuck: alert on the missing `heartbeat:` line (see [Monitoring](#monitoring)).

## Setup
```bash
cd keeper
npm install
cp .env.example .env      # then fill RPC_URL, KEEPER_PK, CONVERT_PK and the contract addresses
```

Fund both keys with a little gas (above their floors). Keep the balances **modest**: they are hot wallets.

### Configuration read from the chain
The keeper does not trust `.env` for anything the contracts already know:
- **The clock.** `genesis`, `dayLength` and `revealDelay` (plus `LIFE_DAYS` and `RIP_XP_WINDOW`) are read from
  `PACK_REGISTRY`, and `RAFFLE_ENGINE.packs()` must equal `PACK_REGISTRY`. `PACK_REGISTRY` is required.
- **The oracle.** Read from `drand()` on every configured `RAFFLE_ENGINE`, `PACK_REGISTRY`, `HOLDER_ENGINE` and
  `NFT_COLLECTION`; they must all agree. Its interface is detected from its bytecode: `BlsDrandOracle` on any
  chain, a `MockDrandOracle` on testnets only. On Robinhood mainnet (chainId 4663) anything but a
  `BlsDrandOracle` is refused and alarmed every tick.
- **Convert.** The QPULL and WETH tokens and both swap adapters come from the `TREASURY` (`qpull()`, `weth()`,
  `qpullWeth()`, `wethQuotron()`). The QPULL/WETH pool key is read verbatim from `QpullWethAdapter.poolKey()` and
  checked against its hook (the hook must serve that key, run on the adapter's PoolManager and exempt that
  adapter). The sell-tax schedule and `launchTime` come from that hook.

`GENESIS`, `REVEAL_DELAY`, `DAY_LENGTH` and `ORACLE` are **not settings for `keeper.js`**. If you set one, it is
an assertion: the keeper exits `FATAL CONFIG` at startup when it disagrees with the chain. `QPULL`, `WETH` and
`WETH_QUOTRON_ADAPTER` are assertions too, but a disagreement disables ALL converts (a `FATAL CONFIG` line
repeated while it holds) rather than exiting, so the draws keep running. `QPULL_POOL_FEE`,
`QPULL_POOL_TICK_SPACING` and `QPULL_POOL_HOOK` describe only the QPULL/WETH pool, which only the donated-QPULL
leg uses: a disagreement (or an inconsistent pool binding) disables that leg alone, with a repeated
`CONFIG: the QPULL/WETH pool binding is wrong` ERROR, and WETH-only sweeps continue. The hook was re-mined when
it moved to taking every tax in WETH, so a `QPULL_POOL_HOOK` carried over from an older `.env` is exactly this
case: remove it. A key present but blank
(`QPULL_POOL_FEE=`) is treated as unset, never as 0.
**Exception:** `keeper-testnet.js` has no other source for the oracle and REQUIRES `ORACLE`; if one `.env` serves
both programs on a testnet, keep `ORACLE` set to the address the contracts read.

`.env` is read from this directory (next to `keeper.js`), not from the working directory, so a supervisor or a
shell started anywhere loads the same file. `DOTENV_CONFIG_PATH` overrides the path explicitly.

Every numeric knob read by `keeper.js` (including `DRAND_TIMEOUT_MS`) is validated at startup; a malformed or
out-of-range value exits `FATAL CONFIG` naming it. So does a malformed address in `TREASURY`, `RAFFLE_ENGINE`,
`LEADERBOARD_ENGINE`, `HOLDER_ENGINE`, `PACK_REGISTRY`, `NFT_COLLECTION`, `CLAIM_MANAGER`, `MULTICALL3`,
`VIEW_QUOTER` or `QPULL_QUOTER`, an `ENABLE_CONVERT` other than `true`/`false`/`simulate`, an `ENABLE_SWEEP` other
than `true`/`false`, and a `CONVERT_SPOT_UNAVAILABLE` other than `hold`/`proceed`. So do two combinations: `CONVERT_PRICE_MIN_SAMPLES` above
`CONVERT_PRICE_WINDOW`, and an explicit `CONVERT_PRICE_MAX_AGE_S` too short for the tick interval (see
[Convert](#convert)). The `QPULL_POOL_*` assertions are checked when convert first reads the pool. A read that
fails at startup (a rate limit, a 5xx) is retried with backoff for up to `STARTUP_RETRY_S` (default 600 s) before
the keeper gives up, so a transient RPC error does not trip the supervisor's restart limit.

### Authorize the convert key (only needed for convert)
The **draws are permissionless**: anyone (including this bot) can call them, no authorization needed.
`Treasury.convert()` is **keeper-gated**, so if you enable convert, the owner must authorize the **convert
key** (`CONVERT_PK`'s address, or `KEEPER_PK`'s if `CONVERT_PK` is unset), and nothing else:
```
Treasury.setKeeper(<CONVERT_PK address>, true)
```
The keeper verifies this at startup and before every convert, and names the fix if it is missing. The go-live
scripts enforce the same thing on their side: `script/GoLiveMainnet.s.sol` and `script/TransferOwnership.s.sol`
read the convert key's address from their `KEEPER` env variable and refuse to run unless `Treasury.isKeeper(KEEPER)`
holds (GoLiveMainnet also requires `keeperCount() == 1` and `KEEPER` not the deployer; TransferOwnership also
requires the deployer to no longer be a keeper). So `KEEPER` there is the `CONVERT_PK` address, never `KEEPER_PK`'s.

## Run
Run the loop as a long-lived process under a supervisor that restarts it (systemd `Restart=always`, pm2,
docker `restart: always`):
```bash
npm start                     # node keeper.js: the loop, every INTERVAL_SECONDS
node keeper.js --failsafe     # permissionless jobs only (no convert); run a second copy on another machine
```
Loading `keeper.js` starts the keeper however it is launched: `node keeper.js`, `node keeper`, `npm start`,
or a supervisor that loads it through its own wrapper, such as pm2 (`pm2 start keeper.js`). It logs
`QPULL keeper online` at startup; if that line never appears, it is not running. The one exception is
`KEEPER_IMPORT_ONLY=1` in the process environment, which only offline tests set: the file then loads as a
library and runs nothing. Never set it for a real run. If it is inherited, the keeper prints
`KEEPER_IMPORT_ONLY=1, loaded as a library; the keeper is NOT running` on stderr instead of starting. A test
harness must set `process.env.KEEPER_IMPORT_ONLY = "1"` in its own process before importing: `keeper.js` loads
`keeper/.env` itself, so a harness that only checks its own environment for keys would still start the keeper.

**`--failsafe`** runs every permissionless job and skips convert, so any key with gas can run it, on another
machine, alongside the primary. It asks the drand relays in the reverse order and watches only its own key.
It does not fund the prize vaults: it buys time during a primary outage, it does not replace the primary.

The keeper keeps state in memory between ticks that makes it cheap and quiet: the no-op draw backoff, the
Super Rare scan, the expired-claim cursor, the spot-price history and the alarms it has already raised.

**Do not schedule `--once` (`npm run once`) from cron or a timer.** `node keeper.js --once` is a single manual
pass for a human to watch. It starts with none of that state and takes no lock, so scheduled every minute it
re-sends no-op draw transactions on every run (real gas), lets overlapping runs race one nonce, and repeats
every alarm. **It is not a dry run:** it sends real beacon and draw transactions. It **never** sends
`convert()`, whatever `ENABLE_CONVERT`, `VIEW_QUOTER`, `CONVERT_SPOT_UNAVAILABLE` or the spot guard say: with
`ENABLE_CONVERT=true` it derives the floors and simulates `convert()` exactly as `ENABLE_CONVERT=simulate` does,
logs `convert [--once]: floors ... convert() simulation SUCCEEDS|REVERTS ...; spot guard ...` and ends with
`Nothing sent (--once never sends convert(); run the loop to send)`. So no `--once` run can ever end in
`treasury.convert: sent ... confirmed`. (Earlier versions could: with `VIEW_QUOTER` unset, or the guard disabled,
they sent on bisection floors.) The convert dry run is `ENABLE_CONVERT=simulate` (below); to send, run the loop.

## Convert
`Treasury.convert(minWethOut, minQuotronOut)` swaps accumulated tax and splits it: 20% team + operations as
WETH, 80% bought as QUOTRON for the three prize vaults. It is **slippage-sensitive**: it is keeper-gated
precisely because a loose `minOut` lets a sandwich bot drain the batch, so the keeper passes tight,
freshly-derived floors, and passes none at all when it cannot derive one.

**Where tax comes from.** The hook takes every tax in **WETH**, on buys and sells alike. So the normal convert
is a **WETH-only sweep**: the QPULL leg is skipped, `minWethOut` is ignored by the contract, and only the
WETH to QUOTRON leg needs a floor, from Quotron's View quoter (`VIEW_QUOTER`). The QPULL to WETH leg runs only
when someone has **donated QPULL** to the Treasury at or above `convertThreshold`.

**Modes** (`ENABLE_CONVERT`):
- `false` (default): no convert. With the Treasury caps armed (go-live ran) this logs `MISCONFIGURED` at ERROR
  level every tick, because tax is then accruing with nothing converting it.
- `simulate`: every tick, derive the floors, apply every guard, and simulate `convert()` from the convert key;
  log the floors and whether the simulation succeeds or reverts (by name). Sends nothing. Use it at go-live.
- `true`: the same, then send (in the loop only: `--once` never sends, see [Run](#run)).

To enable at go-live: arm the caps (GoLive step 1), authorize the convert key, set `VIEW_QUOTER`, run with
`ENABLE_CONVERT=simulate` until the log shows `convert [simulate]: ... simulation SUCCEEDS; spot guard clear`, then
set `true`. The guard needs `CONVERT_PRICE_MIN_SAMPLES` ticks of history, so the first simulate lines say
`HOLDING (... collecting history ...)` alongside a successful simulation; wait for `clear`.

**Fail closed, by the owner's choice.** With the spot guard on (the default) and `CONVERT_SPOT_UNAVAILABLE=hold` (the
default), a convert whose Quotron price check is unavailable does not send: `VIEW_QUOTER` not set is an immediate,
repeated `HOLDING, not sent: the WETH->QUOTRON price check is unavailable` ERROR (and a startup ERROR), and a
`VIEW_QUOTER` whose reference quote fails holds and escalates to ERROR after `CONVERT_FAIL_ALARM` ticks. A
configured `QPULL_QUOTER` holds a convert that needs the donated-QPULL leg whenever it gives no reference quote,
whatever the cause:
- its quote call fails, the QPULL/WETH pool binding cannot be read, or the pool is not bound or initialized yet
  (each can clear by itself): `HOLDING, not sent: the QPULL->WETH reference quote failed at this block`, ERROR
  after `CONVERT_FAIL_ALARM` ticks in a row;
- it quotes on a different PoolManager than the adapter, or the pool binding is wrong (see [Configuration read from
  the chain](#configuration-read-from-the-chain)); neither clears by itself: `HOLDING, not sent: the QPULL->WETH
  price check is unavailable although QPULL_QUOTER is configured`, ERROR at once, repeated every `ALARM_REPEAT_S`.

These holds are checked only for a convert that needs the donated-QPULL leg. While no QPULL at or above
`convertThreshold` sits in the Treasury, a `QPULL_QUOTER` on the wrong PoolManager logs nothing (a wrong pool
binding still logs its own `CONFIG` ERROR every tick), WETH-only sweeps keep sending, and `ENABLE_CONVERT=simulate`
still reports `spot guard clear`. The first sign is then the hold above, on the tick after someone donates QPULL.
So when you configure `QPULL_QUOTER`, confirm `QPULL_QUOTER.poolManager()` equals the adapter's PoolManager.

While such a hold lasts, `convert()` must sell the donated QPULL first, so nothing converts until the cause is
fixed or the WETH backlog reaches `maxWethConvertPerCall` (the Treasury then skips the QPULL leg). The donated-QPULL
leg runs WITHOUT a price check under `hold` in exactly one case: no `QPULL_QUOTER` configured at all (that quoter
is optional). Its floor then comes from bisection, and the hourly `spot guard is NOT in force` info line says so.
Unsetting a broken `QPULL_QUOTER` therefore trades the hold for that unguarded case. Every other path to a floor
fails closed: no floor, no send.
`CONVERT_SPOT_UNAVAILABLE=proceed` (or `CONVERT_PRICE_DEVIATION_BPS=0`, which disables the guard) is the explicit
opt-out.

**How the floors are derived**, each with `CONVERT_SLIPPAGE_BPS` (default 1%) of slippage:
- **Leg 2 (WETH to QUOTRON)** from `VIEW_QUOTER`, quoted as the Treasury's `wethQuotron()` adapter (the router's
  fee is per payer), on the exact prize split the Treasury will swap. The WETH it is sized from includes the
  leg-1 output at its FLOOR, not at its quote.
- **Leg 1 (QPULL to WETH)**, donated QPULL only, from `QPULL_QUOTER` (optional; `script/DeployQuoter.s.sol`
  deploys one) on the pool key read from the adapter. The quoter prices a TAXED sell, but `convert()` sells
  through the tax-exempt adapter, so the quote is grossed up by the hook's sell tax at the quote block, exactly:
  the rate is computed from the hook's own `launchTime`, `SELL_STEP()` and `SELL_DECAY()` at that block's
  timestamp, and the gross-up returns the smallest untaxed output consistent with the hook's floor rounding,
  so the floor never exceeds what the exempt sell yields. A quoter on a different PoolManager than the adapter
  is refused.
- **Bisection fallback.** When a leg runs and its quoter is missing or failing (and the spot guard allows it, see
  above: with a configured quoter that means the guard's reference quote succeeded and only the quote at the
  slice's size did not), that leg's floor is found by simulating `convert()` with a range of floors (tens of
  `eth_call`s, about 0.5% precision), every one pinned to the block the spot guard checked, so the floor comes from
  the pool state the guard vetted and not from whatever the pool shows during the search. It never runs for a
  deliberate skip: below the WETH dust floor or with nothing to convert. A quoted convert whose simulation reverts
  on a floor is logged by name and retried once with bisection floors, at a fresh block that the spot guard checks
  again first.
  Only a floor revert means "too high": `SwapShortfall`, `Slippage`, and `SlippageExceeded()` (`0x8199f5f3`, which
  Quotron's router raises before the adapter's own check). Any other answer (an RPC error, a revert without data,
  which is also how ethers reports a JSON-RPC error such as a rate limit, or an error the keeper cannot name) is
  re-probed once; a second such answer ABORTS the bisection: no floor, no convert, a `convert() did not go
  through` failure that escalates like any other. (Reading it as "too high" would have LOOSENED the floor.) A
  bisection failure is blamed on the QPULL leg (`BLOCKED BY THE QPULL LEG`) only for a dust floor or a revert that
  only that leg can raise.
- **WETH dust floor.** A WETH-only sweep is skipped while the Treasury's WETH is below
  `min(MIN_WETH_CONVERT_WEI, maxWethConvertPerCall)` (default `MIN_WETH_CONVERT_WEI` 0.01 WETH): not worth its gas.
  **Keep `MIN_WETH_CONVERT_WEI` at or below the Treasury's `maxWethConvertPerCall`.** The cap is sized to the
  shallow QUOTRON pool, so it may well be smaller than 0.01 WETH. If it is, the keeper uses the cap as its dust
  floor (a full slice is never dust, so convert keeps running) and logs an hourly ERROR,
  `maxWethConvertPerCall ... is BELOW MIN_WETH_CONVERT_WEI`, until you lower `MIN_WETH_CONVERT_WEI`.
- **Spot guard.** Both methods price off the pool state at the read, so a price pushed down just before the read
  lowers the floor with it. Each tick the keeper takes a fixed-size reference quote per leg
  (`CONVERT_PRICE_REF_WETH_WEI`, `CONVERT_PRICE_REF_QPULL_WEI`) and holds the convert while the current reference
  price is more than `CONVERT_PRICE_DEVIATION_BPS` (default 500) below the median of the last
  `CONVERT_PRICE_WINDOW` ticks (default 15). `0` disables the guard.
  - *Warm-up.* It needs `CONVERT_PRICE_MIN_SAMPLES` (default 5) earlier ticks, each younger than
    `CONVERT_PRICE_MAX_AGE_S`, so the first convert after a restart waits that many ticks. Unset,
    `CONVERT_PRICE_MAX_AGE_S` is `max(1800, 2 x INTERVAL_SECONDS x CONVERT_PRICE_MIN_SAMPLES)`, so a slow
    `INTERVAL_SECONDS` still warms up; set explicitly below that, the keeper exits `FATAL CONFIG` (the guard would
    otherwise never warm up and convert would never send). `ENABLE_CONVERT=simulate` reports the floors and the
    simulation while the guard warms, with the hold alongside.
  - *Its own price impact.* Right after a convert lands, the keeper re-quotes the reference for each leg that ran.
    If its own swap moved that price by more than `CONVERT_PRICE_DEVIATION_BPS`, the leg's history restarts from
    the post-convert price, so the next convert waits `CONVERT_PRICE_MIN_SAMPLES - 1` more ticks instead of
    holding as "manipulation" until the median catches up. So a `maxWethConvertPerCall` slice that moves the
    QUOTRON price more than the deviation limit caps throughput at about one convert per
    `CONVERT_PRICE_MIN_SAMPLES` ticks; a slice that moves it less does not throttle at all. That is one more
    reason to size the cap well inside the pool's depth.
  - *An unavailable reference quote* fails closed under `CONVERT_SPOT_UNAVAILABLE=hold` (the default), as
    described under **Fail closed** above: `VIEW_QUOTER` unset HOLDS every convert with an immediate ERROR, and a
    configured quoter (`VIEW_QUOTER`, or `QPULL_QUOTER` for the QPULL leg) whose quote fails this tick HOLDS too,
    escalating to ERROR after `CONVERT_FAIL_ALARM` ticks in a row: otherwise whoever can make that quote revert
    removes both the quoted floor and the guard in the same tick. A configured `QPULL_QUOTER` that cannot give a
    reference for a reason that does not clear by itself (a quoter on another PoolManager, a wrong pool binding)
    HOLDS with an immediate ERROR. The QPULL leg with no `QPULL_QUOTER` configured is not guarded, and the keeper
    says so hourly. `CONVERT_SPOT_UNAVAILABLE=proceed` converts on floors from the pool state alone (bisection when
    the quoter is unset or broken) without the guard.
  - *What it does not cover.* The guard compares against earlier ticks' prices, so a price held down for longer
    than the median window (`CONVERT_PRICE_WINDOW` ticks) becomes the median. A bisected floor is derived at the
    block the guard checked, but it is not cross-checked against the reference price itself (a large slice's own
    price impact would trip such a check). The per-call caps remain the real bound; the Treasury NatSpec note
    beside `setMaxConvertPerCall` belongs to the contracts.
- **Pool sizing is still the real bound.** Keep `maxWethConvertPerCall` (and `maxConvertPerCall`) small relative
  to pool depth: a floor only limits how much one sandwich can take from one call.

**Convert alarms you may see:**
- `BLOCKED BY THE QPULL LEG`: QPULL at or above `convertThreshold` sits in the Treasury, so `convert()` must
  sell it first, and that sale cannot be priced or run. When the QPULL is dust (it quotes 0 WETH) this is the
  **dust-QPULL grief**: until it clears, `convert()` only runs when the WETH backlog reaches
  `maxWethConvertPerCall`. Owner fix: `Treasury.setConvertThreshold` above the stranded balance (at least 1e18).
  A `convertThreshold` of 0 is warned about at the first convert.
- `convert() did not go through: <reason>`: decoded by name (`NotKeeper`, `NotConfigured`, `SwapShortfall`,
  `Slippage`, hook errors such as `PartialFill`, `SwapTooLarge` and `RecordOutOfGas`, unwrapped from the
  PoolManager's `WrappedError`). Escalates after `CONVERT_FAIL_ALARM` (default 3) failures in a row.
- `HOLDING, not sent: the WETH->QUOTRON price check is unavailable: VIEW_QUOTER is not set`: fail closed (see
  above). Set `VIEW_QUOTER`.
- `HOLDING, not sent: the QPULL->WETH price check is unavailable although QPULL_QUOTER is configured`: fail closed
  (see above). The line names the cause; the usual one is a `QPULL_QUOTER` deployed on a different PoolManager than
  the adapter.
- `NO SUCCESSFUL CONVERT for Nh while tax is pending`: after `CONVERT_STALL_ALARM_H` hours.
- `CONFIG: the QPULL/WETH pool binding is wrong`: the QPULL leg is disabled; WETH-only sweeps continue.
- `caps NOT ARMED ... although the QPULL/WETH pool is LIVE`: go-live ran (the hook's `launchTime` is set) but the
  Treasury caps are still 0, so `convert()` reverts `NotConfigured`. Before go-live the same condition is an
  hourly info line.
- `the Treasury convert caps could not be read for N ticks in a row`: a wrong `TREASURY` or an RPC that refuses
  block-pinned `eth_call`.

## Alarms
The standing alarms repeat while they hold, each on its own cadence:

| Alarm (log text) | Level | Repeats |
|---|---|---|
| `FATAL: oracle ... is unusable` | ERROR | every tick |
| `MISCONFIGURED` (caps armed, `ENABLE_CONVERT=false`) | ERROR | every tick |
| `HOLDING, not fired` (a draw's beacon could not be posted) | ERROR | every tick |
| `convert() did not go through` | ERROR | every failed attempt |
| `did NOT confirm within SEND_WAIT_TIMEOUT_MS` (a sent transaction with no receipt: hash, nonce, sender) | ERROR | every timed-out send |
| `REVERTED on chain` (a sent transaction mined as a revert), `send FAILED` | ERROR | every failed send |
| `was REPLACED (replaced\|repriced\|cancelled) by 0x...` (another sender on the same key took the nonce: a second keeper process or a manual send) | ERROR | every replaced send |
| `NOT sent again: transaction ... is still pending` (a job holding behind its own timed-out transaction) | info | once per timed-out transaction; the `heartbeat:` line lists it while it holds |
| `landed late in block N and succeeded\|REVERTED`, `it was dropped`, `never landed: nonce N is used` (a timed-out transaction resolved) | info | once per timed-out transaction |
| `FATAL CONFIG: convert() reverts NotKeeper` | ERROR | every 10 minutes |
| `LOW BALANCE` | ERROR | hourly (checked every `HEALTH_INTERVAL_S`) |
| `NO SUCCESSFUL CONVERT` | ERROR | hourly |
| `maxWethConvertPerCall ... is BELOW MIN_WETH_CONVERT_WEI` | ERROR | hourly |
| `FATAL CONFIG (convert disabled until fixed)` | ERROR | `ALARM_REPEAT_S` (default 900 s) |
| `CONFIG: the QPULL/WETH pool binding is wrong` | ERROR | `ALARM_REPEAT_S` |
| `BLOCKED BY THE QPULL LEG` | ERROR | `ALARM_REPEAT_S` |
| `caps NOT ARMED ... although the QPULL/WETH pool is LIVE` | ERROR | `ALARM_REPEAT_S` |
| `the Treasury convert caps could not be read for N ticks` | ERROR | `ALARM_REPEAT_S` |
| `HOLDING, not sent: ... reference quote failed ... ticks in a row` | ERROR | `ALARM_REPEAT_S` |
| `HOLDING, not sent: the WETH->QUOTRON price check is unavailable: VIEW_QUOTER is not set` | ERROR | `ALARM_REPEAT_S` (and once at startup) |
| `HOLDING, not sent: the QPULL->WETH price check is unavailable although QPULL_QUOTER is configured` | ERROR | `ALARM_REPEAT_S` |
| `the engine's RevealPending names round ... but this keeper derives round ...` | ERROR | `ALARM_REPEAT_S` |
| `reverted RevealPending(...) for N ticks in a row while this RPC reads that round as on-chain` (N = 3 consecutive ticks) | ERROR | `ALARM_REPEAT_S` |
| `PERIOD VOIDED`, `closed UNSETTLED before this keeper started watching` | ERROR | once per period per process (the UNSETTLED line again after each restart) |
| `HOLDING, not sent` (spot guard warming or price deviation) | info | every 10 minutes |
| `not fired this tick: the engine reverted RevealPending(...)` | info | when its round or post status changes, else every 10 minutes |
| `host clock: ...s BEHIND` / `host clock: ...s AHEAD of the chain's latest block` | info | hourly (checked every `HEALTH_INTERVAL_S`) |
| `heartbeat:` (not an alarm: its ABSENCE is, see [Monitoring](#monitoring)) | info | every `HEALTH_INTERVAL_S`, after a completed tick |

An alarm whose text changes in substance (a new cause, a new cap value) prints at once; the numbers that move
every tick (a warm-up count, a deviation, a quote) are not part of what makes it "new".

**Do not** shortcut any of this with a loose floor; that throws away the sandwich protection keeper-gating
provides.

## Beacons (drand-BLS)
The protocol runs on the **time-locked drand-BLS oracle**, so randomness must be **posted on-chain**. The
keeper fetches beacons from drand quicknet HTTP relays and decompresses the G1 signature to the EIP-2537
format the oracle verifies (`beacon.js`, via `@noble/curves`). Already-posted rounds are skipped
(`isAvailable`); a bad post reverts and fails safe.

- **Relays.** `DRAND_RELAYS` (comma-separated) or the public defaults (`api.drand.sh`, `api2`, `api3`,
  `drand.cloudflare.com`); the older `DRAND_API` is tried first if set. Each request times out after
  `DRAND_TIMEOUT_MS` (default 10 s, validated: 100 ms to 300 s); an answer must name the requested round and decode to a valid point, or
  the next relay is tried. A beacon the oracle rejects (`InvalidBeacon` and friends) is re-fetched from the
  next relay. `--failsafe` uses the reverse order.
- **Timing.** A round is not fetched until it is `DRAND_MARGIN_ROUNDS` (default 3, about 9 s) past its publish
  time on the host clock, and not-yet-due rounds are silent. A relay answers "not yet" for a round it does not
  serve: `drand.cloudflare.com` with HTTP 404, `api.drand.sh`, `api2` and `api3` with HTTP 425 Too Early. If every
  relay still answers 404 or 425 within `DRAND_GRACE_ROUNDS` (default 40, about 2 minutes) of publication the round
  is "pending", not an error; after that it is logged as a failure. Keep the host clock on NTP: the health watch
  logs an info line when the host clock is more than `CLOCK_SKEW_WARN_S` behind the chain's latest block (every
  reveal and draw is late by that much) or ahead of it (the keeper asks for rounds before they publish; the same
  line appears when the chain has produced no block for that long).

Which rounds, and when:
- **Cohort reveal rounds.** Packs bought on day `c` are sealed to `roundAt(genesis + (c+1)*dayLength +
  revealDelay)`. The keeper posts that round as soon as it publishes, for every recent cohort with live packs.
- **Before a raffle draw** it requires, and posts if missing, the reveal round of every cohort the draw can pop
  from (`[drawDay - LIFE_DAYS, drawDay - 1]`; the opening is `drawDay = 2`, cohorts 0 and 1) that still has
  live packs, **and** the draw round. Until all of them are on-chain the draw is held: "waiting" while drand
  has not published, `HOLDING` (ERROR) when a publishable round could not be posted. This is the same set the
  engine checks (`PackRegistry._drawCore` reverts `RevealPending` for any non-empty cohort in that window), and
  the same round (`roundAt(genesis + (c+1)*dayLength + revealDelay)`, what `_mintPacks` stored). With the shipped
  `revealDelay` equal to `REVEAL_LAG` (1 hour each), the opening's cohort-1 reveal and its draw beacon are the same
  round.
- **`RevealPending` anyway.** The keeper decodes it by name, posts the round the engine named, and retries the
  draw on the next tick (see guarantee 2 above).

**Verify beacon posting end-to-end on your chain once before launch**: it is the one piece that touches
external data.

> **Verified chain-free:** `beacon.js` decompressing quicknet round 1000 reproduces, byte-for-byte, the
> uncompressed G1 signature that `test/BlsDrandOracle.t.sol` proves the on-chain verifier accepts.

### Manual beacon submission (real-oracle testnet pass / spot posting)

For a `MOCK_ORACLE=false` run, or to post a beacon by hand, two standalone CLIs sit alongside `beacon.js`.
Both only **print** a `cast send`; signing stays in `cast` + your keystore account (`--account`), so **no
private key ever touches these scripts**. They read addresses from env (the `DeployTestnet` export block
already sets `ORACLE` / `RAFFLE_ENGINE` / `PACK_REGISTRY` / `RPC`).

**`prep-draw.js <day>`, turnkey.** Reads every drand round the raffle draw for `day` needs (the reveal
round of each live cohort in the window, so `tierOf` resolves, **plus** the draw round), fetches each beacon,
skips any already on-chain, and prints the `cast send` for each, then the `runDraw`. Round numbers come
straight from the contracts (`engine.drawRound`, `oracle.roundAt`), so there is no round math to get wrong. A
beacon that has not published yet is reported, not fetched: wait and re-run.
```bash
node keeper/prep-draw.js 1          # prep the draw for day 1
```

**`submit-beacon.js <round>`, single round.** Fetches one round and prints its submit command.
```bash
node keeper/submit-beacon.js 1234567
```
The printed `cast send` signs with `--account $KEEPER_ACCOUNT`, which defaults to `deployer` when unset. Set
`KEEPER_ACCOUNT` to the key you mean to send from (any funded key can post a beacon), and read the printed line before
running it: on mainnet the NFT deployer key must send nothing before `DeployNFT` (with `EXPECTED_NFT_ADDRESS` set, the
deploy checks that the collection lands at an address that depends on that key's nonce). The mainnet Art Pass reveal passes
`KEEPER_ACCOUNT=<any funded key>` for that reason, so the `deployer` default is never used by accident.

## Super Rare index (`registerSuperRare`)
Super Rare passes get a **passive daily auto-entry** into the raffle (spec §16), but the draw only knows a
pass is Super Rare from an on-chain index. `registerSuperRare(ids)` builds it: it is **permissionless** and
**idempotent** (it re-verifies `rarityOf(id)==SuperRare` on-chain and skips ids already indexed), so the
keeper can safely (re)build or repair it. **This is mandatory**: skip it and every Super Rare's auto-entry
silently resolves to **zero** (not a revert, just no free entries).

Each tick, before the draws, the keeper:
1. waits until the collection has revealed (it posts the collection reveal round like any other beacon; on mainnet
   it has normally been posted by hand already, with `submit-beacon.js` right after `finalizeLaunch`, because the
   keeper cannot start before `Deploy.s.sol` and an unposted reveal leaves every tier computable off-chain),
2. discovers the Super Rare token ids by reading `rarityOf` **off-chain** over `1..totalMinted` (so only the
   ~2% Super Rare set is ever sent as calldata). Once the reveal beacon is on-chain no minted id can revert,
   so any failed read (a rate limit, a lagging node) stops the scan without caching a partial set, logs an
   error, and resumes at that id on the next tick,
3. calls `registerSuperRare` for any not-yet-indexed ids (chunked), then **stops** once
   `superRareCount()` covers them all.

Set `PACK_REGISTRY` and `NFT_COLLECTION` in `.env`. **Timing:** the index must be complete **before the first
daily draw's freeze**: a registration made after a given draw's freeze is excluded from that draw and only
counts from the next day. The keeper runs this first each tick and finishes within a tick or two of the
reveal.

## Monitoring
Ship the log to something that pages on these lines (all at ERROR level; the table in [Alarms](#alarms) gives
each one's cadence): `FATAL`, `PERIOD VOIDED`, `closed UNSETTLED before this keeper started watching`,
`HOLDING, not fired`, `LOW BALANCE`, `BLOCKED BY THE QPULL LEG`, `CONFIG: the QPULL/WETH pool binding is wrong`,
`convert() did not go through`, `NO SUCCESSFUL CONVERT`, `caps NOT ARMED`, `convert caps could not be read`,
`BELOW MIN_WETH_CONVERT_WEI`, `reference quote failed` (at ERROR), `price check is unavailable`, `RevealPending`
(at ERROR), `MISCONFIGURED`, `claim sweeper: DISABLED`, `did NOT confirm within SEND_WAIT_TIMEOUT_MS`,
`REVERTED on chain`, `was REPLACED`, `send FAILED`, and `tick error in`. Simplest: page on every line the keeper writes to stderr
with `ERROR`.

**Liveness: alert on the missing heartbeat, not on a quiet log.** A healthy keeper is quiet for hours (nothing is
due), so a quiet log proves nothing, and a stuck loop writes no ERROR. The keeper writes a `heartbeat:` line to
stdout after a tick has run every job, at most every `HEALTH_INTERVAL_S` (default 300 s). **Page when no
`heartbeat:` line has appeared for 2 x `HEALTH_INTERVAL_S` plus the longest tick you expect** (a tick that sends
several transactions into an RPC that drops them can take `SEND_WAIT_TIMEOUT_MS` per send; each of those also logs
an ERROR). Also page when the process is down: the keeper cannot report its own death.

## keeper-testnet.js
The short-clock testnet keeper for a `MockDrandOracle` deploy (`node keeper-testnet.js`, `--once` for one pass,
`DRAW_MODE=auto` to send the draws itself; config from `.env.testnet.example`). It is a testnet crutch, not a
second mainnet keeper:
- **It refuses Robinhood mainnet.** On chainId 4663 it exits `FATAL` before any other read or send. Use
  `keeper.js` there.
- **Convert is opt-in twice.** It sends `Treasury.convert()` only with `TREASURY` set **and** `ENABLE_CONVERT=true`
  (any other value, including `keeper.js`'s `simulate`, leaves convert off and says so at startup), and the keeper
  key must hold the Treasury keeper role. Floors come from bisecting `convert()` itself, read with the same
  classification as `keeper.js` (`reverts.js`): only a slippage revert (`SwapShortfall`, `Slippage`,
  `SlippageExceeded`, the mock adapter's `"slippage"`) means "floor too high". Any other revert, a revert without
  data, or an RPC error stops the search: no floor, nothing sent that tick, one log line per cause.
- **Reveal beacons wait for the chain's clock.** A pack cohort's or the collection's reveal round is posted once
  its drand time has passed on the chain (the pending block's timestamp where the node serves one, else the
  latest block's), so a cohort never reveals while its buy day is still open on chain. Draw-round beacons are
  posted as soon as the draw is due.
- **Sends are bounded and decoded.** A sent transaction is waited on for at most `SEND_WAIT_TIMEOUT_MS` (default
  120 s; ERROR with its hash and nonce after that), and, as in `keeper.js`, that job sends nothing while the
  timed-out transaction is still pending (one `NOT sent again` line). A transaction replaced by another sender on
  the same key is logged as `was REPLACED`, not as reverted. A call that simulated cleanly and then reverts while its
  transaction is built (a draw window that closed in between) is logged once by its error name, for example
  `raffle.runDraw: not callable this tick (OutsideWindow: ...)`, and nothing is sent.
- **Real-oracle fetch failures are bounded like `keeper.js`.** With a `BlsDrandOracle`, a due round for which every
  relay answers 404 or 425 is silent only while it is at most `DRAND_GRACE_ROUNDS` (default 40, about 2 minutes)
  behind the round due now; after that each failed fetch is logged again, so a relay list that answers 404 for
  every round (a wrong path or chain hash) or a host clock far ahead is not silent forever.
- **`KEEPER_IMPORT_ONLY=1`** works as it does for `keeper.js`: set in the process before the import, the file loads
  no `.env`, builds no signer and runs nothing (offline tests only).

## Upgrading later
If Gelato or Chainlink's CRE ever support your chain, you can move these triggers to a managed network
with **zero contract changes**: same functions, different caller. Until then (Robinhood Chain is not
covered by them today), this bot is the way.
