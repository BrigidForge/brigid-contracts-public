// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVaultFactory {
    function vaultCreator(address vault) external view returns (address);
}

interface IVault {
    function token() external view returns (address);
    function totalAllocation() external view returns (uint256);
}

/// @title BrigidLaunchRegistry
/// @author Brigid Forge
/// @notice Immutable structural record linking a launch identity to its on-chain components.
///
/// @dev This contract is NOT a state tracker. It records ONLY the structural relationship:
///      deployer → token → vaults. It does not track activation, security, or certification.
///      Those are derived by off-chain observation of on-chain state.
///
///      Trust properties:
///      - One canonical launch per token (enforced via tokenLaunch mapping)
///      - Every vault is validated against the factory at registration time:
///        (1) was deployed via factory  (2) is linked to correct token
///      - No post-registration mutation of the launch record
///      - No admin functions, no owner, no upgradability, no custody
///      - Emits events for indexer consumption only
///
///      What this contract explicitly does NOT do:
///      - Track LP pair existence or state
///      - Track LP lock existence or state
///      - Track certification or trust status
///      - Allow any post-registration writes
///      - Hold, transfer, or approve any tokens
contract BrigidLaunchRegistry is ReentrancyGuard {

    string public constant VERSION = "1.0.0";

    struct LaunchRecord {
        address deployer;
        address token;
        address[] vaults;
        uint256[] vaultAllocations;  // totalAllocation per vault, captured at registration
        uint256 registeredAt;
        uint256 registeredBlock;
    }

    /// @notice The BrigidVaultFactory used to validate vault provenance.
    IVaultFactory public immutable vaultFactory;

    /// @notice The chain ID baked into launch identity.
    uint256 public immutable registryChainId;

    /// @notice launchId → record
    mapping(bytes32 => LaunchRecord) internal _launches;

    /// @notice token → launchId (one canonical launch per token)
    mapping(address => bytes32) public tokenLaunch;

    /// @notice deployer → launchIds
    mapping(address => bytes32[]) internal _deployerLaunches;

    /// @notice Total registered launches
    uint256 public launchCount;

    event LaunchRegistered(
        bytes32 indexed launchId,
        address indexed deployer,
        address indexed token,
        address[] vaults,
        uint256[] vaultAllocations,
        uint256 registeredAt
    );

    error TokenAlreadyRegistered();
    error InvalidToken();
    error NoVaults();
    error TooManyVaults();
    error DuplicateVault(address vault);
    error VaultNotFromFactory(address vault);
    error VaultCreatorMismatch(address vault, address expectedCreator, address actualCreator);
    error VaultTokenMismatch(address vault, address expectedToken, address actualToken);

    /// @param factory_ The canonical BrigidVaultFactory to validate against.
    /// @param chainId_ The chain ID for deterministic launch ID computation.
    constructor(address factory_, uint256 chainId_) {
        require(factory_ != address(0), "Invalid factory");
        require(chainId_ > 0, "Invalid chainId");
        vaultFactory = IVaultFactory(factory_);
        registryChainId = chainId_;
    }

    /// @notice Compute the deterministic launch ID for a deployer+token pair.
    /// @dev    Pure function — can be called off-chain to predict the ID before registration.
    function computeLaunchId(address deployer, address token) public view returns (bytes32) {
        return keccak256(abi.encode(registryChainId, deployer, token));
    }

    /// @notice Register a launch after deploying token + vaults via the factory.
    /// @param token  The launched token address.
    /// @param vaults Array of BrigidVault addresses. Each is validated:
    ///               (1) was deployed via the factory
    ///               (2) is linked to the correct token
    /// @return launchId The deterministic launch identifier.
    function registerLaunch(
        address token,
        address[] calldata vaults
    ) external nonReentrant returns (bytes32 launchId) {
        return _registerLaunch(msg.sender, token, vaults);
    }

    /// @notice Register a launch on behalf of the original deployer.
    /// @dev    This is intended for trusted orchestration infrastructure that deploys
    ///         contracts atomically while preserving the end-user deployer identity.
    ///         Every supplied vault must still prove provenance via `vaultCreator`.
    function registerLaunchFor(
        address deployer,
        address token,
        address[] calldata vaults
    ) external nonReentrant returns (bytes32 launchId) {
        return _registerLaunch(deployer, token, vaults);
    }

    function _registerLaunch(
        address deployer,
        address token,
        address[] calldata vaults
    ) internal returns (bytes32 launchId) {
        require(deployer != address(0), "Invalid deployer");
        if (token == address(0)) revert InvalidToken();
        if (vaults.length == 0) revert NoVaults();
        if (vaults.length > 20) revert TooManyVaults();
        if (tokenLaunch[token] != bytes32(0)) revert TokenAlreadyRegistered();

        uint256 len = vaults.length;
        uint256[] memory allocations = new uint256[](len);

        for (uint256 i = 0; i < len; ++i) {
            address vault = vaults[i];

            // Check for duplicate vault addresses in the input array
            for (uint256 j = 0; j < i; ++j) {
                if (vaults[j] == vault) revert DuplicateVault(vault);
            }

            // Must have been deployed through the factory
            address creator = vaultFactory.vaultCreator(vault);
            if (creator == address(0)) revert VaultNotFromFactory(vault);
            if (creator != deployer) revert VaultCreatorMismatch(vault, deployer, creator);

            // Must be configured for the correct token
            address vaultToken = IVault(vault).token();
            if (vaultToken != token) revert VaultTokenMismatch(vault, token, vaultToken);

            // Capture allocation at registration time for downstream balance verification
            allocations[i] = IVault(vault).totalAllocation();
        }

        launchId = computeLaunchId(deployer, token);
        // The launchId is deterministic — if registeredAt != 0, this deployer+token
        // already registered. This is a secondary guard; tokenLaunch check above is primary.
        require(_launches[launchId].registeredAt == 0, "Launch already registered");

        _launches[launchId] = LaunchRecord({
            deployer: deployer,
            token: token,
            vaults: vaults,
            vaultAllocations: allocations,
            registeredAt: block.timestamp,
            registeredBlock: block.number
        });

        tokenLaunch[token] = launchId;
        _deployerLaunches[deployer].push(launchId);
        launchCount++;

        emit LaunchRegistered(launchId, deployer, token, vaults, allocations, block.timestamp);
    }

    // ─── Views ────────────────────────────────────────────────────────

    function getLaunch(bytes32 launchId)
        external view
        returns (
            address deployer,
            address token,
            address[] memory vaults,
            uint256[] memory vaultAllocations,
            uint256 registeredAt,
            uint256 registeredBlock
        )
    {
        LaunchRecord storage r = _launches[launchId];
        return (r.deployer, r.token, r.vaults, r.vaultAllocations, r.registeredAt, r.registeredBlock);
    }

    function getLaunchByToken(address token)
        external view
        returns (
            bytes32 launchId,
            address deployer,
            address[] memory vaults,
            uint256[] memory vaultAllocations,
            uint256 registeredAt,
            uint256 registeredBlock
        )
    {
        launchId = tokenLaunch[token];
        require(launchId != bytes32(0), "Launch not found");
        LaunchRecord storage r = _launches[launchId];
        return (launchId, r.deployer, r.vaults, r.vaultAllocations, r.registeredAt, r.registeredBlock);
    }

    function getVaults(bytes32 launchId) external view returns (address[] memory) {
        return _launches[launchId].vaults;
    }

    function getVaultAllocations(bytes32 launchId) external view returns (uint256[] memory) {
        return _launches[launchId].vaultAllocations;
    }

    function getDeployerLaunchCount(address deployer) external view returns (uint256) {
        return _deployerLaunches[deployer].length;
    }

    function getDeployerLaunchIds(address deployer) external view returns (bytes32[] memory) {
        return _deployerLaunches[deployer];
    }

    function exists(bytes32 launchId) external view returns (bool) {
        return _launches[launchId].registeredAt != 0;
    }
}
