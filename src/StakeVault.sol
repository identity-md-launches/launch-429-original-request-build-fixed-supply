// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Locked staking with owner-funded, time-weighted rewards paid in the staking token.
/// @dev Intended exclusively for the paired LaunchToken. All principal and rewards remain in custody
/// until withdrawn/claimed by their beneficiary. There is deliberately no rescue or admin withdrawal.
contract StakeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_DURATION = 7 days;
    uint256 private constant PRECISION = 1e27;

    IERC20 public immutable token;
    address public immutable owner;
    uint256 public immutable lockDuration;
    bool public depositsPaused;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public unlockAt;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @notice Funded tokens less rewards already paid; never includes principal or direct donations.
    uint256 public rewardReserve;
    /// @notice Rewards released while nobody staked, reused on the next owner top-up.
    uint256 public unallocatedRewards;
    uint256 public periodStart;
    uint256 public periodFinish;
    uint256 public periodReward;
    uint256 public lastUpdateTime;

    error InvalidToken();
    error InvalidOwner();
    error InvalidLock();
    error Unauthorized();
    error DepositsPaused();
    error ZeroAmount();
    error InsufficientStake();
    error StakeLocked(uint256 unlockTime);
    error UnsupportedToken();

    event Staked(address indexed account, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsFunded(uint256 received, uint256 scheduled, uint256 finish);
    event DepositsPauseChanged(bool paused);

    /// @param token_ LaunchToken address, supplied as $token by the release manifest.
    /// @param owner_ Policy owner, supplied as $owner; the factory caller receives no privileges.
    /// @param lockDuration_ Nonzero lock in seconds; the launch parameter is 604800 (seven days).
    constructor(address token_, address owner_, uint256 lockDuration_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        if (owner_ == address(0) || owner_ == address(this)) revert InvalidOwner();
        if (lockDuration_ == 0 || lockDuration_ > type(uint64).max) revert InvalidLock();
        token = IERC20(token_);
        owner = owner_;
        lockDuration = lockDuration_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Stake tokens. Every deposit resets the lock on all of the caller's principal.
    function stake(uint256 amount) external nonReentrant {
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        _receiveExact(msg.sender, amount);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        unlockAt[msg.sender] = block.timestamp + lockDuration;
        emit Staked(msg.sender, amount, unlockAt[msg.sender]);
    }

    /// @notice Withdraw only the caller's unlocked principal; rewards remain claimable separately.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();
        if (block.timestamp < unlockAt[msg.sender]) revert StakeLocked(unlockAt[msg.sender]);
        _updateReward(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (balanceOf[msg.sender] == 0) unlockAt[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim vested rewards even while locked or deposits are paused. A zero claim is a no-op.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _updateReward(msg.sender);
        amount = rewards[msg.sender];
        if (amount == 0) return 0;
        rewards[msg.sender] = 0;
        rewardReserve -= amount;
        token.safeTransfer(msg.sender, amount);
        emit RewardPaid(msg.sender, amount);
    }

    /// @notice Pull rewards from the owner and stream new plus unvested/idle rewards for seven days.
    /// @dev Checkpoints earned rewards first. Top-ups may extend the unvested schedule, never earned rewards.
    function fundRewards(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        _updateReward(address(0));
        _receiveExact(msg.sender, amount);
        uint256 remaining = periodReward - _releasedAt(block.timestamp);
        periodReward = amount + remaining + unallocatedRewards;
        unallocatedRewards = 0;
        rewardReserve += amount;
        periodStart = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;
        lastUpdateTime = block.timestamp;
        emit RewardsFunded(amount, periodReward, periodFinish);
    }

    /// @notice The owner's only custody control is stopping/resuming new deposits.
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPauseChanged(paused);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + Math.mulDiv(_newlyReleased(), PRECISION, totalStaked);
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + Math.mulDiv(balanceOf[account], rewardPerToken() - userRewardPerTokenPaid[account], PRECISION);
    }

    function _updateReward(address account) private {
        uint256 released = _newlyReleased();
        if (totalStaked == 0) {
            unallocatedRewards += released;
        } else {
            rewardPerTokenStored += Math.mulDiv(released, PRECISION, totalStaked);
        }
        lastUpdateTime = Math.min(block.timestamp, periodFinish);
        if (account != address(0)) {
            rewards[
                account
            ] += Math.mulDiv(balanceOf[account], rewardPerTokenStored - userRewardPerTokenPaid[account], PRECISION);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _newlyReleased() private view returns (uint256) {
        return _releasedAt(block.timestamp) - _releasedAt(lastUpdateTime);
    }

    /// @dev Cumulative vesting avoids throwing away funding amounts smaller than the duration in seconds.
    function _releasedAt(uint256 time) private view returns (uint256) {
        if (time <= periodStart) return 0;
        if (time >= periodFinish) return periodReward;
        return Math.mulDiv(periodReward, time - periodStart, REWARD_DURATION);
    }

    function _receiveExact(address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedToken();
    }
}
