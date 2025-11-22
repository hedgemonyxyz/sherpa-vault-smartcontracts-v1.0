const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Deploy Fresh SherpaVault System on All 3 Chains
 *
 * Deploys:
 * - SherpaVault (shUSD) on Sepolia, Base, Arbitrum
 * - SherpaUSD (wrapper) on Sepolia, Base, Arbitrum
 *
 * NOTE: CCIP pools are deployed separately (deployAllCCIPPools.js)
 *
 * This script:
 * 1. Backs up existing deployment.json
 * 2. Deploys all vaults with temporary wrapper addresses
 * 3. Deploys all wrappers
 * 4. Updates vaults with correct wrapper addresses
 * 5. Configures chain roles (primary/secondary)
 * 6. Pauses deposits initially (will be enabled after CCIP setup)
 * 7. Saves new addresses to deployment.json
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🚀 DEPLOYING FRESH SHERPAVAULT SYSTEM - ALL 3 CHAINS");
  console.log("=".repeat(70));
  console.log();

  // ===================================================================
  // SETUP
  // ===================================================================

  // Load artifacts
  const SherpaVaultArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  );
  const SherpaUSDArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaUSD.sol/SherpaUSD.json"), "utf8")
  );

  // Chain configurations
  const CHAINS = {
    sepolia: {
      mockUSDC: "0x03f346E161B2cD07F4B14a14F8B661f0E57AF14F",
      ccipRouter: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
      chainSelector: "16015286601757825753",
      chainId: 11155111,
      rpcEnvVar: "SEPOLIA_RPC_URL",
      isPrimary: true
    },
    base: {
      mockUSDC: "0x20b64A9fa5546247C31bD694eCF6E910874f4e55",
      ccipRouter: "0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93",
      chainSelector: "10344971235874465080",
      chainId: 84532,
      rpcEnvVar: "BASE_SEPOLIA_RPC_URL",
      isPrimary: false
    },
    arbitrum: {
      mockUSDC: "0x7c9EEbb6A8DC30fe5fC8CBB00fe666f08eFfED12",
      ccipRouter: "0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165",
      chainSelector: "3478487238524512106",
      chainId: 421614,
      rpcEnvVar: "ARBITRUM_SEPOLIA_RPC_URL",
      isPrimary: false
    }
  };

  // Vault parameters
  const vaultParams = {
    decimals: 6,
    minimumSupply: ethers.utils.parseUnits("1", 6),
    cap: ethers.utils.parseUnits("1000000", 6) // 1M USDC cap per chain
  };

  console.log("Vault Parameters:");
  console.log("  Decimals:", vaultParams.decimals);
  console.log("  Minimum Supply:", ethers.utils.formatUnits(vaultParams.minimumSupply, 6), "USDC");
  console.log("  Cap per chain:", ethers.utils.formatUnits(vaultParams.cap, 6), "USDC");
  console.log();

  // Setup wallets
  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY);
  const providers = {};
  const wallets = {};

  console.log("Deployer:", wallet.address);
  console.log();

  for (const [chain, config] of Object.entries(CHAINS)) {
    const rpcUrl = process.env[config.rpcEnvVar];
    if (!rpcUrl) {
      throw new Error(`Missing ${config.rpcEnvVar} in .env`);
    }
    providers[chain] = new ethers.providers.JsonRpcProvider(rpcUrl);
    wallets[chain] = wallet.connect(providers[chain]);
  }

  // Check balances
  console.log("Wallet Balances:");
  for (const [chain, wallet] of Object.entries(wallets)) {
    const balance = await wallet.getBalance();
    console.log(`  ${chain}: ${ethers.utils.formatEther(balance)} ETH`);
  }
  console.log();

  // ===================================================================
  // BACKUP EXISTING DEPLOYMENT
  // ===================================================================

  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupPath = path.join(__dirname, `../../deployments/deployment-backup-${timestamp}.json`);

  if (fs.existsSync(deploymentPath)) {
    fs.copyFileSync(deploymentPath, backupPath);
    console.log("✅ Backed up deployment.json to:", backupPath);
    console.log();
  }

  // ===================================================================
  // STEP 1: DEPLOY VAULTS (TEMPORARY WRAPPER)
  // ===================================================================

  console.log("📍 STEP 1: DEPLOYING VAULTS (TEMPORARY WRAPPER)");
  console.log("-".repeat(70));
  console.log();

  const vaultFactory = new ethers.ContractFactory(
    SherpaVaultArtifact.abi,
    SherpaVaultArtifact.bytecode
  );

  const vaults = {};
  const tempWrapper = wallet.address; // Use deployer as temporary wrapper

  for (const [chain, config] of Object.entries(CHAINS)) {
    console.log(`Deploying ${chain} vault...`);
    const vault = await vaultFactory.connect(wallets[chain]).deploy(
      "Staked Sherpa USD",
      "shUSD",
      tempWrapper,
      wallet.address,
      vaultParams
    );
    await vault.deployed();
    vaults[chain] = vault;
    console.log(`  ✅ ${chain} Vault: ${vault.address}`);
    console.log();
  }

  // ===================================================================
  // STEP 2: DEPLOY WRAPPERS
  // ===================================================================

  console.log("📍 STEP 2: DEPLOYING WRAPPERS (SherpaUSD)");
  console.log("-".repeat(70));
  console.log();

  const wrapperFactory = new ethers.ContractFactory(
    SherpaUSDArtifact.abi,
    SherpaUSDArtifact.bytecode
  );

  const wrappers = {};

  for (const [chain, config] of Object.entries(CHAINS)) {
    console.log(`Deploying ${chain} wrapper...`);
    const wrapper = await wrapperFactory.connect(wallets[chain]).deploy(
      config.mockUSDC,      // _asset
      vaults[chain].address // _keeper (vault)
    );
    await wrapper.deployed();
    wrappers[chain] = wrapper;
    console.log(`  ✅ ${chain} Wrapper: ${wrapper.address}`);
    console.log();
  }

  // ===================================================================
  // STEP 3: LOCK WRAPPER AND KEEPER TO PREVENT SWAP ATTACKS
  // ===================================================================

  console.log("📍 STEP 3: LOCKING WRAPPER AND KEEPER");
  console.log("-".repeat(70));
  console.log();

  for (const [chain, vault] of Object.entries(vaults)) {
    console.log(`Locking ${chain} vault wrapper...`);
    let tx = await vault.setStableWrapper(wrappers[chain].address);
    await tx.wait();
    console.log(`  ✅ ${chain} wrapper locked (prevents wrapper-swap attack)`);
  }
  console.log();

  for (const [chain, wrapper] of Object.entries(wrappers)) {
    console.log(`Locking ${chain} SherpaUSD keeper...`);
    const tx = await wrapper.setKeeper(vaults[chain].address);
    await tx.wait();
    console.log(`  ✅ ${chain} keeper locked (prevents keeper-swap attack)`);
  }
  console.log();

  // ===================================================================
  // STEP 4: CONFIGURE CHAIN ROLES (PRIMARY/SECONDARY)
  // ===================================================================

  console.log("📍 STEP 4: CONFIGURING CHAIN ROLES");
  console.log("-".repeat(70));
  console.log();

  // Set Sepolia as primary
  console.log("Setting Sepolia as primary chain...");
  let tx = await vaults.sepolia.setPrimaryChain(CHAINS.sepolia.chainSelector, true);
  await tx.wait();
  console.log("  ✅ Sepolia set as primary");

  // Set Base as secondary (not primary)
  console.log("Setting Base as secondary chain...");
  tx = await vaults.base.setPrimaryChain(CHAINS.sepolia.chainSelector, false);
  await tx.wait();
  console.log("  ✅ Base set as secondary");

  // Set Arbitrum as secondary (not primary)
  console.log("Setting Arbitrum as secondary chain...");
  tx = await vaults.arbitrum.setPrimaryChain(CHAINS.sepolia.chainSelector, false);
  await tx.wait();
  console.log("  ✅ Arbitrum set as secondary");
  console.log();

  // ===================================================================
  // STEP 5: PAUSE DEPOSITS (WILL ENABLE AFTER CCIP SETUP)
  // ===================================================================

  console.log("📍 STEP 5: PAUSING DEPOSITS (WILL ENABLE AFTER CCIP SETUP)");
  console.log("-".repeat(70));
  console.log();

  for (const [chain, vault] of Object.entries(vaults)) {
    console.log(`Pausing ${chain} deposits...`);
    const tx = await vault.setDepositsEnabled(false);
    await tx.wait();
    console.log(`  ✅ ${chain} deposits paused`);
  }
  console.log();

  // ===================================================================
  // STEP 6: SAVE DEPLOYMENT DATA
  // ===================================================================

  console.log("📍 STEP 6: SAVING DEPLOYMENT DATA");
  console.log("-".repeat(70));
  console.log();

  const deployment = {
    timestamp: new Date().toISOString(),
    deployer: wallet.address,
    sepolia: {
      chainId: CHAINS.sepolia.chainId,
      chainSelector: CHAINS.sepolia.chainSelector,
      vault: vaults.sepolia.address,
      sherpaUSD: wrappers.sepolia.address,
      mockUSDC: CHAINS.sepolia.mockUSDC,
      ccipRouter: CHAINS.sepolia.ccipRouter,
      isPrimary: true
    },
    base: {
      chainId: CHAINS.base.chainId,
      chainSelector: CHAINS.base.chainSelector,
      vault: vaults.base.address,
      sherpaUSD: wrappers.base.address,
      mockUSDC: CHAINS.base.mockUSDC,
      ccipRouter: CHAINS.base.ccipRouter,
      isPrimary: false
    },
    arbitrum: {
      chainId: CHAINS.arbitrum.chainId,
      chainSelector: CHAINS.arbitrum.chainSelector,
      vault: vaults.arbitrum.address,
      sherpaUSD: wrappers.arbitrum.address,
      mockUSDC: CHAINS.arbitrum.mockUSDC,
      ccipRouter: CHAINS.arbitrum.ccipRouter,
      isPrimary: false
    },
    vaultParams: {
      decimals: vaultParams.decimals,
      minimumSupply: vaultParams.minimumSupply.toString(),
      cap: vaultParams.cap.toString()
    },
    status: "vaults-and-wrappers-deployed",
    notes: "🚧 CCIP pools not yet deployed. Deposits paused. Run deployAllCCIPPools.js next."
  };

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✅ Deployment data saved to:", deploymentPath);
  console.log();

  // ===================================================================
  // VERIFICATION
  // ===================================================================

  console.log("📍 VERIFICATION");
  console.log("-".repeat(70));
  console.log();

  for (const [chain, vault] of Object.entries(vaults)) {
    const wrapper = await vault.stableWrapper();
    const isPrimary = await vault.isPrimaryChain();
    const depositsEnabled = await vault.depositsEnabled();

    console.log(`${chain}:`);
    console.log(`  Vault: ${vault.address}`);
    console.log(`  Wrapper: ${wrapper}`);
    console.log(`  Wrapper correct: ${wrapper === wrappers[chain].address ? '✅' : '❌'}`);
    console.log(`  Is Primary: ${isPrimary ? '✅ YES' : '❌ NO'}`);
    console.log(`  Deposits Enabled: ${depositsEnabled ? '⚠️ YES' : '✅ NO (paused)'}`);
    console.log();
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("🎉 VAULTS & WRAPPERS DEPLOYED SUCCESSFULLY!");
  console.log("=".repeat(70));
  console.log();
  console.log("📋 Deployment Summary:");
  console.log();
  console.log("Sepolia (PRIMARY):");
  console.log(`  Vault (shUSD): ${vaults.sepolia.address}`);
  console.log(`  Wrapper (sherpaUSD): ${wrappers.sepolia.address}`);
  console.log();
  console.log("Base (SECONDARY):");
  console.log(`  Vault (shUSD): ${vaults.base.address}`);
  console.log(`  Wrapper (sherpaUSD): ${wrappers.base.address}`);
  console.log();
  console.log("Arbitrum (SECONDARY):");
  console.log(`  Vault (shUSD): ${vaults.arbitrum.address}`);
  console.log(`  Wrapper (sherpaUSD): ${wrappers.arbitrum.address}`);
  console.log();
  console.log("✅ Vaults and wrappers configured");
  console.log("✅ Primary/secondary roles set");
  console.log("✅ Deposits paused on all chains");
  console.log("✅ deployment.json updated");
  console.log();
  console.log("📋 NEXT STEP:");
  console.log("  node scripts/system-deployment/deployAllCCIPPools.js");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ DEPLOYMENT FAILED:");
    console.error(error);
    console.log("\n💡 If deployment failed partway:");
    console.log("  - Check which step failed in the output above");
    console.log("  - Restore backup: cp deployments/deployment-backup-*.json deployments/deployment.json");
    console.log("  - Fix the issue and re-run this script");
    process.exit(1);
  });
