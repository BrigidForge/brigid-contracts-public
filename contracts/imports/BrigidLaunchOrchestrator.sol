// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../BrigidLaunchToken.sol";
import "./BrigidManagedLPLock.sol";

/**
 * @title BrigidLaunchOrchestrator
 * @notice Atomic two-phase launch workflow for Brigid Forge.
 *
 * Phase 1 — createLaunch():
 *   1. Collect BRIGID fee via ERC20 transferFrom
 *   2. Deploy the canonical Brigid launch token template
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

    uint8 public constant TIER_STARTER = 0;
    uint8 public constant TIER_STANDARD = 1;
    uint8 public constant TIER_ADVANCED = 2;
    uint8 public constant TIER_CERTIFIED = 3;

    uint256 public constant DEFAULT_MIN_CERTIFICATION_LOCK = 180 days;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FEE_QUOTE_DOMAIN_NAME_HASH = keccak256("BrigidLaunchOrchestrator");
    bytes32 private constant FEE_QUOTE_DOMAIN_VERSION_HASH = keccak256("1");
    bytes32 public constant FEE_QUOTE_TYPEHASH = keccak256(
        "FeeQuote(address orchestrator,uint256 chainId,address feeToken,address payer,uint8 launchTier,uint256 feeAmount,uint256 expiresAt,uint256 nonce)"
    );

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
        uint8 launchTier;
    }

    struct CreateLaunchParams {
        string tokenName;
        string tokenSymbol;
        uint256 tokenSupply;
        VaultConfig[] vaults;
        uint256 lpReserveRaw;
        uint8 launchTier;
    }

    struct FeeQuote {
        address payer;
        uint8 launchTier;
        uint256 feeAmount;
        uint256 expiresAt;
        uint256 nonce;
        bytes signature;
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
    address public immutable vaultFactory;
    address public immutable launchRegistry;
    address public immutable pancakeRouter;
    uint256 public immutable minCertificationLock;
    address public owner;
    address public pendingOwner;
    address public feeQuoteSigner;
    bool public feeQuoteRequired;

    mapping(uint8 => uint256) public launchTierFees;
    mapping(uint8 => bool) public launchTierEnabled;
    mapping(bytes32 => LaunchRecord) public launches;
    mapping(address => bytes32[]) public deployerLaunches;
    mapping(address => bytes32) public tokenToLaunch;
    mapping(address => mapping(uint256 => bool)) public feeQuoteNonceUsed;

    uint256 public totalLaunches;

    /// @notice Native (BNB) amounts owed to deployers when an inline refund call fails.
    /// @dev Pull-pattern fallback used when `msg.sender.call{value: ...}("")` fails
    ///      (e.g. deployer is a contract that rejects ETH callbacks). Without this
    ///      the entire activateLaunch transaction would revert and the launch would
    ///      be permanently stuck in CREATED state.
    mapping(address => uint256) public pendingNativeRefunds;

    event FeePaid(address indexed user, uint8 indexed launchTier, uint256 amount, address indexed recipient);
    event LaunchFeeUpdated(uint256 previousFee, uint256 newFee);
    event LaunchTierFeeUpdated(uint8 indexed launchTier, uint256 previousFee, uint256 newFee);
    event LaunchTierStatusUpdated(uint8 indexed launchTier, bool enabled);
    event FeeQuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event FeeQuoteRequiredUpdated(bool required);
    event FeeQuoteUsed(address indexed payer, uint8 indexed launchTier, uint256 amount, uint256 nonce, uint256 expiresAt);
    event LaunchCreated(
        bytes32 indexed launchId,
        address indexed deployer,
        address token,
        address[] vaults,
        uint256 lpReserve,
        uint8 launchTier
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
    event OwnershipTransferStarted(address indexed previous, address indexed pendingOwner);
    event NativeRefundStored(address indexed recipient, uint256 amount);
    event NativeRefundClaimed(address indexed recipient, uint256 amount);

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
    error InvalidLaunchTier(uint8 launchTier);
    error LaunchTierDisabled(uint8 launchTier);
    error FeeQuoteRequired(uint8 launchTier);
    error FeeQuoteSignerNotConfigured();
    error InvalidFeeQuote(address recoveredSigner);
    error FeeQuoteExpired(uint256 expiresAt, uint256 currentTimestamp);
    error FeeQuoteWrongPayer(address providedPayer, address expectedPayer);
    error FeeQuoteWrongTier(uint8 providedTier, uint8 expectedTier);
    error FeeQuoteNonceAlreadyUsed(address payer, uint256 nonce);
    error FeeTransferMismatch();
    error InsufficientEscrowedReserve(uint256 requested, uint256 available);
    error LockDurationTooShort(uint256 provided, uint256 minimumRequired);
    error NotPendingOwner();

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
        uint256[4] memory _launchTierFees,
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
        vaultFactory = _vaultFactory;
        launchRegistry = _launchRegistry;
        pancakeRouter = _pancakeRouter;
        minCertificationLock = _minCertificationLock;
        owner = msg.sender;
        feeQuoteSigner = msg.sender;

        for (uint8 tier = TIER_STARTER; tier <= TIER_CERTIFIED; ++tier) {
            launchTierFees[tier] = _launchTierFees[tier];
            launchTierEnabled[tier] = true;
        }
    }

    function createLaunch(CreateLaunchParams calldata params)
        external
        nonReentrant
        returns (bytes32 launchId)
    {
        uint256 fee = _staticLaunchFeeForCreate(params.launchTier);
        launchId = _createLaunch(params, fee);
    }

    function createLaunchWithFeeQuote(CreateLaunchParams calldata params, FeeQuote calldata quote)
        external
        nonReentrant
        returns (bytes32 launchId)
    {
        uint256 fee = _quotedLaunchFeeForCreate(params.launchTier, quote);
        launchId = _createLaunch(params, fee);
    }

    function _createLaunch(CreateLaunchParams calldata params, uint256 fee) internal returns (bytes32 launchId) {
        if (params.vaults.length == 0) revert ZeroAmount();
        if (params.tokenSupply == 0) revert ZeroAmount();
        if (bytes(params.tokenName).length == 0 || bytes(params.tokenSymbol).length == 0) {
            revert TokenValidationFailed();
        }

        uint256 totalVaultAllocation = 0;
        for (uint256 i = 0; i < params.vaults.length; ++i) {
            VaultConfig calldata vc = params.vaults[i];
            if (vc.vaultOwner == address(0)) revert ZeroAddress();
            if (vc.allocationRaw == 0) revert ZeroAmount();
            totalVaultAllocation += vc.allocationRaw;
        }

        if (totalVaultAllocation + params.lpReserveRaw != params.tokenSupply) revert InvalidAllocationMath();
        if (params.lpReserveRaw == 0) revert ZeroAmount();

        if (fee > 0) {
            uint256 recipientBalanceBefore = brigidToken.balanceOf(feeRecipient);
            brigidToken.safeTransferFrom(msg.sender, feeRecipient, fee);
            uint256 recipientBalanceAfter = brigidToken.balanceOf(feeRecipient);
            if (
                recipientBalanceAfter < recipientBalanceBefore
                    || recipientBalanceAfter - recipientBalanceBefore != fee
            ) {
                revert FeeTransferMismatch();
            }
            emit FeePaid(msg.sender, params.launchTier, fee, feeRecipient);
        }

        BrigidLaunchToken deployedToken = new BrigidLaunchToken(
            params.tokenName,
            params.tokenSymbol,
            18,
            address(this),
            params.tokenSupply
        );
        address token = address(deployedToken);

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
            lpReserve: params.lpReserveRaw,
            launchTier: params.launchTier
        });
        deployerLaunches[msg.sender].push(launchId);
        tokenToLaunch[token] = launchId;
        totalLaunches += 1;

        emit LaunchCreated(launchId, msg.sender, token, vaultAddresses, params.lpReserveRaw, params.launchTier);
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
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
            IPancakeRouter(pancakeRouter).addLiquidityETH{value: msg.value}(
            launch.token,
            params.tokenAmountDesired,
            params.tokenAmountMin,
            params.nativeAmountMin,
            address(this),
            deadline
        );
        if (liquidity == 0) revert ZeroAmount();

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
            if (!refundOk) {
                // Fallback to the pull pattern. Deployer claims via claimNativeRefund.
                // This prevents launches from being permanently locked when the
                // deployer is a contract that rejects ETH callbacks.
                pendingNativeRefunds[msg.sender] += unusedNative;
                emit NativeRefundStored(msg.sender, unusedNative);
            }
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

    /// @notice Claim native refund stored when an inline refund call failed.
    /// @dev Pull pattern: caller drains their own balance to themselves via call.
    function claimNativeRefund() external nonReentrant {
        uint256 amount = pendingNativeRefunds[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingNativeRefunds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Native refund send failed");
        emit NativeRefundClaimed(msg.sender, amount);
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
            uint256 lpReserve,
            uint8 launchTier
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
            r.lpReserve,
            r.launchTier
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

    function launchFee() external view returns (uint256) {
        return launchTierFees[TIER_STANDARD];
    }

    function launchFeeForTier(uint8 launchTier) public view returns (uint256) {
        return _launchFeeForTier(launchTier);
    }

    function setLaunchFee(uint256 newLaunchFee) external onlyOwner {
        _setLaunchTierFee(TIER_STANDARD, newLaunchFee);
    }

    function setLaunchTierFee(uint8 launchTier, uint256 newLaunchFee) external onlyOwner {
        _setLaunchTierFee(launchTier, newLaunchFee);
    }

    function setLaunchTierEnabled(uint8 launchTier, bool enabled) external onlyOwner {
        if (!_isValidLaunchTier(launchTier)) revert InvalidLaunchTier(launchTier);
        launchTierEnabled[launchTier] = enabled;
        emit LaunchTierStatusUpdated(launchTier, enabled);
    }

    function setFeeQuoteSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit FeeQuoteSignerUpdated(feeQuoteSigner, newSigner);
        feeQuoteSigner = newSigner;
    }

    function setFeeQuoteRequired(bool required) external onlyOwner {
        feeQuoteRequired = required;
        emit FeeQuoteRequiredUpdated(required);
    }

    function feeQuoteDigest(FeeQuote calldata quote) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(
                abi.encode(
                    FEE_QUOTE_TYPEHASH,
                    address(this),
                    block.chainid,
                    address(brigidToken),
                    quote.payer,
                    quote.launchTier,
                    quote.feeAmount,
                    quote.expiresAt,
                    quote.nonce
                )
            );
        return keccak256(abi.encodePacked("\x19\x01", _feeQuoteDomainSeparator(), structHash));
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

    function _setLaunchTierFee(uint8 launchTier, uint256 newLaunchFee) internal {
        if (!_isValidLaunchTier(launchTier)) revert InvalidLaunchTier(launchTier);
        uint256 previousFee = launchTierFees[launchTier];
        launchTierFees[launchTier] = newLaunchFee;
        emit LaunchTierFeeUpdated(launchTier, previousFee, newLaunchFee);
        if (launchTier == TIER_STANDARD) {
            emit LaunchFeeUpdated(previousFee, newLaunchFee);
        }
    }

    function _launchFeeForTier(uint8 launchTier) internal view returns (uint256) {
        if (!_isValidLaunchTier(launchTier)) revert InvalidLaunchTier(launchTier);
        if (!launchTierEnabled[launchTier]) revert LaunchTierDisabled(launchTier);
        return launchTierFees[launchTier];
    }

    function _staticLaunchFeeForCreate(uint8 launchTier) internal view returns (uint256 fee) {
        fee = _launchFeeForTier(launchTier);
        if (feeQuoteRequired && fee > 0) revert FeeQuoteRequired(launchTier);
    }

    function _quotedLaunchFeeForCreate(uint8 launchTier, FeeQuote calldata quote) internal returns (uint256 fee) {
        uint256 configuredFee = _launchFeeForTier(launchTier);
        if (configuredFee == 0) return 0;
        if (!feeQuoteRequired && quote.signature.length == 0) return configuredFee;
        fee = _verifyFeeQuote(launchTier, quote);
    }

    function _verifyFeeQuote(uint8 launchTier, FeeQuote calldata quote) internal returns (uint256) {
        if (feeQuoteSigner == address(0)) revert FeeQuoteSignerNotConfigured();
        if (quote.payer != msg.sender) revert FeeQuoteWrongPayer(quote.payer, msg.sender);
        if (quote.launchTier != launchTier) revert FeeQuoteWrongTier(quote.launchTier, launchTier);
        if (quote.expiresAt < block.timestamp) revert FeeQuoteExpired(quote.expiresAt, block.timestamp);
        if (quote.feeAmount == 0) revert ZeroAmount();
        if (feeQuoteNonceUsed[quote.payer][quote.nonce]) revert FeeQuoteNonceAlreadyUsed(quote.payer, quote.nonce);

        address recovered = ECDSA.recover(feeQuoteDigest(quote), quote.signature);
        if (recovered != feeQuoteSigner) revert InvalidFeeQuote(recovered);

        feeQuoteNonceUsed[quote.payer][quote.nonce] = true;
        emit FeeQuoteUsed(quote.payer, quote.launchTier, quote.feeAmount, quote.nonce, quote.expiresAt);
        return quote.feeAmount;
    }

    function _feeQuoteDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                FEE_QUOTE_DOMAIN_NAME_HASH,
                FEE_QUOTE_DOMAIN_VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function _isValidLaunchTier(uint8 launchTier) internal pure returns (bool) {
        return launchTier <= TIER_CERTIFIED;
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
