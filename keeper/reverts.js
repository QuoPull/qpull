/*
 * Revert decoding and classification shared by keeper.js and keeper-testnet.js.
 *
 * Pure: no provider, no key, no environment, no side effects on import. keeper.js re-exports every name here, so
 * its public API is unchanged. keeper-testnet.js imports the same functions, so a convert floor bisection on the
 * testnet keeper reads a revert exactly as the mainnet keeper does: only a known slippage revert means "the floor
 * is too high", and anything else stops the search.
 */
import { ethers } from "ethers";

/// Custom errors of the contracts this keeper calls or quotes through, so a revert is logged by name.
export const KNOWN_ERRORS = new ethers.Interface([
  // RaffleEngine. AlreadyDrawn and OutsideWindow are also HolderDrawEngine.runDraw's, and OutsideWindow is also
  // LeaderboardEngine.distribute's (same signatures, so one entry decodes all three). OutsideWindow is what a draw
  // whose settlement window closed between its simulation and its send reverts with.
  "error AlreadyDrawn()", "error BadDay()", "error OutsideWindow()", "error OpeningPending()",
  "error OpeningAlreadyDone()", "error Accumulating()", "error TooSoonToForgo()",
  "error PotBelowOpeningFloor(uint256 pot, uint256 floor)",
  // ClaimOutOfGas: all three engines revert with it when a prize registration ran out of the gas the
  // draw forwarded, instead of skipping that winner. Same signature on all three, so one entry decodes them.
  "error ClaimOutOfGas()",
  // LeaderboardEngine
  "error AlreadyDistributed()",
  // PackRegistry. RevealPending: a raffle draw's sweep window holds live packs of `cohortDay` whose
  // shared tier round `revealRound` is not on the oracle; nothing was popped. runDraw and runOpeningDraw both
  // bubble it. NoNft / NotStarted: registerSuperRare before the NFT is bound or launched.
  "error RevealPending(uint32 cohortDay, uint64 revealRound)", "error NoNft()", "error NotStarted()",
  // NFTCollection reveal ladder. The keeper does not call advanceRevealFallback (the permissionless fallback for a
  // reveal round drand never produces), but anyone may, and these say WHY it refused.
  "error RevealRoundNotDue()", "error RevealRoundNotSkipped()", "error RevealAlreadyResolved()",
  // ClaimManager.registerClaim / BaseVault, reachable inside sweepExpired (release). Inside a draw payout every
  // engine now catches them per winner and emits a skip event instead
  "error NotEngine()", "error WrongVault()", "error ZeroRecipient()", "error BadDeadline()",
  // ClaimManager (BindingMismatch), NFTCollection (LaunchLockOutOfGas), BaseVault (the rest)
  "error BindingMismatch(address engine, address declared, address given)", "error LaunchLockOutOfGas()",
  "error NotController()", "error InsufficientFree()", "error ReserveUnderflow()",
  // Treasury
  "error NotConfigured()", "error BelowThreshold()", "error NotKeeper()", "error SwapShortfall()",
  "error AdapterNotContract()",
  // convert() is rate limited. ConvertRateLimited is the one revert in this file the keeper
  // will hit in NORMAL operation if it ever sends two converts in one block, or inside an armed cooldown, so
  // it must decode by name rather than as an unknown selector. It is never a reason to stop: retry next tick.
  "error ConvertRateLimited()", "error CooldownTooLong()",
  // The timelocked QUOTRON-adapter swap. Owner-only, so the keeper cannot send these, but an
  // operator reading a failed Safe transaction through this decoder should get a name.
  "error NoAdapterProposal()", "error TimelockNotElapsed()",
  // QpullWethAdapter / QuotronRouterAdapter (shared signatures listed once)
  "error UnsupportedPath()", "error MinOutRequired()", "error PoolKeyUnset()", "error Slippage()",
  "error NotTreasury()", "error BadBuffer()",
  // Quotron's canonical ETH router (RH mainnet 0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18). buyExactEth reverts
  // with this BEFORE QuotronRouterAdapter's own Slippage check when minQuotronOut is not met, so it is the
  // "floor too high" answer of every leg-2 bisection probe. Observed 2026-09-13 with a read-only eth_call
  // (balance state override, 0.001 ETH in, minQuotronOut 1e30): revert data 0x8199f5f3.
  "error SlippageExceeded()",
  // QpullTaxHook. PartialFill: a WETH-specified taxed swap stopped at its price limit.
  // SwapTooLarge: |amountSpecified| (or an exact-out sell's amt + fee) exceeds int128. RecordOutOfGas: a
  // registry ran out of gas inside a buy, which now reverts the buy instead of charging tax for nothing.
  "error PartialFill()", "error SwapTooLarge()", "error RecordOutOfGas(bytes32 which)",
  "error NotCanonicalPool()", "error Gated()", "error BuyCooldown()", "error EarlyBuyTooLarge()",
  "error NotPoolManager()",
  // QpullV4Quoter
  "error QuoteDidNotRevert()", "error MalformedQuote()",
  // Uniswap v4 PoolManager / Hooks. A hook's revert reaches the caller wrapped in WrappedError.
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
  "error HookCallFailed()", "error InvalidHookResponse()", "error HookDeltaExceedsSwapAmount()",
  "error PoolNotInitialized()", "error CurrencyNotSettled()", "error ManagerLocked()",
  "error SwapAmountCannotBeZero()", "error NoLiquidityToReceiveFees()",
  "error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96)",
  "error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96)",
  // ClaimManager
  "error AlreadySettled()", "error Expired()", "error NotExpired()", "error NotRegistered()",
  // BlsDrandOracle
  "error BadSigLength()", "error BadCompressedForm()", "error CompressionMismatch()", "error InvalidBeacon()",
  "error PrecompileFailed()", "error TimestampBeforeGenesis()", "error PrecompileUnavailable()",
]);

