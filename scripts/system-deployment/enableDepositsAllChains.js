const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Enable Deposits on All Chains and Verify System
 *
 * This script:
 * 1. Enables deposits on all vaults
 * 2. Verifies system is ready for user deposits
 * 3. Runs basic health checks
 * 4. Updates deployment.json status
 *
 * Prerequisites:
 * - Vaults and wrappers deployed
 * - CCIP pools deployed and configured
 * - Cross-chain routing configured
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🎉 ENABLING DEPOSITS & VERIFYING SYSTEM");
  console.log("=".repeat(70));
  console.log();

  // ===================================================================
  // LOAD DEPLOYMENT & SETUP
  // ===================================================================

  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  // Verify deployment is ready
  for (const chain of chains) {
    if (!deployment[chain]?.vault) {
      throw new Error(`❌ Vault not found for ${chain}`);
    }
    if (!deployment[chain]?.newCcipPool) {
      throw new Error(`❌ CCIP pool not found for ${chain}`);
    }
  }

  // Setup wallets
  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY);
  const providers = {};
  const wallets = {};

  const RPC_ENV_VARS = {
    sepolia: "SEPOLIA_RPC_URL",
    base: "BASE_SEPOLIA_RPC_URL",
    arbitrum: "ARBITRUM_SEPOLIA_RPC_URL"
  };

  for (const chain of chains) {
    const rpcUrl = process.env[RPC_ENV_VARS[chain]];
    if (!rpcUrl) {
      throw new Error(`Missing ${RPC_ENV_VARS[chain]} in .env`);
    }
    providers[chain] = new ethers.providers.JsonRpcProvider(rpcUrl);
    wallets[chain] = wallet.connect(providers[chain]);
  }

  console.log("Deployer:", wallet.address);
  console.log();

  // Load vault artifact
  const vaultArtifact = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"),
      "utf8"
    )
  );

  // ===================================================================
  // STEP 1: ENABLE DEPOSITS ON ALL CHAINS
  // ===================================================================

  console.log("📍 STEP 1: ENABLING DEPOSITS ON ALL CHAINS");
  console.log("-".repeat(70));
  console.log();

  const vaults = {};

  for (const chain of chains) {
    vaults[chain] = new ethers.Contract(
      deployment[chain].vault,
      vaultArtifact.abi,
      wallets[chain]
    );

    console.log(`Enabling ${chain} deposits...`);
    const tx = await vaults[chain].setDepositsEnabled(true);
    await tx.wait();
    console.log(`  ✅ ${chain} deposits ENABLED`);
    console.log();
  }

  // ===================================================================
  // STEP 2: VERIFY SYSTEM CONFIGURATION
  // ===================================================================

  console.log("📍 STEP 2: VERIFYING SYSTEM CONFIGURATION");
  console.log("-".repeat(70));
  console.log();

  const checks = [];

  for (const chain of chains) {
    console.log(`${chain}:`);

    const vault = vaults[chain];

    // Check vault configuration
    const depositsEnabled = await vault.depositsEnabled();
    const isPrimary = await vault.isPrimaryChain();
    const round = await vault.round();
    const wrapper = await vault.stableWrapper();
    const totalStaked = await vault.totalStaked();
    const totalSupply = await vault.totalSupply();

    console.log(`  Vault: ${deployment[chain].vault}`);
    console.log(`  Wrapper: ${wrapper}`);
    console.log(`  Deposits Enabled: ${depositsEnabled ? '✅ YES' : '❌ NO'}`);
    console.log(`  Is Primary: ${isPrimary ? 'YES' : 'NO'}`);
    console.log(`  Current Round: ${round}`);
    console.log(`  Total Staked: ${ethers.utils.formatUnits(totalStaked, 6)} USDC`);
    console.log(`  Total Supply: ${ethers.utils.formatUnits(totalSupply, 6)} shUSD`);

    // Check CCIP pool authorization
    const poolAuthorized = await vault.ccipPools(deployment[chain].newCcipPool);
    console.log(`  CCIP Pool Authorized: ${poolAuthorized ? '✅ YES' : '❌ NO'}`);

    console.log();

    checks.push({
      chain,
      depositsEnabled,
      poolAuthorized,
      wrapper: wrapper === deployment[chain].sherpaUSD
    });
  }

  // ===================================================================
  // STEP 3: VERIFY CROSS-CHAIN ROUTING
  // ===================================================================

  console.log("📍 STEP 3: VERIFYING CROSS-CHAIN ROUTING");
  console.log("-".repeat(70));
  console.log();

  const POOL_ABI = [
    "function isSupportedChain(uint64 remoteChainSelector) external view returns (bool)"
  ];

  const routingConfigs = {
    sepolia: ["base", "arbitrum"],
    base: ["sepolia", "arbitrum"],
    arbitrum: ["sepolia", "base"]
  };

  const routeChecks = [];

  for (const [sourceChain, remoteChains] of Object.entries(routingConfigs)) {
    const pool = new ethers.Contract(
      deployment[sourceChain].newCcipPool,
      POOL_ABI,
      providers[sourceChain]
    );

    for (const remoteChain of remoteChains) {
      const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);
      const route = `${sourceChain} → ${remoteChain}`;
      console.log(`  ${route}: ${isSupported ? '✅' : '❌'}`);
      routeChecks.push({ route, supported: isSupported });
    }
  }
  console.log();

  // ===================================================================
  // STEP 4: UPDATE DEPLOYMENT.JSON
  // ===================================================================

  console.log("📍 STEP 4: UPDATING DEPLOYMENT.JSON");
  console.log("-".repeat(70));
  console.log();

  deployment.status = "deployed-and-operational";
  deployment.notes = "✅ Complete deployment: vaults, wrappers, CCIP pools configured. Deposits enabled. System ready for users.";

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✅ deployment.json status updated");
  console.log();

  // ===================================================================
  // FINAL HEALTH CHECK
  // ===================================================================

  console.log("📍 FINAL HEALTH CHECK");
  console.log("-".repeat(70));
  console.log();

  const allDepositsEnabled = checks.every(c => c.depositsEnabled);
  const allPoolsAuthorized = checks.every(c => c.poolAuthorized);
  const allWrappersCorrect = checks.every(c => c.wrapper);
  const allRoutesConfigured = routeChecks.every(r => r.supported);

  console.log("System Checks:");
  console.log(`  All deposits enabled: ${allDepositsEnabled ? '✅' : '❌'}`);
  console.log(`  All CCIP pools authorized: ${allPoolsAuthorized ? '✅' : '❌'}`);
  console.log(`  All wrappers connected: ${allWrappersCorrect ? '✅' : '❌'}`);
  console.log(`  All routes configured (6 total): ${allRoutesConfigured ? '✅' : '❌'}`);
  console.log();

  const systemHealthy = allDepositsEnabled && allPoolsAuthorized && allWrappersCorrect && allRoutesConfigured;

  if (!systemHealthy) {
    console.error("⚠️  WARNING: System is not fully healthy!");
    console.log();
    console.log("Please review the checks above and fix any issues.");
    console.log();
    return;
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("🎉 SYSTEM DEPLOYMENT COMPLETE!");
  console.log("=".repeat(70));
  console.log();
  console.log("📋 Deployment Summary:");
  console.log();
  for (const chain of chains) {
    console.log(`${chain} (${deployment[chain].isPrimary ? 'PRIMARY' : 'SECONDARY'}):`);
    console.log(`  Vault (shUSD): ${deployment[chain].vault}`);
    console.log(`  Wrapper (sherpaUSD): ${deployment[chain].sherpaUSD}`);
    console.log(`  CCIP Pool: ${deployment[chain].newCcipPool}`);
    console.log(`  Mock USDC: ${deployment[chain].mockUSDC}`);
    console.log();
  }
  console.log("✅ All vaults and wrappers deployed");
  console.log("✅ All CCIP pools deployed and configured");
  console.log("✅ All cross-chain routes configured (6 routes)");
  console.log("✅ Deposits ENABLED on all chains");
  console.log("✅ System ready for user deposits");
  console.log();
  console.log("📋 NEXT STEPS:");
  console.log();
  console.log("1. Roll to initial round (sets price to 1.0):");
  console.log("   node scripts/core/rollAllChains-dynamic-with-consensus.js 0 true");
  console.log();
  console.log("2. Test deposit on each chain:");
  console.log("   node scripts/testing/singleUserDeposit-universalChain.js 1 sepolia 100");
  console.log("   node scripts/testing/singleUserDeposit-universalChain.js 1 base 100");
  console.log("   node scripts/testing/singleUserDeposit-universalChain.js 1 arbitrum 100");
  console.log();
  console.log("3. Test bridge between chains:");
  console.log("   node scripts/testing/singleUserBridgeTokens.js sepolia base 10 1");
  console.log("   node scripts/testing/singleUserBridgeTokens.js base arbitrum 10 1");
  console.log("   node scripts/testing/singleUserBridgeTokens.js arbitrum sepolia 10 1");
  console.log();
  console.log("4. Verify global accounting:");
  console.log("   node scripts/core/auditSystemState.js");
  console.log();
  console.log("5. Update frontend with new contract addresses");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ FAILED:");
    console.error(error);
    process.exit(1);
  });
