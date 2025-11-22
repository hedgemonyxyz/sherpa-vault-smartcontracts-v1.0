const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Deploy NEW CCIP Pools for Current shUSD (Vault) Deployment
 *
 * Old pools (no longer usable):
 *   Sepolia: 0xe3D3a59533F27ddCb8b343F72A9A7EAF6B5dABE2 (points to old shUSD)
 *   Base: 0x034475c6f81c806C2DAAc701eDaC9138d02c2Dff (points to old shUSD)
 *
 * This will deploy new pools for:
 *   Sepolia shUSD (vault): 0xf83f4771B862161E640c9544c8a0b81d910af062
 *   Base shUSD (vault): 0x7B70B1Db19F5CbCf9e8520619DcA2c12782d4bCF
 *
 * NOTE: shUSD is the vault token that users hold. SherpaUSD is just the wrapper.
 */

// Load current deployment
const deployment = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../../deployments/deployment.json"), "utf8")
);

const SEPOLIA_SHUSD = deployment.sepolia.vault;  // shUSD = vault token
const BASE_SHUSD = deployment.base.vault;  // shUSD = vault token

// CCIP Infrastructure
const SEPOLIA_RMN_PROXY = "0xba3f6251de62dED61Ff98590cB2fDf6871FbB991";
const BASE_RMN_PROXY = "0x99360767a4705f68CcCb9533195B761648d6d807";

const SEPOLIA_ROUTER = deployment.sepolia.ccipRouter;
const BASE_ROUTER = deployment.base.ccipRouter;

const SEPOLIA_CHAIN_SELECTOR = deployment.sepolia.chainSelector;
const BASE_CHAIN_SELECTOR = deployment.base.chainSelector;

// Token Admin Registry
const SEPOLIA_TOKEN_ADMIN_REGISTRY = "0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82";
const BASE_TOKEN_ADMIN_REGISTRY = "0x736D0bBb318c1B27Ff686cd19804094E66250e17";

const SEPOLIA_REGISTRY_MODULE = "0x62e731218d0D47305aba2BE3751E7EE9E5520790";
const BASE_REGISTRY_MODULE = "0x8A55C61227f26a3e2f217842eCF20b52007bAaBe";

// Load official Chainlink BurnFromMintTokenPool (compiled via ChainlinkPoolImport.sol)
const poolArtifact = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../../artifacts/@chainlink/contracts-ccip/contracts/pools/BurnFromMintTokenPool.sol/BurnFromMintTokenPool.json"), "utf8")
);

