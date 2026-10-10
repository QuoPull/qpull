// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { QPULLToken } from "../src/QPULLToken.sol";
import { Treasury } from "../src/Treasury.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { LeaderboardEngine } from "../src/LeaderboardEngine.sol";
import { HolderDrawEngine } from "../src/HolderDrawEngine.sol";
// TESTNET-ONLY short-clock subclasses (10-min holder/leaderboard cadence). Never deployed to mainnet.
import {
    HolderDrawEngineTestnet,
    LeaderboardEngineTestnet,
    LeaderboardRegistryTestnet,
    RaffleEngineTestnet,
    PackRegistryTestnet,
    NFTCollectionTestnet,
    QpullTaxHookTestnet
} from "../src/testnet/TestnetShortClock.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { IPoolManager, PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { HookMiner } from "./HookMiner.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";

// Testnet stand-ins for the mainnet-only externals (QUOTRON / WETH / Quotron router).
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockWETH } from "../test/mocks/MockWETH.sol";
import { MockSwapAdapter } from "../test/mocks/MockSwapAdapter.sol";
import { MockDrandOracle } from "../test/mocks/MockDrandOracle.sol";

/// @notice ONE-COMMAND Robinhood Chain TESTNET deploy (chain 46630). Deploys the mock externals,
///         the NFT, the full protocol, and wires everything exactly like the mainnet Deploy.s.sol
///         (per-vault engine bindings, constructor minPots, keeper gate, adapter binding), then seeds
///         the prize vaults with mock QUOTRON. Run once and sign:
///
///           forge script script/DeployTestnet.s.sol --rpc-url $RH_TESTNET_RPC \
///             --private-key $KEY --broadcast
///
///         The V4 PoolManager is REAL on testnet (0x8366…0951, same as mainnet), so the hook + pool are
///         exercised against real infra. QUOTRON / WETH / the Quotron router do NOT exist on testnet, so
///         this deploys mocks for them. Two steps stay MANUAL (they are inherently interactive) and are
///         printed at the end: (1) mint the NFT (the raise), (2) GO-LIVE = create the pool + seed LP.
///
/// @dev    Env overrides (all optional; sane testnet defaults otherwise):
///           POOL_MANAGER, MOCK_ORACLE(=true for a settable MockDrandOracle instead of BlsDrandOracle),
///           MINT_PRICE_WEI, TICKET_PRICE_WETH, INITIAL_SUPPLY, WINNERS_PER_DAY, REVEAL_DELAY,
///           POOL_FEE, POOL_TICK_SPACING, HOLDER_MIN_POT, HOLDER_POT_CAP,
///           HOLDER_POT_CEILING, VAULT_SEED (mock QUOTRON minted to each prize vault), CONVERT_THRESHOLD
///           (D18{QPULL}, default 10_000e18, >= 1e18 as on mainnet; GoLiveTestnet also requires it to quote >= 1e12
///           wei at the seed price, as GoLiveMainnet does), EARLY_BUY_CAP_WEI (default 0.25 ether).
contract DeployTestnet is Script {
    struct D {
        address me;
        address poolManager;
        address quotron;
        address weth;
        address wethQuotron;
        address oracle;
        address nft;
        address token;
        address treasury;
        address prizeVault;
        address leaderboardVault;
        address holderDrawVault;
        address claimMgr;
        address packs;
        address leaderboardReg;
        address raffle;
        address leaderboardEng;
        address holderDrawEng;
        address adapter;
        address hook;
        address lock; // QpullLiquidityLock: the hook's initializer AND the only ever LP
    }

    struct Cfg {
        uint256 mintPrice;
        uint256 ticketPrice;
        uint256 initialSupply;
        uint256 winnersPerDay;
        uint256 capBps; // daily vault fraction, bps
        uint256 revealDelay;
        uint256 genesis;
        uint256 holderMinPot;
        uint256 raffleMinPot;
        uint256 leaderboardMinPot;
        uint256 rafflePotCap; // required (> 0) at construction
        uint256 leaderboardPotCap; // required (> 0) at construction
        uint256 holderPotCap;
        uint256 holderPotCeiling;
        uint256 vaultSeed;
        uint24 poolFee;
        int24 poolTickSpacing;
        bool mockOracle;
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.mintPrice = vm.envOr("MINT_PRICE_WEI", uint256(0.0075 ether)); // launch price: 0.0075 ETH
        c.ticketPrice = vm.envOr("TICKET_PRICE_WETH", uint256(0.003 ether)); // ~$10 of ETH-in per ticket (value-based)
        c.initialSupply = vm.envOr("INITIAL_SUPPLY", uint256(1_000_000_000e18));
        // WINNERS_PER_DAY is REQUIRED. It was vm.envOr(..., 30), so an unset var
        // silently shipped 30 winners/day — never a decided value, and absent from .env.example
        // entirely. That is a config seam whose wrong value is invisible at runtime.
        // Launch value is 10 (a Super Rare wins ~1 day in 10 and takes 45% of pot solo at that k).
        c.winnersPerDay = vm.envUint("WINNERS_PER_DAY");
        // REQUIRED, no default (same reasoning as WINNERS_PER_DAY): a silent fallback on a value that
        // sizes every payout is just as invisible. 1000 = 10%%/day of the vault; RaffleEngine caps it at 5000.
        c.capBps = vm.envUint("RAFFLE_CAP_BPS");
        // 2 minutes, NOT the mainnet 1 hour. PackRegistryTestnet/NFTCollectionTestnet compress
        // MIN_REVEAL_DELAY to 1 minute and derive MAX_REVEAL_DELAY from the 5-minute DAY(), because a
        // mainnet-sized delay puts a cohort's tier round PAST the pack's own 35-minute life -- under a real
        // oracle that is every paid winner skipped, forever. The old 1-hour default now reverts at
        // construction rather than deploying something unsettleable, which is the right failure, but the
        // default a testnet script hands you should simply be correct.
        c.revealDelay = vm.envOr("REVEAL_DELAY", uint256(2 minutes));
        // GENESIS defaults to the PLANNED GO-LIVE, not to deploy time. The opening accumulation window is
        // days [0, ACCUM_DAYS) = the first 10 minutes on the 5-minute testnet day. Anchored at deploy time it closed
        // before the ~17-minute mint had even started, so the opening draw always ran over empty cohorts 0 and 1,
        // and neither the paid opening nor the rip hold-back could be rehearsed. The lead covers what has to
        // happen before go-live: single-phase (no NFT_ADDR) = delegation setup + openAllowlistMint (inside the 1h
        // reserve fuse) + the ~17m mint + finalize + reveal, default 1800 s; phase 2 (NFT_ADDR, the mint already
        // closed) = just the go-live run, default 300 s. Run GoLiveTestnet at or just after GENESIS and buy inside
        // its first 10 minutes. GENESIS (absolute) still overrides; GENESIS_LEAD_SECS overrides the lead.
        {
            uint256 lead = vm.envOr(
                "GENESIS_LEAD_SECS", vm.envOr("NFT_ADDR", address(0)) == address(0) ? uint256(1800) : uint256(300)
            );
            c.genesis = vm.envOr("GENESIS", block.timestamp + lead);
        }
        c.holderMinPot = vm.envOr("HOLDER_MIN_POT", uint256(1e18));
        c.raffleMinPot = vm.envOr("RAFFLE_MIN_POT", uint256(1e18)); // required (> 0)
        c.leaderboardMinPot = vm.envOr("LEADERBOARD_MIN_POT", uint256(1e18));
        // All three engine potCaps are required (> 0) at construction; testnet defaults well above
        // minPot (1e18) and the seeded pots (VAULT_SEED, 1_000e18) so draws pay out fully.
        c.rafflePotCap = vm.envOr("RAFFLE_POT_CAP", uint256(1_000_000e18));
        c.leaderboardPotCap = vm.envOr("LEADERBOARD_POT_CAP", uint256(1_000_000e18));
        c.holderPotCap = vm.envOr("HOLDER_POT_CAP", uint256(1_000e18));
        c.holderPotCeiling = vm.envOr("HOLDER_POT_CEILING", uint256(10_000e18));
        c.vaultSeed = vm.envOr("VAULT_SEED", uint256(1_000e18));
        c.poolFee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        c.poolTickSpacing = int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60))));
        // This script builds the short-clock *Testnet subclasses, so it is testnet-only by construction:
        // default to the settable MockDrandOracle (keeper posts reveal beacons on the fast clock) and
        // hard-forbid a mock on mainnet regardless of env, so reveals can never silently fail to wire.
        c.mockOracle = vm.envOr("MOCK_ORACLE", true); // run() refuses chainid 4663 outright
    }

    function run() external {
        // Testnet-only. It deploys mock QUOTRON/WETH/router, derives recipients from the deployer and
        // locks routing to them in the same broadcast. Mainnet is Deploy.s.sol + GoLiveMainnet.s.sol.
        require(block.chainid != 4663, "DeployTestnet is testnet-only; mainnet (4663) uses Deploy.s.sol");
        Cfg memory c = _cfg();
        D memory d;
        d.me = msg.sender;
        d.poolManager = vm.envOr("POOL_MANAGER", 0x8366a39CC670B4001A1121B8F6A443A643e40951); // real on testnet

        vm.startBroadcast();

        // 1. mock externals (testnet stand-ins)
        d.quotron = address(new MockERC20()); // QUOTRON stand-in (prize inventory)
        d.weth = address(new MockWETH());
        d.wethQuotron = address(new MockSwapAdapter(1e18, 1e18)); // WETH->QUOTRON, 1:1

        // 2-PHASE LAUNCH: if NFT_ADDR + ORACLE_ADDR are provided, this is PHASE 2 — reuse the phase-1
        // (already-minted-and-CLOSED) NFT + its oracle, and c.genesis defaults to block.timestamp + 300 s so the
        // game clock starts at LAUNCH (go-live right after this run), not at the phase-1 deploy. If not provided, this is a one-shot
        // single-phase deploy (deploys the NFT + oracle here, mint open).
        address existingOracle = vm.envOr("ORACLE_ADDR", address(0));
        address existingNft = vm.envOr("NFT_ADDR", address(0));

        // 2. randomness oracle. DEFAULT IS THE MOCK (see c.mockOracle above: vm.envOr("MOCK_ORACLE", true); this
        //    script refuses chainid 4663 outright). This comment used to claim the opposite --
        //    that the real oracle was the default -- which is how a deployment can end up believing it
        //    exercised the randomness path when it never did.
        //    Set MOCK_ORACLE=false to get the real BlsDrandOracle. That is viable on RH testnet: the
        //    EIP-2537 precompiles are present (script/bls_precompile_check.sh) and a live quicknet beacon
        //    has been verified through it end to end. The mock remains the default only because it lets a
        //    run post beacons for rounds drand has not reached yet, which is much faster to iterate on.
        d.oracle = existingOracle != address(0)
            ? existingOracle
            // The mock oracle's own clock starts at DEPLOY time, not at the (now future) game GENESIS: roundAt()
            // answers round 1 for any time before its genesis, which would bind the NFT reveal to round 1.
            : (c.mockOracle
                    ? address(new MockDrandOracle(block.timestamp, 3))
                    : address(new BlsDrandOracle(1_692_803_367, 3)));

        // 3. NFT (the raise). Phase 2: reuse the phase-1 NFT (must already be finalizeLaunch'd — the hook
        //    reverts pool creation otherwise). Single-phase: deploy + open the mint here.
        if (existingNft != address(0)) {
            d.nft = existingNft;
        } else {
            // Single-phase deploy needs the on-chain art renderer (deploy+chunk it via DeployPassArt first).
            address renderer = vm.envAddress("RENDERER_ADDR");
            // pass-11: the short-clock NFT subclass (test: GTD 3m / overflow 8m / public 6m) so the full tiered
            // mint is walkable in minutes. Caps are the real 3/8/10.
            NFTCollectionTestnet nft = new NFTCollectionTestnet(c.mintPrice, d.oracle, c.revealDelay, renderer, d.me);
            // Recipients must be distinct. On testnet the LP is self-funded at go-live (not from
            // these buckets), so 3 distinct deployer-derived addresses are fine; mainnet uses real treasuries.
            // Env-overridable so a dress rehearsal can exercise the REAL decision. These three freeze
            // PERMANENTLY at the first mint (setRecipients guards on `mintStart != 0 || totalMinted > 0`)
            // and `withdrawProceeds` is permissionless and pays exactly them forever, through the only ETH
            // exits in the contract -- no rescue, no sweep, no owner override. Leaving them hardcoded meant
            // the rehearsal skipped the one launch input that cannot be corrected. Defaults preserve the old
            // deployer-derived behaviour, so an unset env changes nothing. setRecipients also probes that
            // each destination can actually receive ETH.
            nft.setRecipients(
                vm.envOr("LP_TREASURY", d.me),
                vm.envOr("SEED_TREASURY", address(uint160(d.me) + 1)),
                vm.envOr("TEAM_WALLET", address(uint160(d.me) + 2))
            );
            // Wire delegate.xyz v2 (on RH at 0x…Bed493) BEFORE the mint opens so allowlisted holders can
            // delegate a hot wallet ahead of time and mint via delegatedAllowlistMint. Zero disables it.
            address dreg = vm.envOr("DELEGATE_REGISTRY", 0x00000000000000447e69651d841bD8D104Bed493);
            if (dreg != address(0)) nft.setDelegateRegistry(dreg);
            nft.setMintOpen(true); // kill switch on; openAllowlistMint requires it (pass-11)
            // pass-11: single-leaf allowlist root = the deployer, so it can mint in the GTD (cap 3) and overflow
            // (cap 8) windows with an EMPTY proof; public (cap 20) opens automatically once the mint is started.
            // openAllowlistMint is the ONE start action (separate manual step below); there is no openPublicMint.
            nft.setAllowlistRoot(keccak256(abi.encodePacked(d.me)));
            // pass-13: 25-pass treasury reserve (ids 1..25) to the deployer/treasury, taken BEFORE the mint
            // opens so it never consumes a sale slot. Must be after setRecipients, before openAllowlistMint.
            nft.reserveMint(25, d.me);
            // reserve is one-shot (the reserveMinted latch is permanent): abort the launch if the count is wrong
            // rather than silently stranding a short/fat-fingered reserve.
            require(nft.totalMinted() == 25, "reserve count mismatch");
            // pass-13: the mint is left CLOSED here on purpose. Everything is wired (recipients, registry,
            // allowlist root, reserve), but openAllowlistMint() is a SEPARATE manual step so allowlisted
            // holders can delegate a hot wallet (delegate.xyz needs this NFT's address, known only after this
            // deploy) BEFORE the ~17-minute mint clock starts. Start it with:
            //   cast send $NFT "openAllowlistMint()" --rpc-url $RPC --account deployer
            // ONE-HOUR RESERVE FUSE (guards against reserve-then-abandon): reserveMint above stamps reserveAt,
            // and launchBackstopExpired() now ALSO fires from that stamp while mintStart == 0. The testnet NFT's
            // LAUNCH_BACKSTOP() is 1 HOUR (mainnet: 30 days), so openAllowlistMint MUST be sent within 1h of
            // this deploy. Past that, ANYONE can finalizeLaunch() the collection as reserved-only (25 passes),
            // after which the mint can never open and the whole deploy must be redone.
            // Art is fully on-chain via the renderer + tokenURI — no baseURI to set, no reveal flip to forget.
            d.nft = address(nft);
        }

        // 4-6. protocol
        _deployProtocol(d, c);
        _wire(d, c);
        _seedVaults(d, c);

        vm.stopBroadcast();

        _log(d, c);
    }

    function _deployProtocol(D memory d, Cfg memory c) internal {
        d.token = address(new QPULLToken(c.initialSupply, d.me)); // clean ownerless ERC-20
        d.treasury = address(new Treasury(d.token, d.weth, d.quotron, d.me));
        d.prizeVault = address(new BaseVault(d.quotron, d.me));
        d.leaderboardVault = address(new BaseVault(d.quotron, d.me));
        d.holderDrawVault = address(new BaseVault(d.quotron, d.me));
        d.claimMgr = address(new ClaimManager(d.me));
        d.packs = address(new PackRegistryTestnet(d.oracle, c.ticketPrice, c.genesis, c.revealDelay, d.me)); // 5-min day (testnet)
        d.leaderboardReg = address(new LeaderboardRegistryTestnet(c.genesis, d.me)); // 10-min week (testnet)
        d.raffle = address(
            new RaffleEngineTestnet(
                d.oracle,
                d.packs,
                d.prizeVault,
                d.claimMgr,
                c.genesis,
                c.winnersPerDay,
                c.raffleMinPot,
                c.rafflePotCap,
                c.capBps, // 10%/day of the vault (REQUIRED)
                d.me
            )
        );
        d.leaderboardEng = address(
            new LeaderboardEngineTestnet(
                d.leaderboardReg,
                d.leaderboardVault,
                d.claimMgr,
                c.genesis,
                c.leaderboardMinPot,
                c.leaderboardPotCap,
                d.me
            )
        );
        d.holderDrawEng = address(
            new HolderDrawEngineTestnet(
                d.oracle,
                d.nft,
                d.holderDrawVault,
                d.claimMgr,
                c.genesis,
                c.holderPotCap,
                c.holderPotCeiling,
                c.holderMinPot,
                d.me
            )
        );
        d.adapter = address(new QpullWethAdapter(d.poolManager, d.token, d.weth, d.me));

        // The 4% tax hook, at a CREATE2-mined address carrying its callback flags in the low 14 bits.
        // Its `initializer` is the LIQUIDITY LOCK, which does not exist yet, so the lock's CREATE address is
        // predicted here and proved below. A CREATE address depends only on (deployer, nonce), never on
        // constructor args — which is what breaks the hook<->lock cycle. The next transaction from d.me is
        // the hook's CREATE2-factory call, so the lock lands one nonce later. Keep the two adjacent.
        address predictedLock = vm.computeCreateAddress(d.me, vm.getNonce(d.me) + 1);

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: d.poolManager,
            qpull: d.token,
            weth: d.weth,
            fee: c.poolFee,
            tickSpacing: c.poolTickSpacing,
            treasury: d.treasury,
            packRegistry: d.packs,
            leaderboardRegistry: d.leaderboardReg,
            nft: d.nft,
            exemptSender: d.adapter,
            initializer: predictedLock,
            // Per-buy WETH cap while the wallet's gated-window spend is below EARLY_BUY_COUNT * cap (a spend budget,
            // not a buy count; see QpullTaxHook): a fixed ETH amount, never USD-tracking. Defaults to the shipping 0.25 ether so the throttle is rehearsed as
            // it ships; a gap-buster test run lowers it (EARLY_BUY_CAP) so a tiny buy trips EarlyBuyTooLarge.
            // EARLY_BUY_CAP_WEI is the name Deploy.s.sol reads; EARLY_BUY_CAP stays accepted here.
            earlyBuyCapWei: vm.envOr("EARLY_BUY_CAP_WEI", vm.envOr("EARLY_BUY_CAP", uint256(0.25 ether)))
        });
        // TESTNET hook subclass: compressed gate/cooldown/sell-tax windows (15m/20s/20m) so the launch gate,
        // transfer-lock lift, and sell-tax decay can be walked in one session. Mine the SUBCLASS creation code.
        // Flags: the base hook's REQUIRED_FLAGS, AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY
        //   | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA. Bits 7 and 3 let the
        //   hook take the WETH fee on the specified currency (exact-in buys, exact-out sells).
        uint160 flags = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2); // 0x1ACC
        (address mined, bytes32 salt) = HookMiner.find(
            HookMiner.CREATE2_DEPLOYER,
            flags,
            abi.encodePacked(type(QpullTaxHookTestnet).creationCode, abi.encode(hc))
        );
        d.hook = address(new QpullTaxHookTestnet{ salt: salt }(hc));
        require(d.hook == mined, "hook address mismatch (CREATE2 deployer)");

        // THE PERMANENT LOCK — immediately after the hook, which was just mined against this exact address.
        // Landing anywhere else means the hook's initializer is a dead address and the pool could never be
        // created. The require fails the SIMULATION, so a drifted nonce costs a re-run, never a broadcast.
        d.lock = address(
            new QpullLiquidityLock(
                IPoolManager(d.poolManager), d.token, d.weth, c.poolFee, c.poolTickSpacing, d.hook, d.me
            )
        );
        require(d.lock == predictedLock, "lock address mismatch: hook.initializer would be a dead address");

        NFTCollection(d.nft).setTaxHook(d.hook); // wire the launch transfer-lock (flag-on-buy, spec §16)
    }

    function _wire(D memory d, Cfg memory c) internal {
        PackRegistry(d.packs).setRecorder(d.hook);
        LeaderboardRegistry(d.leaderboardReg).setRecorder(d.hook);
        PackRegistry(d.packs).setEngine(d.raffle);
        PackRegistry(d.packs).setNft(d.nft);
        // rip-XP: PackRegistry.claimRipXp -> LeaderboardRegistry.recordXp (both bindings write-once)
        PackRegistry(d.packs).setLeaderboard(d.leaderboardReg);
        LeaderboardRegistry(d.leaderboardReg).setXpRecorder(d.packs);

        BaseVault(d.prizeVault).setController(d.claimMgr);
        BaseVault(d.leaderboardVault).setController(d.claimMgr);
        BaseVault(d.holderDrawVault).setController(d.claimMgr);

        // Each engine bound to its own vault only.
        ClaimManager(d.claimMgr).setEngine(d.raffle, d.prizeVault);
        ClaimManager(d.claimMgr).setEngine(d.leaderboardEng, d.leaderboardVault);
        ClaimManager(d.claimMgr).setEngine(d.holderDrawEng, d.holderDrawVault);
        // Freeze the bindings, passing the exact expected pairs (completeness check).
        address[] memory engs = new address[](3);
        address[] memory vlts = new address[](3);
        engs[0] = d.raffle;
        vlts[0] = d.prizeVault;
        engs[1] = d.leaderboardEng;
        vlts[1] = d.leaderboardVault;
        engs[2] = d.holderDrawEng;
        vlts[2] = d.holderDrawVault;
        ClaimManager(d.claimMgr).lockEngines(engs, vlts);

        // Assert HolderDraw's genesis matches a sibling's (it has no registry to anchor).
        require(
            HolderDrawEngine(d.holderDrawEng).genesis() == RaffleEngine(d.raffle).genesis(),
            "holder-draw genesis mismatch"
        );

        // all three engine potCaps are ctor-set now: no post-deploy setPotCap needed.

        Treasury(d.treasury).setAdapters(d.adapter, d.wethQuotron);
        // Holder tax share (6.25%) routes to the holder-draw vault (same BaseVault HolderDrawEngine draws
        // from) — the standalone trade jackpot is gone; the holder draw is now tax-funded.
        Treasury(d.treasury).setRouting(d.prizeVault, d.holderDrawVault, d.leaderboardVault, d.me);
        // lockRouting() now also requires BOTH convert caps to be armed, because
        // convert() requires them too and a lock that verified only the six addresses promised a
        // completeness it did not check. This block used to lock FIRST and leave the caps to GoLiveTestnet,
        // which would now revert NotConfigured. Arm the caps here so the in-deploy lock still works. Mainnet is
        // unaffected: GoLiveMainnet already arms the caps at step 1 and locks LAST.
        // lockRouting() now latches both caps as permanent CEILINGS, so these can no longer be
        // placeholders of 1 that GoLiveTestnet raises later (that raise would revert CapTooLarge). They are the
        // same values GoLiveTestnet arms, read from the same env names with the same defaults:
        // MAX_CONVERT_PER_CALL (= LP_QPULL, 10,000 QPULL) and MAX_WETH_CONVERT_PER_CALL (= LP_ETH, 0.5 ETH).
        // Run both scripts with the same env, or GoLiveTestnet refuses a cap above what this lock latched.
        Treasury(d.treasury).setMaxConvertPerCall(
            vm.envOr("MAX_CONVERT_PER_CALL", vm.envOr("LP_QPULL", uint256(10_000e18)))
        );
        Treasury(d.treasury).setMaxWethConvertPerCall(
            vm.envOr("MAX_WETH_CONVERT_PER_CALL", vm.envOr("LP_ETH", uint256(0.5 ether)))
        );
        // Declare what is being frozen: lockRouting now refuses to freeze anything but the exact
        // destinations named here, so a routing table changed underneath this script aborts the run.
        Treasury(d.treasury).lockRouting(
            d.adapter, d.wethQuotron, d.prizeVault, d.holderDrawVault, d.leaderboardVault, d.me
        );
        // Dust-QPULL convert grief, mirrored from Deploy.s.sol: a NON-ZERO min-batch threshold, at
        // least one whole QPULL, so testnet exercises the same Treasury.convert() QPULL-leg gate mainnet ships with.
        // It was 0 here, so every testnet run tested a config mainnet refuses. Default 10,000 QPULL: the mainnet 1,000
        // QPULL quotes ~2.1e13 wei against a ~21 ETH pool, but against a testnet pool of 0.3-0.5 ETH it quotes
        // 3e11-5e11 wei, under the 1e12-wei floor GoLiveMainnet enforces and GoLiveTestnet now mirrors. 10,000 QPULL
        // quotes 5e12 wei at GoLiveTestnet's 0.5 ETH default and equals its default QPULL slice cap (LP_QPULL).
        uint256 threshold = vm.envOr("CONVERT_THRESHOLD", uint256(10_000e18));
        require(threshold >= 1e18, "deploy-testnet: CONVERT_THRESHOLD must be >= 1e18 QPULL (as Deploy.s.sol)");
        Treasury(d.treasury).setConvertThreshold(threshold);
        // KEEPER, env-overridable -- it was hardcoded to the deployer and did not read the env at all,
        // so a dress rehearsal SILENTLY could not exercise the keeper privilege split (a zero-privilege
        // draw wallet, and a convert wallet that is the only address Treasury trusts). The mainnet script
        // reads KEEPER at Deploy.s.sol:101; this one did not, so passing KEEPER here was ignored without a
        // word and the deployer stayed the keeper. That is the same fail-open shape as Deploy.s.sol:353,
        // except here there was not even an env var to get wrong.
        //
        // Defaults to the deployer, preserving the old behaviour when unset.
        address keeper = vm.envOr("KEEPER", d.me);
        Treasury(d.treasury).setKeeper(keeper, true);
        if (keeper != d.me) {
            // The deployer must NOT keep convert() rights once a real keeper exists. setKeeper is
            // deliberately never frozen by lockRouting, so this is always correctable after the fact -- but
            // leaving it to a manual step is how it ends up not happening.
            Treasury(d.treasury).setKeeper(d.me, false);
        }

        QpullWethAdapter(d.adapter).setTreasury(d.treasury);
        QpullWethAdapter(d.adapter).setPoolKey(_canonicalKey(d, c));
    }

    /// Seed the prize vaults with mock QUOTRON so draws can pay on testnet.
    function _seedVaults(D memory d, Cfg memory c) internal {
        MockERC20(d.quotron).mint(d.prizeVault, c.vaultSeed);
        MockERC20(d.quotron).mint(d.leaderboardVault, c.vaultSeed);
        MockERC20(d.quotron).mint(d.holderDrawVault, c.vaultSeed);
        MockERC20(d.quotron).mint(d.me, c.vaultSeed); // some for you, for the WETH->QUOTRON mock swaps
    }

    function _canonicalKey(D memory d, Cfg memory c) internal pure returns (PoolKey memory k) {
        (address lo, address hi) = d.token < d.weth ? (d.token, d.weth) : (d.weth, d.token);
        k = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: c.poolFee,
            tickSpacing: c.poolTickSpacing,
            hooks: d.hook
        });
    }

    function _log(D memory d, Cfg memory c) internal view {
        console2.log("== TESTNET DEPLOY (chain 46630) ==");
        console2.log("PoolManager (real)", d.poolManager);
        console2.log("QUOTRON (mock)    ", d.quotron);
        console2.log("WETH (mock)       ", d.weth);
        console2.log("wethQuotron (mock)", d.wethQuotron);
        console2.log("Oracle            ", d.oracle);
        console2.log("NFTCollection     ", d.nft);
        console2.log("QPULLToken         ", d.token);
        console2.log("Treasury          ", d.treasury);
        console2.log("PrizeVault        ", d.prizeVault);
        console2.log("LeaderboardVault  ", d.leaderboardVault);
        console2.log("HolderDrawVault   ", d.holderDrawVault);
        console2.log("ClaimManager      ", d.claimMgr);
        console2.log("PackRegistry      ", d.packs);
        console2.log("LeaderboardReg    ", d.leaderboardReg);
        console2.log("RaffleEngine      ", d.raffle);
        console2.log("LeaderboardEngine ", d.leaderboardEng);
        console2.log("HolderDrawEngine  ", d.holderDrawEng);
        console2.log("QpullWethAdapter  ", d.adapter);
        console2.log("QpullTaxHook      ", d.hook);
        console2.log("LiquidityLock     ", d.lock); // the hook initializer + the go-live LOCK= input
        console2.log("GENESIS (game day 0)", c.genesis);
        if (c.genesis > block.timestamp) {
            console2.log("  starts in (s)     ", c.genesis - block.timestamp);
        }
        console2.log("  opening window ends", c.genesis + 600); // ACCUM_DAYS (2) x the 5-minute testnet day
        (address lo, address hi) = d.token < d.weth ? (d.token, d.weth) : (d.weth, d.token);
        console2.log("-- canonical pool key --");
        console2.log("currency0", lo);
        console2.log("currency1", hi);
        console2.log("fee", uint256(c.poolFee));
        console2.log("tickSpacing", uint256(int256(c.poolTickSpacing)));
        console2.log("hooks", d.hook);
        _printExports(d, c);
    }

    /// @dev Copy-paste block that wires the GoLive / Buy / Exercise helpers.
    function _printExports(D memory d, Cfg memory c) internal pure {
        console2.log("");
        console2.log("== COPY-PASTE THESE (wires the GoLive/Buy/Exercise helpers) ==");
        console2.log(string.concat("export POOL_MANAGER=", vm.toString(d.poolManager)));
        console2.log(string.concat("export QPULL_TOKEN=", vm.toString(d.token)));
        console2.log(string.concat("export WETH=", vm.toString(d.weth)));
        console2.log(string.concat("export HOOK=", vm.toString(d.hook)));
        // REQUIRED by GoLiveTestnet: the lock is the hook's initializer and the only address that can
        // create or seed the canonical pool. It used to be printed only in the address list above, which
        // meant the one input go-live cannot run without had to be copied by hand.
        console2.log(string.concat("export LOCK=", vm.toString(d.lock)));
        console2.log(string.concat("export POOL_FEE=", vm.toString(uint256(c.poolFee))));
        console2.log(string.concat("export POOL_TICK_SPACING=", vm.toString(uint256(int256(c.poolTickSpacing)))));
        console2.log(string.concat("export TREASURY=", vm.toString(d.treasury)));
        console2.log(string.concat("export ORACLE=", vm.toString(d.oracle)));
        console2.log(string.concat("export RAFFLE_ENGINE=", vm.toString(d.raffle)));
        console2.log(string.concat("export PACK_REGISTRY=", vm.toString(d.packs)));
        console2.log(string.concat("export CLAIM_MANAGER=", vm.toString(d.claimMgr)));
        console2.log(string.concat("export NFT=", vm.toString(d.nft)));
        // Complete the set so keeper/.env + web/index.html can be rewired from ONE block (no hunting the
        // full log): the other two engines, the leaderboard registry, and all three prize vaults.
        console2.log(string.concat("export HOLDER_ENGINE=", vm.toString(d.holderDrawEng)));
        console2.log(string.concat("export LEADERBOARD_ENGINE=", vm.toString(d.leaderboardEng)));
        console2.log(string.concat("export LEADERBOARD_REG=", vm.toString(d.leaderboardReg)));
        console2.log(string.concat("export RAFFLE_VAULT=", vm.toString(d.prizeVault)));
        console2.log(string.concat("export LEADER_VAULT=", vm.toString(d.leaderboardVault)));
        console2.log(string.concat("export HOLDER_VAULT=", vm.toString(d.holderDrawVault)));
        console2.log(string.concat("export QUOTRON=", vm.toString(d.quotron)));
        console2.log("");
        console2.log("== NEXT (from the deployer key) ==");
        console2.log("0) DELEGATE (optional, do it now while the mint is still CLOSED so you get the full window):");
        console2.log("   cast send $DELEGATE_REGISTRY 'delegateContract(address,address,bytes32,bool)' $B $NFT 0x0..0 true");
        console2.log("1) START : cast send $NFT 'openAllowlistMint()' --rpc-url $RPC --account deployer");
        console2.log("           pass-11 tiered mint (fast test clock): GTD 3m (cap 3, allowlist=deployer, empty");
        console2.log("           proof) -> overflow 8m (cap 8) -> public 6m (cap 20) -> closed at +17m. The reserve");
        console2.log("           of 25 (ids 1..25) is already minted to the treasury; mint is CLOSED until you START.");
        console2.log("   !! ONE-HOUR RESERVE FUSE: send openAllowlistMint within 1h of THIS deploy (testnet");
        console2.log("   !! LAUNCH_BACKSTOP = 1h from reserveMint; mainnet = 30d). Past it ANYONE can finalizeLaunch");
        console2.log("   !! the collection reserved-only and the mint can NEVER open: redeploy from scratch.");
        console2.log("2) GO-LIVE: forge script script/GoLiveTestnet.s.sol --rpc-url $RPC --account <you> --broadcast");
        console2.log("           Run it at or just after GENESIS (printed above) and make some buys within the first");
        console2.log("           10 minutes (game days 0-1), so the one-time opening draw has packs to pay.");
        console2.log("           (needs TREASURY from the export block; arms BOTH convert caps as its step 1, so");
        console2.log("           convert() stops reverting NotConfigured. Optional: MAX_CONVERT_PER_CALL /");
        console2.log("           MAX_WETH_CONVERT_PER_CALL in wei; defaults = LP_QPULL / LP_ETH.)");
        console2.log("3) BUY   : forge script script/BuyTestnet.s.sol   --rpc-url $RPC --account <you>   --broadcast  (holder -> tickets)");
        console2.log("   SNIPE : forge script script/BuyTestnet.s.sol   --rpc-url $RPC --account <friend> --broadcast (no NFT -> Gated)");
        console2.log("4) EXERCISE: script/ExerciseTestnet.s.sol --sig convertNow() / drawRaffle(uint32,uint256) / claim(uint256)");
        console2.log("(Deploy with MOCK_ORACLE=true so drawRaffle can set the beacon instantly.)");
    }
}