const HOOK_SELECTORS = Object.freeze({
  [ethers.id("beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)").slice(0, 10)]: "beforeSwap",
  [ethers.id("afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)").slice(0, 10)]: "afterSwap",
});

/// One-line explanations for the reverts an operator is most likely to see from convert and quoting.
export const REVERT_HINTS = Object.freeze({
  NotKeeper: "the convert key does not hold the Treasury keeper role",
  NotConfigured: "a Treasury adapter or vault is unset, or a convert cap is not armed",
  BelowThreshold: "nothing to convert (no WETH, and QPULL below convertThreshold)",
  SwapShortfall: "a swap delivered less than its floor (the price moved, or the floor was too tight)",
  Slippage: "an adapter swap returned less than its floor",
  SlippageExceeded: "Quotron's router could not buy minQuotronOut with the prize WETH (the floor was above the pool's output)",
  RevealPending: "a cohort in the draw window has live packs whose reveal round is not on the oracle yet; the keeper posts that round and retries next tick",
  OutsideWindow: "the period's settlement window is not open (it has not started, or it just closed)",
  InsufficientFree: "the prize vault's free balance cannot cover the prize being reserved",
  MinOutRequired: "an adapter was handed a 0 floor",
  PoolKeyUnset: "QpullWethAdapter.setPoolKey has not run",
  PartialFill: "the pool stopped a WETH-specified taxed swap at its price limit, and the hook refuses partial fills",
  SwapTooLarge: "the swap amount exceeds int128",
  RecordOutOfGas: "a buy ran out of gas inside a game registry; resend it with more gas",
  ClaimOutOfGas: "a draw ran out of gas while registering a prize; nothing was paid or skipped, resend it with more gas",
  PoolNotInitialized: "no initialized pool has this key",
  InvalidBeacon: "the relay's signature does not verify for this round",
  ConvertRateLimited: "convert() already ran in this block, or is inside the armed convertCooldown; not an error, retry next tick",
  RevealRoundNotDue: "the reveal round's own publish instant has not passed yet, so it cannot have been skipped",
  RevealRoundNotSkipped: "no LATER beacon is on the oracle, so this round is merely unposted rather than skipped: post it with submitBeacon instead of advancing the ladder",
  RevealAlreadyResolved: "the reveal beacon landed; the reveal can never be re-rolled",
  NoAdapterProposal: "no QUOTRON-adapter swap is proposed",
  TimelockNotElapsed: "the proposed adapter swap is still inside ADAPTER_TIMELOCK (7 days)",
  BindingMismatch: "an engine's own vault() disagrees with the vault lockEngines was handed: the wiring is transposed, fix it BEFORE locking",
  LaunchLockOutOfGas: "the launch transfer-lock hook read was gas-starved rather than broken; resend with more gas",
});

/// True for an eth_call CALL_EXCEPTION. A transport failure (SERVER_ERROR, TIMEOUT), a method missing from an
/// ABI (TypeError) or bad arguments are false. NOT PROOF THE CONTRACT RAN: ethers 6.17 maps every JSON-RPC
/// error object returned for eth_call to CALL_EXCEPTION (provider-jsonrpc.js getRpcError), so a rate-limit or
/// "header not found" reply is true here, indistinguishable from a revert without data. Never use this to
/// decide that a failure is permanent or safe to skip for good.
export function isRevertError(e) {
  return ethers.isError(e, "CALL_EXCEPTION");
}

const bytes32Label = (b) => {
  try {
    return ethers.decodeBytes32String(b);
  } catch {
    return String(b); // not a short string: show the raw word
  }
};

