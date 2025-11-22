const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Deploy CCIP Pools for All 3 Chains
 *
 * This script:
 * 1. Registers as token admin for shUSD on all chains
 * 2. Deploys BurnFromMintTokenPool on all chains
 * 3. Registers pools in Token Admin Registry
 * 4. Authorizes pools in shUSD vaults (grants mint/burn permissions)
 * 5. Updates deployment.json with pool addresses
 *
 * NOTE: Cross-chain routing is configured separately (configureAllPoolRoutes.js)
 *
 * Prerequisites:
 * - Vaults and wrappers must be deployed (deployFreshSystem-all3chains.js)
 * - deployment.json must have vault addresses
 */

// RMN Proxy addresses (MUST use same RMN for all pools!)
const RMN_PROXIES = {
  sepolia: "0xba3f6251de62dED61Ff98590cB2fDf6871FbB991",
  base: "0x99360767a4705f68CcCb9533195B761648d6d807",
  arbitrum: "0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2" // Arbitrum Sepolia
};

// Token Admin Registry addresses
const TOKEN_ADMIN_REGISTRIES = {
  sepolia: "0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82",
  base: "0x736D0bBb318c1B27Ff686cd19804094E66250e17",
  arbitrum: "0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f" // Arbitrum Sepolia
};

// Registry Module addresses (for registering as admin)
const REGISTRY_MODULES = {
  sepolia: "0x62e731218d0D47305aba2BE3751E7EE9E5520790",
  base: "0x8A55C61227f26a3e2f217842eCF20b52007bAaBe",
  arbitrum: "0xE625f0b8b0Ac86946035a7729Aba124c8A64cf69" // Arbitrum Sepolia
};

