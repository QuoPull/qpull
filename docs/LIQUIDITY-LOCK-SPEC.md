# QpullLiquidityLock: Permanent LP Lock

Status: BUILT + unit-tested (`test/QpullLiquidityLock.t.sol`, 25 tests; the go-live paths through it in `test/GoLivePartialBroadcast.t.sol`, `test/regression/GoLiveLpEthUnchecked.t.sol` and the RH mainnet fork suites). Makes "100% of supply to LP, can't rug" a bytecode fact instead of a procedural promise, and, since `seed` now **creates the pool as well**, leaves no launch window for a stranger to stand in.

## Why

The QPULL token mints 100% of supply to the deployer, and the go-live seeds it into the canonical v4 pool. Nothing in the contracts *forced* that liquidity to stay: the hook restricts LP add/remove to the `initializer` (the deployer), but there was **no lock**, the deployer could pull it. `QpullLiquidityLock` closes that.

A second hole was closed in the same contract, and it is the reason `seed` changed shape. The go-live used to broadcast `initialize` and `seed` **five transactions apart**. **A v4 pool with zero liquidity has a price ANY address can walk to an arbitrary value for gas alone:** `SwapMath` returns `amountIn = amountOut = feeAmount = 0` when `liquidity == 0` yet still moves to the step target, `Pool.swap`'s loop therefore always reaches the price limit and writes it to slot0, and `PoolManager._accountDelta` returns early on a zero delta, so nothing is owed. `QpullTaxHook` cannot stop it. When this was found it had no `beforeSwap` (flags `0x1A44`); since the change that takes the tax in WETH on every swap kind it has one (flags `0x1ACC`), but that `beforeSwap` only prices the specified WETH leg of exact-in buys and exact-out sells, an exact-in sell's fee is a share of the pool's WETH output (0 at zero liquidity, so no fee and no `take()`), and the holder gate is `if (isBuy && ...)`, so the sell direction still walks ungated. Anyone could walk the launch price inside that window and make the seed revert, repeatably, for gas, and every token amount an add costs is a pure function of that price. The dangerous part was the tempting recovery: **re-sizing the seed to the walked price passes the consumption band and LATCHES**, entombing nearly the whole LP bucket (about 20.8 of a 21 ETH seed) forever in a contract with no way out. The fix removes the window instead of detecting the attack.

## The mechanism (guarantee = absence of code)

In Uniswap v4 a liquidity position is owned by the address that called `modifyLiquidity` to create it, and **only that owner can ever modify or remove it.** The lock exploits this:

- The lock calls `modifyLiquidity` to seed, so **the lock owns the position.**
- The lock's bytecode contains **no** function that removes, withdraws, collects, or sweeps: no negative `liquidityDelta`, no fee-collect, no token transfer-out, no owner, no setter, no delegatecall, no selfdestruct.
- Therefore **no transaction can ever pull the liquidity**, removal isn't restricted, it does not exist in the code. Verifiable by reading the (small, immutable) contract.

## The lock creates the pool (guarantee = no window)

`seed` calls `poolManager.initialize(poolKey(), sqrtPriceX96)` on the line immediately above the add, in the **same transaction**. That is a security property, not a convenience:

- **No block ever exists in which the pool has a price and no liquidity.** There is nothing to walk, so the band below is computed from a price nobody else could touch.
- **The lock IS the hook's `initializer`**, so `afterInitialize` reverts `NotInitializer` for every other address: no one else can create the canonical pool at all (it also refuses any non-canonical key, and refuses while the pass mint is still open, `MintStillOpen`).
- **`afterInitialize` stamps `launchTime` at the instant liquidity exists.** The 1-hour holder gate and the 48-hour sell-tax decay no longer start ticking against an empty pool.
- **A revert unwinds the pool creation too**, along with the `seeded` latch, so a failed seed can be retried cleanly with a corrected size. `initialize` reverts if the pool already exists, which doubles as the retry guard on a re-run.

