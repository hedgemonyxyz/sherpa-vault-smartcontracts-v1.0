const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Test All Bridge Routes for a Single User
 *
 * This script systematically tests all 6 possible bridge routes:
 * - sepolia → base
 * - sepolia → arbitrum
 * - base → sepolia
 * - base → arbitrum
 * - arbitrum → sepolia
 * - arbitrum → base
 *
 * Each route transfers a specified amount of shUSD tokens.
 *
 * Usage:
 *   node scripts/testing/singleUser-testAllBridgeRoutes.js <userNumber> [amountPerRoute]
 *
 * Examples:
 *   node scripts/testing/singleUser-testAllBridgeRoutes.js 1          # Uses 10000 shUSD per route
 *   node scripts/testing/singleUser-testAllBridgeRoutes.js 1 5000    # Uses 5000 shUSD per route
 */

// Load deployment info
const deployment = JSON.parse(fs.readFileSync(path.join(__dirname, "../../deployments/deployment.json"), "utf8"));

const CHAINS = {
  sepolia: {
    name: "Sepolia",
    rpcUrl: process.env.SEPOLIA_RPC_URL,
    router: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
    chainSelector: "16015286601757825753",
    shUSD: deployment.sepolia.vault,
    linkToken: "0x779877A7B0D9E8603169DdbD7836e478b4624789",
    explorer: "https://sepolia.etherscan.io"
  },
  base: {
    name: "Base Sepolia",
    rpcUrl: process.env.BASE_SEPOLIA_RPC_URL,
    router: "0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93",
    chainSelector: "10344971235874465080",
    shUSD: deployment.base.vault,
    linkToken: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410",
    explorer: "https://sepolia.basescan.org"
  },
  arbitrum: {
    name: "Arbitrum Sepolia",
    rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL,
    router: "0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165",
    chainSelector: "3478487238524512106",
    shUSD: deployment.arbitrum.vault,
    linkToken: "0xb1D4538B4571d411F07960EF2838Ce337FE1E80E",
    explorer: "https://sepolia.arbiscan.io"
  }
};

// All 6 bridge routes to test
const ROUTES = [
  { from: "sepolia", to: "base" },
  { from: "sepolia", to: "arbitrum" },
  { from: "base", to: "sepolia" },
  { from: "base", to: "arbitrum" },
  { from: "arbitrum", to: "sepolia" },
  { from: "arbitrum", to: "base" }
];

// CCIP Router ABI
const ROUTER_ABI = [
  "function getFee(uint64 destinationChainSelector, tuple(bytes receiver, bytes data, tuple(address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) view returns (uint256 fee)",
  "function ccipSend(uint64 destinationChainSelector, tuple(bytes receiver, bytes data, tuple(address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) payable returns (bytes32)"
];

// ERC20 ABI
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)"
];

/**
 * Bridge tokens from one chain to another
 */
