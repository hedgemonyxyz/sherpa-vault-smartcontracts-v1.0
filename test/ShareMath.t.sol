// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../contracts/lib/ShareMath.sol";
import {Vault} from "../contracts/lib/Vault.sol";

/**
 * @title ShareMathWrapper
 * @notice Wrapper contract to test library reverts at proper call depth
 * @dev Required because library functions are inlined and revert at test contract level
 */
contract ShareMathWrapper {
    function assetToShares(
        uint256 assetAmount,
        uint256 assetPerShare,
        uint256 decimals
    ) external pure returns (uint256) {
        return ShareMath.assetToShares(assetAmount, assetPerShare, decimals);
    }

    function sharesToAsset(
        uint256 shares,
        uint256 assetPerShare,
        uint256 decimals
    ) external pure returns (uint256) {
        return ShareMath.sharesToAsset(shares, assetPerShare, decimals);
    }

    function assertUint104(uint256 num) external pure {
        ShareMath.assertUint104(num);
    }

    function assertUint128(uint256 num) external pure {
        ShareMath.assertUint128(num);
    }
}

/**
 * @title ShareMath Test Suite
 * @notice Tests for ShareMath library functions
 */
contract ShareMathTest is Test {
    using ShareMath for Vault.StakeReceipt;

    ShareMathWrapper public wrapper;

    uint256 constant DECIMALS_18 = 18;
    uint256 constant DECIMALS_6 = 6;

    function setUp() public {
        wrapper = new ShareMathWrapper();
    }

    // #############################################
    // ASSET TO SHARES TESTS
    // #############################################

    /**
     * @notice Test clean asset to shares conversion (no fractional remainder)
     * @dev 100 tokens at 10 tokens/share (18 decimals) = 10 shares
     */
    function test_assetToSharesClean() public {
        uint256 assetAmount = 100e6; // 100 USDC
        uint256 assetPerShare = 10e6; // 10 USDC per share

        uint256 shares = ShareMath.assetToShares(
            assetAmount,
            assetPerShare,
            DECIMALS_18
        );

        assertEq(shares, 10e18, "Should convert to 10 shares with 18 decimals");
    }

    /**
     * @notice Test asset to shares with fractional results
     * @dev 83 tokens at 2.3 tokens/share should handle precision correctly
     */
    function test_assetToSharesDirty() public {
        uint256 assetAmount = 83e6; // 83 USDC
        uint256 assetPerShare = 2.3e6; // 2.3 USDC per share

        uint256 shares = ShareMath.assetToShares(
            assetAmount,
            assetPerShare,
            DECIMALS_18
        );

        // 83 / 2.3 = 36.086956521739130434...
        uint256 expected = 36086956521739130434;
        assertEq(shares, expected, "Should handle fractional conversion with precision");
    }

    /**
     * @notice Test that assetToShares reverts with invalid price (placeholder)
     */
    function test_assetToSharesRevertsWithPlaceholder() public {
        uint256 assetAmount = 100e6;
        uint256 invalidPrice = 1; // Placeholder value

        vm.expectRevert(abi.encodeWithSignature("InvalidAssetPerShare()"));
        wrapper.assetToShares(assetAmount, invalidPrice, DECIMALS_18);
    }

    /**
     * @notice Test that assetToShares reverts with zero price
     */
    function test_assetToSharesRevertsWithZero() public {
        uint256 assetAmount = 100e6;
        uint256 zeroPrice = 0;

        vm.expectRevert(abi.encodeWithSignature("InvalidAssetPerShare()"));
        wrapper.assetToShares(assetAmount, zeroPrice, DECIMALS_18);
    }

    // #############################################
    // SHARES TO ASSET TESTS
    // #############################################

    /**
     * @notice Test clean shares to asset conversion
     * @dev 10 shares at 10 tokens/share (18 decimals) = 100 tokens
     */
    function test_sharesToAssetClean() public {
        uint256 shares = 10e18; // 10 shares
        uint256 assetPerShare = 10e6; // 10 USDC per share

        uint256 assets = ShareMath.sharesToAsset(
            shares,
            assetPerShare,
            DECIMALS_18
        );

        assertEq(assets, 100e6, "Should convert to 100 USDC");
    }

    /**
     * @notice Test shares to asset with fractional conversion
     * @dev Confirm precision is maintained through rounding
     */
    function test_sharesToAssetDirty() public {
        uint256 shares = 36086956521739130434; // From previous test
        uint256 assetPerShare = 2.3e6; // 2.3 USDC per share

        uint256 assets = ShareMath.sharesToAsset(
            shares,
            assetPerShare,
            DECIMALS_18
        );

        // Should be approximately 83 USDC
        assertApproxEqAbs(assets, 83e6, 1, "Should convert back to ~83 USDC");
    }

    /**
     * @notice Test that sharesToAsset reverts with invalid price
     */
    function test_sharesToAssetRevertsWithPlaceholder() public {
        uint256 shares = 10e18;
        uint256 invalidPrice = 1;

        vm.expectRevert(abi.encodeWithSignature("InvalidAssetPerShare()"));
        wrapper.sharesToAsset(shares, invalidPrice, DECIMALS_18);
    }

    // #############################################
    // GET SHARES FROM RECEIPT TESTS
    // #############################################

    /**
     * @notice Test extracting shares from receipt with no unclaimed shares
     */
    function test_getSharesFromReceiptNoUnclaimed() public {
        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: 1,
            amount: 100e6, // 100 USDC
            unclaimedShares: 0
        });

        uint256 currentRound = 2;
        uint256 assetPerShare = 1e6; // 1 USDC per share

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        // 100 USDC / 1 USDC per share = 100 shares
        assertEq(shares, 100e18, "Should calculate shares from deposit amount only");
    }

    /**
     * @notice Test that no shares are calculated when receipt round matches current round
     */
    function test_getSharesFromReceiptSameRound() public {
        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: 2,
            amount: 100e6,
            unclaimedShares: 0
        });

        uint256 currentRound = 2;
        uint256 assetPerShare = 1e6;

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        assertEq(shares, 0, "Should return 0 when round matches (not yet rolled)");
    }

    /**
     * @notice Test share calculation combines converted assets and existing unclaimed shares
     */
    function test_getSharesFromReceiptClean() public {
        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: 1,
            amount: 50e6, // 50 USDC
            unclaimedShares: 25e18 // 25 existing shares
        });

        uint256 currentRound = 2;
        uint256 assetPerShare = 1e6; // 1 USDC per share

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        // 50 USDC / 1 USDC per share + 25 existing = 75 shares
        assertEq(shares, 75e18, "Should combine converted and unclaimed shares");
    }

    /**
     * @notice Test receipt share extraction with fractional conversion
     */
    function test_getSharesFromReceiptDirty() public {
        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: 1,
            amount: 83e6, // 83 USDC
            unclaimedShares: 10e18 // 10 existing shares
        });

        uint256 currentRound = 2;
        uint256 assetPerShare = 2.3e6; // 2.3 USDC per share

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        // 83 / 2.3 = 36.086956521739130434 + 10 = 46.086956521739130434
        uint256 expected = 46086956521739130434;
        assertEq(shares, expected, "Should handle fractional conversion with unclaimed shares");
    }

    /**
     * @notice Test receipt with round 0 (initial state)
     */
    function test_getSharesFromReceiptRoundZero() public {
        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: 0,
            amount: 100e6,
            unclaimedShares: 0
        });

        uint256 currentRound = 1;
        uint256 assetPerShare = 1e6;

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        assertEq(shares, 0, "Should return 0 for round 0 receipt");
    }

    // #############################################
    // PRICE PER SHARE TESTS
    // #############################################

    /**
     * @notice Test price calculation with no existing supply (initial state)
     */
    function test_pricePerShareInitial() public {
        uint256 totalSupply = 0;
        uint256 totalBalance = 0;
        uint256 pendingAmount = 100e6;

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        assertEq(price, 1e18, "Initial price should be 1:1 (1e18)");
    }

    /**
     * @notice Test price calculation with existing supply
     */
    function test_pricePerShareWithSupply() public {
        uint256 totalSupply = 100e18; // 100 shares
        uint256 totalBalance = 110e6; // 110 USDC (10% yield)
        uint256 pendingAmount = 10e6; // 10 USDC pending

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        // (110 - 10) / 100 = 1.0 USDC per share
        assertEq(price, 1e6, "Price should be 1.0 USDC per share");
    }

    /**
     * @notice Test price calculation with positive yield
     */
    function test_pricePerShareWithYield() public {
        uint256 totalSupply = 100e18; // 100 shares
        uint256 totalBalance = 120e6; // 120 USDC
        uint256 pendingAmount = 0;

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        // 120 / 100 = 1.2 USDC per share
        assertEq(price, 1.2e6, "Price should reflect 20% yield");
    }

    /**
     * @notice Test price calculation with negative yield (loss)
     */
    function test_pricePerShareWithLoss() public {
        uint256 totalSupply = 100e18; // 100 shares
        uint256 totalBalance = 80e6; // 80 USDC (20% loss)
        uint256 pendingAmount = 0;

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        // 80 / 100 = 0.8 USDC per share
        assertEq(price, 0.8e6, "Price should reflect 20% loss");
    }

    /**
     * @notice Test price calculation with pending deposits
     */
    function test_pricePerShareExcludesPending() public {
        uint256 totalSupply = 100e18; // 100 shares
        uint256 totalBalance = 150e6; // 150 USDC total
        uint256 pendingAmount = 50e6; // 50 USDC pending (not yet converted to shares)

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        // (150 - 50) / 100 = 1.0 USDC per share (pending excluded from price calc)
        assertEq(price, 1e6, "Price should exclude pending deposits");
    }

    // #############################################
    // ASSERTION HELPER TESTS
    // #############################################

    /**
     * @notice Test uint104 assertion with valid value
     */
    function test_assertUint104Valid() public {
        uint256 validAmount = type(uint104).max;
        ShareMath.assertUint104(validAmount); // Should not revert
    }

    /**
     * @notice Test uint104 assertion with overflow
     */
    function test_assertUint104Overflow() public {
        uint256 overflowAmount = uint256(type(uint104).max) + 1;

        vm.expectRevert(abi.encodeWithSignature("Overflow104()"));
        wrapper.assertUint104(overflowAmount);
    }

    /**
     * @notice Test uint128 assertion with valid value
     */
    function test_assertUint128Valid() public {
        uint256 validAmount = type(uint128).max;
        ShareMath.assertUint128(validAmount); // Should not revert
    }

    /**
     * @notice Test uint128 assertion with overflow
     */
    function test_assertUint128Overflow() public {
        uint256 overflowAmount = uint256(type(uint128).max) + 1;

        vm.expectRevert(abi.encodeWithSignature("Overflow128()"));
        wrapper.assertUint128(overflowAmount);
    }

    // #############################################
    // FUZZ TESTS
    // #############################################

    /**
     * @notice Fuzz test: assetToShares -> sharesToAsset should round-trip
     */
    function testFuzz_assetSharesRoundTrip(uint256 assetAmount, uint256 assetPerShare) public {
        // Bound inputs to reasonable ranges
        assetAmount = bound(assetAmount, 1e6, 1_000_000e6); // 1 to 1M USDC
        assetPerShare = bound(assetPerShare, 0.01e6, 100e6); // 0.01 to 100 USDC per share

        // Ensure assetPerShare is not placeholder
        vm.assume(assetPerShare > 1);

        uint256 shares = ShareMath.assetToShares(assetAmount, assetPerShare, DECIMALS_18);
        uint256 assetsBack = ShareMath.sharesToAsset(shares, assetPerShare, DECIMALS_18);

        // Allow small rounding difference
        assertApproxEqAbs(assetsBack, assetAmount, 100, "Round-trip should preserve value");
    }

    /**
     * @notice Fuzz test: price calculation should never be zero with supply
     */
    function testFuzz_priceNeverZeroWithSupply(
        uint256 totalSupply,
        uint256 totalBalance,
        uint256 pendingAmount
    ) public {
        // Bound to realistic ranges that ensure price won't round to 0
        // With shares in 18 decimals and assets in 6 decimals, we need sufficient asset value
        totalSupply = bound(totalSupply, 1e18, 1_000_000e18); // 1 to 1M shares (18 decimals)
        totalBalance = bound(totalBalance, 1e6, 1_000_000e6); // At least 1 USDC total
        pendingAmount = bound(pendingAmount, 0, totalBalance - 1e6); // Leave at least 1 USDC non-pending

        uint256 price = ShareMath.pricePerShare(
            totalSupply,
            totalBalance,
            pendingAmount,
            DECIMALS_18
        );

        assertGt(price, 0, "Price should never be zero with supply");
    }

    /**
     * @notice Fuzz test: getSharesFromReceipt should handle various states
     */
    function testFuzz_getSharesFromReceipt(
        uint16 receiptRound,
        uint104 amount,
        uint128 unclaimedShares,
        uint16 currentRound,
        uint256 assetPerShare
    ) public {
        receiptRound = uint16(bound(receiptRound, 0, 100));
        currentRound = uint16(bound(currentRound, receiptRound, 200));
        assetPerShare = bound(assetPerShare, 0.01e6, 100e6);

        vm.assume(assetPerShare > 1);
        vm.assume(amount > 0);

        Vault.StakeReceipt memory receipt = Vault.StakeReceipt({
            round: receiptRound,
            amount: amount,
            unclaimedShares: unclaimedShares
        });

        uint256 shares = receipt.getSharesFromReceipt(
            currentRound,
            assetPerShare,
            DECIMALS_18
        );

        // Shares should be >= unclaimed shares (may be more if amount > 0 and round < current)
        assertGe(shares, unclaimedShares, "Shares should be at least unclaimed amount");
    }
}
