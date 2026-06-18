// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Project-owner subscription contract. Accepts BRIGID payment and emits
///         SubscriptionPurchased so the Beacon worker can index subscription status.
///         No funds sit in this contract — tokens are forwarded to treasury immediately.
///
/// @dev Token support: **standard ERC-20 only** (exact `transferFrom` amount delivered to treasury).
///      Fee-on-transfer, rebasing, blacklistable, admin-burnable, or other
///      balance-manipulating tokens revert with `UnexpectedTransferAmount` and are
///      UNSUPPORTED unless explicitly approved by Brigid governance.
contract BrigidSubscription {
    uint8 public constant TIER_ADVANCED_MONITORING = 1;
    uint8 public constant TERM_30_DAYS = 1;
    uint8 public constant TERM_6_MONTHS = 2;
    uint8 public constant TERM_ANNUAL = 3;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant DISCOUNT_6_MONTHS_BPS = 1_000;
    uint16 public constant DISCOUNT_ANNUAL_BPS = 1_500;

    IERC20Minimal public immutable token;

    address public owner;
    address public pendingOwner;
    address public treasury;

    /// @notice Base 30-day price in BRIGID (18 decimals) per tier.
    /// @dev Kept as `tierPrice` for compatibility with existing scripts/UI reads.
    mapping(uint8 => uint256) public tierPrice;

    /// @notice Current expiration timestamp by project token address and tier.
    mapping(address => mapping(uint8 => uint256)) public projectExpiresAt;

    event SubscriptionPurchased(
        address indexed project,
        address indexed payer,
        uint8 indexed tier,
        uint8 term,
        uint256 previousExpiresAt,
        uint256 expiresAt,
        uint256 amount,
        uint256 timestamp,
        uint256 duration,
        uint16 discountBps
    );
    event TierPriceSet(uint8 indexed tier, uint256 price);
    event ProjectExpirySet(address indexed project, uint8 indexed tier, uint256 expiresAt);
    event TreasuryUpdated(address indexed treasury);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error UnknownTier();
    error UnknownTerm();
    error TransferFailed();
    error Reentrancy();
    error UnexpectedTransferAmount();

    uint256 private _entered;

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address token_, address treasury_) {
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        token = IERC20Minimal(token_);
        treasury = treasury_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Purchase or renew a subscription for a project.
    /// @param project  The token address that identifies the project in the Beacon index.
    /// @param tier     Subscription tier. tier 1 = Advanced Monitoring.
    /// @param term     1 = 30 days, 2 = 6 months at 10% off, 3 = annual at 15% off.
    function purchase(address project, uint8 tier, uint8 term) external nonReentrant {
        if (project == address(0)) revert ZeroAddress();

        (uint256 price, uint256 duration, uint16 discountBps) = quote(tier, term);
        uint256 previousExpiresAt = projectExpiresAt[project][tier];
        uint256 startsAt = previousExpiresAt > block.timestamp ? previousExpiresAt : block.timestamp;
        uint256 expiresAt = startsAt + duration;

        uint256 treasuryBefore = token.balanceOf(treasury);
        if (!token.transferFrom(msg.sender, treasury, price)) revert TransferFailed();
        if (token.balanceOf(treasury) - treasuryBefore != price) revert UnexpectedTransferAmount();

        projectExpiresAt[project][tier] = expiresAt;

        emit SubscriptionPurchased(
            project,
            msg.sender,
            tier,
            term,
            previousExpiresAt,
            expiresAt,
            price,
            block.timestamp,
            duration,
            discountBps
        );
    }

    function setTierPrice(uint8 tier, uint256 price) external onlyOwner {
        tierPrice[tier] = price;
        emit TierPriceSet(tier, price);
    }

    /// @notice Seeds or corrects project expiry during contract migrations.
    /// @dev Intended for one-time migration from earlier subscription contracts.
    function setProjectExpiry(address project, uint8 tier, uint256 expiresAt) external onlyOwner {
        if (project == address(0)) revert ZeroAddress();
        if (tierPrice[tier] == 0) revert UnknownTier();
        projectExpiresAt[project][tier] = expiresAt;
        emit ProjectExpirySet(project, tier, expiresAt);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Returns amount, duration, and discount for a tier/term pair.
    function quote(uint8 tier, uint8 term) public view returns (uint256 amount, uint256 duration, uint16 discountBps) {
        uint256 basePrice = tierPrice[tier];
        if (basePrice == 0) revert UnknownTier();

        uint256 periods;
        (periods, duration, discountBps) = termConfig(term);
        amount = (basePrice * periods * (BPS_DENOMINATOR - discountBps)) / BPS_DENOMINATOR;
    }

    function termConfig(uint8 term) public pure returns (uint256 periods, uint256 duration, uint16 discountBps) {
        if (term == TERM_30_DAYS) return (1, 30 days, 0);
        if (term == TERM_6_MONTHS) return (6, 180 days, DISCOUNT_6_MONTHS_BPS);
        if (term == TERM_ANNUAL) return (12, 365 days, DISCOUNT_ANNUAL_BPS);
        revert UnknownTerm();
    }

    function transferOwnership(address pendingOwner_) external onlyOwner {
        if (pendingOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = pendingOwner_;
        emit OwnershipTransferStarted(msg.sender, pendingOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

}
