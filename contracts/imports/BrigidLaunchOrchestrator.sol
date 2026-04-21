// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./BrigidManagedLPLock.sol";

/**
 * @title BrigidLaunchOrchestrator
 * @notice Atomic two-phase launch workflow for Brigid Forge.
 *
 * Phase 1 — createLaunch():
 *   1. Collect BRIGID fee via ERC20 transferFrom
 *   2. Deploy the canonical project token from constructor init code
 *   3. Validate total supply + initial custody on-chain
 *   4. Create vaults on behalf of the original deployer
 *   5. Fund each vault from orchestrator-held supply
 *   6. Keep LP reserve escrowed in the orchestrator for the official activation path
 *   7. Renounce token ownership
 *   8. Register the launch for the original deployer in BrigidLaunchRegistry
 *   9. Store lifecycle metadata in CREATED state
 *
 * Phase 2 — activateLaunch():
 *   1. Use the escrowed LP reserve to create official PancakeSwap liquidity
 *   2. Mint LP tokens to the orchestrator
 *   3. Deploy the canonical Brigid-managed LP lock
 *   4. Deposit LP tokens into the lock
 *   5. Release any unused escrowed reserve back to the deployer
 *   6. Mark the launch CERTIFIED only after the canonical path succeeds
 *
 * Manual path — markManualActivation():
 *   1. Permanently mark the launch MANUAL
 *   2. Release the escrowed LP reserve back to the original deployer
 */
