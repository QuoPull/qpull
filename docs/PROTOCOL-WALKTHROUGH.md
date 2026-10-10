# QuoPull: Full Protocol Walkthrough

A plain-language, end-to-end run-through of the whole QuoPull system: what a player does, what happens under the hood, and every number that matters. Written against the source as of 2026-09-14. It gives no file:line citations; the contracts in `src/` are authoritative.

QuoPull is a token-funded pack raffle plus three overlapping onchain games on Robinhood Chain. Everything pays from pots the protocol already holds. Nothing here is a promise of profit: prizes are funded by trade tax and mint proceeds, draws are permissionless and fixed, and a pot too small to pay simply rolls forward.

---

## The three things you hold

| Thing | What it is | Role |
|---|---|---|
| **Art Pass** | The launch NFT (`NFTCollection`, max 3,500). Rarity revealed onchain. | Your holder identity: buying in the 1-hour launch window, free daily raffle entries, and (with 4+) the weekly holder draw. |
| **$QPULL** | The game/tax token (`QPULLToken`, fixed supply, ownerless ERC-20). | What you buy. Buying it mints packs and earns XP; the 4% trade tax funds the prize pots. |
| **$QUOTRON** | The prize token (an external ERC-404 the protocol holds inventory of). | What every game pays out. You never buy it; you win it. |

---

## The player's loop

```
Mint an Art Pass  ->  Buy $QPULL  ->  get sealed Packs  ->  packs reveal a tier
        |                  |                                      |
        |                  +-- 4% tax funds the prize pots        +-- win -> claim $QUOTRON
        |                  +-- earns leaderboard XP               +-- lose -> RIP for XP
        |
        +-- hold 1+  -> free DAILY RAFFLE entries (Super Rare auto, others pledge)
        +-- hold 4+  -> weekly HOLDER DRAW (5 winning passes, pot/5 each)

XP (from buys + losing rips)  ->  weekly LEADERBOARD (top 25 paid pro rata; weeks end Sunday 00:00 UTC, settled the following week)
```

Three games run off one wallet: the **daily raffle** (your packs + your passes), the **weekly leaderboard** (your activity), and the **weekly holder draw** (just for holding 4+). Win in any of them, claim $QUOTRON within 30 days.

---

## Part 1 - Mint the Art Pass

The mint is a self-running, time-boxed machine. The owner opens it once; after that it runs on the clock with no further owner action.

**What you do:** connect, pick a quantity, pay `mintPrice x qty` in ETH, receive sequential token ids. Your pass shows **Sealed** art until reveal.

**The windows** (mainnet; the short-clock testnet compresses these):

| Phase | Mainnet length | Who can mint | Per-wallet cap (cumulative) |
|---|---|---|---|
| GTD / allowlist | first 6h | allowlisted wallets (merkle proof) | 3 |
| Overflow | next 18h | allowlisted wallets | 8 |
| Public | 24h | anyone (`mint` / `mintBatch`) | 20 |

- The close is **fixed** at ~48h after start. A late-overflow mint can *soft-close* (push the public open later), which shortens the public window rather than extending the end.
- After the close, **`finalizeLaunch()` becomes permissionless** (anyone can call). It seals rarity and moves no ETH, so a missing owner can never strand the collection. A 30-day backstop covers the allowlist-only-then-vanish case.
- Mint proceeds split **80% LP / 10% prize seed / 10% team + operations**, paid out by `withdrawProceeds()` (the go-live makes that call). The LP bucket seeds the permanently locked pool; the prize seed is bought into the daily raffle vault as $QUOTRON.

**Reveal:** `finalizeLaunch()` picks one future drand round. When that one beacon posts, **the entire collection reveals at once**. `tokenURI` flips from sealed art to your tier art, fully onchain (SSTORE2, no IPFS).

**Rarity bands** (independent per pass, so counts are approximate, not quotas):

| Tier | Odds | Pool-share trait |
|---|---|---|
| Super Rare | 2% | 45% |
| Rare | 8% | 25% |
| Uncommon | 20% | 20% |
| Common | 70% | 10% |

