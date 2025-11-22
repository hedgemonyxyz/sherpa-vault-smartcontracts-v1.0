const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: path.join(__dirname, "../../.env") });

/**
 * Set Vault Supply Cap - Universal Chain
 *
 * Updates the supply cap on a specific chain's vault
 *
 * Usage:
 *   node scripts/core/setVaultCap-universalChain.js <chain> <newCap>
 *
 * Examples:
 *   node scripts/core/setVaultCap-universalChain.js sepolia 500000
 *   node scripts/core/setVaultCap-universalChain.js base 1000000
 *   node scripts/core/setVaultCap-universalChain.js arbitrum 750000
 *
 * Arguments:
 *   chain: sepolia, base, or arbitrum
 *   newCap: New cap amount in USDC (e.g., 500000 for 500k USDC)
 */

// Load deployment configuration
const deployment = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../deployments/deployment.json"), "utf8")
);

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
  const chain = process.argv[2]?.toLowerCase();
  const newCapArg = process.argv[3];

  // Validate arguments
  if (!chain || !newCapArg) {
    console.error("Usage: node scripts/core/setVaultCap-universalChain.js <chain> <newCap>");
    console.error("");
    console.error("Arguments:");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("  newCap: New cap amount in USDC (e.g., 500000 for 500k USDC)");
    console.error("");
    console.error("Examples:");
    console.error("  node scripts/core/setVaultCap-universalChain.js sepolia 500000");
    console.error("  node scripts/core/setVaultCap-universalChain.js base 1000000");
    console.error("  node scripts/core/setVaultCap-universalChain.js arbitrum 750000");
    process.exit(1);
  }

  if (!RPC_URLS[chain]) {
    console.error(`❌ Invalid chain. Supported chains: ${Object.keys(RPC_URLS).join(", ")}`);
    process.exit(1);
  }

  const newCapUSDC = parseFloat(newCapArg);
  if (isNaN(newCapUSDC) || newCapUSDC <= 0) {
    console.error("❌ Invalid cap amount. Must be a positive number.");
    process.exit(1);
  }

  const newCapWithDecimals = ethers.utils.parseUnits(newCapUSDC.toString(), 6); // USDC has 6 decimals

  console.log("=".repeat(80));
  console.log("SET VAULT SUPPLY CAP");
  console.log("=".repeat(80));
  console.log();
  console.log(`Chain: ${chain.toUpperCase()}`);
  console.log(`New Cap: ${newCapUSDC.toLocaleString()} USDC`);
  console.log();

  // Load deployment
  if (!deployment[chain]) {
    console.error(`❌ Chain '${chain}' not found in deployment.json`);
    process.exit(1);
  }

  const vaultAddress = deployment[chain].vault;

  console.log(`Vault Address: ${vaultAddress}`);
  console.log();

  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(RPC_URLS[chain]);
  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY, provider);

  console.log(`Owner Address: ${wallet.address}`);
  const ethBalance = await provider.getBalance(wallet.address);
  console.log(`ETH Balance: ${ethers.utils.formatEther(ethBalance)} ETH`);
  console.log();

  // Load contract ABI
  const vaultABI = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  ).abi;

  const vaultContract = new ethers.Contract(vaultAddress, vaultABI, wallet);

  // =================================================================
  // STEP 1: Check current cap
  // =================================================================

  console.log("📍 STEP 1: Checking Current Cap");
  console.log("-".repeat(80));

  const currentCap = await vaultContract.cap();
  const totalStaked = await vaultContract.totalStaked();

  console.log(`Current Cap: ${ethers.utils.formatUnits(currentCap, 6)} USDC`);
  console.log(`Total Staked: ${ethers.utils.formatUnits(totalStaked, 6)} USDC`);
  console.log(`Available: ${ethers.utils.formatUnits(currentCap.sub(totalStaked), 6)} USDC`);
  console.log();

  // Check if new cap is valid
  if (newCapWithDecimals.lte(currentCap)) {
    console.log(`⚠️  Warning: New cap (${newCapUSDC.toLocaleString()}) is not greater than current cap (${ethers.utils.formatUnits(currentCap, 6)})`);
    console.log(`   This will DECREASE the cap.`);
    console.log();
  }

  if (newCapWithDecimals.lt(totalStaked)) {
    console.error(`❌ Error: New cap (${newCapUSDC.toLocaleString()}) is less than current total staked (${ethers.utils.formatUnits(totalStaked, 6)})`);
    console.error(`   Cannot set cap below current usage.`);
    process.exit(1);
  }

  // =================================================================
  // STEP 2: Set new cap
  // =================================================================

  console.log("📍 STEP 2: Setting New Cap");
  console.log("-".repeat(80));

  console.log(`Setting cap to ${newCapUSDC.toLocaleString()} USDC...`);
  const tx = await vaultContract.setCap(newCapWithDecimals);
  console.log(`  Tx hash: ${tx.hash}`);
  console.log(`  Explorer: ${EXPLORERS[chain]}/tx/${tx.hash}`);

  const receipt = await tx.wait();
  console.log(`  ✅ Transaction confirmed in block ${receipt.blockNumber}`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
  console.log();

  // =================================================================
  // STEP 3: Verify new cap
  // =================================================================

  console.log("📍 STEP 3: Verifying New Cap");
  console.log("-".repeat(80));

  const updatedCap = await vaultContract.cap();
  const updatedTotalStaked = await vaultContract.totalStaked();

  console.log(`New Cap: ${ethers.utils.formatUnits(updatedCap, 6)} USDC`);
  console.log(`Total Staked: ${ethers.utils.formatUnits(updatedTotalStaked, 6)} USDC`);
  console.log(`Available: ${ethers.utils.formatUnits(updatedCap.sub(updatedTotalStaked), 6)} USDC`);
  console.log();

  if (updatedCap.eq(newCapWithDecimals)) {
    console.log("✅ Cap updated successfully!");
  } else {
    console.log("❌ Warning: Cap mismatch!");
    console.log(`   Expected: ${ethers.utils.formatUnits(newCapWithDecimals, 6)}`);
    console.log(`   Actual: ${ethers.utils.formatUnits(updatedCap, 6)}`);
  }
  console.log();

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(80));
  console.log("✅ CAP UPDATE COMPLETE!");
  console.log("=".repeat(80));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${tx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  Chain: ${chain.toUpperCase()}`);
  console.log(`  Vault: ${vaultAddress}`);
  console.log(`  Previous Cap: ${ethers.utils.formatUnits(currentCap, 6)} USDC`);
  console.log(`  New Cap: ${ethers.utils.formatUnits(updatedCap, 6)} USDC`);
  console.log(`  Change: ${ethers.utils.formatUnits(updatedCap.sub(currentCap), 6)} USDC`);
  console.log(`  Available for deposits: ${ethers.utils.formatUnits(updatedCap.sub(updatedTotalStaked), 6)} USDC`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ CAP UPDATE FAILED:");
    console.error(error);
    process.exit(1);
  });
