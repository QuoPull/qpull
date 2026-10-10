# Mainnet pot sizing (`*_MIN_POT`, `*_POT_CAP`)

Derived 2026-09-12 against the LIVE Quotron pool. **Re-derive before deploying**, every number below is
a function of the QUOTRON price, which moves.

## The input that makes this urgent

    1 QUOTRON = 2.6676 ETH

Read from the canonical view quoter `0xb8960fdC8A0Be155d196C2795b75747763562df2` on chain 4663
(`quoteBuyExactEth(1e16, addr)` -> 3748643795499224, feeBps 300). QUOTRON total supply is 1,411 tokens,
which is why one is worth this much. **`minPot` is denominated in QUOTRON base units, so `1e18` is not
"one unit of dust", it is 2.67 ETH.**

## What the testnet placeholder would do at launch

The testnet deploys carry `minPot = 1e18` on all three engines. The three engines start very differently,
so the failure looks different in each.

**The 2.6 ETH prize seed funds the DAILY RAFFLE ONLY.** `NFTCollection` has no split logic: `withdrawProceeds`
(sent by `GoLiveMainnet`) pays the seed bucket as ETH to `seedTreasury` (a separate regular wallet used only for
the prize seed, never the team + operations wallet; `DeployNFT` preflights it), and `script/SeedRaffleVault.s.sol`,
run from `seedTreasury` right after go-live and before the opening draw, buys QUOTRON with it straight into
`RaffleEngine.vault()` (one `buyExactEth`, floored at the View quoter's quote less `SEED_SLIPPAGE_BPS`,
default 1%). Holder and leaderboard are NOT seeded and do not need to be:
each accumulates tax before its first settlement can run. The holder draw's first week is a full 7 days from
`GENESIS`. The leaderboard's weeks are Sunday-aligned (`weekAnchor` is the most recent Sunday 00:00 UTC at or
before `GENESIS`), so its FIRST week runs only from `GENESIS` to the next Sunday boundary and can be anywhere
from a few hours to 7 days long; size `LEADERBOARD_MIN_POT` against that shorter first week, or
accept that it may void. The daily raffle accumulates for `ACCUM_DAYS` (48h) before its one-shot opening draw.

    raffle       2.6 ETH seed = 0.9747 QUOTRON, + 48h of tax, opening pot = 10% of vault = 0.2600 ETH
    holder       starts at ZERO, + 7 days of tax   (0.25% of trade volume)
    leaderboard  starts at ZERO, + 7 days of tax   (0.50% of trade volume)

| `minPot` | = ETH | raffle opening | holder: volume needed in its first 7 days | leaderboard: same, over a full week (its first week may be shorter) |
|---|---|---|---|---|
| **1.0** (testnet placeholder) | 2.6676 | **waits** | **1,067 ETH** | **534 ETH** |
| 0.02 | 0.0534 | pays | 21 ETH | 11 ETH |
| 0.01 | 0.0267 | pays | 11 ETH | 5 ETH |

At `1e18` the seed is 10x too small to open the raffle, and the two weekly engines need four-figure ETH
volume in week one or they void. At 0.01 to 0.02 the raffle opens off the seed alone and the weekly engines
clear their floor on volume that is plausible on day one.

### The opening draw WAITS, it is not lost