/// Decode raw revert data by name. Unwraps the PoolManager's WrappedError (a hook's revert) to the inner error.
export function decodeRevertData(data, depth = 0) {
  if (typeof data !== "string" || data.length < 10) return "reverted without data";
  let parsed = null;
  try {
    parsed = KNOWN_ERRORS.parseError(data);
  } catch {
    parsed = null; // a known selector with malformed arguments: report the raw selector below
  }
  if (!parsed) return `custom error ${data.slice(0, 10)}`;
  if (parsed.name === "Error") return `"${parsed.args[0]}"`;
  if (parsed.name === "Panic") return `panic ${parsed.args[0]}`;
  if (parsed.name === "WrappedError") {
    const [target, selector, reason] = parsed.args;
    const inner = depth < 4 ? decodeRevertData(reason, depth + 1) : "nested too deep";
    return `${inner} (wrapped: ${HOOK_SELECTORS[String(selector).toLowerCase()] ?? `call ${selector}`} on ${target})`;
  }
  if (parsed.name === "RecordOutOfGas") return `RecordOutOfGas(${bytes32Label(parsed.args[0])})`;
  if (parsed.name === "RevealPending") return `RevealPending(cohort ${parsed.args[0]}, round ${parsed.args[1]})`;
  return parsed.name;
}

/// The cohort and round an engine's RevealPending revert names, or null for any other failure. Accepts
/// raw revert data or an ethers error (its `revert`, when the binding's ABI decoded it, else its `data`).
export function revealPendingOf(eOrData) {
  const fromArgs = (args) => ({ cohort: BigInt(args[0]), round: BigInt(args[1]) });
  if (eOrData && typeof eOrData === "object") {
    if (eOrData.revert?.name === "RevealPending" && eOrData.revert.args?.length >= 2) return fromArgs(eOrData.revert.args);
    return revealPendingOf(eOrData.data);
  }
  if (typeof eOrData !== "string" || eOrData.length < 10) return null;
  try {
    const parsed = KNOWN_ERRORS.parseError(eOrData);
    return parsed?.name === "RevealPending" ? fromArgs(parsed.args) : null;
  } catch {
    return null; // the RevealPending selector with malformed arguments: not a usable round
  }
}

/// A short, human reason for a revert.
export function revertReason(e) {
  const rv = e?.revert;
  if (rv?.name === "Error" && rv.args?.length) return `"${rv.args[0]}"`;
  if (rv?.name === "Panic" && rv.args?.length) return `panic ${rv.args[0]}`;
  if (rv?.name) return rv.name;
  const data = typeof e?.data === "string" ? e.data : null;
  if (data && data.length >= 10) return decodeRevertData(data);
  return e?.reason ? `"${e.reason}"` : "reverted without data";
}

export const reasonName = (reason) => String(reason).split(/[ (]/)[0];

/// `reason` plus its REVERT_HINTS explanation, when there is one.
export function describeRevert(reason) {
  const hint = REVERT_HINTS[reasonName(reason)];
  return hint ? `${reason}: ${hint}` : String(reason);
}

/// How a failed convert() simulation reads during floor bisection:
///   floor    the floor was too high: search lower. SwapShortfall (Treasury), Slippage (either adapter),
///            SlippageExceeded (Quotron's router, which checks minQuotronOut before the adapter does), and the
///            string "slippage" (test/mocks/MockSwapAdapter, the testnet WETH->QUOTRON adapter)
///   abort    convert cannot run for a reason no floor fixes: stop and report it
///   unknown  anything else: an error this file cannot name, or a revert WITHOUT data, which is also what a
///            JSON-RPC error on eth_call looks like (a rate limit, "header not found"). Nothing was learned about
///            the floor, so the caller re-probes once and then ABORTS the bisection (maxFeasible).
const FLOOR_REVERTS = new Set(["SwapShortfall", "Slippage", "SlippageExceeded"]);
const FLOOR_REVERT_STRINGS = new Set(['"slippage"']);
const ABORT_REVERTS = new Set([
  "NotKeeper", "NotConfigured", "BelowThreshold", "MinOutRequired", "PoolKeyUnset", "UnsupportedPath",
  "NotTreasury", "AdapterNotContract", "PartialFill", "SwapTooLarge", "RecordOutOfGas", "PoolNotInitialized",
  "NotCanonicalPool", "ManagerLocked", "CurrencyNotSettled",
  // No floor fixes a rate limit, so this aborts the bisection rather than being read as
  // "unknown" — which is the bucket for reverts WITHOUT data, i.e. what an RPC failure looks like. It is the
  // one abort here that is entirely routine: convert already ran this block (or the armed cooldown has not
  // elapsed), the keeper logs it by name and the next tick proceeds normally. Do NOT treat it as an incident.
  "ConvertRateLimited",
]);
export function classifyConvertRevert(reason) {
  const n = reasonName(reason);
  if (FLOOR_REVERTS.has(n) || FLOOR_REVERT_STRINGS.has(String(reason))) return "floor";
  if (ABORT_REVERTS.has(n)) return "abort";
  return "unknown";
}
