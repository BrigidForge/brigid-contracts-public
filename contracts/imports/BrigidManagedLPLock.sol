// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BrigidManagedLPLock
/// @notice Canonical LP lock used by BrigidLaunchOrchestrator.
/// @dev The orchestrator is the single allowed depositor, while the launch deployer
///      remains the sole beneficiary who can withdraw after the unlock time.
contract BrigidManagedLPLock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotBeneficiary();
    error NotDepositor();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyDeposited();
    error NothingToWithdraw();
    error StillLocked();
    error UnlockNotInFuture();

    IERC20 public immutable lpToken;
    address public immutable beneficiary;
    address public immutable depositor;
    uint256 public immutable unlockTime;

    uint256 public depositedAmount;
    bool public deposited;

    event Deposited(
        address indexed beneficiary,
        address indexed depositor,
        address indexed lpToken,
        uint256 amount,
        uint256 unlockTime
    );

    event Withdrawn(
        address indexed beneficiary,
        address indexed lpToken,
        uint256 amount,
        uint256 withdrawnAt
    );

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    modifier onlyDepositor() {
        if (msg.sender != depositor) revert NotDepositor();
        _;
    }

    constructor(address lpToken_, address beneficiary_, address depositor_, uint256 unlockTime_) {
        if (lpToken_ == address(0) || beneficiary_ == address(0) || depositor_ == address(0)) revert ZeroAddress();
        if (unlockTime_ <= block.timestamp) revert UnlockNotInFuture();

        lpToken = IERC20(lpToken_);
        beneficiary = beneficiary_;
        depositor = depositor_;
        unlockTime = unlockTime_;
    }

    function deposit(uint256 amount) external onlyDepositor nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (deposited) revert AlreadyDeposited();

        deposited = true;
        depositedAmount = amount;
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(beneficiary, depositor, address(lpToken), amount, unlockTime);
    }

    function withdraw() external onlyBeneficiary nonReentrant {
        if (!deposited) revert NothingToWithdraw();
        if (block.timestamp < unlockTime) revert StillLocked();

        uint256 balance = lpToken.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();

        lpToken.safeTransfer(beneficiary, balance);
        emit Withdrawn(beneficiary, address(lpToken), balance, block.timestamp);
    }
}
