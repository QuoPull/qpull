// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { BlsDrandOracle } from "../src/oracle/BlsDrandOracle.sol";
import { NFTCollection } from "../src/NFTCollection.sol";
import { PassArtRenderer } from "../src/nft/PassArtRenderer.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { LaunchGuards } from "../script/LaunchGuards.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice Randomness IN MAINNET ORDER with REAL Drand quicknet beacons. Every beacon
///         below is a real, published quicknet round, fetched read-only from two public relays (api.drand.sh and
///         drand.cloudflare.com, which returned byte-identical answers), and each relay's `randomness` field equals
///         sha256(signature), asserted here. The 128-byte uncompressed form was computed off-chain (y = sqrt(x^3 + 4) mod p,
///         root chosen by the compression sign bit) and is only a hint: BlsDrandOracle verifies the BLS pairing against
///         drand's group key with the EIP-2537 precompiles and binds the published 48-byte form to it.
///
///         WHY REAL SIGNATURES LINE UP WITH THE CONTRACTS' ROUND MATH. The contracts never choose rounds: NFTCollection binds
///         roundAt(finalizeLaunch + revealDelay), PackRegistry roundAt(genesis + (cohort+1)*DAY + revealDelay) and
///         RaffleEngine roundAt(genesis + (day+1)*DAY + REVEAL_LAG), all through BlsDrandOracle.roundAt (quicknet genesis
///         1692803367, period 3). So the launch timeline is placed in the PAST (mint 2026-09-02, finalize 2026-09-04,
///         GENESIS 2026-09-06 00:00 UTC), the rounds that timeline binds were computed with the same ceil formula, and those
///         exact rounds were fetched. The test asserts that each round the contracts bind equals the embedded round, that
///         each round's drand publish time (genesis + (round-1)*3) is at or after the contract's cutoff while the round
///         before it is not (the time lock), and that every beacon is posted only after its publish time.
///
///         ORDER (the mainnet launch sequence): NFT raise -> finalizeLaunch binds the pass reveal round -> anyone posts that real
///         beacon -> rarity resolves (checked against a map computed off-chain from the same public beacon) -> the protocol
///         is deployed against the same oracle (LaunchGuards checks) -> Super Rares registered -> buys on days 0, 1, 2 ->
///         the OPENING draw: its settling beacon posted alone, the reveal guard refuses (RevealPending for cohort 0's real
///         round), cohort 0's real reveal posted, the same call pays every opening winner -> a DAILY draw after a skipped
///         day: its settling beacon posted alone, the guard refuses on the older in-window cohort, that real round posted, the
///         draw pays K winners with the free block (real Super Rares and a pledged Rare) active. No WinnerSkipped anywhere.
contract RealDrandMainnetOrderTest is Test {
    // ── drand quicknet ──
    uint256 constant DRAND_GENESIS = 1_692_803_367;
    uint256 constant DRAND_PERIOD = 3;

    uint64 constant R_PASS_REVEAL = 31_893_433;
    bytes constant COMP_PASS_REVEAL =
        hex"a716ee76b94147a850371df6c6abd0ed81c48e91f03ae222d487344324a14f77a56e13af187e60b2fe3b1839dbd58dfb";
    bytes constant SIG_PASS_REVEAL =
        hex"000000000000000000000000000000000716ee76b94147a850371df6c6abd0ed81c48e91f03ae222d487344324a14f77a56e13af187e60b2fe3b1839dbd58dfb000000000000000000000000000000000f645a020c99a29f4f470bb78d310e40635cbb95f19a3109ea332a571bca7be77ca2bfe48f1d0d168a147e3e167eca09";
    bytes32 constant DRAND_RANDOMNESS_PASS_REVEAL = 0x3dfdac8d5ad2616accd100dc411d0bcec8c708c8524cc75619663ec34097ebae;

    uint64 constant R_DRAW_ROUND_0 = 31_979_812;
    bytes constant COMP_DRAW_ROUND_0 =
        hex"aee167ea68cd512ec5de865112130ec54106d5656b904bbaeee58f22d02f22c0718a248e5635f5cb877ce781c6b73a16";
    bytes constant SIG_DRAW_ROUND_0 =
        hex"000000000000000000000000000000000ee167ea68cd512ec5de865112130ec54106d5656b904bbaeee58f22d02f22c0718a248e5635f5cb877ce781c6b73a1600000000000000000000000000000000102e9e65fda0bc68e0f8e518f916022ad12211727e407d7761e25ee9e01504c9a1e7ac55cc07096491223b5d650dbf29";
    bytes32 constant DRAND_RANDOMNESS_DRAW_ROUND_0 = 0x8c5c6e175abc6bf6643fef2ca001c254af5fc4fe44bf87eee0e530414709eec0;

    uint64 constant R_DRAW_ROUND_1 = 32_008_612;
    bytes constant COMP_DRAW_ROUND_1 =
        hex"9553a2967147e2409e29241dc3180d639aeccd7b4276aa65a4365dc277741ed8ac4504f64a14094d5a421c7570c64c76";
    bytes constant SIG_DRAW_ROUND_1 =
        hex"000000000000000000000000000000001553a2967147e2409e29241dc3180d639aeccd7b4276aa65a4365dc277741ed8ac4504f64a14094d5a421c7570c64c7600000000000000000000000000000000060d94594f6a02163952b97732cef35d5d43d22068eae3efc3338b64d723a0a5c6f020329f82472f0f0377bc00ec8b64";
    bytes32 constant DRAND_RANDOMNESS_DRAW_ROUND_1 = 0xf6ab6739f884918806fc2e34afe6da0a79d6b0feb4d04e0c25fdc63c634c547b;

    uint64 constant R_DRAW_ROUND_2 = 32_037_412;
    bytes constant COMP_DRAW_ROUND_2 =
        hex"97f03582777f7a187bd18e4384e8328c20c615a1f9e334ea53e9a2d6ef95052e1f6e378cf0d162904fdfac71f8d6a3a5";
    bytes constant SIG_DRAW_ROUND_2 =
        hex"0000000000000000000000000000000017f03582777f7a187bd18e4384e8328c20c615a1f9e334ea53e9a2d6ef95052e1f6e378cf0d162904fdfac71f8d6a3a5000000000000000000000000000000000b8a27ffd1bd7239bebb9444e16dfa2e673032d6034e88aab91d339ab11e090755d506f1e476b0522aa46638d5ee6944";
    bytes32 constant DRAND_RANDOMNESS_DRAW_ROUND_2 = 0x508e888b8fdaabff7068e6a454bd1eb22a6db34bb2ee716f74caa6892e17a9e2;

    uint64 constant R_DRAW_ROUND_3 = 32_066_212;
    bytes constant COMP_DRAW_ROUND_3 =
        hex"ab502b5a49c949f36bcb06ea2f387dd0e024d124d0759b1038d2b23cd39de1bad35480dff249aa7de33ce5040e3dd029";
    bytes constant SIG_DRAW_ROUND_3 =
        hex"000000000000000000000000000000000b502b5a49c949f36bcb06ea2f387dd0e024d124d0759b1038d2b23cd39de1bad35480dff249aa7de33ce5040e3dd029000000000000000000000000000000001174ed49af5ffe49311b0cbbea960f83e2980fa70e1867b4b584ba70de4de1193d3096e1cd917b3562842f0f4e35f79b";
    bytes32 constant DRAND_RANDOMNESS_DRAW_ROUND_3 = 0x6e4a81a920ee9c88593b970bb96346be511ddb112cab3ef418877e2756a3a584;

    // ── the launch timeline (UTC) ──
    uint256 constant MINT_START = 1_788_307_200; // 2026-09-02T00:00:00Z openAllowlistMint
    uint256 constant FINALIZE_AT = MINT_START + 48 hours + 61; // after the fixed mint close
    uint256 constant GENESIS = 1_788_652_800; // 2026-09-06T00:00:00Z
    uint256 constant DAY = 1 days;
    uint256 constant PASSES = 200;
    uint256 constant PRICE = 0.0075 ether;
    uint256 constant TICKET = 0.003 ether;
    uint256 constant K = 10; // the launch winnersPerDay

    // The pass rarity map computed OFF-CHAIN from the public beacon of R_PASS_REVEAL for ids 1..200:
    // roll = keccak256(abi.encodePacked(keccak256(COMP_PASS_REVEAL), tokenId, "nft")) % 10000 (cast keccak), tiers at
    // 200 / 1000 / 3000. Result: 142 Common, 40 Uncommon, 14 Rare, 4 Super Rare.
    uint256 constant OFFCHAIN_COMMON = 142;
    uint256 constant OFFCHAIN_UNCOMMON = 40;
    uint256 constant OFFCHAIN_RARE = 14;
    uint256 constant OFFCHAIN_SUPER_RARE = 4;

    bytes32 constant WINNER_PAID = keccak256("WinnerPaid(uint32,uint256,address,uint8,uint256,uint256)");
    bytes32 constant WINNER_SKIPPED = keccak256("WinnerSkipped(uint32,uint256,uint8)");
    bytes32 constant FREE_ENTRY = keccak256("FreeEntryDrawn(uint32,uint256,address,uint8,uint256)");

    BlsDrandOracle oracle;
    NFTCollection nft;
    PackRegistry packs;
    RaffleEngine raffle;
    BaseVault vault;
    ClaimManager claims;
    MockERC20 quotron;
    address recorder = makeAddr("hookAsRecorder");
    address poster = makeAddr("anyoneWhoPostsABeacon");
    address[10] minters;

    function _publishTime(uint64 round) internal pure returns (uint256) {
        return DRAND_GENESIS + (uint256(round) - 1) * DRAND_PERIOD;
    }

    /// The time lock: `round` is the FIRST quicknet round published at or after `cutoff`.
    function _assertTimeLocked(uint64 round, uint256 cutoff, string memory what) internal pure {
        assertGe(_publishTime(round), cutoff, string.concat(what, ": round publishes at or after its cutoff"));
        assertLt(_publishTime(round - 1), cutoff, string.concat(what, ": and it is the first such round"));
    }

    /// Posts a real beacon, permissionlessly, and only once drand has published it.
    function _post(uint64 round, bytes memory sig, bytes memory comp, bytes32 drandRandomness) internal {
        assertGe(block.timestamp, _publishTime(round), "never posted before drand published the round");
        assertEq(sha256(comp), drandRandomness, "the relay's randomness field is sha256 of the published signature");
        vm.prank(poster);
        oracle.submitBeacon(round, sig, comp);
        assertTrue(oracle.isAvailable(round), "beacon verified on chain");
        assertEq(oracle.randomness(round), keccak256(comp), "seed = keccak256(drand's published 48 bytes)");
        assertEq(oracle.signatureOf(round), comp, "stored bytes are drand's archive bytes");
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    function _buyCohort(uint256 salt, uint256 buyers, uint256 ticketsEach) internal {
        for (uint256 i; i < buyers; ++i) {
            vm.prank(recorder);
            packs.recordBuy(makeAddr(string.concat("buyer", vm.toString(salt), "-", vm.toString(i))), ticketsEach * TICKET);
        }
    }

    // ── stage 1: the raise and the pass reveal ───────────────────────────────────────────────────────────────────

    function _raiseAndRevealPasses() internal {
        vm.warp(MINT_START - 1 days);
        oracle = new BlsDrandOracle(DRAND_GENESIS, DRAND_PERIOD);
        PassArtRenderer renderer = new PassArtRenderer(address(this));
        renderer.lock();
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(renderer), address(this));
        nft.setRecipients(makeAddr("lpTreasury"), makeAddr("seedTreasury"), makeAddr("team+ops"));
        nft.setAllowlistRoot(keccak256("allowlist"));
        nft.setMintOpen(true);
        vm.warp(MINT_START);
        nft.openAllowlistMint();
        vm.warp(nft.publicOpensAt());
        for (uint256 i; i < 10; ++i) {
            minters[i] = makeAddr(string.concat("minter", vm.toString(i)));
            vm.deal(minters[i], 1 ether);
            vm.prank(minters[i]);
            nft.mintBatch{ value: 20 * PRICE }(20);
        }
        assertEq(nft.totalMinted(), PASSES, "premise: 200 passes, ids 1..200");

        vm.warp(FINALIZE_AT);
        assertTrue(nft.publicMintExpired(), "premise: the mint closed by time");
        nft.finalizeLaunch();
        assertEq(nft.revealRound(), R_PASS_REVEAL, "finalizeLaunch binds exactly the embedded real round");
        _assertTimeLocked(R_PASS_REVEAL, FINALIZE_AT + 1 hours, "pass reveal");
        assertFalse(nft.isRevealed(), "sealed until the beacon is posted");
        vm.expectRevert(bytes("unavailable"));
        nft.rarityOf(1);

        // A real beacon of a DIFFERENT round cannot stand in for the bound round: the pairing is over sha256(round).
        vm.warp(_publishTime(R_PASS_REVEAL) + 5);
        vm.expectRevert(BlsDrandOracle.InvalidBeacon.selector);
        oracle.submitBeacon(R_PASS_REVEAL, SIG_DRAW_ROUND_0, COMP_DRAW_ROUND_0);

        _post(R_PASS_REVEAL, SIG_PASS_REVEAL, COMP_PASS_REVEAL, DRAND_RANDOMNESS_PASS_REVEAL);
        assertTrue(nft.isRevealed(), "revealed");

        uint256[4] memory counts;
        bytes32 seed = keccak256(COMP_PASS_REVEAL);
        for (uint256 id = 1; id <= PASSES; ++id) {
            uint8 r = nft.rarityOf(id);
            ++counts[r];
            uint256 roll = uint256(keccak256(abi.encodePacked(seed, id, "nft"))) % 10_000;
            uint8 expect = roll < 200 ? 3 : (roll < 1000 ? 2 : (roll < 3000 ? 1 : 0));
            assertEq(r, expect, "rarityOf == the formula over drand's published bytes");
        }
        assertEq(counts[0], OFFCHAIN_COMMON, "Common count == the off-chain map");
        assertEq(counts[1], OFFCHAIN_UNCOMMON, "Uncommon count == the off-chain map");
        assertEq(counts[2], OFFCHAIN_RARE, "Rare count == the off-chain map");
        assertEq(counts[3], OFFCHAIN_SUPER_RARE, "Super Rare count == the off-chain map");
        assertEq(nft.rarityOf(35), 3, "SR id 35 (off-chain map)");
        assertEq(nft.rarityOf(66), 3, "SR id 66 (off-chain map)");
        assertEq(nft.rarityOf(92), 3, "SR id 92 (off-chain map)");
        assertEq(nft.rarityOf(175), 3, "SR id 175 (off-chain map)");
        assertEq(nft.rarityOf(7), 2, "Rare id 7 (off-chain map)");
    }

    // ── stage 2: the protocol, deployed after finalizeLaunch against the same oracle ─────────────────────────────

    function _deployProtocol() internal {
        vm.warp(GENESIS - 1 days);
        LaunchGuards.requireQuicknetOracle(address(oracle)); // what Deploy.s.sol runs on DRAND_ORACLE
        assertEq(address(nft.drand()), address(oracle), "Deploy.s.sol: DRAND_ORACLE == NFTCollection.drand()");
        LaunchGuards.requireDeployGenesis(GENESIS, nft.revealBoundAt());
        quotron = new MockERC20();
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claims = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claims), GENESIS, K, 1, 1000e18, 1000, address(this)
        );
        packs.setRecorder(recorder);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        claims.setEngine(address(raffle), address(vault));
        vault.setController(address(claims));
        quotron.mint(address(vault), 100_000e18);

        uint256[] memory ids = new uint256[](PASSES);
        for (uint256 i; i < PASSES; ++i) ids[i] = i + 1;
        packs.registerSuperRare(ids); // permissionless; only the four real Super Rares index
        assertEq(packs.superRareIds(0), 35, "SR index 0");
        assertEq(packs.superRareIds(3), 175, "SR index 3");
        vm.expectRevert();
        packs.superRareIds(4); // exactly four
    }

    function test_realQuicknet_passReveal_openingAndDailyDraw_inMainnetOrder() public {
        _raiseAndRevealPasses();
        _deployProtocol();

        // ── stage 3: buys on day 0 and day 1; every pack carries its cohort's real round ──
        vm.warp(GENESIS + 2 hours); // day 0, after the 1-hour gate
        _buyCohort(0, 4, 5); // 20 packs, ids 1..20
        (, uint64 rr0,,) = packs.packs(1);
        assertEq(rr0, R_DRAW_ROUND_0, "cohort 0 is sealed to the embedded real round");
        assertEq(raffle.drawRound(0), R_DRAW_ROUND_0, "== drawRound(0) at revealDelay == REVEAL_LAG");
        _assertTimeLocked(R_DRAW_ROUND_0, GENESIS + DAY + 1 hours, "cohort 0 reveal");
        vm.warp(GENESIS + DAY + 2 hours); // day 1
        _buyCohort(1, 4, 5); // ids 21..40
        (, uint64 rr1,,) = packs.packs(21);
        assertEq(rr1, R_DRAW_ROUND_1, "cohort 1 is sealed to the embedded real round");
        assertEq(raffle.drawRound(1), R_DRAW_ROUND_1, "the opening settles on this same round");
        _assertTimeLocked(R_DRAW_ROUND_1, GENESIS + 2 * DAY + 1 hours, "opening settle");

        // ── stage 4: the opening draw, the reveal guard with real rounds ──
        vm.warp(_publishTime(R_DRAW_ROUND_1) + 30);
        assertEq(raffle.currentDay(), 2, "premise: the accumulation window closed");
        _post(R_DRAW_ROUND_1, SIG_DRAW_ROUND_1, COMP_DRAW_ROUND_1, DRAND_RANDOMNESS_DRAW_ROUND_1); // only this one
        vm.expectRevert(abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(0), R_DRAW_ROUND_0));
        raffle.runOpeningDraw(false);
        assertFalse(raffle.openingDone(), "reveal guard: nothing latched");
        assertEq(claims.nextClaimId(), 0, "reveal guard: no claim");
        (,,, bool spent1) = packs.packs(1);
        assertFalse(spent1, "reveal guard: nothing popped");

        _post(R_DRAW_ROUND_0, SIG_DRAW_ROUND_0, COMP_DRAW_ROUND_0, DRAND_RANDOMNESS_DRAW_ROUND_0); // published a day ago
        vm.recordLogs();
        raffle.runOpeningDraw(false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(raffle.openingDone(), "the opening settled on the paying call");
        assertEq(_count(logs, address(raffle), WINNER_PAID), raffle.OPENING_WINNERS(), "every opening winner paid");
        assertEq(_count(logs, address(raffle), WINNER_SKIPPED), 0, "no WinnerSkipped");
        _assertWinnerRolls(logs, false);

        // ── stage 5: day 2's draw is skipped (an outage); day 2's buys; a Rare pledged for day 3 ──
        vm.warp(GENESIS + 2 * DAY + 2 hours);
        _buyCohort(2, 4, 5); // ids 41..60, sealed to drawRound(2), which nobody posts during the outage
        (, uint64 rr2,,) = packs.packs(41);
        assertEq(rr2, R_DRAW_ROUND_2, "cohort 2 is sealed to the embedded real round");
        vm.warp(GENESIS + 3 * DAY + 2 hours); // day 3
        assertEq(nft.ownerOf(7), minters[0], "premise: minter0 holds Rare id 7");
        uint256[] memory pledgeIds = new uint256[](1);
        pledgeIds[0] = 7;
        vm.prank(minters[0]);
        packs.pledge(pledgeIds);

        // ── stage 6: the day-3 draw, the reveal guard on the older in-window cohort with real rounds ──
        vm.warp(_publishTime(R_DRAW_ROUND_3) + 30);
        assertEq(raffle.currentDay(), 4, "premise: day 3's only window");
        assertEq(raffle.drawRound(3), R_DRAW_ROUND_3, "day 3 settles on the embedded real round");
        _assertTimeLocked(R_DRAW_ROUND_3, GENESIS + 4 * DAY + 1 hours, "day 3 settle");
        _post(R_DRAW_ROUND_3, SIG_DRAW_ROUND_3, COMP_DRAW_ROUND_3, DRAND_RANDOMNESS_DRAW_ROUND_3); // only this one
        vm.expectRevert(abi.encodeWithSelector(PackRegistry.RevealPending.selector, uint32(2), R_DRAW_ROUND_2));
        raffle.runDraw(3);
        assertFalse(raffle.drawn(3), "reveal guard: the day is not consumed");

        _post(R_DRAW_ROUND_2, SIG_DRAW_ROUND_2, COMP_DRAW_ROUND_2, DRAND_RANDOMNESS_DRAW_ROUND_2);
        uint256 claimsBefore = claims.nextClaimId();
        vm.recordLogs();
        raffle.runDraw(3);
        logs = vm.getRecordedLogs();
        assertTrue(raffle.drawn(3), "the retry inside the window pays");
        assertEq(_count(logs, address(raffle), WINNER_PAID), K, "K winners paid (paid and free together)");
        assertEq(_count(logs, address(raffle), WINNER_SKIPPED), 0, "no WinnerSkipped");
        assertEq(claims.nextClaimId() - claimsBefore, K, "one claim per winner");
        uint256 freeSeated = _count(logs, address(packs), FREE_ENTRY);
        emit log_named_uint("free-entry winners seated from the real Super Rares / pledge", freeSeated);
        // The beacons are fixed, so this is deterministic: the day-3 draw seats at least one free-entry winner from the
        // real Super Rares / pledge, and every seated one is paid as a virtual winner (no WinnerSkipped above).
        assertGt(freeSeated, 0, "the free-entry block seated at least one winner");
        assertEq(_countVirtualPaid(logs), freeSeated, "every seated free-entry winner was paid");
        _assertWinnerRolls(logs, true);
    }

    /// WinnerPaid events for virtual (free-entry) ids: the top bit of the packed id is set.
    function _countVirtualPaid(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(raffle) || logs[i].topics.length < 3 || logs[i].topics[0] != WINNER_PAID) continue;
            if (uint256(logs[i].topics[2]) >> 255 != 0) ++n;
        }
    }

    /// Every PAID winner's tier roll recomputes from drand's published bytes for its cohort's round, independently of
    /// the oracle's storage: roll = keccak256(abi.encodePacked(keccak256(published signature), packId)) % 10000.
    function _assertWinnerRolls(Vm.Log[] memory logs, bool daily) internal view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(raffle) || logs[i].topics.length < 3 || logs[i].topics[0] != WINNER_PAID) continue;
            uint256 packId = uint256(logs[i].topics[2]);
            (, uint8 tier,,) = abi.decode(logs[i].data, (address, uint8, uint256, uint256));
            assertEq(tier, packs.tierOf(packId), "the event tier is the on-chain tier");
            if (packId >> 255 != 0) {
                assertTrue(daily, "virtual winners only in the daily draw");
                continue; // a free-entry winner: its tier is the pass's rarity, packed into the id
            }
            (, uint64 rr, uint32 cohort,) = packs.packs(packId);
            bytes memory comp = rr == R_DRAW_ROUND_0 ? COMP_DRAW_ROUND_0 : (rr == R_DRAW_ROUND_1 ? COMP_DRAW_ROUND_1 : COMP_DRAW_ROUND_2);
            assertTrue(rr == R_DRAW_ROUND_0 || rr == R_DRAW_ROUND_1 || rr == R_DRAW_ROUND_2, "a winner from a real-round cohort");
            assertLe(cohort, 2, "swept cohorts only");
            uint256 roll = uint256(keccak256(abi.encodePacked(keccak256(comp), packId))) % 10_000;
            assertEq(packs.rollOf(packId), roll, "roll recomputed from drand's published bytes");
        }
    }
}
