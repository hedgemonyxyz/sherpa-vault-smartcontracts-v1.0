// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "./external/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "./external/ReentrancyGuardTransient.sol";

/**
 * @title SherpaUSD
 * @notice 1:1 wrapper for USDC with epoch-based withdrawals
 * @dev Simplified version for CCIP - bridging handled by separate token pools
 */
contract SherpaUSD is ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The asset being wrapped (USDC)
    address public immutable asset;

    /// @notice The current epoch number
    uint32 public currentEpoch;
    /// @notice Enable automatic USDC transfers in processWithdrawals()
    bool public autoTransfer;

    /// @notice The vault/keeper address
    address public keeper;

    /// @notice The operator address for automated operations
    address public operator;

    /// @notice Prevents keeper-swap attack (owner swaps keeper to drain user USDC approvals)
    bool private keeperLocked;

    /// @notice User withdrawal receipts
    mapping(address user => WithdrawalReceipt receipt) public withdrawalReceipts;

    /// @notice Withdrawal amount for current epoch
    uint256 public withdrawalAmountForEpoch;

    /// @notice Deposit amount for current epoch
    uint256 public depositAmountForEpoch;

    /// @notice Approved adjustment amounts for vault rebalancing
    mapping(address vault => uint256 amount) public approvedTotalStakedAdjustment;
    mapping(address vault => uint256 amount) public approvedAccountingAdjustment;

    struct WithdrawalReceipt {
        uint224 amount;
        uint32 epoch;
    }

    event DepositToVault(address indexed user, uint256 amount);
    event WithdrawalInitiated(address indexed user, uint224 amount, uint32 indexed epoch);
    event Withdrawn(address indexed user, uint256 amount);
    event WithdrawalsProcessed(uint256 withdrawalAmount, uint256 balance, uint32 indexed epoch);
    event AssetTransferred(address indexed to, uint256 amount);
    event PermissionedMint(address indexed to, uint256 amount);
    event PermissionedBurn(address indexed from, uint256 amount);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event AutoTransferSet(bool oldValue, bool newValue);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event RebalanceApprovalSet(address indexed vault, uint256 totalStakedAmount, uint256 accountingAmount);
    event TotalStakedApprovalConsumed(address indexed vault);
    event AccountingApprovalConsumed(address indexed vault);

    error AmountMustBeGreaterThanZero();
    error AddressMustBeNonZero();
    error InsufficientBalance();
    error NotKeeper();
    error CannotCompleteWithdrawalInSameEpoch();
    error OnlyOperator();
    error InvalidAssetDecimals();
    error CannotRenounceOwnership();
    error KeeperAlreadyLocked();
    error ApprovalNotConsumed();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert OnlyOperator();
        _;
    }

    constructor(
        address _asset,
        address _keeper
    ) ERC20("Sherpa USD", "sherpaUSD") {
        if (_asset == address(0)) revert AddressMustBeNonZero();
        if (_keeper == address(0)) revert AddressMustBeNonZero();

        // CRITICAL: SherpaUSD only supports 6-decimal assets WITHOUT transfer fees (e.g., USDC)
        // DO NOT use fee-on-transfer tokens (including USDT which has dormant fee mechanisms)
        if (IERC20Metadata(_asset).decimals() != 6) revert InvalidAssetDecimals();

        asset = _asset;
        keeper = _keeper;
        currentEpoch = 1;
        autoTransfer = false; // Default to manual mode for safety
    }

    /**
     * @notice Vault deposits USDC from user and mints sherpaUSD to keeper
     * @param from User depositing USDC
     * @param amount Amount of USDC to deposit
     * @dev INTENTIONAL DESIGN: Uses `from` parameter instead of msg.sender to allow keeper (vault)
     *      to pull funds on behalf of users. Users approve this contract and call vault.depositAndStake(),
     *      which calls this function with the user's address. Users must trust keeper to only pass the
     *      actual caller's address. Malicious/compromised keeper could drain approved users.
     */
    function depositToVault(
        address from,
        uint256 amount
    ) external nonReentrant onlyKeeper {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        _mint(keeper, amount);
        depositAmountForEpoch += amount;

        emit DepositToVault(from, amount);

        IERC20(asset).safeTransferFrom(from, address(this), amount);
    }

    /**
     * @notice Initiate withdrawal - burns sherpaUSD and creates receipt
     * @param amount Amount to withdraw
     */
    function initiateWithdrawal(uint224 amount) external nonReentrant {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _burn(msg.sender, amount);

        WithdrawalReceipt storage receipt = withdrawalReceipts[msg.sender];
        receipt.amount = uint224(uint256(receipt.amount) + amount);
        receipt.epoch = currentEpoch;

        withdrawalAmountForEpoch += amount;

        emit WithdrawalInitiated(msg.sender, amount, currentEpoch);
    }

    /**
     * @notice Initiate withdrawal from vault (called by vault on behalf of user)
     * @param from User address to create withdrawal receipt for
     * @param amount Amount to withdraw
     * @dev INTENTIONAL DESIGN: Uses `from` parameter to allow keeper (vault) to create withdrawal
     *      receipts on behalf of users. Vault transfers sherpaUSD here, then this function burns it
     *      and creates receipt for user. Users trust keeper to only create receipts for legitimate unstakes.
     */
    function initiateWithdrawalFromVault(
        address from,
        uint224 amount
    ) external nonReentrant onlyKeeper {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // Burn from this contract (vault transferred tokens here)
        _burn(address(this), amount);

        // Cache current epoch
        uint32 epoch = currentEpoch;

        // Create/update withdrawal receipt for user
        WithdrawalReceipt storage receipt = withdrawalReceipts[from];
        receipt.amount = uint224(uint256(receipt.amount) + amount);
        receipt.epoch = epoch;

        withdrawalAmountForEpoch += amount;

        emit WithdrawalInitiated(from, amount, epoch);
    }

    /**
     * @notice Complete withdrawal after epoch passes
     */
    function completeWithdrawal() external nonReentrant {
        WithdrawalReceipt storage receipt = withdrawalReceipts[msg.sender];

        if (receipt.epoch == currentEpoch) {
            revert CannotCompleteWithdrawalInSameEpoch();
        }
        if (receipt.amount == 0) revert AmountMustBeGreaterThanZero();

        uint256 withdrawAmount = receipt.amount;
        receipt.amount = 0;

        emit Withdrawn(msg.sender, withdrawAmount);

        IERC20(asset).safeTransfer(msg.sender, withdrawAmount);
    }

    /**
     * @notice Process withdrawals and roll to next epoch (keeper only)
     * @dev If autoTransfer is enabled, automatically transfers USDC to/from owner
     */
    function processWithdrawals() external nonReentrant onlyKeeper {
        // Cache storage values
        uint256 withdrawalAmount = withdrawalAmountForEpoch;
        uint256 depositAmount = depositAmountForEpoch;
        uint32 epoch = currentEpoch;

        // Automatic transfer logic (if enabled)
        if (autoTransfer) {
            if (withdrawalAmount > depositAmount) {
                // More withdrawals than deposits - pull from owner
                IERC20(asset).safeTransferFrom(
                    owner(),
                    address(this),
                    withdrawalAmount - depositAmount
                );
            } else if (withdrawalAmount < depositAmount) {
                // More deposits than withdrawals - send excess to owner
                IERC20(asset).safeTransfer(
                    owner(),
                    depositAmount - withdrawalAmount
                );
            }
        }

        emit WithdrawalsProcessed(withdrawalAmount, depositAmount, epoch);

        currentEpoch = epoch + 1;
        depositAmountForEpoch = 0;
        withdrawalAmountForEpoch = 0;
    }

    /**
     * @notice Permissioned mint for yield (keeper only)
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function permissionedMint(address to, uint256 amount) external onlyKeeper {
        _mint(to, amount);
        emit PermissionedMint(to, amount);
    }

    /**
     * @notice Permissioned burn (keeper only)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function permissionedBurn(address from, uint256 amount) external onlyKeeper {
        _burn(from, amount);
        emit PermissionedBurn(from, amount);
    }

    /**
     * @notice Operator-level mint for manual rebalancing across chains
     * @param to Address to mint to
     * @param amount Amount to mint
     * @dev Sets approval for vault to adjust totalStaked and accountingSupply
     * @dev Reverts if previous approvals not consumed (prevents accounting corruption)
     */
    function ownerMint(address to, uint256 amount) external onlyOperator {
        // Enforce atomicity: previous approvals must be consumed before new mint
        if (approvedTotalStakedAdjustment[to] != 0) revert ApprovalNotConsumed();
        if (approvedAccountingAdjustment[to] != 0) revert ApprovalNotConsumed();

        _mint(to, amount);

        // Approve vault to adjust by this amount
        approvedTotalStakedAdjustment[to] = amount;
        approvedAccountingAdjustment[to] = amount;

        emit PermissionedMint(to, amount);
        emit RebalanceApprovalSet(to, amount, amount);
    }

    /**
     * @notice Operator-level burn for manual rebalancing across chains
     * @param from Address to burn from
     * @param amount Amount to burn
     * @dev Sets approval for vault to adjust totalStaked and accountingSupply
     * @dev Reverts if previous approvals not consumed (prevents accounting corruption)
     */
    function ownerBurn(address from, uint256 amount) external onlyOperator {
        // Enforce atomicity: previous approvals must be consumed before new burn
        if (approvedTotalStakedAdjustment[from] != 0) revert ApprovalNotConsumed();
        if (approvedAccountingAdjustment[from] != 0) revert ApprovalNotConsumed();

        _burn(from, amount);

        // Approve vault to adjust by this amount
        approvedTotalStakedAdjustment[from] = amount;
        approvedAccountingAdjustment[from] = amount;

        emit PermissionedBurn(from, amount);
        emit RebalanceApprovalSet(from, amount, amount);
    }

    /**
     * @notice Operator-level mint for asset-only rebalancing (yield-induced backing imbalances)
     * @param to Address to mint to
     * @param amount Amount to mint
     * @dev Only sets approval for totalStaked adjustment, NOT accountingSupply
     * @dev Use this when rebalancing sherpaUSD backing without moving shUSD shares
     * @dev Reverts if previous approvals not consumed (prevents accounting corruption)
     */
    function ownerMintAssetOnly(address to, uint256 amount) external onlyOperator {
        // Enforce atomicity: previous approvals must be consumed before new mint
        if (approvedTotalStakedAdjustment[to] != 0) revert ApprovalNotConsumed();
        if (approvedAccountingAdjustment[to] != 0) revert ApprovalNotConsumed();

        _mint(to, amount);

        // Only approve totalStaked adjustment
        approvedTotalStakedAdjustment[to] = amount;
        // DO NOT set approvedAccountingAdjustment - no shares are moving

        emit PermissionedMint(to, amount);
        emit RebalanceApprovalSet(to, amount, 0);
    }

    /**
     * @notice Operator-level burn for asset-only rebalancing (yield-induced backing imbalances)
     * @param from Address to burn from
     * @param amount Amount to burn
     * @dev Only sets approval for totalStaked adjustment, NOT accountingSupply
     * @dev Use this when rebalancing sherpaUSD backing without moving shUSD shares
     * @dev Reverts if previous approvals not consumed (prevents accounting corruption)
     */
    function ownerBurnAssetOnly(address from, uint256 amount) external onlyOperator {
        // Enforce atomicity: previous approvals must be consumed before new burn
        if (approvedTotalStakedAdjustment[from] != 0) revert ApprovalNotConsumed();
        if (approvedAccountingAdjustment[from] != 0) revert ApprovalNotConsumed();

        _burn(from, amount);

        // Only approve totalStaked adjustment
        approvedTotalStakedAdjustment[from] = amount;
        // DO NOT set approvedAccountingAdjustment - no shares are moving

        emit PermissionedBurn(from, amount);
        emit RebalanceApprovalSet(from, amount, 0);
    }

    /**
     * @notice Consume approval for totalStaked adjustment
     * @dev Only callable by the keeper (vault)
     */
    function consumeTotalStakedApproval() external onlyKeeper {
        approvedTotalStakedAdjustment[msg.sender] = 0;
        emit TotalStakedApprovalConsumed(msg.sender);
    }

    /**
     * @notice Consume approval for accounting adjustment
     * @dev Only callable by the keeper (vault)
     */
    function consumeAccountingApproval() external onlyKeeper {
        approvedAccountingAdjustment[msg.sender] = 0;
        emit AccountingApprovalConsumed(msg.sender);
    }

    /**
     * @notice Transfer USDC to external address (operator for yield strategies)
     * @param to Destination address
     * @param amount Amount to transfer
     */
    function transferAsset(
        address to,
        uint256 amount
    ) external onlyOperator {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        emit AssetTransferred(to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    /**
     * @notice Set new keeper address (one-time only)
     * @param _keeper New keeper address
     * @dev SECURITY: Locks after first call to prevent keeper-swap attack where malicious keeper drains user USDC approvals
     * @dev During deployment: wrapper initialized with temporary keeper, then this is called once to set vault as keeper
     */
    function setKeeper(address _keeper) external onlyOwner {
        if (keeperLocked) revert KeeperAlreadyLocked();
        if (_keeper == address(0)) revert AddressMustBeNonZero();
        emit KeeperSet(keeper, _keeper);
        keeper = _keeper;
        keeperLocked = true; // Lock permanently after first call
    }

    /**
     * @notice Set or change the operator address (owner only)
     * @param newOperator Address of the new operator for automated operations
     */
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert AddressMustBeNonZero();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /**
     * @notice Enable or disable automatic USDC transfers in processWithdrawals()
     * @param _enabled True to enable automatic transfers, false for manual control
     */
    function setAutoTransfer(bool _enabled) external onlyOwner {
        emit AutoTransferSet(autoTransfer, _enabled);
        autoTransfer = _enabled;
    }

    /**
     * @notice Renouncing ownership is disabled for SherpaUSD
     * @dev SherpaUSD requires an active owner for keeper/operator management
     * @dev Ownership is transferred to a multisig for decentralization
     */
    function renounceOwnership() public override onlyOwner {
        revert CannotRenounceOwnership();
    }

    /**
     * @notice Returns 6 decimals (same as USDC)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