async function bridgeTokens(fromChain, toChain, amount, wallet, receiverAddress) {
  const sourceChain = CHAINS[fromChain];
  const destChain = CHAINS[toChain];

  console.log(`  From: ${sourceChain.name}`);
  console.log(`  To: ${destChain.name}`);
  console.log(`  Amount: ${ethers.utils.formatUnits(amount, 6)} shUSD`);
  console.log();

  // Connect to contracts
  const token = new ethers.Contract(sourceChain.shUSD, ERC20_ABI, wallet);
  const router = new ethers.Contract(sourceChain.router, ROUTER_ABI, wallet);

  // Check balance
  const balance = await token.balanceOf(wallet.address);
  console.log(`  Current balance: ${ethers.utils.formatUnits(balance, 6)} shUSD`);

  if (balance.lt(amount)) {
    throw new Error(`Insufficient balance. Have ${ethers.utils.formatUnits(balance, 6)} shUSD, need ${ethers.utils.formatUnits(amount, 6)} shUSD`);
  }

  // Approve router if needed
  const allowance = await token.allowance(wallet.address, sourceChain.router);
  if (allowance.lt(amount)) {
    console.log(`  Approving router...`);
    const approveTx = await token.approve(sourceChain.router, ethers.constants.MaxUint256);
    await approveTx.wait();
    console.log(`  ✅ Approved`);
  }

  // Build CCIP message
  const extraArgsEncoded = ethers.utils.defaultAbiCoder.encode(
    ["uint256", "bool"],
    [500000, false] // gasLimit, allowOutOfOrderExecution
  );

  const message = {
    receiver: ethers.utils.defaultAbiCoder.encode(["address"], [receiverAddress]),
    data: "0x",
    tokenAmounts: [{
      token: sourceChain.shUSD,
      amount: amount
    }],
    feeToken: ethers.constants.AddressZero, // Pay in native ETH
    extraArgs: "0x181dcf10" + extraArgsEncoded.slice(2)
  };

  // Get fee
  const fee = await router.getFee(destChain.chainSelector, message);
  console.log(`  CCIP fee: ${ethers.utils.formatEther(fee)} ETH`);

  // Send bridge transaction
  console.log(`  Sending bridge transaction...`);
  const tx = await router.ccipSend(destChain.chainSelector, message, {
    value: fee
  });

  console.log(`  Tx hash: ${tx.hash}`);
  console.log(`  Explorer: ${sourceChain.explorer}/tx/${tx.hash}`);

  const receipt = await tx.wait();
  console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);

  // Extract CCIP message ID
  const onRampLog = receipt.logs[receipt.logs.length - 1];
  if (onRampLog && onRampLog.data) {
    const data = onRampLog.data;
    const messageIdStart = 2 + (13 * 64);
    const messageId = '0x' + data.slice(messageIdStart, messageIdStart + 64);
    console.log(`  Message ID: ${messageId}`);
    console.log(`  Track: https://ccip.chain.link/msg/${messageId}`);
  }

  return tx.hash;
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 1) {
    console.error("Usage: node scripts/testing/singleUser-testAllBridgeRoutes.js <userNumber> [amountPerRoute]");
    console.error("");
    console.error("Arguments:");
    console.error("  userNumber: Test user number (1-5)");
    console.error("  amountPerRoute: Amount of shUSD to bridge per route (default: 10000)");
    console.error("");
    console.error("Examples:");
    console.error("  node scripts/testing/singleUser-testAllBridgeRoutes.js 1");
    console.error("  node scripts/testing/singleUser-testAllBridgeRoutes.js 1 5000");
    process.exit(1);
  }

  const userNumber = parseInt(args[0]);
  const amountPerRoute = args[1] ? parseFloat(args[1]) : 10000;

  if (isNaN(userNumber) || userNumber < 1 || userNumber > 5) {
    console.error("❌ Error: User number must be between 1 and 5");
    process.exit(1);
  }

  const user = getTestUser(userNumber);
  const amount = ethers.utils.parseUnits(amountPerRoute.toString(), 6);

  console.log("=".repeat(80));
  console.log("🌉 TESTING ALL BRIDGE ROUTES");
  console.log("=".repeat(80));
  console.log();
  console.log(`User: ${user.name} (${user.address})`);
  console.log(`Amount per route: ${amountPerRoute} shUSD`);
  console.log(`Total routes: ${ROUTES.length}`);
  console.log(`Total shUSD to bridge: ${amountPerRoute * ROUTES.length} shUSD`);
  console.log();
  console.log("Routes to test:");
  ROUTES.forEach((route, i) => {
    console.log(`  ${i + 1}. ${route.from} → ${route.to}`);
  });
  console.log();
  console.log("=".repeat(80));
  console.log();

  const results = [];
  const delayBetweenRoutes = 5000; // 5 seconds

  for (let i = 0; i < ROUTES.length; i++) {
    const route = ROUTES[i];

    console.log(`📍 Route ${i + 1}/${ROUTES.length}: ${route.from.toUpperCase()} → ${route.to.toUpperCase()}`);
    console.log("-".repeat(80));

    try {
      // Setup wallet for source chain
      const sourceChain = CHAINS[route.from];
      const provider = new ethers.providers.JsonRpcProvider(sourceChain.rpcUrl);
      const wallet = new ethers.Wallet(user.key, provider);

      // Bridge tokens
      const txHash = await bridgeTokens(route.from, route.to, amount, wallet, user.address);

      results.push({
        route: `${route.from} → ${route.to}`,
        status: "success",
        txHash: txHash
      });

      console.log(`  ✅ Bridge initiated successfully`);

    } catch (error) {
      console.error(`  ❌ Bridge failed: ${error.message}`);

      results.push({
        route: `${route.from} → ${route.to}`,
        status: "failed",
        error: error.message
      });
    }

    console.log();

    // Delay before next route (except for last one)
    if (i < ROUTES.length - 1) {
      console.log(`⏳ Waiting ${delayBetweenRoutes / 1000}s before next route...`);
      console.log();
      await new Promise(resolve => setTimeout(resolve, delayBetweenRoutes));
    }
  }

  // Summary
  console.log("=".repeat(80));
  console.log("📋 BRIDGE TEST SUMMARY");
  console.log("=".repeat(80));
  console.log();

  const successful = results.filter(r => r.status === "success").length;
  const failed = results.filter(r => r.status === "failed").length;

  console.log(`Total routes tested: ${ROUTES.length}`);
  console.log(`Successful: ${successful}`);
  console.log(`Failed: ${failed}`);
  console.log();

  console.log("Results:");
  results.forEach((result, i) => {
    const status = result.status === "success" ? "✅" : "❌";
    console.log(`  ${i + 1}. ${status} ${result.route}`);
    if (result.txHash) {
      console.log(`     Tx: ${result.txHash}`);
    }
    if (result.error) {
      console.log(`     Error: ${result.error}`);
    }
  });
  console.log();

  if (successful === ROUTES.length) {
    console.log("🎉 ALL ROUTES TESTED SUCCESSFULLY!");
    console.log();
    console.log("⏳ Note: CCIP messages take ~10-20 minutes to arrive on destination chains.");
    console.log("   Track your transfers at https://ccip.chain.link");
  } else if (failed > 0) {
    console.log("⚠️  SOME ROUTES FAILED");
    console.log(`   ${successful}/${ROUTES.length} routes succeeded`);
  }

  console.log();
  console.log("=".repeat(80));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ TEST FAILED:");
    console.error(error);
    process.exit(1);
  });
