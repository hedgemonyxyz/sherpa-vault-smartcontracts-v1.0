const { exec } = require("child_process");
const fs = require("fs");
const path = require("path");
const util = require("util");

const execPromise = util.promisify(exec);

/**
 * Verify All Newly Deployed Contracts on Block Explorers
 *
 * Verifies:
 * - 3 SherpaVault (shUSD) contracts
 * - 3 SherpaUSD (wrapper) contracts
 * - 3 CCIP BurnFromMintTokenPool contracts
 */

async function main() {
  console.log("=".repeat(70));
  console.log("🔍 VERIFYING ALL DEPLOYED CONTRACTS ON BLOCK EXPLORERS");
  console.log("=".repeat(70));
  console.log();

  // Load deployment
  const deploymentPath = path.join(__dirname, "../../deployments/deployment.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const chains = ["sepolia", "base", "arbitrum"];

  // Verification commands
  const verifications = [];

  // ===================================================================
  // SEPOLIA CONTRACTS
  // ===================================================================

  console.log("📍 SEPOLIA CONTRACTS");
  console.log("-".repeat(70));

  // Sepolia Vault
  verifications.push({
    chain: "sepolia",
    contract: "SherpaVault",
    address: deployment.sepolia.vault,
    command: `npx hardhat verify --network sepolia --constructor-args scripts/system-deployment/args/args-sepolia-vault.js ${deployment.sepolia.vault}`
  });

  // Sepolia Wrapper
  verifications.push({
    chain: "sepolia",
    contract: "SherpaUSD",
    address: deployment.sepolia.sherpaUSD,
    command: `npx hardhat verify --network sepolia ${deployment.sepolia.sherpaUSD} "${deployment.sepolia.mockUSDC}" "${deployment.sepolia.vault}"`
  });

  // Sepolia Pool
  verifications.push({
    chain: "sepolia",
    contract: "BurnFromMintTokenPool",
    address: deployment.sepolia.newCcipPool,
    command: `npx hardhat verify --network sepolia ${deployment.sepolia.newCcipPool} "${deployment.sepolia.vault}" 6 "[]" "0xba3f6251de62dED61Ff98590cB2fDf6871FbB991" "${deployment.sepolia.ccipRouter}"`
  });

  // ===================================================================
  // BASE CONTRACTS
  // ===================================================================

  console.log("📍 BASE CONTRACTS");
  console.log("-".repeat(70));

  // Base Vault
  verifications.push({
    chain: "base",
    contract: "SherpaVault",
    address: deployment.base.vault,
    command: `npx hardhat verify --network baseSepolia --constructor-args scripts/system-deployment/args/args-base-vault.js ${deployment.base.vault}`
  });

  // Base Wrapper
  verifications.push({
    chain: "base",
    contract: "SherpaUSD",
    address: deployment.base.sherpaUSD,
    command: `npx hardhat verify --network baseSepolia ${deployment.base.sherpaUSD} "${deployment.base.mockUSDC}" "${deployment.base.vault}"`
  });

  // Base Pool
  verifications.push({
    chain: "base",
    contract: "BurnFromMintTokenPool",
    address: deployment.base.newCcipPool,
    command: `npx hardhat verify --network baseSepolia ${deployment.base.newCcipPool} "${deployment.base.vault}" 6 "[]" "0x99360767a4705f68CcCb9533195B761648d6d807" "${deployment.base.ccipRouter}"`
  });

  // ===================================================================
  // ARBITRUM CONTRACTS
  // ===================================================================

  console.log("📍 ARBITRUM CONTRACTS");
  console.log("-".repeat(70));

  // Arbitrum Vault
  verifications.push({
    chain: "arbitrum",
    contract: "SherpaVault",
    address: deployment.arbitrum.vault,
    command: `npx hardhat verify --network arbitrumSepolia --constructor-args scripts/system-deployment/args/args-arbitrum-vault.js ${deployment.arbitrum.vault}`
  });

  // Arbitrum Wrapper
  verifications.push({
    chain: "arbitrum",
    contract: "SherpaUSD",
    address: deployment.arbitrum.sherpaUSD,
    command: `npx hardhat verify --network arbitrumSepolia ${deployment.arbitrum.sherpaUSD} "${deployment.arbitrum.mockUSDC}" "${deployment.arbitrum.vault}"`
  });

  // Arbitrum Pool
  verifications.push({
    chain: "arbitrum",
    contract: "BurnFromMintTokenPool",
    address: deployment.arbitrum.newCcipPool,
    command: `npx hardhat verify --network arbitrumSepolia ${deployment.arbitrum.newCcipPool} "${deployment.arbitrum.vault}" 6 "[]" "0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2" "${deployment.arbitrum.ccipRouter}"`
  });

  // ===================================================================
  // CREATE CONSTRUCTOR ARGS FILES
  // ===================================================================

  console.log("📍 CREATING CONSTRUCTOR ARGS FILES");
  console.log("-".repeat(70));

  const vaultParams = {
    decimals: 6,
    minimumSupply: "1000000",
    cap: "1000000000000"
  };

  // Create args directory if it doesn't exist
  const argsDir = path.join(__dirname, "args");
  if (!fs.existsSync(argsDir)) {
    fs.mkdirSync(argsDir, { recursive: true });
  }

  // Sepolia vault args
  fs.writeFileSync(
    path.join(argsDir, "args-sepolia-vault.js"),
    `module.exports = [
  "Staked Sherpa USD",
  "shUSD",
  "${deployment.sepolia.sherpaUSD}",
  "${deployment.sepolia.ccipRouter}",
  [${vaultParams.decimals}, "${vaultParams.minimumSupply}", "${vaultParams.cap}"]
];`
  );

  // Base vault args
  fs.writeFileSync(
    path.join(argsDir, "args-base-vault.js"),
    `module.exports = [
  "Staked Sherpa USD",
  "shUSD",
  "${deployment.base.sherpaUSD}",
  "${deployment.base.ccipRouter}",
  [${vaultParams.decimals}, "${vaultParams.minimumSupply}", "${vaultParams.cap}"]
];`
  );

  // Arbitrum vault args
  fs.writeFileSync(
    path.join(argsDir, "args-arbitrum-vault.js"),
    `module.exports = [
  "Staked Sherpa USD",
  "shUSD",
  "${deployment.arbitrum.sherpaUSD}",
  "${deployment.arbitrum.ccipRouter}",
  [${vaultParams.decimals}, "${vaultParams.minimumSupply}", "${vaultParams.cap}"]
];`
  );

  console.log("✅ Constructor args files created");
  console.log();

  // ===================================================================
  // RUN VERIFICATIONS
  // ===================================================================

  console.log("📍 RUNNING VERIFICATIONS");
  console.log("-".repeat(70));
  console.log();

  const results = [];

  for (const verification of verifications) {
    console.log(`Verifying ${verification.chain} ${verification.contract}...`);
    console.log(`  Address: ${verification.address}`);

    try {
      const { stdout, stderr } = await execPromise(verification.command);

      if (stdout.includes("Successfully verified") || stdout.includes("already been verified")) {
        console.log(`  ✅ Verified`);
        results.push({ ...verification, status: "success" });
      } else {
        console.log(`  ⚠️  Unknown status`);
        console.log(`  Output: ${stdout.substring(0, 200)}`);
        results.push({ ...verification, status: "unknown", output: stdout });
      }
    } catch (error) {
      console.log(`  ❌ Failed: ${error.message.substring(0, 200)}`);
      results.push({ ...verification, status: "failed", error: error.message });
    }
    console.log();
  }

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("VERIFICATION SUMMARY");
  console.log("=".repeat(70));
  console.log();

  const successCount = results.filter(r => r.status === "success").length;
  const failedCount = results.filter(r => r.status === "failed").length;

  console.log(`✅ Successful: ${successCount}/${verifications.length}`);
  console.log(`❌ Failed: ${failedCount}/${verifications.length}`);
  console.log();

  if (failedCount > 0) {
    console.log("Failed verifications:");
    for (const result of results.filter(r => r.status === "failed")) {
      console.log(`  ${result.chain} ${result.contract}: ${result.address}`);
      console.log(`    Error: ${result.error.substring(0, 150)}`);
    }
    console.log();
  }

  console.log("📋 Contract Links:");
  console.log();
  console.log("Sepolia:");
  console.log(`  Vault: https://sepolia.etherscan.io/address/${deployment.sepolia.vault}#code`);
  console.log(`  Wrapper: https://sepolia.etherscan.io/address/${deployment.sepolia.sherpaUSD}#code`);
  console.log(`  Pool: https://sepolia.etherscan.io/address/${deployment.sepolia.newCcipPool}#code`);
  console.log();
  console.log("Base:");
  console.log(`  Vault: https://sepolia.basescan.org/address/${deployment.base.vault}#code`);
  console.log(`  Wrapper: https://sepolia.basescan.org/address/${deployment.base.sherpaUSD}#code`);
  console.log(`  Pool: https://sepolia.basescan.org/address/${deployment.base.newCcipPool}#code`);
  console.log();
  console.log("Arbitrum:");
  console.log(`  Vault: https://sepolia.arbiscan.io/address/${deployment.arbitrum.vault}#code`);
  console.log(`  Wrapper: https://sepolia.arbiscan.io/address/${deployment.arbitrum.sherpaUSD}#code`);
  console.log(`  Pool: https://sepolia.arbiscan.io/address/${deployment.arbitrum.newCcipPool}#code`);
  console.log();

  console.log("📁 Constructor args files saved in: scripts/system-deployment/args/");
  console.log();

  process.exit(failedCount > 0 ? 1 : 0);
}

main()
  .then(() => {})
  .catch((error) => {
    console.error("\n❌ VERIFICATION FAILED:");
    console.error(error);
    process.exit(1);
  });
