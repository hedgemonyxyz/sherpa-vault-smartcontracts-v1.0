const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

/**
 * Deploy completely fresh system: SherpaUSD + Vaults on both chains
 */

async function main() {
  console.log("=".repeat(70));
  console.log("DEPLOYING FRESH SHERPAVAULT SYSTEM WITH CAP FIXES");
  console.log("=".repeat(70));
  console.log();

  // Load artifacts
  const SherpaVaultArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../../artifacts/contracts/SherpaVault.sol/SherpaVault.json"), "utf8")
  );
  const SherpaUSDArtifact = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../../artifacts/contracts/SherpaUSD.sol/SherpaUSD.json"), "utf8")
  );

  // Setup providers and wallets
  const sepoliaProvider = new ethers.providers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const baseProvider = new ethers.providers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC_URL);

  const wallet = new ethers.Wallet("0x" + process.env.PRIVATE_KEY);
  const sepoliaWallet = wallet.connect(sepoliaProvider);
  const baseWallet = wallet.connect(baseProvider);

  console.log("Deployer:", wallet.address);
  console.log();

  const [sepoliaBalance, baseBalance] = await Promise.all([
    sepoliaWallet.getBalance(),
    baseWallet.getBalance()
  ]);

  console.log("Sepolia balance:", ethers.utils.formatEther(sepoliaBalance), "ETH");
  console.log("Base balance:", ethers.utils.formatEther(baseBalance), "ETH");
  console.log();

  // Existing contracts
  const SEPOLIA_MOCK_USDC = "0x03f346E161B2cD07F4B14a14F8B661f0E57AF14F";
  const BASE_MOCK_USDC = "0x20b64A9fa5546247C31bD694eCF6E910874f4e55";

  const SEPOLIA_CCIP_ROUTER = "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59";
  const BASE_CCIP_ROUTER = "0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93";

  const SEPOLIA_CHAIN_SELECTOR = "16015286601757825753";
  const BASE_CHAIN_SELECTOR = "10344971235874465080";

  // Vault params
  const vaultParams = {
    decimals: 6,
    minimumSupply: ethers.utils.parseUnits("1", 6),
    cap: ethers.utils.parseUnits("1000000", 6)
  };

  console.log("Vault parameters:");
  console.log("  Decimals:", vaultParams.decimals);
  console.log("  Minimum Supply:", ethers.utils.formatUnits(vaultParams.minimumSupply, 6), "USDC");
  console.log("  Cap:", ethers.utils.formatUnits(vaultParams.cap, 6), "USDC per chain");
  console.log();

  // =================================================================
  // STEP 1: Deploy Vaults with placeholder wrapper
  // =================================================================

  console.log("📍 STEP 1: DEPLOYING VAULTS (TEMPORARY WRAPPER)");
  console.log("-".repeat(70));

  const vaultFactory = new ethers.ContractFactory(
    SherpaVaultArtifact.abi,
    SherpaVaultArtifact.bytecode
  );

  // Use deployer address as temporary placeholder
  const tempWrapper = wallet.address;

  console.log("Deploying Sepolia vault (temp wrapper)...");
  const sepoliaVault = await vaultFactory.connect(sepoliaWallet).deploy(
    "Staked Sherpa USD",
    "shUSD",
    tempWrapper,
    wallet.address,
    vaultParams
  );
  await sepoliaVault.deployed();
  console.log("  ✅ Sepolia Vault:", sepoliaVault.address);

  console.log("Deploying Base vault (temp wrapper)...");
  const baseVault = await vaultFactory.connect(baseWallet).deploy(
    "Staked Sherpa USD",
    "shUSD",
    tempWrapper,
    wallet.address,
    vaultParams
  );
  await baseVault.deployed();
  console.log("  ✅ Base Vault:", baseVault.address);
  console.log();

  // =================================================================
  // STEP 2: Deploy SherpaUSD wrappers pointing to vaults
  // =================================================================

  console.log("📍 STEP 2: DEPLOYING SHERPAUSD WRAPPERS");
  console.log("-".repeat(70));

  const sherpaUSDFactory = new ethers.ContractFactory(
    SherpaUSDArtifact.abi,
    SherpaUSDArtifact.bytecode
  );

  console.log("Deploying Sepolia SherpaUSD...");
  const sepoliaSherpaUSD = await sherpaUSDFactory.connect(sepoliaWallet).deploy(
    SEPOLIA_MOCK_USDC,
    sepoliaVault.address
  );
  await sepoliaSherpaUSD.deployed();
  console.log("  ✅ Sepolia SherpaUSD:", sepoliaSherpaUSD.address);

  console.log("Deploying Base SherpaUSD...");
  const baseSherpaUSD = await sherpaUSDFactory.connect(baseWallet).deploy(
    BASE_MOCK_USDC,
    baseVault.address
  );
  await baseSherpaUSD.deployed();
  console.log("  ✅ Base SherpaUSD:", baseSherpaUSD.address);
  console.log();

  // =================================================================
  // STEP 3: Lock wrapper and keeper to prevent swap attacks
  // =================================================================

  console.log("📍 STEP 3: LOCKING WRAPPER AND KEEPER");
  console.log("-".repeat(70));

  console.log("Locking Sepolia vault wrapper...");
  let tx = await sepoliaVault.setStableWrapper(sepoliaSherpaUSD.address);
  await tx.wait();
  console.log("  ✅ Wrapper locked (prevents wrapper-swap attack)");

  console.log("Locking Base vault wrapper...");
  tx = await baseVault.setStableWrapper(baseSherpaUSD.address);
  await tx.wait();
  console.log("  ✅ Wrapper locked (prevents wrapper-swap attack)");

  console.log("Locking Sepolia SherpaUSD keeper...");
  tx = await sepoliaSherpaUSD.setKeeper(sepoliaVault.address);
  await tx.wait();
  console.log("  ✅ Keeper locked (prevents keeper-swap attack)");

  console.log("Locking Base SherpaUSD keeper...");
  tx = await baseSherpaUSD.setKeeper(baseVault.address);
  await tx.wait();
  console.log("  ✅ Keeper locked (prevents keeper-swap attack)");
  console.log();

  // =================================================================
  // STEP 4: Configure vault relationships
  // =================================================================

  console.log("📍 STEP 4: CONFIGURING VAULT RELATIONSHIPS");
  console.log("-".repeat(70));

  console.log("Setting Sepolia as PRIMARY...");
  tx = await sepoliaVault.setPrimaryChain(SEPOLIA_CHAIN_SELECTOR, true);
  await tx.wait();
  console.log("  ✅ Done");

  console.log("Setting Base as SECONDARY...");
  tx = await baseVault.setPrimaryChain(BASE_CHAIN_SELECTOR, false);
  await tx.wait();
  console.log("  ✅ Done");
  console.log();

  // =================================================================
  // STEP 5: Save deployment
  // =================================================================

  const deployment = {
    timestamp: new Date().toISOString(),
    deployer: wallet.address,
    sepolia: {
      chainId: 11155111,
      chainSelector: SEPOLIA_CHAIN_SELECTOR,
      vault: sepoliaVault.address,
      sherpaUSD: sepoliaSherpaUSD.address,
      mockUSDC: SEPOLIA_MOCK_USDC,
      ccipRouter: SEPOLIA_CCIP_ROUTER,
      isPrimary: true
    },
    base: {
      chainId: 84532,
      chainSelector: BASE_CHAIN_SELECTOR,
      vault: baseVault.address,
      sherpaUSD: baseSherpaUSD.address,
      ccipRouter: BASE_CCIP_ROUTER,
      isPrimary: false
    },
    vaultParams: {
      decimals: 6,
      minimumSupply: "1000000",
      cap: "1000000000000"
    },
    status: "deployed-fresh-with-cap-fixes",
    notes: "✅ Fresh deployment with clean accounting. Cap fixes: 1) Deposit check includes 'amount', 2) Yield cap removed"
  };

  fs.writeFileSync(
    path.join(__dirname, "../../../deployments/deployment.json"),
    JSON.stringify(deployment, null, 2)
  );

  console.log("=".repeat(70));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(70));
  console.log();
  console.log("Sepolia:");
  console.log("  Vault:", sepoliaVault.address);
  console.log("  SherpaUSD:", sepoliaSherpaUSD.address);
  console.log();
  console.log("Base:");
  console.log("  Vault:", baseVault.address);
  console.log("  SherpaUSD:", baseSherpaUSD.address);
  console.log();
  console.log("Saved to: ./deployments/deployment.json");
}

main().catch(console.error);
