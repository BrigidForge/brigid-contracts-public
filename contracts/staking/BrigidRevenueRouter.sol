// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBrigidStakingRevenueTarget {
    function allocateRevenue(uint256 amount) external;
}

/// @title BrigidRevenueRouter
/// @notice Hold-and-distribute contract for protocol revenue.
/// @dev Token safety: only standard fixed-balance ERC-20 tokens are supported.
/// Fee-on-transfer tokens are rejected via balance-delta checks. Rebasing,
/// blacklistable, admin-burnable, or other balance-manipulating tokens are
/// UNSUPPORTED unless explicitly approved by Brigid governance.
contract BrigidRevenueRouter {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant TREASURY_SHARE_BPS = 5_000;
    uint256 public constant STAKING_SHARE_BPS = 4_000;
    uint256 public constant BURN_SHARE_BPS = 1_000;

    IERC20Minimal public immutable token;

    address public owner;
    address public pendingOwner;
    address public treasury;
    address public burnAddress;
    address public staking;
    bool public distributionPaused;

    uint256 private _entered;

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasuryUpdated(address indexed treasury);
    event BurnAddressUpdated(address indexed burnAddress);
    event StakingUpdated(address indexed staking);
    event DistributionPauseUpdated(bool paused);
    event RevenueDistributed(
        address indexed caller,
        uint256 grossAmount,
        uint256 treasuryShare,
        uint256 stakingShare,
        uint256 burnShare
    );
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error DistributionPaused();
    error Reentrancy();
    error StakingNotConfigured();
    error TokenTransferFailed();
    error ApproveFailed();
    error InvalidShareConfiguration();
    error CannotRecoverPrimaryToken();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address token_, address treasury_, address burnAddress_, address staking_) {
        if (token_ == address(0) || treasury_ == address(0) || burnAddress_ == address(0) || staking_ == address(0)) {
            revert ZeroAddress();
        }
        if (TREASURY_SHARE_BPS + STAKING_SHARE_BPS + BURN_SHARE_BPS != BPS_DENOMINATOR) {
            revert InvalidShareConfiguration();
        }

        token = IERC20Minimal(token_);
        owner = msg.sender;
        treasury = treasury_;
        burnAddress = burnAddress_;
        staking = staking_;

        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryUpdated(treasury_);
        emit BurnAddressUpdated(burnAddress_);
        emit StakingUpdated(staking_);
    }

    // Distribute a specific amount from the router's held balance.
    function distribute(uint256 amount) external onlyOwner nonReentrant {
        if (distributionPaused) revert DistributionPaused();
        if (staking == address(0)) revert StakingNotConfigured();
        if (amount == 0) revert ZeroAmount();
        if (token.balanceOf(address(this)) < amount) revert InsufficientBalance();

        _distribute(amount);
    }

    // Distribute the entire token balance held by the router.
    function distributeAll() external onlyOwner nonReentrant {
        if (distributionPaused) revert DistributionPaused();
        if (staking == address(0)) revert StakingNotConfigured();

        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        _distribute(amount);
    }

    /// @notice Preview the 50/40/10 revenue split for a given gross amount.
    /// @dev Micro-scale rounding behavior: for very small amounts (< 3 wei),
    ///      stakingShare may round to zero and the remainder is directed to burn.
    ///      This is accepted micro-scale rounding behavior and is not a security
    ///      issue. Protocols with frequent sub-wei revenue events may observe
    ///      minor economic skew toward burn at staking's expense.
    function previewSplit(uint256 amount)
        public
        pure
        returns (uint256 treasuryShare, uint256 stakingShare, uint256 burnShare)
    {
        if (amount == 0) {
            return (0, 0, 0);
        }

        treasuryShare = (amount * TREASURY_SHARE_BPS) / BPS_DENOMINATOR;
        stakingShare = (amount * STAKING_SHARE_BPS) / BPS_DENOMINATOR;
        burnShare = amount - treasuryShare - stakingShare;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setBurnAddress(address burnAddress_) external onlyOwner {
        if (burnAddress_ == address(0)) revert ZeroAddress();
        burnAddress = burnAddress_;
        emit BurnAddressUpdated(burnAddress_);
    }

    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = staking_;
        emit StakingUpdated(staking_);
    }

    function pauseDistribution(bool paused) external onlyOwner {
        distributionPaused = paused;
        emit DistributionPauseUpdated(paused);
    }

    function transferOwnership(address pendingOwner_) external onlyOwner {
        if (pendingOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = pendingOwner_;
        emit OwnershipTransferStarted(msg.sender, pendingOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function recoverERC20(address token_, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token_ == address(token)) revert CannotRecoverPrimaryToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (!IERC20Minimal(token_).transfer(to, amount)) revert TokenTransferFailed();
        emit ERC20Recovered(token_, to, amount);
    }

    function _distribute(uint256 amount) internal {
        (uint256 treasuryShare, uint256 stakingShare, uint256 burnShare) = previewSplit(amount);

        if (stakingShare > 0) {
            _safeApprove(staking, stakingShare);
            IBrigidStakingRevenueTarget(staking).allocateRevenue(stakingShare);
        }
        _safeTransfer(treasury, treasuryShare);
        _safeTransfer(burnAddress, burnShare);

        emit RevenueDistributed(msg.sender, amount, treasuryShare, stakingShare, burnShare);
    }

    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!token.transfer(to, amount)) revert TokenTransferFailed();
    }

    /// @dev USDT-style tokens require allowance reset to zero before changing a non-zero allowance.
    function _safeApprove(address spender, uint256 amount) internal {
        (bool ok, bytes memory returndata) =
            address(token).call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, 0));
        if (!ok) revert ApproveFailed();
        if (returndata.length > 0 && !abi.decode(returndata, (bool))) revert ApproveFailed();

        if (amount == 0) return;

        (ok, returndata) = address(token).call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok) revert ApproveFailed();
        if (returndata.length > 0 && !abi.decode(returndata, (bool))) revert ApproveFailed();
    }
}
