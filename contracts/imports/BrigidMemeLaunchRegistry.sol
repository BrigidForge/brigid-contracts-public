// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BrigidMemeLaunchRegistry
 * @notice Dedicated registry for standardized Meme Launch records.
 * @dev Meme launches with a non-zero dev allocation store the canonical
 *      BrigidVault address in devVestingVault. Community-max launches use
 *      address(0) because there is no dev allocation to vest.
 */
contract BrigidMemeLaunchRegistry is ReentrancyGuard {
    struct MemeLaunchRecord {
        address deployer;
        address token;
        address devVestingVault;
        address lpPair;
        address lpLock;
        uint8 tier;
        uint256 nativeLiquidity;
        uint256 tokenLiquidity;
        uint256 tokenSupply;
        uint16 devAllocationBps;
        uint256 registeredAt;
        uint256 registeredBlock;
    }

    address public owner;
    address public pendingOwner;
    address public registrar;
    uint256 public immutable registryChainId;
    uint256 public launchCount;

    mapping(bytes32 => MemeLaunchRecord) private _launches;
    mapping(address => bytes32) public tokenLaunch;
    mapping(address => bytes32[]) private _deployerLaunches;

    event RegistrarUpdated(address indexed previousRegistrar, address indexed newRegistrar);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event MemeLaunchRegistered(
        bytes32 indexed launchId,
        address indexed deployer,
        address indexed token,
        address devVestingVault,
        address lpPair,
        address lpLock,
        uint8 tier,
        uint256 nativeLiquidity,
        uint256 tokenLiquidity,
        uint256 tokenSupply,
        uint16 devAllocationBps,
        uint256 registeredAt
    );

    error NotOwner();
    error NotPendingOwner();
    error NotRegistrar();
    error ZeroAddress();
    error InvalidAmount();
    error TokenAlreadyRegistered();
    error LaunchAlreadyRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    constructor(uint256 chainId_) {
        if (chainId_ == 0) revert InvalidAmount();
        owner = msg.sender;
        registryChainId = chainId_;
    }

    function setRegistrar(address newRegistrar) external onlyOwner {
        if (newRegistrar == address(0)) revert ZeroAddress();
        emit RegistrarUpdated(registrar, newRegistrar);
        registrar = newRegistrar;
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

    function registerMemeLaunchFor(
        address deployer,
        address token,
        address devVestingVault,
        address lpPair,
        address lpLock,
        uint8 tier,
        uint256 nativeLiquidity,
        uint256 tokenLiquidity,
        uint256 tokenSupply,
        uint16 devAllocationBps
    ) external onlyRegistrar nonReentrant returns (bytes32 launchId) {
        if (
            deployer == address(0)
                || token == address(0)
                || lpPair == address(0)
                || lpLock == address(0)
        ) {
            revert ZeroAddress();
        }
        if (nativeLiquidity == 0 || tokenLiquidity == 0 || tokenSupply == 0) revert InvalidAmount();
        if (devAllocationBps > 2_500 || tokenLiquidity > tokenSupply) revert InvalidAmount();
        if (devAllocationBps > 0 && devVestingVault == address(0)) revert ZeroAddress();
        if (devAllocationBps == 0 && devVestingVault != address(0)) revert InvalidAmount();
        if (tokenLaunch[token] != bytes32(0)) revert TokenAlreadyRegistered();

        launchId = computeLaunchId(deployer, token);
        if (_launches[launchId].registeredAt != 0) revert LaunchAlreadyRegistered();

        _launches[launchId] = MemeLaunchRecord({
            deployer: deployer,
            token: token,
            devVestingVault: devVestingVault,
            lpPair: lpPair,
            lpLock: lpLock,
            tier: tier,
            nativeLiquidity: nativeLiquidity,
            tokenLiquidity: tokenLiquidity,
            tokenSupply: tokenSupply,
            devAllocationBps: devAllocationBps,
            registeredAt: block.timestamp,
            registeredBlock: block.number
        });
        tokenLaunch[token] = launchId;
        _deployerLaunches[deployer].push(launchId);
        launchCount++;

        emit MemeLaunchRegistered(
            launchId,
            deployer,
            token,
            devVestingVault,
            lpPair,
            lpLock,
            tier,
            nativeLiquidity,
            tokenLiquidity,
            tokenSupply,
            devAllocationBps,
            block.timestamp
        );
    }

    function computeLaunchId(address deployer, address token) public view returns (bytes32) {
        return keccak256(abi.encode(registryChainId, deployer, token));
    }

    function getLaunch(bytes32 launchId) external view returns (MemeLaunchRecord memory) {
        return _launches[launchId];
    }

    function getLaunchByToken(address token) external view returns (bytes32 launchId, MemeLaunchRecord memory record) {
        launchId = tokenLaunch[token];
        record = _launches[launchId];
    }

    function getDeployerLaunchIds(address deployer) external view returns (bytes32[] memory) {
        return _deployerLaunches[deployer];
    }
}
