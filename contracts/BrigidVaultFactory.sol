// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BrigidVault} from "./BrigidVault.sol";
import {BrigidTokenRegistry} from "./BrigidTokenRegistry.sol";

/// @title BrigidVaultFactory
/// @notice Permissioned factory and canonical registry for official Brigid vaults.
/// @dev Callers must present a valid EIP-712 LaunchPermit signed by the configured
///      permitSigner, or be in the authorizedDeployers whitelist (admin bypass).
///      Token safety: direct vault creation only accepts tokens approved in the
///      registry. Trusted Brigid launch infrastructure may create vaults for
///      canonical launchpad tokens before those fresh token addresses can be
///      registered. Vaults deployed through this factory enforce dual
///      balance-delta verification. Fee-on-transfer, rebasing, blacklistable,
///      admin-burnable, or other balance-manipulating tokens are unsupported
///      unless explicitly approved by the Brigid governance layer.
contract BrigidVaultFactory is Ownable2Step, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    string public constant VERSION = "1.3.0";
    uint256 public constant EXECUTION_WINDOW = 72 hours;
    uint256 public constant CANCELLATION_WINDOW = 1 hours;
    uint256 public constant MIN_WITHDRAWAL_DELAY = 24 hours;
    uint256 public constant MAX_WITHDRAWAL_DELAY = 72 hours;
    uint256 public constant DEPLOY_TIME_START = 0;
    /// @notice Cap on how far in the future a vault may be scheduled to start.
    /// @dev    Prevents misconfigured vaults that effectively lock funds for an
    ///         unreasonable horizon (e.g. block.timestamp + 1000 years).
    uint256 public constant MAX_START_OFFSET = 5 * 365 days;
    /// @notice Cap on the cliff duration. A cliff that exceeds the realistic
    ///         lifetime of the protocol would brick the vault.
    uint256 public constant MAX_CLIFF_DURATION = 10 * 365 days;

    // EIP-712 type hash for LaunchPermit(address wallet,uint256 nonce,uint256 expiry)
    // The `nonce` field commits each permit to a specific chain state, making
    // permits single-use: once consumed, the signer's nonce advances and any
    // signed permit referencing the prior nonce becomes unusable. Replay
    // (using the same signature twice) is therefore impossible.
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("LaunchPermit(address wallet,uint256 nonce,uint256 expiry)");

    /// @notice The off-chain key whose signatures authorise a wallet to deploy vaults.
    ///         Can be rotated by the owner without redeploying the factory.
    address public permitSigner;

    /// @notice Per-deployer nonce. Incremented on every successful permit consumption.
    /// @dev    Off-chain signers MUST read the current nonce before signing so the
    ///         signature references the wallet's live chain state. Two signatures for
    ///         the same nonce can never both be redeemed — the first one consumed
    ///         advances the nonce, invalidating any others referencing the prior value.
    mapping(address => uint256) public nonces;

    /// @notice Registry of Brigid-approved ERC20 tokens.
    ///         Only approved tokens may be used when creating vaults.
    BrigidTokenRegistry public tokenRegistry;

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
    /// @param _tokenRegistry   The BrigidTokenRegistry for approved ERC20 tokens.
    constructor(address _permitSigner, address _tokenRegistry)
        Ownable(msg.sender)
        EIP712("BrigidVaultFactory", "1")
    {
        require(_permitSigner != address(0), "Invalid signer");
        require(_tokenRegistry != address(0), "Invalid registry");
        permitSigner = _permitSigner;
        tokenRegistry = BrigidTokenRegistry(_tokenRegistry);
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

    // ─── Views ────────────────────────────────────────────────────────────────

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Compute the EIP-712 digest for a LaunchPermit using the wallet's
    ///         current on-chain nonce. Useful for off-chain signing.
    function permitDigest(address wallet, uint256 expiry) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PERMIT_TYPEHASH, wallet, nonces[wallet], expiry))
        );
    }

    /// @notice Compute the EIP-712 digest for a LaunchPermit at an arbitrary nonce.
    ///         Used by tests and tooling; production signers should use `permitDigest`.
    function permitDigestAt(address wallet, uint256 nonce, uint256 expiry) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PERMIT_TYPEHASH, wallet, nonce, expiry))
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
            permitSig,
            false
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
            permitSig,
            true
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
        bytes calldata permitSig,
        bool allowUnregisteredToken
    ) internal returns (address vault) {
        // Authorization check.
        // For permit-authenticated callers we bind the signature to the deployer's
        // current nonce, then advance it. This makes every permit single-use:
        // the same signature cannot be replayed in a second call because the
        // nonce will have moved on.
        if (!authorizedDeployers[launchDeployer]) {
            if (block.timestamp > permitExpiry) revert PermitExpired();
            uint256 expectedNonce = nonces[launchDeployer];
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(PERMIT_TYPEHASH, launchDeployer, expectedNonce, permitExpiry))
            );
            if (digest.recover(permitSig) != permitSigner) revert InvalidPermit();
            unchecked { nonces[launchDeployer] = expectedNonce + 1; }
        }

        bool noVesting = interval == 0 && intervals == 0;
        bool invalidSchedule = (interval == 0) != (intervals == 0);
        uint256 effectiveStartTime = startTime;

        require(allowUnregisteredToken || tokenRegistry.approved(token), "Unsupported token");
        require(launchDeployer != address(0), "Invalid deployer");
        require(token != address(0), "Invalid token");
        require(vaultOwner != address(0), "Invalid owner");
        require(funder != address(0), "Invalid funder");
        require(totalAllocation > 0, "Invalid allocation");
        require(!invalidSchedule, "Invalid schedule");
        require(withdrawalDelay >= MIN_WITHDRAWAL_DELAY && withdrawalDelay <= MAX_WITHDRAWAL_DELAY, "Delay out of bounds");
        require(executionWindow == EXECUTION_WINDOW, "Invalid execution window");
        require(cancelWindow == CANCELLATION_WINDOW, "Cancel window invalid");
        require(executionWindow <= type(uint256).max - withdrawalDelay, "Delay+window overflow");
        require(cliff <= MAX_CLIFF_DURATION, "Cliff too long");
        if (!noVesting) {
            require(startTime > block.timestamp + 60, "Start time too soon");
            require(startTime <= block.timestamp + MAX_START_OFFSET, "Start time too far");
            require(interval > 0, "Invalid interval");
            require(intervals > 0, "Invalid schedule");
        } else if (startTime == DEPLOY_TIME_START) {
            effectiveStartTime = block.timestamp;
        } else {
            require(startTime > block.timestamp + 60, "Start time too soon");
            require(startTime <= block.timestamp + MAX_START_OFFSET, "Start time too far");
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
