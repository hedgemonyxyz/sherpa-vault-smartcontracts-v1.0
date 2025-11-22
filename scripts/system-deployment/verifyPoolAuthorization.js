const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Verify CCIP Pool Authorization on All Chains
 *
 * Checks that all CCIP pools are properly authorized in their vaults.
 * This is CRITICAL - pools cannot mint/burn shUSD without authorization.
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🔍 VERIFYING CCIP POOL AUTHORIZATION");
  console.log("=".repeat(70));
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  // Setup providers
  const providers = {
    sepolia: new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL),
    base: new ethers.providers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC_URL),
    arbitrum: new ethers.providers.JsonRpcProvider(process.env.ARBITRUM_SEPOLIA_RPC_URL)
  };

  const VAULT_ABI = ["function ccipPools(address) external view returns (bool)"];

  console.log("Pool Addresses:");
  for (const chain of chains) {
    console.log(`  ${chain}: ${deployment[chain].newCcipPool}`);
  }
  console.log();

  console.log("Vault Addresses:");
  for (const chain of chains) {
    console.log(`  ${chain}: ${deployment[chain].vault}`);
  }
  console.log();

  console.log("📍 CHECKING AUTHORIZATION");
  console.log("-".repeat(70));
  console.log();

  const results = [];

  for (const chain of chains) {
    const vault = new ethers.Contract(
      deployment[chain].vault,
      VAULT_ABI,
      providers[chain]
    );

    try {
      const isAuthorized = await vault.ccipPools(deployment[chain].newCcipPool);

      console.log(`${chain}:`);
      console.log(`  Pool: ${deployment[chain].newCcipPool}`);
      console.log(`  Vault: ${deployment[chain].vault}`);
      console.log(`  Authorized: ${isAuthorized ? '✅ true' : '❌ false'}`);

      if (!isAuthorized) {
        console.log(`  ⚠️  CRITICAL: Pool cannot mint/burn shUSD!`);
      }

      console.log();

      results.push({
        chain,
        authorized: isAuthorized
      });
    } catch (error) {
      console.log(`${chain}:`);
      console.log(`  ❌ Error checking authorization: ${error.message}`);
      console.log();

      results.push({
        chain,
        authorized: false,
        error: error.message
      });
    }
  }

  // Summary
  console.log("=".repeat(70));
  console.log("AUTHORIZATION SUMMARY");
  console.log("=".repeat(70));
  console.log();

  const allAuthorized = results.every(r => r.authorized);
  const totalChains = results.length;
  const authorizedCount = results.filter(r => r.authorized).length;

  console.log(`Authorized: ${authorizedCount}/${totalChains}`);
  console.log();

  if (allAuthorized) {
    console.log("🎉 ALL POOLS PROPERLY AUTHORIZED!");
    console.log();
    console.log("✅ All pools can mint/burn shUSD");
    console.log("✅ Cross-chain bridging enabled");
    console.log("✅ System ready for operation");
  } else {
    console.log("⚠️  AUTHORIZATION FAILURES DETECTED!");
    console.log();

    const unauthorized = results.filter(r => !r.authorized);
    console.log("Unauthorized pools:");
    for (const result of unauthorized) {
      console.log(`  - ${result.chain}`);
      if (result.error) {
        console.log(`    Error: ${result.error}`);
      }
    }
    console.log();
    console.log("💡 To fix, run for each failed chain:");
    console.log("   node -e \"");
    console.log("   const { ethers } = require('ethers');");
    console.log("   const fs = require('fs');");
    console.log("   require('dotenv').config();");
    console.log("   ");
    console.log("   async function fix() {");
    console.log("     const deployment = JSON.parse(fs.readFileSync('deployments/deployment.json'));");
    console.log("     const wallet = new ethers.Wallet('0x' + process.env.PRIVATE_KEY);");
    console.log("     const provider = new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL); // or BASE_SEPOLIA_RPC_URL, etc.");
    console.log("     const signer = wallet.connect(provider);");
    console.log("     const vault = new ethers.Contract(deployment.sepolia.vault, ['function addCCIPPool(address)'], signer);");
    console.log("     const tx = await vault.addCCIPPool(deployment.sepolia.newCcipPool);");
    console.log("     await tx.wait();");
    console.log("     console.log('Fixed!');");
    console.log("   }");
    console.log("   fix();");
    console.log("   \"");
  }

  console.log();
  console.log("=".repeat(70));

  process.exit(allAuthorized ? 0 : 1);
}

main()
  .then(() => {})
  .catch((error) => {
    console.error("\n❌ VERIFICATION FAILED:");
    console.error(error);
    process.exit(1);
  });
