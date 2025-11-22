const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { TEST_USERS } = require("../config/testUsers");
require("dotenv").config({ path: path.join(__dirname, "../../.env") });

/**
 * Simulate 10 User Deposits - Universal Chain
 *
 * This script deposits random amounts of MockUSDC from all 10 test users
 * on any chain with configurable deposit ranges.
 *
 * Usage:
 *   node simulate10userDeposits-universalChain.js <chain> <minAmount> <maxAmount>
 *
 * Examples:
 *   node simulate10userDeposits-universalChain.js sepolia 1000 50000
 *   node simulate10userDeposits-universalChain.js base 500 10000
 *   node simulate10userDeposits-universalChain.js arbitrum 100 5000
 *
 * Arguments:
 *   chain: sepolia, base, or arbitrum
 *   minAmount: Minimum deposit amount in USDC (integer, will add decimals)
 *   maxAmount: Maximum deposit amount in USDC (integer, will add decimals)
 */

// Load deployment configuration
const deployment = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../deployments/deployment.json"), "utf8")
);

// ABIs
const mockUSDCAbi = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

const vaultAbi = [
  "function depositAndStake(uint104 amount, address creditor) external",
  "function depositsEnabled() view returns (bool)"
];

/**
 * Generate random deposit amount with up to 6 decimals precision
 * @param {number} min - Minimum amount (without decimals)
 * @param {number} max - Maximum amount (without decimals)
 * @returns {BigNumber} Random amount with 6 decimals
 */
function getRandomDepositAmount(min, max) {
  // Generate random integer part
  const integerPart = Math.floor(Math.random() * (max - min + 1)) + min;

  // Generate random decimal part (0-999999 for 6 decimals)
  const decimalPart = Math.floor(Math.random() * 1000000);

  // Combine: (integerPart * 1e6) + decimalPart
  const totalMicroUnits = (integerPart * 1000000) + decimalPart;

  return ethers.BigNumber.from(totalMicroUnits);
}

/**
 * Get RPC URL for chain
 */
function getRpcUrl(chain) {
  if (chain === 'sepolia') {
    return process.env.SEPOLIA_RPC_URL;
  } else if (chain === 'base') {
    return process.env.BASE_SEPOLIA_RPC_URL;
  } else if (chain === 'arbitrum') {
    return process.env.ARBITRUM_SEPOLIA_RPC_URL;
  } else {
    throw new Error(`Unknown chain: ${chain}`);
  }
}

/**
 * Get chain explorer URL
 */
function getExplorerUrl(chain) {
  if (chain === 'sepolia') {
    return 'https://sepolia.etherscan.io/tx/';
  } else if (chain === 'base') {
    return 'https://sepolia.basescan.org/tx/';
  } else if (chain === 'arbitrum') {
    return 'https://sepolia.arbiscan.io/tx/';
  } else {
    return '';
  }
}

/**
 * Process a single user's deposit
 */