async function main() {
  console.log("=".repeat(70));
  console.log("🏊 DEPLOYING NEW CCIP TOKEN POOLS");
  console.log("=".repeat(70));
  console.log();

  const sepoliaProvider = new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const baseProvider = new ethers.providers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC_URL);

  const sepoliaWallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY, sepoliaProvider);
  const baseWallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY, baseProvider);

  console.log("Deployer:", sepoliaWallet.address);
  console.log();
  console.log("Current shUSD (Vault) Addresses:");
  console.log("  Sepolia:", SEPOLIA_SHUSD);
  console.log("  Base:", BASE_SHUSD);
  console.log();
  console.log("NOTE: Deploying pools for shUSD (vault token), NOT SherpaUSD (wrapper)");
  console.log();

  // ===================================================================
  // STEP 1: REGISTER AS TOKEN ADMIN
  // ===================================================================

  console.log("📍 STEP 1: Registering as token admin");
  console.log("-".repeat(70));

  const REGISTRY_MODULE_ABI = ["function registerAdminViaOwner(address token) external"];
  const TOKEN_ADMIN_REGISTRY_ABI = [
    "function acceptAdminRole(address token) external",
    "function setPool(address token, address pool) external",
    "function getPool(address token) external view returns (address)"
  ];

  const sepoliaRegistryModule = new ethers.Contract(SEPOLIA_REGISTRY_MODULE, REGISTRY_MODULE_ABI, sepoliaWallet);
  const baseRegistryModule = new ethers.Contract(BASE_REGISTRY_MODULE, REGISTRY_MODULE_ABI, baseWallet);

  const sepoliaTokenAdmin = new ethers.Contract(SEPOLIA_TOKEN_ADMIN_REGISTRY, TOKEN_ADMIN_REGISTRY_ABI, sepoliaWallet);
  const baseTokenAdmin = new ethers.Contract(BASE_TOKEN_ADMIN_REGISTRY, TOKEN_ADMIN_REGISTRY_ABI, baseWallet);

  // Check if already registered
  let sepoliaPoolCheck = await sepoliaTokenAdmin.getPool(SEPOLIA_SHUSD);
  let basePoolCheck = await baseTokenAdmin.getPool(BASE_SHUSD);

  if (sepoliaPoolCheck === ethers.constants.AddressZero) {
    console.log("Registering Sepolia admin...");
    try {
      let tx = await sepoliaRegistryModule.registerAdminViaOwner(SEPOLIA_SHUSD);
      await tx.wait();
      console.log("  ✅ Sepolia admin registered");
    } catch (e) {
      console.log("  ℹ️  Sepolia admin already registered");
    }

    console.log("Accepting Sepolia admin role...");
    try {
      let tx = await sepoliaTokenAdmin.acceptAdminRole(SEPOLIA_SHUSD);
      await tx.wait();
      console.log("  ✅ Sepolia admin role accepted");
    } catch (e) {
      console.log("  ℹ️  Sepolia admin role already accepted");
    }
  } else {
    console.log("  ℹ️  Sepolia already has pool registered, skipping admin registration");
  }

  if (basePoolCheck === ethers.constants.AddressZero) {
    console.log("Registering Base admin...");
    try {
      let tx = await baseRegistryModule.registerAdminViaOwner(BASE_SHUSD);
      await tx.wait();
      console.log("  ✅ Base admin registered");
    } catch (e) {
      console.log("  ℹ️  Base admin already registered");
    }

    console.log("Accepting Base admin role...");
    try {
      let tx = await baseTokenAdmin.acceptAdminRole(BASE_SHUSD);
      await tx.wait();
      console.log("  ✅ Base admin role accepted");
    } catch (e) {
      console.log("  ℹ️  Base admin role already accepted");
    }
  } else {
    console.log("  ℹ️  Base already has pool registered, skipping admin registration");
  }

  console.log();

  // ===================================================================
  // STEP 2: DEPLOY POOLS
  // ===================================================================

  console.log("📍 STEP 2: Deploying Official Chainlink BurnFromMintTokenPool");
  console.log("-".repeat(70));

  console.log("Deploying Sepolia BurnFromMintTokenPool...");
  const sepoliaPoolFactory = new ethers.ContractFactory(poolArtifact.abi, poolArtifact.bytecode, sepoliaWallet);
  const sepoliaPool = await sepoliaPoolFactory.deploy(
    SEPOLIA_SHUSD,        // token
    6,                     // decimals
    [],                    // allowlist (empty = no restrictions)
    SEPOLIA_RMN_PROXY,     // RMN proxy for security
    SEPOLIA_ROUTER         // CCIP router
  );
  await sepoliaPool.deployed();
  console.log(`  ✅ Sepolia Pool: ${sepoliaPool.address}`);
  console.log();

  console.log("Deploying Base BurnFromMintTokenPool...");
  const basePoolFactory = new ethers.ContractFactory(poolArtifact.abi, poolArtifact.bytecode, baseWallet);
  const basePool = await basePoolFactory.deploy(
    BASE_SHUSD,            // token
    6,                     // decimals
    [],                    // allowlist (empty = no restrictions)
    BASE_RMN_PROXY,        // RMN proxy for security
    BASE_ROUTER            // CCIP router
  );
  await basePool.deployed();
  console.log(`  ✅ Base Pool: ${basePool.address}`);
  console.log();

  // ===================================================================
  // STEP 3: REGISTER POOLS IN TOKEN ADMIN REGISTRY
  // ===================================================================

  console.log("📍 STEP 3: Registering pools in TokenAdminRegistry");
  console.log("-".repeat(70));

  let tx = await sepoliaTokenAdmin.setPool(SEPOLIA_SHUSD, sepoliaPool.address);
  await tx.wait();
  console.log("  ✅ Sepolia pool registered");

  tx = await baseTokenAdmin.setPool(BASE_SHUSD, basePool.address);
  await tx.wait();
  console.log("  ✅ Base pool registered");
  console.log();

  // ===================================================================
  // STEP 4: CONFIGURE CROSS-CHAIN ROUTING
  // ===================================================================

  console.log("📍 STEP 4: Configuring cross-chain routing");
  console.log("-".repeat(70));

  // Chainlink's BurnFromMintTokenPool uses applyChainUpdates()
  const POOL_ABI = [
    "function applyChainUpdates(uint64[] calldata remoteChainSelectorsToRemove, tuple(uint64 remoteChainSelector, bytes[] remotePoolAddresses, bytes remoteTokenAddress, tuple(bool isEnabled, uint128 capacity, uint128 rate) outboundRateLimiterConfig, tuple(bool isEnabled, uint128 capacity, uint128 rate) inboundRateLimiterConfig)[] calldata chainsToAdd) external"
  ];

  const sepoliaPoolContract = new ethers.Contract(sepoliaPool.address, POOL_ABI, sepoliaWallet);
  const basePoolContract = new ethers.Contract(basePool.address, POOL_ABI, baseWallet);

  // Configure Sepolia -> Base
  const sepoliaChainUpdate = {
    remoteChainSelector: BASE_CHAIN_SELECTOR,
    remotePoolAddresses: [ethers.utils.defaultAbiCoder.encode(["address"], [basePool.address])],
    remoteTokenAddress: ethers.utils.defaultAbiCoder.encode(["address"], [BASE_SHUSD]),
    outboundRateLimiterConfig: { isEnabled: false, capacity: 0, rate: 0 },
    inboundRateLimiterConfig: { isEnabled: false, capacity: 0, rate: 0 }
  };

  tx = await sepoliaPoolContract.applyChainUpdates([], [sepoliaChainUpdate]);
  await tx.wait();
  console.log("  ✅ Sepolia pool configured for Base");

  // Configure Base -> Sepolia
  const baseChainUpdate = {
    remoteChainSelector: SEPOLIA_CHAIN_SELECTOR,
    remotePoolAddresses: [ethers.utils.defaultAbiCoder.encode(["address"], [sepoliaPool.address])],
    remoteTokenAddress: ethers.utils.defaultAbiCoder.encode(["address"], [SEPOLIA_SHUSD]),
    outboundRateLimiterConfig: { isEnabled: false, capacity: 0, rate: 0 },
    inboundRateLimiterConfig: { isEnabled: false, capacity: 0, rate: 0 }
  };

  tx = await basePoolContract.applyChainUpdates([], [baseChainUpdate]);
  await tx.wait();
  console.log("  ✅ Base pool configured for Sepolia");
  console.log();

  // ===================================================================
  // STEP 5: AUTHORIZE POOLS IN SHUSD (VAULT)
  // ===================================================================

  console.log("📍 STEP 5: Authorizing pools in shUSD (vault) tokens");
  console.log("-".repeat(70));

  const vaultArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  );

  const sepoliaVault = new ethers.Contract(SEPOLIA_SHUSD, vaultArtifact.abi, sepoliaWallet);
  const baseVault = new ethers.Contract(BASE_SHUSD, vaultArtifact.abi, baseWallet);

  tx = await sepoliaVault.addCCIPPool(sepoliaPool.address);
  await tx.wait();
  console.log("  ✅ Sepolia pool authorized");

  tx = await baseVault.addCCIPPool(basePool.address);
  await tx.wait();
  console.log("  ✅ Base pool authorized");
  console.log();

  // ===================================================================
  // VERIFICATION
  // ===================================================================

  console.log("📍 VERIFICATION");
  console.log("-".repeat(70));

  const sepoliaAuthorized = await sepoliaVault.ccipPools(sepoliaPool.address);
  const baseAuthorized = await baseVault.ccipPools(basePool.address);

  // Check if chains are configured - reuse existing pool contract instances
  const checkConfigAbi = ["function isSupportedChain(uint64 remoteChainSelector) external view returns (bool)"];
  const sepoliaPoolForCheck = new ethers.Contract(sepoliaPool.address, checkConfigAbi, sepoliaProvider);
  const basePoolForCheck = new ethers.Contract(basePool.address, checkConfigAbi, baseProvider);

  const sepoliaSupportsBase = await sepoliaPoolForCheck.isSupportedChain(BASE_CHAIN_SELECTOR);
  const baseSupportsSepolia = await basePoolForCheck.isSupportedChain(SEPOLIA_CHAIN_SELECTOR);

  console.log("Sepolia:");
  console.log(`  Pool authorized in shUSD vault: ${sepoliaAuthorized ? '✅' : '❌'}`);
  console.log(`  Supports Base chain: ${sepoliaSupportsBase ? '✅' : '❌'}`);
  console.log();
  console.log("Base:");
  console.log(`  Pool authorized in shUSD vault: ${baseAuthorized ? '✅' : '❌'}`);
  console.log(`  Supports Sepolia chain: ${baseSupportsSepolia ? '✅' : '❌'}`);
  console.log();

  // ===================================================================
  // SUMMARY
  // ===================================================================

  console.log("=".repeat(70));
  console.log("🎉 CCIP TOKEN POOLS DEPLOYED SUCCESSFULLY!");
  console.log("=".repeat(70));
  console.log();
  console.log("📋 Deployment Summary:");
  console.log();
  console.log("Sepolia:");
  console.log(`  shUSD (vault): ${SEPOLIA_SHUSD}`);
  console.log(`  CCIP Pool: ${sepoliaPool.address}`);
  console.log(`  Router: ${SEPOLIA_ROUTER}`);
  console.log();
  console.log("Base:");
  console.log(`  shUSD (vault): ${BASE_SHUSD}`);
  console.log(`  CCIP Pool: ${basePool.address}`);
  console.log(`  Router: ${BASE_ROUTER}`);
  console.log();
  console.log("✅ All configured! Users can now bridge shUSD between chains via CCIP.");
  console.log();
  console.log("To save deployment info, update deployments/deployment.json:");
  console.log(`  sepolia.ccipPool: "${sepoliaPool.address}"`);
  console.log(`  base.ccipPool: "${basePool.address}"`);
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ DEPLOYMENT FAILED:");
    console.error(error);
    process.exit(1);
  });