The circular dependency, the hook must name the lock, and the lock must name the hook, is broken in `script/Deploy.s.sol` and `script/DeployTestnet.s.sol` by **predicting** the lock's CREATE address with `vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1)`: a CREATE address depends only on `(deployer, nonce)` and **never on constructor arguments**. The hook is mined against that predicted address, the lock is deployed on the very next transaction, and `require(lock == predictedLock, ...)` proves it. **Operational constraint: the hook deployment and the lock deployment must stay adjacent in the script.** Any extra deployer transaction between them shifts the nonce and the hook's `initializer` would point at a dead address, an unrecoverable brick. The `require` fails in **simulation**, so a drifted nonce costs a re-run, never a broadcast.

## Removal is impossible at the pool as well as absent from the lock

- **The lock** has no removal code (above). That is still the guarantee.
- **The hook** now refuses too: `beforeRemoveLiquidity` reverts `LiquidityRemovalDisabled` **unconditionally, for every caller including the lock**, with no branch and no privileged exception. The `BEFORE_REMOVE_LIQUIDITY` bit (`1 << 9`) is part of the mined hook address (`0x1ACC` since the hook gained a `beforeSwap` to take the tax in WETH on every swap kind; it was `0x1A44` when this landed).
- The refusal closes a **round trip**: add liquidity untaxed, let taxed swaps push the position through its range, withdraw untaxed, and QPULL has moved at 0% instead of 4%. Killing the return leg collapses it, and removing the need to identify anyone on the way out is what let the `tx.origin` branch be deleted from the add gate.
- That round trip could never reach the *locked* position in the first place: v4 keys every position by `owner: msg.sender`, so a contract phished into calling `modifyLiquidity` operates on its **own, empty** position and underflows. The hook's refusal does not protect the lock; it upgrades "can't rug" from a property of one contract's source to a property the pool enforces on everyone.
- **ACCEPTED CONSEQUENCE, and it belongs in every description of LP policy: the canonical pool's depth is FIXED FOREVER at whatever the launch seeds. No liquidity can ever be added or removed again.**

## Decisions (locked)

- **Permanent, no removal ever.** No timelock escape hatch. Strongest guarantee; matches the immutable/ownerless ethos. This is enforced twice over: the lock has no remove path, and the hook refuses removal for everyone (see above), which fixes pool depth at the seeded amount permanently.
- **LP fees stay with the position, never collected.** The pool's 0.30% Uniswap LP fee (distinct from the protocol's 4% trade tax) accrues to the locked position and is deliberately never harvested: there is no collect path. This keeps the contract to a single entrypoint (easy to verify by reading); the 4% trade tax funds the prize games separately. Leftover token dust after seeding also stays locked.
- **The `initializer` is a contract, not a key.** The mitigation previously on record, treat the initializer EOA as a launch-only key and retire it after go-live, was never achievable: that key owns the Treasury, the NFT, all three engines, both registries, `ClaimManager`, the three vaults and both adapters, with live ongoing duties. `QpullTaxHook._onlyProtocolLp` is now a plain `if (sender != initializer) revert LiquidityRestricted();`, **the `tx.origin` branch is GONE**, so there is no EOA in the gate to phish and none left to retire.
- **The launch price and liquidity are DERIVED, never typed** (see Sizing below).

## Interface (the entire surface)

