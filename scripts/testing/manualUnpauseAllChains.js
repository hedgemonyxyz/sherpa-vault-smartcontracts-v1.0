const { ethers } = require("ethers");
const fs = require("fs");
require("dotenv").config();

/**
 * Manual Unpause All Chains
 *
 * Use this script to manually unpause all vaults after a successful round roll
 * that failed to complete the unpause step.
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🔓 MANUAL UNPAUSE ALL CHAINS");
  console.log("=".repeat(70));
  console.log();

  // Load deployment data
  const deployment = JSON.parse(
    fs.readFileSync("deployments/deployment.json", "utf8")
  );

  // Load vault ABI
  const vaultArtifact = JSON.parse(
    fs.readFileSync("artifacts/contracts/SherpaVault.sol/SherpaVault.json", "utf8")
  );

  const chains = [
    { name: "sepolia", rpcEnvVar: "SEPOLIA_RPC_URL" },
    { name: "base", rpcEnvVar: "BASE_SEPOLIA_RPC_URL" },
    { name: "arbitrum", rpcEnvVar: "ARBITRUM_SEPOLIA_RPC_URL" }
  ];

  // Setup wallet
  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY);
  console.log("Operator:", wallet.address);
  console.log();

  // Check current pause status
  console.log("📊 Current Pause Status:");
  console.log("-".repeat(70));

  for (const chain of chains) {
    const provider = new ethers.providers.JsonRpcProvider(process.env[chain.rpcEnvVar]);
    const vault = new ethers.Contract(
      deployment[chain.name].vault,
      vaultArtifact.abi,
      provider
    );
    const isPaused = await vault.isPaused();
    const status = isPaused ? "⏸️  PAUSED" : "▶️  ACTIVE";
    console.log(`  ${chain.name.padEnd(15)} ${status}`);
  }
  console.log();

  // Unpause all chains
  console.log("🔓 Unpausing all chains...");
  console.log("-".repeat(70));

  for (const chain of chains) {
    const provider = new ethers.providers.JsonRpcProvider(process.env[chain.rpcEnvVar]);
    const vault = new ethers.Contract(
      deployment[chain.name].vault,
      vaultArtifact.abi,
      wallet.connect(provider)
    );

    const isPaused = await vault.isPaused();
    if (!isPaused) {
      console.log(`  ${chain.name}: Already active ✅`);
      continue;
    }

    console.log(`  ${chain.name}: Sending unpause transaction...`);
    const tx = await vault.setSystemPaused(false, {
      maxFeePerGas: ethers.utils.parseUnits("2", "gwei"),
      maxPriorityFeePerGas: ethers.utils.parseUnits("1.5", "gwei")
    });

    console.log(`    TX: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`    ✅ Unpaused in block ${receipt.blockNumber}`);
  }

  console.log();
  console.log("📊 Final Pause Status:");
  console.log("-".repeat(70));

  for (const chain of chains) {
    const provider = new ethers.providers.JsonRpcProvider(process.env[chain.rpcEnvVar]);
    const vault = new ethers.Contract(
      deployment[chain.name].vault,
      vaultArtifact.abi,
      provider
    );
    const isPaused = await vault.isPaused();
    const status = isPaused ? "⏸️  PAUSED" : "▶️  ACTIVE";
    console.log(`  ${chain.name.padEnd(15)} ${status}`);
  }

  console.log();
  console.log("=".repeat(70));
  console.log("✅ UNPAUSE COMPLETE!");
  console.log("=".repeat(70));
  console.log();
  console.log("System is now active and ready for user interactions.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
