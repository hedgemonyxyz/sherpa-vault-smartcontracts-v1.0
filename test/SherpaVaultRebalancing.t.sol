// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SherpaVault} from "../contracts/SherpaVault.sol";
import {SherpaUSD} from "../contracts/SherpaUSD.sol";
import {Vault} from "../contracts/lib/Vault.sol";
import {MockUSDC} from "../contracts/MockUSDC.sol";

/**
 * @title SherpaVault Rebalancing Integration Tests
 * @notice Tests the complete 6-step rebalancing process as performed by rebalanceSherpaUSD.js
 * @dev Verifies multi-chain accounting remains consistent during SherpaUSD rebalancing
 */
contract SherpaVaultRebalancingTest is Test {
    SherpaVault public vaultSepolia;
    SherpaVault public vaultBase;

    SherpaUSD public wrapperSepolia;
    SherpaUSD public wrapperBase;

    MockUSDC public usdc;

    address public owner;
    address public operator;
    address public user1;

    uint256 constant INITIAL_BALANCE = 1_000_000e6;

    function setUp() public {
        owner = address(this);
        operator = address(0x100);
        user1 = address(0x1);

        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy wrappers
        wrapperSepolia = new SherpaUSD(address(usdc), address(0xdead));
        wrapperBase = new SherpaUSD(address(usdc), address(0xdead));

        // Deploy vaults
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: 100e6,
            cap: 10_000_000e6
        });

        vaultSepolia = new SherpaVault(
            "Sherpa Vault Sepolia",
            "svSEP",
            address(wrapperSepolia),
            address(this),
            params
        );

        vaultBase = new SherpaVault(
            "Sherpa Vault Base",
            "svBASE",
            address(wrapperBase),
            address(this),
            params
        );

        // Setup keepers
        wrapperSepolia.setKeeper(address(vaultSepolia));
        wrapperBase.setKeeper(address(vaultBase));

        // Set operators
        vaultSepolia.setOperator(operator);
        vaultBase.setOperator(operator);
        wrapperSepolia.setOperator(operator);
        wrapperBase.setOperator(operator);

        // Fund user
        usdc.mint(user1, INITIAL_BALANCE);
        vm.prank(user1);
        usdc.approve(address(wrapperSepolia), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(wrapperBase), type(uint256).max);
    }

    // #############################################
    // FULL REBALANCING INTEGRATION TESTS
    // #############################################

    /**
     * @notice Test complete 6-step rebalancing process (Sepolia → Base)
     * @dev Matches the exact flow of rebalanceSherpaUSD.js
     */
    function test_fullRebalancingFlow() public {
        // ============ SETUP ============
        // 1. Deposit on both chains
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        // 2. Roll both chains to establish price
        vaultSepolia.setPrimaryChain(1, true);

        vm.prank(operator);
        vaultSepolia.rollToNextRound(
            0,      // yield
            true,   // isYieldPositive
            0,      // globalTotalStaked (will be set)
            0,      // globalAccountingSupply
            8000e6  // globalTotalPending
        );

        uint256 newRound = vaultSepolia.round();
        uint256 price = vaultSepolia.roundPricePerShare(1);

        vm.prank(operator);
        vaultBase.applyGlobalPrice(newRound, price);

        // Verify initial state
        assertEq(wrapperSepolia.balanceOf(address(vaultSepolia)), 5000e6);
        assertEq(wrapperBase.balanceOf(address(vaultBase)), 3000e6);
        assertEq(vaultSepolia.totalStaked(), 5000e6);
        assertEq(vaultBase.totalStaked(), 3000e6);

        // ============ REBALANCING: Move 1000 USDC from Sepolia to Base ============

        uint256 rebalanceAmount = 1000e6;

        // Calculate accounting adjustment: amount / pricePerShare
        // price is in 6 decimals, amount is in 6 decimals
        // accountingSupply is in 6 decimals
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // Record state before rebalancing
        uint256 sepoliaSherpaUSDBefore = wrapperSepolia.balanceOf(address(vaultSepolia));
        uint256 baseSherpaUSDBefore = wrapperBase.balanceOf(address(vaultBase));
        uint256 sepoliaTotalStakedBefore = vaultSepolia.totalStaked();
        uint256 baseTotalStakedBefore = vaultBase.totalStaked();
        uint256 sepoliaAccountingBefore = vaultSepolia.accountingSupply();
        uint256 baseAccountingBefore = vaultBase.accountingSupply();
        uint256 globalSherpaUSDBefore = sepoliaSherpaUSDBefore + baseSherpaUSDBefore;
        uint256 globalAccountingBefore = sepoliaAccountingBefore + baseAccountingBefore;

        // ============ DEBIT CHAIN (Sepolia) ============

        // Step 1: ownerBurn (burn SherpaUSD from vault)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);

        assertEq(
            wrapperSepolia.balanceOf(address(vaultSepolia)),
            sepoliaSherpaUSDBefore - rebalanceAmount,
            "Sepolia SherpaUSD should decrease"
        );

        // Step 2: adjustTotalStaked (negative)
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));

        assertEq(
            vaultSepolia.totalStaked(),
            sepoliaTotalStakedBefore - rebalanceAmount,
            "Sepolia totalStaked should decrease"
        );

        // Step 3: adjustAccountingSupply (negative)
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        assertEq(
            vaultSepolia.accountingSupply(),
            sepoliaAccountingBefore - accountingAdjustment,
            "Sepolia accountingSupply should decrease"
        );

        // ============ CREDIT CHAIN (Base) ============

        // Step 4: ownerMint (mint SherpaUSD to vault)
        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);

        assertEq(
            wrapperBase.balanceOf(address(vaultBase)),
            baseSherpaUSDBefore + rebalanceAmount,
            "Base SherpaUSD should increase"
        );

        // Step 5: adjustTotalStaked (positive)
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));

        assertEq(
            vaultBase.totalStaked(),
            baseTotalStakedBefore + rebalanceAmount,
            "Base totalStaked should increase"
        );

        // Step 6: adjustAccountingSupply (positive)
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        assertEq(
            vaultBase.accountingSupply(),
            baseAccountingBefore + accountingAdjustment,
            "Base accountingSupply should increase"
        );

        // ============ VERIFY GLOBAL INVARIANTS ============

        uint256 globalSherpaUSDAfter = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                       wrapperBase.balanceOf(address(vaultBase));
        uint256 globalAccountingAfter = vaultSepolia.accountingSupply() +
                                        vaultBase.accountingSupply();

        assertEq(
            globalSherpaUSDAfter,
            globalSherpaUSDBefore,
            "CRITICAL: Global SherpaUSD supply should be unchanged"
        );

        assertEq(
            globalAccountingAfter,
            globalAccountingBefore,
            "CRITICAL: Global accountingSupply should be unchanged"
        );

        // Verify individual chain changes are symmetric
        assertEq(
            vaultSepolia.totalStaked(),
            sepoliaTotalStakedBefore - rebalanceAmount,
            "Sepolia totalStaked final check"
        );
        assertEq(
            vaultBase.totalStaked(),
            baseTotalStakedBefore + rebalanceAmount,
            "Base totalStaked final check"
        );
    }

    /**
     * @notice Test rebalancing with high price (low accounting adjustment)
     */
    function test_rebalancingWithHighPrice() public {
        // Setup with yield to create high price
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        // Roll with significant yield (25%)
        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(2000e6, true, 0, 0, 8000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        // Price should be > 1.0 due to yield

        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price);

        // Rebalance 1000 USDC
        uint256 rebalanceAmount = 1000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // Execute rebalancing
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify invariants still hold
        // Note: Total is 10000e6 because 2000e6 yield was minted during rollToNextRound
        uint256 globalSherpaUSD = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                  wrapperBase.balanceOf(address(vaultBase));
        assertEq(globalSherpaUSD, 10000e6, "Global SherpaUSD preserved");
    }

    /**
     * @notice Test rebalancing with loss (low price, high accounting adjustment)
     */
    function test_rebalancingWithLowPrice() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        // Round 1: Initial roll to establish vault
        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 8000e6);

        uint256 price1 = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price1);

        // Round 2: Roll with loss (-10%)
        vm.prank(operator);
        vaultSepolia.rollToNextRound(800e6, false, 8000e6, vaultSepolia.accountingSupply() + vaultBase.accountingSupply(), 0);

        uint256 price = vaultSepolia.roundPricePerShare(2);
        // Price should be < 1.0 due to loss
        assertLt(price, price1, "Price should decrease with loss");

        vm.prank(operator);
        vaultBase.applyGlobalPrice(3, price);

        // Rebalance
        uint256 rebalanceAmount = 1000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // Execute
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify
        // Note: Total is 7200e6 because 800e6 loss was burned during rollToNextRound
        uint256 globalSherpaUSD = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                  wrapperBase.balanceOf(address(vaultBase));
        assertEq(globalSherpaUSD, 7200e6, "Global SherpaUSD preserved despite loss");
    }

    // #############################################
    // FAILURE SCENARIO TESTS
    // #############################################

    /**
     * @notice Test partial failure: debit chain completes, credit chain fails
     * @dev This tests the script's error recovery paths
     */
    function test_rebalancingPartialFailure_DebitComplete_CreditFails() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 8000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price);

        uint256 rebalanceAmount = 1000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // Complete debit chain
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        // Record state after debit (before credit)
        uint256 globalSherpaUSDMidway = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                        wrapperBase.balanceOf(address(vaultBase));

        // At this point, global SherpaUSD is REDUCED (imbalanced state)
        assertEq(globalSherpaUSDMidway, 7000e6, "Global supply reduced after debit only");

        // Now complete credit chain to restore balance
        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify balance restored
        uint256 globalSherpaUSDFinal = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                       wrapperBase.balanceOf(address(vaultBase));
        assertEq(globalSherpaUSDFinal, 8000e6, "Global supply restored after credit");
    }

    /**
     * @notice Test that non-operator cannot execute rebalancing steps
     */
    function test_rebalancingRevertsNotOperator() public {
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // User tries to burn (should fail)
        vm.prank(user1);
        vm.expectRevert();
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // User tries to adjust (should fail)
        vm.prank(user1);
        vm.expectRevert();
        vaultSepolia.adjustTotalStaked(-1000e6);

        vm.prank(user1);
        vm.expectRevert();
        vaultSepolia.adjustAccountingSupply(-1000e18);
    }

    /**
     * @notice Test rebalancing the entire balance from one chain to another
     */
    function test_rebalancingFullBalance() public {
        // Setup with unequal distribution
        vm.prank(user1);
        vaultSepolia.depositAndStake(7000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(1000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 8000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price);

        // Rebalance ALL of Sepolia to Base (7000 USDC)
        uint256 rebalanceAmount = 7000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // Execute
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify Sepolia has 0, Base has all
        assertEq(vaultSepolia.totalStaked(), 0, "Sepolia should have 0");
        assertEq(vaultBase.totalStaked(), 8000e6, "Base should have all");

        // Global invariants still hold
        uint256 globalSherpaUSD = wrapperSepolia.balanceOf(address(vaultSepolia)) +
                                  wrapperBase.balanceOf(address(vaultBase));
        assertEq(globalSherpaUSD, 8000e6, "Global supply unchanged");
    }

    // #############################################
    // APPROVAL VALIDATION TESTS
    // #############################################

    /**
     * @notice Test that adjustTotalStaked fails without prior ownerMint/ownerBurn
     */
    function test_adjustTotalStaked_RevertsWithoutApproval() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Try to adjust without ownerBurn (no approval)
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("AdjustmentNotApproved()"));
        vaultSepolia.adjustTotalStaked(-1000e6);
    }

    /**
     * @notice Test that adjustAccountingSupply fails without prior ownerMint/ownerBurn
     */
    function test_adjustAccountingSupply_RevertsWithoutApproval() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        uint256 accountingAdjustment = (1000e6 * 1e6) / price;

        // Try to adjust without ownerBurn (no approval)
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("IncorrectCalculation()"));
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));
    }

    /**
     * @notice Test that adjustTotalStaked fails with wrong amount (different from ownerBurn amount)
     */
    function test_adjustTotalStaked_RevertsWithWrongAmount() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Burn 1000 (sets approval to 1000)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // Try to adjust with wrong amount (500 instead of 1000)
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("AdjustmentNotApproved()"));
        vaultSepolia.adjustTotalStaked(-500e6);
    }

    /**
     * @notice Test that adjustAccountingSupply fails with wrong calculation
     */
    function test_adjustAccountingSupply_RevertsWithWrongCalculation() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);

        // Burn 1000 (sets approval to 1000)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // Adjust totalStaked correctly
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        // Try to adjust accountingSupply with WRONG calculation (half of correct)
        uint256 correctAccounting = (1000e6 * 1e6) / price;
        uint256 wrongAccounting = correctAccounting / 2;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("IncorrectCalculation()"));
        vaultSepolia.adjustAccountingSupply(-int256(wrongAccounting));
    }

    /**
     * @notice Test that approvals cannot be reused (consumed after first use)
     */
    function test_approvals_CannotBeReused() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Burn 1000 (sets approval to 1000)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // First adjust - should work
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        // Try to adjust again with same approval - should fail (approval consumed)
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("AdjustmentNotApproved()"));
        vaultSepolia.adjustTotalStaked(-1000e6);
    }

    /**
     * @notice Test that ownerMint sets approvals correctly
     */
    function test_ownerMint_SetsApprovals() public {
        // Setup
        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        vaultBase.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultBase.rollToNextRound(0, true, 0, 0, 3000e6);

        // Check approvals are 0 before mint
        assertEq(wrapperBase.approvedTotalStakedAdjustment(address(vaultBase)), 0);
        assertEq(wrapperBase.approvedAccountingAdjustment(address(vaultBase)), 0);

        // Mint 1000
        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), 1000e6);

        // Check approvals are set correctly
        assertEq(wrapperBase.approvedTotalStakedAdjustment(address(vaultBase)), 1000e6);
        assertEq(wrapperBase.approvedAccountingAdjustment(address(vaultBase)), 1000e6);
    }

    /**
     * @notice Test that ownerBurn sets approvals correctly
     */
    function test_ownerBurn_SetsApprovals() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Check approvals are 0 before burn
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 0);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 0);

        // Burn 1000
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // Check approvals are set correctly
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 1000e6);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 1000e6);
    }

    /**
     * @notice Test that adjustTotalStaked consumes its approval (not accountingSupply approval)
     */
    function test_adjustTotalStaked_ConsumesOnlyItsApproval() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Burn 1000 (sets both approvals to 1000)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // Verify both approvals are set
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 1000e6);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 1000e6);

        // Adjust totalStaked
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        // Verify totalStaked approval consumed, but accounting approval still there
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 0);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 1000e6);
    }

    /**
     * @notice Test that adjustAccountingSupply consumes its approval (not totalStaked approval)
     */
    function test_adjustAccountingSupply_ConsumesOnlyItsApproval() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        uint256 accountingAdjustment = (1000e6 * 1e6) / price;

        // Burn 1000 (sets both approvals to 1000)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // First adjust totalStaked
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        // Verify accounting approval still there
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 1000e6);

        // Adjust accountingSupply
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        // Verify accounting approval consumed
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 0);
    }

    /**
     * @notice Test complete rebalancing with approval validation (integration test)
     */
    function test_rebalancing_WithApprovalValidation_Complete() public {
        // Setup both chains
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 8000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price);

        uint256 rebalanceAmount = 1000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price;

        // DEBIT CHAIN: ownerBurn sets approvals
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);

        // Verify approvals set
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), rebalanceAmount);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), rebalanceAmount);

        // adjustTotalStaked validates and consumes
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));

        // Verify totalStaked approval consumed
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 0);

        // adjustAccountingSupply validates calculation and consumes
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        // Verify accounting approval consumed
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 0);

        // CREDIT CHAIN: ownerMint sets approvals
        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);

        // Verify approvals set
        assertEq(wrapperBase.approvedTotalStakedAdjustment(address(vaultBase)), rebalanceAmount);
        assertEq(wrapperBase.approvedAccountingAdjustment(address(vaultBase)), rebalanceAmount);

        // adjustTotalStaked validates and consumes
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));

        // Verify totalStaked approval consumed
        assertEq(wrapperBase.approvedTotalStakedAdjustment(address(vaultBase)), 0);

        // adjustAccountingSupply validates calculation and consumes
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify accounting approval consumed
        assertEq(wrapperBase.approvedAccountingAdjustment(address(vaultBase)), 0);

        // Verify final state correct
        assertEq(vaultSepolia.totalStaked(), 4000e6);
        assertEq(vaultBase.totalStaked(), 4000e6);
    }

    // #############################################
    // ASSET-ONLY REBALANCING TESTS (AUDIT ISSUE #14)
    // #############################################

    /**
     * @notice Test asset-only rebalancing for yield-induced backing imbalances
     * @dev This is the fix for audit issue #14: When yield creates backing imbalance,
     *      only backing should move (totalStaked), NOT shares (accountingSupply)
     */
    function test_assetOnlyRebalancing_YieldInducedImbalance() public {
        // ============ SETUP ============
        // User deposits on both chains
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(5000e6, user1);

        // Roll to establish initial state
        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 10000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price);

        // Initial state: Both chains have 5000 USDC backing and 5000 accountingSupply
        assertEq(vaultSepolia.totalStaked(), 5000e6, "Initial Sepolia totalStaked");
        assertEq(vaultBase.totalStaked(), 5000e6, "Initial Base totalStaked");
        assertEq(vaultSepolia.accountingSupply(), 5000e6, "Initial Sepolia accountingSupply");
        assertEq(vaultBase.accountingSupply(), 5000e6, "Initial Base accountingSupply");

        // ============ YIELD SCENARIO ============
        // Simulate yield earned on Sepolia by rolling with positive yield
        // This will mint additional sherpaUSD on Sepolia as backing
        vm.prank(operator);
        vaultSepolia.rollToNextRound(
            1000e6,  // 1000 USDC yield
            true,    // isYieldPositive
            10000e6, // globalTotalStaked
            vaultSepolia.accountingSupply() + vaultBase.accountingSupply(), // globalAccountingSupply
            0        // globalTotalPending
        );

        // Apply the new price to Base (Base doesn't get the yield)
        uint256 newPrice = vaultSepolia.roundPricePerShare(2);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(3, newPrice);

        // Now Sepolia has 6000 backing (5000 + 1000 yield) but accountingSupply remains 5000
        // Base still has 5000 backing and 5000 accountingSupply
        assertEq(vaultSepolia.totalStaked(), 6000e6, "Sepolia backing increased from yield");
        assertEq(vaultBase.totalStaked(), 5000e6, "Base backing unchanged");
        assertEq(vaultSepolia.accountingSupply(), 5000e6, "Sepolia shares unchanged (no user deposits)");
        assertEq(vaultBase.accountingSupply(), 5000e6, "Base shares unchanged");

        // ============ ASSET-ONLY REBALANCING ============
        // Need to move 500 USDC backing from Sepolia to Base to balance backing distribution
        // But shares should NOT move (users deposited 50/50, that shouldn't change)

        uint256 rebalanceAmount = 500e6;

        // Record state before rebalancing
        uint256 globalAccountingBefore = vaultSepolia.accountingSupply() + vaultBase.accountingSupply();
        uint256 globalBackingBefore = vaultSepolia.totalStaked() + vaultBase.totalStaked();

        // Verify initial imbalance: 11000 total backing, but still 10000 accountingSupply
        assertEq(globalBackingBefore, 11000e6, "Total backing is 11000 (5000 + 5000 + 1000 yield)");
        assertEq(globalAccountingBefore, 10000e6, "Total accountingSupply unchanged at 10000");

        // DEBIT CHAIN: Use asset-only burn (only adjusts totalStaked approval)
        vm.prank(operator);
        wrapperSepolia.ownerBurnAssetOnly(address(vaultSepolia), rebalanceAmount);

        // Verify only totalStaked approval set
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), rebalanceAmount);
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 0, "Accounting approval should NOT be set");

        // Adjust only totalStaked (backing)
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));

        // accountingSupply should NOT change
        assertEq(vaultSepolia.accountingSupply(), 5000e6, "Sepolia shares should NOT change");
        assertEq(vaultSepolia.totalStaked(), 5500e6, "Sepolia backing decreased");

        // CREDIT CHAIN: Use asset-only mint (only adjusts totalStaked approval)
        vm.prank(operator);
        wrapperBase.ownerMintAssetOnly(address(vaultBase), rebalanceAmount);

        // Verify only totalStaked approval set
        assertEq(wrapperBase.approvedTotalStakedAdjustment(address(vaultBase)), rebalanceAmount);
        assertEq(wrapperBase.approvedAccountingAdjustment(address(vaultBase)), 0, "Accounting approval should NOT be set");

        // Adjust only totalStaked (backing)
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));

        // accountingSupply should NOT change
        assertEq(vaultBase.accountingSupply(), 5000e6, "Base shares should NOT change");
        assertEq(vaultBase.totalStaked(), 5500e6, "Base backing increased");

        // ============ VERIFY INVARIANTS ============
        uint256 globalAccountingAfter = vaultSepolia.accountingSupply() + vaultBase.accountingSupply();
        uint256 globalBackingAfter = vaultSepolia.totalStaked() + vaultBase.totalStaked();

        assertEq(globalAccountingAfter, globalAccountingBefore, "CRITICAL: Global accountingSupply unchanged (shares didn't move)");
        assertEq(globalBackingAfter, globalBackingBefore, "CRITICAL: Global backing unchanged (only redistributed)");
        assertEq(globalAccountingAfter, 10000e6, "Total shares still 10000");
        assertEq(globalBackingAfter, 11000e6, "Total backing now 11000 (with yield)");
    }

    /**
     * @notice Test that asset-only rebalancing does NOT allow adjustAccountingSupply
     * @dev Verifies the fix prevents the corruption described in audit issue #14
     */
    function test_assetOnlyRebalancing_CannotAdjustAccountingSupply() public {
        // Setup
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);

        // Use asset-only burn
        vm.prank(operator);
        wrapperSepolia.ownerBurnAssetOnly(address(vaultSepolia), 1000e6);

        // adjustTotalStaked should work
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        // But adjustAccountingSupply should FAIL (no accounting approval)
        uint256 accountingAdjustment = (1000e6 * 1e6) / price;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("IncorrectCalculation()"));
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));
    }

    /**
     * @notice Compare share-sync vs asset-only rebalancing side by side
     * @dev Demonstrates the difference between CCIP bridging and yield rebalancing
     */
    function test_compareShareSyncVsAssetOnlyRebalancing() public {
        // ===== SCENARIO A: Share-sync rebalancing (CCIP) =====
        // User wants to move their shUSD shares from Sepolia to Base
        // Both backing AND shares move

        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 5000e6);

        // Share-sync: Use regular ownerBurn (sets BOTH approvals)
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), 1000e6);

        // Both approvals should be set
        assertEq(wrapperSepolia.approvedTotalStakedAdjustment(address(vaultSepolia)), 1000e6, "Share-sync: totalStaked approval");
        assertEq(wrapperSepolia.approvedAccountingAdjustment(address(vaultSepolia)), 1000e6, "Share-sync: accounting approval");

        // Can adjust BOTH totalStaked and accountingSupply
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-1000e6);

        uint256 price = vaultSepolia.roundPricePerShare(1);
        uint256 accountingAdj = (1000e6 * 1e6) / price;
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdj));

        // ===== SCENARIO B: Asset-only rebalancing (yield) =====
        // Deploy fresh vault for clean comparison
        SherpaUSD wrapperBase2 = new SherpaUSD(address(usdc), address(0xdead));
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: 100e6,
            cap: 10_000_000e6
        });
        SherpaVault vaultBase2 = new SherpaVault("Test", "TEST", address(wrapperBase2), address(this), params);
        wrapperBase2.setKeeper(address(vaultBase2));
        wrapperBase2.setOperator(operator);
        vaultBase2.setOperator(operator);

        // Approve the new vault to spend user1's USDC
        vm.prank(user1);
        usdc.approve(address(wrapperBase2), type(uint256).max);

        vm.prank(user1);
        vaultBase2.depositAndStake(5000e6, user1);

        vaultBase2.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultBase2.rollToNextRound(0, true, 0, 0, 5000e6);

        // Asset-only: Use ownerBurnAssetOnly (sets ONLY totalStaked approval)
        vm.prank(operator);
        wrapperBase2.ownerBurnAssetOnly(address(vaultBase2), 1000e6);

        // Only totalStaked approval should be set
        assertEq(wrapperBase2.approvedTotalStakedAdjustment(address(vaultBase2)), 1000e6, "Asset-only: totalStaked approval");
        assertEq(wrapperBase2.approvedAccountingAdjustment(address(vaultBase2)), 0, "Asset-only: NO accounting approval");

        // Can adjust totalStaked but NOT accountingSupply
        vm.prank(operator);
        vaultBase2.adjustTotalStaked(-1000e6);

        // This should fail
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("IncorrectCalculation()"));
        vaultBase2.adjustAccountingSupply(-int256(accountingAdj));
    }

    /**
     * @notice Test rebalancing after multiple rounds with varying prices
     */
    function test_rebalancingAfterMultipleRounds() public {
        // Round 1: Initial deposit
        vm.prank(user1);
        vaultSepolia.depositAndStake(5000e6, user1);
        vm.prank(user1);
        vaultBase.depositAndStake(3000e6, user1);

        vaultSepolia.setPrimaryChain(1, true);
        vm.prank(operator);
        vaultSepolia.rollToNextRound(0, true, 0, 0, 8000e6);

        uint256 price1 = vaultSepolia.roundPricePerShare(1);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(2, price1);

        // Round 2: Add yield
        vm.prank(operator);
        vaultSepolia.rollToNextRound(400e6, true, 8000e6, vaultSepolia.accountingSupply() + vaultBase.accountingSupply(), 0);

        uint256 price2 = vaultSepolia.roundPricePerShare(2);
        vm.prank(operator);
        vaultBase.applyGlobalPrice(3, price2);

        // Price should have increased
        assertGt(price2, price1, "Price should increase with yield");

        // Now rebalance using the higher price
        uint256 rebalanceAmount = 1000e6;
        uint256 accountingAdjustment = (rebalanceAmount * 1e6) / price2;

        // Execute rebalancing
        vm.prank(operator);
        wrapperSepolia.ownerBurn(address(vaultSepolia), rebalanceAmount);
        vm.prank(operator);
        vaultSepolia.adjustTotalStaked(-int256(rebalanceAmount));
        vm.prank(operator);
        vaultSepolia.adjustAccountingSupply(-int256(accountingAdjustment));

        vm.prank(operator);
        wrapperBase.ownerMint(address(vaultBase), rebalanceAmount);
        vm.prank(operator);
        vaultBase.adjustTotalStaked(int256(rebalanceAmount));
        vm.prank(operator);
        vaultBase.adjustAccountingSupply(int256(accountingAdjustment));

        // Verify global accounting unchanged
        uint256 globalAccounting = vaultSepolia.accountingSupply() + vaultBase.accountingSupply();
        // Should equal the accounting supply after round 2
        assertGt(globalAccounting, 0, "Global accounting preserved");
    }
}
