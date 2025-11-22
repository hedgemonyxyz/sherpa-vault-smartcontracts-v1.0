const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Deployer Initialize Script
 *
 * Deposits 1 MockUSDC from deployer wallet to initialize vault
 * Follows same flow as singleUserDeposit-universalChain.js
 *
 * Usage: node scripts/system-deployment/deployerInitialize1usdc.js sepolia
 */

const RPC_URLS = {
  sepolia: process.env.SEPOLIA_RPC_URL,
  base: process.env.BASE_SEPOLIA_RPC_URL,
  arbitrum: process.env.ARBITRUM_SEPOLIA_RPC_URL
};

const EXPLORERS = {
  sepolia: "https://sepolia.etherscan.io",
  base: "https://sepolia.basescan.org",
  arbitrum: "https://sepolia.arbiscan.io"
};

async function main() {
  const chain = process.argv[2]?.toLowerCase() || "sepolia";
  const amountUSDC = 1; // Always 1 USDC for initialization
  const amountWithDecimals = ethers.utils.parseUnits(amountUSDC.toString(), 6);

  console.log("=".repeat(70));
  console.log("DEPLOYER INITIALIZE - 1 USDC DEPOSIT");
  console.log("=".repeat(70));
  console.log();
  console.log(`Chain: ${chain}`);
  console.log(`Amount: ${amountUSDC} USDC`);
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const mockUSDC = deployment[chain].mockUSDC;
  const sherpaUSD = deployment[chain].sherpaUSD;
  const vault = deployment[chain].vault;

  console.log(`${chain.charAt(0).toUpperCase() + chain.slice(1)} Contracts:`);
  console.log("  MockUSDC:", mockUSDC);
  console.log("  SherpaUSD:", sherpaUSD);
  console.log("  Vault:", vault);
  console.log();

  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(RPC_URLS[chain]);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  console.log("Deployer Address:", wallet.address);
  const ethBalance = await provider.getBalance(wallet.address);
  console.log("ETH Balance:", ethers.utils.formatEther(ethBalance), "ETH");
  console.log();

  // Load contract ABIs
  const mockUSDCABI = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)"
  ];

  const vaultABI = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  ).abi;

  const mockUSDCContract = new ethers.Contract(mockUSDC, mockUSDCABI, wallet);
  const vaultContract = new ethers.Contract(vault, vaultABI, wallet);

  // =================================================================
  // STEP 1: Check balances
  // =================================================================

  console.log("📍 STEP 1: Checking Balances");
  console.log("-".repeat(70));

  const usdcBalance = await mockUSDCContract.balanceOf(wallet.address);
  const shUSDBalance = await vaultContract.balanceOf(wallet.address);

  console.log("MockUSDC Balance:", ethers.utils.formatUnits(usdcBalance, 6), "USDC");
  console.log("shUSD Balance:", ethers.utils.formatUnits(shUSDBalance, 6), "shUSD");
  console.log();

  if (usdcBalance.lt(amountWithDecimals)) {
    console.error("❌ Insufficient MockUSDC balance!");
    console.error(`   Have: ${ethers.utils.formatUnits(usdcBalance, 6)} USDC`);
    console.error(`   Need: ${amountUSDC} USDC`);
    process.exit(1);
  }

  // Check if deposits are enabled
  const depositsEnabled = await vaultContract.depositsEnabled();
  if (!depositsEnabled) {
    console.error("❌ Deposits are currently disabled on the vault!");
    console.error("   Deposits may be paused during round rolling.");
    process.exit(1);
  }

  console.log("✅ Deposits are enabled");
  console.log();

  // =================================================================
  // STEP 2: Approve MockUSDC to SherpaUSD wrapper
  // =================================================================

  console.log("📍 STEP 2: Approving MockUSDC");
  console.log("-".repeat(70));

  const currentAllowance = await mockUSDCContract.allowance(wallet.address, sherpaUSD);
  console.log("Current allowance:", ethers.utils.formatUnits(currentAllowance, 6), "USDC");

  if (currentAllowance.lt(amountWithDecimals)) {
    console.log(`Approving ${amountUSDC} USDC for SherpaUSD...`);
    const approveTx = await mockUSDCContract.approve(sherpaUSD, amountWithDecimals);
    console.log("  Tx hash:", approveTx.hash);
    await approveTx.wait();
    console.log("  ✅ Approved");
  } else {
    console.log("  ℹ️  Already approved");
  }
  console.log();

  // =================================================================
  // STEP 3: Deposit and Stake
  // =================================================================

  console.log("📍 STEP 3: Depositing and Staking");
  console.log("-".repeat(70));

  console.log(`Calling depositAndStake(${amountUSDC} USDC)...`);
  const depositTx = await vaultContract.depositAndStake(amountWithDecimals, wallet.address);
  console.log("  Tx hash:", depositTx.hash);

  const receipt = await depositTx.wait();
  console.log("  ✅ Deposit successful!");
  console.log("  Gas used:", receipt.gasUsed.toString());
  console.log();

  // =================================================================
  // STEP 4: Check updated balances
  // =================================================================

  console.log("📍 STEP 4: Checking Updated Balances");
  console.log("-".repeat(70));

  const newUSDCBalance = await mockUSDCContract.balanceOf(wallet.address);
  const newShUSDBalance = await vaultContract.balanceOf(wallet.address);

  console.log("MockUSDC Balance:", ethers.utils.formatUnits(newUSDCBalance, 6), "USDC");
  console.log("shUSD Balance:", ethers.utils.formatUnits(newShUSDBalance, 6), "shUSD");
  console.log();

  const usdcSpent = usdcBalance.sub(newUSDCBalance);
  const shUSDReceived = newShUSDBalance.sub(shUSDBalance);

  console.log("Change:");
  console.log("  MockUSDC spent:", ethers.utils.formatUnits(usdcSpent, 6), "USDC");
  console.log("  shUSD received:", ethers.utils.formatUnits(shUSDReceived, 6), "shUSD");
  console.log();

  // Get current price per share
  const currentRound = await vaultContract.round();
  const pricePerShare = await vaultContract.roundPricePerShare(currentRound);
  console.log("Current round:", currentRound.toString());
  console.log("Current price per share:", ethers.utils.formatUnits(pricePerShare, 6), "USDC per shUSD");
  console.log();

  // =================================================================
  // SUMMARY
  // =================================================================

  console.log("=".repeat(70));
  console.log("✅ INITIALIZATION COMPLETE!");
  console.log("=".repeat(70));
  console.log();
  console.log("Transaction:", `${EXPLORERS[chain]}/tx/${depositTx.hash}`);
  console.log();
  console.log("Summary:");
  console.log(`  Deployer: ${wallet.address}`);
  console.log(`  Chain: ${chain}`);
  console.log(`  Deposited: ${ethers.utils.formatUnits(usdcSpent, 6)} USDC`);
  console.log(`  Received: ${ethers.utils.formatUnits(shUSDReceived, 6)} shUSD`);
  console.log(`  Current Round: ${currentRound}`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ ERROR:");
    console.error(error);
    process.exit(1);
  });