- `seed(uint160 sqrtPriceX96, uint128 liquidity, uint256 expectedQpull, uint256 expectedWeth)`, the ONE state-changing entrypoint. `opener`-only, one-shot (`AlreadySeeded` latch, set **before** the interactions). It CREATES the pool at `sqrtPriceX96`, adds full-range `liquidity` from the contract's own balance, and refuses to latch unless the add actually **cost** `expectedQpull` and `expectedWeth` to within ±50 bps per side. Requires the lock pre-funded with QPULL + WETH by the opener, and requires the pool NOT to exist yet. Rejects `liquidity == 0` (`ZeroLiquidity`), `sqrtPriceX96 == 0`, and an `expected*` of zero or above `type(uint128).max` (`BadExpectedInput`, a v4 `BalanceDelta` is a pair of `int128`, so a larger expectation is unsatisfiable by construction and the tolerance arithmetic below stays overflow-free).
- `unlockCallback(bytes)`, v4 callback, pool-manager-only; reachable only via `seed`, always a positive add. Returns what the add cost in `(qpull, weth)` order, mapped through the pair's sort order.
- Views: `poolKey()`, `seeded`, `tickLower/tickUpper`, immutables. No others.
- Event: `Seeded(sqrtPriceX96, liquidity, tickLower, tickUpper, qpullConsumed, wethConsumed)`.
- Errors: `NotOpener`, `AlreadySeeded`, `NotPoolManager`, `ZeroAddress`, `ZeroLiquidity`, `BadTickSpacing`, `BadExpectedInput`, `SeedConsumptionOutOfBand(address token, uint256 consumed, uint256 expected)`. **`ResidualStranded` no longer exists**, the band is a consumption test now, not a leftover test.

