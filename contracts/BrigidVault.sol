// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BrigidVault
 * @author Brigid Forge
 * @custom:version v2.2.0
 * @notice Visibility before execution.
 *
 * @dev
 * Immutable token vesting vault with enforced withdrawal delays and full on-chain visibility.
 *
 * Core Features:
 * - Dual-bucket system (protected vesting + excess treasury funds)
 * - Single active withdrawal request
 * - Time-delayed execution (withdrawalDelay)
 * - Cancellation window (cancelWindow)
 * - Permissionless execution after delay
 *
 * Important Constraints:
 * - Fee-on-transfer tokens are NOT supported
 * - Constructor enforces cancelWindow < withdrawalDelay
 *
 * Key Behaviors:
 * - Funding uses balance-delta verification (pre/post balance check)
 * - Cliff is a pure lock period; vesting begins only after the cliff ends
 * - Dead-zone exists between cancel window and execution window
 *
 * Audit:
 * - March 2026
 */

/// @notice Token-vesting vault with delayed withdrawals and separate excess fund handling


contract BrigidVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error NotFunder();
    error AlreadyFunded();
    error NotFunded();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error NoActiveRequest();
    error ActiveRequestExists();
    error CancelWindowClosed();
    error TooEarly();
    error RequestExpired();
    error AmountExceedsAvailable();
    error InvalidRequestType();
    error FundingAmountMismatch();

    event Funded(address indexed token, uint256 amount);

    event ExcessDeposited(
        address indexed from,
        address indexed token,
        uint256 amount
    );

    event WithdrawalRequested(
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 requestedAt,
        uint256 executableAt,
        uint256 expiresAt
    );

    event WithdrawalRequestedTyped(
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 requestedAt,
        uint256 executableAt,
        uint256 expiresAt,
        uint8 requestType
    );

    event WithdrawalCanceled(
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 canceledAt
    );

    event WithdrawalCanceledTyped(
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 canceledAt,
        uint8 requestType
    );

    event WithdrawalExecuted(
        address indexed executor,
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 executedAt
    );

    event WithdrawalExecutedTyped(
        address indexed executor,
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 executedAt,
        uint8 requestType
    );

    event WithdrawalExpired(
        address indexed owner,
        uint256 amount,
        bytes32 indexed purposeHash,
        uint256 expiredAt,
        uint8 requestType
    );

    // 0 = none, 1 = protected, 2 = excess
    uint8 public constant REQUEST_TYPE_NONE = 0;
    uint8 public constant REQUEST_TYPE_PROTECTED = 1;
    uint8 public constant REQUEST_TYPE_EXCESS = 2;

    /// @notice Minimum execution window duration.  Ensures observers have
    ///         sufficient time to react to a pending withdrawal before it
    ///         expires and the request must be re-submitted.
    uint256 public constant MIN_EXECUTION_WINDOW = 6 hours;

    /// @dev Keep this struct shape unchanged for UI compatibility.
    ///
    ///      **Zombie-state notice:** when a request's `expiresAt` timestamp passes,
    ///      the struct fields are NOT immediately zeroed in storage.  Cleanup only
    ///      occurs when `_clearRequest` runs inside a *successful* (non-reverting)
    ///      state-changing transaction — such as `requestWithdrawal`,
    ///      `requestExcessWithdrawal`, `cancelWithdrawal`, or `clearExpiredRequest`.
    ///      If a caller attempts `executeWithdrawal` on an already-expired request
    ///      the internal cleanup runs but is rolled back along with the revert, so
    ///      the stale struct fields remain in storage until the next successful call.
    ///
    ///      All view logic (e.g. `isWithdrawalActive`, `hasActiveRequest`,
    ///      `activeRequestedAmount`) gates on `expiresAt` rather than `exists` alone,
    ///      so they return the correct logical state even while stale data sits in
    ///      storage.  Off-chain consumers should do the same — never rely on `exists`
    ///      or `pendingRequestType` in isolation.
    struct PendingWithdrawal {
        uint256 amount;
        bytes32 purposeHash;
        uint256 requestedAt;
        uint256 executableAt;
        uint256 expiresAt;
        bool exists;
    }

    IERC20 public immutable token;
    address public immutable owner;
    address public immutable funder;

    uint256 public immutable totalAllocation;
    uint256 public immutable startTime;

    uint256 public immutable cliffDuration;
    uint256 public immutable intervalDuration;
    uint256 public immutable intervalCount;

    uint256 public immutable cancelWindow;
    uint256 public immutable withdrawalDelay;
    uint256 public immutable executionWindow;

    bool public funded;
    uint256 public totalWithdrawn; // protected bucket only
    uint256 public totalExcessWithdrawn;

    // Separate request-type state so we do not break the existing
    // ABI shape of pendingWithdrawal().
    //
    // IMPORTANT — dev / indexer note:
    // Do NOT use `pendingRequestType` alone to determine whether a request is
    // active.  When a request expires and the subsequent transaction reverts,
    // this field retains its last-set value even though the request is logically
    // dead.  Always combine with an expiry check, or use `hasActiveRequest()`.
    uint8 public pendingRequestType;

    PendingWithdrawal public pendingWithdrawal;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFunder() {
        if (msg.sender != funder) revert NotFunder();
        _;
    }

    constructor(
        address token_,
        address owner_,
        address funder_,
        uint256 totalAllocation_,
        uint256 startTime_,
        uint256 cliffDuration_,
        uint256 intervalDuration_,
        uint256 intervalCount_,
        uint256 cancelWindow_,
        uint256 withdrawalDelay_,
        uint256 executionWindow_
    ) {
        if (token_ == address(0) || owner_ == address(0) || funder_ == address(0)) revert ZeroAddress();
        if (totalAllocation_ == 0) revert ZeroAmount();

        // No backdating. Keeps vesting schedule honest.
        if (startTime_ < block.timestamp) revert InvalidConfig();

        bool noVesting = intervalDuration_ == 0 && intervalCount_ == 0;
        bool invalidSchedule = (intervalDuration_ == 0) != (intervalCount_ == 0);

        if (
            invalidSchedule ||
            (!noVesting && (intervalDuration_ == 0 || intervalCount_ == 0)) ||
            executionWindow_ < MIN_EXECUTION_WINDOW ||
            cancelWindow_ >= withdrawalDelay_
        ) {
            revert InvalidConfig();
        }

        token = IERC20(token_);
        owner = owner_;
        funder = funder_;
        totalAllocation = totalAllocation_;
        startTime = startTime_;

        cliffDuration = cliffDuration_;
        intervalDuration = intervalDuration_;
        intervalCount = intervalCount_;

        cancelWindow = cancelWindow_;
        withdrawalDelay = withdrawalDelay_;
        executionWindow = executionWindow_;
    }

    /// @notice One-time exact funding of the protected / vested allocation bucket.
    /// @dev Fee-on-transfer tokens are not supported; reverts with
    ///      `FundingAmountMismatch` if the received amount does not exactly
    ///      equal `totalAllocation`.
    function fund() external onlyFunder nonReentrant {
        if (funded) revert AlreadyFunded();

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), totalAllocation);
        uint256 afterBalance = token.balanceOf(address(this));

        if (afterBalance - beforeBalance != totalAllocation) {
            revert FundingAmountMismatch();
        }

        funded = true;
        emit Funded(address(token), totalAllocation);
    }

    /// @notice Optional helper for depositing later treasury funds that are
    /// delay-only and not subject to vesting.
    /// Direct ERC20 transfers to the vault also work and will count as excess.
    function depositExcess(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));

        uint256 received = afterBalance - beforeBalance;
        if (received == 0) revert ZeroAmount();

        emit ExcessDeposited(msg.sender, address(token), received);
    }

    /// @notice Protected / vested withdrawal path.
    /// Keeps the original function signature for UI compatibility.
    function requestWithdrawal(
        uint256 amount,
        bytes32 purposeHash
    ) external onlyOwner {
        if (!funded) revert NotFunded();
        if (amount == 0) revert ZeroAmount();

        _clearRequest();

        if (pendingWithdrawal.exists) revert ActiveRequestExists();

        uint256 available = availableToWithdraw();
        if (amount > available) revert AmountExceedsAvailable();

        _setPendingRequest(amount, purposeHash, REQUEST_TYPE_PROTECTED);
    }

    /// @notice Delay-only withdrawal path for post-deployment treasury inflows.
    function requestExcessWithdrawal(
        uint256 amount,
        bytes32 purposeHash
    ) external onlyOwner {
        if (!funded) revert NotFunded();
        if (amount == 0) revert ZeroAmount();

        _clearRequest();

        if (pendingWithdrawal.exists) revert ActiveRequestExists();

        uint256 available = excessAvailableToWithdraw();
        if (amount > available) revert AmountExceedsAvailable();

        _setPendingRequest(amount, purposeHash, REQUEST_TYPE_EXCESS);
    }

    function cancelWithdrawal() external onlyOwner {
        _clearRequest();

        if (!pendingWithdrawal.exists) revert NoActiveRequest();
        if (block.timestamp > pendingWithdrawal.requestedAt + cancelWindow) {
            revert CancelWindowClosed();
        }

        uint256 amount = pendingWithdrawal.amount;
        bytes32 purposeHash = pendingWithdrawal.purposeHash;
        uint8 requestType = pendingRequestType;

        delete pendingWithdrawal;
        pendingRequestType = REQUEST_TYPE_NONE;

        emit WithdrawalCanceledTyped(
            owner,
            amount,
            purposeHash,
            block.timestamp,
            requestType
        );
    }

    /// @notice Execute a pending withdrawal once the delay has elapsed and the
    ///         execution window is still open.
    /// @dev    **Revert-rollback behavior:** `_clearRequest` runs first to evict
    ///         any expired request from storage.  If the request *is* expired,
    ///         `_clearRequest` deletes the struct and resets `pendingRequestType`,
    ///         then this function reverts with `NoActiveRequest`.  Because the EVM
    ///         rolls back all state changes on revert, the cleanup performed by
    ///         `_clearRequest` is also rolled back — the stale struct and type
    ///         remain in storage until the next successful state-changing call.
    ///         Off-chain observers should not infer successful cleanup from a
    ///         reverted `executeWithdrawal` transaction.
    function executeWithdrawal() external nonReentrant {
        _clearRequest();

        if (!pendingWithdrawal.exists) revert NoActiveRequest();
        if (block.timestamp < pendingWithdrawal.executableAt) revert TooEarly();
        if (block.timestamp > pendingWithdrawal.expiresAt) revert RequestExpired();

        uint256 amount = pendingWithdrawal.amount;
        bytes32 purposeHash = pendingWithdrawal.purposeHash;
        uint8 requestType = pendingRequestType;

        if (requestType == REQUEST_TYPE_PROTECTED) {
            totalWithdrawn += amount;
        } else if (requestType == REQUEST_TYPE_EXCESS) {
            totalExcessWithdrawn += amount;
        } else {
            revert InvalidRequestType();
        }

        delete pendingWithdrawal;
        pendingRequestType = REQUEST_TYPE_NONE;

        token.safeTransfer(owner, amount);

        emit WithdrawalExecutedTyped(
            msg.sender,
            owner,
            amount,
            purposeHash,
            block.timestamp,
            requestType
        );
    }

    /// @notice Allows anyone to trigger expiry cleanup for a stale pending request.
    /// @dev Calls the internal `_clearRequest` logic only; no other state is modified.
    function clearExpiredRequest() external {
        _clearRequest();
    }

    function vestedAmount() public view returns (uint256) {
        uint256 unlockStart = startTime + cliffDuration;

        if (block.timestamp < unlockStart) {
            return 0;
        }

        if (intervalDuration == 0 && intervalCount == 0) {
            return totalAllocation;
        }

        uint256 elapsedSinceCliff = block.timestamp - unlockStart;
        uint256 intervalsVested = elapsedSinceCliff / intervalDuration;

        if (intervalsVested > intervalCount) {
            intervalsVested = intervalCount;
        }

        return (totalAllocation * intervalsVested) / intervalCount;
    }

    /// @notice Protected vested funds available for delayed withdrawal.
    function availableToWithdraw() public view returns (uint256) {
        if (!funded) return 0;

        uint256 vested = vestedAmount();
        uint256 reserved = activeProtectedRequestedAmount();

        if (vested <= totalWithdrawn + reserved) {
            return 0;
        }

        uint256 available = vested - totalWithdrawn - reserved;

        // Defensive cap: never expose more than protected balance still held.
        uint256 protectedOutstanding = protectedOutstandingBalance();
        if (available > protectedOutstanding) {
            return protectedOutstanding;
        }

        return available;
    }

    /// @notice Delay-only treasury funds available for withdrawal.
    function excessAvailableToWithdraw() public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        uint256 protectedOutstanding = protectedOutstandingBalance();
        uint256 reserved = activeExcessRequestedAmount();

        if (balance <= protectedOutstanding + reserved) {
            return 0;
        }

        return balance - protectedOutstanding - reserved;
    }

    /// @notice Total protected funds still held in the vault.
    function protectedOutstandingBalance() public view returns (uint256) {
        if (!funded) return 0;
        return totalAllocation - totalWithdrawn;
    }

    /// @notice Current excess balance held in the vault, including any active excess request.
    function excessBalance() public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        uint256 protectedOutstanding = protectedOutstandingBalance();

        if (balance <= protectedOutstanding) {
            return 0;
        }

        return balance - protectedOutstanding;
    }

    /// @notice Existing UI-compatible helper.
    /// Returns the active request amount regardless of request type.
    function activeRequestedAmount() public view returns (uint256) {
        if (!pendingWithdrawal.exists) return 0;
        if (block.timestamp > pendingWithdrawal.expiresAt) return 0;
        return pendingWithdrawal.amount;
    }

    function activeProtectedRequestedAmount() public view returns (uint256) {
        if (pendingRequestType != REQUEST_TYPE_PROTECTED) return 0;
        return activeRequestedAmount();
    }

    function activeExcessRequestedAmount() public view returns (uint256) {
        if (pendingRequestType != REQUEST_TYPE_EXCESS) return 0;
        return activeRequestedAmount();
    }

    function isWithdrawalActive() public view returns (bool) {
        return pendingWithdrawal.exists && block.timestamp <= pendingWithdrawal.expiresAt;
    }

    /// @notice Returns true if and only if a withdrawal request exists and has
    ///         not yet passed its expiry timestamp.
    /// @dev    Preferred over reading `pendingWithdrawal.exists` or
    ///         `pendingRequestType` directly.  Expired requests may linger in
    ///         storage between transactions (see struct-level NatSpec), so raw
    ///         field reads can mislead off-chain consumers and indexers.
    ///         This function applies the expiry gate and is always safe to use.
    function hasActiveRequest() public view returns (bool) {
        return pendingWithdrawal.exists &&
               block.timestamp <= pendingWithdrawal.expiresAt;
    }

    function isCancelable() external view returns (bool) {
        if (!pendingWithdrawal.exists) return false;
        return block.timestamp <= pendingWithdrawal.requestedAt + cancelWindow;
    }

    function isExecutable() external view returns (bool) {
        if (!pendingWithdrawal.exists) return false;
        return
            block.timestamp >= pendingWithdrawal.executableAt &&
            block.timestamp <= pendingWithdrawal.expiresAt;
    }

    function isExpired() external view returns (bool) {
        if (!pendingWithdrawal.exists) return false;
        return block.timestamp > pendingWithdrawal.expiresAt;
    }

    function cliffEnd() external view returns (uint256) {
        return startTime + cliffDuration;
    }

    function fullVestingTime() external view returns (uint256) {
        uint256 unlockStart = startTime + cliffDuration;
        if (intervalDuration == 0 && intervalCount == 0) {
            return unlockStart;
        }
        return unlockStart + (intervalCount * intervalDuration);
    }

    function _setPendingRequest(
        uint256 amount,
        bytes32 purposeHash,
        uint8 requestType
    ) internal {
        if (
            requestType != REQUEST_TYPE_PROTECTED &&
            requestType != REQUEST_TYPE_EXCESS
        ) {
            revert InvalidRequestType();
        }

        uint256 requestedAt = block.timestamp;
        uint256 executableAt = requestedAt + withdrawalDelay;
        uint256 expiresAt = executableAt + executionWindow;

        pendingWithdrawal = PendingWithdrawal({
            amount: amount,
            purposeHash: purposeHash,
            requestedAt: requestedAt,
            executableAt: executableAt,
            expiresAt: expiresAt,
            exists: true
        });

        pendingRequestType = requestType;

        emit WithdrawalRequestedTyped(
            owner,
            amount,
            purposeHash,
            requestedAt,
            executableAt,
            expiresAt,
            requestType
        );
    }

    function _clearRequest() internal {
        if (pendingWithdrawal.exists && block.timestamp > pendingWithdrawal.expiresAt) {
            uint256 amount = pendingWithdrawal.amount;
            bytes32 purposeHash = pendingWithdrawal.purposeHash;
            uint8 requestType = pendingRequestType;

            delete pendingWithdrawal;
            pendingRequestType = REQUEST_TYPE_NONE;

            emit WithdrawalExpired(
                owner,
                amount,
                purposeHash,
                block.timestamp,
                requestType
            );
        }
    }
}
