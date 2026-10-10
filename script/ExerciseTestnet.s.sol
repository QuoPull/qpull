// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

interface ITreasuryX {
    function convert(uint256 minWethOut, uint256 minQuotronOut) external;
}

interface IMockOracle {
    function setBeacon(uint64 round, bytes32 rnd) external;
    function isAvailable(uint64 round) external view returns (bool);
    function highestRound() external view returns (uint64);
    function roundAt(uint256 timestamp) external view returns (uint64);
}

interface IRaffleX {
    function runDraw(uint32 day) external;
    function drawRound(uint32 day) external view returns (uint64);
    function currentDay() external view returns (uint32);
}

interface IPacksX {
    function packs(uint256) external view returns (address owner, uint64 revealRound, uint32 cohortDay, bool spent);
    function drand() external view returns (address);
    function genesis() external view returns (uint256);
    function revealDelay() external view returns (uint256);
    function dayLength() external view returns (uint256);
    function cohortSize(uint32 cohortDay) external view returns (uint256);
    function LIFE_DAYS() external view returns (uint32);
}

interface IClaimX {
    function claim(uint256 id) external;
}

/// @notice EXERCISE (testnet, HELPER 3/3): drive the back half — fees to prizes, draw, and claim. Call each
///         phase separately with `--sig`, because the draw is TIME-GATED (a day's tickets are only drawable
///         during the FOLLOWING day). Requires the MOCK oracle deploy (MOCK_ORACLE=true) so you can set the
///         random number instead of waiting days for a real drand reveal.
///
/// @dev    Run as the deployer/keeper. Env (from DeployTestnet output):
///           TREASURY, ORACLE, RAFFLE_ENGINE, PACK_REGISTRY, CLAIM_MANAGER
///
///         1) forge script script/ExerciseTestnet.s.sol --sig "convertNow()"            --account deployer --broadcast
///              -> Treasury.convert(): the collected tax buys (mock) QUOTRON and splits to the vaults.
///         2) WAIT until the buy-day has closed (next day), then:
///            forge script script/ExerciseTestnet.s.sol --sig "drawRaffle(uint32)" <day> --account deployer --broadcast
///              -> posts the tier-reveal round of EVERY non-empty cohort in the draw window [day-7, day-1] (because
///                 runDraw reverts RevealPending while any of them is unposted), then the draw round, then runs the
///                 raffle draw for <day>. The old form "drawRaffle(uint32,uint256)" <day> <packId> still works: it
///                 does the same and additionally checks <packId>'s stored reveal round against the cohort formula.
///         3) forge script script/ExerciseTestnet.s.sol --sig "claim(uint256)" <claimId> --account <winner> --broadcast
///              -> the winner pulls their (mock) QUOTRON prize into their wallet.
contract ExerciseTestnet is Script {
    /// @dev Every entry point is testnet-only. On mainnet convertNow() would run a keeper convert(0, 1)
    ///      with no slippage floor (a sandwich target if run with the real keeper key), and drawRaffle() needs the
    ///      mock oracle.
    modifier testnetOnly() {
        require(block.chainid != 4663, "ExerciseTestnet is testnet-only; never run it on mainnet (4663)");
        _;
    }

    function convertNow() external testnetOnly {
        ITreasuryX treasury = ITreasuryX(_envAddress("TREASURY"));
        vm.startBroadcast();
        treasury.convert(0, 1); // WETH-only sweep floor; keeper-gated (you = keeper)
        vm.stopBroadcast();
        console2.log("convert() done: collected tax -> (mock) QUOTRON -> split to raffle/leaderboard/holder-draw vaults.");
    }

    /// @dev The env seam, so test/ExerciseTestnetDraw.t.sol can drive the real body with per-test addresses.
    function _envAddress(string memory key) internal view virtual returns (address) {
        return vm.envAddress(key);
    }

    function drawRaffle(uint32 day) external testnetOnly {
        _drawRaffle(day, 0, false);
    }

    function drawRaffle(uint32 day, uint256 packId) external testnetOnly {
        _drawRaffle(day, packId, true);
    }

    /// @dev The draw is REVEAL BEFORE POP: PackRegistry._drawCore reverts RevealPending(cohort, round) while any
    ///      non-empty cohort in [day - LIFE_DAYS, day - 1] has its tier round unposted. Posting only one caller-named
    ///      pack's round therefore reverted as soon as two cohorts were live. Every cohort's round is
    ///      roundAt(genesis + (c + 1) * dayLength + revealDelay), the formula PackRegistry._mintPacks stores on each
    ///      of its packs, read here off the registry's own oracle.
    function _drawRaffle(uint32 day, uint256 packId, bool checkPack) internal {
        IMockOracle oracle = IMockOracle(_envAddress("ORACLE"));
        IRaffleX raffle = IRaffleX(_envAddress("RAFFLE_ENGINE"));
        IPacksX packs = IPacksX(_envAddress("PACK_REGISTRY"));

        require(day >= 1, "exercise: day 0 has no draw window");
        require(raffle.currentDay() == day + 1, "not in the draw window yet: wait until the buy-day has closed");
        require(packs.drand() == address(oracle), "exercise: ORACLE is not PackRegistry.drand()");
        if (checkPack) {
            (, uint64 rr, uint32 cd,) = packs.packs(packId);
            require(rr != 0 && rr == _cohortRound(packs, oracle, cd), "exercise: <packId> reveal round != its cohort's");
        }

        uint32 life = packs.LIFE_DAYS();
        uint32 from = day > life ? day - life : 0;
        vm.startBroadcast();
        uint256 posted;
        for (uint32 c = from; c <= day - 1; ++c) {
            if (packs.cohortSize(c) == 0) continue; // an empty cohort pops nothing, so its reveal is irrelevant
            uint64 rr = _cohortRound(packs, oracle, c);
            if (!oracle.isAvailable(rr)) {
                oracle.setBeacon(rr, keccak256(abi.encode("reveal", c))); // tier reveal of cohort c
                ++posted;
            }
        }
        uint64 dr = raffle.drawRound(day);
        if (!oracle.isAvailable(dr)) oracle.setBeacon(dr, keccak256(abi.encode("draw", day))); // winner selection
        raffle.runDraw(day);
        vm.stopBroadcast();
        console2.log("tier-reveal rounds posted (non-empty cohorts in the window):", posted);
        console2.log("raffle draw run for day:", uint256(day));
        console2.log("winners now have claims registered in ClaimManager (see nextClaimId / your claim id).");
    }

    function _cohortRound(IPacksX packs, IMockOracle oracle, uint32 c) internal view returns (uint64) {
        return oracle.roundAt(packs.genesis() + (uint256(c) + 1) * packs.dayLength() + packs.revealDelay());
    }

    function claim(uint256 id) external testnetOnly {
        IClaimX cm = IClaimX(_envAddress("CLAIM_MANAGER"));
        vm.startBroadcast();
        cm.claim(id); // msg.sender must be the recipient of this claim
        vm.stopBroadcast();
        console2.log("claimed prize id:", id);
        console2.log("(mock) QUOTRON is now in the winner's wallet. Full path proven end to end.");
    }
}