contract BrigidLaunchOrchestrator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum LaunchState {
        NONE,
        CREATED,
        ACTIVATED,
        CERTIFIED,
        MANUAL
    }

    uint256 public constant DEFAULT_MIN_CERTIFICATION_LOCK = 180 days;

    struct VaultConfig {
        address vaultOwner;
        uint256 allocationRaw;
        uint256 startTime;
        uint256 cliff;
        uint256 interval;
        uint256 intervals;
        uint256 cancelWindow;
        uint256 withdrawalDelay;
        uint256 executionWindow;
        uint256 permitExpiry;
        bytes permitSig;
    }

    struct LaunchRecord {
        address deployer;
        address token;
        address[] vaults;
        LaunchState state;
        uint256 createdAt;
        uint256 activatedAt;
        address lpPair;
        address lpLock;
        uint256 lpReserve;
    }

    struct CreateLaunchParams {
        bytes tokenInitCode;
        string tokenName;
        string tokenSymbol;
        uint256 tokenSupply;
        VaultConfig[] vaults;
        uint256 lpReserveRaw;
    }

    struct ActivateLaunchParams {
        bytes32 launchId;
        uint256 tokenAmountDesired;
        uint256 tokenAmountMin;
        uint256 nativeAmountMin;
        uint256 lockDurationSeconds;
    }

    IERC20 public immutable brigidToken;
    address public immutable feeRecipient;
    uint256 public immutable launchFee;
    address public immutable vaultFactory;
    address public immutable launchRegistry;
    address public immutable pancakeRouter;
    uint256 public immutable minCertificationLock;
    address public owner;

    mapping(bytes32 => LaunchRecord) public launches;
    mapping(address => bytes32[]) public deployerLaunches;
    mapping(address => bytes32) public tokenToLaunch;

    uint256 public totalLaunches;

    event FeePaid(address indexed user, uint256 amount, address indexed recipient);
    event LaunchCreated(
        bytes32 indexed launchId,
        address indexed deployer,
        address token,
        address[] vaults,
        uint256 lpReserve
    );
    event LaunchActivated(
        bytes32 indexed launchId,
        address indexed deployer,
        address lpPair,
        address lpLock,
        uint256 tokenAmountUsed,
        uint256 nativeAmountUsed,
        uint256 lockDuration
    );
    event LaunchCertified(bytes32 indexed launchId);
    event LaunchMarkedManual(bytes32 indexed launchId, uint256 releasedReserve);
    event OwnershipTransferred(address indexed previous, address indexed next);

    error NotOwner();
    error LaunchAlreadyExists(bytes32 launchId);
    error LaunchNotFound(bytes32 launchId);
    error LaunchNotInState(bytes32 launchId, LaunchState expected, LaunchState actual);
    error TokenDeploymentFailed();
    error TokenValidationFailed();
    error VaultCreationFailed(uint256 index);
    error RegistrationFailed();
    error RenounceFailed();
    error NotLaunchDeployer(bytes32 launchId);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidAllocationMath();
    error InsufficientEscrowedReserve(uint256 requested, uint256 available);
    error LockDurationTooShort(uint256 provided, uint256 minimumRequired);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyLaunchDeployer(bytes32 launchId) {
        LaunchRecord storage launch = launches[launchId];
        if (launch.deployer == address(0)) revert LaunchNotFound(launchId);
        if (launch.deployer != msg.sender) revert NotLaunchDeployer(launchId);
        _;
    }

    constructor(
        address _brigidToken,
        address _feeRecipient,
        uint256 _launchFee,
        address _vaultFactory,
        address _launchRegistry,
        address _pancakeRouter,
        uint256 _minCertificationLock
    ) {
        if (_brigidToken == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_vaultFactory == address(0)) revert ZeroAddress();
        if (_launchRegistry == address(0)) revert ZeroAddress();
        if (_pancakeRouter == address(0)) revert ZeroAddress();
        if (_minCertificationLock == 0) revert ZeroAmount();

        brigidToken = IERC20(_brigidToken);
        feeRecipient = _feeRecipient;
        launchFee = _launchFee;
        vaultFactory = _vaultFactory;
        launchRegistry = _launchRegistry;
        pancakeRouter = _pancakeRouter;
        minCertificationLock = _minCertificationLock;
        owner = msg.sender;
    }

    function createLaunch(CreateLaunchParams calldata params)
        external
        nonReentrant
        returns (bytes32 launchId)
    {
        if (params.tokenInitCode.length == 0) revert TokenDeploymentFailed();
        if (params.vaults.length == 0) revert ZeroAmount();
        if (params.tokenSupply == 0) revert ZeroAmount();

        uint256 totalVaultAllocation;
        for (uint256 i = 0; i < params.vaults.length; ++i) {
            VaultConfig calldata vc = params.vaults[i];
            if (vc.vaultOwner == address(0)) revert ZeroAddress();
            if (vc.allocationRaw == 0) revert ZeroAmount();
            totalVaultAllocation += vc.allocationRaw;
        }

        if (totalVaultAllocation + params.lpReserveRaw != params.tokenSupply) revert InvalidAllocationMath();

        if (launchFee > 0) {
            brigidToken.safeTransferFrom(msg.sender, feeRecipient, launchFee);
            emit FeePaid(msg.sender, launchFee, feeRecipient);
        }

        address token;
        bytes memory initCode = params.tokenInitCode;
        assembly {
            token := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (token == address(0)) revert TokenDeploymentFailed();

        ILaunchToken tokenContract = ILaunchToken(token);
        if (
            keccak256(bytes(IERC20Metadata(token).name())) != keccak256(bytes(params.tokenName)) ||
            keccak256(bytes(IERC20Metadata(token).symbol())) != keccak256(bytes(params.tokenSymbol)) ||
            tokenContract.totalSupply() != params.tokenSupply ||
            tokenContract.balanceOf(address(this)) != params.tokenSupply ||
            tokenContract.owner() != address(this)
        ) {
            revert TokenValidationFailed();
        }

        launchId = _computeLaunchId(msg.sender, token);
        if (launches[launchId].deployer != address(0)) revert LaunchAlreadyExists(launchId);

        address[] memory vaultAddresses = new address[](params.vaults.length);
        IERC20 launchedToken = IERC20(token);

        for (uint256 i = 0; i < params.vaults.length; ++i) {
            VaultConfig calldata vc = params.vaults[i];
            address vault = _createVault(msg.sender, token, vc);
            if (vault == address(0)) revert VaultCreationFailed(i);
            vaultAddresses[i] = vault;

            launchedToken.forceApprove(vault, vc.allocationRaw);
            IVault(vault).fund();
        }

        tokenContract.renounceOwnership();
        if (tokenContract.owner() != address(0)) revert RenounceFailed();

        bytes32 registryLaunchId = ILaunchRegistry(launchRegistry).registerLaunchFor(
            msg.sender,
            token,
            vaultAddresses
        );
        if (registryLaunchId != launchId) revert RegistrationFailed();

        launches[launchId] = LaunchRecord({
            deployer: msg.sender,
            token: token,
            vaults: vaultAddresses,
            state: LaunchState.CREATED,
            createdAt: block.timestamp,
            activatedAt: 0,
            lpPair: address(0),
            lpLock: address(0),
            lpReserve: params.lpReserveRaw
        });
        deployerLaunches[msg.sender].push(launchId);
        tokenToLaunch[token] = launchId;
        totalLaunches += 1;

        emit LaunchCreated(launchId, msg.sender, token, vaultAddresses, params.lpReserveRaw);
    }

    function activateLaunch(ActivateLaunchParams calldata params)
        external
        payable
        nonReentrant
        onlyLaunchDeployer(params.launchId)
    {
        LaunchRecord storage launch = launches[params.launchId];
        if (launch.state != LaunchState.CREATED) {
            revert LaunchNotInState(params.launchId, LaunchState.CREATED, launch.state);
        }
        if (msg.value == 0) revert ZeroAmount();
        if (params.tokenAmountDesired == 0) revert ZeroAmount();
        if (params.lockDurationSeconds < minCertificationLock) {
            revert LockDurationTooShort(params.lockDurationSeconds, minCertificationLock);
        }
        if (params.tokenAmountDesired > launch.lpReserve) {
            revert InsufficientEscrowedReserve(params.tokenAmountDesired, launch.lpReserve);
        }

        IERC20 tokenContract = IERC20(launch.token);
        tokenContract.forceApprove(pancakeRouter, params.tokenAmountDesired);

        uint256 deadline = block.timestamp + 1200;
        (uint256 amountToken, uint256 amountETH,) = IPancakeRouter(pancakeRouter).addLiquidityETH{value: msg.value}(
            launch.token,
            params.tokenAmountDesired,
            params.tokenAmountMin,
            params.nativeAmountMin,
            address(this),
            deadline
        );

        address factory = IPancakeRouter(pancakeRouter).factory();
        address wrappedNative = IPancakeRouter(pancakeRouter).WETH();
        address lpPair = IPancakeFactory(factory).getPair(launch.token, wrappedNative);
        if (lpPair == address(0)) revert RegistrationFailed();

        uint256 unlockTime = block.timestamp + params.lockDurationSeconds;
        BrigidManagedLPLock lpLock = new BrigidManagedLPLock(
            lpPair,
            msg.sender,
            address(this),
            unlockTime
        );

        uint256 lpBalance = IERC20(lpPair).balanceOf(address(this));
        if (lpBalance == 0) revert ZeroAmount();
        IERC20(lpPair).forceApprove(address(lpLock), lpBalance);
        lpLock.deposit(lpBalance);

        launch.state = LaunchState.CERTIFIED;
        launch.activatedAt = block.timestamp;
        launch.lpPair = lpPair;
        launch.lpLock = address(lpLock);

        uint256 reserveRemaining = launch.lpReserve - amountToken;
        launch.lpReserve = 0;
        if (reserveRemaining > 0) {
            tokenContract.safeTransfer(msg.sender, reserveRemaining);
        }

        uint256 unusedNative = msg.value - amountETH;
        if (unusedNative > 0) {
            (bool refundOk,) = msg.sender.call{value: unusedNative}("");
            require(refundOk, "Native refund failed");
        }

        emit LaunchActivated(
            params.launchId,
            msg.sender,
            lpPair,
            address(lpLock),
            amountToken,
            amountETH,
            params.lockDurationSeconds
        );
        emit LaunchCertified(params.launchId);
    }

    function markManualActivation(bytes32 launchId)
        external
        nonReentrant
        onlyLaunchDeployer(launchId)
    {
        LaunchRecord storage launch = launches[launchId];
        if (launch.state != LaunchState.CREATED) {
            revert LaunchNotInState(launchId, LaunchState.CREATED, launch.state);
        }

        uint256 releasedReserve = launch.lpReserve;
        launch.lpReserve = 0;
        launch.state = LaunchState.MANUAL;

        if (releasedReserve > 0) {
            IERC20(launch.token).safeTransfer(msg.sender, releasedReserve);
        }

        emit LaunchMarkedManual(launchId, releasedReserve);
    }

    function getLaunch(bytes32 launchId)
        external
        view
        returns (
            address deployer,
            address token,
            address[] memory vaults,
            LaunchState state,
            uint256 createdAt,
            uint256 activatedAt,
            address lpPair,
            address lpLock,
            uint256 lpReserve
        )
    {
        LaunchRecord storage r = launches[launchId];
        return (
            r.deployer,
            r.token,
            r.vaults,
            r.state,
            r.createdAt,
            r.activatedAt,
            r.lpPair,
            r.lpLock,
            r.lpReserve
        );
    }

    function getLaunchState(bytes32 launchId) external view returns (LaunchState) {
        return launches[launchId].state;
    }

    function getDeployerLaunches(address deployer) external view returns (bytes32[] memory) {
        return deployerLaunches[deployer];
    }

    function getLaunchByToken(address token) external view returns (bytes32) {
        return tokenToLaunch[token];
    }

    function computeLaunchId(address deployer, address token) external view returns (bytes32) {
        return _computeLaunchId(deployer, token);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _createVault(
        address originalDeployer,
        address token,
        VaultConfig calldata vc
    ) internal returns (address vault) {
        (bool ok, bytes memory result) = vaultFactory.call(
            abi.encodeWithSignature(
                "createVaultFor(address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes)",
                originalDeployer,
                token,
                vc.vaultOwner,
                address(this),
                vc.allocationRaw,
                vc.startTime,
                vc.cliff,
                vc.interval,
                vc.intervals,
                vc.cancelWindow,
                vc.withdrawalDelay,
                vc.executionWindow,
                vc.permitExpiry,
                vc.permitSig
            )
        );
        if (!ok || result.length < 32) return address(0);
        vault = abi.decode(result, (address));
    }

    function _computeLaunchId(address deployer, address token) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, deployer, token));
    }

    receive() external payable {}
}

interface ILaunchToken is IERC20 {
    function owner() external view returns (address);
    function renounceOwnership() external;
}

interface IVault {
    function fund() external;
}

interface ILaunchRegistry {
    function registerLaunchFor(address deployer, address token, address[] calldata vaults) external returns (bytes32);
}

interface IPancakeRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
