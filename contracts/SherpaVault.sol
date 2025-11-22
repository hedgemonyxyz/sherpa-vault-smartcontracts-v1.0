// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ShareMath} from "./lib/ShareMath.sol";
import {Vault} from "./lib/Vault.sol";
import {Ownable2Step} from "./external/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "./external/ReentrancyGuardTransient.sol";

interface ISherpaUSD {
    function permissionedMint(address to, uint256 amount) external;
    function permissionedBurn(address from, uint256 amount) external;
    function depositToVault(address from, uint256 amount) external;
    function processWithdrawals() external;
    function initiateWithdrawalFromVault(address from, uint224 amount) external;
    function approvedTotalStakedAdjustment(address vault) external view returns (uint256);
    function approvedAccountingAdjustment(address vault) external view returns (uint256);
    function consumeTotalStakedApproval() external;
    function consumeAccountingApproval() external;
}

interface IBurnMintERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
    function burn(address account, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title SherpaVault
 * @notice Cross-chain yield vault with CCIP integration
 * @dev Implements IBurnMintERC20 for CCIP burn/mint pool compatibility
 * @dev Cross-chain transfers handled via CCIP token pools (not direct messaging)
 */
contract SherpaVault is ReentrancyGuardTransient, ERC20, Ownable2Step, IBurnMintERC20 {
    using SafeERC20 for IERC20;
    using ShareMath for Vault.StakeReceipt;

    // #############################################
    // CONSTANTS
    // #############################################
    uint256 private constant MINIMUM_VALID_ROUND = 2;
    uint256 private constant MAX_PAUSE_DURATION = 24 hours; // Auto-unpause after 24 hours

    // #############################################
    // STATE
    // #############################################
    mapping(address account => Vault.StakeReceipt receipt) public stakeReceipts;
    mapping(uint256 round => uint256 pricePerShare) public roundPricePerShare;

    Vault.VaultParams public vaultParams;
    Vault.VaultState public vaultState;

    address public stableWrapper;
    uint256 public totalStaked;
    uint256 public lastRollTimestamp;
    uint256 public accountingSupply; // Tracks logical shUSD shares (immune to CCIP burns/mints)

    // CCIP specific
    uint64 public primaryChainSelector; // Primary chain selector for reference
    bool public isPrimaryChain;
    mapping(address pool => bool authorized) public ccipPools;

    // Access control and flags (packed together for gas savings)
    address public operator; // wallet employed for automated daily operations
    bool public depositsEnabled = true;
    bool public allowIndependence;
    bool public isPaused;
    uint256 public pauseDeadline; // Timestamp when auto-unpause happens (0 if not paused)
    bool private stableWrapperLocked; // Prevents wrapper-swap attack (owner swaps wrapper then rescues old tokens)

    // #############################################
    // EVENTS
    // #############################################
    event Stake(address indexed account, uint256 amount, uint256 indexed round);
    event Unstake(address indexed account, uint256 amount, uint256 indexed round);
    event ClaimShares(address indexed account, uint256 share, uint256 indexed round);
    event CapSet(uint256 oldCap, uint256 newCap);
    event RoundRolled(
        uint256 indexed round,
        uint256 pricePerShare,
        uint256 sharesMinted,
        uint256 wrappedTokensMinted,
        uint256 wrappedTokensBurned,
        uint256 yield,
        bool isYieldPositive
    );
    event InstantUnstake(address indexed account, uint256 amount, uint256 indexed round);
    event PrimaryChainSet(uint64 indexed chainSelector, bool isPrimary);
    event DepositsToggled(bool oldValue, bool newValue);
    event GlobalPriceApplied(uint256 indexed round, uint256 pricePerShare);
    event CCIPPoolAdded(address indexed pool);
    event CCIPPoolRemoved(address indexed pool);
    event StableWrapperUpdated(address indexed oldWrapper, address indexed newWrapper);
    event TokensRescued(address indexed token, uint256 amount);
    event AllowIndependenceSet(bool oldValue, bool newValue);
    event AccountingSupplyAdjusted(address indexed operator, uint256 oldValue, int256 adjustment, uint256 newValue);
    event TotalStakedAdjusted(address indexed operator, uint256 oldValue, int256 adjustment, uint256 newValue);
    event SystemPausedToggled(bool isPaused);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    // #############################################
    // ERRORS
    // #############################################
    error AmountMustBeGreaterThanZero();
    error AddressMustBeNonZero();
    error CapExceeded();
    error MinimumSupplyNotMet();
    error BelowMinimumDeposit();
    error CapMustBeGreaterThanZero();
    error OnlyPrimaryChain();
    error OnlyCCIPPool();
    error DepositsDisabled();
    error OnlySecondaryChain();
    error InsufficientReserves(uint256 needed, uint256 available);
    error InvalidRound();
    error InsufficientBalance();
    error CannotRescueWrapperToken();
    error IndependenceNotAllowed();
    error SystemPaused();
    error OnlyOperator();
    error CannotRenounceOwnership();
    error InvalidRoundNumber();
    error NotPaused();
    error DeadlineNotReached();
    error NoDeadlineSet();
    error AdjustmentNotApproved();
    error IncorrectCalculation();
    error InvalidDecimals();
    error StableWrapperAlreadyLocked();

    // #############################################
    // MODIFIERS
    // #############################################

    /**
     * @notice Ensures user functions cannot be called when system is paused
     * @dev Used during round rolls to prevent state changes that would affect price calculations
     * @dev Auto-unpauses after MAX_PAUSE_DURATION (24 hours) to prevent permanent freeze
     */
    modifier whenNotPaused() {
        // Auto-unpause if deadline passed
        if (isPaused && block.timestamp >= pauseDeadline && pauseDeadline != 0) {
            isPaused = false;
            pauseDeadline = 0;
            emit SystemPausedToggled(false);
        }

        if (isPaused) revert SystemPaused();
        _;
    }

    /**
     * @notice Restricts access to operator or owner
     * @dev Used for automated daily operations (round rolls, pausing, rebalancing)
     */
    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert OnlyOperator();
        _;
    }

    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address _stableWrapper,
        address _owner,
        Vault.VaultParams memory _vaultParams
    ) ERC20(tokenName, tokenSymbol) {
        if (_stableWrapper == address(0)) revert AddressMustBeNonZero();
        if (_owner == address(0)) revert AddressMustBeNonZero();
        if (_vaultParams.cap == 0) revert CapMustBeGreaterThanZero();
        if (_vaultParams.decimals != 6) revert InvalidDecimals();

        stableWrapper = _stableWrapper;
        vaultParams = _vaultParams;
        vaultState.round = 1;

        // Transfer ownership to specified owner (needed for CREATE2 deployment)
        _transferOwnership(_owner);
    }

    // #############################################
    // DEPOSIT & STAKE
    // #############################################

    /**
     * @notice Deposit USDC and stake in current round
     * @param amount Amount of USDC to deposit (6 decimals)
     * @param creditor Address to credit the stake to (usually msg.sender)
     * @dev User must approve SherpaUSD wrapper (not vault) for USDC before calling.
     *      Vault pulls USDC from user via wrapper.depositToVault().
     */
    function depositAndStake(
        uint104 amount,
        address creditor
    ) external nonReentrant whenNotPaused {
        if (!depositsEnabled) revert DepositsDisabled();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        ISherpaUSD(stableWrapper).depositToVault(msg.sender, amount);

        vaultState.totalPending += uint128(amount);

        _stakeInternal(amount, creditor);
    }

    function _stakeInternal(uint104 amount, address creditor) private {
        uint16 currentRound = vaultState.round;
        Vault.VaultParams memory _vaultParams = vaultParams;
        uint256 totalWithStakedAmount = totalStaked + vaultState.totalPending;

        // Prevent dust deposits that could grief other users from exiting
        if (amount < _vaultParams.minimumSupply) revert BelowMinimumDeposit();
        if (totalWithStakedAmount > _vaultParams.cap) revert CapExceeded();
        if (totalWithStakedAmount < _vaultParams.minimumSupply) revert MinimumSupplyNotMet();

        emit Stake(creditor, amount, currentRound);

        Vault.StakeReceipt memory stakeReceipt = stakeReceipts[creditor];

        uint256 unclaimedShares = stakeReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[stakeReceipt.round],
            _vaultParams.decimals
        );

        if (stakeReceipt.round < currentRound && stakeReceipt.amount > 0) {
            stakeReceipt.round = currentRound;
            stakeReceipt.amount = 0;
        }

        uint256 newAmount = uint256(stakeReceipt.amount) + amount;
        ShareMath.assertUint104(newAmount);

        stakeReceipt.amount = uint104(newAmount);
        stakeReceipt.round = currentRound;

        ShareMath.assertUint128(unclaimedShares);
        stakeReceipt.unclaimedShares = uint128(unclaimedShares);

        stakeReceipts[creditor] = stakeReceipt;
    }

    // #############################################
    // CLAIM SHARES
    // #############################################

    /**
     * @notice Claim all available shares from stake receipt to user wallet
     * @dev Transfers shares from vault custody to user. No burning occurs - shares remain in circulation.
     *      User can later unstake these shares to withdraw underlying assets.
     */
    function maxClaimShares() external nonReentrant whenNotPaused {
        _claimShares(0, true);
    }

    /**
     * @notice Claim specific amount of shares from stake receipt to user wallet
     * @param numShares Number of shares to claim from vault custody
     * @dev Transfers shares from vault custody to user. No burning occurs - shares remain in circulation.
     *      User can later unstake these shares to withdraw underlying assets.
     */
    function claimShares(uint256 numShares) external nonReentrant whenNotPaused {
        if (numShares == 0) revert AmountMustBeGreaterThanZero();
        _claimShares(numShares, false);
    }

    function _claimShares(uint256 numShares, bool isMax) internal {
        Vault.StakeReceipt memory stakeReceipt = stakeReceipts[msg.sender];
        uint16 currentRound = vaultState.round;

        if (stakeReceipt.round < MINIMUM_VALID_ROUND) {
            return;
        }

        uint256 unclaimedShares = stakeReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[stakeReceipt.round],
            vaultParams.decimals
        );

        numShares = isMax ? unclaimedShares : numShares;

        if (numShares == 0) {
            return;
        }
        if (numShares > unclaimedShares) revert InsufficientBalance();

        if (stakeReceipt.round < currentRound) {
            stakeReceipt.round = currentRound;
            stakeReceipt.amount = 0;
        }

        ShareMath.assertUint128(unclaimedShares - numShares);
        stakeReceipt.unclaimedShares = uint128(unclaimedShares - numShares);
        stakeReceipts[msg.sender] = stakeReceipt;

        emit ClaimShares(msg.sender, numShares, currentRound);

        _transfer(address(this), msg.sender, numShares);
    }

    // #############################################
    // UNSTAKE & WITHDRAW
    // #############################################

    /**
     * @notice Unstake shares and initiate withdrawal (two-step flow)
     * @param sharesToUnstake Number of shares to burn
     * @param minAmountOut Minimum wrapped tokens to receive (slippage protection)
     * @dev Sends tokens to wrapper and initiates withdrawal on behalf of user
     * @dev User must call completeWithdrawal() on wrapper after epoch increments
     */
    function unstakeAndWithdraw(
        uint256 sharesToUnstake,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused {
        // Send tokens to wrapper (not user)
        uint256 withdrawAmount = _unstake(sharesToUnstake, stableWrapper, minAmountOut);

        // Validate withdrawal amount fits in uint224 before casting
        ShareMath.assertUint224(withdrawAmount);

        // Initiate withdrawal on wrapper for user
        ISherpaUSD(stableWrapper).initiateWithdrawalFromVault(
            msg.sender,
            uint224(withdrawAmount)
        );
    }

    /**
     * @notice Unstake shares and receive wrapped tokens directly (bypass wrapper)
     * @param sharesToUnstake Number of shares to burn
     * @param minAmountOut Minimum wrapped tokens value (slippage protection)
     * @dev Requires allowIndependence to be enabled by owner
     */
    function unstake(
        uint256 sharesToUnstake,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused {
        if (!allowIndependence) revert IndependenceNotAllowed();
        _unstake(sharesToUnstake, msg.sender, minAmountOut);
    }

    /**
     * @notice Internal unstake logic
     * @param sharesToUnstake Number of shares to burn
     * @param recipient Address to receive the wrapped tokens
     * @param minAmountOut Minimum wrapped tokens to receive
     * @return wrappedTokensToWithdraw Amount of wrapped tokens transferred
     */
    function _unstake(
        uint256 sharesToUnstake,
        address recipient,
        uint256 minAmountOut
    ) internal returns (uint256 wrappedTokensToWithdraw) {
        if (sharesToUnstake == 0) revert AmountMustBeGreaterThanZero();
        if (recipient == address(0)) revert AddressMustBeNonZero();

        // Auto-claim any unclaimed shares before unstaking
        {
            Vault.StakeReceipt memory stakeReceipt = stakeReceipts[msg.sender];
            if (stakeReceipt.amount > 0 || stakeReceipt.unclaimedShares > 0) {
                _claimShares(0, true);
            }
        }

        // Validate current round
        uint16 currentRound = vaultState.round;
        if (currentRound < MINIMUM_VALID_ROUND) revert InvalidRound();

        accountingSupply -= sharesToUnstake;
        _burn(msg.sender, sharesToUnstake);

        wrappedTokensToWithdraw = ShareMath.sharesToAsset(
            sharesToUnstake,
            roundPricePerShare[currentRound - 1],
            vaultParams.decimals
        );

        if (wrappedTokensToWithdraw < minAmountOut) revert SlippageExceeded();

        // Check if vault has enough SherpaUSD reserves
        uint256 availableReserves = IERC20(stableWrapper).balanceOf(address(this));
        if (wrappedTokensToWithdraw > availableReserves) {
            revert InsufficientReserves(wrappedTokensToWithdraw, availableReserves);
        }

        // Ensure vault maintains minimum supply (allow full exit to 0)
        if (totalStaked - wrappedTokensToWithdraw < vaultParams.minimumSupply &&
            totalStaked - wrappedTokensToWithdraw > 0) {
            revert MinimumSupplyNotMet();
        }

        totalStaked -= wrappedTokensToWithdraw;

        emit Unstake(msg.sender, wrappedTokensToWithdraw, currentRound);

        IERC20(stableWrapper).safeTransfer(recipient, wrappedTokensToWithdraw);
    }

    /**
     * @notice Instantly unstake PENDING deposits (current round only) with NO FEE
     * @param amount Amount of pending stake to instantly withdraw
     * @dev Only works for deposits in current round that haven't been converted to shares yet
     * @dev This allows users to exit before round rollover without penalty
     * @dev Requires allowIndependence to be enabled by owner
     */
    function instantUnstake(uint104 amount) external nonReentrant whenNotPaused {
        if (!allowIndependence) revert IndependenceNotAllowed();
        _instantUnstake(amount, msg.sender);
    }

    /**
     * @notice Instantly unstake and withdraw in one transaction (current round only)
     * @param amount Amount of pending stake to instantly withdraw
     * @dev Sends tokens to wrapper and initiates withdrawal on behalf of user
     * @dev User must call completeWithdrawal() on wrapper after epoch increments
     */
    function instantUnstakeAndWithdraw(uint104 amount) external nonReentrant whenNotPaused {
        // Cache wrapper address
        address wrapper = stableWrapper;

        // Send tokens to wrapper (not user)
        _instantUnstake(amount, wrapper);

        // Initiate withdrawal on wrapper for user
        ISherpaUSD(wrapper).initiateWithdrawalFromVault(
            msg.sender,
            uint224(amount)
        );
    }

    /**
     * @notice Internal instant unstake logic - ONLY for pending stakes in current round
     * @param amount Amount to instantly unstake
     * @param recipient Address to receive tokens
     * @dev NO FEE - Returns tokens 1:1
     * @dev Only works on pending deposits (stakeReceipt.amount) before they convert to shares
     * @dev Maintains minimum supply requirement
     */
    function _instantUnstake(uint104 amount, address recipient) internal {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        Vault.StakeReceipt storage stakeReceipt = stakeReceipts[msg.sender];
        uint16 currentRound = vaultState.round;

        // Can only instant unstake pending deposits from current round
        if (stakeReceipt.round != currentRound) revert InvalidRound();
        if (amount > stakeReceipt.amount) revert InsufficientBalance();

        // Calculate remaining balance after unstake
        uint256 remainingBalance = totalStaked + vaultState.totalPending - amount;

        // If not fully exiting, must maintain minimum supply
        if (remainingBalance > 0 && remainingBalance < vaultParams.minimumSupply) {
            revert MinimumSupplyNotMet();
        }

        // Update accounting - reduce pending amount
        stakeReceipt.amount -= amount;
        vaultState.totalPending -= uint128(amount);

        emit InstantUnstake(recipient, amount, currentRound);

        // Transfer wrapped tokens 1:1 (no fee, no share conversion)
        IERC20(stableWrapper).safeTransfer(recipient, amount);
    }

    // #############################################
    // ROLL TO NEXT ROUND
    // #############################################

    /**
     * @notice PRIMARY CHAIN: Calculate global price using script-provided totals
     * @param yield Total yield across all chains
     * @param isYieldPositive Whether yield is positive or negative
     * @param globalTotalStaked Total staked across all chains (queried by script)
     * @param globalShareSupply Total share supply across all chains (queried by script)
     * @param globalTotalPending Total pending deposits across all chains (queried by script)
     */
    function rollToNextRound(
        uint256 yield,
        bool isYieldPositive,
        uint256 globalTotalStaked,
        uint256 globalShareSupply,
        uint256 globalTotalPending
    ) external nonReentrant onlyOperator {
        if (!isPrimaryChain) revert OnlyPrimaryChain();

        _rollInternal(yield, isYieldPositive, globalTotalStaked, globalShareSupply, globalTotalPending);
    }

    function _rollInternal(
        uint256 yield,
        bool isYieldPositive,
        uint256 globalTotalStaked,
        uint256 globalShareSupply,
        uint256 globalTotalPending
    ) internal {
        uint256 balance = totalStaked;
        uint256 currentBalance = isYieldPositive ? balance + yield : balance - yield;

        Vault.VaultParams memory _vaultParams = vaultParams;

        // Include pending deposits in minimum supply check for script-based architecture
        uint256 totalBalanceWithPending = currentBalance + vaultState.totalPending;
        if (totalBalanceWithPending < uint256(_vaultParams.minimumSupply)) revert MinimumSupplyNotMet();

        uint256 currentRound = vaultState.round;
        uint256 pending = vaultState.totalPending;

        // Calculate global price using script-provided totals
        // Note: globalBalance includes pending, but pricePerShare() subtracts it out internally
        // Final price = (globalTotalStaked ± yield) / globalShareSupply (pending excluded)
        uint256 globalBalance = isYieldPositive
            ? globalTotalStaked + globalTotalPending + yield
            : globalTotalStaked + globalTotalPending - yield;

        uint256 newPricePerShare = ShareMath.pricePerShare(
            globalShareSupply,
            globalBalance,
            globalTotalPending,
            _vaultParams.decimals
        );

        roundPricePerShare[currentRound] = newPricePerShare;
        vaultState.totalPending = 0;
        vaultState.round = uint16(currentRound + 1);
        lastRollTimestamp = block.timestamp;

        // Mint shares for local pending deposits
        uint256 mintShares = ShareMath.assetToShares(
            pending,
            newPricePerShare,
            _vaultParams.decimals
        );

        accountingSupply += mintShares;
        _mint(address(this), mintShares);

        // Adjust local SherpaUSD balance for yield and emit event
        _adjustBalanceAndEmit(currentBalance, balance, currentRound, newPricePerShare, mintShares, yield, isYieldPositive);

        // Add pending deposits to totalStaked AFTER yield adjustment
        // This accounts for the newly minted shares' underlying value
        totalStaked += pending;
    }

    function _adjustBalanceAndEmit(
        uint256 currentBalance,
        uint256 balance,
        uint256 currentRound,
        uint256 newPricePerShare,
        uint256 mintShares,
        uint256 yield,
        bool isYieldPositive
    ) internal {
        if (currentBalance > balance) {
            uint256 diff = currentBalance - balance;
            ISherpaUSD(stableWrapper).permissionedMint(address(this), diff);
            totalStaked = totalStaked + diff;
            emit RoundRolled(currentRound, newPricePerShare, mintShares, diff, 0, yield, isYieldPositive);
        } else if (currentBalance < balance) {
            uint256 diff = balance - currentBalance;
            ISherpaUSD(stableWrapper).permissionedBurn(address(this), diff);
            totalStaked = totalStaked - diff;
            emit RoundRolled(currentRound, newPricePerShare, mintShares, 0, diff, yield, isYieldPositive);
        } else {
            emit RoundRolled(currentRound, newPricePerShare, mintShares, 0, 0, yield, isYieldPositive);
        }
    }

    /**
     * @notice SECONDARY CHAIN: Apply global price from primary (called by script)
     * @param newRound The round number to advance to
     * @param globalPricePerShare The global price calculated by primary chain
     */
    function applyGlobalPrice(
        uint256 newRound,
        uint256 globalPricePerShare
    ) external nonReentrant onlyOperator {
        if (isPrimaryChain) revert OnlySecondaryChain();

        uint256 currentRound = vaultState.round;

        // Sanity check
        if (newRound != currentRound + 1) revert InvalidRoundNumber();

        // Set the global price for current round
        roundPricePerShare[currentRound] = globalPricePerShare;

        Vault.VaultState memory state = vaultState;
        Vault.VaultParams memory _vaultParams = vaultParams;

        // Validate minimum supply requirement
        uint256 newTotalStaked = totalStaked + state.totalPending;
        if (newTotalStaked > 0 && newTotalStaked < uint256(_vaultParams.minimumSupply)) {
            revert MinimumSupplyNotMet();
        }

        // Mint shares for pending deposits using global price
        uint256 mintShares = ShareMath.assetToShares(
            state.totalPending,
            globalPricePerShare,
            _vaultParams.decimals
        );

        accountingSupply += mintShares;
        _mint(address(this), mintShares);

        // Add pending deposits to totalStaked (they're now committed)
        totalStaked = newTotalStaked;

        // Clear pending and advance round
        vaultState.totalPending = 0;
        vaultState.round = uint16(newRound);
        lastRollTimestamp = block.timestamp;

        emit GlobalPriceApplied(newRound, globalPricePerShare);
        emit RoundRolled(
            currentRound,
            globalPricePerShare,
            mintShares,
            0,
            0,
            0,
            true
        );
    }

    // #############################################
    // ADMIN FUNCTIONS
    // #############################################

    function setCap(uint104 newCap) external onlyOwner {
        if (newCap == 0) revert CapMustBeGreaterThanZero();
        emit CapSet(vaultParams.cap, newCap);
        vaultParams.cap = newCap;
    }

    function setPrimaryChain(uint64 chainSelector, bool _isPrimary) external onlyOwner {
        primaryChainSelector = chainSelector;
        isPrimaryChain = _isPrimary;
        emit PrimaryChainSet(chainSelector, _isPrimary);
    }

    function setDepositsEnabled(bool enabled) external onlyOwner {
        emit DepositsToggled(depositsEnabled, enabled);
        depositsEnabled = enabled;
    }

    function setAllowIndependence(bool _allowIndependence) external onlyOwner {
        bool oldValue = allowIndependence;
        allowIndependence = _allowIndependence;
        emit AllowIndependenceSet(oldValue, _allowIndependence);
    }

    /**
     * @notice Toggle system pause state
     * @param _isPaused True to pause all user interactions, false to unpause
     * @dev Used during round rolls to prevent state changes that would affect price calculations
     * @dev Blocks: depositAndStake, unstake, unstakeAndWithdraw, instantUnstake, instantUnstakeAndWithdraw, claimShares, maxClaimShares
     * @dev Does NOT block: owner functions, view functions, CCIP functions
     * @dev Auto-unpauses after 24 hours to prevent permanent freeze if owner/operator key is lost
     */
    function setSystemPaused(bool _isPaused) external onlyOperator {
        isPaused = _isPaused;

        if (_isPaused) {
            // Set auto-unpause deadline
            pauseDeadline = block.timestamp + MAX_PAUSE_DURATION;
        } else {
            pauseDeadline = 0; // Clear deadline
        }

        emit SystemPausedToggled(_isPaused);
    }

    /**
     * @notice Emergency unpause callable by anyone after deadline
     * @dev Allows anyone to rescue the system if owner key is lost and deadline has passed
     * @dev Reverts if system is not paused or deadline has not been reached
     */
    function emergencyUnpause() external {
        if (!isPaused) revert NotPaused();

        // Cache deadline
        uint256 deadline = pauseDeadline;
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (deadline == 0) revert NoDeadlineSet();

        isPaused = false;
        pauseDeadline = 0;
        emit SystemPausedToggled(false);
    }

    /**
     * @notice Process withdrawals on the SherpaUSD wrapper (increments epoch)
     * @dev This should be called after each round roll to keep epochs synchronized
     */
    function processWrapperWithdrawals() external onlyOperator {
        ISherpaUSD(stableWrapper).processWithdrawals();
    }

    /**
     * @notice Update the stable wrapper contract address (one-time only)
     * @param newWrapper Address of the new SherpaUSD wrapper contract
     * @dev SECURITY: Locks after first call to prevent wrapper-swap attack where owner swaps wrapper then rescues old tokens
     * @dev During deployment: vault initialized with temporary wrapper, then this is called once to set real wrapper
     */
    function setStableWrapper(address newWrapper) external onlyOwner {
        if (stableWrapperLocked) revert StableWrapperAlreadyLocked();
        if (newWrapper == address(0)) revert AddressMustBeNonZero();
        emit StableWrapperUpdated(stableWrapper, newWrapper);
        stableWrapper = newWrapper;
        stableWrapperLocked = true; // Lock permanently after first call
    }

    /**
     * @notice Rescue tokens accidentally sent to the vault
     * @param token Address of the token to rescue
     * @param amount Amount of tokens to rescue
     * @dev SECURITY: Cannot rescue stableWrapper or vault share tokens (user funds are protected)
     * @dev Can rescue other ERC20 tokens sent by mistake
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert AddressMustBeNonZero();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // CRITICAL: Cannot rescue the wrapper token or vault's own share token (user funds)
        // This protects deposited SherpaUSD and unclaimed shares from being withdrawn by owner
        if (token == stableWrapper || token == address(this)) revert CannotRescueWrapperToken();

        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokensRescued(token, amount);
    }

    /**
     * @notice Manual rebalancing of SherpaUSD between chains (called by operator after ownerMint/Burn)
     * @param adjustment Positive to increase totalStaked, negative to decrease
     * @dev Operator must call SherpaUSD.ownerMint/ownerBurn separately, then call this to sync accounting
     * @dev Used for cross-chain liquidity management
     * @dev Validates adjustment matches approved amount from ownerMint/ownerBurn
     */
    function adjustTotalStaked(int256 adjustment) external onlyOperator {
        if (adjustment == 0) revert AmountMustBeGreaterThanZero();

        // Get approved amount from SherpaUSD
        uint256 approved = ISherpaUSD(stableWrapper).approvedTotalStakedAdjustment(address(this));
        uint256 adjustmentAbs = uint256(adjustment > 0 ? adjustment : -adjustment);

        // Validate exact match
        if (approved != adjustmentAbs) revert AdjustmentNotApproved();

        // Consume approval
        ISherpaUSD(stableWrapper).consumeTotalStakedApproval();

        // Cache old value for event
        uint256 oldValue = totalStaked;

        if (adjustment > 0) {
            // Increase totalStaked (after ownerMint was called)
            totalStaked += uint256(adjustment);
        } else {
            // Decrease totalStaked (after ownerBurn was called)
            totalStaked -= uint256(-adjustment);
        }

        emit TotalStakedAdjusted(msg.sender, oldValue, adjustment, totalStaked);
    }

    /**
     * @notice Adjust accounting supply after manual SherpaUSD rebalancing
     * @param adjustment Positive to increase, negative to decrease
     * @dev Called by operator after rebalancing SherpaUSD between chains
     * @dev Maintains invariant: accountingSupply reflects logical shares per chain
     * @dev Validates adjustment matches expected share calculation from approved amount
     */
    function adjustAccountingSupply(int256 adjustment) external onlyOperator {
        if (adjustment == 0) revert AmountMustBeGreaterThanZero();

        // Get approved SherpaUSD amount
        uint256 approvedAmount = ISherpaUSD(stableWrapper).approvedAccountingAdjustment(address(this));

        // Calculate expected share adjustment from the approved amount using N-1 price
        uint256 expectedShares = ShareMath.assetToShares(
            approvedAmount,
            roundPricePerShare[vaultState.round - 1],
            vaultParams.decimals
        );

        uint256 adjustmentAbs = uint256(adjustment > 0 ? adjustment : -adjustment);
        if (adjustmentAbs != expectedShares) revert IncorrectCalculation();

        // Consume approval
        ISherpaUSD(stableWrapper).consumeAccountingApproval();

        // Cache old value for event
        uint256 oldValue = accountingSupply;

        if (adjustment > 0) {
            accountingSupply += uint256(adjustment);
        } else {
            accountingSupply -= uint256(-adjustment);
        }

        emit AccountingSupplyAdjusted(msg.sender, oldValue, adjustment, accountingSupply);
    }

    /**
     * @notice Set or change the operator address (multi-sig only)
     * @param newOperator Address of the new operator wallet for automated operations
     * @dev STRATEGIC FUNCTION: Only callable by owner (multi-sig)
     * @dev Operator can call: rollToNextRound, applyGlobalPrice, setSystemPaused, adjustTotalStaked, adjustAccountingSupply, processWrapperWithdrawals
     * @dev Use this to appoint an operator account to run automated operations
     */
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert AddressMustBeNonZero();
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorUpdated(oldOperator, newOperator);
    }

    /**
     * @notice Renouncing ownership is disabled for SherpaVault
     * @dev SherpaVault requires an active owner for critical configuration and emergency controls
     * @dev Ownership is transferred to a multisig for decentralization
     */
    function renounceOwnership() public override onlyOwner {
        revert CannotRenounceOwnership();
    }

    // #############################################
    // VIEW FUNCTIONS
    // #############################################

    function cap() public view returns (uint256) {
        return vaultParams.cap;
    }

    function round() public view returns (uint256) {
        return vaultState.round;
    }

    function totalPending() public view returns (uint256) {
        return vaultState.totalPending;
    }

    function decimals() public view override returns (uint8) {
        return vaultParams.decimals;
    }

    /**
     * @notice Get available SherpaUSD reserves in this vault
     * @return Amount of SherpaUSD held by vault
     */
    function getReserveAmount() external view returns (uint256) {
        return IERC20(stableWrapper).balanceOf(address(this));
    }

    /**
     * @notice Get reserve level as percentage of cap
     * @return Percentage (0-100) of reserves available
     */
    function getReserveLevel() external view returns (uint256) {
        uint256 reserves = IERC20(stableWrapper).balanceOf(address(this));
        uint256 capacity = vaultParams.cap;
        if (capacity == 0) return 0;
        return (reserves * 100) / capacity;
    }

    /**
     * @notice Get total vault balance (asset value) for an account
     * @param account Address to check
     * @return Total asset value (pending + shares value in wrapped tokens)
     * @dev Combines pending deposits with share value at current price
     */
    function accountVaultBalance(address account) external view returns (uint256) {
        Vault.StakeReceipt memory stakeReceipt = stakeReceipts[account];
        uint16 currentRound = vaultState.round;

        // Return 0 if vault hasn't rolled yet (Round 1 has no price)
        if (currentRound < MINIMUM_VALID_ROUND) {
            return 0;
        }

        // Use previous round's price (current round price isn't set until round rolls)
        uint256 pricePerShare = roundPricePerShare[currentRound - 1];

        // Get pending amount (deposits not yet converted to shares)
        uint256 pendingAmount;
        if (stakeReceipt.round == currentRound) {
            pendingAmount = stakeReceipt.amount;
        }

        // Get unclaimed shares value
        uint256 unclaimedSharesValue;
        if (stakeReceipt.round < currentRound && stakeReceipt.unclaimedShares > 0) {
            unclaimedSharesValue = ShareMath.sharesToAsset(
                stakeReceipt.unclaimedShares,
                pricePerShare,
                vaultParams.decimals
            );
        }

        // Get claimed shares value (shares in wallet)
        uint256 claimedSharesValue;
        uint256 walletShares = balanceOf(account);
        if (walletShares > 0) {
            claimedSharesValue = ShareMath.sharesToAsset(
                walletShares,
                pricePerShare,
                vaultParams.decimals
            );
        }

        return pendingAmount + unclaimedSharesValue + claimedSharesValue;
    }

    /**
     * @notice Get total shares for an account (claimed + unclaimed)
     * @param account Address to check
     * @return Total shares (in wallet + in vault custody)
     */
    function shares(address account) external view returns (uint256) {
        Vault.StakeReceipt memory stakeReceipt = stakeReceipts[account];
        uint16 currentRound = vaultState.round;

        // Calculate unclaimed shares from receipt
        uint256 unclaimedShares = stakeReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[stakeReceipt.round],
            vaultParams.decimals
        );

        // Add wallet shares
        return unclaimedShares + balanceOf(account);
    }

    /**
     * @notice Get remaining time until auto-unpause (in seconds)
     * @return Seconds remaining until auto-unpause (0 if not paused or already expired)
     */
    function pauseTimeRemaining() external view returns (uint256) {
        // Cache deadline
        uint256 deadline = pauseDeadline;

        if (!isPaused || deadline == 0) {
            return 0;
        }

        if (block.timestamp >= deadline) {
            return 0;
        }

        return deadline - block.timestamp;
    }

    /**
     * @notice Get shares held in user's wallet (already claimed)
     * @param account Address to check
     * @return Shares in wallet
     */
    function shareBalancesHeldByAccount(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @notice Get shares held by vault for user (pending redemption)
     * @param account Address to check
     * @return Shares in vault custody
     */
    function shareBalancesHeldByVault(address account) external view returns (uint256) {
        Vault.StakeReceipt memory stakeReceipt = stakeReceipts[account];
        uint16 currentRound = vaultState.round;

        return stakeReceipt.getSharesFromReceipt(
            currentRound,
            roundPricePerShare[stakeReceipt.round],
            vaultParams.decimals
        );
    }

    // #############################################
    // CCIP BURN/MINT FUNCTIONS (IBurnMintERC20)
    // #############################################

    /**
     * @notice Add a CCIP pool address that can mint/burn
     * @param pool Address of the CCIP token pool
     */
    function addCCIPPool(address pool) external onlyOwner {
        if (pool == address(0)) revert AddressMustBeNonZero();
        ccipPools[pool] = true;
        emit CCIPPoolAdded(pool);
    }

    /**
     * @notice Remove a CCIP pool address
     * @param pool Address of the CCIP token pool
     */
    function removeCCIPPool(address pool) external onlyOwner {
        ccipPools[pool] = false;
        emit CCIPPoolRemoved(pool);
    }

    /**
     * @notice Mint tokens - callable only by authorized CCIP pools
     * @param account Address to mint to
     * @param amount Amount to mint
     * @dev Required by IBurnMintERC20 for CCIP burn/mint pools
     */
    function mint(address account, uint256 amount) external override {
        if (!ccipPools[msg.sender]) revert OnlyCCIPPool();
        _mint(account, amount);
    }

    /**
     * @notice Burn tokens from sender - callable by CCIP pools
     * @param amount Amount to burn
     * @dev Required by IBurnMintERC20 for CCIP burn/mint pools
     */
    function burn(uint256 amount) external override {
        if (!ccipPools[msg.sender]) revert OnlyCCIPPool();
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burn tokens from address - callable by CCIP pools
     * @param account Address to burn from
     * @param amount Amount to burn
     * @dev Required by IBurnMintERC20 for CCIP burn/mint pools
     */
    function burn(address account, uint256 amount) external override {
        if (!ccipPools[msg.sender]) revert OnlyCCIPPool();
        _burn(account, amount);
    }

    /**
     * @notice Burn tokens using allowance - callable by CCIP pools
     * @param account Address to burn from
     * @param amount Amount to burn
     * @dev Required by IBurnMintERC20 for CCIP burn/mint pools
     */
    function burnFrom(address account, uint256 amount) external override {
        if (!ccipPools[msg.sender]) revert OnlyCCIPPool();
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    error SlippageExceeded();
}
