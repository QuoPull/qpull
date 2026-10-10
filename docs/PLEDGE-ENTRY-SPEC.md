# Art Pass Daily-Entry: Virtual Pledge Model, Buildable Spec

Status: BUILT and unit-tested (owner-approved). It replaced the count-based `claimFreeEntries` perk, which no longer exists.
Supersedes the earlier minted/clamped draft. All new logic lives in `PackRegistry.sol`.

## 0. Implemented vs this draft (AUTHORITATIVE deltas)

The shipped code diverges from the sections below in a few places. Where they conflict, THIS section
and `src/PackRegistry.sol` win; the older prose is kept for context.

- **Selection is MULTI-SHOT (with replacement), not one-shot / Fisher-Yates.** `vPool = cap` whenever any
  pass is eligible (`_buildFreeCfg`); a virtual seat re-samples the whole eligible pool each time, so one
  Super Rare can win several seats. The realized free prize-share therefore holds ~9.09% at every volume
  (not the pass-limited decline in the old §3 table). There is NO `min(cap, srCount)` sizing, NO
  within-draw dedup / `TSTORE`, and NO no-replacement rule. `§2.5`, the `§3` decline rows, `§4` distinctness
  "wins twice" line, and `§8.4` are superseded by this.
- **`drawFrom` signature CHANGED.** Daily draws call `drawFrom(beacon,drawDay,k)` (free block active); the
  one-time opening sweep calls the sibling `drawFromPaidOnly(beacon,drawDay,k)`. Both are `onlyEngine` and
  delegate to internal `_drawCore(...,allowFree)`.

### Security hardening landed (was: must-fix before mainnet)

1. **SR draw set frozen per draw.** `srRegisteredAt[tid]` is stamped in `registerSuperRare`;
   `_buildSrList` skips any id with `srRegisteredAt==0 || srRegisteredAt > freeze`. A `registerSuperRare`
   after a day's settling beacon is public cannot enter that day's draw (it counts from the next day),
   so the SR set is immutable once randomness is public.
2. **Opening sweep is paid-only BY CONSTRUCTION.** `runOpeningDraw` calls `drawFromPaidOnly`,
   which forces `vPool=0` regardless of when the (permissionless) opening runs. Paid-only is no longer a
   timing accident, so a late opening can never fold the free block against an already-revealed beacon. A
   later daily `runDraw(ACCUM_DAYS)` still uses `drawFrom` and keeps its free block.
3. **VTIER keyed on the frozen winning-pass id + its per-draw win-index, not the seat counter.**
   `vtier = _tierFromRoll(keccak(beacon, day, 2, tid, winIdx) % 10000)`, where `winIdx` is how many times
   this same `tid` has already won in this draw (`_tidWinIndex` over the in-order `wonTids` memory list,
   identical in `_drawCore` and `_replayVirtual`). Two properties:
   - **Non-steerable:** a token's k-th win ALWAYS rolls `keccak(...,tid,k)`; no post-beacon transfer /
     pledge-void / seat reshuffle can reassign which roll a win gets, and every win is paid, so there is no
     cherry-pick and no bucket upgrade. `seat` remains only the synthetic-id uniqueness nonce.
   - **Variance-correct (concentration regression fix):** an earlier draft keyed VTIER on `tid` alone, so a
     pass's many multi-shot wins all shared ONE tier roll, in a thin market a lone SR could concentrate the
     whole SR bucket (~41% of the pot on a 1% roll) despite an unchanged ~9.09% EV. `winIdx` makes each of a
     pass's wins an INDEPENDENT roll over the 1/4/15/80 bands, so realized free value-share re-converges to
     ~9.09% and the tail collapses. (Dedup-to-one-seat was rejected: it breaks the locked MULTI-SHOT design
     that holds 9.09% with a finite ~3k pass supply.)

`RaffleEngine` changed at exactly one line (opening calls `drawFromPaidOnly`); `ClaimManager` and the
vaults are UNCHANGED.

## 1. Overview

Art Passes become **direct daily-raffle entrants**, tier sets **how often** you enter, and entries are
**virtual** (never minted, never stored as a list).

- **Super Rare** (`rarityOf == 3`): passive **auto-entry**, first claim on the day's cap. **Always in**
  (no opt-out).
