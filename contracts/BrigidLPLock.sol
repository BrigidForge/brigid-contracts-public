// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BrigidLPLock
 * @author Brigid Forge
 * @notice Single-deposit LP token time-lock vault.
 *
 * @dev
 * Designed for locking PancakeSwap (or any DEX) LP tokens to signal
 * liquidity commitment to token holders. Core properties:
 *
 * - Single deposit: once tokens are deposited, no additional deposits
 *   are accepted. The vault holds exactly one LP token balance.
 * - Immutable unlock: the unlock timestamp is set at construction and
 *   cannot be changed by anyone — not even the owner.
 * - Delayed withdrawal: the owner may only withdraw after unlockTime.
 * - No custody: the lock contract holds tokens autonomously; Brigid
 *   has no access to the locked funds.
 *
 * Intended usage:
 * 1. Deploy with (lpToken, owner, unlockTime).
 * 2. Owner approves this contract for `amount` LP tokens.
 * 3. Owner calls deposit(amount).
 * 4. After unlockTime, owner calls withdraw().
 *
 * Important constraints:
 * - Fee-on-transfer LP tokens are NOT supported.
 * - unlockTime must be strictly in the future at construction.
 */
contract BrigidLPLock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyDeposited();
    error NothingToWithdraw();
    error StillLocked();
    error UnlockNotInFuture();

    /// @notice The LP token being locked.
    IERC20 public immutable lpToken;

    /// @notice Address that may deposit and later withdraw.
    address public immutable owner;

    /// @notice Unix timestamp after which the owner may withdraw.
    uint256 public immutable unlockTime;

    /// @notice Amount of LP tokens deposited.
    uint256 public depositedAmount;

    /// @notice Whether the single deposit has occurred.
    bool public deposited;

    event Deposited(
        address indexed owner,
        address indexed lpToken,
        uint256 amount,
        uint256 unlockTime
    );

    event Withdrawn(
        address indexed owner,
        address indexed lpToken,
        uint256 amount,
        uint256 withdrawnAt
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @param lpToken_    Address of the LP token to lock.
     * @param owner_      Address that controls this lock vault.
     * @param unlockTime_ Unix timestamp after which withdrawal is permitted.
     *                    Must be strictly greater than block.timestamp.
     */
    constructor(address lpToken_, address owner_, uint256 unlockTime_) {
        if (lpToken_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        if (unlockTime_ <= block.timestamp) revert UnlockNotInFuture();

        lpToken = IERC20(lpToken_);
        owner = owner_;
        unlockTime = unlockTime_;
    }

    /**
     * @notice Deposit LP tokens into this lock vault.
     * @dev    Only the owner may deposit. May only be called once.
     *         The caller must have approved this contract for `amount` tokens
     *         before calling.
     * @param amount Amount of LP tokens to lock.
     */
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (deposited) revert AlreadyDeposited();

        deposited = true;
        depositedAmount = amount;

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(owner, address(lpToken), amount, unlockTime);
    }

    /**
     * @notice Withdraw all LP tokens after the lock period has elapsed.
     * @dev    Only the owner may withdraw. Requires deposited == true
     *         and block.timestamp >= unlockTime.
     */
    function withdraw() external onlyOwner nonReentrant {
        if (!deposited) revert NothingToWithdraw();
        if (block.timestamp < unlockTime) revert StillLocked();

        uint256 balance = lpToken.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();

        lpToken.safeTransfer(owner, balance);

        emit Withdrawn(owner, address(lpToken), balance, block.timestamp);
    }

    /**
     * @notice Returns the number of seconds remaining until unlock.
     *         Returns 0 if already unlocked.
     */
    function timeUntilUnlock() external view returns (uint256) {
        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }
}