async function main() {
  console.log("=".repeat(70));
  console.log("🏊 DEPLOYING CCIP POOLS FOR ALL 3 CHAINS");
  console.log("=".repeat(70));
  console.log();

  // ===================================================================
  // LOAD DEPLOYMENT & SETUP
  // ===================================================================

  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  // Verify vaults exist
  for (const chain of chains) {
    if (!deployment[chain]?.vault) {
      throw new Error(`❌ Vault not found for ${chain}. Run deployFreshSystem-all3chains.js first.`);
    }
  }

  console.log("Vault Addresses (shUSD tokens for pools):");
  for (const chain of chains) {
    console.log(`  ${chain}: ${deployment[chain].vault}`);
  }
  console.log();

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

  // Check balances
  console.log("Wallet Balances:");
  for (const chain of chains) {
    const balance = await wallets[chain].getBalance();
    console.log(`  ${chain}: ${ethers.utils.formatEther(balance)} ETH`);
  }
  console.log();

  // Load artifacts
  const poolArtifact = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, "../../artifacts/@chainlink/contracts-ccip/contracts/pools/BurnFromMintTokenPool.sol/BurnFromMintTokenPool.json"),
      "utf8"
    )
  );

  const vaultArtifact = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"),
      "utf8"
    )
  );

  // ===================================================================
  // STEP 1: REGISTER AS TOKEN ADMIN ON ALL CHAINS
  // ===================================================================

  console.log("📍 STEP 1: REGISTERING AS TOKEN ADMIN ON ALL CHAINS");
  console.log("-".repeat(70));
  console.log();

  const REGISTRY_MODULE_ABI = ["function registerAdminViaOwner(address token) external"];
  const TOKEN_ADMIN_REGISTRY_ABI = [
    "function acceptAdminRole(address token) external",
    "function setPool(address token, address pool) external",
    "function getPool(address token) external view returns (address)",
    "function getTokenConfig(address token) external view returns (address administrator, address pendingAdministrator)"
  ];

  for (const chain of chains) {
    console.log(`${chain}:`);

    const shUSD = deployment[chain].vault;
    const registryModule = new ethers.Contract(
      REGISTRY_MODULES[chain],
      REGISTRY_MODULE_ABI,
      wallets[chain]
    );
    const tokenAdmin = new ethers.Contract(
      TOKEN_ADMIN_REGISTRIES[chain],
      TOKEN_ADMIN_REGISTRY_ABI,
      wallets[chain]
    );

    // Check if already has pool registered
    const existingPool = await tokenAdmin.getPool(shUSD);

    if (existingPool === ethers.constants.AddressZero) {
      console.log("  Registering admin...");
      try {
        let tx = await registryModule.registerAdminViaOwner(shUSD);
        await tx.wait();
        console.log("    ✅ Admin registered");
      } catch (e) {
        console.log("    ℹ️  Admin already registered");
      }

      console.log("  Accepting admin role...");
      try {
        let tx = await tokenAdmin.acceptAdminRole(shUSD);
        await tx.wait();
        console.log("    ✅ Admin role accepted");
      } catch (e) {
        console.log("    ℹ️  Admin role already accepted");
      }
    } else {
      console.log("  ℹ️  Pool already registered, checking admin status...");

      // Even if pool exists, we might be pending admin
      const tokenConfig = await tokenAdmin.getTokenConfig(shUSD);
      if (tokenConfig.pendingAdministrator.toLowerCase() === wallet.address.toLowerCase()) {
        console.log("  We are pending admin, accepting role...");
        try {
          let tx = await tokenAdmin.acceptAdminRole(shUSD);
          await tx.wait();
          console.log("    ✅ Admin role accepted");
        } catch (e) {
          console.log("    ℹ️  Failed to accept:", e.message);
        }
      }
    }
    console.log();
  }

  // ===================================================================
  // STEP 2: DEPLOY BURNFROMMINT TOKEN POOLS
  // ===================================================================

  console.log("📍 STEP 2: DEPLOYING BURNFROMMINT TOKEN POOLS");
  console.log("-".repeat(70));
  console.log();

  const pools = {};

  for (const chain of chains) {
    console.log(`Deploying ${chain} BurnFromMintTokenPool...`);

    const shUSD = deployment[chain].vault;
    const router = deployment[chain].ccipRouter;
    const rmnProxy = RMN_PROXIES[chain];

    const poolFactory = new ethers.ContractFactory(
      poolArtifact.abi,
      poolArtifact.bytecode,
      wallets[chain]
    );

    const pool = await poolFactory.deploy(
      shUSD,        // token (shUSD vault)
      6,            // decimals
      [],           // allowlist (empty = public)
      rmnProxy,     // RMN proxy for security
      router        // CCIP router
    );
    await pool.deployed();

    pools[chain] = pool;
    console.log(`  ✅ ${chain} Pool: ${pool.address}`);
    console.log(`     Token: ${shUSD}`);
    console.log(`     Router: ${router}`);
    console.log(`     RMN: ${rmnProxy}`);
    console.log();
  }

  // ===================================================================
  // STEP 3: REGISTER POOLS IN TOKEN ADMIN REGISTRY
  // ===================================================================

  console.log("📍 STEP 3: REGISTERING POOLS IN TOKEN ADMIN REGISTRY");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    console.log(`Registering ${chain} pool...`);

    const shUSD = deployment[chain].vault;
    const tokenAdmin = new ethers.Contract(
      TOKEN_ADMIN_REGISTRIES[chain],
      TOKEN_ADMIN_REGISTRY_ABI,
      wallets[chain]
    );

    // Check if pool already registered
    const existingPool = await tokenAdmin.getPool(shUSD);
    if (existingPool !== ethers.constants.AddressZero && existingPool.toLowerCase() === pools[chain].address.toLowerCase()) {
      console.log(`  ℹ️  Pool already registered (correct address)`);
      console.log();
      continue;
    }

    if (existingPool !== ethers.constants.AddressZero) {
      console.log(`  ⚠️  WARNING: Different pool already registered: ${existingPool}`);
      console.log(`  Attempting to update to new pool: ${pools[chain].address}`);
    }

    // Verify we are the admin before trying to set pool
    const tokenConfig = await tokenAdmin.getTokenConfig(shUSD);
    if (tokenConfig.administrator.toLowerCase() !== wallet.address.toLowerCase()) {
      console.log(`  ❌ ERROR: We are NOT the administrator!`);
      console.log(`     Current admin: ${tokenConfig.administrator}`);
      console.log(`     Our address: ${wallet.address}`);
      if (tokenConfig.pendingAdministrator.toLowerCase() === wallet.address.toLowerCase()) {
        console.log(`  ℹ️  We are pending admin - run acceptAdminRole first!`);
      }
      console.log(`  ⚠️  Skipping pool registration for ${chain}`);
      console.log();
      continue;
    }

    try {
      const tx = await tokenAdmin.setPool(shUSD, pools[chain].address);
      await tx.wait();
      console.log(`  ✅ ${chain} pool registered in Token Admin Registry`);
    } catch (e) {
      console.log(`  ❌ Failed to register ${chain} pool:`, e.message);
    }
    console.log();
  }

  // ===================================================================
  // STEP 4: AUTHORIZE POOLS IN SHUSD VAULTS
  // ===================================================================

  console.log("📍 STEP 4: AUTHORIZING POOLS IN SHUSD VAULTS");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    console.log(`Authorizing ${chain} pool in vault...`);

    const vault = new ethers.Contract(
      deployment[chain].vault,
      vaultArtifact.abi,
      wallets[chain]
    );

    // Check if already authorized
    const isAlreadyAuthorized = await vault.ccipPools(pools[chain].address);
    if (isAlreadyAuthorized) {
      console.log(`  ℹ️  Pool already authorized`);
      console.log();
      continue;
    }

    try {
      const tx = await vault.addCCIPPool(pools[chain].address);
      console.log(`  Transaction sent: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`  ✅ ${chain} pool authorized (block ${receipt.blockNumber})`);

      // Verify authorization succeeded
      const isNowAuthorized = await vault.ccipPools(pools[chain].address);
      if (!isNowAuthorized) {
        console.log(`  ❌ WARNING: Authorization transaction succeeded but pool not showing as authorized!`);
        console.log(`  Please manually verify and re-run if needed.`);
      }
    } catch (error) {
      console.log(`  ❌ Failed to authorize ${chain} pool:`, error.message);
      console.log(`  This is CRITICAL - pool cannot mint/burn shUSD without authorization!`);
      throw error; // Stop deployment - this is critical
    }
    console.log();
  }

  // ===================================================================
  // STEP 5: UPDATE DEPLOYMENT.JSON
  // ===================================================================

  console.log("📍 STEP 5: UPDATING DEPLOYMENT.JSON");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    deployment[chain].newCcipPool = pools[chain].address;
    deployment[chain].poolType = "BurnFromMintTokenPool 1.6.1";
  }

  deployment.status = "ccip-pools-deployed";
  deployment.notes = "🚧 Pools deployed but not yet configured for cross-chain routing. Run configureAllPoolRoutes.js next.";

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✅ deployment.json updated with pool addresses");
  console.log();

  // ===================================================================
  // VERIFICATION
  // ===================================================================

  console.log("📍 VERIFICATION");
  console.log("-".repeat(70));
  console.log();

  const verificationResults = [];

  for (const chain of chains) {
    const vault = new ethers.Contract(
      deployment[chain].vault,
      vaultArtifact.abi,
      providers[chain]
    );

    const tokenAdmin = new ethers.Contract(
      TOKEN_ADMIN_REGISTRIES[chain],
      TOKEN_ADMIN_REGISTRY_ABI,
      providers[chain]
    );

    const poolAuthorized = await vault.ccipPools(pools[chain].address);
    const registeredPool = await tokenAdmin.getPool(deployment[chain].vault);
    const poolRegistered = registeredPool.toLowerCase() === pools[chain].address.toLowerCase();

    console.log(`${chain}:`);
    console.log(`  Pool deployed: ${pools[chain].address}`);
    console.log(`  Pool authorized in vault: ${poolAuthorized ? '✅' : '❌'}`);
    console.log(`  Pool registered in Token Admin Registry: ${poolRegistered ? '✅' : '❌'}`);
    console.log();

    verificationResults.push({
      chain,
      poolAuthorized,
      poolRegistered
    });
  }

  // Check for failures
  const allAuthorized = verificationResults.every(r => r.poolAuthorized);
  const allRegistered = verificationResults.every(r => r.poolRegistered);

  if (!allAuthorized || !allRegistered) {
    console.log("❌ CRITICAL VERIFICATION FAILURES DETECTED!");
    console.log();

    if (!allAuthorized) {
      console.log("Pools not authorized in vaults:");
      verificationResults.filter(r => !r.poolAuthorized).forEach(r => {
        console.log(`  - ${r.chain}: Pool cannot mint/burn shUSD!`);
      });
      console.log();
    }

    if (!allRegistered) {
      console.log("Pools not registered in Token Admin Registry:");
      verificationResults.filter(r => !r.poolRegistered).forEach(r => {
        console.log(`  - ${r.chain}: Cross-chain bridging will fail!`);
      });
      console.log();
    }

    throw new Error("Pool deployment verification failed - critical issues detected!");
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("🎉 CCIP POOLS DEPLOYED SUCCESSFULLY!");
  console.log("=".repeat(70));
  console.log();
  console.log("📋 Deployment Summary:");
  console.log();
  for (const chain of chains) {
    console.log(`${chain}:`);
    console.log(`  shUSD (vault): ${deployment[chain].vault}`);
    console.log(`  CCIP Pool: ${pools[chain].address}`);
    console.log(`  Router: ${deployment[chain].ccipRouter}`);
    console.log(`  RMN: ${RMN_PROXIES[chain]}`);
    console.log();
  }
  console.log("✅ All pools deployed");
  console.log("✅ All pools registered in Token Admin Registry");
  console.log("✅ All pools authorized in vaults (mint/burn permissions)");
  console.log("✅ deployment.json updated");
  console.log();
  console.log("⚠️  Pools are NOT yet configured for cross-chain routing");
  console.log();
  console.log("📋 NEXT STEP:");
  console.log("  node scripts/system-deployment/configureAllPoolRoutes.js");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ DEPLOYMENT FAILED:");
    console.error(error);
    console.log("\n💡 If deployment failed:");
    console.log("  - Check which chain/step failed in the output above");
    console.log("  - You may need to redeploy all pools (they're independent)");
    console.log("  - Check RMN addresses are correct for each chain");
    process.exit(1);
  });