- **Common / Uncommon / Rare**: **opt-in pledge** each day (default not entered), weighted 1 / 2 / 4.
- **Cap** = **10% of the live paid window**, linear, no hard clamp (`FREE_CAP_BPS` 2000 -> 1000).
- **Contested slots**: beacon-seeded tier-weighted lottery (Super Rare proportional-first, then weighted
  C/U/R). No FCFS, no MEV, no gas race (the beacon reveals after the pledge freeze).
- **1 shot per day.** Entries do not ride the 7-day window (that would require materialization).
- Free entries can never rip for XP (structural, no pack exists).

**Why virtual.** At 10% a busy day is thousands of seats; minting or even storing a list of them exceeds
the block gas ceiling. Instead the whole free-eligible block enters the draw as ONE integer weight
`vPool` added to `drawFrom`'s sampling total, and at most K winners are resolved at draw time.

## 2. Onchain mechanism (`PackRegistry.drawFrom`, signature unchanged)

Today `drawFrom(beacon, drawDay, k)` sums the live paid packs and samples K winners. The change adds a
free block after the paid sum:

1. `paidLive` = sum of `cohortLive[drawDay-7 .. drawDay-1]` (the existing loop). Free entries are never
   minted into `cohortLive`, so this stays **paid-only** (self-reference firewall intact).
2. `freeze = genesis + (drawDay+1)*DAY()`; `freeActive = block.timestamp > freeze`. True for every real
   daily draw (the settling beacon reveals after the freeze); **false for the one-time opening sweep**, so
   the opening draw is paid-only.
3. `cap = paidLive * FREE_CAP_BPS / 10_000` (10% of the live paid window). If `!freeActive` or `cap==0`,
   the free block is empty and `drawFrom` behaves exactly as today.
4. **SR list**: one bounded scan of `superRareIds` only (never the 3k token space), capped at
   `MAX_SR_SCAN=128`, building an in-memory list of eligible Super Rares (`ownerSince != 0 && <= freeze`,
   `ownerOf` resolves non-zero via try/catch). `rarityOf` is never called here (SR comes from the index),
   so the draw is reveal-independent.
5. **(IMPLEMENTED, supersedes the old min-sizing here)** `vPool = cap` whenever any pass is eligible
   (`srCount*SR_WEIGHT + pledgeList[day].length > 0`), else 0. MULTI-SHOT: each virtual seat re-samples the
   whole eligible pool (repeats allowed), so `pledgeDistinct` does NOT size the pool. `total = paidLive +
   vPool`, and `vPool <= cap` still bounds the free share so paid odds are never diluted beyond 10%.

**Sampling** (without replacement over the combined domain): for each of the ≤K draws,
`r = keccak(beacon, day, j) % total`.
- `r < paidRemaining` → **paid**: walk cohorts and `_popAt` exactly as today.
- else → **virtual**: route proportionally by roll position between SR and pledge (reproduces
  "Super Rare first-claim, then weighted lottery" exactly, when SR is oversubscribed all virtual wins go
  to SR; when undersubscribed, wins split by seat count).
  - **SR seat**: resolved rejection-free via a partial Fisher-Yates over the SR list (zero rejection
    budget).
  - **Pledge seat**: bounded rejection under a per-seat sub-cap (`MAX_REJECTS_PER_SEAT=6`) and a global
    budget (`MAX_VDRAW_ROLLS=256`); accept iff not-already-won, `pledgerOf[tid][day]==ownerOf(tid)` (a
    transfer voids the pledge) and `ownerSince<=freeze`. Weight-expanded copies make the uniform pick
    1/2/4. If none accepted, the seat voids (rolls forward).
- On a seated hit: mark won (transient `TSTORE` dedup), roll a fresh **VTIER** off the beacon, and emit
  the winner as a synthetic id.

**Prize bucket (VTIER).** A virtual winner gets a **fresh beacon roll** on the pack tier bands
(SR 1% / Rare 4% / Uncommon 15% / Common 80%), NOT the pass's `rarityOf`. This is ungameable (keyed on the
post-freeze beacon) and avoids double-dipping (rare passes already enter more often). Rarity governs **how
often you enter, never how much a win pays**.

**Payout (RaffleEngine unchanged).** A virtual winner is a self-describing synthetic id:
`id = VIRTUAL_FLAG | (seat<<168) | (vtier<<160) | passOwner`, `VIRTUAL_FLAG = 1<<255`. Real pack ids
(from 1) never set the top bit. `ownerOf(id)` and `tierOf(id)` decode the passholder and tier from the id,
so `RaffleEngine._payWinners` works verbatim (tier bucket, no-dust skip, `registerClaim` to the
passholder). Void-on-miss preserved.

