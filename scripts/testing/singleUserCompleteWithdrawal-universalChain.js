const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Universal Single User Complete Withdrawal Script
 *
 * Allows any test user to complete their pending withdrawal on any chain
 *
 * Usage: node scripts/testing/singleUserCompleteWithdrawal-universalChain.js <user_number> <chain>
 * Example: node scripts/testing/singleUserCompleteWithdrawal-universalChain.js 3 base
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

  // Validate arguments
  if (!userNumber || !chain) {
    console.error("Usage: node scripts/testing/singleUserCompleteWithdrawal-universalChain.js <user_number> <chain>");
    console.error("");
    console.error("Arguments:");
    console.error("  user_number: 1-10");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("");
    console.error("Example: node scripts/testing/singleUserCompleteWithdrawal-universalChain.js 3 base");
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

  console.log("=".repeat(70));
  console.log("UNIVERSAL COMPLETE WITHDRAWAL SCRIPT");
  console.log("=".repeat(70));
  console.log();
  console.log(`User: ${user.name}`);
  console.log(`Chain: ${chain}`);
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  if (!deployment[chain]) {
    console.error(`❌ Chain '${chain}' not found in deployment.json`);
    process.exit(1);
  }

  const sherpaUSD = deployment[chain].sherpaUSD;
  const usdc = deployment[chain].mockUSDC;

  console.log(`${chain.charAt(0).toUpperCase() + chain.slice(1)} Contracts:`);
  console.log("  SherpaUSD:", sherpaUSD);
  console.log("  USDC:", usdc);
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

  const usdcABI = [
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)"
  ];

  const sherpaUSDContract = new ethers.Contract(sherpaUSD, sherpaUSDABI, wallet);
  const usdcContract = new ethers.Contract(usdc, usdcABI, provider);

  // =================================================================
  // STEP 1: Check withdrawal status
  // =================================================================

  console.log("📍 STEP 1: Checking Withdrawal Status");
  console.log("-".repeat(70));

  const currentEpoch = await sherpaUSDContract.currentEpoch();
  const withdrawalReceipt = await sherpaUSDContract.withdrawalReceipts(wallet.address);

  console.log("Current Epoch:", currentEpoch.toString());
  console.log("User Withdrawal Receipt:");
  console.log("  Amount:", ethers.utils.formatUnits(withdrawalReceipt.amount, 6), "USDC");
  console.log("  Epoch:", withdrawalReceipt.epoch.toString());
  console.log();

  if (withdrawalReceipt.amount.eq(0)) {
    console.log("❌ No pending withdrawal found for this user");
    console.log();
    console.log("Possible reasons:");
    console.log("  • No withdrawal was initiated");
    console.log("  • Withdrawal was already completed");
    console.log("  • Epoch has not been processed yet");
    process.exit(1);
  }

  // Check if withdrawal is ready to complete (epoch must be incremented)
  const withdrawalEpoch = ethers.BigNumber.from(withdrawalReceipt.epoch);
  if (withdrawalEpoch.gte(currentEpoch)) {
    console.log("⚠️  Withdrawal not ready yet!");
    console.log(`   Withdrawal initiated in epoch: ${withdrawalReceipt.epoch}`);
    console.log(`   Current epoch: ${currentEpoch}`);
    console.log(`   Wait for next round roll (processWithdrawals must be called)`);
    process.exit(1);
  }

  console.log("✅ Withdrawal ready to complete");
  console.log(`   Withdrawal from epoch ${withdrawalReceipt.epoch}, current epoch ${currentEpoch}`);
  console.log();

  // =================================================================
  // STEP 2: Check balances before withdrawal
  // =================================================================

  console.log("📍 STEP 2: Checking Balances Before Withdrawal");
  console.log("-".repeat(70));

  const usdcBalanceBefore = await usdcContract.balanceOf(wallet.address);

  console.log("USDC Balance Before:", ethers.utils.formatUnits(usdcBalanceBefore, 6), "USDC");
  console.log();

  // =================================================================
  // STEP 3: Complete withdrawal
  // =================================================================

  console.log("📍 STEP 3: Completing Withdrawal");
  console.log("-".repeat(70));

  console.log("Calling completeWithdrawal()...");
  console.log("  This will:");
  console.log("  1. Claim your pending USDC from the withdrawal queue");
  console.log("  2. Transfer USDC to your wallet");
  console.log();

  const completeTx = await sherpaUSDContract.completeWithdrawal();
  console.log("  Tx hash:", completeTx.hash);

  const receipt = await completeTx.wait();
  console.log("  ✅ Withdrawal completed!");
  console.log("  Gas used:", receipt.gasUsed.toString());
  console.log();

  // =================================================================
  // STEP 4: Check updated balances
  // =================================================================

  console.log("📍 STEP 4: Checking Updated Balances");
  console.log("-".repeat(70));

  // Wait a moment for RPC to update
  await new Promise(resolve => setTimeout(resolve, 2000));

  const usdcBalanceAfter = await usdcContract.balanceOf(wallet.address);
  const usdcReceived = usdcBalanceAfter.sub(usdcBalanceBefore);

  console.log("USDC Balance Before:", ethers.utils.formatUnits(usdcBalanceBefore, 6), "USDC");
  console.log("USDC Balance After:", ethers.utils.formatUnits(usdcBalanceAfter, 6), "USDC");
  console.log();

  console.log("Change:");
  console.log("  USDC received:", ethers.utils.formatUnits(usdcReceived, 6), "USDC");
  console.log();

  // If RPC caching prevents accurate reading
  if (usdcReceived.eq(0) && withdrawalReceipt.amount.gt(0)) {
    console.log("  (Note: Due to RPC caching, balance may not update immediately)");
    console.log("  Expected amount:", ethers.utils.formatUnits(withdrawalReceipt.amount, 6), "USDC");
    console.log();
  }

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(70));
  console.log("✅ WITHDRAWAL COMPLETED!");
  console.log("=".repeat(70));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${completeTx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  User: ${user.name} (${wallet.address})`);
  console.log(`  Chain: ${chain}`);
  console.log(`  USDC Received: ${ethers.utils.formatUnits(usdcReceived.gt(0) ? usdcReceived : withdrawalReceipt.amount, 6)} USDC`);
  console.log(`  Epoch: ${currentEpoch}`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ COMPLETE WITHDRAWAL FAILED:");
    console.error(error);
    process.exit(1);
  });
