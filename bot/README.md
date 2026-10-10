# qpull-drawbot

Watches the three prize engines and posts **one summary per draw** to X.

**Read-only by construction.** It creates no wallet, signs nothing, and never reads `KEEPER_PK` or
`CONVERT_PK`. If this process were fully compromised, the worst it could do is post text. Keep it
that way: never add a private key to its environment.

## Why summary and not per winner

Per-winner posting is 400+/month, because the leaderboard pays every point holder at once. That
needs a paid X tier and reads as a spam feed. One post per draw is roughly 38/month:

| | per winner | summary |
|---|---|---|
| Daily raffle | 300 | 30 |
| Holder draw | varies | 4 |
| Leaderboard | hundreds | 4 |

## What it posts

    Daily draw, 24 Sep: 0.4874 Quotron to 5 winners.

    Paid from the prize vault, funded by trading activity. Winners claim onchain.
    https://robinhoodchain.blockscout.com/tx/0x...

Preview all three without sending anything: `node drawbot.js --sample`.

## Setup

1. `cp .env.example .env` and fill in `RPC_URL` and the three engine addresses.
2. On developer.x.com, set the app to **Read and write**, then **regenerate the access token pair**.
   A token minted before that change stays read-only and posting returns 403. This is the single
   most common failure.
3. Leave `DRY_RUN=true` and run `npm run once`. It prints what it would post.
4. Set `DRY_RUN=false` only once the copy looks right. The bot refuses to start with `DRY_RUN=false`
   unless all four `X_*` credentials are present.

## Self-test

    node selftest.mjs

Covers the paths a dry run cannot reach, because no draw has fired yet: topic derivation, decoding a
synthetic log for each engine (including a max uint32 day), the percent-encoder, and the OAuth
signature. The signature is cross-checked against an independent implementation, and the three event
signatures are checked against the compiled artifacts in `out/` so a wrong ABI cannot make the bot
silently match nothing.

## Verify your X credentials without posting

    node drawbot.js --check-x

Calls `GET /2/users/me`, which needs exactly the same user-context OAuth a post needs, and prints the
authenticated handle. Nothing is posted. Do this BEFORE a draw so the first live post is not also the
first test. A 403 means the access token pair predates setting the app to Read and write: regenerate it.

## Flags

- `--check-x` verify the X credentials, post nothing
- `--sample` print example posts for all three engines, send nothing, touch no network
- `--once` one pass, then exit
- `--dry` force dry run whatever `.env` says
- `--backfill` on first run, look back ~2.5M blocks instead of starting from now

## Running it on Railway

Same pattern as the keeper. **Attach a volume and point `STATE_FILE` into it**, e.g. mount at
`/data` and set `STATE_FILE=/data/state.json`. Railway's filesystem is otherwise ephemeral, so a
redeploy would lose the record of what was already announced. It cannot double post (a fresh state
starts at the current head rather than re-scanning), but it would silently miss any draw that landed
while it was down.

## State

`state.json` holds `lastBlock` and a `posted` map keyed by `engine:period`. The key is what prevents
duplicates, so re-scanning the same blocks is always safe. Writes are atomic (temp file plus
rename), so a crash mid-write cannot corrupt it.

## Notes

- The RPC rejects wide `eth_getLogs` ranges; 100k blocks is the measured ceiling and the chunk size.
- A failed post is not recorded, so it is retried on the next pass rather than lost.
- The daily draw is titled by date; the weeklies keep their week number.
