const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Configure Cross-Chain Routing for All CCIP Pools
 *
 * This script configures all pools to communicate with each other:
 * - Sepolia pool → knows about Base + Arbitrum pools
 * - Base pool → knows about Sepolia + Arbitrum pools
 * - Arbitrum pool → knows about Sepolia + Base pools
 *
 * CRITICAL: Uses pool addresses from Token Admin Registry to avoid
 * "Invalid source pool address" errors (see docs/CCIP_TROUBLESHOOTING.md)
 *
 * Prerequisites:
 * - Pools must be deployed (deployAllCCIPPools.js)
 * - Pools must be registered in Token Admin Registry
 * - deployment.json must have pool addresses
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🔗 CONFIGURING CROSS-CHAIN ROUTING FOR ALL CCIP POOLS");
  console.log("=".repeat(70));
  console.log();

  // ===================================================================
  // LOAD DEPLOYMENT & SETUP
  // ===================================================================

  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  // Verify pools exist
  for (const chain of chains) {
    if (!deployment[chain]?.newCcipPool) {
      throw new Error(`❌ Pool not found for ${chain}. Run deployAllCCIPPools.js first.`);
    }
  }

  console.log("Pool Addresses:");
  for (const chain of chains) {
    console.log(`  ${chain}: ${deployment[chain].newCcipPool}`);
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

  // Token Admin Registry addresses (for verifying pool addresses)
  const TOKEN_ADMIN_REGISTRIES = {
    sepolia: "0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82",
    base: "0x736D0bBb318c1B27Ff686cd19804094E66250e17",
    arbitrum: "0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f"
  };

  // ===================================================================
  // STEP 1: VERIFY POOL ADDRESSES VIA TOKEN ADMIN REGISTRY
  // ===================================================================

  console.log("📍 STEP 1: VERIFYING POOL ADDRESSES VIA TOKEN ADMIN REGISTRY");
  console.log("-".repeat(70));
  console.log("(This prevents 'Invalid source pool address' errors)");
  console.log();

  const TOKEN_ADMIN_REGISTRY_ABI = [
    "function getPool(address token) external view returns (address)"
  ];

  const registeredPools = {};

  for (const chain of chains) {
    const tokenAdmin = new ethers.Contract(
      TOKEN_ADMIN_REGISTRIES[chain],
      TOKEN_ADMIN_REGISTRY_ABI,
      providers[chain]
    );

    const shUSD = deployment[chain].vault;
    const registeredPool = await tokenAdmin.getPool(shUSD);

    registeredPools[chain] = registeredPool;

    console.log(`${chain}:`);
    console.log(`  shUSD token: ${shUSD}`);
    console.log(`  Registered pool: ${registeredPool}`);
    console.log(`  deployment.json pool: ${deployment[chain].newCcipPool}`);

    if (registeredPool.toLowerCase() !== deployment[chain].newCcipPool.toLowerCase()) {
      console.log(`  ⚠️  WARNING: Mismatch detected!`);
      console.log(`     Will use registered pool: ${registeredPool}`);
    } else {
      console.log(`  ✅ Addresses match`);
    }
    console.log();
  }

  // Use registered pools for configuration (source of truth!)
  const pools = {
    sepolia: registeredPools.sepolia,
    base: registeredPools.base,
    arbitrum: registeredPools.arbitrum
  };

  // ===================================================================
  // STEP 2: CONFIGURE CROSS-CHAIN ROUTING
  // ===================================================================

  console.log("📍 STEP 2: CONFIGURING CROSS-CHAIN ROUTING");
  console.log("-".repeat(70));
  console.log();

  // Pool ABI for configuration
  const POOL_ABI = [
    "function applyChainUpdates(uint64[] calldata remoteChainSelectorsToRemove, tuple(uint64 remoteChainSelector, bytes[] remotePoolAddresses, bytes remoteTokenAddress, tuple(bool isEnabled, uint128 capacity, uint128 rate) outboundRateLimiterConfig, tuple(bool isEnabled, uint128 capacity, uint128 rate) inboundRateLimiterConfig)[] calldata chainsToAdd) external",
    "function isSupportedChain(uint64 remoteChainSelector) external view returns (bool)",
    "function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory)",
    "function getRemoteToken(uint64 remoteChainSelector) external view returns (bytes memory)"
  ];

  // Rate limiter config (disabled)
  const rateLimiterConfig = {
    isEnabled: false,
    capacity: 0,
    rate: 0
  };

  // Configure each pool to know about the other two chains
  const routingConfigs = {
    sepolia: ["base", "arbitrum"],      // Sepolia knows about Base + Arbitrum
    base: ["sepolia", "arbitrum"],      // Base knows about Sepolia + Arbitrum
    arbitrum: ["sepolia", "base"]       // Arbitrum knows about Sepolia + Base
  };

  for (const [sourceChain, remoteChains] of Object.entries(routingConfigs)) {
    console.log(`Configuring ${sourceChain} pool → knows about: ${remoteChains.join(", ")}`);

    const pool = new ethers.Contract(pools[sourceChain], POOL_ABI, wallets[sourceChain]);

    // Build chain updates for all remote chains
    const chainUpdates = remoteChains.map(remoteChain => ({
      remoteChainSelector: deployment[remoteChain].chainSelector,
      remotePoolAddresses: [
        ethers.utils.defaultAbiCoder.encode(["address"], [pools[remoteChain]])
      ],
      remoteTokenAddress: ethers.utils.defaultAbiCoder.encode(
        ["address"],
        [deployment[remoteChain].vault]
      ),
      outboundRateLimiterConfig: rateLimiterConfig,
      inboundRateLimiterConfig: rateLimiterConfig
    }));

    console.log(`  Configuring ${chainUpdates.length} remote chains...`);

    try {
      const tx = await pool.applyChainUpdates([], chainUpdates);
      const receipt = await tx.wait();
      console.log(`    ✅ Transaction confirmed (block ${receipt.blockNumber})`);

      // Small delay to ensure state is updated before checking
      await new Promise(resolve => setTimeout(resolve, 2000));

      // Verify configuration
      for (const remoteChain of remoteChains) {
        const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);
        console.log(`    ${isSupported ? '✅' : '❌'} ${sourceChain} → ${remoteChain}: ${isSupported ? 'CONFIGURED' : 'NOT CONFIGURED'}`);
      }
    } catch (error) {
      // Check if error is because chain already configured
      if (error.message.includes("ChainAlreadyExists") || error.message.includes("0x1d5ad3c5") || error.message.includes("already configured")) {
        console.log(`    ℹ️  Chains already exist, verifying remote pool addresses are set...`);

        let needsReconfiguration = false;

        for (const remoteChain of remoteChains) {
          const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);

          // Try to verify remote pool address is actually set
          let remotePoolSet = false;
          try {
            const remotePoolsArray = await pool.getRemotePools(deployment[remoteChain].chainSelector);
            if (remotePoolsArray.length > 0) {
              const remotePoolAddr = '0x' + remotePoolsArray[0].slice(-40);
              remotePoolSet = remotePoolAddr.toLowerCase() === pools[remoteChain].toLowerCase();
            }

            if (!remotePoolSet) {
              console.log(`    ⚠️  ${sourceChain} → ${remoteChain}: Chain supported but WRONG remote pool!`);
              console.log(`       Expected: ${pools[remoteChain]}, Got: ${remotePoolAddr}`);
              needsReconfiguration = true;
            } else {
              console.log(`    ✅ ${sourceChain} → ${remoteChain}: ALREADY CONFIGURED CORRECTLY`);
            }
          } catch (e) {
            // getRemotePools reverts if not set (even though isSupportedChain returns true!)
            console.log(`    ❌ ${sourceChain} → ${remoteChain}: Chain marked as supported but REMOTE POOL NOT SET!`);
            needsReconfiguration = true;
          }
        }

        if (needsReconfiguration) {
          console.log();
          console.log(`    ⚠️  ${sourceChain} needs reconfiguration!`);
          console.log(`    💡 Fix: Remove chains and re-add with correct pool addresses`);
          console.log(`       Run: node scripts/system-deployment/fixPoolRoutes.js ${sourceChain}`);
          console.log();

          throw new Error(`Pool configuration incomplete for ${sourceChain}. Remote pool addresses not set.`);
        }
      } else {
        console.log(`    ❌ Error configuring ${sourceChain}:`, error.message);
        throw error;
      }
    }
    console.log();
  }

  // ===================================================================
  // STEP 3: UPDATE DEPLOYMENT.JSON
  // ===================================================================

  console.log("📍 STEP 3: UPDATING DEPLOYMENT.JSON");
  console.log("-".repeat(70));
  console.log();

  deployment.status = "ccip-routing-configured";
  deployment.notes = "✅ All CCIP pools configured for cross-chain bridging. Deposits still paused. Run enableDepositsAllChains.js next.";

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("✅ deployment.json status updated");
  console.log();

  // ===================================================================
  // VERIFICATION
  // ===================================================================

  console.log("📍 VERIFICATION: DEEP CHECK OF ALL ROUTES");
  console.log("-".repeat(70));
  console.log();

  const verificationResults = [];
  let verificationErrors = [];

  for (const [sourceChain, remoteChains] of Object.entries(routingConfigs)) {
    const pool = new ethers.Contract(pools[sourceChain], POOL_ABI, providers[sourceChain]);

    for (const remoteChain of remoteChains) {
      const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);

      // Deep verification: check if remote pool address is actually set
      let remotePoolConfigured = false;
      let expectedPool = pools[remoteChain];
      let actualPool = null;

      try {
        const remotePoolsArray = await pool.getRemotePools(deployment[remoteChain].chainSelector);
        if (remotePoolsArray.length > 0) {
          actualPool = '0x' + remotePoolsArray[0].slice(-40);
          remotePoolConfigured = actualPool.toLowerCase() === expectedPool.toLowerCase();
        }
      } catch (e) {
        // getRemotePools reverts if not configured
        remotePoolConfigured = false;
      }

      const fullyConfigured = isSupported && remotePoolConfigured;

      verificationResults.push({
        route: `${sourceChain} → ${remoteChain}`,
        supported: isSupported,
        remotePoolSet: remotePoolConfigured,
        fullyConfigured: fullyConfigured,
        expectedPool,
        actualPool
      });

      if (!fullyConfigured) {
        if (isSupported && !remotePoolConfigured) {
          verificationErrors.push(`${sourceChain} → ${remoteChain}: Chain marked as supported but remote pool address NOT SET!`);
        } else if (!isSupported) {
          verificationErrors.push(`${sourceChain} → ${remoteChain}: Chain not supported`);
        }
      }
    }
  }

  console.log("Route Configuration (Deep Verification):");
  for (const result of verificationResults) {
    const status = result.fullyConfigured ? '✅' : '❌';
    console.log(`  ${result.route}: ${status}`);
    if (!result.fullyConfigured && result.supported && !result.remotePoolSet) {
      console.log(`    ⚠️  Chain supported but remote pool address NOT SET`);
    }
    if (!result.fullyConfigured && result.actualPool && result.actualPool !== result.expectedPool) {
      console.log(`    ⚠️  Wrong remote pool: expected ${result.expectedPool}, got ${result.actualPool}`);
    }
  }
  console.log();

  const allConfigured = verificationResults.every(r => r.fullyConfigured);

  if (!allConfigured) {
    console.error("❌ CRITICAL ERROR: Some routes are NOT properly configured!");
    console.log();
    console.log("Errors detected:");
    for (const error of verificationErrors) {
      console.log(`  - ${error}`);
    }
    console.log();
    console.log("💡 This usually means:");
    console.log("  - Chains were marked as 'supported' but remote pool addresses were never set");
    console.log("  - This causes 'Invalid source pool address' errors in CCIP");
    console.log();
    console.log("🔧 To fix:");
    console.log("  1. Remove the chains: pool.applyChainUpdates([chainSelector], [])");
    console.log("  2. Re-add with correct pool addresses: pool.applyChainUpdates([], [chainConfig])");
    console.log("  3. Or run the automated fix script if available");
    console.log();

    throw new Error("Pool configuration incomplete. Remote pool addresses not properly set.");
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("🎉 CROSS-CHAIN ROUTING CONFIGURED!");
  console.log("=".repeat(70));
  console.log();
  console.log("📋 Configuration Summary:");
  console.log();
  console.log("Routes Configured: (6 total = 3 chains × 2 directions)");
  console.log("  Sepolia ↔ Base");
  console.log("  Sepolia ↔ Arbitrum");
  console.log("  Base ↔ Arbitrum");
  console.log();
  console.log("Pool Addresses:");
  for (const chain of chains) {
    console.log(`  ${chain}: ${pools[chain]}`);
  }
  console.log();
  console.log("✅ All pools configured for cross-chain communication");
  console.log("✅ Token Admin Registry addresses verified");
  console.log("✅ deployment.json updated");
  console.log();
  console.log("⚠️  Deposits still PAUSED on all chains");
  console.log();
  console.log("📋 NEXT STEP:");
  console.log("  node scripts/system-deployment/enableDepositsAllChains.js");
  console.log();
  console.log("🧪 OPTIONAL TEST:");
  console.log("  Test bridge before enabling deposits:");
  console.log("  node scripts/testing/singleUserBridgeTokens.js sepolia base 1 1");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ CONFIGURATION FAILED:");
    console.error(error);
    console.log("\n💡 Common issues:");
    console.log("  - 'Invalid source pool address': Use pool from Token Admin Registry");
    console.log("  - 'Not authorized': Ensure pool is authorized in vault (addCCIPPool)");
    console.log("  - 'Chain already configured': This is OK, script is idempotent");
    console.log("\n📚 See docs/CCIP_TROUBLESHOOTING.md for detailed help");
    process.exit(1);
  });
