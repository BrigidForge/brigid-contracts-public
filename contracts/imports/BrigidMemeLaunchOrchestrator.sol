// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./BrigidManagedLPLock.sol";

/**
 * @title BrigidMemeLaunchOrchestrator
 * @notice Flat-price one-transaction Meme Launch path with selectable native liquidity.
 *
 * This contract is intentionally separate from BrigidLaunchOrchestrator so the
 * Custom Launch path can remain flexible while Meme Launch stays constrained:
 *   - whole-number native BNB liquidity selected inside an owner-configurable range
 *   - one flat BRIGID infrastructure fee
 *   - standardized no-owner/no-mint token
 *   - preset deployer allocation through the canonical BrigidVault system
 *   - automatic LP creation and Brigid-managed LP lock
 */
contract BrigidMemeLaunchOrchestrator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum MemeTier {
        STARTER,
        GROWTH,
        PREMIUM
    }

    enum MemeSupply {
        ONE_MILLION,
        TEN_MILLION,
        ONE_HUNDRED_MILLION,
        ONE_BILLION
    }

    enum MemeAllocation {
        COMMUNITY_MAX,
        LEAN_BUILDER,
        CLASSIC_MEME,
        BUILDER_RESERVE,
        MAX_BUILDER
    }

    struct MemeLaunchRecord {
        address deployer;
        address token;
        address devVault;
        address lpPair;
        address lpLock;
        MemeTier tier;
        uint256 nativeLiquidity;
        uint256 tokenLiquidity;
        uint256 tokenSupply;
        uint16 devAllocationBps;
        uint256 createdAt;
    }

    struct LaunchMemeParams {
        string tokenName;
        string tokenSymbol;
        MemeTier tier;
        MemeSupply supply;
        MemeAllocation allocation;
        uint256 infrastructureFeeAmount;
        uint256 nativeLiquidityAmount;
        uint256 tokenAmountMin;
        uint256 nativeAmountMin;
        uint256 lpLockDurationSeconds;
        uint256 vaultPermitExpiry;
        bytes vaultPermitSig;
    }

    struct ExternalMemeLockParams {
        LaunchMemeParams launch;
        uint256 lockerFeeAmount;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEV_VESTING_DURATION = 180 days;
    uint256 public constant DEV_VESTING_INTERVAL = 1 days;
    uint256 public constant DEV_VESTING_START_DELAY = 2 minutes;
    uint256 public constant DEFAULT_MIN_LP_LOCK = 180 days;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FEE_QUOTE_DOMAIN_NAME_HASH = keccak256("BrigidMemeLaunchOrchestrator");
    bytes32 private constant FEE_QUOTE_DOMAIN_VERSION_HASH = keccak256("1");
    bytes32 public constant FEE_QUOTE_TYPEHASH = keccak256(
        "FeeQuote(address orchestrator,uint256 chainId,address feeToken,address payer,uint256 nativeLiquidityAmount,uint256 feeAmount,uint256 expiresAt,uint256 nonce)"
    );
    uint256 public constant NATIVE_LIQUIDITY_STEP = 1 ether;

    struct FeeQuote {
        address payer;
        uint256 nativeLiquidityAmount;
        uint256 feeAmount;
        uint256 expiresAt;
        uint256 nonce;
        bytes signature;
    }

    IERC20 public immutable brigidToken;
    address public immutable feeRecipient;
    address public immutable vaultFactory;
    address public immutable launchRegistry;
    address public immutable pancakeRouter;
    uint256 public immutable minLpLockDuration;
    address public owner;
    address public pendingOwner;
    address public feeQuoteSigner;
    address public externalLpLocker;
    bool public feeQuoteRequired;

    uint256 public infrastructureFee;
    uint256 public minNativeLiquidity;
    uint256 public maxNativeLiquidity;

    mapping(MemeTier => uint256) public tierNativeLiquidity;
    mapping(MemeTier => bool) public tierEnabled;
    mapping(bytes32 => MemeLaunchRecord) public launches;
    mapping(address => bytes32[]) public deployerLaunches;
    mapping(address => bytes32) public tokenToLaunch;
    mapping(address => mapping(uint256 => bool)) public feeQuoteNonceUsed;
    mapping(address => uint256) public pendingNativeRefunds;
    uint256 public totalPendingNativeRefunds;

    uint256 public totalLaunches;

    event InfrastructureFeePaid(address indexed payer, uint256 amount, address indexed recipient);
    event InfrastructureFeeUpdated(uint256 previousFee, uint256 newFee);
    event FeeQuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event FeeQuoteRequiredUpdated(bool required);
    event FeeQuoteUsed(
        address indexed payer, uint256 nativeLiquidityAmount, uint256 amount, uint256 nonce, uint256 expiresAt
    );
    event ExternalLpLockerUpdated(address indexed previousLocker, address indexed newLocker);
    event ExternalLpLockUsed(
        bytes32 indexed launchId, address indexed provider, address indexed lockTarget, uint256 lockerFeeAmount
    );
    event NativeLiquidityRangeUpdated(uint256 previousMin, uint256 previousMax, uint256 newMin, uint256 newMax);
    event TierNativeLiquidityUpdated(MemeTier indexed tier, uint256 previousAmount, uint256 newAmount);
    event TierStatusUpdated(MemeTier indexed tier, bool enabled);
    event NativeRefundStored(address indexed recipient, uint256 amount);
    event NativeRefundClaimed(address indexed recipient, uint256 amount);
    event NativeRescued(address indexed recipient, uint256 amount);
    event TokenRescued(address indexed token, address indexed recipient, uint256 amount);
    event MemeLaunchCreated(
        bytes32 indexed launchId,
        address indexed deployer,
        address token,
        address devVault,
        address lpPair,
        address lpLock,
        MemeTier tier,
        uint256 nativeLiquidity,
        uint256 tokenLiquidity,
        uint256 tokenSupply,
        uint16 devAllocationBps
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTier();
    error InvalidSupply();
    error InvalidAllocation();
    error TierDisabled(MemeTier tier);
    error InvalidNativeLiquidity(uint256 minimum, uint256 maximum, uint256 received);
    error InvalidNativeLiquidityStep(uint256 step, uint256 received);
    error InvalidNativeLiquidityQuote(uint256 expected, uint256 received);
    error InvalidNativeLiquidityRange(uint256 minimum, uint256 maximum);
    error InvalidTokenConfig();
    error LockDurationTooShort(uint256 provided, uint256 minimumRequired);
    error LaunchAlreadyExists(bytes32 launchId);
    error RegistrationFailed();
    error PairNotCreated();
    error InvalidInfrastructureFee(uint256 expected, uint256 provided);
    error FeeQuoteRequired(MemeTier tier);
    error FeeQuoteSignerNotConfigured();
    error InvalidFeeQuote(address recoveredSigner);
    error FeeQuoteExpired(uint256 expiresAt, uint256 currentTimestamp);
    error FeeQuoteWrongPayer(address providedPayer, address expectedPayer);
    error FeeQuoteWrongNativeLiquidity(uint256 providedNativeLiquidity, uint256 expectedNativeLiquidity);
    error FeeQuoteNonceAlreadyUsed(address payer, uint256 nonce);
    error FeeTransferMismatch();
    error ExternalLpLockerNotConfigured();
    error InsufficientRescuableNative(uint256 requested, uint256 available);
    error RescueTokenBlocked(address token);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address _brigidToken,
        address _feeRecipient,
        uint256 _infrastructureFee,
        address _vaultFactory,
        address _launchRegistry,
        address _pancakeRouter,
        uint256 _minLpLockDuration
    ) {
        if (_brigidToken == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_vaultFactory == address(0)) revert ZeroAddress();
        if (_launchRegistry == address(0)) revert ZeroAddress();
        if (_pancakeRouter == address(0)) revert ZeroAddress();

        brigidToken = IERC20(_brigidToken);
        feeRecipient = _feeRecipient;
        infrastructureFee = _infrastructureFee;
        vaultFactory = _vaultFactory;
        launchRegistry = _launchRegistry;
        pancakeRouter = _pancakeRouter;
        minLpLockDuration = _minLpLockDuration == 0 ? DEFAULT_MIN_LP_LOCK : _minLpLockDuration;
        owner = msg.sender;
        feeQuoteSigner = msg.sender;
        minNativeLiquidity = 1 ether;
        maxNativeLiquidity = 20 ether;

        // Legacy tier values remain readable for older tools, but launch
        // liquidity is enforced by nativeLiquidityAmount and msg.value.
        tierNativeLiquidity[MemeTier.STARTER] = 1 ether;
        tierNativeLiquidity[MemeTier.GROWTH] = 2 ether;
        tierNativeLiquidity[MemeTier.PREMIUM] = 3 ether;
        tierEnabled[MemeTier.STARTER] = true;
        tierEnabled[MemeTier.GROWTH] = true;
        tierEnabled[MemeTier.PREMIUM] = true;
    }

    function launchMeme(LaunchMemeParams calldata params) external payable nonReentrant returns (bytes32 launchId) {
        uint256 fee = _staticInfrastructureFeeForLaunch(params);
        launchId = _launchMeme(params, fee, params.nativeLiquidityAmount, 0, false);
    }

    function launchMemeWithFeeQuote(LaunchMemeParams calldata params, FeeQuote calldata quote)
        external
        payable
        nonReentrant
        returns (bytes32 launchId)
    {
        uint256 fee = _quotedInfrastructureFeeForLaunch(params, quote);
        launchId = _launchMeme(params, fee, params.nativeLiquidityAmount, 0, false);
    }

    function launchMemeWithExternalLocker(ExternalMemeLockParams calldata params)
        external
        payable
        nonReentrant
        returns (bytes32 launchId)
    {
        if (externalLpLocker == address(0)) revert ExternalLpLockerNotConfigured();
        if (msg.value < params.launch.nativeLiquidityAmount + params.lockerFeeAmount) revert ZeroAmount();

        uint256 fee = _staticInfrastructureFeeForLaunch(params.launch);
        launchId = _launchMeme(params.launch, fee, params.launch.nativeLiquidityAmount, params.lockerFeeAmount, true);
    }

    function launchMemeWithFeeQuoteAndExternalLocker(ExternalMemeLockParams calldata params, FeeQuote calldata quote)
        external
        payable
        nonReentrant
        returns (bytes32 launchId)
    {
        if (externalLpLocker == address(0)) revert ExternalLpLockerNotConfigured();
        if (msg.value < params.launch.nativeLiquidityAmount + params.lockerFeeAmount) revert ZeroAmount();

        uint256 fee = _quotedInfrastructureFeeForLaunch(params.launch, quote);
        launchId = _launchMeme(params.launch, fee, params.launch.nativeLiquidityAmount, params.lockerFeeAmount, true);
    }

    function _launchMeme(
        LaunchMemeParams calldata params,
        uint256 fee,
        uint256 nativeLiquidityAmount,
        uint256 lockerFeeAmount,
        bool useExternalLocker
    ) internal returns (bytes32 launchId) {
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        if (bytes(params.tokenName).length == 0 || bytes(params.tokenSymbol).length == 0) {
            revert InvalidTokenConfig();
        }
        if (!_isValidTier(params.tier)) revert InvalidTier();
        if (!_isValidSupply(params.supply)) revert InvalidSupply();
        if (!_isValidAllocation(params.allocation)) revert InvalidAllocation();
        if (!tierEnabled[params.tier]) revert TierDisabled(params.tier);
        if (params.lpLockDurationSeconds < minLpLockDuration) {
            revert LockDurationTooShort(params.lpLockDurationSeconds, minLpLockDuration);
        }

        _validateNativeLiquidity(params.nativeLiquidityAmount);
        if (nativeLiquidityAmount != params.nativeLiquidityAmount) {
            revert InvalidNativeLiquidityQuote(params.nativeLiquidityAmount, nativeLiquidityAmount);
        }
        if (!useExternalLocker && msg.value != params.nativeLiquidityAmount) {
            revert InvalidNativeLiquidityQuote(params.nativeLiquidityAmount, msg.value);
        }

        if (fee > 0) {
            uint256 recipientBalanceBefore = brigidToken.balanceOf(feeRecipient);
            brigidToken.safeTransferFrom(msg.sender, feeRecipient, fee);
            uint256 recipientBalanceAfter = brigidToken.balanceOf(feeRecipient);
            if (recipientBalanceAfter < recipientBalanceBefore || recipientBalanceAfter - recipientBalanceBefore != fee)
            {
                revert FeeTransferMismatch();
            }
            emit InfrastructureFeePaid(msg.sender, fee, feeRecipient);
        }

        uint256 tokenSupply = supplyFor(params.supply);
        uint16 devAllocationBps = devAllocationBpsFor(params.allocation);

        BrigidStandardMemeToken token = new BrigidStandardMemeToken(params.tokenName, params.tokenSymbol, tokenSupply);

        launchId = _computeLaunchId(msg.sender, address(token));
        if (launches[launchId].deployer != address(0)) revert LaunchAlreadyExists(launchId);

        uint256 devAllocation = (tokenSupply * devAllocationBps) / BPS_DENOMINATOR;
        uint256 tokenLiquidity = tokenSupply - devAllocation;

        address devVault = address(0);
        if (devAllocation > 0) {
            devVault = _createCanonicalDevVault(
                msg.sender, address(token), devAllocation, params.vaultPermitExpiry, params.vaultPermitSig
            );
            if (devVault == address(0)) revert ZeroAddress();
            IERC20(address(token)).forceApprove(devVault, devAllocation);
            IMemeVault(devVault).fund();
        }

        IERC20(address(token)).forceApprove(pancakeRouter, tokenLiquidity);
        uint256 deadline = block.timestamp + 1200;
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IMemePancakeRouter(pancakeRouter)
        .addLiquidityETH{value: nativeLiquidityAmount}(
            address(token), tokenLiquidity, params.tokenAmountMin, params.nativeAmountMin, address(this), deadline
        );
        if (liquidity == 0) revert ZeroAmount();

        address factory = IMemePancakeRouter(pancakeRouter).factory();
        address wrappedNative = IMemePancakeRouter(pancakeRouter).WETH();
        address lpPair = IMemePancakeFactory(factory).getPair(address(token), wrappedNative);
        if (lpPair == address(0)) revert PairNotCreated();

        uint256 unlockTime = block.timestamp + params.lpLockDurationSeconds;
        uint256 lpBalance = IERC20(lpPair).balanceOf(address(this));
        if (lpBalance == 0) revert ZeroAmount();

        address lpLockAddress;
        if (useExternalLocker) {
            lpLockAddress =
                _lockWithExternalLocker(launchId, lpPair, msg.sender, lpBalance, unlockTime, lockerFeeAmount);
        } else {
            lpLockAddress = _lockWithBrigidLocker(lpPair, msg.sender, lpBalance, unlockTime);
        }

        uint256 unusedToken = tokenLiquidity - amountToken;
        if (unusedToken > 0) {
            IERC20(address(token)).safeTransfer(msg.sender, unusedToken);
        }

        uint256 nativeBalanceAfter = address(this).balance;
        uint256 unusedNative = nativeBalanceAfter > nativeBalanceBefore ? nativeBalanceAfter - nativeBalanceBefore : 0;
        if (unusedNative > 0) {
            (bool refundOk,) = msg.sender.call{value: unusedNative}("");
            if (!refundOk) {
                pendingNativeRefunds[msg.sender] += unusedNative;
                totalPendingNativeRefunds += unusedNative;
                emit NativeRefundStored(msg.sender, unusedNative);
            }
        }

        bytes32 registryLaunchId = IMemeLaunchRegistry(launchRegistry)
            .registerMemeLaunchFor(
                msg.sender,
                address(token),
                devVault,
                lpPair,
                lpLockAddress,
                uint8(params.tier),
                amountETH,
                amountToken,
                tokenSupply,
                devAllocationBps
            );
        if (registryLaunchId != launchId) revert RegistrationFailed();

        launches[launchId] = MemeLaunchRecord({
            deployer: msg.sender,
            token: address(token),
            devVault: devVault,
            lpPair: lpPair,
            lpLock: lpLockAddress,
            tier: params.tier,
            nativeLiquidity: amountETH,
            tokenLiquidity: amountToken,
            tokenSupply: tokenSupply,
            devAllocationBps: devAllocationBps,
            createdAt: block.timestamp
        });
        deployerLaunches[msg.sender].push(launchId);
        tokenToLaunch[address(token)] = launchId;
        totalLaunches += 1;

        emit MemeLaunchCreated(
            launchId,
            msg.sender,
            address(token),
            devVault,
            lpPair,
            lpLockAddress,
            params.tier,
            amountETH,
            amountToken,
            tokenSupply,
            devAllocationBps
        );
    }

    function supplyFor(MemeSupply supply) public pure returns (uint256) {
        if (supply == MemeSupply.ONE_MILLION) return 1_000_000 ether;
        if (supply == MemeSupply.TEN_MILLION) return 10_000_000 ether;
        if (supply == MemeSupply.ONE_HUNDRED_MILLION) return 100_000_000 ether;
        if (supply == MemeSupply.ONE_BILLION) return 1_000_000_000 ether;
        revert InvalidSupply();
    }

    function devAllocationBpsFor(MemeAllocation allocation) public pure returns (uint16) {
        if (allocation == MemeAllocation.COMMUNITY_MAX) return 0;
        if (allocation == MemeAllocation.LEAN_BUILDER) return 500;
        if (allocation == MemeAllocation.CLASSIC_MEME) return 1_000;
        if (allocation == MemeAllocation.BUILDER_RESERVE) return 1_500;
        if (allocation == MemeAllocation.MAX_BUILDER) return 2_500;
        revert InvalidAllocation();
    }

    function setInfrastructureFee(uint256 newFee) external onlyOwner {
        uint256 previousFee = infrastructureFee;
        infrastructureFee = newFee;
        emit InfrastructureFeeUpdated(previousFee, newFee);
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

    function setExternalLpLocker(address newLocker) external onlyOwner {
        emit ExternalLpLockerUpdated(externalLpLocker, newLocker);
        externalLpLocker = newLocker;
    }

    function setNativeLiquidityRange(uint256 newMin, uint256 newMax) external onlyOwner {
        if (newMin == 0 || newMax == 0) revert ZeroAmount();
        if (newMin > newMax) revert InvalidNativeLiquidityRange(newMin, newMax);
        if (newMin % NATIVE_LIQUIDITY_STEP != 0) revert InvalidNativeLiquidityStep(NATIVE_LIQUIDITY_STEP, newMin);
        if (newMax % NATIVE_LIQUIDITY_STEP != 0) revert InvalidNativeLiquidityStep(NATIVE_LIQUIDITY_STEP, newMax);
        uint256 previousMin = minNativeLiquidity;
        uint256 previousMax = maxNativeLiquidity;
        minNativeLiquidity = newMin;
        maxNativeLiquidity = newMax;
        emit NativeLiquidityRangeUpdated(previousMin, previousMax, newMin, newMax);
    }

    function setTierEnabled(MemeTier tier, bool enabled) external onlyOwner {
        if (!_isValidTier(tier)) revert InvalidTier();
        tierEnabled[tier] = enabled;
        emit TierStatusUpdated(tier, enabled);
    }

    function setTierNativeLiquidity(MemeTier tier, uint256 newAmount) external onlyOwner {
        if (!_isValidTier(tier)) revert InvalidTier();
        if (newAmount == 0) revert ZeroAmount();
        uint256 previousAmount = tierNativeLiquidity[tier];
        tierNativeLiquidity[tier] = newAmount;
        emit TierNativeLiquidityUpdated(tier, previousAmount, newAmount);
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

    function getDeployerLaunches(address deployer) external view returns (bytes32[] memory) {
        return deployerLaunches[deployer];
    }

    function claimNativeRefund() external nonReentrant {
        uint256 amount = pendingNativeRefunds[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingNativeRefunds[msg.sender] = 0;
        totalPendingNativeRefunds -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Native refund send failed");
        emit NativeRefundClaimed(msg.sender, amount);
    }

    function rescuableNative() public view returns (uint256) {
        uint256 balance = address(this).balance;
        return balance > totalPendingNativeRefunds ? balance - totalPendingNativeRefunds : 0;
    }

    function rescueNative(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = rescuableNative();
        if (amount > available) revert InsufficientRescuableNative(amount, available);
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "Native rescue failed");
        emit NativeRescued(recipient, amount);
    }

    function rescueToken(address token, address recipient, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(brigidToken) || tokenToLaunch[token] != bytes32(0)) {
            revert RescueTokenBlocked(token);
        }
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRescued(token, recipient, amount);
    }

    function computeLaunchId(address deployer, address token) external view returns (bytes32) {
        return _computeLaunchId(deployer, token);
    }

    function feeQuoteDigest(FeeQuote calldata quote) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                FEE_QUOTE_TYPEHASH,
                address(this),
                block.chainid,
                address(brigidToken),
                quote.payer,
                quote.nativeLiquidityAmount,
                quote.feeAmount,
                quote.expiresAt,
                quote.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _feeQuoteDomainSeparator(), structHash));
    }

    function _createCanonicalDevVault(
        address originalDeployer,
        address token,
        uint256 allocationRaw,
        uint256 permitExpiry,
        bytes calldata permitSig
    ) internal returns (address vault) {
        (bool ok, bytes memory result) = vaultFactory.call(
            abi.encodeWithSignature(
                "createVaultFor(address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes)",
                originalDeployer,
                token,
                originalDeployer,
                address(this),
                allocationRaw,
                block.timestamp + DEV_VESTING_START_DELAY,
                0,
                DEV_VESTING_INTERVAL,
                DEV_VESTING_DURATION / DEV_VESTING_INTERVAL,
                1 hours,
                1 days,
                72 hours,
                permitExpiry,
                permitSig
            )
        );
        if (!ok || result.length < 32) return address(0);
        vault = abi.decode(result, (address));
    }

    function _lockWithBrigidLocker(address lpPair, address beneficiary, uint256 lpBalance, uint256 unlockTime)
        internal
        returns (address lpLockAddress)
    {
        BrigidManagedLPLock lpLock = new BrigidManagedLPLock(lpPair, beneficiary, address(this), unlockTime);
        lpLockAddress = address(lpLock);
        IERC20(lpPair).forceApprove(lpLockAddress, lpBalance);
        lpLock.deposit(lpBalance);
    }

    function _lockWithExternalLocker(
        bytes32 launchId,
        address lpPair,
        address beneficiary,
        uint256 lpBalance,
        uint256 unlockTime,
        uint256 lockerFeeAmount
    ) internal returns (address lockTarget) {
        IERC20(lpPair).forceApprove(externalLpLocker, lpBalance);
        lockTarget = IMemeExternalLPLocker(externalLpLocker).lockLpTokens{value: lockerFeeAmount}(
            lpPair, beneficiary, lpBalance, unlockTime
        );
        if (lockTarget == address(0)) revert ZeroAddress();
        if (IERC20(lpPair).balanceOf(address(this)) != 0) revert ZeroAmount();
        emit ExternalLpLockUsed(launchId, externalLpLocker, lockTarget, lockerFeeAmount);
    }

    function _computeLaunchId(address deployer, address token) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, deployer, token));
    }

    function _validateNativeLiquidity(uint256 amount) internal view {
        if (amount < minNativeLiquidity || amount > maxNativeLiquidity) {
            revert InvalidNativeLiquidity(minNativeLiquidity, maxNativeLiquidity, amount);
        }
        if (amount % NATIVE_LIQUIDITY_STEP != 0) {
            revert InvalidNativeLiquidityStep(NATIVE_LIQUIDITY_STEP, amount);
        }
    }

    function _staticInfrastructureFeeForLaunch(LaunchMemeParams calldata params) internal view returns (uint256) {
        if (!_isValidTier(params.tier)) revert InvalidTier();
        if (feeQuoteRequired && infrastructureFee > 0) revert FeeQuoteRequired(params.tier);
        if (params.infrastructureFeeAmount != infrastructureFee) {
            revert InvalidInfrastructureFee(infrastructureFee, params.infrastructureFeeAmount);
        }
        return infrastructureFee;
    }

    function _quotedInfrastructureFeeForLaunch(LaunchMemeParams calldata params, FeeQuote calldata quote)
        internal
        returns (uint256)
    {
        if (!_isValidTier(params.tier)) revert InvalidTier();
        if (infrastructureFee == 0) return 0;
        if (!feeQuoteRequired && quote.signature.length == 0) {
            if (params.infrastructureFeeAmount != infrastructureFee) {
                revert InvalidInfrastructureFee(infrastructureFee, params.infrastructureFeeAmount);
            }
            return infrastructureFee;
        }
        return _verifyFeeQuote(params.nativeLiquidityAmount, quote);
    }

    function _verifyFeeQuote(uint256 nativeLiquidityAmount, FeeQuote calldata quote) internal returns (uint256) {
        if (feeQuoteSigner == address(0)) revert FeeQuoteSignerNotConfigured();
        if (quote.payer != msg.sender) revert FeeQuoteWrongPayer(quote.payer, msg.sender);
        if (quote.nativeLiquidityAmount != nativeLiquidityAmount) {
            revert FeeQuoteWrongNativeLiquidity(quote.nativeLiquidityAmount, nativeLiquidityAmount);
        }
        if (quote.expiresAt < block.timestamp) revert FeeQuoteExpired(quote.expiresAt, block.timestamp);
        if (quote.feeAmount == 0) revert ZeroAmount();
        if (feeQuoteNonceUsed[quote.payer][quote.nonce]) revert FeeQuoteNonceAlreadyUsed(quote.payer, quote.nonce);

        address recovered = ECDSA.recover(feeQuoteDigest(quote), quote.signature);
        if (recovered != feeQuoteSigner) revert InvalidFeeQuote(recovered);

        feeQuoteNonceUsed[quote.payer][quote.nonce] = true;
        emit FeeQuoteUsed(quote.payer, quote.nativeLiquidityAmount, quote.feeAmount, quote.nonce, quote.expiresAt);
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

    function _isValidTier(MemeTier tier) internal pure returns (bool) {
        return uint8(tier) <= uint8(MemeTier.PREMIUM);
    }

    function _isValidSupply(MemeSupply supply) internal pure returns (bool) {
        return uint8(supply) <= uint8(MemeSupply.ONE_BILLION);
    }

    function _isValidAllocation(MemeAllocation allocation) internal pure returns (bool) {
        return uint8(allocation) <= uint8(MemeAllocation.MAX_BUILDER);
    }

    receive() external payable {}
}

contract BrigidStandardMemeToken is IERC20Metadata {
    string private _name;
    string private _symbol;
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory name_, string memory symbol_, uint256 supply_) {
        _name = name_;
        _symbol = symbol_;
        _mint(msg.sender, supply_);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: transfer to zero");
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from zero");
        require(spender != address(0), "ERC20: approve to zero");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

interface IMemeLaunchRegistry {
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
    ) external returns (bytes32);
}

interface IMemeVault {
    function fund() external;
}

interface IMemePancakeRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IMemePancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IMemeExternalLPLocker {
    function lockLpTokens(address lpToken, address beneficiary, uint256 amount, uint256 unlockTime)
        external
        payable
        returns (address lockTarget);
}
