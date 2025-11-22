const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Fix Pool Route Configuration
 *
 * This script fixes pools that have chains marked as "supported" but don't have
 * remote pool addresses properly set, which causes "Invalid source pool address"
 * errors in CCIP.
 *
 * Usage:
 *   node scripts/system-deployment/fixPoolRoutes.js [chain]
 *
 * Examples:
 *   node scripts/system-deployment/fixPoolRoutes.js base     # Fix Base pool only
 *   node scripts/system-deployment/fixPoolRoutes.js          # Fix all pools
 */

async function main() {
  const chainArg = process.argv[2];
  const chainsToFix = chainArg ? [chainArg] : ["sepolia", "base", "arbitrum"];

  console.log("=".repeat(70));
  console.log("🔧 FIX POOL ROUTE CONFIGURATION");
  console.log("=".repeat(70));
  console.log();

  if (chainArg) {
    console.log(`Fixing pool: ${chainArg}`);
  } else {
    console.log("Fixing all pools");
  }
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const allChains = ["sepolia", "base", "arbitrum"];

  // Verify pools exist
  for (const chain of chainsToFix) {
    if (!allChains.includes(chain)) {
      throw new Error(`Invalid chain: ${chain}. Must be one of: ${allChains.join(", ")}`);
    }
    if (!deployment[chain]?.newCcipPool) {
      throw new Error(`Pool not found for ${chain} in deployment.json`);
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

  for (const chain of allChains) {
    const rpcUrl = process.env[RPC_ENV_VARS[chain]];
    if (!rpcUrl) {
      throw new Error(`Missing ${RPC_ENV_VARS[chain]} in .env`);
    }
    providers[chain] = new ethers.providers.JsonRpcProvider(rpcUrl);
    wallets[chain] = wallet.connect(providers[chain]);
  }

  console.log("Deployer:", wallet.address);
  console.log();

  // Pool ABI
  const POOL_ABI = [
    "function applyChainUpdates(uint64[] calldata remoteChainSelectorsToRemove, tuple(uint64 remoteChainSelector, bytes[] remotePoolAddresses, bytes remoteTokenAddress, tuple(bool isEnabled, uint128 capacity, uint128 rate) outboundRateLimiterConfig, tuple(bool isEnabled, uint128 capacity, uint128 rate) inboundRateLimiterConfig)[] calldata chainsToAdd) external",
    "function isSupportedChain(uint64 remoteChainSelector) external view returns (bool)",
    "function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory)"
  ];

  const rateLimiterConfig = {
    isEnabled: false,
    capacity: 0,
    rate: 0
  };

  // Define routing (which chains each pool should know about)
  const routingConfigs = {
    sepolia: ["base", "arbitrum"],
    base: ["sepolia", "arbitrum"],
    arbitrum: ["sepolia", "base"]
  };

  // Fix each pool
  for (const sourceChain of chainsToFix) {
    console.log("=".repeat(70));
    console.log(`FIXING ${sourceChain.toUpperCase()} POOL`);
    console.log("=".repeat(70));
    console.log();

    const pool = new ethers.Contract(
      deployment[sourceChain].newCcipPool,
      POOL_ABI,
      wallets[sourceChain]
    );

    const remoteChains = routingConfigs[sourceChain];

    // Step 1: Check current state
    console.log("Step 1: Checking current state...");
    const chainsToRemove = [];

    for (const remoteChain of remoteChains) {
      const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);
      console.log(`  ${sourceChain} → ${remoteChain}: ${isSupported ? 'Supported' : 'Not supported'}`);

      if (isSupported) {
        // Check if remote pool is actually set
        try {
          const remotePoolsArray = await pool.getRemotePools(deployment[remoteChain].chainSelector);
          if (remotePoolsArray.length > 0) {
            const remotePoolAddr = '0x' + remotePoolsArray[0].slice(-40);
            if (remotePoolAddr.toLowerCase() === deployment[remoteChain].newCcipPool.toLowerCase()) {
              console.log(`    ✅ Remote pool address correctly set`);
            } else {
              console.log(`    ⚠️  Remote pool address WRONG: ${remotePoolAddr}`);
              chainsToRemove.push(deployment[remoteChain].chainSelector);
            }
          } else {
            console.log(`    ❌ Remote pool address NOT SET (empty array)`);
            chainsToRemove.push(deployment[remoteChain].chainSelector);
          }
        } catch (e) {
          console.log(`    ❌ Remote pool address NOT SET (reverted)`);
          chainsToRemove.push(deployment[remoteChain].chainSelector);
        }
      }
    }
    console.log();

    if (chainsToRemove.length === 0) {
      console.log(`✅ ${sourceChain} pool is already correctly configured. No fix needed.`);
      console.log();
      continue;
    }

    // Step 2: Remove chains
    console.log(`Step 2: Removing ${chainsToRemove.length} chains...`);
    try {
      const removeTx = await pool.applyChainUpdates(chainsToRemove, []);
      console.log(`  Tx: ${removeTx.hash}`);
      await removeTx.wait();
      console.log(`  ✅ Chains removed`);
    } catch (e) {
      console.log(`  ❌ Error removing chains:`, e.message);
      throw e;
    }
    console.log();

    // Step 3: Re-add chains with correct configuration
    console.log("Step 3: Re-adding chains with correct pool addresses...");

    const chainUpdates = remoteChains.map(remoteChain => ({
      remoteChainSelector: deployment[remoteChain].chainSelector,
      remotePoolAddresses: [
        ethers.utils.defaultAbiCoder.encode(["address"], [deployment[remoteChain].newCcipPool])
      ],
      remoteTokenAddress: ethers.utils.defaultAbiCoder.encode(
        ["address"],
        [deployment[remoteChain].vault]
      ),
      outboundRateLimiterConfig: rateLimiterConfig,
      inboundRateLimiterConfig: rateLimiterConfig
    }));

    try {
      const addTx = await pool.applyChainUpdates([], chainUpdates);
      console.log(`  Tx: ${addTx.hash}`);
      await addTx.wait();
      console.log(`  ✅ Chains re-added with correct configuration`);
    } catch (e) {
      console.log(`  ❌ Error adding chains:`, e.message);
      throw e;
    }
    console.log();

    // Step 4: Verify fix
    console.log("Step 4: Verifying fix...");
    for (const remoteChain of remoteChains) {
      const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);

      let remotePoolSet = false;
      try {
        const remotePoolsArray = await pool.getRemotePools(deployment[remoteChain].chainSelector);
        if (remotePoolsArray.length > 0) {
          const remotePoolAddr = '0x' + remotePoolsArray[0].slice(-40);
          remotePoolSet = remotePoolAddr.toLowerCase() === deployment[remoteChain].newCcipPool.toLowerCase();
        }
      } catch (e) {
        remotePoolSet = false;
      }

      if (isSupported && remotePoolSet) {
        console.log(`  ✅ ${sourceChain} → ${remoteChain}: FIXED`);
      } else {
        console.log(`  ❌ ${sourceChain} → ${remoteChain}: STILL BROKEN`);
      }
    }
    console.log();

    console.log(`✅ ${sourceChain} pool fixed!`);
    console.log();
  }

  console.log("=".repeat(70));
  console.log("🎉 POOL ROUTE FIX COMPLETE");
  console.log("=".repeat(70));
  console.log();
  console.log("All specified pools have been fixed.");
  console.log();
  console.log("📋 NEXT STEPS:");
  console.log("  1. Test a bridge transaction to verify:");
  console.log("     node scripts/testing/singleUserBridgeTokens.js sepolia base 1 1");
  console.log();
  console.log("  2. If tests pass, you can continue with deployment:");
  console.log("     node scripts/system-deployment/enableDepositsAllChains.js");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ FIX FAILED:");
    console.error(error);
    process.exit(1);
  });
