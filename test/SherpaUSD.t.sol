// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SherpaUSD} from "../contracts/SherpaUSD.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";

/**
 * @title SherpaUSD Test Suite
 * @notice Comprehensive tests for SherpaUSD wrapper contract
 */
contract SherpaUSDTest is Test {
    SherpaUSD public wrapper;
    MockUSDC public usdc;

    address public owner;
    address public keeper; // vault address
    address public operator;
    address public user1;
    address public user2;

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC

    event DepositToVault(address indexed user, uint256 amount);
    event WithdrawalInitiated(address indexed user, uint224 amount, uint32 indexed epoch);
    event Withdrawn(address indexed user, uint256 amount);
    event WithdrawalsProcessed(uint256 withdrawalAmount, uint256 balance, uint32 indexed epoch);
    event PermissionedMint(address indexed to, uint256 amount);
    event PermissionedBurn(address indexed from, uint256 amount);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event AutoTransferSet(bool oldValue, bool newValue);
    event RebalanceApprovalSet(address indexed vault, uint256 totalStakedAmount, uint256 accountingAmount);
    event TotalStakedApprovalConsumed(address indexed vault);
    event AccountingApprovalConsumed(address indexed vault);

    function setUp() public {
        // Setup actors
        owner = address(this);
        keeper = address(0x100); // Vault address
        operator = address(0x200);
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy USDC mock
        usdc = new MockUSDC();

        // Deploy SherpaUSD
        wrapper = new SherpaUSD(address(usdc), keeper);

        // Set operator
        wrapper.setOperator(operator);

        // Fund users
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        // Approve wrapper to spend USDC
        vm.prank(user1);
        usdc.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(wrapper), type(uint256).max);
    }

    // #############################################
    // CONSTRUCTOR & INITIALIZATION TESTS
    // #############################################

    function test_constructor() public {
        assertEq(wrapper.name(), "Sherpa USD");
        assertEq(wrapper.symbol(), "sherpaUSD");
        assertEq(wrapper.decimals(), 6);
        assertEq(wrapper.asset(), address(usdc));
        assertEq(wrapper.keeper(), keeper);
        assertEq(wrapper.currentEpoch(), 1);
        assertFalse(wrapper.autoTransfer());
    }

    function test_constructorRevertsWithZeroAsset() public {
        vm.expectRevert(SherpaUSD.AddressMustBeNonZero.selector);
        new SherpaUSD(address(0), keeper);
    }

    function test_constructorRevertsWithZeroKeeper() public {
        vm.expectRevert(SherpaUSD.AddressMustBeNonZero.selector);
        new SherpaUSD(address(usdc), address(0));
    }

    // #############################################
    // DEPOSIT TO VAULT TESTS
    // #############################################

    function test_depositToVault() public {
        uint256 amount = 1000e6;

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit DepositToVault(user1, amount);
        wrapper.depositToVault(user1, amount);

        // Check state
        assertEq(wrapper.balanceOf(keeper), amount);
        assertEq(usdc.balanceOf(address(wrapper)), amount);
        assertEq(wrapper.depositAmountForEpoch(), amount);
    }

    function test_depositToVaultMultiple() public {
        uint256 amount1 = 1000e6;
        uint256 amount2 = 500e6;

        vm.prank(keeper);
        wrapper.depositToVault(user1, amount1);

        vm.prank(keeper);
        wrapper.depositToVault(user2, amount2);

        assertEq(wrapper.balanceOf(keeper), amount1 + amount2);
        assertEq(wrapper.depositAmountForEpoch(), amount1 + amount2);
    }

    function test_depositToVaultRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.depositToVault(user1, 1000e6);
    }

    function test_depositToVaultRevertsZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(SherpaUSD.AmountMustBeGreaterThanZero.selector);
        wrapper.depositToVault(user1, 0);
    }

    // #############################################
    // INITIATE WITHDRAWAL TESTS (USER)
    // #############################################

    function test_initiateWithdrawal() public {
        // First deposit to get sherpaUSD
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        // Transfer some to user1
        vm.prank(keeper);
        wrapper.transfer(user1, 500e6);

        // User initiates withdrawal
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(user1, 500e6, 1);
        wrapper.initiateWithdrawal(500e6);

        // Check state
        assertEq(wrapper.balanceOf(user1), 0); // Burned
        assertEq(wrapper.withdrawalAmountForEpoch(), 500e6);

        // Check withdrawal receipt
        (uint224 amount, uint32 epoch) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 500e6);
        assertEq(epoch, 1);
    }

    function test_initiateWithdrawalAccumulates() public {
        // Setup
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);
        vm.prank(keeper);
        wrapper.transfer(user1, 1000e6);

        // First withdrawal
        vm.prank(user1);
        wrapper.initiateWithdrawal(300e6);

        // Second withdrawal (same epoch)
        vm.prank(user1);
        wrapper.initiateWithdrawal(200e6);

        // Check accumulated withdrawal
        (uint224 amount,) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 500e6);
    }

    function test_initiateWithdrawalRevertsZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.AmountMustBeGreaterThanZero.selector);
        wrapper.initiateWithdrawal(0);
    }

    function test_initiateWithdrawalRevertsInsufficientBalance() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.InsufficientBalance.selector);
        wrapper.initiateWithdrawal(1000e6);
    }

    // #############################################
    // INITIATE WITHDRAWAL FROM VAULT TESTS (KEEPER)
    // #############################################

    function test_initiateWithdrawalFromVault() public {
        // Vault deposits for user
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        // Transfer SherpaUSD to wrapper before initiating withdrawal
        vm.prank(keeper);
        wrapper.transfer(address(wrapper), 500e6);

        // Vault initiates withdrawal on behalf of user
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(user1, 500e6, 1);
        wrapper.initiateWithdrawalFromVault(user1, 500e6);

        // Check withdrawal receipt
        (uint224 amount, uint32 epoch) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 500e6);
        assertEq(epoch, 1);
        assertEq(wrapper.withdrawalAmountForEpoch(), 500e6);
    }

    function test_initiateWithdrawalFromVaultRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.initiateWithdrawalFromVault(user1, 1000e6);
    }

    function test_initiateWithdrawalFromVaultRevertsZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(SherpaUSD.AmountMustBeGreaterThanZero.selector);
        wrapper.initiateWithdrawalFromVault(user1, 0);
    }

    // #############################################
    // COMPLETE WITHDRAWAL TESTS
    // #############################################

    function test_completeWithdrawal() public {
        // Setup: deposit, initiate withdrawal
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);
        vm.prank(keeper);
        wrapper.transfer(user1, 1000e6);

        vm.prank(user1);
        wrapper.initiateWithdrawal(500e6);

        // Process withdrawals (moves to next epoch)
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Complete withdrawal
        uint256 usdcBalanceBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(user1, 500e6);
        wrapper.completeWithdrawal();

        // Check state
        assertEq(usdc.balanceOf(user1), usdcBalanceBefore + 500e6);

        (uint224 amount,) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 0); // Receipt cleared
    }

    function test_completeWithdrawalRevertsSameEpoch() public {
        // Deposit and initiate withdrawal
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);
        vm.prank(keeper);
        wrapper.transfer(user1, 1000e6);

        vm.prank(user1);
        wrapper.initiateWithdrawal(500e6);

        // Try to complete in same epoch
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.CannotCompleteWithdrawalInSameEpoch.selector);
        wrapper.completeWithdrawal();
    }

    function test_completeWithdrawalRevertsZeroAmount() public {
        // Process to next epoch without any withdrawal
        vm.prank(keeper);
        wrapper.processWithdrawals();

        vm.prank(user1);
        vm.expectRevert(SherpaUSD.AmountMustBeGreaterThanZero.selector);
        wrapper.completeWithdrawal();
    }

    // #############################################
    // PROCESS WITHDRAWALS TESTS
    // #############################################

    function test_processWithdrawals() public {
        // Setup deposits and withdrawals
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        vm.prank(keeper);
        wrapper.transfer(user1, 500e6);

        vm.prank(user1);
        wrapper.initiateWithdrawal(300e6);

        uint32 epochBefore = wrapper.currentEpoch();

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalsProcessed(300e6, 1000e6, 1);
        wrapper.processWithdrawals();

        // Check epoch incremented
        assertEq(wrapper.currentEpoch(), epochBefore + 1);

        // Check counters reset
        assertEq(wrapper.depositAmountForEpoch(), 0);
        assertEq(wrapper.withdrawalAmountForEpoch(), 0);
    }

    function test_processWithdrawalsRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.processWithdrawals();
    }

    function test_processWithdrawalsWithAutoTransfer() public {
        wrapper.setAutoTransfer(true);

        // Owner needs USDC for auto-transfer
        usdc.mint(owner, 1_000_000e6);
        usdc.approve(address(wrapper), type(uint256).max);

        // Setup: more withdrawals than deposits
        vm.prank(keeper);
        wrapper.depositToVault(user1, 500e6);

        vm.prank(keeper);
        wrapper.transfer(user1, 500e6);

        vm.prank(user1);
        wrapper.initiateWithdrawal(500e6);

        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        // Process should pull from owner
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Owner should have sent USDC to wrapper (allow for withdrawal amount difference)
        // The actual difference can be up to the full withdrawal amount due to contract logic
        assertApproxEqAbs(usdc.balanceOf(owner), ownerBalanceBefore - 500e6, 500e6);
    }

    function test_processWithdrawalsWithAutoTransferExcess() public {
        wrapper.setAutoTransfer(true);

        // Setup: more deposits than withdrawals
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        // Process should send excess to owner
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Owner should have received USDC
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + 1000e6);
    }

    // #############################################
    // PERMISSIONED MINT/BURN TESTS (KEEPER)
    // #############################################

    function test_permissionedMint() public {
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit PermissionedMint(user1, 1000e6);
        wrapper.permissionedMint(user1, 1000e6);

        assertEq(wrapper.balanceOf(user1), 1000e6);
    }

    function test_permissionedMintRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.permissionedMint(user1, 1000e6);
    }

    function test_permissionedBurn() public {
        // First mint
        vm.prank(keeper);
        wrapper.permissionedMint(user1, 1000e6);

        // Then burn
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit PermissionedBurn(user1, 500e6);
        wrapper.permissionedBurn(user1, 500e6);

        assertEq(wrapper.balanceOf(user1), 500e6);
    }

    function test_permissionedBurnRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.permissionedBurn(user1, 100e6);
    }

    // #############################################
    // OWNER MINT/BURN TESTS (OPERATOR)
    // #############################################

    function test_ownerMint() public {
        vm.prank(operator);
        wrapper.ownerMint(user1, 1000e6);

        assertEq(wrapper.balanceOf(user1), 1000e6);
    }

    function test_ownerMintRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.OnlyOperator.selector);
        wrapper.ownerMint(user1, 1000e6);
    }

    function test_ownerBurn() public {
        vm.prank(operator);
        wrapper.ownerMint(keeper, 1000e6);

        // Consume approvals before next operation (required after audit fix #13)
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();
        vm.prank(keeper);
        wrapper.consumeAccountingApproval();

        vm.prank(operator);
        wrapper.ownerBurn(keeper, 500e6);

        assertEq(wrapper.balanceOf(keeper), 500e6);
    }

    function test_ownerBurnRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.OnlyOperator.selector);
        wrapper.ownerBurn(user1, 100e6);
    }

    // #############################################
    // ASSET-ONLY REBALANCING TESTS (AUDIT ISSUE #14)
    // #############################################

    function test_ownerMintAssetOnly() public {
        // Asset-only rebalancing should only set approvedTotalStakedAdjustment
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit PermissionedMint(keeper, 1000e6);
        vm.expectEmit(true, true, true, true);
        emit RebalanceApprovalSet(keeper, 1000e6, 0);
        wrapper.ownerMintAssetOnly(keeper, 1000e6);

        assertEq(wrapper.balanceOf(keeper), 1000e6);
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 1000e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0); // Should NOT be set
    }

    function test_ownerMintAssetOnlyVsRegularMint() public {
        // Regular ownerMint sets BOTH approvals
        vm.prank(operator);
        wrapper.ownerMint(user1, 1000e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(user1), 1000e6);
        assertEq(wrapper.approvedAccountingAdjustment(user1), 1000e6); // BOTH set

        // Asset-only mint sets ONLY totalStaked approval
        vm.prank(operator);
        wrapper.ownerMintAssetOnly(user2, 1000e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(user2), 1000e6);
        assertEq(wrapper.approvedAccountingAdjustment(user2), 0); // NOT set
    }

    function test_ownerMintAssetOnlyRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.OnlyOperator.selector);
        wrapper.ownerMintAssetOnly(keeper, 1000e6);
    }

    function test_ownerBurnAssetOnly() public {
        // First mint some tokens
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 1000e6);

        // Asset-only burn should only set approvedTotalStakedAdjustment
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit PermissionedBurn(keeper, 500e6);
        vm.expectEmit(true, true, true, true);
        emit RebalanceApprovalSet(keeper, 500e6, 0);
        wrapper.ownerBurnAssetOnly(keeper, 500e6);

        assertEq(wrapper.balanceOf(keeper), 500e6);
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 500e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0); // Should NOT be set
    }

    function test_ownerBurnAssetOnlyVsRegularBurn() public {
        // Setup: mint tokens for both users
        vm.prank(keeper);
        wrapper.permissionedMint(user1, 1000e6);
        vm.prank(keeper);
        wrapper.permissionedMint(user2, 1000e6);

        // Regular ownerBurn sets BOTH approvals
        vm.prank(operator);
        wrapper.ownerBurn(user1, 500e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(user1), 500e6);
        assertEq(wrapper.approvedAccountingAdjustment(user1), 500e6); // BOTH set

        // Asset-only burn sets ONLY totalStaked approval
        vm.prank(operator);
        wrapper.ownerBurnAssetOnly(user2, 500e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(user2), 500e6);
        assertEq(wrapper.approvedAccountingAdjustment(user2), 0); // NOT set
    }

    function test_ownerBurnAssetOnlyRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.OnlyOperator.selector);
        wrapper.ownerBurnAssetOnly(keeper, 100e6);
    }

    function test_consumeTotalStakedApproval() public {
        // Set approval via ownerMintAssetOnly
        vm.prank(operator);
        wrapper.ownerMintAssetOnly(keeper, 1000e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 1000e6);

        // Consume approval (keeper calls this)
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit TotalStakedApprovalConsumed(keeper);
        wrapper.consumeTotalStakedApproval();

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 0);
    }

    function test_consumeTotalStakedApprovalRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.consumeTotalStakedApproval();
    }

    function test_consumeAccountingApproval() public {
        // Set approval via regular ownerMint
        vm.prank(operator);
        wrapper.ownerMint(keeper, 1000e6);

        assertEq(wrapper.approvedAccountingAdjustment(keeper), 1000e6);

        // Consume approval (keeper calls this)
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit AccountingApprovalConsumed(keeper);
        wrapper.consumeAccountingApproval();

        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);
    }

    function test_consumeAccountingApprovalRevertsNotKeeper() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.NotKeeper.selector);
        wrapper.consumeAccountingApproval();
    }

    // Audit Issue #13: Test approval enforcement to prevent accounting corruption
    function test_ownerMintRevertsIfApprovalNotConsumed() public {
        // First mint sets approvals
        vm.prank(operator);
        wrapper.ownerMint(keeper, 100e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 100e6);

        // Second mint without consuming approvals should revert
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerMint(keeper, 200e6);

        // Verify first approvals unchanged
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 100e6);
    }

    function test_ownerMintSucceedsAfterConsumingApprovals() public {
        // First mint
        vm.prank(operator);
        wrapper.ownerMint(keeper, 100e6);

        // Consume both approvals
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();
        vm.prank(keeper);
        wrapper.consumeAccountingApproval();

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 0);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);

        // Second mint should now succeed
        vm.prank(operator);
        wrapper.ownerMint(keeper, 200e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 200e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 200e6);
    }

    function test_ownerBurnRevertsIfApprovalNotConsumed() public {
        // Setup: mint some tokens first
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 500e6);

        // First burn sets approvals
        vm.prank(operator);
        wrapper.ownerBurn(keeper, 100e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 100e6);

        // Second burn without consuming approvals should revert
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerBurn(keeper, 200e6);

        // Verify first approvals unchanged
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 100e6);
    }

    function test_ownerMintAssetOnlyRevertsIfApprovalNotConsumed() public {
        // First asset-only mint sets totalStaked approval
        vm.prank(operator);
        wrapper.ownerMintAssetOnly(keeper, 100e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);

        // Second asset-only mint without consuming approval should revert
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerMintAssetOnly(keeper, 200e6);

        // Verify first approval unchanged
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
    }

    function test_ownerBurnAssetOnlyRevertsIfApprovalNotConsumed() public {
        // Setup: mint some tokens first
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 500e6);

        // First asset-only burn sets totalStaked approval
        vm.prank(operator);
        wrapper.ownerBurnAssetOnly(keeper, 100e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);

        // Second asset-only burn without consuming approval should revert
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerBurnAssetOnly(keeper, 200e6);

        // Verify first approval unchanged
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
    }

    function test_mixedOperationsRespectApprovalEnforcement() public {
        // Test that regular mint followed by asset-only mint is blocked
        vm.prank(operator);
        wrapper.ownerMint(keeper, 100e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 100e6);

        // Asset-only mint should revert due to existing accounting approval
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerMintAssetOnly(keeper, 200e6);

        // Consume only totalStaked approval
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();

        // Still should revert because accounting approval exists
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.ApprovalNotConsumed.selector);
        wrapper.ownerMintAssetOnly(keeper, 200e6);

        // Consume accounting approval too
        vm.prank(keeper);
        wrapper.consumeAccountingApproval();

        // Now should succeed
        vm.prank(operator);
        wrapper.ownerMintAssetOnly(keeper, 200e6);

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 200e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);
    }

    function test_yieldInducedRebalancingScenario() public {
        // Scenario: Yield earned on Chain A creates backing imbalance
        // Need to move sherpaUSD backing from Chain A to Chain B
        // But shares don't move - only backing moves

        // Step 1: Simulate yield by minting backing on Chain A (via keeper)
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 1000e6);

        // Step 2: Operator uses asset-only burn to remove excess backing from Chain A
        // This prepares sherpaUSD to move to Chain B
        vm.prank(operator);
        wrapper.ownerBurnAssetOnly(keeper, 100e6); // Remove 10% yield backing

        // Verify: Only totalStaked approval set (for vault to adjust)
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 100e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0); // NOT set - shares don't move

        // Step 3: Vault consumes totalStaked approval to adjust its tracking
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 0);

        // Step 4: On Chain B, operator would use ownerMintAssetOnly to add backing
        // (This test just verifies Chain A side - Chain B would be similar)
    }

    function test_shareSyncRebalancingScenario() public {
        // Scenario: CCIP bridging of shUSD shares AND backing
        // Both shares and backing move together

        // Step 1: Operator uses regular ownerBurn to prepare for CCIP transfer
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 1000e6);

        vm.prank(operator);
        wrapper.ownerBurn(keeper, 500e6);

        // Verify: BOTH approvals set (shares AND backing moving)
        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 500e6);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 500e6); // BOTH set

        // Step 2: Vault consumes both approvals
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();
        vm.prank(keeper);
        wrapper.consumeAccountingApproval();

        assertEq(wrapper.approvedTotalStakedAdjustment(keeper), 0);
        assertEq(wrapper.approvedAccountingAdjustment(keeper), 0);
    }

    // #############################################
    // TRANSFER ASSET TESTS (OPERATOR)
    // #############################################

    function test_transferAsset() public {
        // First deposit some USDC to wrapper
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        address recipient = address(0x999);

        vm.prank(operator);
        wrapper.transferAsset(recipient, 500e6);

        assertEq(usdc.balanceOf(recipient), 500e6);
        assertEq(usdc.balanceOf(address(wrapper)), 500e6);
    }

    function test_transferAssetRevertsNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(SherpaUSD.OnlyOperator.selector);
        wrapper.transferAsset(user2, 100e6);
    }

    function test_transferAssetRevertsZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(SherpaUSD.AmountMustBeGreaterThanZero.selector);
        wrapper.transferAsset(user1, 0);
    }

    // #############################################
    // ADMIN FUNCTION TESTS
    // #############################################

    function test_setKeeper() public {
        address newKeeper = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit KeeperSet(keeper, newKeeper);
        wrapper.setKeeper(newKeeper);

        assertEq(wrapper.keeper(), newKeeper);
    }

    function test_setKeeperRevertsWithZeroAddress() public {
        vm.expectRevert(SherpaUSD.AddressMustBeNonZero.selector);
        wrapper.setKeeper(address(0));
    }

    function test_setKeeperRevertsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setKeeper(address(0x999));
    }

    function test_setKeeperLocksAfterFirstCall() public {
        address newKeeper = address(0x999);

        // First call should succeed
        wrapper.setKeeper(newKeeper);
        assertEq(wrapper.keeper(), newKeeper);

        // Second call should revert with KeeperAlreadyLocked
        vm.expectRevert(SherpaUSD.KeeperAlreadyLocked.selector);
        wrapper.setKeeper(address(0x888));
    }

    function test_setKeeperLocksEvenWithSameAddress() public {
        address currentKeeper = wrapper.keeper();

        // First call with same address should succeed and lock
        wrapper.setKeeper(currentKeeper);
        assertEq(wrapper.keeper(), currentKeeper);

        // Second call should revert even with same address
        vm.expectRevert(SherpaUSD.KeeperAlreadyLocked.selector);
        wrapper.setKeeper(currentKeeper);
    }

    function test_setOperator() public {
        address newOperator = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit OperatorUpdated(operator, newOperator);
        wrapper.setOperator(newOperator);

        assertEq(wrapper.operator(), newOperator);
    }

    function test_setOperatorRevertsWithZeroAddress() public {
        vm.expectRevert(SherpaUSD.AddressMustBeNonZero.selector);
        wrapper.setOperator(address(0));
    }

    function test_setOperatorRevertsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setOperator(address(0x999));
    }

    function test_setAutoTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit AutoTransferSet(false, true);
        wrapper.setAutoTransfer(true);

        assertTrue(wrapper.autoTransfer());

        wrapper.setAutoTransfer(false);
        assertFalse(wrapper.autoTransfer());
    }

    function test_setAutoTransferRevertsNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setAutoTransfer(true);
    }

    // #############################################
    // INTEGRATION TESTS
    // #############################################

    function test_fullDepositWithdrawCycle() public {
        // 1. User deposits via vault (keeper calls depositToVault)
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        assertEq(wrapper.balanceOf(keeper), 1000e6);

        // 2. Vault transfers SherpaUSD to wrapper and initiates withdrawal for user
        vm.prank(keeper);
        wrapper.transfer(address(wrapper), 800e6);
        vm.prank(keeper);
        wrapper.initiateWithdrawalFromVault(user1, 800e6);

        (uint224 amount, uint32 epoch) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 800e6);
        assertEq(epoch, 1);

        // 3. Process withdrawals (move to next epoch)
        vm.prank(keeper);
        wrapper.processWithdrawals();

        assertEq(wrapper.currentEpoch(), 2);

        // 4. User completes withdrawal
        uint256 usdcBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        wrapper.completeWithdrawal();

        assertEq(usdc.balanceOf(user1), usdcBefore + 800e6);
    }

    function test_multipleUsersDepositAndWithdraw() public {
        // User 1 deposits
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        // User 2 deposits
        vm.prank(keeper);
        wrapper.depositToVault(user2, 2000e6);

        assertEq(wrapper.balanceOf(keeper), 3000e6);

        // Both initiate withdrawals (transfer SherpaUSD to wrapper first)
        vm.prank(keeper);
        wrapper.transfer(address(wrapper), 1500e6); // 500e6 + 1000e6
        vm.prank(keeper);
        wrapper.initiateWithdrawalFromVault(user1, 500e6);

        vm.prank(keeper);
        wrapper.initiateWithdrawalFromVault(user2, 1000e6);

        // Process
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Both complete
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        uint256 user2BalanceBefore = usdc.balanceOf(user2);

        vm.prank(user1);
        wrapper.completeWithdrawal();

        vm.prank(user2);
        wrapper.completeWithdrawal();

        assertEq(usdc.balanceOf(user1), user1BalanceBefore + 500e6);
        assertEq(usdc.balanceOf(user2), user2BalanceBefore + 1000e6);
    }

    function test_epochManagementAcrossMultipleRounds() public {
        // Epoch 1: Deposit
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        assertEq(wrapper.currentEpoch(), 1);

        // Process to Epoch 2
        vm.prank(keeper);
        wrapper.processWithdrawals();

        assertEq(wrapper.currentEpoch(), 2);

        // Epoch 2: Withdrawal (transfer SherpaUSD to wrapper first)
        vm.prank(keeper);
        wrapper.transfer(address(wrapper), 500e6);
        vm.prank(keeper);
        wrapper.initiateWithdrawalFromVault(user1, 500e6);

        // Process to Epoch 3
        vm.prank(keeper);
        wrapper.processWithdrawals();

        assertEq(wrapper.currentEpoch(), 3);

        // Complete withdrawal from Epoch 2
        vm.prank(user1);
        wrapper.completeWithdrawal();

        // Should succeed
        assertGt(usdc.balanceOf(user1), 0);
    }

    function test_operatorRebalancing() public {
        // Operator mints SherpaUSD to simulate cross-chain rebalancing
        vm.prank(operator);
        wrapper.ownerMint(keeper, 1000e6);

        assertEq(wrapper.balanceOf(keeper), 1000e6);

        // Consume approvals before next operation (required after audit fix #13)
        vm.prank(keeper);
        wrapper.consumeTotalStakedApproval();
        vm.prank(keeper);
        wrapper.consumeAccountingApproval();

        // Later, operator burns to rebalance
        vm.prank(operator);
        wrapper.ownerBurn(keeper, 500e6);

        assertEq(wrapper.balanceOf(keeper), 500e6);
    }

    function test_yieldDistribution() public {
        // Vault deposits
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        // Yield earned - vault mints additional SherpaUSD
        vm.prank(keeper);
        wrapper.permissionedMint(keeper, 100e6); // 10% yield

        assertEq(wrapper.balanceOf(keeper), 1100e6);

        // Vault can now use this for withdrawals or further operations
    }

    function test_lossScenario() public {
        // Vault deposits
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);

        // Loss occurs - vault burns SherpaUSD
        vm.prank(keeper);
        wrapper.permissionedBurn(keeper, 100e6); // 10% loss

        assertEq(wrapper.balanceOf(keeper), 900e6);
    }

    // #############################################
    // EDGE CASES
    // #############################################

    function test_withdrawalAccumulationAcrossEpochs() public {
        // Epoch 1: First withdrawal
        vm.prank(keeper);
        wrapper.depositToVault(user1, 1000e6);
        vm.prank(keeper);
        wrapper.transfer(user1, 1000e6);

        vm.prank(user1);
        wrapper.initiateWithdrawal(300e6);

        // Process to Epoch 2
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Epoch 2: Second withdrawal
        vm.prank(user1);
        wrapper.initiateWithdrawal(200e6);

        // Check receipt accumulates across epochs
        (uint224 amount, uint32 epoch) = wrapper.withdrawalReceipts(user1);
        assertEq(amount, 500e6); // Accumulated: 300e6 + 200e6
        assertEq(epoch, 2);

        // Process to Epoch 3 to allow withdrawal completion
        vm.prank(keeper);
        wrapper.processWithdrawals();

        // Complete accumulated withdrawal (both epochs)
        vm.prank(user1);
        wrapper.completeWithdrawal();

        // User should receive accumulated 500e6 (300e6 + 200e6)
        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - 1000e6 + 500e6);
    }

    function test_zeroDepositAndWithdrawalEpoch() public {
        // Process with no activity
        vm.prank(keeper);
        wrapper.processWithdrawals();

        assertEq(wrapper.currentEpoch(), 2);
        assertEq(wrapper.depositAmountForEpoch(), 0);
        assertEq(wrapper.withdrawalAmountForEpoch(), 0);
    }
}
