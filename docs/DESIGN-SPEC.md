# QuoPull design specification (v2)

**Status:** The v2 design handoff (27 August 2026), revised 2026-09-13 so that the mechanics it states match the
contracts. The design rationale is kept; where the built protocol differs, this document now says what was
built. For the player-level rules read `docs/PROTOCOL-WALKTHROUGH.md`; the contract source is authoritative
over both documents.
**Chain:** Robinhood Chain mainnet
**Date:** 27 August 2026 (mechanics updated 2026-09-13)
**Supersedes:** v1 (see §0 changelog)

> **What was built differs from the original v2 design in these ways:**
> - **Draws are DAILY**, not hourly; a pack (ticket) is live for **7 days** (7 daily shots). Each day a fixed
>   **K winners** is drawn from a sliding 7-day cohort window, O(K) regardless of ticket count, fully on-chain.
> - **The standalone jackpot was removed.** Its slice became the **weekly holder draw** (5 passes, flat pot/5,
>   hold 4+ Art Passes). Sells earn no entries of any kind.
> - **The tax is a Uniswap v4 hook**, not a token transfer tax: 4% on buys, a launch sell tax decaying 20% to 4%
>   over 48h, always taken in WETH. `QPULLToken` is a plain ownerless ERC-20.
> - **Split of all tax:** daily raffle 61.25% / leaderboard 12.5% / holder draw 6.25% / team + operations 20%.
> - **Leaderboard pays linearly pro-rata** over all of the week's points (the square-root weighting was removed
>   as sybil-positive).
> - **The launch NFT is a 3,500-pass mint** split 80/10/10, and the launch holder gate is **1 hour**.

---

## 0. What changed from v1

The design change recorded on 27 August 2026. The jackpot and the square-root leaderboard in the right-hand column were later replaced (see the list at the top).

| Area | v1 | v2 (this doc) |
|---|---|---|
| QUOTRON's role | A *position*, held/hardwired to earn Quotron's fees (the "alignment premise") | **Pure prize inventory.** Bought only to pay out as raffle prizes. No position, no hardwire, no burn. |
| Hardwire / ERC-404 | Whole section on hardwiring, exemption, sweep/distribute tension | **Deleted.** `hardwire()` is an explicit opt-in call we simply never make. Holding QUOTRON fires nothing. |
| Strategy bucket (3 pts) | "Buy QUOTRON to hold, vault/resale or top-100 distribution" | **Reallocated to prizes** (see §3). |
| Ticket issuance | "Packs proportional to size" (vague) | **Fixed whole-ticket schedule** with a minimum and remainder banking (§4). |
| Sells | Only buys emit packs (implicit) | **Two-sided tax, one-sided core rewards.** Buys mint raffle tickets + leaderboard points; sells pay tax and earn *jackpot* entries only (§4, §10, §11). |
| Payout distribution | Split pot by drawn-ticket weight; flat 20% per-draw cap | **Fixed tier-bucket model** (§7). SR = 45% of the pot; per-tier bucket replaces the flat cap. |
| Secondary games | none | **Pari-mutuel weekly jackpot** (§10) **and √-weighted buys-only loyalty leaderboard** (§11), both from launch. |
| §11.1 (fee gating) | BLOCKING | **Informational**, the alignment story it protected is gone. |

---

## 1. Summary

QPULL is a token-funded pack-raffle protocol. Buying QPULL incurs a 4% tax and selling it a 4% tax (20% decaying to 4% over the first 48h), taken in WETH. That tax is converted into **$QUOTRON**, which the protocol holds **solely as prize inventory** and pays out, fractionally, to winners.

Every QPULL **purchase** emits packs. Packs are tickets. Tiers are sealed at purchase and revealed against a future drand beacon. Once per day, tickets are drawn; a drawn ticket pays out fractional $QUOTRON from that day's pot, divided across tiers by a fixed budget (§7). A **weekly holder draw** (§10) pays five Art Passes held by 4+ pass wallets, and a **buys-only loyalty leaderboard** (§11) pays linearly by points each week.

**Design premise (revised):** QUOTRON is not a position, it is the payout currency. The protocol buys it to give it away. This routes real volume through Quotron's pool (a genuine benefit to their ecosystem) but makes no claim to *earn* Quotron's fee stream. "Hold for raffles," nothing more.

