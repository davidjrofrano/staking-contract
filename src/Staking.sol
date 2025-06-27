// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Staking is Ownable, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    struct StakeInfo {
        address staker;
        uint256 amount;
        uint256 duration;
        uint256 endTime;
        uint256 rewardPerToken;
        uint256 reward;
    }

    /* ============ STATE VARIABLES =========== */

    uint256 internal constant ROUND_DURATION = 1000 days;
    uint256 internal constant EARLY_PENALTY_GRACE = 90 days;
    uint256 internal constant LATE_PENALTY_GRACE = 14 days;
    uint256 internal constant LATE_PENALTY_SCALE = 700 days;

    IERC20 public immutable stakingToken;

    address public rewardCharger;
    uint256 public roundCounter = 1;
    uint256 public pendingReward;
    uint256 public roundEndTime;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public stakeIdCounter = 1;
    mapping(uint256 => StakeInfo) public stakeInfos;
    mapping(address => EnumerableSet.UintSet) private stakerStakeIds;

    uint256 private _totalStaked;

    /* ================ EVENTS ================ */

    event RewardChargerUpdated(address indexed newRewardCharger);
    event RewardCharged(uint256 reward);
    event RoundStarted(uint256 indexed round);
    event Staked(
        uint256 indexed stakeId,
        address indexed staker,
        uint256 amount,
        uint256 duration
    );
    event Unstaked(uint256 indexed stakeId);
    event Recovered(address token, uint256 amount);
    event RewardAdded(uint256 reward);

    /* ================ ERRORS ================ */

    error NotRewardCharger();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidStaker();
    error RoundInProgress();
    error CannotRecoverStakingToken();

    /* =============== MODIFIERS ============== */

    modifier onlyRewardCharger() {
        if (msg.sender != rewardCharger) revert NotRewardCharger();
        _;
    }

    /* ============== CONSTRUCTOR ============= */

    constructor(address _stakingToken) Ownable(msg.sender) {
        rewardCharger = msg.sender;
        stakingToken = IERC20(_stakingToken);
    }

    /* ============ VIEW FUNCTIONS ============ */

    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    function isRoundInProgress() public view returns (bool) {
        return roundEndTime > 0 && block.timestamp < roundEndTime;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < roundEndTime ? block.timestamp : roundEndTime;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate) *
                1e18) /
            _totalStaked;
    }

    function earned(uint256 stakeId) public view returns (uint256) {
        StakeInfo memory info = stakeInfos[stakeId];
        return
            (info.amount * (rewardPerToken() - info.rewardPerToken)) /
            1e18 +
            info.reward;
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * ROUND_DURATION;
    }

    function getStakeIds(
        address staker
    ) external view returns (uint256[] memory) {
        return stakerStakeIds[staker].values();
    }

    function getStakeInfo(
        uint256 stakeId
    ) external view returns (StakeInfo memory) {
        return stakeInfos[stakeId];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(
        uint256 amount,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (amount == 0) revert ZeroAmount();

        _totalStaked += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        stakeId = stakeIdCounter++;
        stakeInfos[stakeId] = StakeInfo({
            staker: msg.sender,
            amount: amount,
            duration: duration,
            endTime: block.timestamp + duration,
            rewardPerToken: rewardPerToken(),
            reward: 0
        });
        stakerStakeIds[msg.sender].add(stakeId);

        _updateReward(stakeId);

        emit Staked(stakeId, msg.sender, amount, duration);
    }

    function unstake(uint256 stakeId) public nonReentrant returns (uint256) {
        _updateReward(stakeId);

        StakeInfo storage info = stakeInfos[stakeId];
        if (info.staker != msg.sender) revert InvalidStaker();

        _totalStaked -= info.amount;

        uint256 amountToPay = _takePenalty(stakeId);
        if (amountToPay > 0) stakingToken.safeTransfer(msg.sender, amountToPay);

        stakerStakeIds[msg.sender].remove(stakeId);

        emit Unstaked(stakeId);
        return amountToPay;
    }

    /* ========= RESTRICTED FUNCTIONS ========= */

    function updateRewardCharger(address newRewardCharger) external onlyOwner {
        if (newRewardCharger == address(0)) revert ZeroAddress();
        rewardCharger = newRewardCharger;
        emit RewardChargerUpdated(newRewardCharger);
    }

    function chargeReward(
        uint256 reward
    ) external onlyRewardCharger nonReentrant {
        if (reward == 0) revert ZeroAmount();
        stakingToken.safeTransferFrom(rewardCharger, address(this), reward);

        _updateReward(0);

        if (!isRoundInProgress()) {
            pendingReward += reward;
        } else {
            uint256 remaining = roundEndTime - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / remaining;
        }
        lastUpdateTime = block.timestamp;

        emit RewardCharged(reward);
    }

    function startRound() external onlyOwner {
        if (isRoundInProgress()) revert RoundInProgress();

        rewardRate = pendingReward / ROUND_DURATION;
        pendingReward = 0;
        roundEndTime = block.timestamp + ROUND_DURATION;

        emit RoundStarted(roundCounter++);
    }

    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner {
        if (tokenAddress == address(stakingToken))
            revert CannotRecoverStakingToken();

        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _updateReward(uint256 stakeId) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (stakeId > 0) {
            stakeInfos[stakeId].reward = earned(stakeId);
            stakeInfos[stakeId].rewardPerToken = rewardPerTokenStored;
        }
    }

    function _takePenalty(uint256 stakeId) internal returns (uint256) {
        StakeInfo memory info = stakeInfos[stakeId];
        uint256 realAmount = info.amount + info.reward;
        uint256 penalty;

        uint256 stakedFor = block.timestamp + info.duration - info.endTime;
        if (block.timestamp < info.endTime) {
            /// calculate early penalty
            uint256 penaltyDays = (info.duration + 1) / 2;
            if (penaltyDays < EARLY_PENALTY_GRACE)
                penaltyDays = EARLY_PENALTY_GRACE;

            if (stakedFor == 0 || penaltyDays >= stakedFor) {
                penalty = realAmount;
            } else {
                penalty = (realAmount * penaltyDays) / stakedFor;
            }
        } else {
            /// calculate late penalty
            if (block.timestamp > info.endTime + LATE_PENALTY_GRACE) {
                penalty =
                    (realAmount *
                        (block.timestamp - info.endTime - LATE_PENALTY_GRACE)) /
                    LATE_PENALTY_SCALE;
            }
        }

        if (penalty > realAmount) {
            penalty = realAmount;
            realAmount = 0;
        } else if (penalty > 0) {
            realAmount -= penalty;
        }

        _notifyRewardAmount(penalty);

        delete stakeInfos[stakeId];

        return realAmount;
    }

    function _notifyRewardAmount(uint256 reward) internal {
        _updateReward(0);

        if (block.timestamp >= roundEndTime) {
            pendingReward += reward;
        } else {
            uint256 remaining = roundEndTime - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / remaining;
        }
        lastUpdateTime = block.timestamp;

        emit RewardAdded(reward);
    }
}
