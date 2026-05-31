// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BrigidTokenRegistry
/// @notice Simple owner-controlled registry of Brigid-approved ERC20 tokens.
/// @dev Only tokens explicitly approved by the owner may be used in vault
///      creation and launch workflows. This prevents incompatibilities with
///      fee-on-transfer, rebasing, blacklistable, or admin-burn tokens.
contract BrigidTokenRegistry {
    mapping(address => bool) public approved;

    address public owner;
    address public pendingOwner;

    event TokenApproved(address indexed token, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    error NotOwner();
    error NotPendingOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
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

    /// @notice Approve or revoke approval for a token.
    /// @param token  The ERC20 token address.
    /// @param status true to approve, false to revoke.
    function setApproved(address token, bool status) external onlyOwner {
        approved[token] = status;
        emit TokenApproved(token, status);
    }

    /// @notice Check whether a token is approved.
    function isApproved(address token) external view returns (bool) {
        return approved[token];
    }
}
