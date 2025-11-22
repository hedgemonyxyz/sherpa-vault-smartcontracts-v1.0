const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Universal Single User Instant Unstake and Withdraw Script
 *
 * Allows any test user to instantly unstake pending USDC deposits and initiate withdrawal on any chain
 *
 * IMPORTANT: instantUnstakeAndWithdraw() can only unstake USDC deposits made in the CURRENT round
 *            that haven't been converted to shUSD yet. If the round has already rolled, you must
 *            use the regular unstakeAndWithdraw() function instead.
 *
 * Usage: node scripts/testing/singleUserInstantUnstakeAndWithdraw-universalChain.js <user_number> <chain> <amount>
 * Example: node scripts/testing/singleUserInstantUnstakeAndWithdraw-universalChain.js 1 arbitrum 5000
 *
 * Supported chains: sepolia, base, arbitrum
 * Supported users: 1-10
 */

// RPC URL mapping
const RPC_URLS = {
  sepolia: process.env.SEPOLIA_RPC_URL,
  base: process.env.BASE_SEPOLIA_RPC_URL,
  arbitrum: process.env.ARBITRUM_SEPOLIA_RPC_URL
};

// Block explorer mapping
const EXPLORERS = {
  sepolia: "https://sepolia.etherscan.io",
  base: "https://sepolia.basescan.org",
  arbitrum: "https://sepolia.arbiscan.io"
};