async function processUserDeposit(user, minAmount, maxAmount, vaultAddress, wrapperAddress, mockUSDCAddress, provider, chain) {
  console.log(`\n${"=".repeat(70)}`);
  console.log(`Processing: ${user.name}`);
  console.log(`${"=".repeat(70)}`);

  // Create wallet
  const wallet = new ethers.Wallet(user.key, provider);
  console.log(`Address: ${wallet.address}`);

  // Check ETH balance
  const ethBalance = await wallet.getBalance();
  console.log(`ETH Balance: ${ethers.utils.formatEther(ethBalance)} ETH`);

  if (ethBalance.eq(0)) {
    console.log("❌ User has no ETH for gas. Skipping...");
    return null;
  }

  // Create contract instances
  const mockUSDC = new ethers.Contract(mockUSDCAddress, mockUSDCAbi, wallet);
  const vault = new ethers.Contract(vaultAddress, vaultAbi, wallet);

  // Check MockUSDC balance
  const usdcBalance = await mockUSDC.balanceOf(wallet.address);
  console.log(`MockUSDC Balance: ${ethers.utils.formatUnits(usdcBalance, 6)} USDC`);

  if (usdcBalance.eq(0)) {
    console.log("❌ User has no MockUSDC. Skipping...");
    return null;
  }

  // Get random deposit amount with decimals
  const depositAmount = getRandomDepositAmount(minAmount, maxAmount);
  const depositAmountFormatted = ethers.utils.formatUnits(depositAmount, 6);

  // Cap at user's balance
  let actualDepositAmount = depositAmount;
  if (depositAmount.gt(usdcBalance)) {
    actualDepositAmount = usdcBalance;
    console.log(`⚠️  Intended amount (${depositAmountFormatted} USDC) exceeds balance`);
    console.log(`   Using full balance: ${ethers.utils.formatUnits(actualDepositAmount, 6)} USDC`);
  } else {
    console.log(`💰 Random Deposit Amount: ${depositAmountFormatted} USDC`);
  }

  // Check current allowance (for wrapper, not vault!)
  const currentAllowance = await mockUSDC.allowance(wallet.address, wrapperAddress);
  console.log(`Current Allowance: ${ethers.utils.formatUnits(currentAllowance, 6)} USDC`);

  // Approve if needed (approve wrapper, not vault!)
  if (currentAllowance.lt(actualDepositAmount)) {
    console.log(`\n📝 Approving MockUSDC for SherpaUSD wrapper...`);
    const approveTx = await mockUSDC.approve(wrapperAddress, ethers.constants.MaxUint256);
    console.log(`   Tx: ${approveTx.hash}`);
    console.log(`   Waiting for confirmation...`);
    await approveTx.wait();
    console.log(`   ✅ Approved!`);
  } else {
    console.log(`✅ Already has sufficient allowance`);
  }

  // Deposit
  console.log(`\n💸 Depositing ${ethers.utils.formatUnits(actualDepositAmount, 6)} USDC to vault...`);
  const depositTx = await vault.depositAndStake(
    actualDepositAmount,
    wallet.address
  );
  console.log(`   Tx: ${depositTx.hash}`);
  console.log(`   Waiting for confirmation...`);
  await depositTx.wait();
  console.log(`   ✅ Deposit successful!`);

  return {
    user: user.name,
    address: wallet.address,
    amount: ethers.utils.formatUnits(actualDepositAmount, 6),
    txHash: depositTx.hash
  };
}

