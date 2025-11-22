const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { queryWithConsensus, queryMultipleChainsWithConsensus } = require("./consensusProvider");

/**
 * Example: Using Consensus Provider for Critical Operations
 *
 * This example shows how to use consensus queries when rolling rounds
 * to ensure accurate vault state readings before calculating global price.
 */

async function exampleConsensusQuery() {
  const deployment = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../deployments/deployment.json"), "utf8")
  );

  console.log("EXAMPLE 1: Single Chain Query with Consensus");
  console.log("=".repeat(70));

  // Load vault ABI
  const vaultAbi = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  ).abi;

  // Query vault's total assets with consensus
  const totalAssets = await queryWithConsensus(
    "sepolia",
    async (provider) => {
      const vault = new ethers.Contract(
        deployment.sepolia.vault,
        vaultAbi,
        provider
      );
      return await vault.totalAssets();
    },
    {
      minConsensus: 2, // At least 2 RPCs must agree
      timeout: 5000, // 5 second timeout per RPC
    }
  );

  console.log(`\nTotal Assets (consensus): ${ethers.utils.formatUnits(totalAssets, 6)} USDC`);
  console.log();

  console.log("\nEXAMPLE 2: Multi-Chain Query with Consensus");
  console.log("=".repeat(70));

  // Query all chains' vault states with consensus
  const chains = ["sepolia", "base", "arbitrum"];
  const vaultStates = await queryMultipleChainsWithConsensus(
    chains,
    async (chain, provider) => {
      const vault = new ethers.Contract(
        deployment[chain].vault,
        vaultAbi,
        provider
      );

      // Query multiple values in parallel
      const [totalAssets, totalSupply, round, depositsEnabled] = await Promise.all([
        vault.totalAssets(),
        vault.totalSupply(),
        vault.round(),
        vault.depositsEnabled(),
      ]);

      return {
        totalAssets: totalAssets.toString(),
        totalSupply: totalSupply.toString(),
        round: round.toString(),
        depositsEnabled,
      };
    },
    {
      minConsensus: 2,
      requireMajority: true, // Require majority of RPCs to agree
    }
  );

  console.log("\n" + "=".repeat(70));
  console.log("VAULT STATES (CONSENSUS)");
  console.log("=".repeat(70));

  for (const [chain, state] of Object.entries(vaultStates)) {
    console.log(`\n${chain}:`);
    console.log(`  Total Assets: ${ethers.utils.formatUnits(state.totalAssets, 6)} USDC`);
    console.log(`  Total Supply: ${ethers.utils.formatUnits(state.totalSupply, 6)} shUSD`);
    console.log(`  Round: ${state.round}`);
    console.log(`  Deposits: ${state.depositsEnabled ? "ENABLED" : "PAUSED"}`);
  }
}

/**
 * Example: How to integrate consensus queries into rollAllChains script
 */
async function exampleRollWithConsensus() {
  console.log("\nEXAMPLE 3: Roll Round with Consensus (Pseudo-code)");
  console.log("=".repeat(70));
  console.log(`
// In rollAllChains-dynamic.js, replace:
const provider = new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
const vault = new ethers.Contract(vaultAddress, vaultAbi, provider);
const totalAssets = await vault.totalAssets();

// With:
const { queryWithConsensus } = require('./utils/consensusProvider');
const totalAssets = await queryWithConsensus('sepolia', async (provider) => {
  const vault = new ethers.Contract(vaultAddress, vaultAbi, provider);
  return await vault.totalAssets();
}, { minConsensus: 2, requireMajority: true });

// This ensures that at least 2 RPCs agree on the totalAssets value
// before calculating the global price and applying it to all chains!
  `);
}

// Run examples
if (require.main === module) {
  exampleConsensusQuery()
    .then(() => exampleRollWithConsensus())
    .then(() => {
      console.log("\n✅ Examples completed!");
      process.exit(0);
    })
    .catch((error) => {
      console.error("\n❌ Example failed:");
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  exampleConsensusQuery,
  exampleRollWithConsensus,
};
