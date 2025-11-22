const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Pre-Flight Check - Comprehensive System Verification
 *
 * Verifies all critical configurations before enabling deposits:
 * 1. Pool authorization (mint/burn permissions)
 * 2. Pool registration in Token Admin Registry
 * 3. Cross-chain routing (all 6 routes)
 * 4. Vault-wrapper connections
 * 5. Primary/secondary chain settings
 * 6. CCIP router configurations
 * 7. Ownership verification
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🔍 PRE-FLIGHT CHECK - COMPREHENSIVE SYSTEM VERIFICATION");
  console.log("=".repeat(70));
  console.log();

  // ===================================================================
  // LOAD DEPLOYMENT & SETUP
  // ===================================================================

  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  const providers = {
    sepolia: new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL),
    base: new ethers.providers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC_URL),
    arbitrum: new ethers.providers.JsonRpcProvider(process.env.ARBITRUM_SEPOLIA_RPC_URL)
  };

  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY);

  console.log("Deployer Address:", wallet.address);
  console.log();

  const TOKEN_ADMIN_REGISTRIES = {
    sepolia: "0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82",
    base: "0x736D0bBb318c1B27Ff686cd19804094E66250e17",
    arbitrum: "0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f"
  };

  // ABIs
  const VAULT_ABI = [
    "function ccipPools(address) external view returns (bool)",
    "function stableWrapper() external view returns (address)",
    "function isPrimaryChain() external view returns (bool)",
    "function owner() external view returns (address)",
    "function depositsEnabled() external view returns (bool)",
    "function vaultState() external view returns (tuple(uint16 round, uint104 lockedAmount, uint104 lastLockedAmount, uint104 totalPending))",
    "function roundPricePerShare(uint256) external view returns (uint256)"
  ];

  const POOL_ABI = [
    "function isSupportedChain(uint64) external view returns (bool)",
    "function getRemotePools(uint64) external view returns (bytes[] memory)",
    "function getRemotePool(uint64) external view returns (bytes memory)",
    "function getRemoteToken(uint64) external view returns (bytes memory)"
  ];

  const TOKEN_ADMIN_REGISTRY_ABI = [
    "function getPool(address token) external view returns (address)"
  ];

  const WRAPPER_ABI = [
    "function asset() external view returns (address)",
    "function keeper() external view returns (address)"
  ];

  const issues = [];
  const warnings = [];

  // ===================================================================
  // CHECK 1: POOL AUTHORIZATION
  // ===================================================================

  console.log("📍 CHECK 1: POOL AUTHORIZATION");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const vault = new ethers.Contract(deployment[chain].vault, VAULT_ABI, providers[chain]);
    const isAuthorized = await vault.ccipPools(deployment[chain].newCcipPool);

    console.log(`${chain}:`);
    console.log(`  Pool: ${deployment[chain].newCcipPool}`);
    console.log(`  Authorized: ${isAuthorized ? '✅' : '❌'}`);

    if (!isAuthorized) {
      issues.push(`${chain}: Pool not authorized in vault - cannot mint/burn shUSD!`);
    }
    console.log();
  }

  // ===================================================================
  // CHECK 2: TOKEN ADMIN REGISTRY
  // ===================================================================

  console.log("📍 CHECK 2: TOKEN ADMIN REGISTRY");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const tokenAdmin = new ethers.Contract(
      TOKEN_ADMIN_REGISTRIES[chain],
      TOKEN_ADMIN_REGISTRY_ABI,
      providers[chain]
    );

    const registeredPool = await tokenAdmin.getPool(deployment[chain].vault);

    console.log(`${chain}:`);
    console.log(`  Registered pool: ${registeredPool}`);
    console.log(`  Expected pool:   ${deployment[chain].newCcipPool}`);

    const matches = registeredPool.toLowerCase() === deployment[chain].newCcipPool.toLowerCase();
    console.log(`  Matches: ${matches ? '✅' : '❌'}`);

    if (!matches) {
      issues.push(`${chain}: Pool address mismatch in Token Admin Registry!`);
    }
    console.log();
  }

  // ===================================================================
  // CHECK 3: CROSS-CHAIN ROUTING (6 ROUTES)
  // ===================================================================

  console.log("📍 CHECK 3: CROSS-CHAIN ROUTING");
  console.log("-".repeat(70));
  console.log();

  const routingConfigs = {
    sepolia: ["base", "arbitrum"],
    base: ["sepolia", "arbitrum"],
    arbitrum: ["sepolia", "base"]
  };

  for (const [sourceChain, remoteChains] of Object.entries(routingConfigs)) {
    console.log(`${sourceChain} routes:`);

    const pool = new ethers.Contract(
      deployment[sourceChain].newCcipPool,
      POOL_ABI,
      providers[sourceChain]
    );

    for (const remoteChain of remoteChains) {
      const isSupported = await pool.isSupportedChain(deployment[remoteChain].chainSelector);

      // Deep verification: check if remote pool address is actually set
      let remotePoolConfigured = false;
      let remotePoolAddress = null;

      if (isSupported) {
        try {
          // Try getRemotePool first (singular)
          const remotePoolBytes = await pool.getRemotePool(deployment[remoteChain].chainSelector);
          remotePoolAddress = '0x' + remotePoolBytes.slice(-40);
          remotePoolConfigured = remotePoolAddress.toLowerCase() === deployment[remoteChain].newCcipPool.toLowerCase();
        } catch (e1) {
          // If getRemotePool fails, try getRemotePools (plural)
          try {
            const remotePools = await pool.getRemotePools(deployment[remoteChain].chainSelector);
            const decodedPool = ethers.utils.defaultAbiCoder.decode(["address"], remotePools[0])[0];
            remotePoolAddress = decodedPool;
            remotePoolConfigured = decodedPool.toLowerCase() === deployment[remoteChain].newCcipPool.toLowerCase();
          } catch (e2) {
            // Both functions failed - remote pool not configured
            remotePoolConfigured = false;
          }
        }
      }

      const status = isSupported && remotePoolConfigured ? '✅' : '❌';
      console.log(`  → ${remoteChain}: ${status}`);

      if (!isSupported) {
        issues.push(`${sourceChain} → ${remoteChain}: Route not configured!`);
      } else if (!remotePoolConfigured) {
        issues.push(`${sourceChain} → ${remoteChain}: CRITICAL - Chain supported but remote pool address NOT SET! This causes "Invalid source pool address" errors.`);
        console.log(`    ⚠️  CRITICAL: Remote pool address not configured!`);
        console.log(`    💡 Fix: node scripts/system-deployment/fixPoolRoutes.js ${sourceChain}`);
      } else if (remotePoolAddress && remotePoolAddress.toLowerCase() !== deployment[remoteChain].newCcipPool.toLowerCase()) {
        issues.push(`${sourceChain} → ${remoteChain}: Remote pool address mismatch! Expected ${deployment[remoteChain].newCcipPool}, got ${remotePoolAddress}`);
      }
    }
    console.log();
  }

  // ===================================================================
  // CHECK 4: VAULT-WRAPPER CONNECTIONS
  // ===================================================================

  console.log("📍 CHECK 4: VAULT-WRAPPER CONNECTIONS");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const vault = new ethers.Contract(deployment[chain].vault, VAULT_ABI, providers[chain]);
    const wrapper = new ethers.Contract(deployment[chain].sherpaUSD, WRAPPER_ABI, providers[chain]);

    const vaultWrapper = await vault.stableWrapper();
    const wrapperAsset = await wrapper.asset();
    const wrapperKeeper = await wrapper.keeper();

    console.log(`${chain}:`);
    console.log(`  Vault's wrapper: ${vaultWrapper}`);
    console.log(`  Expected:        ${deployment[chain].sherpaUSD}`);
    console.log(`  Match: ${vaultWrapper.toLowerCase() === deployment[chain].sherpaUSD.toLowerCase() ? '✅' : '❌'}`);
    console.log();
    console.log(`  Wrapper's keeper: ${wrapperKeeper}`);
    console.log(`  Expected:         ${deployment[chain].vault}`);
    console.log(`  Match: ${wrapperKeeper.toLowerCase() === deployment[chain].vault.toLowerCase() ? '✅' : '❌'}`);
    console.log();
    console.log(`  Wrapper's asset: ${wrapperAsset}`);
    console.log(`  Expected:        ${deployment[chain].mockUSDC}`);
    console.log(`  Match: ${wrapperAsset.toLowerCase() === deployment[chain].mockUSDC.toLowerCase() ? '✅' : '❌'}`);

    if (vaultWrapper.toLowerCase() !== deployment[chain].sherpaUSD.toLowerCase()) {
      issues.push(`${chain}: Vault wrapper mismatch!`);
    }
    if (wrapperKeeper.toLowerCase() !== deployment[chain].vault.toLowerCase()) {
      issues.push(`${chain}: Wrapper keeper mismatch!`);
    }
    if (wrapperAsset.toLowerCase() !== deployment[chain].mockUSDC.toLowerCase()) {
      issues.push(`${chain}: Wrapper asset mismatch!`);
    }
    console.log();
  }

  // ===================================================================
  // CHECK 5: PRIMARY/SECONDARY CHAIN SETTINGS
  // ===================================================================

  console.log("📍 CHECK 5: PRIMARY/SECONDARY CHAIN SETTINGS");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const vault = new ethers.Contract(deployment[chain].vault, VAULT_ABI, providers[chain]);
    const isPrimary = await vault.isPrimaryChain();
    const expectedPrimary = deployment[chain].isPrimary || false;

    console.log(`${chain}:`);
    console.log(`  isPrimaryChain: ${isPrimary}`);
    console.log(`  Expected:       ${expectedPrimary}`);
    console.log(`  Match: ${isPrimary === expectedPrimary ? '✅' : '❌'}`);

    if (isPrimary !== expectedPrimary) {
      issues.push(`${chain}: Primary/secondary mismatch!`);
    }
    console.log();
  }

  // Verify only one primary
  const primaryCount = chains.filter(c => deployment[c].isPrimary).length;
  if (primaryCount !== 1) {
    issues.push(`Expected exactly 1 primary chain, found ${primaryCount}!`);
  }

  // ===================================================================
  // CHECK 6: OWNERSHIP
  // ===================================================================

  console.log("📍 CHECK 7: OWNERSHIP");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const vault = new ethers.Contract(deployment[chain].vault, VAULT_ABI, providers[chain]);
    const owner = await vault.owner();

    console.log(`${chain} vault owner: ${owner}`);
    console.log(`  Deployer: ${wallet.address}`);
    console.log(`  Match: ${owner.toLowerCase() === wallet.address.toLowerCase() ? '✅' : '❌'}`);

    if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
      issues.push(`${chain}: Vault owner is not deployer!`);
    }
    console.log();
  }

  // ===================================================================
  // CHECK 8: DEPOSITS STATUS
  // ===================================================================

  console.log("📍 CHECK 8: DEPOSITS STATUS");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    const vault = new ethers.Contract(deployment[chain].vault, VAULT_ABI, providers[chain]);
    const depositsEnabled = await vault.depositsEnabled();

    console.log(`${chain}: Deposits ${depositsEnabled ? 'ENABLED ⚠️' : 'PAUSED ✅'}`);

    if (depositsEnabled) {
      warnings.push(`${chain}: Deposits already enabled (expected paused until final verification)`);
    }
  }
  console.log();

  // ===================================================================
  // CHECK 9: CONTRACT DEPLOYMENT VERIFICATION
  // ===================================================================

  console.log("📍 CHECK 9: CONTRACT DEPLOYMENT VERIFICATION");
  console.log("-".repeat(70));
  console.log();

  for (const chain of chains) {
    console.log(`${chain}:`);
    console.log(`  Vault: ${deployment[chain].vault}`);
    console.log(`  Wrapper: ${deployment[chain].sherpaUSD}`);
    console.log(`  Pool: ${deployment[chain].newCcipPool}`);
    console.log(`  Mock USDC: ${deployment[chain].mockUSDC}`);
    console.log();
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("PRE-FLIGHT CHECK SUMMARY");
  console.log("=".repeat(70));
  console.log();

  if (issues.length === 0 && warnings.length === 0) {
    console.log("🎉 ALL CHECKS PASSED!");
    console.log();
    console.log("✅ Pool authorization configured");
    console.log("✅ Token Admin Registry correct");
    console.log("✅ Cross-chain routing configured (6 routes)");
    console.log("✅ Vault-wrapper connections correct");
    console.log("✅ Primary/secondary settings correct");
    console.log("✅ Ownership verified");
    console.log("✅ Deposits paused (ready to enable)");
    console.log();
    console.log("🚀 SYSTEM READY FOR PHASE 6 (ENABLE DEPOSITS)");
  } else {
    if (issues.length > 0) {
      console.log(`❌ CRITICAL ISSUES FOUND: ${issues.length}`);
      console.log();
      issues.forEach((issue, i) => {
        console.log(`${i + 1}. ${issue}`);
      });
      console.log();
      console.log("⚠️  DO NOT ENABLE DEPOSITS UNTIL ISSUES ARE RESOLVED!");
    }

    if (warnings.length > 0) {
      console.log(`⚠️  WARNINGS: ${warnings.length}`);
      console.log();
      warnings.forEach((warning, i) => {
        console.log(`${i + 1}. ${warning}`);
      });
      console.log();
      console.log("These warnings may be acceptable depending on deployment stage");
    }
  }

  console.log();
  console.log("=".repeat(70));

  process.exit(issues.length > 0 ? 1 : 0);
}

main()
  .then(() => {})
  .catch((error) => {
    console.error("\n❌ PRE-FLIGHT CHECK FAILED:");
    console.error(error);
    process.exit(1);
  });