## 3. Cap and realized dilution (quote honestly, never "10%")

Free prize-value share = `vPool / (vPool + paidLive)`. It rises with volume until the finite pass supply
(~3,000) can't fill the cap, then declines:

| Daily paid volume | ~Eligible passes (E) | Realized free share |
|---|---|---|
| Dead (0 buys) |, | **0%** (paid keep everything) |
| Low (~100/day) | ~70 SR | **9.09%** (cap-filling ceiling) |
| Mid (~1,000/day) | ~700 | **9.09%** |
| High (~5,000/day) | ~3,000 (max) | **~7.9%** (pass-limited) |
| Very high (~25,000/day) | ~3,000 | **~1.7%** (pass-limited) |

Design ceiling is **9.09%** (paid buyers keep ≥ ~91%). Free entries share the fixed K winner slots and the
fixed pot, they **transfer** value to passholders within the tier buckets, never enlarge the pot. The UI
must show **realized/eligible seats**, not the raw 10% cap.

**Self-reference firewall:** after `claimFreeEntries` is deleted, `recordBuy` is the only caller of
`_mintPacks` (always `free=false`), so `cohortLive`/`liveCount` is paid-only and a free win can never raise
today's share or tomorrow's cap.

## 4. Edge-case guards

- **Freeze-before-beacon:** `drand.randomness` reverts until the settling beacon reveals (after freeze), and
  `freeActive = block.timestamp > freeze` is the explicit gate.
- **Opening draw:** paid-only (freeActive false); free entries begin at the first normal daily draw.
- **Dead / zero-buy day:** `paidLive==0` → cap 0 → no free block; draw behaves as today.
- **Transfers mid-day:** a pledged token transferred at/before freeze fails `pledgerOf==ownerOf` (voids);
  after freeze fails `ownerSince<=freeze`. New owner may re-pledge with no lockout.
- **Pre-reveal:** `pledge`/`registerSuperRare` gate on `nft.launched()` and try/catch `rarityOf`; `drawFrom`
  never calls `rarityOf`, so one unreadable token can't brick a draw.
- **Idempotency:** the free block is folded into `drawFrom`, so there is ONE consume/void surface
  (`RaffleEngine.drawn[day]`); winners are a pure function of frozen state + beacon (preview == draw).
- **Distinctness:** SR and pledge sets are disjoint; within-draw dedup prevents a token winning twice; an
  owner holding several eligible passes can win several distinct seats (sybil-neutral).
- **Re-org:** shares the daily raffle's exact beacon + reveal lag; adds no new timing surface.
- **Stale-pledge phantom (bounded):** `pledgeDistinct` doesn't self-heal on transfer, so a
  pledge-then-transfer flood can leave stale distinct entries, but `vPool<=cap` (no share inflation), the
  per-seat sub-cap bounds gas, stale picks void, and the attacker gains nothing while paying transfer gas.

## 5. Contract changes

- `FREE_CAP_BPS` 2000 → 1000 (10% linear, `liveCount` basis).
- New constants: `VIRTUAL_FLAG=1<<255`, `MAX_SR_SCAN=128`, `MAX_VDRAW_ROLLS=256`, `MAX_REJECTS_PER_SEAT=6`,
  `SAFE_FREE_K=150` (later removed as dead code: nothing enforced it; the measured bound is
  `MAX_DRAW_K == MAX_K = 200`); `_entryWeight` (C 1 / U 2 / R 4).
- New state: `superRareIds[]` + `srIndexed`; `pledgeList[day]`, `pledgerOf[tid][day]`, `pledgeDistinct[day]`;
  transient within-draw dedup (`TSTORE`/`TLOAD`, prague).
- Delete: `claimFreeEntries`, `_freeEntries`, `freeToday`, `freeClaimed`, event `FreeEntriesClaimed`.
- New events: `FreeEntryDrawn(day, passTokenId, owner, tier, seat)`, `Pledged`, `SuperRareRegistered`.
- `drawFrom` MODIFIED (signature unchanged): the free block above.
- `ownerOf` / `tierOf` MODIFIED: decode virtual ids. `rollOf` / `tierAndRollOf`: revert `VirtualId` for
  top-bit ids.