**The one law behind every reward mechanic:** *every ticket-reward must be negative-EV to farm.* Topping any pool must cost more in tax than it pays out. Get that right and wash-trading stops being a threat and becomes voluntary tax, a farmer who can't extract more than they put in is just funding the prizes. Every guard in this document is that one law.

---

## 2. Token and tax

| Parameter | Value |
|---|---|
| Buy tax | 4%, always |
| Sell tax | 20% at launch, stepping down 4 points every 12h to 4% at 48h, then 4% |
| Where it is taken | `QpullTaxHook`, a Uniswap v4 hook on the one canonical QPULL/WETH pool |
| Tax currency | WETH, on every swap kind |
| Chain | Robinhood Chain |

The hook takes the tax inside the swap and sends it to the Treasury as WETH, where it waits until the keeper
converts it to QUOTRON (§3). **Both sides are taxed; only buys earn raffle tickets and leaderboard points** (§4).
`QPULLToken` has no transfer hook, so a separate QPULL/WETH pool without this hook trades untaxed and feeds no
game; all protocol liquidity sits in the canonical pool behind a permanent lock.

---

## 3. Fee split

QUOTRON is prize inventory, so 80% of every tax becomes prize buys and 20% goes to team + operations. The split
is applied by `Treasury.convert()` to the aggregate, whatever side of the trade the tax came from:

| Bucket | Share of tax | `Treasury` constant | Funds |
|---|---|---|---|
| Daily raffle | 61.25% | `RAFFLE_BPS = 6125` | the daily pack raffle vault |
| Weekly leaderboard | 12.5% | `LEADERBOARD_BPS = 1250` | the leaderboard vault |
| Weekly holder draw | 6.25% | `HOLDER_BPS = 625` | the holder-draw vault |
| Team + operations | 20% | `TEAM_BPS = 2000` | paid as WETH |

**Conversion cadence.** Do not buy per transaction. The keeper accumulates WETH and converts in pool-sized slices
(`maxWethConvertPerCall`), each with an off-chain slippage floor from Quotron's View quoter. Each conversion pays
Quotron's dynamic pool fee, so batching matters.

---

## 4. Ticket issuance, fixed, buys-only

**Principle: randomize the prize, never the entitlement.** How many tickets your money buys is *fixed and predictable*; only the tier and the draw are random (§6). Randomizing issuance would feel like a scam and would invite gaming.

### The schedule

Tickets are minted **only on buys**, as **whole units** by floor division:

```
tickets = floor(buyValue / TICKET_PRICE)
```

The minimum buy to earn a ticket *is* `TICKET_PRICE`. Below it: no ticket (dust).

| Buy (gross) | Tickets | Note |
|---|---|---|
| < TICKET_PRICE | 0 | dust, no ticket |
| 1× TICKET_PRICE | 1 | minimum |
| 2.5× | 2 | 0.5× remainder |
| 10× | 10 | |
| 100× | 100 | |

**Remainder banking.** The sub-ticket remainder (the 0.5× above) accrues per-address toward the buyer's next ticket, rather than being dropped. Fairer, and it avoids the "I bought just under the line and got nothing" complaint. One extra storage slot per address.

