// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BrigidStaking
/// @notice Fixed-lot staking engine with maturity-gated revenue shares.
/// @dev Token safety: this contract uses raw-token accounting (not share-based).
/// Fee-on-transfer tokens are rejected via balance-delta checks, but rebasing,
/// blacklistable, admin-burnable, or other balance-manipulating tokens are
/// UNSUPPORTED and may cause insolvency. Only standard fixed-balance ERC-20
/// tokens should be used unless explicitly approved by Brigid governance.
contract BrigidStaking {
    uint256 private constant ACC_REWARD_PRECISION = 1e18;

    struct StakeLot {
        address owner;
        uint256 principalAmount;
        uint64 stakedAt;
        uint64 eligibleAt;
        uint256 rewardPerTokenPaid;
        uint256 accruedRewards;
        bool eligible;
        bool withdrawn;
    }

    IERC20 public immutable stakingToken;
    uint256 public immutable eligibilityDelay;

    address public owner;
    address public pendingOwner;
    address public treasury;
    address public revenueDistributor;

    bool public stakingPaused;
    bool public allocationsPaused;

    uint256 public nextLotId = 1;
    uint256 public nextUnmaturedLotId = 1;
    uint256 public totalActivePrincipal;
    uint256 public totalEligiblePrincipal;
    uint256 public accRewardPerEligibleToken;
    uint256 public pendingAllocationDust;
    uint256 private _entered;

    mapping(uint256 => StakeLot) public lots;
    mapping(address => uint256[]) private _accountLotIds;

    event Staked(address indexed user, uint256 indexed lotId, uint256 amount, uint256 eligibleAt);
    event RewardsClaimed(address indexed user, uint256 amount);
    event LotWithdrawn(address indexed user, uint256 indexed lotId, uint256 principal, uint256 rewards);
    event RevenueAllocated(address indexed caller, uint256 amount, uint256 eligiblePrincipal);
    event RevenueRedirectedToTreasury(address indexed caller, uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event RevenueDistributorUpdated(address indexed distributor);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event StakingPauseUpdated(bool paused);
    event AllocationsPauseUpdated(bool paused);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event SurplusStakingTokensRecovered(address indexed to, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error NotRevenueDistributor();
    error ZeroAddress();
    error ZeroAmount();
    error StakingPaused();
    error AllocationsPaused();
    error LotNotFound();
    error NotLotOwner();
    error LotAlreadyWithdrawn();
    error TokenTransferFailed();
    error Reentrancy();
    error UnexpectedTransferAmount();
    error CannotRecoverStakingToken();
    error InsufficientSurplus();
    error InvalidEligibilityDelay();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRevenueDistributor() {
        if (msg.sender != revenueDistributor) revert NotRevenueDistributor();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address stakingToken_, address treasury_, address revenueDistributor_, uint256 eligibilityDelay_) {
        if (stakingToken_ == address(0) || treasury_ == address(0) || revenueDistributor_ == address(0)) {
            revert ZeroAddress();
        }
        if (eligibilityDelay_ == 0) revert InvalidEligibilityDelay();

        stakingToken = IERC20(stakingToken_);
        eligibilityDelay = eligibilityDelay_;
        owner = msg.sender;
        treasury = treasury_;
        revenueDistributor = revenueDistributor_;

        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryUpdated(treasury_);
        emit RevenueDistributorUpdated(revenueDistributor_);
    }

    function stake(uint256 amount) external nonReentrant returns (uint256 lotId) {
        if (stakingPaused) revert StakingPaused();
        if (amount == 0) revert ZeroAmount();

        _syncEligibleLots();
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        if (stakingToken.balanceOf(address(this)) - beforeBalance != amount) {
            revert UnexpectedTransferAmount();
        }

        lotId = nextLotId++;

        StakeLot storage lot = lots[lotId];
        lot.owner = msg.sender;
        lot.principalAmount = amount;
        lot.stakedAt = uint64(block.timestamp);
        lot.eligibleAt = uint64(block.timestamp + eligibilityDelay);
        lot.rewardPerTokenPaid = accRewardPerEligibleToken;

        _accountLotIds[msg.sender].push(lotId);
        totalActivePrincipal += amount;

        emit Staked(msg.sender, lotId, amount, lot.eligibleAt);
    }

    function claim() external nonReentrant returns (uint256 rewards) {
        _syncEligibleLots();
        uint256[] storage accountLots = _accountLotIds[msg.sender];
        uint256 length = accountLots.length;

        for (uint256 i = 0; i < length; ++i) {
            rewards += _claimableForLot(accountLots[i]);
        }

        if (rewards == 0) {
            return 0;
        }

        _safeTransfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, rewards);
    }

    function claimRange(uint256 startIndex, uint256 count) external nonReentrant returns (uint256 rewards) {
        _syncEligibleLotsLimited(count);
        rewards = _claimRange(msg.sender, startIndex, count);

        if (rewards == 0) {
            return 0;
        }

        _safeTransfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, rewards);
    }

    function unstakeLot(uint256 lotId) external nonReentrant returns (uint256 principal, uint256 rewards) {
        _syncEligibleLots();
        StakeLot storage lot = lots[lotId];
        if (lot.owner == address(0)) revert LotNotFound();
        if (lot.owner != msg.sender) revert NotLotOwner();
        if (lot.withdrawn) revert LotAlreadyWithdrawn();

        principal = lot.principalAmount;
        rewards = _claimableForLot(lotId);
        bool wasEligible = _isEligible(lot);

        lot.withdrawn = true;
        totalActivePrincipal -= principal;

        if (wasEligible) {
            totalEligiblePrincipal -= principal;
        }

        uint256 payout = principal + rewards;
        _safeTransfer(msg.sender, payout);

        emit LotWithdrawn(msg.sender, lotId, principal, rewards);
        if (rewards > 0) {
            emit RewardsClaimed(msg.sender, rewards);
        }
    }

    function allocateRevenue(uint256 amount) external onlyRevenueDistributor nonReentrant {
        if (allocationsPaused) revert AllocationsPaused();
        if (amount == 0) revert ZeroAmount();

        _syncEligibleLots();
        uint256 beforeBalance = stakingToken.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        if (stakingToken.balanceOf(address(this)) - beforeBalance != amount) {
            revert UnexpectedTransferAmount();
        }

        uint256 eligiblePrincipal = totalEligiblePrincipal;
        if (eligiblePrincipal == 0) {
            uint256 redirectAmount = amount + pendingAllocationDust;
            pendingAllocationDust = 0;
            _safeTransfer(treasury, redirectAmount);
            emit RevenueRedirectedToTreasury(msg.sender, redirectAmount);
            return;
        }

        uint256 totalAmount = amount + pendingAllocationDust;
        uint256 increment = (totalAmount * ACC_REWARD_PRECISION) / eligiblePrincipal;
        if (increment == 0) {
            pendingAllocationDust = totalAmount;
            emit RevenueAllocated(msg.sender, amount, eligiblePrincipal);
            return;
        }

        // Consume all pending dust in this non-zero increment allocation.
        // The dust from this specific allocation (if any) is bounded and
        // becomes owner-recoverable surplus, identical to the pre-fix behavior.
        pendingAllocationDust = 0;
        accRewardPerEligibleToken += increment;

        emit RevenueAllocated(msg.sender, amount, eligiblePrincipal);
    }

    function claimable(address account) external view returns (uint256 totalRewards) {
        uint256[] storage accountLots = _accountLotIds[account];
        uint256 length = accountLots.length;
        for (uint256 i = 0; i < length; ++i) {
            totalRewards += _previewClaimableForLot(accountLots[i], accRewardPerEligibleToken);
        }
    }

    function claimableRange(address account, uint256 startIndex, uint256 count)
        external
        view
        returns (uint256 totalRewards)
    {
        uint256[] storage accountLots = _accountLotIds[account];
        uint256 endIndex = _boundedEnd(startIndex, count, accountLots.length);

        for (uint256 i = startIndex; i < endIndex; ++i) {
            totalRewards += _previewClaimableForLot(accountLots[i], accRewardPerEligibleToken);
        }
    }

    function syncEligibleLots(uint256 maxLots) external nonReentrant returns (uint256 synced) {
        synced = _syncEligibleLotsLimited(maxLots);
    }

    function eligibleStake() public view returns (uint256 eligiblePrincipal) {
        eligiblePrincipal = totalEligiblePrincipal;
        uint256 lotId = nextUnmaturedLotId;
        while (lotId < nextLotId) {
            StakeLot storage lot = lots[lotId];
            if (lot.owner == address(0) || lot.eligibleAt > block.timestamp) {
                break;
            }
            if (!lot.withdrawn) {
                eligiblePrincipal += lot.principalAmount;
            }
            unchecked {
                ++lotId;
            }
        }
    }

    function activeLots(address account) external view returns (uint256[] memory ids) {
        uint256[] storage accountLots = _accountLotIds[account];
        uint256 activeCount = 0;
        uint256 length = accountLots.length;

        for (uint256 i = 0; i < length; ++i) {
            if (!lots[accountLots[i]].withdrawn) {
                ++activeCount;
            }
        }

        ids = new uint256[](activeCount);
        uint256 writeIndex = 0;
        for (uint256 i = 0; i < length; ++i) {
            uint256 lotId = accountLots[i];
            if (!lots[lotId].withdrawn) {
                ids[writeIndex++] = lotId;
            }
        }
    }

    function lotInfo(uint256 lotId) external view returns (StakeLot memory) {
        return lots[lotId];
    }

    function totalClaimableRewards() public view returns (uint256 totalRewards) {
        uint256 currentRewardIndex = accRewardPerEligibleToken;
        for (uint256 lotId = 1; lotId < nextLotId; ++lotId) {
            totalRewards += _previewClaimableForLot(lotId, currentRewardIndex);
        }
    }

    function totalClaimableRewardsRange(uint256 startLotId, uint256 count)
        external
        view
        returns (uint256 totalRewards)
    {
        uint256 currentRewardIndex = accRewardPerEligibleToken;
        uint256 lotId = startLotId == 0 ? 1 : startLotId;
        uint256 endLotId = lotId + count;
        if (endLotId > nextLotId || endLotId < lotId) {
            endLotId = nextLotId;
        }

        while (lotId < endLotId) {
            totalRewards += _previewClaimableForLot(lotId, currentRewardIndex);
            unchecked {
                ++lotId;
            }
        }
    }

    function totalRequiredBacking() public view returns (uint256) {
        return totalActivePrincipal + totalClaimableRewards() + pendingAllocationDust;
    }

    function surplusTokenBalance() public view returns (uint256 surplus) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));
        uint256 requiredBacking = totalRequiredBacking();

        if (contractBalance > requiredBacking) {
            surplus = contractBalance - requiredBacking;
        }
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setRevenueDistributor(address revenueDistributor_) external onlyOwner {
        if (revenueDistributor_ == address(0)) revert ZeroAddress();
        revenueDistributor = revenueDistributor_;
        emit RevenueDistributorUpdated(revenueDistributor_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function pauseStaking(bool paused) external onlyOwner {
        stakingPaused = paused;
        emit StakingPauseUpdated(paused);
    }

    function pauseAllocations(bool paused) external onlyOwner {
        allocationsPaused = paused;
        emit AllocationsPauseUpdated(paused);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();

        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TokenTransferFailed();

        emit ERC20Recovered(token, to, amount);
    }

    function recoverSurplusStakingTokens(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _syncEligibleLots();
        uint256 surplus = surplusTokenBalance();
        if (amount > surplus) revert InsufficientSurplus();

        _safeTransfer(to, amount);
        emit SurplusStakingTokensRecovered(to, amount);
    }

    function _claimableForLot(uint256 lotId) internal returns (uint256 rewards) {
        StakeLot storage lot = lots[lotId];
        rewards = _previewClaimable(lot);
        lot.accruedRewards = 0;
        lot.rewardPerTokenPaid = accRewardPerEligibleToken;
    }

    function _claimRange(address account, uint256 startIndex, uint256 count) internal returns (uint256 rewards) {
        uint256[] storage accountLots = _accountLotIds[account];
        uint256 endIndex = _boundedEnd(startIndex, count, accountLots.length);

        for (uint256 i = startIndex; i < endIndex; ++i) {
            rewards += _claimableForLot(accountLots[i]);
        }
    }

    function _boundedEnd(uint256 startIndex, uint256 count, uint256 length) internal pure returns (uint256 endIndex) {
        if (startIndex >= length || count == 0) {
            return startIndex;
        }
        endIndex = startIndex + count;
        if (endIndex > length || endIndex < startIndex) {
            endIndex = length;
        }
    }

    function _previewClaimableForLot(uint256 lotId, uint256 currentRewardIndex) internal view returns (uint256 rewards) {
        StakeLot storage lot = lots[lotId];
        rewards = _previewClaimable(lot, currentRewardIndex);
    }

    function _previewClaimable(StakeLot storage lot) internal view returns (uint256 rewards) {
        return _previewClaimable(lot, accRewardPerEligibleToken);
    }

    function _previewClaimable(StakeLot storage lot, uint256 currentRewardIndex) internal view returns (uint256 rewards) {
        rewards = lot.accruedRewards;
        if (lot.withdrawn) {
            return rewards;
        }

        bool eligibleNow = lot.eligible || (lot.owner != address(0) && block.timestamp >= lot.eligibleAt);
        if (!eligibleNow) {
            return rewards;
        }

        uint256 rewardPerTokenPaid = lot.eligible ? lot.rewardPerTokenPaid : currentRewardIndex;
        uint256 accruedPerToken = currentRewardIndex - rewardPerTokenPaid;
        rewards += (lot.principalAmount * accruedPerToken) / ACC_REWARD_PRECISION;
    }

    function _isEligible(StakeLot storage lot) internal view returns (bool) {
        return lot.owner != address(0) && !lot.withdrawn && block.timestamp >= lot.eligibleAt;
    }

    function _syncEligibleLots() internal {
        _syncEligibleLotsLimited(type(uint256).max);
    }

    function _syncEligibleLotsLimited(uint256 maxLots) internal returns (uint256 synced) {
        uint256 lotId = nextUnmaturedLotId;
        while (lotId < nextLotId && synced < maxLots) {
            StakeLot storage lot = lots[lotId];
            if (lot.owner == address(0) || lot.eligibleAt > block.timestamp) {
                break;
            }

            if (!lot.withdrawn && !lot.eligible) {
                lot.eligible = true;
                lot.rewardPerTokenPaid = accRewardPerEligibleToken;
                totalEligiblePrincipal += lot.principalAmount;
            }

            unchecked {
                ++lotId;
                ++synced;
            }
        }
        nextUnmaturedLotId = lotId;
    }

    function _safeTransfer(address to, uint256 amount) internal {
        bool ok = stakingToken.transfer(to, amount);
        if (!ok) revert TokenTransferFailed();
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        bool ok = stakingToken.transferFrom(from, to, amount);
        if (!ok) revert TokenTransferFailed();
    }
}