- New externals: `registerSuperRare(ids)` (permissionless, verify `rarityOf==3`, append), `pledge(tokenIds)`,
  `capOf(day)` view, `previewDraw(day)` view (replays selection read-only).
- **RaffleEngine / ClaimManager / vaults / INFTCollection: no source change.**
- Web: at the `WinnerPaid` enrichment, skip `rollOf` for top-bit ids and render them as free-entry wins from
  `WinnerPaid.tier`.

## 6. Implementation plan (ordered)

1. Constants + deletions (drop the count perk).
2. State + events + typed errors.
3. Externals: `registerSuperRare`, `pledge`, `capOf`.
4. Core `_select(beacon, day, k, commit)` shared by `drawFrom` (commit: storage pop + transient dedup) and
   `previewDraw` (view: memory swap-pop + memory dedup) so the two provably agree.
5. Decode views (`ownerOf`/`tierOf` branch on `VIRTUAL_FLAG`; guard `rollOf`/`tierAndRollOf`).
6. Web `WinnerPaid` handling.
7. Mocks + replace the `claimFreeEntries` tests.
8. Keeper/runbook: the keeper now AUTO-builds the SR index (`registerSuperRare`, permissionless + idempotent)
   right after reveal, before the first daily draw's freeze, see keeper/README.md "Super Rare index" and
   keeper/keeper{,-testnet}.js `runRegisterSR`/`doRegisterSR`. (The opening no longer needs to run promptly
   for safety: it is paid-only by construction, see §0 item 2.) Pin `winnersPerDay <= 150` unless
   the gas test passes at a higher K (it now does at K = 200: `test/GasBenchmark.t.sol`).
9. Docs: this file, including the re-org note in §4; no em/en dashes in user-facing copy.

## 7. Test plan

- **MANDATORY gas test:** paidLive ~25,000, K=200, pledge field packed with all-rejecting
  pledge-then-transfer tokens + ~70 SR; assert `drawFrom` + `_payWinners` < 30M gas. Gate any deploy with
  `winnersPerDay > 150` on this.
- `previewDraw == drawFrom` across many beacons and mixed states.
- Proportional SR:pledge routing; SR-oversubscribed starves pledges; undersubscribed splits by seats.
- Realized share ≈ 9.09% when cap-filling, `E/(E+paidLive)` when pass-limited; cap uses `liveCount`.
- Pledge 1:2:4 weighting; cap-at-resolvable + flood bound; prize-bucket bands; payout/decode
  (`ownerOf`/`tierOf`/`rollOf`); freeze-before-beacon + opening paid-only; zero-buy day; regression
  (paid-only draws unchanged).

## 8. Owner decisions (with recommendations)

1. **Cap basis** = `liveCount` (9.09% ceiling, pass-limited at high volume). Keep it; quote the honest
   table, never "10%".
2. **`winnersPerDay` ceiling** = run ≤ 150 for full gas margin; 150 to 200 only after the
   mandatory gas test passes at that K. (The `SAFE_FREE_K` constant was never enforced and was removed.)
3. **Prize bucket** = fresh VTIER roll (ungameable), not `rarityOf`.
4. **Pledge-slot sizing** = IMPLEMENTED as MULTI-SHOT (`vPool=cap`, weighted re-sampling over `pledgeList`),
   NOT `pledgeDistinct`-sized (see §0). `pledgeDistinct` survives only as its public getter
   `pledgeDistinct(day)` (the duplicate `pledgeCount(day)` view was removed), an
   UPPER bound that is not decremented on transfer; use `previewDraw(day)` for realized free winners.
5. **`registerSuperRare`** = permissionless + mandatory keeper call at reveal.

## 9. Risks

- Gas at K in (150, 200] is safe by conservative bound + per-seat sub-cap, but MUST be measured before
  shipping K>150.
- SR index operational gap: a missed `registerSuperRare` at reveal silently yields 0 SR (not a brick):
  mandatory runbook step.
- High-volume free share declines to ~1.7% (finite passes), surface realized/eligible seats in the UI.
- Overloaded `ownerOf`/`tierOf` semantics keep RaffleEngine untouched but integrators may prefer a
  seat-keyed (owner, tier) store, available as a fallback.
- Stale-pledge thin-day griefing: bounded, hardenable if observed.
- Deleting `claimFreeEntries` touches a few tests/mocks, modest but real churn.