Leaderboard points (§11) are **WETH wei, not tickets**: a buy banks its hook credit (the WETH it actually paid, backed by the WETH tax the same swap took), and a final non-winning ripped pack banks rip XP (`RIP_XP_BPS` = 1.8% of its cohort's ticket price × its rarity weight 1/2/4/10). Both land in the same weekly pool.

### Denomination, RESOLVED (§13.4): WETH-in value, bounded owner re-peg

The buy hook prices tickets off the **ETH going IN to a buy** (the hook's `credit`: the WETH the buyer actually paid, capped at fee × BPS / TAX_BPS of the WETH tax taken in the same swap), not the QPULL received and not a USD oracle. A ticket costs **N WETH wei of ETH-in value**, seeded at deploy to the ETH worth **~$10 at launch** (target: $10 → 1 ticket, $100 → 10, $10k → 1,000). Because the basis is the spend and not the QPULL amount, pool depth and slippage never change how many tickets a given spend earns, and pumping the pool cannot mint extra tickets. To hold ~$10 as ETH's USD price moves, the owner re-pegs `ticketPrice`, but only within hard, on-chain bounds: **≤ ±25% per change, ≤ once per day** (`setTicketPrice`).

Why not a live USD peg: QPULL's only on-chain price source is its own pool, so any contract reading it to price tickets is manipulable in a single tx (pump the pool → mint extra tickets), the exact grind vector we forbid. The bounded manual re-peg gives a real ~$10 peg with **no oracle and no per-tx price read**; between adjustments the game stays fair regardless, because tickets *and* prize-funding both scale with WETH volume (tickets from the WETH a buy pays, prize funding from the WETH tax), so the farm-EV ratio is price-invariant.

| Option | Oracle? | Verdict |
|---|---|---|
| **WETH-in value (hook credit) + bounded re-peg** | No | ✅ **Chosen**, holds ~$10, no pool-price read, every credited wei paid the WETH tax |
| QPULL amount + bounded re-peg | No | ✗ pool depth, slippage or a pump change how many tickets a spend earns |
| USD hard peg (live) | **Yes** | ✗ single-tx pool manipulation → mint-farm |
| USD soft peg (unbounded admin) | No | ✗ unbounded knob = rug/brick lever |

Bounds are public constants (`MAX_ADJ_BPS = 2500`, `ADJUST_COOLDOWN = 1 day`); the owner is meant to be the launch Safe (threshold >= 2, no timelock), and the ±25% band and the 1-day cooldown are the delay. Caveat: a sharp QPULL *crash* opens a brief +EV window (cheap new tickets vs. an already-funded pool); it is transient and limited by the daily raffle's fast distribution.

**Recommendation:** ETH-denominated with a governance-set soft peg, unless a reliable price feed on Robinhood Chain is confirmed (same class of unknown as §13.2). Do not take a USD-literal promise to market until the feed exists.

### Sells

Sells pay the sell tax and earn **no raffle tickets, no leaderboard points and no entries of any kind**. This is deliberate:
- Reinforces **buy > hold > sell**, the only way to play the raffle *or* climb the board is to buy.
- Closes the wash-trade hole, if sells minted raffle tickets or board points, round-trips could farm.
- Still captures sell value, the sell tax swells the prize pools regardless.

### Issuance curve

Straight-proportional (linear) issuance means a whale's single large buy can dominate a given day's cohort; the 7-day ticket life (§5) bounds accumulation over *time* but not *within* a day. What shipped: linear, with `maxTicketsPerBuy` (default 100, ceiling 200) bounding one buy's gas, the excess value banked for later buys.

---

## 5. Packs and tickets

- Packs are uncapped. Every purchase emits packs per §4.
- A pack **is** a ticket. There is no separate ticket object.
- Tiers: Common, Uncommon, Rare, Super Rare.
- Tier is sealed at purchase, revealed at the next beacon (§6). **No re-roll.**
- A ticket is live for **7 days** from purchase (≈7 daily draws), then expires unclaimed and unusable.
- A drawn ticket is spent, one draw, one payout, ticket burned.
- Payouts are **fractional $QUOTRON only.** Whole units are never transferred to winners.

*(Leaderboard points are a separate cumulative tally and are unaffected by ticket expiry or burning, see §11.)*

Expiry keeps odds legible. Without it, hour 400's buyers compete against every ticket ever minted and new-buyer odds decay toward zero.

---

## 6. Randomness, drand

All raffle and holder-draw randomness comes from drand, verified on-chain by `BlsDrandOracle`. Nothing derives entropy from block data; no operator holds a secret that affects outcomes. This governs the daily raffle draws (§7), each pack's tier, the pass reveal, and the weekly holder draw. *(The leaderboard is deterministic, pro-rata by points, and needs no randomness.)*

**Why not commit-reveal:** whoever holds the secret sees the outcome first and can withhold the reveal. drand is external, scheduled, and unforgeable by anyone including the team.

### Sealed-then-revealed

On purchase, the contract records the pack against a **future** drand round. That round has not published; nobody can know the outcome. This defeats simulate-and-revert: if tier resolved inside the buy tx, a bot could simulate, see a Common, and revert before settlement, free re-rolls funded by honest buyers.

### Derivation

One beacon verification per round, many outcomes derived from it:

```
tier(packId)      = keccak256(beacon, packId)
draw(day, j)      = keccak256(beacon, drawDay, j)       // PackRegistry._drawCore
```

**Critical:** `packId` must be in the hash. Hashing the beacon alone, or with anything shared across packs, gives every pack in that window the same tier. Cheap bug, very visible failure.

### Verification

Beacon, packId, and hash function are all public. Any player can recompute any outcome. Expose a "verify this rip" affordance in the UI: it is why the Drand complexity is worth paying for. A draw never runs before the reveal beacon of every cohort it can draw from is onchain: it reverts `RevealPending` and waits, so no winner is ever left without a tier.

### Independent events

Rarity rolls, daily draw pulls, and holder-draw selection are separate attack surfaces and must be derived separately.

---

## 7. Epoch accounting & the tier-bucket distribution

**Cadence: daily.** The epoch pot is the product, and it has to feel like a prize. Splitting the raffle's fixed share of tax across *more* draws shrinks each pot, hourly (168/wk) makes each pot 24× smaller than daily (7/wk), so at realistic early volume an hourly pot is too thin to screenshot. Daily concentrates the money into pots that land, and it's cheaper to run (7 keeper draws/week, 7 cohorts). Frequency can be revisited once volume proves out; you can't un-dilute a pot that's too thin.

### On-chain draw model (implemented)

The draw is **fully on-chain**, the contract computes winners, so claims are one click with no proofs, and the chain is the sole authority (no off-chain results-poster).

- **Fixed-K draw.** Each day the contract draws exactly **K winners** from the live set (O(K), independent of how many tickets exist), then buckets those K by tier and splits each tier's pot among however many of the K landed there. K and the tier odds are parameters.
- **Cohort expiry.** Tickets are grouped by the day bought. A cohort minted on day *D* is eligible for the draws on days *D+1…D+7* (7 shots), then falls out of the sliding window, expiry is free, no per-ticket cleanup.
- **Pot & rollover.** `P` = the vault's free QUOTRON snapshotted at draw time; unpaid tier buckets simply stay in the vault and swell the next day's `P` (the Super-Rare climb).
- **Void-on-miss (§14).** A day is drawable only during the following day; miss it and its pot stays in the vault. No catch-up.

*(Implemented in `PackRegistry.sol` + `RaffleEngine.sol`; fuzz-tested for distinctness, window correctness, and solvency.)*

### Snapshot mechanism

1. At epoch open, snapshot the vault's **free $QUOTRON balance** (excluding `unclaimedReserve`, §8) and lock it as that epoch's distributable `P`.
2. Fees arriving mid-epoch accrue to the **next** snapshot, never the current one.
3. Draws in the epoch distribute `P` by the tier-bucket model below.
4. At epoch close, any undistributed remainder (including empty buckets) rolls into the next snapshot.

Snapshot the QUOTRON balance, not an ETH-denominated value. The payout unit must be the asset actually held, so price movement between snapshot and claim cannot create a shortfall.

### The tier-bucket model

`P` is carved into **fixed per-tier buckets**. This is "the distribution", it is the same every day, so payouts are *consistent by construction*, and it makes Super Rare *feel special* because a large, fixed share of the pot flows to a rare few.

| Tier | Mint odds | Pot bucket | Relative payout / winning ticket |
|---|---|---|---|
| **Super Rare** | 1% | **45%** | **~360×** a Common |
| Rare | 4% | 25% | ~50× |
| Uncommon | 15% | 20% | ~11× |
| Common | 80% | 10% | 1× |

*(Odds and the lower-tier buckets are tunable parameters; SR concentration is locked at 45% per design. "Relative payout" = bucket ÷ mint-odds, normalized to Common.)*

**Rules:**
- Each day, the tickets **drawn** within a tier split that tier's bucket. Every live ticket is equally likely to be drawn; the tier only chooses the bucket.
- If a tier has **no winner that day, its bucket stays in the vault** and swells the next day's pot. For Super Rare, rare by construction, this means a **climbing grand prize**.
- The **per-tier bucket replaces the flat 20% per-draw cap.** A lone Super Rare winner takes at most the SR bucket (45%); the other 55% is guaranteed to the lower tiers. No thin-day drain, but SR still gets to be huge.

### Why this model

- **Fixed amount** ("Rare pays 0.05 QUOTRON") can go insolvent when tier luck runs hot on a low-volume day. Public failure on a provable-fairness protocol.
- **Fixed fraction of the whole pot per ticket** cannot break but cannot be marketed and dilutes unpredictably with draw count.
- **Tier-bucket** gives a true, verifiable, on-screen structure, *today: SR pot X, Rare pot Y…*, that is structurally impossible to overdraw, because only an already-held balance is ever distributed, and each tier is capped at its budget.

Consistency comes from the fixed buckets + the snapshot; the *upside excitement* comes from the Super Rare rollover.

---

## 8. Claims, pull, not push

Drawing a ticket **writes a claim.** It does not transfer. The winner claims when they choose. This applies to daily raffle wins, holder-draw wins, and leaderboard payouts alike.

| Parameter | Value |
|---|---|
| Claim window | 30 days |
| Unclaimed after window | Rolls into next epoch pot |
| Storage | `mapping(ticketId => claimable)` |

**Accounting requirement.** Track `unclaimedReserve` separately from vault balance. Every pot, daily raffle (§7), holder draw, leaderboard (§11), must count only genuinely free QUOTRON, or the protocol promises a pot that includes prizes already owed. This is the one accounting bug that would let a pot be over-stated.

Push payouts over a winner set are a gas sink and a griefing surface (a reverting recipient blocks the loop). Straight per-ticket mapping is correct at this scale.

---

## 9. Quotron integration

Quotrons is an ERC-404 protocol on Robinhood Chain: 4,444 terminals, one canonical QUOTRON/WETH pool, 3% base fee, burn-to-hardwire. We touch it **only** to buy prize inventory.

### Buy flow

1. Quote with the **real payer address** before every swap
2. Apply slippage bounds and a deadline
3. Execute the swap
4. Vault receives QUOTRON

Do not interact with PoolManager directly or construct hook data by hand unless the fork probe (§13.1) proves it necessary.

### ERC-404, collapses to one line

The v1 hazard is gone. **Hardwiring is an explicit, opt-in call (`hardwire(id)`) that we never make.** Holding QUOTRON, whole or fractional, fires no burn, no hardwire, nothing automatic; a "dark terminal" just sits inert. And contract-holding is a supported, normal thing: **Quotron's own QUOTRON/WETH pool is a contract that holds QUOTRON**, so a vault holding it is fine.

Therefore: **the vaults hold QUOTRON as prize inventory and pay fractional prizes. They never call `hardwire`.** That's the whole ERC-404 story. No exemption fight, no sweeping, no receiver gymnastics. (One cheap sanity check remains, §13.3.)

Note: reflections accrue **only to hardwired terminals**, so holding earns nothing. That is exactly consistent with "hold for raffles only"; there is no yield to design around.

### Addresses

**Pull every address from the official Quotrons builders manifest.** Do not hardcode any address from prior conversation, including the router address that circulated in early drafts, it is unverified and must not reach production.

---

## 10. Weekly holder draw (replaced the jackpot)

The 14-day pari-mutuel jackpot in the original v2 design was removed before launch. Its tax slice (6.25%) funds
the **weekly holder draw** (`HolderDrawEngine`): 5 distinct Art Passes are drawn each week from the drand beacon
by bounded rejection sampling, each paid a flat `pot / 5`, and a pass is eligible only if its owner has held 4+
passes continuously since that week's freeze (`qualifiedSince`, `ownerSince`). Selection is per pass, so
splitting a holding across wallets gains nothing. The draw is O(1) in supply. Void-on-miss: a week is drawable
only during the following week, and an unpaid pot stays in the vault. See `docs/PROTOCOL-WALKTHROUGH.md`
Part 4c.

---

## 11. Leaderboard, weekly, buys-only loyalty board

The deterministic, skill/commitment-based secondary game. Rewards the wallets that buy the most, distributes real value back to the community's top players.

### Mechanism

- **Points** are **WETH wei** (§4): a buy's hook credit, plus rip XP for final non-winning ripped packs, tallied cumulatively over the weekly period, independent of ticket expiry/burning. Sells earn none.
- **Pot** = the leaderboard vault's free balance when the week is distributed, capped per week at `potCap` (`LeaderboardEngine.distribute`). The vault is funded with **12.5% of all trade tax** (`Treasury.LEADERBOARD_BPS = 1250`; 0.5% of volume at the flat 4%), buys and sells alike, converted to QUOTRON. Anything not paid out rolls forward.
- **Distribution:** at period close, the **top 25 wallets by points** are paid **linearly pro-rata**: each board member's share is its points over ALL of that week's points (`LeaderboardRegistry.totalPoints`), so the board collectively receives its fraction of the week's points and the rest stays in the vault. √-weighting was replaced because it is sybil-positive; linear weighting is sybil-neutral. No randomness, no Drand.
- **Payout:** written as a claim (§8). Points reset for the next period.

### Why buys-only, and why linear

A deterministic board is the *most* farmable shape we have: there is no variance to discourage grinding. What
keeps it honest as built:
- **Buys-only points** (plus rip XP for non-winning packs): a point is backed by WETH tax the same buy paid
  (credit = fee × 25, capped at the WETH paid), so a point costs about 3.9% of its value in tax once rip XP is
  counted, and a same-transaction pump and dump cannot buy points cheaper than that.
- **Linear pro-rata over ALL of the week's points** (`LeaderboardRegistry.totalPoints`), not over the board:
  splitting a wallet cannot raise its share. The pot is capped per week (`potCap`) and funded by
  12.5% of all tax, and whatever is not paid stays in the vault.

---

## 12. Contract architecture

| Contract | Responsibility |
|---|---|
| `QpullTaxHook` | Uniswap v4 hook on the canonical QPULL/WETH pool: takes the tax in WETH, credits buys to the two registries, launch holder gate and throttle, LP gate; immutable |
| `QPULLToken` | Plain, ownerless, fixed-supply ERC-20 (no transfer tax) |
| `QpullLiquidityLock` | Creates the canonical pool and seeds it in one transaction; no removal path |
| `QpullSwapRouter` (periphery) | The website's buy and sell: ETH in and out, exact input, taxed like any swapper, credit to the signer, no owner; deployed by `Deploy.s.sol` (mainnet) and `GoLiveTestnet` (testnet) |
| `Treasury` | Holds the WETH tax, converts it to QUOTRON through two adapters, splits 61.25 / 12.5 / 6.25 / 20 |
| `PackRegistry` | Mints packs on buys (§4), banks remainders, seals tiers to a future drand round, daily fixed-K draw, virtual free entries for passholders, rip XP |
| `LeaderboardRegistry` | Tallies points per wallet per Sunday-aligned week (§11) |
| `BaseVault` ×3 | Raffle, leaderboard and holder-draw prize inventory; `unclaimedReserve` solvency; one immutable controller |
| `RaffleEngine` | Runs the opening draw and the daily draws, distributes tier buckets, writes claims |
| `LeaderboardEngine` | Weekly linear pro-rata distribution, writes claims |
| `HolderDrawEngine` | Weekly holder draw, writes claims |
| `BlsDrandOracle` | Verifies drand quicknet beacons on-chain (EIP-2537) and stores them |
| `ClaimManager` | Claim redemption for all games, 30-day expiry, sweep back to the vault |
| `NFTCollection` | The launch Art Pass mint (§16) and its on-chain rarity |

Separation matters most between the **balance-holding** contracts (the three vaults) and the **outcome-determining**
contracts (the three engines): they are separate addresses, each engine bound to exactly one vault and the map
frozen by `ClaimManager.lockEngines()`. No hardwire engine exists.

---

## 13. Open items, resolve before build

### 13.1 Is Quotron's 3% pool-side or router-gated? **[RESOLVED, router-gated]**

The official Quotrons manifest lists a **Canonical ETH router** (`0x42…1C18`) + **Canonical WETH fee hook** + **View quoter**, with the token/hook/router *jointly enforcing* the QUOTRON/WETH pool. So swaps go through **their canonical router** (router-gated). The Treasury's WETH→QUOTRON `ISwapAdapter` targets that router; the fee hook charges its 3% automatically (we never call it directly). No architecture change.

### 13.2 BLS12-381 precompile on Robinhood Chain **[RESOLVED, precompile is LIVE]**

Verified 2026-08 via `script/bls_precompile_check.sh` against the RH public RPC (`https://rpc.mainnet.chain.robinhood.com`, chain ID 4663): the **EIP-2537 BLS12-381 precompile set is live** (G1ADD present + correct; pairing precompile executing). → drand beacons can be verified **fully on-chain**, build the trustless `BlsDrandOracle` and retire the `CommitteeDrandOracle` fallback.

drand network: **quicknet**, scheme `bls-unchained-g1-rfc9380` (sigs on G1, pubkey on G2), period 3s. Verification = hash-to-curve to G1 (RFC 9380, `sha256`/`MAP_FP_TO_G1`) + a pairing check against the group public key; randomness = `sha256(signature)`. This is specialist crypto, validate against official test vectors before mainnet.

### 13.3 ERC-404 dark-terminal receipt **[RESOLVED]**

QUOTRON (`0x5a86…0D7F`) is a **custom ERC-404** ("QUOTRONS", 18 decimals, 1,786 whole units) with a transfer-exemption list (`erc721TransferExempt(address)`) but **no self-service setter**, exemption is owner-gated (ask the Quotron team pre-launch if desired). We don't depend on it: contracts can hold QUOTRON (the canonical pool does), and **`BaseVault` now implements `onERC721Received`**, so any whole-unit terminal mint into a vault cannot revert. Terminals held are inert (never hardwired). Optional cleanliness: request owner-exemption so vaults hold pure ERC-20 with no terminal NFTs.

### 13.4 Ticket denomination / price feed, RESOLVED

**WETH-in value with a bounded owner re-peg** (see §4). `ticketPrice` is WETH wei, the ETH-in VALUE of a buy (the hook's `credit`), NOT QPULL base units. It is seeded to ~$10 of ETH at launch and held near $10 by `setTicketPrice`, bounded on-chain to ≤ ±25%/day, ≤ once per day. No price feed is used, a live USD oracle off QPULL's own pool would be a single-tx manipulation vector, and pricing off the QPULL amount received would let pool depth or a pump change ticket issuance; the ETH-in basis avoids both. Set `TICKET_PRICE_WETH` at deploy from the launch ETH price (e.g. `0.003 ether` = ~$10).

---

## 14. Failure modes

| Mode | Cause | Mitigation |
|---|---|---|
| Pot over-stated | Snapshot counts owed prizes | `unclaimedReserve` tracked separately (§8) |
| Epoch drained by one pull | No per-tier cap | Tier buckets *are* the cap (§7) |
| Identical tiers in a window | Beacon hashed without packId | `keccak(beacon, packId)` (§6) |
| Free re-rolls | Tier resolves in buy tx | Sealed-then-revealed (§6) |
| Odds decay to zero | Tickets never expire | 7-day ticket life (§5) |
| Ticket farming (raffle) | Sells mint raffle tickets | Buys-only issuance (§4) |
| Wash-trading for credit | Credit priced off something a pump inflates | Credit derived from the WETH tax the same swap paid (§11) |
| Leaderboard farming | Deterministic top-N pays > cost | Linear pro-rata over all of the week's points, a per-week pot cap (§11) |
| Winner with no tier | Draw fired before a cohort's reveal beacon | Draw reverts `RevealPending` and waits (§6) |
| Leaderboard rank bought via sells | Sells feed a redistributive pool | Buys-only points (§4, §11) |
| Insolvent payout | Fixed-amount prizes | Tier-bucket snapshot model (§7) |
| Claim blocked | Push payouts to reverting recipient | Pull claims (§8) |
| Keeper timing advantage | Catch-up draws on published beacons | Void policy (§15) |

---

## 15. Keeper

A keeper bot (`keeper/keeper.js`) posts the drand beacons, registers Super Rares, runs the opening and daily raffle draws, the weekly leaderboard distribution and holder draw, converts the tax, and sweeps expired claims. Every one of those calls except `convert()` is permissionless. See `keeper/README.md`.

**Missed-draw policy: void.** If a draw (daily or weekly) does not fire, RPC failure, keeper down, beacon unavailable, that slot is **void**; the undistributed amount rolls into the next epoch/week. **Do not build catch-up**, catch-up lets a keeper choose *when* to fire a draw whose beacon has already published, reintroducing the timing advantage drand exists to remove. Void must be an explicit, documented rule.

**The keeper cannot affect outcomes, only whether and when a scheduled event executes.** Any keeper input that reaches a hash is a bug. (The leaderboard distribution is deterministic, so a missed run inside its window is simply re-runnable against the same period data, no timing advantage exists there.)

---

## 16. Launch, NFT-funded, no team LP capital

The launch is bankrolled by a **3,500-pass Art Pass mint** (`NFTCollection`), not team capital.

**The mint (a "pack rip").** Fixed ETH price (0.0075 ETH), a tiered time-boxed sale (GTD 6h, overflow 18h, public
24h, closing at a fixed 48h), and rarity **Common / Uncommon / Rare / Super Rare** (odds 70 / 20 / 8 / 2), sealed
at `finalizeLaunch()` to a future drand round and revealed fully on-chain. Each mint **auto-splits** its ETH on
chain **80% LP / 10% prize seed / 10% team + operations**; `withdrawProceeds()` pays the buckets to three frozen,
distinct recipients.

**NFT perks (utility, not a dividend, the dividend was rejected as a security):**
- **Free daily raffle entries**, the virtual model (`docs/PLEDGE-ENTRY-SPEC.md`): registered Super Rares enter
  automatically at weight 8, and Common / Uncommon / Rare passes enter for a day when their owner pledges them, at
  weight 1 / 2 / 4. The free block is **capped at 10% of the live paid window**, so it is **VOLUME-DEPENDENT**: on
  a low-volume day holders receive fewer free seats, or none, and nothing is guaranteed. **This must be specified
  as volume-dependent in the Terms & Conditions and all docs.**
- **Weekly holder draw** for wallets holding 4+ passes (§10).
- **Buys in the first hour after pool creation are NFT-holders-only** (`QpullTaxHook.GATE_DURATION()`, 1 hour),
  with a per-wallet 2-minute cooldown and a 0.25 ETH per-buy cap until the wallet has spent 2.5 ETH, and a
  transfer lock on a gated buyer's passes for the rest of the hour.

**Go-live sequence:**
0. Before anything else, create the two wallets no script creates: the seed wallet `SEED_TREASURY` (a separate
   regular wallet, funded for gas, before `DeployNFT.s.sol`, which preflights it) and the launch Safe (a SafeL2
   1.4.1 or SafeL2 1.5.0 proxy from the matching factory, no module, before `Deploy.s.sol`).
1. Deploy the on-chain art renderer, the quicknet `BlsDrandOracle`, and `NFTCollection` (`DeployNFT.s.sol`). Open
   the mint once; it runs and closes on its own; `finalizeLaunch()` seals rarity.
2. Deploy the protocol (`Deploy.s.sol`): the hook, the liquidity lock, Treasury, vaults, registries, engines and the
   site's `QpullSwapRouter`.
3. `GoLiveMainnet.s.sol`: withdraw the LP bucket, fund the lock, create and seed the pool in one transaction
   (100% of QPULL supply plus the LP ETH, locked forever), rehearse `convert()`, freeze routing.
4. `SeedRaffleVault.s.sol`, from `SEED_TREASURY` (a separate regular wallet used only for the prize seed, not the
   deployer key and not the team + operations wallet): buy the 10% prize seed into the daily raffle vault as QUOTRON,
   right after go-live and before the opening draw at `GENESIS + 48h`. Then hand ownership of the 13 ownable
   instances to the launch Safe (`TransferOwnership`, accept in the Safe, prove with `VerifyOwnership`).
5. Day 2 onward: the one-time opening draw, then daily raffle draws (each day drawn during the following day).
   Weekly: leaderboard distributions and the holder draw.

Tickets are live for 7 days (7 daily shots). `GENESIS` is set to the planned seed time.

---

## 17. Compliance

Terms and conditions with click-to-agree will carry the relevant disclosures, including Quotron's own US restriction on stock-token swaps, and the raffle and holder-draw lottery framing. Implement the gate as a hard precondition to purchase, not a footer link. (Note: with hardwiring cut, the protocol no longer handles tokenized-stock rewards, that compliance surface is gone.)
