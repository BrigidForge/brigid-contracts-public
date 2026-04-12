// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BrigidVault} from "./BrigidVault.sol";

/// @title BrigidVaultFactory
/// @notice Permissioned factory and canonical registry for official Brigid vaults.
/// @dev Callers must present a valid EIP-712 LaunchPermit signed by the configured
///      permitSigner, or be in the authorizedDeployers whitelist (admin bypass).
contract BrigidVaultFactory is Ownable, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    string public constant VERSION = "1.2.0";
    uint256 public constant MIN_EXECUTION_WINDOW = 6 hours;
    uint256 public constant DEPLOY_TIME_START = 0;

    // EIP-712 type hash for LaunchPermit(address wallet,uint256 expiry)
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("LaunchPermit(address wallet,uint256 expiry)");

    /// @notice The off-chain key whose signatures authorise a wallet to deploy vaults.
    ///         Can be rotated by the owner without redeploying the factory.
    address public permitSigner;

    /// @notice Admin whitelist — bypasses the permit requirement entirely.
    ///         Intended for the factory owner and trusted internal deployers.
    mapping(address => bool) public authorizedDeployers;

    address[] public allVaults;
    mapping(address => address) public vaultCreator;
    mapping(address => address[]) public tokenVaults;

    error PermitExpired();
    error InvalidPermit();
    error NotAuthorized();

    event AuthorizedDeployerSet(address indexed deployer, bool allowed);
    event PermitSignerUpdated(address indexed signer);

    event VaultDeployed(
        address indexed vault,
        address indexed deployer,
        address indexed token,
        uint256 allocation,
        uint256 startTime
    );

    // Kept for backward compatibility with existing indexers.
    event BrigidVaultDeployed(
        address indexed deployer,
        address indexed vault,
        address indexed token,
        address owner,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 cliff,
        uint256 interval,
        uint256 intervals,
        uint256 cancelWindow,
        uint256 withdrawalDelay,
        uint256 executionWindow
    );

    /// @param _permitSigner  The off-chain signer key for LaunchPermits.
    constructor(address _permitSigner)
        Ownable(msg.sender)
        EIP712("BrigidVaultFactory", "1")
    {
        require(_permitSigner != address(0), "Invalid signer");
        permitSigner = _permitSigner;
        authorizedDeployers[msg.sender] = true;
        emit AuthorizedDeployerSet(msg.sender, true);
        emit PermitSignerUpdated(_permitSigner);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Rotate the permit signer key (e.g. after a key compromise or rotation policy).
    function setPermitSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "Invalid signer");
        permitSigner = _signer;
        emit PermitSignerUpdated(_signer);
    }

    /// @notice Grant or revoke a permanent whitelist bypass for a deployer address.
    function setAuthorizedDeployer(address deployer, bool allowed) external onlyOwner {
        require(deployer != address(0), "Invalid deployer");
        authorizedDeployers[deployer] = allowed;
        emit AuthorizedDeployerSet(deployer, allowed);
    }

    /// @notice Batch version of setAuthorizedDeployer.
    function batchAuthorize(address[] calldata deployers, bool allowed) external onlyOwner {
        require(deployers.length <= 100, "Batch too large");
        uint256 length = deployers.length;
        for (uint256 i = 0; i < length; ++i) {
            address deployer = deployers[i];
            require(deployer != address(0), "Invalid deployer");
            authorizedDeployers[deployer] = allowed;
            emit AuthorizedDeployerSet(deployer, allowed);
        }
    }

    /// @notice Transfer factory ownership, auto-authorizing the new owner and
    ///         deauthorizing the previous owner.
    function transferOwnership(address newOwner) public override onlyOwner {
        address oldOwner = owner();
        super.transferOwnership(newOwner);

        if (!authorizedDeployers[newOwner]) {
            authorizedDeployers[newOwner] = true;
            emit AuthorizedDeployerSet(newOwner, true);
        }

        if (authorizedDeployers[oldOwner]) {
            authorizedDeployers[oldOwner] = false;
            emit AuthorizedDeployerSet(oldOwner, false);
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Compute the EIP-712 digest for a LaunchPermit — useful for off-chain signing.
    function permitDigest(address wallet, uint256 expiry) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PERMIT_TYPEHASH, wallet, expiry))
        );
    }

    // ─── Core ─────────────────────────────────────────────────────────────────

    /// @notice Deploy a new BrigidVault.
    /// @dev    Authorization: the caller must either be in `authorizedDeployers` (admin
    ///         bypass) OR supply a valid LaunchPermit signed by `permitSigner`.
    ///         When a permit is required, pass the permit expiry timestamp and the
    ///         65-byte EIP-712 signature. Whitelisted callers may pass (0, "") to skip
    ///         the permit check.
    function createVault(
        address token,
        address vaultOwner,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 cliff,
        uint256 interval,
        uint256 intervals,
        uint256 cancelWindow,
        uint256 withdrawalDelay,
        uint256 executionWindow,
        uint256 permitExpiry,
        bytes calldata permitSig
    ) external nonReentrant returns (address vault) {
        return _createVault(
            msg.sender,
            msg.sender,
            token,
            vaultOwner,
            totalAllocation,
            startTime,
            cliff,
            interval,
            intervals,
            cancelWindow,
            withdrawalDelay,
            executionWindow,
            permitExpiry,
            permitSig
        );
    }

    /// @notice Deploy a new BrigidVault on behalf of an end-user launch deployer.
    /// @dev    Intended for trusted Brigid infrastructure such as the launch orchestrator.
    ///         The caller must be a whitelisted authorized deployer, and the original
    ///         launch deployer must either be whitelisted or supply a valid LaunchPermit.
    function createVaultFor(
        address launchDeployer,
        address token,
        address vaultOwner,
        address funder,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 cliff,
        uint256 interval,
        uint256 intervals,
        uint256 cancelWindow,
        uint256 withdrawalDelay,
        uint256 executionWindow,
        uint256 permitExpiry,
        bytes calldata permitSig
    ) external nonReentrant returns (address vault) {
        if (!authorizedDeployers[msg.sender]) revert NotAuthorized();
        return _createVault(
            launchDeployer,
            funder,
            token,
            vaultOwner,
            totalAllocation,
            startTime,
            cliff,
            interval,
            intervals,
            cancelWindow,
            withdrawalDelay,
            executionWindow,
            permitExpiry,
            permitSig
        );
    }

    function _createVault(
        address launchDeployer,
        address funder,
        address token,
        address vaultOwner,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 cliff,
        uint256 interval,
        uint256 intervals,
        uint256 cancelWindow,
        uint256 withdrawalDelay,
        uint256 executionWindow,
        uint256 permitExpiry,
        bytes calldata permitSig
    ) internal returns (address vault) {
        // Authorization check
        if (!authorizedDeployers[launchDeployer]) {
            if (block.timestamp > permitExpiry) revert PermitExpired();
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(PERMIT_TYPEHASH, launchDeployer, permitExpiry))
            );
            if (digest.recover(permitSig) != permitSigner) revert InvalidPermit();
        }

        bool noVesting = interval == 0 && intervals == 0;
        bool invalidSchedule = (interval == 0) != (intervals == 0);
        uint256 effectiveStartTime = startTime;

        require(launchDeployer != address(0), "Invalid deployer");
        require(token != address(0), "Invalid token");
        require(vaultOwner != address(0), "Invalid owner");
        require(funder != address(0), "Invalid funder");
        require(totalAllocation > 0, "Invalid allocation");
        require(!invalidSchedule, "Invalid schedule");
        require(withdrawalDelay > 0, "Invalid delay");
        require(executionWindow >= MIN_EXECUTION_WINDOW, "Invalid execution window");
        require(cancelWindow < withdrawalDelay, "Cancel window too large");
        if (!noVesting) {
            require(startTime > block.timestamp + 60, "Start time too soon");
            require(interval > 0, "Invalid interval");
            require(intervals > 0, "Invalid schedule");
        } else if (startTime == DEPLOY_TIME_START) {
            effectiveStartTime = block.timestamp;
        } else {
            require(startTime > block.timestamp + 60, "Start time too soon");
        }

        BrigidVault deployedVault = new BrigidVault(
            token,
            vaultOwner,
            funder,
            totalAllocation,
            effectiveStartTime,
            cliff,
            interval,
            intervals,
            cancelWindow,
            withdrawalDelay,
            executionWindow
        );

        vault = address(deployedVault);

        require(address(deployedVault.token()) == token, "Token mismatch");
        require(deployedVault.owner() == vaultOwner, "Owner mismatch");
        require(deployedVault.funder() == funder, "Funder mismatch");
        require(deployedVault.totalAllocation() == totalAllocation, "Allocation mismatch");
        require(deployedVault.startTime() == effectiveStartTime, "Start time mismatch");
        require(deployedVault.withdrawalDelay() == withdrawalDelay, "Delay mismatch");
        require(deployedVault.cliffDuration() == cliff, "Cliff mismatch");
        require(deployedVault.intervalDuration() == interval, "Interval mismatch");
        require(deployedVault.intervalCount() == intervals, "Interval count mismatch");
        require(deployedVault.cancelWindow() == cancelWindow, "Cancel window mismatch");
        require(deployedVault.executionWindow() == executionWindow, "Execution window mismatch");

        allVaults.push(vault);
        vaultCreator[vault] = launchDeployer;
        tokenVaults[token].push(vault);

        emit VaultDeployed(vault, launchDeployer, token, totalAllocation, effectiveStartTime);
        emit BrigidVaultDeployed(
            launchDeployer,
            vault,
            token,
            vaultOwner,
            totalAllocation,
            effectiveStartTime,
            cliff,
            interval,
            intervals,
            cancelWindow,
            withdrawalDelay,
            executionWindow
        );

        return vault;
    }
}
