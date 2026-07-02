// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BrigidUncxV1LPLockerAdapter
/// @notice Adapter from Brigid launch orchestrators to UNCX/UniCrypt V1 UniV2 LP lockers.
/// @dev The adapter receives LP from the calling Brigid orchestrator, approves
///      the configured UNCX locker, and locks with `beneficiary` as withdrawer.
contract BrigidUncxV1LPLockerAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable uncxLocker;
    address public immutable referral;
    bool public immutable feeInEth;

    event UncxLpLocked(
        address indexed lpToken,
        address indexed beneficiary,
        address indexed lockRecord,
        uint256 amount,
        uint256 unlockTime,
        uint256 nativeFeeAmount,
        uint256 providerLockIndex,
        uint256 providerLockId
    );

    error ZeroAddress();
    error ZeroAmount();
    error UnlockNotInFuture();
    error UncxDidNotPullAllLp(uint256 remainingBalance);
    error UncxLockReferenceMissing();
    error UnexpectedUncxLockReference();
    error NativeRefundFailed();

    constructor(address uncxLocker_, address referral_, bool feeInEth_) {
        if (uncxLocker_ == address(0)) revert ZeroAddress();
        uncxLocker = uncxLocker_;
        referral = referral_;
        feeInEth = feeInEth_;
    }

    function lockLpTokens(address lpToken, address beneficiary, uint256 amount, uint256 unlockTime)
        external
        payable
        nonReentrant
        returns (address lockTarget)
    {
        if (lpToken == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert UnlockNotInFuture();

        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        IERC20 lp = IERC20(lpToken);
        lp.safeTransferFrom(msg.sender, address(this), amount);
        lp.forceApprove(uncxLocker, amount);

        uint256 providerLockCountBefore = IUncxV1LPLocker(uncxLocker).getUserNumLocksForToken(beneficiary, lpToken);
        uint256 providerBalanceBefore = lp.balanceOf(uncxLocker);
        IUncxV1LPLocker(uncxLocker).lockLPToken{value: msg.value}(
            lpToken,
            amount,
            unlockTime,
            referral,
            feeInEth,
            beneficiary
        );

        uint256 remaining = lp.balanceOf(address(this));
        if (remaining != 0) revert UncxDidNotPullAllLp(remaining);

        uint256 providerLockedAmount = lp.balanceOf(uncxLocker) - providerBalanceBefore;
        if (providerLockedAmount == 0) revert ZeroAmount();

        uint256 providerLockCountAfter = IUncxV1LPLocker(uncxLocker).getUserNumLocksForToken(beneficiary, lpToken);
        if (providerLockCountAfter <= providerLockCountBefore) revert UncxLockReferenceMissing();
        uint256 providerLockIndex = providerLockCountAfter - 1;
        IUncxV1LPLocker.TokenLock memory providerLock =
            IUncxV1LPLocker(uncxLocker).getUserLockForTokenAtIndex(beneficiary, lpToken, providerLockIndex);
        if (
            providerLock.owner != beneficiary
                || providerLock.amount != providerLockedAmount
                || providerLock.unlockDate != unlockTime
        ) {
            revert UnexpectedUncxLockReference();
        }

        BrigidExternalLPLockRecord record = new BrigidExternalLPLockRecord(
            lpToken,
            beneficiary,
            amount,
            unlockTime,
            uncxLocker,
            uncxLocker,
            providerLockedAmount,
            providerLockIndex,
            providerLock.lockID
        );
        lockTarget = address(record);

        uint256 nativeBalanceAfter = address(this).balance;
        uint256 unusedNative = nativeBalanceAfter > nativeBalanceBefore ? nativeBalanceAfter - nativeBalanceBefore : 0;
        if (unusedNative > 0) {
            (bool refundOk,) = msg.sender.call{value: unusedNative}("");
            if (!refundOk) revert NativeRefundFailed();
        }

        emit UncxLpLocked(
            lpToken,
            beneficiary,
            lockTarget,
            amount,
            unlockTime,
            msg.value,
            providerLockIndex,
            providerLock.lockID
        );
        return lockTarget;
    }

    receive() external payable {}
}

contract BrigidExternalLPLockRecord {
    IERC20 public immutable lpToken;
    address public immutable beneficiary;
    uint256 public immutable depositedAmount;
    uint256 public immutable unlockTime;
    address public immutable provider;
    address public immutable providerLockTarget;
    uint256 public immutable providerLockedAmount;
    uint256 public immutable providerLockIndex;
    uint256 public immutable providerLockId;
    bool public constant providerLockReferenceAvailable = true;
    bool public constant deposited = true;

    constructor(
        address lpToken_,
        address beneficiary_,
        uint256 depositedAmount_,
        uint256 unlockTime_,
        address provider_,
        address providerLockTarget_,
        uint256 providerLockedAmount_,
        uint256 providerLockIndex_,
        uint256 providerLockId_
    ) {
        if (
            lpToken_ == address(0) ||
            beneficiary_ == address(0) ||
            provider_ == address(0) ||
            providerLockTarget_ == address(0)
        ) {
            revert BrigidUncxV1LPLockerAdapter.ZeroAddress();
        }
        if (depositedAmount_ == 0 || providerLockedAmount_ == 0) {
            revert BrigidUncxV1LPLockerAdapter.ZeroAmount();
        }
        if (unlockTime_ <= block.timestamp) {
            revert BrigidUncxV1LPLockerAdapter.UnlockNotInFuture();
        }

        lpToken = IERC20(lpToken_);
        beneficiary = beneficiary_;
        depositedAmount = depositedAmount_;
        unlockTime = unlockTime_;
        provider = provider_;
        providerLockTarget = providerLockTarget_;
        providerLockedAmount = providerLockedAmount_;
        providerLockIndex = providerLockIndex_;
        providerLockId = providerLockId_;
    }

    function timeUntilUnlock() external view returns (uint256) {
        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }
}

interface IUncxV1LPLocker {
    struct TokenLock {
        uint256 lockDate;
        uint256 amount;
        uint256 initialAmount;
        uint256 unlockDate;
        uint256 lockID;
        address owner;
    }

    function lockLPToken(
        address lpToken,
        uint256 amount,
        uint256 unlockDate,
        address referral,
        bool feeInEth,
        address withdrawer
    ) external payable;

    function getUserNumLocksForToken(address user, address lpToken) external view returns (uint256);

    function getUserLockForTokenAtIndex(address user, address lpToken, uint256 index)
        external
        view
        returns (TokenLock memory);
}
