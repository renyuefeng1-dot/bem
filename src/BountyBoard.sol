// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BEM 任务悬赏板 (BountyBoard)
/// @notice 不可升级、无管理员、无法提取用户资金。发布者托管 BEM，审批后支付给工作者，10% 自动销毁。
contract BountyBoard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status { None, Open, Submitted, Completed, Cancelled, Reclaimed }

    struct Task {
        address poster;
        address worker;        // 当前待审核/已完成的提交者
        uint256 reward;        // 托管的净奖励（已扣除发布费）
        uint64 deadline;
        uint64 submittedAt;
        Status status;
        string metadataURI;
        string submissionURI;
    }

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant BURN_BPS = 1000;       // 支付时销毁 10%
    uint256 public constant POSTING_FEE_BPS = 50;  // 发布时销毁 0.5%
    uint256 public constant REVIEW_WINDOW = 3 days; // 提交后发布者需在此窗口内处理
    uint256 public constant MIN_DURATION = 1 hours;

    IERC20 public immutable token;
    uint8 public immutable tokenDecimals;

    uint256 public taskCount;
    uint256 public totalBurned;
    uint256 public totalEscrowed;
    mapping(uint256 => Task) private _tasks;

    event TaskCreated(uint256 indexed taskId, address indexed poster, uint256 reward, uint256 postingFee, uint64 deadline, string metadataURI);
    event WorkSubmitted(uint256 indexed taskId, address indexed worker, string submissionURI);
    event SubmissionRejected(uint256 indexed taskId, address indexed worker);
    event TaskCompleted(uint256 indexed taskId, address indexed worker, uint256 paidToWorker, uint256 burned, bool autoApproved);
    event TaskCancelled(uint256 indexed taskId, uint256 refund);
    event TaskReclaimed(uint256 indexed taskId, uint256 refund);
    event Burned(uint256 indexed taskId, uint256 amount);

    error InvalidParams();
    error NotPoster();
    error NotWorker();
    error BadStatus();
    error DeadlinePassed();
    error TooEarly();
    error ZeroReceived();

    constructor(IERC20 _token) {
        if (address(_token) == address(0)) revert InvalidParams();
        token = _token;
        uint8 d = 18;
        try IERC20Metadata(address(_token)).decimals() returns (uint8 v) { d = v; } catch {}
        tokenDecimals = d;
    }

    function getTask(uint256 id) external view returns (Task memory) { return _tasks[id]; }

    function createTask(uint256 amount, uint64 deadline, string calldata metadataURI) external nonReentrant returns (uint256 id) {
        if (amount == 0 || deadline < block.timestamp + MIN_DURATION || bytes(metadataURI).length == 0) revert InvalidParams();
        // 交互在前但受 nonReentrant 保护：必须测量实际到账（兼容转账收费代币）
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroReceived();
        uint256 fee = received * POSTING_FEE_BPS / BPS;
        uint256 reward = received - fee;
        if (reward == 0) revert ZeroReceived();

        id = ++taskCount;
        Task storage t = _tasks[id];
        t.poster = msg.sender;
        t.reward = reward;
        t.deadline = deadline;
        t.status = Status.Open;
        t.metadataURI = metadataURI;
        totalEscrowed += reward;
        emit TaskCreated(id, msg.sender, reward, fee, deadline, metadataURI);
        if (fee > 0) _burn(id, fee);
    }

    function submit(uint256 id, string calldata submissionURI) external nonReentrant {
        Task storage t = _tasks[id];
        if (t.status != Status.Open) revert BadStatus();
        if (block.timestamp > t.deadline) revert DeadlinePassed();
        if (msg.sender == t.poster || bytes(submissionURI).length == 0) revert InvalidParams();
        t.worker = msg.sender;
        t.submittedAt = uint64(block.timestamp);
        t.submissionURI = submissionURI;
        t.status = Status.Submitted;
        emit WorkSubmitted(id, msg.sender, submissionURI);
    }

    function approve(uint256 id) external nonReentrant {
        Task storage t = _tasks[id];
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status != Status.Submitted) revert BadStatus();
        _payout(id, t, false);
    }

    /// @notice 拒绝当前提交；仅在审核窗口内可拒绝，超时后工作者可直接领取。
    function reject(uint256 id) external nonReentrant {
        Task storage t = _tasks[id];
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status != Status.Submitted) revert BadStatus();
        if (block.timestamp > t.submittedAt + REVIEW_WINDOW) revert DeadlinePassed();
        address w = t.worker;
        t.worker = address(0);
        t.submittedAt = 0;
        t.submissionURI = "";
        t.status = Status.Open;
        emit SubmissionRejected(id, w);
    }

    /// @notice 发布者未在审核窗口内处理，工作者可自行领取（自动批准）。
    function claim(uint256 id) external nonReentrant {
        Task storage t = _tasks[id];
        if (t.status != Status.Submitted) revert BadStatus();
        if (msg.sender != t.worker) revert NotWorker();
        if (block.timestamp <= t.submittedAt + REVIEW_WINDOW) revert TooEarly();
        _payout(id, t, true);
    }

    function cancel(uint256 id) external nonReentrant {
        Task storage t = _tasks[id];
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status != Status.Open) revert BadStatus();
        uint256 r = t.reward;
        t.status = Status.Cancelled;
        t.reward = 0;
        totalEscrowed -= r;
        emit TaskCancelled(id, r);
        token.safeTransfer(t.poster, r);
    }

    function reclaim(uint256 id) external nonReentrant {
        Task storage t = _tasks[id];
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status != Status.Open) revert BadStatus(); // 有待审核提交时不可取回
        if (block.timestamp <= t.deadline) revert TooEarly();
        uint256 r = t.reward;
        t.status = Status.Reclaimed;
        t.reward = 0;
        totalEscrowed -= r;
        emit TaskReclaimed(id, r);
        token.safeTransfer(t.poster, r);
    }

    function _payout(uint256 id, Task storage t, bool auto_) internal {
        uint256 r = t.reward;
        uint256 burnAmt = r * BURN_BPS / BPS;
        uint256 pay = r - burnAmt;
        t.status = Status.Completed;
        totalEscrowed -= r;
        emit TaskCompleted(id, t.worker, pay, burnAmt, auto_);
        token.safeTransfer(t.worker, pay);
        if (burnAmt > 0) _burn(id, burnAmt);
    }

    function _burn(uint256 id, uint256 amt) internal {
        totalBurned += amt;
        emit Burned(id, amt);
        token.safeTransfer(BURN_ADDRESS, amt);
    }
}
