const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Universal Single User ClaimShares Script
 *
 * Allows any test user (1-5) to claimShares their shUSD shares on any chain
 *
 * Usage: node scripts/testing/singleUserClaimShares-universalChain.js <user_number> <chain>
 * Example: node scripts/testing/singleUserClaimShares-universalChain.js 1 arbitrum
 *
 * Supported chains: sepolia, base, arbitrum
 * Supported users: 1, 2, 3, 4, 5
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
    console.error("Usage: node scripts/testing/singleUserClaimShares-universalChain.js <user_number> <chain>");
    console.error("");
    console.error("Arguments:");
    console.error("  user_number: 1, 2, 3, 4, or 5");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("");
    console.error("Example: node scripts/testing/singleUserClaimShares-universalChain.js 1 arbitrum");
    process.exit(1);
  }

  if (userNumber < 1 || userNumber > 5) {
    console.error("❌ Invalid user number. Must be 1-5");
    process.exit(1);
  }

  if (!RPC_URLS[chain]) {
    console.error(`❌ Invalid chain. Supported chains: ${Object.keys(RPC_URLS).join(", ")}`);
    process.exit(1);
  }

  const user = getTestUser(userNumber);

  console.log("=".repeat(70));
  console.log("UNIVERSAL CLAIM SHARES SCRIPT");
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

  const vault = deployment[chain].vault;

  console.log(`${chain.charAt(0).toUpperCase() + chain.slice(1)} Contracts:`);
  console.log("  Vault:", vault);
  console.log();

  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(RPC_URLS[chain]);
  const wallet = new ethers.Wallet(user.key, provider);

  console.log("User Address:", wallet.address);
  const ethBalance = await provider.getBalance(wallet.address);
  console.log("ETH Balance:", ethers.utils.formatEther(ethBalance), "ETH");
  console.log();

  // Load contract ABI
  const vaultABI = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  ).abi;

  const vaultContract = new ethers.Contract(vault, vaultABI, wallet);

  // =================================================================
  // STEP 1: Check current state
  // =================================================================

  console.log("📍 STEP 1: Checking Current State");
  console.log("-".repeat(70));

  const [shUSDBalance, stakeReceipt, currentRound, currentRoundPrice] = await Promise.all([
    vaultContract.balanceOf(wallet.address),
    vaultContract.stakeReceipts(wallet.address),
    vaultContract.round(),
    vaultContract.roundPricePerShare(await vaultContract.round())
  ]);

  console.log("Current shUSD Balance:", ethers.utils.formatUnits(shUSDBalance, 6), "shUSD");
  console.log("Current Round:", currentRound.toString());
  console.log("Current Price per Share:", ethers.utils.formatUnits(currentRoundPrice, 6), "USDC per shUSD");
  console.log();

  console.log("Stake Receipt:");
  console.log("  Round:", stakeReceipt.round.toString());
  console.log("  Amount:", ethers.utils.formatUnits(stakeReceipt.amount, 6), "USDC");
  console.log("  UnclaimSharesed Shares:", ethers.utils.formatUnits(stakeReceipt.unclaimSharesedShares, 6), "shUSD");
  console.log();

  if (stakeReceipt.unclaimSharesedShares.eq(0) && stakeReceipt.amount.eq(0)) {
    console.log("ℹ️  No stake found for this user");
    console.log();
    console.log("This user has not staked any funds yet.");
    console.log();
    process.exit(0);
  }

  if (stakeReceipt.unclaimSharesedShares.eq(0) && stakeReceipt.amount.gt(0)) {
    console.log("ℹ️  Stake found but shares not yet calculated in receipt");
    console.log();
    console.log("The contract will calculate shares when maxClaimShares() is called.");
    console.log("This is normal for stakes from previous rounds.");
    console.log();
  }

  // Calculate claimSharesable shares
  const receiptRoundPrice = await vaultContract.roundPricePerShare(stakeReceipt.round);
  console.log(`Receipt Round ${stakeReceipt.round} Price:`, ethers.utils.formatUnits(receiptRoundPrice, 6), "USDC per shUSD");
  console.log();

  // =================================================================
  // STEP 2: Execute maxClaimShares
  // =================================================================

  console.log("📍 STEP 2: ClaimSharesing All Available Shares");
  console.log("-".repeat(70));

  console.log(`Calling maxClaimShares()...`);
  console.log(`This will claimShares ${ethers.utils.formatUnits(stakeReceipt.unclaimSharesedShares, 6)} shUSD shares`);
  console.log();

  const claimSharesTx = await vaultContract.maxClaimShares();
  console.log("  Tx hash:", claimSharesTx.hash);

  const receipt = await claimSharesTx.wait();
  console.log("  ✅ ClaimShares successful!");
  console.log("  Gas used:", receipt.gasUsed.toString());
  console.log();

  // =================================================================
  // STEP 3: Check updated state
  // =================================================================

  console.log("📍 STEP 3: Checking Updated State");
  console.log("-".repeat(70));

  const [newShUSDBalance, newStakeReceipt] = await Promise.all([
    vaultContract.balanceOf(wallet.address),
    vaultContract.stakeReceipts(wallet.address)
  ]);

  console.log("New shUSD Balance:", ethers.utils.formatUnits(newShUSDBalance, 6), "shUSD");
  console.log();

  console.log("New Stake Receipt:");
  console.log("  Round:", newStakeReceipt.round.toString());
  console.log("  Amount:", ethers.utils.formatUnits(newStakeReceipt.amount, 6), "USDC");
  console.log("  UnclaimSharesed Shares:", ethers.utils.formatUnits(newStakeReceipt.unclaimSharesedShares, 6), "shUSD");
  console.log();

  const sharesClaimSharesed = newShUSDBalance.sub(shUSDBalance);

  console.log("Change:");
  console.log("  shUSD shares received:", ethers.utils.formatUnits(sharesClaimSharesed, 6), "shUSD");
  console.log();

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(70));
  console.log("✅ CLAIM SHARES COMPLETE!");
  console.log("=".repeat(70));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${claimSharesTx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  User: ${user.name} (${wallet.address})`);
  console.log(`  Chain: ${chain}`);
  console.log(`  Shares ClaimSharesed: ${ethers.utils.formatUnits(sharesClaimSharesed, 6)} shUSD`);
  console.log(`  New Balance: ${ethers.utils.formatUnits(newShUSDBalance, 6)} shUSD`);
  console.log();
  console.log("Next Steps:");
  console.log("  • User can now unstake and initiate withdrawal if desired");
  console.log("  • Or hold shUSD shares to continue earning yield");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ CLAIM SHARES FAILED:");
    console.error(error);
    process.exit(1);
  });
