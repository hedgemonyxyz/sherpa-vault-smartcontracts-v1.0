// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SherpaVault} from "../contracts/SherpaVault.sol";
import {SherpaUSD} from "../contracts/SherpaUSD.sol";
import {Vault} from "../contracts/lib/Vault.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";

/**
 * @title SherpaVault Test Suite
 * @notice Comprehensive tests for SherpaVault contract
 */
contract SherpaVaultTest is Test {
    SherpaVault public vault;
    SherpaUSD public wrapper;
    MockUSDC public usdc;

    address public owner;
    address public operator;
    address public user1;
    address public user2;
    address public ccipRouter;
    address public ccipPool;

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
    uint256 constant VAULT_CAP = 10_000_000e6; // 10M USDC cap
    uint256 constant MIN_SUPPLY = 1e6; // 1 USDC minimum (matches deployed contracts)

    event Stake(address indexed account, uint256 amount, uint256 indexed round);
    event Unstake(address indexed account, uint256 amount, uint256 indexed round);
    event ClaimShares(address indexed account, uint256 share, uint256 indexed round);
    event InstantUnstake(address indexed account, uint256 amount, uint256 indexed round);
    event RoundRolled(
        uint256 indexed round,
        uint256 pricePerShare,
        uint256 sharesMinted,
        uint256 wrappedTokensMinted,
        uint256 wrappedTokensBurned,
        uint256 yield,
        bool isYieldPositive
    );
    event SystemPausedToggled(bool isPaused);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    function setUp() public {
        // Setup actors
        owner = address(this);
        operator = address(0x100);
        user1 = address(0x1);
        user2 = address(0x2);
        ccipRouter = address(0x200);
        ccipPool = address(0x300);

        // Deploy USDC mock
        usdc = new MockUSDC();

        // Deploy SherpaUSD wrapper
        wrapper = new SherpaUSD(address(usdc), address(0xdead)); // Temporary keeper

        // Deploy SherpaVault
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: uint56(MIN_SUPPLY),
            cap: uint104(VAULT_CAP)
        });

        vault = new SherpaVault(
            "Sherpa Vault Token",
            "shVAULT",
            address(wrapper),
            address(this),
            params
        );

        // Set vault as keeper for wrapper
        wrapper.setKeeper(address(vault));

        // Set operator for both vault and wrapper
        vault.setOperator(operator);
        wrapper.setOperator(operator);

        // Fund users
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        // Approve vault to spend USDC (via wrapper)
        vm.prank(user1);
        usdc.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(wrapper), type(uint256).max);
    }

    // #############################################
    // CONSTRUCTOR & INITIALIZATION TESTS
    // #############################################

    function test_constructor() public {
        assertEq(vault.name(), "Sherpa Vault Token");
        assertEq(vault.symbol(), "shVAULT");
        assertEq(vault.decimals(), 6);
        assertEq(vault.stableWrapper(), address(wrapper));
        assertEq(vault.round(), 1);
        assertEq(vault.cap(), VAULT_CAP);
        assertEq(vault.operator(), operator);
        assertTrue(vault.depositsEnabled());
        assertFalse(vault.allowIndependence());
        assertFalse(vault.isPaused());
    }

    function test_constructorRevertsWithZeroWrapper() public {
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: uint56(MIN_SUPPLY),
            cap: uint104(VAULT_CAP)
        });

        vm.expectRevert(SherpaVault.AddressMustBeNonZero.selector);
        new SherpaVault(
            "Test",
            "TEST",
            address(0),
            address(this),
            params
        );
    }

    function test_constructorRevertsWithZeroCap() public {
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: uint56(MIN_SUPPLY),
            cap: 0
        });

        vm.expectRevert(SherpaVault.CapMustBeGreaterThanZero.selector);
        new SherpaVault(
            "Test",
            "TEST",
            address(wrapper),
            address(this),
            params
        );
    }

    // #############################################
    // DEPOSIT & STAKE TESTS
    // #############################################

    function test_depositAndStake() public {
        uint104 amount = 1000e6; // 1000 USDC

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Stake(user1, amount, 1);
        vault.depositAndStake(amount, user1);

        // Check state
        assertEq(vault.totalPending(), amount);
        assertEq(wrapper.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(address(wrapper)), amount);

        // Check stake receipt
        (uint16 round, uint104 stakedAmount, uint128 unclaimedShares) = vault.stakeReceipts(user1);
        assertEq(round, 1);
        assertEq(stakedAmount, amount);
        assertEq(unclaimedShares, 0);
    }

    function test_depositAndStakeMultipleUsers() public {
        uint104 amount1 = 1000e6;
        uint104 amount2 = 2000e6;

        vm.prank(user1);
        vault.depositAndStake(amount1, user1);

        vm.prank(user2);
        vault.depositAndStake(amount2, user2);

        assertEq(vault.totalPending(), amount1 + amount2);
        assertEq(wrapper.balanceOf(address(vault)), amount1 + amount2);
    }

    function test_depositAndStakeRevertsWhenPaused() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.SystemPaused.selector);
        vault.depositAndStake(1000e6, user1);
    }

    function test_depositAndStakeRevertsWhenDepositsDisabled() public {
        vault.setDepositsEnabled(false);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.DepositsDisabled.selector);
        vault.depositAndStake(1000e6, user1);
    }

    function test_depositAndStakeRevertsWithZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.AmountMustBeGreaterThanZero.selector);
        vault.depositAndStake(0, user1);
    }

    function test_depositAndStakeRevertsWhenCapExceeded() public {
        // Mint enough USDC to test cap
        uint104 capAmount = uint104(VAULT_CAP);
        usdc.mint(user1, capAmount);
        vm.prank(user1);
        usdc.approve(address(wrapper), capAmount);

        // Deposit up to cap
        vm.prank(user1);
        vault.depositAndStake(capAmount, user1);

        // Try to deposit more
        usdc.mint(user1, 1000e6);
        vm.prank(user1);
        usdc.approve(address(wrapper), 1000e6);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.CapExceeded.selector);
        vault.depositAndStake(1000e6, user1);
    }

    function test_depositAndStakeRevertsWhenBelowMinimum() public {
        uint104 tooSmall = uint104(MIN_SUPPLY - 1);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.BelowMinimumDeposit.selector);
        vault.depositAndStake(tooSmall, user1);
    }

    function test_depositAndStakeRevertsIndividualDepositBelowMinimum() public {
        // First user deposits enough to meet minimum supply
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY * 10), user1);

        // Second user tries to deposit below minimum (dust amount)
        uint104 dustAmount = uint104(MIN_SUPPLY - 1);

        vm.prank(user2);
        vm.expectRevert(SherpaVault.BelowMinimumDeposit.selector);
        vault.depositAndStake(dustAmount, user2);
    }

    function test_depositAndStakeAccumulatesInReceipt() public {
        uint104 amount1 = 1000e6;
        uint104 amount2 = 500e6;

        vm.prank(user1);
        vault.depositAndStake(amount1, user1);

        vm.prank(user1);
        vault.depositAndStake(amount2, user1);

        (uint16 round, uint104 stakedAmount,) = vault.stakeReceipts(user1);
        assertEq(round, 1);
        assertEq(stakedAmount, amount1 + amount2);
    }

    // #############################################
    // CLAIM SHARES TESTS
    // #############################################

    function test_claimAfterRoundRoll() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, depositAmount);

        // Now claim shares
        vm.prank(user1);
        vault.maxClaimShares();

        // Check that shares were minted to user
        uint256 shares = vault.balanceOf(user1);
        assertGt(shares, 0, "User should have received shares");
    }

    function test_claimPartialShares() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, depositAmount);

        // Get total unclaimed shares
        uint256 unclaimedShares = vault.shareBalancesHeldByVault(user1);
        uint256 partialAmount = unclaimedShares / 2;

        vm.prank(user1);
        vault.claimShares(partialAmount);

        // Check balances
        assertEq(vault.balanceOf(user1), partialAmount);
        assertEq(vault.shareBalancesHeldByVault(user1), unclaimedShares - partialAmount);
    }

    function test_claimRevertsWithZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.AmountMustBeGreaterThanZero.selector);
        vault.claimShares(0);
    }

    function test_claimRevertsWhenPaused() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.SystemPaused.selector);
        vault.maxClaimShares();
    }

    function test_claimRevertsWhenInsufficientShares() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, 1000e6);

        uint256 unclaimedShares = vault.shareBalancesHeldByVault(user1);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.InsufficientBalance.selector);
        vault.claimShares(unclaimedShares + 1);
    }

    // #############################################
    // UNSTAKE & WITHDRAW TESTS
    // #############################################

    function test_unstakeAndWithdraw() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, depositAmount);

        vm.prank(user1);
        vault.maxClaimShares();

        uint256 sharesToUnstake = vault.balanceOf(user1);

        // Unstake
        vm.prank(user1);
        vault.unstakeAndWithdraw(sharesToUnstake, 0);

        // Check withdrawal receipt was created in wrapper
        (uint224 amount, uint32 epoch) = wrapper.withdrawalReceipts(user1);
        assertGt(amount, 0, "Withdrawal receipt should be created");
    }

    function test_unstakeRevertsWhenNotAllowed() public {
        // allowIndependence is false by default
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

                vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        vm.prank(user1);
        vault.maxClaimShares();

        uint256 shares = vault.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.IndependenceNotAllowed.selector);
        vault.unstake(shares, 0);
    }

    function test_unstakeWithIndependenceEnabled() public {
        vault.setAllowIndependence(true);

        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, 1000e6);

        vm.prank(user1);
        vault.maxClaimShares();

        uint256 shares = vault.balanceOf(user1);
        uint256 wrapperBalanceBefore = wrapper.balanceOf(user1);

        vm.prank(user1);
        vault.unstake(shares, 0);

        // User should receive wrapper tokens directly
        assertGt(wrapper.balanceOf(user1), wrapperBalanceBefore);
    }

    function test_unstakeRevertsWhenPaused() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.SystemPaused.selector);
        vault.unstakeAndWithdraw(1000e18, 0);
    }

    function test_unstakeRevertsWithZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.AmountMustBeGreaterThanZero.selector);
        vault.unstakeAndWithdraw(0, 0);
    }

    function test_unstakeAutoClaims() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2 (don't manually claim)
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, 1000e6);

        // Unstake without claiming first (should auto-claim)
        uint256 unclaimedShares = vault.shareBalancesHeldByVault(user1);

        vm.prank(user1);
        vault.unstakeAndWithdraw(unclaimedShares, 0);

        // Should succeed and create withdrawal receipt
        (uint224 amount,) = wrapper.withdrawalReceipts(user1);
        assertGt(amount, 0);
    }

    // #############################################
    // INSTANT UNSTAKE TESTS
    // #############################################

    function test_instantUnstakeCurrentRound() public {
        vault.setAllowIndependence(true);

        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        uint256 wrapperBalanceBefore = wrapper.balanceOf(user1);

        // Instant unstake before round rolls
        vm.prank(user1);
        vault.instantUnstake(uint104(depositAmount));

        // User gets tokens back 1:1
        assertEq(wrapper.balanceOf(user1), wrapperBalanceBefore + depositAmount);
        assertEq(vault.totalPending(), 0);
    }

    function test_instantUnstakePartial() public {
        vault.setAllowIndependence(true);

        uint104 depositAmount = 1000e6;
        uint104 unstakeAmount = 400e6;

        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        vm.prank(user1);
        vault.instantUnstake(unstakeAmount);

        (,uint104 remainingStake,) = vault.stakeReceipts(user1);
        assertEq(remainingStake, depositAmount - unstakeAmount);
        assertEq(vault.totalPending(), depositAmount - unstakeAmount);
    }

    function test_instantUnstakeAndWithdraw() public {
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

        // Instant unstake and withdraw (creates withdrawal receipt)
        vm.prank(user1);
        vault.instantUnstakeAndWithdraw(uint104(depositAmount));

        // Check withdrawal receipt
        (uint224 amount,) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, depositAmount);
    }

    function test_instantUnstakeRevertsWhenNotAllowed() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.IndependenceNotAllowed.selector);
        vault.instantUnstake(500e6);
    }

    function test_instantUnstakeRevertsWrongRound() public {
        vault.setAllowIndependence(true);

        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Roll to next round
                vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        // Try instant unstake (should fail - not current round anymore)
        vm.prank(user1);
        vm.expectRevert(SherpaVault.InvalidRound.selector);
        vault.instantUnstake(500e6);
    }

    function test_instantUnstakeRevertsInsufficientBalance() public {
        vault.setAllowIndependence(true);

        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        vm.prank(user1);
        vm.expectRevert(SherpaVault.InsufficientBalance.selector);
        vault.instantUnstake(1001e6);
    }

    // #############################################
    // ROUND ROLL TESTS (PRIMARY CHAIN)
    // #############################################

    function test_rollToNextRound() public {
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

                vault.setPrimaryChain(1, true);

        uint256 yield = 100e6; // 10% yield

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit RoundRolled(1, 1e6, 1000e6, 100e6, 0, yield, true);
        vault.rollToNextRound(yield, true, 0, 0, depositAmount);

        // Check state after roll
        assertEq(vault.round(), 2);
        assertEq(vault.totalPending(), 0);
        assertGt(vault.totalStaked(), 0);
        assertEq(vault.roundPricePerShare(1), 1e6); // Initial price 1:1
    }

    function test_rollToNextRoundWithNegativeYield() public {
        // First roll to establish baseline
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

                vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        // Add more deposits
        vm.prank(user2);
        vault.depositAndStake(1000e6, user2);

        // Roll with loss
        uint256 loss = 50e6; // 5% loss
        vm.prank(operator);
        vault.rollToNextRound(loss, false, 1000e6, 1000e6, 1000e6);

        // Price should reflect loss
        uint256 newPrice = vault.roundPricePerShare(2);
        assertLt(newPrice, 1e6); // Price should be less than initial 1:1
    }

    function test_rollToNextRoundRevertsNotPrimaryChain() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Don't set as primary chain
        vm.prank(operator);
        vm.expectRevert(SherpaVault.OnlyPrimaryChain.selector);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);
    }

    function test_rollToNextRoundRevertsNotOperator() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

                vault.setPrimaryChain(1, true);

        vm.prank(user1); // Not operator
        vm.expectRevert(SherpaVault.OnlyOperator.selector);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);
    }

    function test_rollToNextRoundMintsShares() public {
        uint104 depositAmount = 1000e6;
        vm.prank(user1);
        vault.depositAndStake(depositAmount, user1);

                vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, depositAmount);

        // Shares should be minted to vault (user must claim)
        uint256 vaultShares = vault.balanceOf(address(vault));
        assertGt(vaultShares, 0, "Shares should be minted to vault");
    }

    // #############################################
    // SECONDARY CHAIN TESTS
    // #############################################

    function test_applyGlobalPrice() public {
        // Set as secondary chain
        vault.setPrimaryChain(1, false);

        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        uint256 globalPrice = 1e6;
        uint256 newRound = 2;

        vm.prank(operator);
        vault.applyGlobalPrice(newRound, globalPrice);

        assertEq(vault.round(), newRound);
        assertEq(vault.roundPricePerShare(1), globalPrice);
    }

    function test_applyGlobalPriceRevertsOnPrimaryChain() public {
        vault.setPrimaryChain(1, true);

        vm.prank(operator);
        vm.expectRevert(SherpaVault.OnlySecondaryChain.selector);
        vault.applyGlobalPrice(2, 1e6);
    }

    // #############################################
    // PAUSE TESTS
    // #############################################

    function test_setSystemPaused() public {
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit SystemPausedToggled(true);
        vault.setSystemPaused(true);

        assertTrue(vault.isPaused());
        assertGt(vault.pauseDeadline(), 0);
    }

    function test_setSystemUnpaused() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        vm.prank(operator);
        vault.setSystemPaused(false);

        assertFalse(vault.isPaused());
        assertEq(vault.pauseDeadline(), 0);
    }

    function test_pauseAutoUnpauseAfter24Hours() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        uint256 deadline = vault.pauseDeadline();

        // Fast forward 24 hours + 1 second
        vm.warp(deadline + 1);

        // Try to deposit (should auto-unpause)
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1); // Should not revert

        assertFalse(vault.isPaused());
    }

    function test_emergencyUnpause() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        uint256 deadline = vault.pauseDeadline();
        vm.warp(deadline + 1);

        // Anyone can call emergency unpause after deadline
        vm.prank(user1);
        vault.emergencyUnpause();

        assertFalse(vault.isPaused());
    }

    function test_emergencyUnpauseRevertsBeforeDeadline() public {
        vm.prank(operator);
        vault.setSystemPaused(true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("DeadlineNotReached()"));
        vault.emergencyUnpause();
    }

    // #############################################
    // ADMIN FUNCTION TESTS
    // #############################################

    function test_setCap() public {
        uint104 newCap = 20_000_000e6;
        vault.setCap(newCap);
        assertEq(vault.cap(), newCap);
    }

    function test_setCapRevertsWithZero() public {
        vm.expectRevert(SherpaVault.CapMustBeGreaterThanZero.selector);
        vault.setCap(0);
    }

    function test_setCapRevertsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setCap(1000e6);
    }

    function test_setPrimaryChain() public {
        uint64 chainSelector = 12345;
        vault.setPrimaryChain(chainSelector, true);

        assertEq(vault.primaryChainSelector(), chainSelector);
        assertTrue(vault.isPrimaryChain());
    }

    function test_setDepositsEnabled() public {
        vault.setDepositsEnabled(false);
        assertFalse(vault.depositsEnabled());

        vault.setDepositsEnabled(true);
        assertTrue(vault.depositsEnabled());
    }

    function test_setAllowIndependence() public {
        vault.setAllowIndependence(true);
        assertTrue(vault.allowIndependence());

        vault.setAllowIndependence(false);
        assertFalse(vault.allowIndependence());
    }

    function test_setOperator() public {
        address newOperator = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit OperatorUpdated(operator, newOperator);
        vault.setOperator(newOperator);

        assertEq(vault.operator(), newOperator);
    }

    function test_setOperatorRevertsWithZeroAddress() public {
        vm.expectRevert(SherpaVault.AddressMustBeNonZero.selector);
        vault.setOperator(address(0));
    }

    function test_setOperatorRevertsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setOperator(address(0x999));
    }

    function test_setStableWrapperLocksAfterFirstCall() public {
        // Deploy a new wrapper
        SherpaUSD newWrapper = new SherpaUSD(address(usdc), address(vault));

        // First call should succeed
        vault.setStableWrapper(address(newWrapper));
        assertEq(vault.stableWrapper(), address(newWrapper));

        // Second call should revert with StableWrapperAlreadyLocked
        SherpaUSD anotherWrapper = new SherpaUSD(address(usdc), address(vault));
        vm.expectRevert(SherpaVault.StableWrapperAlreadyLocked.selector);
        vault.setStableWrapper(address(anotherWrapper));
    }

    function test_setStableWrapperLocksEvenWithSameAddress() public {
        // Deploy a new wrapper
        SherpaUSD newWrapper = new SherpaUSD(address(usdc), address(vault));

        // First call should succeed
        vault.setStableWrapper(address(newWrapper));
        assertEq(vault.stableWrapper(), address(newWrapper));

        // Second call should revert even with same address
        vm.expectRevert(SherpaVault.StableWrapperAlreadyLocked.selector);
        vault.setStableWrapper(address(newWrapper));
    }

    function test_setStableWrapperRevertsWithZeroAddress() public {
        vm.expectRevert(SherpaVault.AddressMustBeNonZero.selector);
        vault.setStableWrapper(address(0));
    }

    function test_setStableWrapperRevertsNotOwner() public {
        SherpaUSD newWrapper = new SherpaUSD(address(usdc), address(vault));

        vm.prank(user1);
        vm.expectRevert();
        vault.setStableWrapper(address(newWrapper));
    }

    // #############################################
    // CCIP POOL TESTS
    // #############################################

    function test_addCCIPPool() public {
        vault.addCCIPPool(ccipPool);
        assertTrue(vault.ccipPools(ccipPool));
    }

    function test_addCCIPPoolRevertsWithZeroAddress() public {
        vm.expectRevert(SherpaVault.AddressMustBeNonZero.selector);
        vault.addCCIPPool(address(0));
    }

    function test_removeCCIPPool() public {
        vault.addCCIPPool(ccipPool);
        vault.removeCCIPPool(ccipPool);
        assertFalse(vault.ccipPools(ccipPool));
    }

    function test_ccipMint() public {
        vault.addCCIPPool(ccipPool);

        vm.prank(ccipPool);
        vault.mint(user1, 1000e18);

        assertEq(vault.balanceOf(user1), 1000e18);
    }

    function test_ccipMintRevertsNotPool() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.OnlyCCIPPool.selector);
        vault.mint(user1, 1000e18);
    }

    function test_ccipBurn() public {
        vault.addCCIPPool(ccipPool);

        // First mint some tokens
        vm.prank(ccipPool);
        vault.mint(user1, 1000e18);

        // Then burn
        vm.prank(ccipPool);
        vault.burn(user1, 500e18);

        assertEq(vault.balanceOf(user1), 500e18);
    }

    function test_ccipBurnRevertsNotPool() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.OnlyCCIPPool.selector);
        vault.burn(user1, 100e18);
    }

    // #############################################
    // VIEW FUNCTION TESTS
    // #############################################

    function test_accountVaultBalance() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // Deposit in round 2
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // Roll to round 3
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, 1000e6);

        // Claim shares to convert deposits to wallet shares
        vm.prank(user1);
        vault.maxClaimShares();

        // Check balance (should be approximately deposit amount)
        uint256 balance = vault.accountVaultBalance(user1);
        assertApproxEqAbs(balance, 1001e6, 100); // 1000e6 + 1e6 MIN_SUPPLY
    }

    function test_shares() public {
        // Deposit and roll
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

                vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        // Check shares (unclaimed)
        uint256 totalShares = vault.shares(user1);
        assertGt(totalShares, 0);

        // Claim half
        vm.prank(user1);
        vault.claimShares(totalShares / 2);

        // Total shares should remain same (just split between claimed/unclaimed)
        assertEq(vault.shares(user1), totalShares);
    }

    function test_getReserveAmount() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        assertEq(vault.getReserveAmount(), 1000e6);
    }

    function test_getReserveLevel() public {
        uint256 depositAmount = VAULT_CAP / 2; // 50% of cap

        // Mint enough USDC for the deposit
        usdc.mint(user1, depositAmount);
        vm.prank(user1);
        usdc.approve(address(wrapper), depositAmount);

        vm.prank(user1);
        vault.depositAndStake(uint104(depositAmount), user1);

        assertEq(vault.getReserveLevel(), 50);
    }

    // #############################################
    // REBALANCING TESTS
    // #############################################

    function test_adjustTotalStaked() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        uint256 totalStakedBefore = vault.totalStaked();

        // Operator mints to create approval for adjustment
        vm.prank(operator);
        wrapper.ownerMint(address(vault), 100e6);

        // Operator adjusts totalStaked
        vm.prank(operator);
        vault.adjustTotalStaked(int256(100e6));

        assertEq(vault.totalStaked(), totalStakedBefore + 100e6);
    }

    function test_adjustTotalStakedNegative() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        uint256 totalStakedBefore = vault.totalStaked();

        // Operator burns to create approval for negative adjustment
        vm.prank(operator);
        wrapper.ownerBurn(address(vault), 100e6);

        // Operator adjusts totalStaked downward
        vm.prank(operator);
        vault.adjustTotalStaked(-int256(100e6));

        assertEq(vault.totalStaked(), totalStakedBefore - 100e6);
    }

    function test_adjustAccountingSupply() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        vault.setPrimaryChain(1, true);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        uint256 accountingBefore = vault.accountingSupply();

        // Operator mints to create approval for accounting adjustment
        // Amount needs to convert to 100e18 shares at current price
        vm.prank(operator);
        wrapper.ownerMint(address(vault), 100e6);

        // Operator adjusts accounting supply
        vm.prank(operator);
        vault.adjustAccountingSupply(int256(100e6));

        assertEq(vault.accountingSupply(), accountingBefore + 100e6);
    }

    // #############################################
    // EDGE CASES & INTEGRATION TESTS
    // #############################################

    function test_fullUserJourney() public {
        // Setup: Deposit minimum and roll to round 2 (MINIMUM_VALID_ROUND)
        vault.setPrimaryChain(1, true);
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // 1. User deposits in round 2
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // 2. Round rolls with yield
        vm.prank(operator);
        vault.rollToNextRound(100e6, true, MIN_SUPPLY, 0, 1000e6);

        // 3. User claims shares
        vm.prank(user1);
        vault.maxClaimShares();

        uint256 shares = vault.balanceOf(user1);
        assertGt(shares, 0);

        // 4. User unstakes
        vm.prank(user1);
        vault.unstakeAndWithdraw(shares, 0);

        // 5. Complete withdrawal from wrapper
        vm.prank(address(vault)); // Vault is the keeper
        wrapper.processWithdrawals();
        vm.prank(user1);
        wrapper.completeWithdrawal();

        // User should have more USDC than initial due to yield
        assertGt(usdc.balanceOf(user1), INITIAL_BALANCE - 1000e6 - MIN_SUPPLY);
    }

    function test_multipleRoundRolls() public {
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

                vault.setPrimaryChain(1, true);

        // Roll 3 times
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);

        assertEq(vault.round(), 2);

        vm.prank(user2);
        vault.depositAndStake(500e6, user2);

        vm.prank(operator);
        vault.rollToNextRound(50e6, true, 1000e6, 1000e6, 500e6);

        assertEq(vault.round(), 3);

        vm.prank(operator);
        vault.rollToNextRound(25e6, true, 1500e6, vault.accountingSupply(), 0);

        assertEq(vault.round(), 4);
    }

    function test_multipleRoundRollsWithZeroDeposits() public {
        // Initialize with minimum deposit
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        vault.setPrimaryChain(1, true);

        // Roll to round 2 (process initial deposits)
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, 1000e6);
        assertEq(vault.round(), 2);
        assertEq(vault.totalPending(), 0, "Round 2: Should have no pending deposits");

        uint256 totalStakedAfterRound2 = vault.totalStaked();
        uint256 accountingAfterRound2 = vault.accountingSupply();
        assertGt(totalStakedAfterRound2, 0, "Round 2: Should have staked balance");

        // Roll to round 3 with ZERO new deposits (totalPending = 0)
        vm.prank(operator);
        vault.rollToNextRound(10e6, true, totalStakedAfterRound2, accountingAfterRound2, 0); // 10 USDC yield, zero pending
        assertEq(vault.round(), 3);
        assertEq(vault.totalPending(), 0, "Round 3: Should still have no pending deposits");

        uint256 totalStakedAfterRound3 = vault.totalStaked();
        uint256 accountingAfterRound3 = vault.accountingSupply();

        // Verify yield was applied correctly even with zero deposits
        assertGt(totalStakedAfterRound3, totalStakedAfterRound2, "Round 3: Yield should increase totalStaked");
        uint256 priceRound3 = vault.roundPricePerShare(2);
        assertGt(priceRound3, 1e6, "Round 3: Price should reflect yield");

        // Roll to round 4 with ZERO deposits again
        vm.prank(operator);
        vault.rollToNextRound(5e6, true, totalStakedAfterRound3, accountingAfterRound3, 0); // 5 USDC yield, zero pending
        assertEq(vault.round(), 4);
        assertEq(vault.totalPending(), 0, "Round 4: Should still have no pending deposits");

        uint256 totalStakedAfterRound4 = vault.totalStaked();

        // Verify yield continues to compound correctly
        assertGt(totalStakedAfterRound4, totalStakedAfterRound3, "Round 4: Yield should continue increasing totalStaked");
        uint256 priceRound4 = vault.roundPricePerShare(3);
        assertGt(priceRound4, priceRound3, "Round 4: Price should continue increasing");

        // Roll to round 5 with ZERO deposits and NEGATIVE yield
        uint256 loss = 3e6; // 3 USDC loss
        vm.prank(operator);
        vault.rollToNextRound(loss, false, totalStakedAfterRound4, accountingAfterRound3, 0);
        assertEq(vault.round(), 5);

        uint256 totalStakedAfterRound5 = vault.totalStaked();
        uint256 priceRound5 = vault.roundPricePerShare(4);

        // Verify loss was applied correctly
        assertLt(totalStakedAfterRound5, totalStakedAfterRound4, "Round 5: Loss should decrease totalStaked");
        assertLt(priceRound5, priceRound4, "Round 5: Price should reflect loss");

        // Verify user can still interact after multiple zero-deposit rounds
        vm.prank(user1);
        vault.depositAndStake(500e6, user1);
        assertEq(vault.totalPending(), 500e6, "User deposit should work after zero-deposit rounds");
    }

    // =================================================================
    // PROCESS WRAPPER WITHDRAWALS TESTS
    // =================================================================

    /**
     * @notice Test processWrapperWithdrawals delegation pattern
     * @dev This is critical for multi-chain round roll process
     * Operator calls vault.processWrapperWithdrawals() -> vault calls wrapper.processWithdrawals()
     */
    function test_processWrapperWithdrawals() public {
        // Setup: Create a withdrawal that needs processing
        vault.setPrimaryChain(1, true);

        // 1. Deposit minimum to initialize
        vm.prank(user1);
        vault.depositAndStake(uint104(MIN_SUPPLY), user1);

        // 2. Roll to round 2
        vm.prank(operator);
        vault.rollToNextRound(0, true, 0, 0, MIN_SUPPLY);

        // 3. User deposits more
        vm.prank(user1);
        vault.depositAndStake(1000e6, user1);

        // 4. Roll to mint shares
        vm.prank(operator);
        vault.rollToNextRound(0, true, MIN_SUPPLY, 0, 1000e6);

        // 5. User claims and unstakes
        vm.prank(user1);
        vault.maxClaimShares();

        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vault.unstakeAndWithdraw(shares, 0);

        // 6. Check epoch before processing
        uint32 epochBefore = wrapper.currentEpoch();

        // 7. Operator calls processWrapperWithdrawals through vault (DELEGATION PATTERN)
        vm.prank(operator);
        vault.processWrapperWithdrawals();

        // 8. Verify epoch was incremented (processWithdrawals was called)
        assertEq(wrapper.currentEpoch(), epochBefore + 1, "Epoch should increment");

        // 9. User can now complete withdrawal
        vm.prank(user1);
        wrapper.completeWithdrawal();

        assertGt(usdc.balanceOf(user1), INITIAL_BALANCE - 1000e6 - MIN_SUPPLY);
    }

    /**
     * @notice Test processWrapperWithdrawals access control
     * @dev Only operator can call this function
     */
    function test_processWrapperWithdrawalsRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaVault.OnlyOperator.selector);
        vault.processWrapperWithdrawals();
    }
}
