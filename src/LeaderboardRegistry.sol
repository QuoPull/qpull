// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ILeaderboardRegistry } from "./interfaces/IRegistries.sol";

/// @title  LeaderboardRegistry
/// @notice Tallies buy points per weekly period (buys only) and maintains the running
///         top-25 board. Points are WETH wei from two sources that share one pool: (1) a buy's hook credit,
///         the WETH it paid, backed by the 4% WETH fee the same swap took (QpullTaxHook); and (2) rip
///         XP from PackRegistry.claimRipXp, RIP_XP_BPS (1.8%) of the pack's cohort ticket price times its
///         rarity weight 1/2/4/10, so about 2.45% of a pack's price in expectation, and in expectation a
///         point costs ~3.9% in tax. Sells never touch this, a redistributive top-N pool must not be fed by
///         sells (they'd spend others' money to buy rank).
///
/// @dev    Board maintenance is O(1) when the buyer is already on the board or the board isn't full,
///         and O(25) only when a newcomer displaces the current minimum. The board is unsorted:
///         rank order does not matter because LeaderboardEngine.distribute pays each member pro-rata by its
///         own points over the week's totalPoints.
///         Non-renounceable: setRecorder / setXpRecorder are write-once wiring, and each kind of point is
///         recorded only once its recorder is set.
contract LeaderboardRegistry is ILeaderboardRegistry, NonRenounceableOwnable2Step {
    uint256 public immutable genesis;
    // Weeks are anchored to Sunday 00:00 UTC (payouts land on Sundays). Derived from genesis, so the
    // registry and engine compute identical week numbers without passing a separate arg. Unix epoch is a
    // Thursday, so a Sunday 00:00 UTC satisfies (ts % 7 days == 3 days); weekAnchor is the most recent such
    // instant at or before genesis, giving a Sunday-aligned weekly leaderboard.
    uint256 public immutable weekAnchor;
    // `virtual` so a TESTNET-ONLY subclass can shorten the week; MUST mirror LeaderboardEngine.WEEK() so
    // accrual-week and distribute-week numbering stay byte-for-byte identical. Mainnet + tests keep 7 days.
    // Public on purpose: LeaderboardEngine's constructor reads this (and weekAnchor) and reverts with
    // CadenceMismatch on any divergence (a cadence cross-check that mirrors the genesis check).
    function WEEK() public view virtual returns (uint256) { return 7 days; }
    uint256 public constant BOARD_SIZE = 25;

    address public recorder; // QpullTaxHook, only caller of recordBuy
    address public xpRecorder; // PackRegistry, only caller of recordXp (rarity XP for non-winning rips)

    struct Entry {
        address addr;
        uint256 points;
    }

    mapping(uint256 => Entry[BOARD_SIZE]) internal board; // week => top-25
    mapping(uint256 => uint256) public boardCount; // week => filled slots (≤ 25)
    mapping(uint256 => mapping(address => uint256)) public points; // week => addr => points
    mapping(uint256 => mapping(address => uint256)) internal boardIndex; // week => addr => (slot+1); 0 = off-board
    // Total points across ALL buyers this week (board and non-board). The payout divides by THIS, not by the
    // 25-member board sum, so a board eviction never shrinks the denominator.
    mapping(uint256 => uint256) public totalPoints;

    event RecorderSet(address recorder);
    event XpRecorderSet(address xpRecorder);
    event PointsAdded(uint256 indexed week, address indexed buyer, uint256 amount, uint256 total);

    error NotRecorder();
    error NotXpRecorder();
    error AlreadySet(); // recorder is write-once

    modifier onlyRecorder() {
        if (msg.sender != recorder) revert NotRecorder();
        _;
    }

    constructor(uint256 genesis_, address initialOwner) Ownable(initialOwner) {
        genesis = genesis_;
        // most recent Sunday 00:00 UTC at or before genesis (guarded for tiny test genesis values). Derivation
        // is `virtual` so the TESTNET-ONLY subclass can anchor to genesis with a short week (mirrors the engine).
        weekAnchor = _deriveWeekAnchor(genesis_);
    }

    /// @dev `virtual` for the TESTNET-ONLY subclass; MUST mirror LeaderboardEngine._deriveWeekAnchor.
    function _deriveWeekAnchor(uint256 genesis_) internal view virtual returns (uint256) {
        return genesis_ >= 3 days ? genesis_ - ((genesis_ - 3 days) % 7 days) : 0;
    }

    // Write-once: the recorder cannot be changed after it is set.
    function setRecorder(address t) external onlyOwner {
        if (t == address(0) || recorder != address(0)) revert AlreadySet();
        recorder = t;
        emit RecorderSet(t);
    }

    // Write-once, mirrors setRecorder. A SEPARATE recorder from the hook: only PackRegistry.claimRipXp may
    // mint rip XP, so each recorder can only add its own kind of points.
    function setXpRecorder(address t) external onlyOwner {
        if (t == address(0) || xpRecorder != address(0)) revert AlreadySet();
        xpRecorder = t;
        emit XpRecorderSet(t);
    }

    /// @inheritdoc ILeaderboardRegistry
    function recordBuy(address buyer, uint256 grossValue) external override onlyRecorder {
        _addPoints(buyer, grossValue);
    }

    /// @inheritdoc ILeaderboardRegistry
    /// @notice Rarity-weighted XP for a final non-winning ripped pack. Same points pool as buys, so it
    ///         flows through the identical board + all-buyer denominator with no separate path.
    function recordXp(address who, uint256 amount) external override {
        if (msg.sender != xpRecorder) revert NotXpRecorder();
        _addPoints(who, amount);
    }

    function _addPoints(address who, uint256 amount) internal {
        if (amount == 0) return;
        uint256 w = _week();
        totalPoints[w] += amount; // all-buyer denominator (buys + rip XP share it)
        uint256 p = points[w][who] + amount;
        points[w][who] = p;
        _updateBoard(w, who, p);
        emit PointsAdded(w, who, amount, p);
    }

    function _updateBoard(uint256 w, address addr, uint256 p) internal {
        uint256 idx = boardIndex[w][addr];
        if (idx != 0) {
            board[w][idx - 1].points = p; // already on board, bump points, keep slot
            return;
        }
        uint256 cnt = boardCount[w];
        if (cnt < BOARD_SIZE) {
            board[w][cnt] = Entry(addr, p);
            boardIndex[w][addr] = cnt + 1;
            boardCount[w] = cnt + 1;
            return;
        }
        // board full: locate the current minimum
        uint256 minI;
        uint256 minP = type(uint256).max;
        for (uint256 i; i < BOARD_SIZE; ++i) {
            uint256 pp = board[w][i].points;
            if (pp < minP) {
                minP = pp;
                minI = i;
            }
        }
        if (p > minP) {
            address evicted = board[w][minI].addr;
            boardIndex[w][evicted] = 0;
            board[w][minI] = Entry(addr, p);
            boardIndex[w][addr] = minI + 1;
        }
    }

    function boardAt(uint256 w, uint256 i) external view returns (address addr, uint256 pts) {
        Entry storage e = board[w][i];
        return (e.addr, e.points);
    }

    function isOnBoard(uint256 w, address a) external view returns (bool) {
        return boardIndex[w][a] != 0;
    }

    function _week() internal view returns (uint256) {
        if (block.timestamp < weekAnchor) return 0;
        return (block.timestamp - weekAnchor) / WEEK(); // Sunday-aligned week index
    }

    function currentWeek() external view returns (uint256) {
        return _week();
    }
}