async function main() {
  // Parse CLI arguments
  const chain = process.argv[2]?.toLowerCase();
  const minAmount = parseInt(process.argv[3]);
  const maxAmount = parseInt(process.argv[4]);

  if (!chain || isNaN(minAmount) || isNaN(maxAmount)) {
    console.error("Usage: node simulate10userDeposits-universalChain.js <chain> <minAmount> <maxAmount>");
    console.error("");
    console.error("Examples:");
    console.error("  node simulate10userDeposits-universalChain.js sepolia 1000 50000");
    console.error("  node simulate10userDeposits-universalChain.js base 500 10000");
    console.error("  node simulate10userDeposits-universalChain.js arbitrum 100 5000");
    console.error("");
    console.error("Arguments:");
    console.error("  chain: sepolia, base, or arbitrum");
    console.error("  minAmount: Minimum deposit amount in USDC (will add up to 6 decimals)");
    console.error("  maxAmount: Maximum deposit amount in USDC (will add up to 6 decimals)");
    process.exit(1);
  }

  if (minAmount > maxAmount) {
    console.error("❌ Error: minAmount cannot be greater than maxAmount");
    process.exit(1);
  }

  if (!deployment[chain]) {
    console.error(`❌ Error: Chain '${chain}' not found in deployment.json`);
    console.error(`Available chains: ${Object.keys(deployment).filter(k => typeof deployment[k] === 'object' && deployment[k].vault).join(', ')}`);
    process.exit(1);
  }

  const vaultAddress = deployment[chain].vault;
  const wrapperAddress = deployment[chain].sherpaUSD;
  const mockUSDCAddress = deployment[chain].mockUSDC;

  console.log("=".repeat(70));
  console.log(`SIMULATING 10 USER DEPOSITS TO ${chain.toUpperCase()}`);
  console.log("=".repeat(70));
  console.log();
  console.log(`Chain: ${chain}`);
  console.log(`Vault Address: ${vaultAddress}`);
  console.log(`SherpaUSD Wrapper: ${wrapperAddress}`);
  console.log(`MockUSDC: ${mockUSDCAddress}`);
  console.log(`Deposit Range: ${minAmount} - ${maxAmount} USDC (with up to 6 decimals)`);
  console.log(`Users: All 10 test users`);
  console.log();

  // Setup provider
  const rpcUrl = getRpcUrl(chain);
  if (!rpcUrl) {
    console.error(`❌ Error: No RPC URL configured for ${chain}`);
    process.exit(1);
  }

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  console.log(`Connected to ${chain} RPC`);

  // Check if deposits are enabled
  const vaultArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  );
  const vaultContract = new ethers.Contract(vaultAddress, vaultArtifact.abi, provider);
  const depositsEnabled = await vaultContract.depositsEnabled();

  console.log(`Deposits Enabled: ${depositsEnabled ? '✅ YES' : '❌ NO'}`);

  if (!depositsEnabled) {
    console.error("\n⚠️  WARNING: Deposits are currently disabled on this vault!");
    console.error("Enable deposits first: vault.setDepositsEnabled(true)");
    process.exit(1);
  }

  console.log();

  // Process all 10 users
  const results = [];
  for (let i = 0; i < TEST_USERS.length; i++) {
    try {
      const result = await processUserDeposit(
        TEST_USERS[i],
        minAmount,
        maxAmount,
        vaultAddress,
        wrapperAddress,
        mockUSDCAddress,
        provider,
        chain
      );
      if (result) {
        results.push(result);
      }
    } catch (error) {
      console.log(`\n❌ Error processing ${TEST_USERS[i].name}:`, error.message);
      if (error.reason) {
        console.log(`   Reason: ${error.reason}`);
      }
    }
  }

  // Summary
  console.log("\n" + "=".repeat(70));
  console.log("DEPOSIT SUMMARY");
  console.log("=".repeat(70));
  console.log();

  if (results.length === 0) {
    console.log("❌ No deposits were successful");
    return;
  }

  console.log(`✅ ${results.length} successful deposits:\n`);

  const explorerUrl = getExplorerUrl(chain);
  let totalDeposited = 0;

  results.forEach((result, index) => {
    console.log(`${index + 1}. ${result.user}`);
    console.log(`   Address: ${result.address}`);
    console.log(`   Amount: ${result.amount} USDC`);
    console.log(`   Tx: ${explorerUrl}${result.txHash}`);
    console.log();
    totalDeposited += parseFloat(result.amount);
  });

  console.log(`💰 Total Deposited: ${totalDeposited.toFixed(6)} USDC`);
  console.log();
  console.log("=".repeat(70));
  console.log("NEXT STEPS:");
  console.log("=".repeat(70));
  console.log();
  console.log("1. Check vault state:");
  console.log(`   node scripts/core/auditSystemState.js`);
  console.log();
  console.log("2. Roll to next round with yield:");
  console.log("   node scripts/core/rollAllChains-dynamic-with-consensus.js <yieldAmount> <isPositive>");
  console.log("   # Example: node scripts/core/rollAllChains-dynamic-with-consensus.js 10000000 true");
  console.log();
  console.log("3. Check individual user stakes:");
  console.log("   node scripts/analysis/checkUserStake.js <userNumber> <chain>");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ SCRIPT FAILED:");
    console.error(error);
    process.exit(1);
  });
