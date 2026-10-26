// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Owner-managed configuration and linearly refilling limits for a Midnight Managed Account.
/// @dev Limits are keyed by a `bytes32` derived in `LimitKeys`. A missing limit (zero `maxAmount`) denies
/// consumption, so receiver-keyed limits double as receiver allowlists.
abstract contract MidnightManagedAccountLimits {
    /// @dev Rates are per second, scaled by WAD.
    struct MarketConfig {
        uint128 maxDebt;
        uint64 maxBorrowRate;
        uint64 minLendRate;
        bool enabled;
    }

    struct Limit {
        uint128 maxAmount;
        uint128 refillPerSecond;
        uint128 balance;
        uint64 lastUpdate;
    }

    error InvalidOwner();
    error OnlyOwner();
    error OnlyOwnerOrFreezer();
    error LimitNotConfigured(bytes32 key);
    error LimitExceeded(bytes32 key, uint256 available, uint256 required);

    event SetPaused(address indexed caller, bool paused);
    event SetOperator(address indexed caller, address indexed operator, bool enabled);
    event SetFreezer(address indexed freezer, bool enabled);
    event SetMarketConfig(
        bytes32 indexed marketId, uint128 maxDebt, uint64 maxBorrowRate, uint64 minLendRate, bool enabled
    );
    event SetLimit(bytes32 indexed key, uint128 maxAmount, uint128 refillPerSecond, uint128 balance);
    event ConsumeLimit(bytes32 indexed key, uint256 amount, uint256 remaining);

    address public immutable OWNER;

    bool public paused = true;

    mapping(address operator => bool) public isOperator;
    mapping(address freezer => bool) public isFreezer;
    mapping(bytes32 marketId => MarketConfig) public marketConfig;
    mapping(bytes32 key => Limit) public limits;

    modifier onlyOwner() {
        require(msg.sender == OWNER, OnlyOwner());
        _;
    }

    modifier onlyOwnerOrFreezer() {
        require(msg.sender == OWNER || isFreezer[msg.sender], OnlyOwnerOrFreezer());
        _;
    }

    constructor(address owner) {
        require(owner != address(0), InvalidOwner());
        OWNER = owner;
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit SetPaused(msg.sender, newPaused);
    }

    function setOperator(address operator, bool enabled) external onlyOwner {
        isOperator[operator] = enabled;
        emit SetOperator(msg.sender, operator, enabled);
    }

    /// @dev Freezers can only restrict, never unpause or configure.
    function setFreezer(address freezer, bool enabled) external onlyOwner {
        isFreezer[freezer] = enabled;
        emit SetFreezer(freezer, enabled);
    }

    function freeze() external onlyOwnerOrFreezer {
        paused = true;
        emit SetPaused(msg.sender, true);
    }

    function freezeOperator(address operator) external onlyOwnerOrFreezer {
        isOperator[operator] = false;
        emit SetOperator(msg.sender, operator, false);
    }

    function setMarketConfig(bytes32 marketId, uint128 maxDebt, uint64 maxBorrowRate, uint64 minLendRate, bool enabled)
        external
        onlyOwner
    {
        marketConfig[marketId] =
            MarketConfig({maxDebt: maxDebt, maxBorrowRate: maxBorrowRate, minLendRate: minLendRate, enabled: enabled});
        emit SetMarketConfig(marketId, maxDebt, maxBorrowRate, minLendRate, enabled);
    }

    /// @dev A new limit starts full. Reconfiguring clamps the balance to the new maximum, so tightening never
    /// grants fresh capacity. To refill a limit, remove it (zero `maxAmount`) and set it again.
    function setLimit(bytes32 key, uint128 maxAmount, uint128 refillPerSecond) external onlyOwner {
        uint256 startBalance;
        if (limits[key].maxAmount == 0) {
            startBalance = maxAmount;
        } else {
            uint256 available = availableLimit(key);
            startBalance = available < maxAmount ? available : maxAmount;
        }

        // forge-lint: disable-next-item(unsafe-typecast) startBalance <= maxAmount (uint128); timestamps fit uint64.
        limits[key] = Limit({
            maxAmount: maxAmount, refillPerSecond: refillPerSecond, balance: uint128(startBalance),
            lastUpdate: uint64(block.timestamp)
        });
        // forge-lint: disable-next-item(unsafe-typecast) startBalance <= maxAmount (uint128).
        emit SetLimit(key, maxAmount, refillPerSecond, uint128(startBalance));
    }

    function availableLimit(bytes32 key) public view returns (uint256) {
        Limit memory limit = limits[key];
        uint256 refilled = uint256(limit.balance) + uint256(limit.refillPerSecond) * (block.timestamp - limit.lastUpdate);
        return refilled < limit.maxAmount ? refilled : limit.maxAmount;
    }

    function _consumeLimit(bytes32 key, uint256 amount) internal {
        Limit storage limit = limits[key];
        require(limit.maxAmount > 0, LimitNotConfigured(key));

        uint256 available = availableLimit(key);
        require(amount <= available, LimitExceeded(key, available, amount));

        // forge-lint: disable-next-item(unsafe-typecast) available <= maxAmount (uint128).
        limit.balance = uint128(available - amount);
        // forge-lint: disable-next-item(unsafe-typecast) timestamps fit uint64.
        limit.lastUpdate = uint64(block.timestamp);
        emit ConsumeLimit(key, amount, available - amount);
    }
}