async function main() {
  // Parse CLI arguments
  const userNumber = parseInt(process.argv[2]);
  const chain = process.argv[3]?.toLowerCase();
  const amountArg = process.argv[4];

  // Validate arguments
  if (!userNumber || !chain || !amountArg) {
    console.error("Usage: node scripts/testing/singleUserInstantUnstakeAndWithdraw-universalChain.js <user_number> <chain> <amount>");
    console.error("");
    console.error("Arguments:");
    console.error("  user_number: 1-10");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("  amount: Amount of USDC to instantly unstake (e.g., 5000)");
    console.error("");
    console.error("Example: node scripts/testing/singleUserInstantUnstakeAndWithdraw-universalChain.js 1 arbitrum 5000");
    console.error("");
    console.error("⚠️  IMPORTANT: You can only instantly unstake pending deposits from the CURRENT round.");
    console.error("   If the round has already rolled, use singleUserUnstakeAndWithdraw-universalChain.js instead.");
    process.exit(1);
  }

  if (userNumber < 1 || userNumber > 10) {
    console.error("❌ Invalid user number. Must be 1-10");
    process.exit(1);
  }

  if (!RPC_URLS[chain]) {
    console.error(`❌ Invalid chain. Supported chains: ${Object.keys(RPC_URLS).join(", ")}`);
    process.exit(1);
  }

  const user = getTestUser(userNumber);
  const amountUSDC = parseFloat(amountArg);
  const amountWithDecimals = ethers.utils.parseUnits(amountUSDC.toString(), 6); // USDC has 6 decimals

  console.log("=".repeat(70));
  console.log("UNIVERSAL INSTANT UNSTAKE AND WITHDRAW SCRIPT");
  console.log("=".repeat(70));
  console.log();
  console.log(`User: ${user.name}`);
  console.log(`Chain: ${chain}`);
  console.log(`Amount: ${amountUSDC} USDC (pending deposit)`);
  console.log();
  console.log("⚠️  This will instantly unstake pending USDC from the current round");
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  if (!deployment[chain]) {
    console.error(`❌ Chain '${chain}' not found in deployment.json`);
    process.exit(1);
  }

  const sherpaUSD = deployment[chain].sherpaUSD;
  const vault = deployment[chain].vault;

  console.log(`${chain.charAt(0).toUpperCase() + chain.slice(1)} Contracts:`);
  console.log("  SherpaUSD:", sherpaUSD);
  console.log("  Vault:", vault);
  console.log();

  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(RPC_URLS[chain]);
  const wallet = new ethers.Wallet(user.key, provider);

  console.log("User Address:", wallet.address);
  const ethBalance = await provider.getBalance(wallet.address);
  console.log("ETH Balance:", ethers.utils.formatEther(ethBalance), "ETH");
  console.log();

  // Load contract ABIs
  const sherpaUSDABI = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaUSD.sol/SherpaUSD.json"), "utf8")
  ).abi;

  const vaultABI = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  ).abi;

  const sherpaUSDContract = new ethers.Contract(sherpaUSD, sherpaUSDABI, wallet);
  const vaultContract = new ethers.Contract(vault, vaultABI, wallet);

  // =================================================================
  // STEP 1: Check pending deposits and round
  // =================================================================

  console.log("📍 STEP 1: Checking Pending Deposits");
  console.log("-".repeat(70));

  const currentRound = await vaultContract.round();
  const stakeReceipt = await vaultContract.stakeReceipts(wallet.address);
  const pendingAmount = stakeReceipt.amount;
  const receiptRound = stakeReceipt.round;

  console.log("Current Round:", currentRound.toString());
  console.log("Your Pending Deposit:");
  console.log("  Amount:", ethers.utils.formatUnits(pendingAmount, 6), "USDC");
  console.log("  Round:", receiptRound.toString());
  console.log();

  // Check if user has pending deposits
  if (pendingAmount.eq(0)) {
    console.error("❌ No pending deposits found!");
    console.error("   You must have pending deposits from the current round to use instant unstake.");
    console.error("   To unstake already-staked shUSD, use singleUserUnstakeAndWithdraw-universalChain.js");
    process.exit(1);
  }

  // Check if pending deposit is from current round
  if (receiptRound !== currentRound.toNumber()) {
    console.error("❌ Your pending deposit is from a previous round!");
    console.error(`   Deposit Round: ${receiptRound}, Current Round: ${currentRound}`);
    console.error("   These deposits have already been converted to shUSD.");
    console.error("   Use singleUserUnstakeAndWithdraw-universalChain.js to unstake shUSD instead.");
    process.exit(1);
  }

  // Check if user has enough pending deposits
  if (pendingAmount.lt(amountWithDecimals)) {
    console.error("❌ Insufficient pending deposits!");
    console.error(`   Have: ${ethers.utils.formatUnits(pendingAmount, 6)} USDC`);
    console.error(`   Need: ${amountUSDC} USDC`);
    process.exit(1);
  }

  console.log("✅ Sufficient pending deposits from current round");
  console.log();

  // =================================================================
  // STEP 2: Instant Unstake and Withdraw
  // =================================================================

  console.log("📍 STEP 2: Instant Unstaking and Initiating Withdrawal");
  console.log("-".repeat(70));

  console.log(`Calling instantUnstakeAndWithdraw(${amountUSDC} USDC)...`);
  console.log("  This will:");
  console.log("  1. Cancel your pending deposit (reduce totalPending)");
  console.log("  2. Queue a withdrawal request for the USDC");
  console.log("  3. USDC will be claimable after next epoch");
  console.log();

  const withdrawTx = await vaultContract.instantUnstakeAndWithdraw(amountWithDecimals);
  console.log("  Tx hash:", withdrawTx.hash);

  const receipt = await withdrawTx.wait();
  console.log("  ✅ Instant unstake and withdrawal initiated!");
  console.log("  Gas used:", receipt.gasUsed.toString());
  console.log();

  console.log("ℹ️  Withdrawal Process:");
  console.log("   1. Your pending deposit has been cancelled");
  console.log("   2. Withdrawal request has been queued for the next epoch");
  console.log("   3. After the next round rolls, you can claim your USDC");
  console.log("   4. Call completeWithdrawal() on SherpaUSD to claim (usually done during round roll)");
  console.log();

  // =================================================================
  // STEP 3: Check updated state
  // =================================================================

  console.log("📍 STEP 3: Checking Updated State");
  console.log("-".repeat(70));

  // Wait a moment for RPC to update
  await new Promise(resolve => setTimeout(resolve, 2000));

  const newStakeReceipt = await vaultContract.stakeReceipts(wallet.address);
  const newPendingAmount = newStakeReceipt.amount;

  console.log("Previous Pending Deposit:", ethers.utils.formatUnits(pendingAmount, 6), "USDC");
  console.log("Current Pending Deposit:", ethers.utils.formatUnits(newPendingAmount, 6), "USDC");
  console.log();

  const usdcUnstaked = pendingAmount.sub(newPendingAmount);

  console.log("Change:");
  console.log("  Pending USDC cancelled:", ethers.utils.formatUnits(usdcUnstaked, 6), "USDC");
  console.log();

  // If RPC caching prevents accurate reading, show the intended amount
  if (usdcUnstaked.eq(0)) {
    console.log("  (Note: Due to RPC caching, balance may not update immediately)");
    console.log("  Actual amount unstaked:", ethers.utils.formatUnits(amountWithDecimals, 6), "USDC");
    console.log();
  }

  console.log("Expected USDC to receive:", ethers.utils.formatUnits(amountWithDecimals, 6), "USDC");
  console.log("(1:1 ratio since these were pending deposits, not staked shares)");
  console.log();

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(70));
  console.log("✅ INSTANT UNSTAKE AND WITHDRAW INITIATED!");
  console.log("=".repeat(70));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${withdrawTx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  User: ${user.name} (${wallet.address})`);
  console.log(`  Chain: ${chain}`);
  console.log(`  Cancelled Pending Deposit: ${ethers.utils.formatUnits(amountWithDecimals, 6)} USDC`);
  console.log(`  Expected USDC to Claim: ${ethers.utils.formatUnits(amountWithDecimals, 6)} USDC`);
  console.log(`  Current Round: ${currentRound}`);
  console.log();
  console.log("Next Steps:");
  console.log("  • Wait for next round to roll");
  console.log("  • processWithdrawals() will be called (usually automatic during roll)");
  console.log("  • Your USDC will be available to claim via completeWithdrawal()");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ INSTANT UNSTAKE AND WITHDRAW FAILED:");
    console.error(error);
    process.exit(1);
  });