Worth being precise, because the failure mode is gentler than it looks. `runOpeningDraw(bool
forgoIfUnderfunded)` with `false` **reverts** (`PotBelowOpeningFloor`) rather than forgoing, and
`keeper.js` passes `false` deliberately ("NEVER consent to forgoing the opening. Only a human,
deliberately, after the grace day"). `FORGO_GRACE_DAYS` must also elapse before forgoing is permitted at
all. So an underfunded opening is DEFERRED until the vault grows, the prize is not destroyed.

What is genuinely lost under a too-high floor is every DAILY draw in the meantime: those take the
void-on-miss branch, which does not consume the day or burn tickets, but pays nobody.

Note `openingMinPot` and `openingCapBps` are snapshots of the same constructor args as `minPot`/`capBps`
(set in the `RaffleEngine` constructor), tunable only before `ACCUM_DAYS`. `RAFFLE_MIN_POT` therefore sets both the
opening floor and the daily floor, there is no separate opening env var. The opening splits 5 ways
(`OPENING_WINNERS`), the daily 10 (`WINNERS_PER_DAY`).

## Recommended values

    RAFFLE_MIN_POT=10000000000000000          # 0.01 QUOTRON  = 0.0267 ETH
    RAFFLE_POT_CAP=10000000000000000000       # 10 QUOTRON    = 26.7 ETH  (backstop behind RAFFLE_CAP_BPS)
    RAFFLE_CAP_BPS=1000                       # 10%/day, unchanged, this is the primary ceiling
    WINNERS_PER_DAY=10                        # unchanged

    HOLDER_MIN_POT=10000000000000000          # 0.01 QUOTRON  = 0.0267 ETH
    HOLDER_POT_CAP=5000000000000000000        # 5 QUOTRON     = 13.3 ETH
    HOLDER_POT_CEILING=100000000000000000000  # 100 QUOTRON   = 267 ETH, IMMUTABLE, see below

    LEADERBOARD_MIN_POT=20000000000000000     # 0.02 QUOTRON  = 0.0534 ETH (2x: pot splits up to 25 ways)
    LEADERBOARD_POT_CAP=10000000000000000000  # 10 QUOTRON    = 26.7 ETH

### Why these

- **`minPot`'s only job** is to stop a day/week consuming its tickets for a payout not worth winning. At
  0.01 QUOTRON the raffle's smallest bucket (Common, 10% of pot) still pays each winner ~0.00044 ETH.
- **Leaderboard is set 2x higher** because its pot divides across up to 25 seats, where the others pay 10
  and 5. Same per-winner floor, different divisor.
- **`HOLDER_POT_CEILING` is immutable** and can never be raised after deploy, only `HOLDER_POT_CAP` moves,
  and only up to the ceiling. Set it far above any plausible pot. 100 QUOTRON is deliberate headroom, not
  a target.
- **Runway check:** at 0.01 QUOTRON the raffle's 2.6 ETH seed alone funds **22 consecutive daily draws at
  ZERO trade volume** (the vault decays 10%/day geometrically, and it holds the whole seed). That is the
  window the participation flywheel has to start in. At `1e18` the raffle never opens at all.
- **Holder and leaderboard need no seed**, they accumulate for their first period before their first
  settlement (7 days for the holder draw; up to 7 days for the Sunday-aligned leaderboard). The only question
  for them is whether `minPot` is reachable on that period's real volume: 11 ETH and 5 ETH respectively over a
  full week at these values, versus 1,067 and 534 at `1e18`.
- **`HOLDER_POT_CAP` is a weekly sizing knob.** `HolderDrawEngine` pays each weekly pot as
  `min(freeBalance, potCap)`. The owner can move `potCap` by at most 25% per change and at most once a week, never above the immutable
  `HOLDER_POT_CEILING` (100 QUOTRON, about 267 ETH at these values).

## The canary test

`test/fork/PotSizingFork.t.sol` runs this whole calculation against the LIVE Quotron pool on every
`forge test`, so the sizing cannot drift unnoticed:

- `test_seedAloneOpensTheRaffle`, the seed's opening pot must clear `RAFFLE_MIN_POT`. Currently **9.95x
  headroom**, so the floor holds until QUOTRON reaches ~26 ETH (a 10x move).
- `test_weeklyEnginesClearTheirFloorsOnFirstWeekVolume`, holder and leaderboard must clear their floors on
  one week of `WEEK1_VOLUME_ETH` (default 50 ETH). Both clear with ~4.8x headroom.
- `test_liveQuoteMatchesARealFill`, buys real QUOTRON through the real router and checks the quote the
  sizing rests on against an actual fill. Measured exact to the wei.
- `test_report_breakEvenQuotronPrice`, asserts nothing; prints the price at which the floors stop working
  and the current margin, for whoever runs the launch.

All four take their floors from env (`RAFFLE_MIN_POT`, `HOLDER_MIN_POT`, `LEADERBOARD_MIN_POT`,
`WEEK1_VOLUME_ETH`), so you can try a candidate set without editing the test.

**IF ONE OF THESE FAILS IT IS PROBABLY NOT A CODE REGRESSION.** They read a live market. A failure means
the QUOTRON price moved far enough that the floors no longer fit, and the fix is to re-derive them below,
not to debug the contracts. The assert messages say so.

## Checklist item

Before `Deploy.s.sol`, re-read the QUOTRON price and re-derive, rather than copying these or the testnet
values. One line:

    cast call 0xb8960fdC8A0Be155d196C2795b75747763562df2 \
      "quoteBuyExactEth(uint256,address)(uint256,uint256,uint256,uint256)" \
      10000000000000000 0x0000000000000000000000000000000000000001 \
      --rpc-url https://rpc.mainnet.chain.robinhood.com

`0.01 ETH / (first return field / 1e18)` is the ETH price of one QUOTRON. Every `minPot` above is
`<target pot in ETH> / <that price> * 1e18`.
