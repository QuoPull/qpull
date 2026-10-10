# Hosting the keeper so it runs on its own

The keeper is one long-running program (`node keeper.js`, the loop). Once it is hosted it does every job by itself:
drand beacons, cohort reveals, the opening and daily raffles, the holder and leaderboard draws, the expired-claim
sweep and the tax convert. The only ongoing task is keeping its two wallets topped up with gas.

Three rules for any host:
1. **Exactly one copy** of the primary keeper, ever. Two copies with the same keys fight over nonces.
2. **Never asleep.** It has no web traffic, so any "sleep when idle" setting must be off.
3. **Restart on any exit.** A crash or a host restart brings it straight back; it resumes from the chain.

Do not run it from cron (Vercel Cron, GitHub Actions, crontab): a scheduled `--once` keeps no state between runs and
never sends `convert()`. See README "Run".

## Before you start

- **Two new hot wallets you create yourself**: the draw key (`KEEPER_PK`) and the convert key (`CONVERT_PK`). Fund
  them on Robinhood Chain with a little ETH: draw key above **0.02 ETH**, convert key above **0.005 ETH** (its
  LOW BALANCE alarms fire below those). Keep the balances modest; they are hot wallets.
- **The convert key must be the Treasury keeper** (`Treasury.setKeeper`), which the launch steps do before
  `GoLiveMainnet`. The keeper checks `Treasury.isKeeper` at startup and before every convert.
- **The contract addresses** from the launch deploy (`Deploy.s.sol` output): `TREASURY`, `RAFFLE_ENGINE`,
  `LEADERBOARD_ENGINE`, `HOLDER_ENGINE`, `PACK_REGISTRY`, and `NFT_COLLECTION`
  (`0xE423E4565EC9196f5B3e1319Aa7175a82A00D858`).
- **An RPC URL.** The public node `https://rpc.mainnet.chain.robinhood.com` works. A dedicated RPC provider key is more
  reliable, but never reuse a website read key: a domain-locked key only answers requests from the site's own origin.

## Railway (recommended, about 15 minutes, once)

1. railway.com → sign in with GitHub → **New Project** → **Deploy from GitHub repo** → your copy of this repository (`<your-account>/<your-repo>`).
   When GitHub asks, give Railway access to that one repository only.
2. Open the new service → **Settings**:
   - **Root Directory**: `keeper`
   - **Config file** (config as code): `/keeper/railway.json` if Railway did not pick it up by itself. It sets the
     start command `node keeper.js` and the restart policy **Always**; `.node-version` pins Node 24.
   - Check by hand: Start command `node keeper.js` · Restart policy **Always** · **1 replica** ·
     **Serverless / app sleeping OFF** · no public domain (Networking: none needed).
   - **Watch Paths**: `/keeper/**`, so website commits do not restart the keeper.
3. **Variables** → Raw editor → paste, with your values:
   ```
   RPC_URL=https://rpc.mainnet.chain.robinhood.com
   KEEPER_PK=
   CONVERT_PK=
   TREASURY=
   RAFFLE_ENGINE=
   LEADERBOARD_ENGINE=
   HOLDER_ENGINE=
   PACK_REGISTRY=
   NFT_COLLECTION=0xE423E4565EC9196f5B3e1319Aa7175a82A00D858
   INTERVAL_SECONDS=60
   ENABLE_CONVERT=simulate
   VIEW_QUOTER=0xb8960fdC8A0Be155d196C2795b75747763562df2
   CONVERT_SLIPPAGE_BPS=100
   ```
   Paste the two keys yourself. Everything else in `.env.example` has a safe default; leave it unset.
4. **Deploy**, then open **Logs**. Expect `QPULL keeper online`, then a `heartbeat:` line every 5 minutes.
   A `FATAL CONFIG` line names the setting to fix.
5. **Turn convert on.** Leave `ENABLE_CONVERT=simulate` until the log shows
   `convert [simulate]: ... simulation SUCCEEDS; spot guard clear`, then change it to `true`. Railway redeploys by itself.

## Day to day

- **Gas.** The only recurring task. The log prints a LOW BALANCE alarm when a key drops under its floor. Check the
  two balances every week or two, or set up a scheduled weekly balance check that notifies you.
- **Is it alive?** The `heartbeat:` line every 5 minutes. No heartbeat means it is not running (it cannot report its
  own death).
- **Updates.** A commit that changes `keeper/` on `main` redeploys it; the keeper resumes from the chain.
- **Stop it.** Service → Settings → remove the service, or set replicas to 0.

## Never

- Never run a second primary copy. A backup copy may only run `node keeper.js --failsafe` (permissionless jobs,
  no convert) under a **different** key, on a different host.
- Never deploy from your laptop with `railway up`: deploy from GitHub, so the local `keeper/.env` never leaves your
  Mac. Never commit `keeper/.env`.
- Never put large balances on the keeper keys.

## Render (alternative)

New → **Background Worker** → repo `<your-account>/<your-repo>` → Root Directory `keeper` → Build `npm ci` →
Start `node keeper.js` → Instance **Starter** → Environment: the same variables as above → Create. Background
workers never sleep and restart automatically. Same rules: one copy, keys pasted by you, convert on after simulate.