Immutables: `poolManager, qpull, weth, fee, tickSpacing, hook, opener`, full-range ticks (aligned to `tickSpacing`; the constructor rejects `tickSpacing` outside v4's `[1, 32767]` with `BadTickSpacing`, because it is divided by and a larger value can never create a pool), `qpullIs0`. Constants: `MAX_RESIDUAL_BPS = 50`, `BPS_DENOM = 10_000`.

## The consumption band (measured on what the pool CHARGED)

`liquidity` is caller-supplied and the token amounts it consumes depend entirely on the pool price, which the lock never checked; whatever the add does not consume is stranded here forever, because the missing withdrawal path IS the guarantee. So `seed` takes the two `expected*` amounts as the opener's declaration of what it funded, and `_assertConsumed` reverts `SeedConsumptionOutOfBand` unless the add cost that ±`MAX_RESIDUAL_BPS` (50), **on both sides and in both directions** (under-consuming strands the difference; over-consuming means the declaration did not describe the add that happened).

**The measurement is CONSUMPTION, not LEFTOVER, and that distinction is load-bearing.** A leftover test, post-add `balanceOf(this)` against a pre-add snapshot, tests a number any third party can move: the lock's address is public from the transaction that deploys it, the seed lands blocks later, and a plain ERC-20 transfer in between inflates the leftover while the pool charges exactly the same amount. Roughly 0.5% of the WETH side (about 0.106 ETH against a 21 ETH launch) would have been enough to revert the seed for good, with 100% of supply already inside a contract that cannot hand it back. What the pool **charges** is not donatable: it is fixed by `liquidity`, the price and the tick range, and it is reported by the pool manager's own `BalanceDelta`, which `unlockCallback` returns to `seed`. An unsolicited transfer into the lock can no longer decide whether the launch happens; it just joins the locked position's dust.

This bound used to live in `GoLiveMainnet._assertSeeded` as `MAX_LOCK_RESIDUAL_BPS`, which is `internal view` and therefore ran **in simulation only**. It is now a property of the lock's bytecode and runs during the real broadcast.

## Sizing is derived, not typed

`SQRT_PRICE_X96` and `LP_LIQUIDITY` (and testnet's `SQRT_PRICE` / `LP_LIQUIDITY`) **are no longer inputs anywhere.** `script/LpSizing.sol` derives both from the amounts actually being seeded:

- `sqrtPriceX96 = sqrt(amount1 / amount0) * 2**96`, via `FullMath.mulDiv`'s 512-bit intermediate (`amount1 * 2**192` overflows `uint256` on its own at any realistic supply), bounds-checked against `TickMath`'s min/max price.
- `liquidity = LiquidityAmounts.getLiquidityForAmounts(...)` over the lock's own full-range tick bounds, read from `lock.tickLower()` / `lock.tickUpper()`.
- `sizeFor` does the **currency sort itself**, so the launch price cannot be seeded inverted.

Why: **no `LP_ETH` / `SQRT_PRICE` / `LP_LIQUIDITY` triple recorded anywhere in this repo satisfied the 50 bps band.** The one rehearsed testnet run was 322.6 bps off on the WETH side (silently stranded under the old code), and the mainnet values were left blank. Setting the price to the ratio of the two sides is what makes both sides consume fully; any other price consumes one side and strands the other.

For reference, the derived mainnet numbers for a 1e27 supply against 21 ETH (the realized sell-out bucket is 20.85 ETH, so the real numbers differ), with QPULL sorting first, are `sqrtPriceX96 = 11481251519025279852052291` and `liquidity = 144913767461894385737186`. **These are COMPUTED at go-live time, they are not values anyone types in.**

## Deploy / go-live wiring

`Deploy.s.sol` and `DeployTestnet.s.sol` deploy the lock (`opener = deployer`) immediately after the mined hook and print it as `LiquidityLock`. **`LOCK` is a required env input to both go-live scripts**, alongside the existing addresses.

`GoLiveTestnet` and `GoLiveMainnet` no longer deploy a lock of their own and **no longer call `poolManager.initialize` at all.** Each preflight-checks the wiring (`hook.initializer() == LOCK`, `lock.opener() == msg.sender`, `!lock.seeded()`; mainnet additionally re-checks the lock's pair, pool manager, fee and tickSpacing against the hook's key), derives the price and liquidity with `LpSizing`, funds the lock and calls `lock.seed`, the one transaction that creates the pool and adds the liquidity. They differ in what they declare:
- **`GoLiveTestnet`** wraps `LP_ETH` and transfers it plus the deployer's entire QPULL balance, then calls `lock.seed(sqrtPriceX96, liq, qpullIn, LP_ETH)`.
- **`GoLiveMainnet`** declares `lock.seed(sqrtPriceX96, liq, totalSupply, LP_ETH_WEI)`, never a balance. `LP_ETH_WEI` must equal the mint's LP bucket plus a declared `LP_TOPUP_WEI`. It funds only the shortfall (WETH the lock already holds counts, and WETH left in the deployer by an interrupted wrap is sent first), so a WETH donation to the lock can neither block the launch nor move its price: WETH above `LP_ETH_WEI` is not seeded and strands here, logged. Preflight requires 100% of supply in the deployer and the lock, so no one else can donate QPULL before the seed.

**Mainnet:** `script/GoLiveMainnet.s.sol` is the reviewed mainnet twin. It seeds **100% of supply** (the deployer's entire QPULL balance plus the LP WETH) through `QpullLiquidityLock` and enforces the post-conditions onchain in the same broadcast: `lock.seeded() == true`, the position keyed `(lock, tickLower, tickUpper)` holds exactly the derived liquidity and equals the pool's whole liquidity, deployer residual QPULL `== 0`, `hook.launchTime() != 0`, and both convert caps armed. The old simulation-only residual block (`MAX_LOCK_RESIDUAL_BPS`, and the `BPS` constant with it) has been **removed**: the equivalent bound is enforced inside the lock during the real broadcast, against what the pool charged. The script now only *reports* whatever QPULL/WETH dust remains in the lock; it does not gate the seed on it. `LiquiditySeeder` was deleted outright, a deployer-owned position is a removable position.

## How to verify onchain (the "can't rug" proof)

1. The lock's source has no remove/withdraw/collect/sweep function (read it), and `QpullTaxHook.beforeRemoveLiquidity` reverts for everyone.
2. `hook.initializer() == lock`, so the lock is the only address that could ever have created this pool or added to it.
3. `lock.seeded() == true` and the pool holds the launch liquidity.
4. The position at `(lock, tickLower, tickUpper)` holds it, and no other address can modify it (v4 ownership).
5. Deployer residual QPULL ≈ 0 (all supply went into the lock's position).
6. The `Seeded` event reports what the add actually consumed, per token, next to the declared amounts in the same transaction.

## Tests

`test/QpullLiquidityLock.t.sol` (25, against a deterministic PoolManager stub): seed adds + latches, one-shot, opener-only, callback pool-manager-only, no remove/withdraw/collect selectors exist, constructor zero-guards and `BadTickSpacing`, full-range tick alignment; the consumption-band group (`test_f1_*`: under-consume, over-consume, dust inside the band, immunity to an unsolicited donation before the seed, under-funding, degenerate declarations, no-latch-on-failure + retry, consumption mapped to the right token in both sort orders, and the ±50 bps edge pinned one wei either side on both legs); and the pool-creation group (`test_seed_createsThePoolInTheSameTransaction`, `test_seed_failedSeedLeavesNoPoolAndCanRetry`, `test_seed_rejectsZeroPrice`).

Hook side: `test_evenTheInitializerCannotRemoveLiquidity` (an **inversion** of an earlier test that asserted the initializer could remove liquidity, which passed while certifying that the protocol could withdraw liquidity untaxed, the round trip described above), `test_routerCannotAddEvenWhenTheInitializerSignsIt`, `test_nonInitializerCannotRemoveLiquidity`.

New harness `test/utils/V4LpBase.sol`: because the LP gate is now `sender == initializer` and `sender` for a v4-core test router is **the router**, every hook test that seeded through `PoolModifyLiquidityTest` was only ever admitted by the `tx.origin` branch, the same branch this change removed. The test contract is now the initializer and the LP, which is the production shape. The fork test does the same with `V4LiquidityHelper`, which creates the pool and provides its liquidity from one contract.

**Not yet rehearsed on a live network:** the atomic create-and-seed shape. It runs against Robinhood's real PoolManager on a mainnet fork (`test/fork/LaunchSeedFork.t.sol`, `test/fork/GoLiveMainnetFork.t.sol`); the earlier testnet run seeded through the old two-transaction path with a hand-typed triple that was 322.6 bps off on the WETH side.

## Open

- A live testnet run of the new `seed(sqrtPriceX96, liquidity, expectedQpull, expectedWeth)` against a real PoolManager (create + add + band, in one transaction).
- **CLOSED:** mainnet go-live script adopts the lock: `script/GoLiveMainnet.s.sol` seeds 100% of supply through `QpullLiquidityLock` with the onchain post-conditions listed above.
- **CLOSED:** deployer residual QPULL `== 0` post-seed is asserted onchain by `GoLiveMainnet` (`require`, not a manual read-back after the broadcast).
- **CLOSED:** the empty-pool price walk: `seed` creates the pool itself, in the same transaction as the add, so the price the sizing depends on never exists in a block a stranger can act in.
- **CLOSED:** the untaxed add-and-remove round trip, structurally. `_onlyProtocolLp` is a plain `sender != initializer` check with no `tx.origin` branch, the `initializer` is this lock rather than an EOA, and `beforeRemoveLiquidity` reverts for everyone. **An earlier plan, retiring the initializer EOA after go-live, is superseded and was never achievable; the gate does not admit `tx.origin`.**
- **CLOSED:** the residual bound is onchain and runs in the real broadcast, measured from the pool manager's `BalanceDelta`. `GoLiveMainnet`'s simulation-only `MAX_LOCK_RESIDUAL_BPS` assert and constants were removed; **the script itself no longer gates the seed on a stranded residual; that bound lives in the lock.**
- **CLOSED:** hand-typed launch sizing: `script/LpSizing.sol` derives the price and the liquidity from the amounts being seeded and sorts the currencies itself.
