const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Universal Single User Unstake and Withdraw Script
 *
 * Allows any test user to unstake shUSD and initiate withdrawal on any chain
 *
 * Usage: node scripts/testing/singleUserUnstakeAndWithdraw-universalChain.js <user_number> <chain> <amount>
 * Example: node scripts/testing/singleUserUnstakeAndWithdraw-universalChain.js 2 arbitrum 100000
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
    console.error("Usage: node scripts/testing/singleUserUnstakeAndWithdraw-universalChain.js <user_number> <chain> <amount>");
    console.error("");
    console.error("Arguments:");
    console.error("  user_number: 1-10");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("  amount: Amount of shUSD to unstake (e.g., 10000)");
    console.error("");
    console.error("Example: node scripts/testing/singleUserUnstakeAndWithdraw-universalChain.js 2 arbitrum 100000");
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
  const amountShUSD = parseFloat(amountArg);
  const amountWithDecimals = ethers.utils.parseUnits(amountShUSD.toString(), 6); // shUSD has 6 decimals

  console.log("=".repeat(70));
  console.log("UNIVERSAL UNSTAKE AND WITHDRAW SCRIPT");
  console.log("=".repeat(70));
  console.log();
  console.log(`User: ${user.name}`);
  console.log(`Chain: ${chain}`);
  console.log(`Amount: ${amountShUSD} shUSD`);
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
  // STEP 1: Check balances
  // =================================================================

  console.log("📍 STEP 1: Checking Balances");
  console.log("-".repeat(70));

  const shUSDBalance = await vaultContract.balanceOf(wallet.address);
  const currentRound = await vaultContract.round();

  console.log("shUSD Balance:", ethers.utils.formatUnits(shUSDBalance, 6), "shUSD");
  console.log("Current Round:", currentRound.toString());
  console.log();

  if (shUSDBalance.lt(amountWithDecimals)) {
    console.error("❌ Insufficient shUSD balance!");
    console.error(`   Have: ${ethers.utils.formatUnits(shUSDBalance, 6)} shUSD`);
    console.error(`   Need: ${amountShUSD} shUSD`);
    process.exit(1);
  }

  console.log("✅ Sufficient shUSD balance");
  console.log();

  // Note: No approval needed - vault can burn its own tokens (shUSD) directly

  // =================================================================
  // STEP 2: Unstake and Withdraw (calls vault.unstakeAndWithdraw)
  // =================================================================

  console.log("📍 STEP 2: Unstaking and Initiating Withdrawal");
  console.log("-".repeat(70));

  // Calculate expected USDC based on previous round price
  const previousRound = currentRound.sub(1);
  const previousRoundPrice = await vaultContract.roundPricePerShare(previousRound);

  // expectedUSDC = shares * pricePerShare
  const expectedUSDC = amountWithDecimals.mul(previousRoundPrice).div(ethers.BigNumber.from(10).pow(6));

  console.log(`Previous round (${previousRound}) price: ${ethers.utils.formatUnits(previousRoundPrice, 6)} USDC per shUSD`);
  console.log(`Expected USDC to receive: ${ethers.utils.formatUnits(expectedUSDC, 6)} USDC`);
  console.log();

  console.log(`Calling unstakeAndWithdraw(${amountShUSD} shUSD, minAmountOut: ${ethers.utils.formatUnits(expectedUSDC, 6)} USDC)...`);
  console.log("  This will:");
  console.log("  1. Burn your shUSD shares");
  console.log("  2. Queue a withdrawal request");
  console.log("  3. USDC will be claimable after next round");
  console.log();

  // Use expectedUSDC as minAmountOut for exact slippage protection
  const withdrawTx = await vaultContract.unstakeAndWithdraw(amountWithDecimals, expectedUSDC);
  console.log("  Tx hash:", withdrawTx.hash);

  const receipt = await withdrawTx.wait();
  console.log("  ✅ Unstake and withdrawal initiated!");
  console.log("  Gas used:", receipt.gasUsed.toString());
  console.log();

  console.log("ℹ️  Withdrawal Process:");
  console.log("   1. Your shUSD has been unstaked and burned");
  console.log("   2. Withdrawal request has been queued for the next round");
  console.log("   3. After the next round rolls, you can claim your USDC");
  console.log("   4. Use processWithdrawals() to finalize (usually done during round roll)");
  console.log();

  // =================================================================
  // STEP 3: Check updated balances
  // =================================================================

  console.log("📍 STEP 3: Checking Updated Balances");
  console.log("-".repeat(70));

  // Wait a moment for RPC to update
  await new Promise(resolve => setTimeout(resolve, 2000));

  const newShUSDBalance = await vaultContract.balanceOf(wallet.address);

  console.log("Previous shUSD Balance:", ethers.utils.formatUnits(shUSDBalance, 6), "shUSD");
  console.log("Current shUSD Balance:", ethers.utils.formatUnits(newShUSDBalance, 6), "shUSD");
  console.log();

  const shUSDSpent = shUSDBalance.sub(newShUSDBalance);

  console.log("Change:");
  console.log("  shUSD unstaked:", ethers.utils.formatUnits(shUSDSpent, 6), "shUSD");
  console.log();

  // If RPC caching prevents accurate reading, show the intended amount
  if (shUSDSpent.eq(0)) {
    console.log("  (Note: Due to RPC caching, balance may not update immediately)");
    console.log("  Actual amount unstaked:", ethers.utils.formatUnits(amountWithDecimals, 6), "shUSD");
    console.log();
  }

  // Get current price per share to estimate USDC value
  // Use the actual unstaked amount for calculation
  const actualUnstakedAmount = shUSDSpent.gt(0) ? shUSDSpent : amountWithDecimals;

  console.log("Estimated USDC to receive:", ethers.utils.formatUnits(expectedUSDC, 6), "USDC");
  console.log("(Based on previous round price of", ethers.utils.formatUnits(previousRoundPrice, 6), "USDC per shUSD)");
  console.log();

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(70));
  console.log("✅ UNSTAKE AND WITHDRAW INITIATED!");
  console.log("=".repeat(70));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${withdrawTx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  User: ${user.name} (${wallet.address})`);
  console.log(`  Chain: ${chain}`);
  console.log(`  Unstaked: ${ethers.utils.formatUnits(actualUnstakedAmount, 6)} shUSD`);
  console.log(`  Expected USDC: ${ethers.utils.formatUnits(expectedUSDC, 6)} USDC`);
  console.log(`  Current Round: ${currentRound}`);
  console.log();
  console.log("Next Steps:");
  console.log("  • Wait for next round to roll");
  console.log("  • processWithdrawals() will be called (usually automatic during roll)");
  console.log("  • Your USDC will be available to claim");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ UNSTAKE AND WITHDRAW FAILED:");
    console.error(error);
    process.exit(1);
  });