Two hidden clocks are stamped on every transfer and drive holder eligibility: **`ownerSince[tokenId]`** (when a pass last changed hands) and **`qualifiedSince[owner]`** (when a wallet's balance last crossed up to 4 and held there). Both are what make the holder draw un-gameable (see Part 4c).

---

## Part 2 - Buy $QPULL (the 4% tax, the 1-hour launch gate)

You swap into $QPULL on the canonical Uniswap v4 pool. The tax lives in an **immutable v4 hook** (no owner, no setters), not in the token.

**How the website does it:** the swap box calls the protocol's own small router, `QpullSwapRouter` (no owner, it holds nothing between trades). A buy sends ETH, which the router wraps and swaps; the $QPULL goes straight to your wallet. A sell asks you to approve exactly the amount first, then pays you ETH. Every trade carries a minimum-received amount (never zero) and a 10-minute deadline, so a trade that would fill at a worse price, or that sits unmined too long, reverts instead. The router is taxed like any other way of trading, and your packs and points go to the wallet that signed. So in the first hour, hold your Art Pass in the wallet you connect: the swap box says so above the Buy button, and the site's FAQ (`docs.html#faq`) answers the common launch questions.

**The tax** (always taken in WETH, on every kind of swap):
- **Buys: flat 4%** of the WETH you spend, rounded up.
- **Sells: decay 20% -> 4% over the first 48h** (an anti-dump; steps 20/16/12/8/4, one step every 12h). Buys are never elevated.
- An exact-output swap pays the true rate too: a sell that asks for an exact WETH amount pays 20% of its gross in the first step (25% of the WETH received).

**The first hour after pool creation only** (the "gate window", `GATE_DURATION()` = 1 hour on mainnet):
- **Holders only:** the signing wallet must hold an Art Pass, or the buy reverts (`Gated`). (A pass in a Safe/AA wallet doesn't count in that hour, since the check is on the signer EOA.)
- **Cooldown:** at least 2 minutes between your buys.
- **Size cap:** each buy can spend at most `earlyBuyCapWei` (planned 0.25 ETH; fixed at deploy, and the swap screen shows the live figure) until your wallet has spent 10 times that (2.5 ETH at the planned value) in the window. After that your buys are uncapped; the cooldown still applies. Small buys do not use the cap up.
- **Transfer lock:** if you made a gated buy, your pass can't be transferred until the window ends (no buy-then-shuffle-to-a-second-wallet).

After the window: no gate, no cooldown, no lock. Just the 4%.

**Rewards:** a buy credits you **pack tickets + leaderboard XP** equal to the WETH you spent, derived from the WETH tax the hook actually took (credit = fee x 25, never more than what you paid). Pumping and dumping the pool inside one transaction therefore costs at least the full tax on the credit it buys. **Sells earn nothing.**

---

## Part 3 - Packs: mint, reveal, rip

**Mint on buy:** the hook calls `recordBuy(you, value)`. Your value (plus any banked sub-ticket remainder) divides by the ticket price into **whole sealed packs**; the remainder rolls into your next buy. Capped at `maxTicketsPerBuy` (default 100) per buy; the excess value banks for later.

**Reveal -> tier:** every pack minted on a given day shares one future reveal round (keeper efficiency). Once it posts, the pack shows a **roll 0-9999** and a tier. Anyone can recompute the roll to "verify this rip." No raffle draw can run while a cohort it would draw from is still unrevealed: it reverts and waits for the reveal, so a winning pack always has a tier to be paid by.

| Pack tier | Odds | Daily-draw bucket |
|---|---|---|
| Super Rare | 1% | 45% |
| Rare | 4% | 25% |
| Uncommon | 15% | 20% |
| Common | 80% | 10% |

**Life:** a pack is entered in the daily raffle for **7 days**, then ages out automatically.

**Rip for XP:** a pack that revealed, was never drawn, and has aged past its draw window becomes a **settled non-winner**. You call `claimRipXp([ids])` to bank rarity-weighted XP toward the weekly leaderboard, claimable only in a one-week window after it settles. Winners claim $QUOTRON instead; a winning pack never earns rip XP.

Rip XP by tier: **1.8% of the pack's cohort ticket price, times Common 1x / Uncommon 2x / Rare 4x / Super Rare 10x** (a Super Rare rip is worth 18% of a ticket in points). Packs from the first two days (the opening cohorts) can only be ripped once the one-time opening draw has settled.

---

## Part 4 - The three games

### 4a. Daily raffle (your packs + your passes)

Once a day, a keeper runs the previous day's draw. It picks **K winners** across all live cohorts, sorts them into tier buckets, and writes a claim for each. Each winner's prize is its **equal share of its tier bucket** `(pot x bucketBps) / (BPS x winnersInThatTier)`; an empty tier's bucket stays in the vault.

- The draw window is **exactly the following day**. Miss it and that day voids, pot rolls forward.
- **Void-on-miss:** if the pot is below `minPot`, or too small to pay every winner at least 1 wei, or the window is empty, the draw returns without burning tickets or consuming the day. Nothing is ever lost, just deferred.
- **Launch:** no draws for the first 48h while packs and the pool build; then a **one-time opening draw** splits the built-up pool 5 ways among paid packs only, and normal daily draws unlock. The 10% mint seed is bought into the raffle vault before it, so the opening has a pot.
- **Equal odds per pack:** every live pack has the same chance to be drawn. The tier a pack revealed only decides which prize bucket pays it.

**Free entries for passholders (the "virtual" pledge model):** your Art Passes enter the same daily draw directly, weighted into the sampling as one integer (the free block is capped at **10% of the live paid window**). Nothing is minted; winners are resolved lazily as self-describing synthetic ids.

- **Super Rare: passive auto-entry** (draw weight 8). You do nothing; the keeper registers all Super Rares once at reveal.
- **Common / Uncommon / Rare: opt-in `pledge()` each day** (weight 1 / 2 / 4). Default is not entered; a pledge is good for one day and voids if the pass changes hands.
- Rarity decides **how often** you enter, never how much a win pays: a free winner rolls a fresh prize tier (VTIER) on the pack bands.
- **Multi-shot:** the free block re-samples, so realized free prize-share holds ~9.09% at every volume (paid buyers keep ~91%).

Three security properties keep it fair: the Super Rare set is **frozen at each day's freeze** (`srRegisteredAt`), the opening sweep is **paid-only by construction**, and a free winner's tier is keyed on the **frozen pass id + its per-draw win index** (non-steerable and not concentration-prone).

### 4b. Weekly leaderboard (your activity)

Points accrue Sunday-to-Sunday two ways: **every buy** (1:1 with the ETH you spent) and **banked rip XP** (rarity-weighted). Sells add nothing, so no one can buy rank with someone else's money.

- **Top 25** buyers make the board.
- At week's end, anyone calls `distribute(week)` during the following week. The pot splits **linearly, pro-rata by points** across ALL buyers' points (not just the board's sum), so the top 25 collectively receive `theirPoints / allPoints` of the pot; the rest rolls forward.
- The split is **not** sqrt-weighted. An earlier sqrt curve was removed because it was found to be sybil-positive; linear pro-rata is sybil-neutral.
- Funded by **12.5% of the trade tax**. Void-on-miss like every game.

### 4c. Weekly holder draw (just for holding 4+)

The funded holder jackpot: **5 distinct winning passes, each paid an equal `pot/5`**, funded by **6.25% of the trade tax**.

- **You do nothing but hold.** To be in week W you must hold **4+ Art Passes continuously since that week's freeze** (`MIN_HOLD = 4`).
- Eligibility is **frozen, not live:** it reads `qualifiedSince(owner)` stamped by the NFT, so **topping up to 4 after the winning beacon is public buys nothing.** The winning number only becomes public ~4.5 days after the freeze, which exceeds Robinhood Chain's 4-day sequencer back-dating bound, so the ordering is code-enforced.
- **Selection is per-token, not per-wallet.** More eligible passes -> linearly more chances, and a wallet can win multiple of the 5 slots. A per-wallet cap was deliberately **rejected**: capping per wallet would reward splitting a holding across cheap 4-pass wallets (strictly +EV), inverting sybil-neutrality. Per-token keeps 8 passes worth the same whether in one wallet or two.
- The draw is O(1) in supply (bounded rejection sampling), so it never gets more expensive as the collection grows. Void-on-miss; the crux is that a pass moved after the freeze pays neither buyer nor seller (the slot re-rolls).

---

## Part 5 - Claiming your prize

Every win writes an onchain **claim** in your name against that game's vault. To collect, you send one transaction within **30 days**: `claim(id)` for one, or `claimBatch([ids])` to sweep all your prizes at once.

- No admin approval, no counterparty. $QUOTRON transfers straight from the vault to you.
- In a batch, an id that isn't yours / is already paid / expired is silently skipped, and a single prize whose payout reverts is skipped and left retryable, so one bad id never bricks the rest.
- Unclaimed after 30 days -> swept back into the vault, rolls into future pots.
- **No-owner-drain:** each vault has one immutable controller (the ClaimManager); the owner can never move funds already owed to winners, nor point a game at the wrong vault (bindings are frozen at launch).

Three vaults, one game each: **prize/raffle vault** (daily raffle), **leaderboard vault**, **holder-draw vault**.

---

## Part 6 - How the randomness works

Every draw is **sealed, then revealed.** The random number that decides an outcome does not exist when you enter; it is a future **drand** beacon (a threshold-BLS network on a fixed 3-second schedule). Because a future round's signature cannot be forged or known early, binding a draw to a future round makes the seed unknowable at entry time.

- The oracle verifies each beacon **onchain** against the BLS12-381 precompiles, so stored randomness is byte-identical to drand's public archive and anyone can recompute it. No trusted relayer.
- The settling beacon for a game reveals **after** its entry/eligibility window closes, so no one can act on the winning number.
- A **keeper** bot is the unattended operator: each tick it posts the due beacons, registers Super Rares at reveal, and triggers the draws. On mainnet drand produces the randomness for free (the keeper only relays and triggers); on the short-clock testnet a mock oracle stands in.

---

## Part 7 - Where the money flows

**Mint proceeds (ETH):** 80% LP / 10% prize seed (to the daily raffle vault) / 10% team + operations.

**Trade tax (the 4% buy / decaying sell), swept by the keeper via `convert()` into $QUOTRON prize inventory:**

| Slice | Share of tax | Funds |
|---|---|---|
| Team + operations | 20% | team + operations |
| Daily raffle | 61.25% | the daily pack raffle pot |
| Leaderboard | 12.5% | the weekly leaderboard pool |
| Holder draw | 6.25% | the weekly holder jackpot |

So **80% of every trade tax becomes prizes**, split across the three games.

---

## Numbers at a glance

| Parameter | Value |
|---|---|
| Art Pass supply | 3,500 max |
| Mint caps (GTD / overflow / public) | 3 / 8 / 20 per wallet |
| Buy tax / sell tax | 4% flat / 20% -> 4% over 48h |
| Launch gate / cooldown / early cap | 1 hour / 2 min / planned 0.25 ETH per buy until 2.5 ETH spent (fixed at deploy) |
| Pack life | 7 days |
| Daily raffle buckets (SR/R/U/C) | 45 / 25 / 20 / 10% |
| Free-entry cap | 10% of the paid window (multi-shot, ~9.09% realized) |
| Free-entry weights (C/U/R/SR) | 1 / 2 / 4 / 8 |
| Leaderboard | top 25, linear pro-rata over all the week's points; weeks end Sunday 00:00 UTC, settled by anyone the following week |
| Holder draw | hold 4+, 5 winning passes (one wallet can win more than one), flat pot/5 |
| Claim window | 30 days (all games) |
| Prize tier bands (pack SR/R/U/C) | 1 / 4 / 15 / 80% |
| Rip XP (C/U/R/SR) | 1.8% of the cohort ticket price x 1 / 2 / 4 / 10 |

**Testnet vs mainnet clocks:** only the *cadence* is compressed on the short-clock testnet (a "day" is 5 min, a "week" is 10 min, the launch gate is 15 min, the mint windows run in minutes). Every economic value (caps, tax, tiers, weights, the 30-day claim window) is identical.

---

## Current state

- **Deployed.** The contracts described here run on Robinhood Chain mainnet (chain id 4663). The Art Pass sold out in September 2026, and the pool was seeded and the games started on 2026-09-22. Every address is listed in [`DEPLOYMENTS.md`](DEPLOYMENTS.md).
- **What the code includes.** The tax is always taken in WETH, draws wait for reveals, the launch window was 1 hour, and rip XP scales with the ticket price. The site trades through its own swap router (`QpullSwapRouter`), the ownership-transfer script pins a SafeL2 1.4.1 or 1.5.0 Safe, and a preflight keeps the 10% prize-seed wallet separate from the deployer key and the team + operations wallet. The launch scripts carry a pinned NFT address for the delegation-only launch, a stack binding for the prize seed, a creation check on the ownership Safe, unit-slip bounds on the ticket price and launch cap, and a scripted oracle deploy; the keeper has bounded transaction waits and a heartbeat; the site pairs wins with claims by event and labels expired prizes.

*This document is a reference, not a promise. The rules on this page are the rules the contracts enforce.*
