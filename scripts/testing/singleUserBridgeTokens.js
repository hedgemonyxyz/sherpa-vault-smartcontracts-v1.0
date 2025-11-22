const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { getTestUser } = require("../config/testUsers");
require("dotenv").config();

/**
 * Bridge shUSD tokens from one chain to another using CCIP
 *
 * Usage:
 *   node scripts/testing/singleUserBridgeTokens.js <fromChain> <toChain> <amount> <userNumber|receiverAddress> [privateKey]
 *
 * Supported chains: sepolia, base, arbitrum
 *
 * Examples:
 *   # Using test user number (1-5) - auto-uses user's address and private key:
 *   node scripts/testing/singleUserBridgeTokens.js sepolia base 100 1
 *   node scripts/testing/singleUserBridgeTokens.js arbitrum base 50 2
 *
 *   # Using custom address and private key:
 *   node scripts/testing/singleUserBridgeTokens.js base sepolia 100 0xYourAddress 0x123...
 */

// Load deployment info - always use main deployment.json
const deployment = JSON.parse(fs.readFileSync(path.join(__dirname, "../../deployments/deployment.json"), "utf8"));

const CHAINS = {
  sepolia: {
    rpcUrl: process.env.SEPOLIA_RPC_URL,
    router: "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
    chainSelector: "16015286601757825753",
    shUSD: deployment.sepolia.vault,
    linkToken: "0x779877A7B0D9E8603169DdbD7836e478b4624789"
  },
  base: {
    rpcUrl: process.env.BASE_SEPOLIA_RPC_URL,
    router: "0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93",
    chainSelector: "10344971235874465080",
    shUSD: deployment.base.vault,
    linkToken: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410"
  },
  arbitrum: {
    rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL,
    router: "0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165",
    chainSelector: "3478487238524512106",
    shUSD: deployment.arbitrum.vault,
    linkToken: "0xb1D4538B4571d411F07960EF2838Ce337FE1E80E"
  }
};

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

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 4) {
    console.error("Usage: node scripts/testing/singleUserBridgeTokens.js <fromChain> <toChain> <amount> <userNumber|receiverAddress> [privateKey]");
    console.error("");
    console.error("Supported chains: sepolia, base, arbitrum");
    console.error("");
    console.error("Examples:");
    console.error("  # Using test user (bridges to self):");
    console.error("  node scripts/testing/singleUserBridgeTokens.js sepolia base 100 1");
    console.error("");
    console.error("  # Using custom address:");
    console.error("  node scripts/testing/singleUserBridgeTokens.js base sepolia 100 0xYourAddress 0xYourPrivateKey");
    process.exit(1);
  }

  const [fromChainName, toChainName, amountStr, receiverOrUserNumber, customPrivateKey] = args;

  // Determine if user number (1-5) or address was provided
  let receiverAddress;
  let privateKey;

  const userNumber = parseInt(receiverOrUserNumber);
  if (!isNaN(userNumber) && userNumber >= 1 && userNumber <= 5) {
    // User number provided - use test user
    const user = getTestUser(userNumber);
    receiverAddress = user.address;
    privateKey = user.key;
    console.log(`Using test user #${userNumber}: ${user.name}`);
  } else if (receiverOrUserNumber.startsWith("0x")) {
    // Address provided - require private key
    receiverAddress = receiverOrUserNumber;
    if (!customPrivateKey) {
      console.error("❌ Error: When using custom address, you must provide the private key");
      console.error("Usage: node scripts/testing/singleUserBridgeTokens.js <fromChain> <toChain> <amount> <address> <privateKey>");
      process.exit(1);
    }
    privateKey = customPrivateKey;
  } else {
    console.error("❌ Error: Fourth parameter must be a user number (1-5) or an address (0x...)");
    process.exit(1);
  }

  // Validate chains
  if (!CHAINS[fromChainName] || !CHAINS[toChainName]) {
    console.error(`Invalid chain. Options: ${Object.keys(CHAINS).join(", ")}`);
    process.exit(1);
  }

  const sourceChain = CHAINS[fromChainName];
  const destChain = CHAINS[toChainName];
  const amount = ethers.utils.parseUnits(amountStr, 6); // shUSD has 6 decimals

  console.log("=".repeat(80));
  console.log("🌉 CCIP CROSS-CHAIN BRIDGE");
  console.log("=".repeat(80));
  console.log();
  console.log(`From: ${fromChainName.toUpperCase()}`);
  console.log(`To: ${toChainName.toUpperCase()}`);
  console.log(`Amount: ${amountStr} shUSD`);
  console.log(`Receiver: ${receiverAddress}`);
  console.log();

  // Setup provider and wallet
  const provider = new ethers.providers.JsonRpcProvider(sourceChain.rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);

  // Connect to contracts
  const token = new ethers.Contract(sourceChain.shUSD, ERC20_ABI, wallet);
  const router = new ethers.Contract(sourceChain.router, ROUTER_ABI, wallet);

  // Check balance
  const balance = await token.balanceOf(wallet.address);
  console.log(`Your shUSD balance: ${ethers.utils.formatUnits(balance, 6)}`);

  if (balance.lt(amount)) {
    console.error(`❌ Insufficient balance. You have ${ethers.utils.formatUnits(balance, 6)} shUSD`);
    process.exit(1);
  }
  console.log();

  // 1. Approve router to spend tokens
  console.log("📝 Step 1: Approving router to spend shUSD...");
  const allowance = await token.allowance(wallet.address, sourceChain.router);

  if (allowance.lt(amount)) {
    const approveTx = await token.approve(sourceChain.router, ethers.constants.MaxUint256);
    console.log(`Approval tx: ${approveTx.hash}`);
    await approveTx.wait();
    console.log("✅ Approved");
  } else {
    console.log("✅ Already approved");
  }
  console.log();

  // 2. Build CCIP message
  console.log("📦 Step 2: Building CCIP message...");

  // Build extraArgs using GenericExtraArgsV2 format
  // See: https://docs.chain.link/ccip/api-reference/evm/v1.6.0/i-router-client
  // Tag: 0x181dcf10 for GenericExtraArgsV2 (supports gasLimit + allowOutOfOrderExecution)
  const extraArgsEncoded = ethers.utils.defaultAbiCoder.encode(
    ["uint256", "bool"],
    [500000, false] // gasLimit (increased from 200k to 500k), allowOutOfOrderExecution
  );

  const message = {
    receiver: ethers.utils.defaultAbiCoder.encode(["address"], [receiverAddress]),
    data: "0x", // No additional data
    tokenAmounts: [
      {
        token: sourceChain.shUSD,
        amount: amount
      }
    ],
    feeToken: ethers.constants.AddressZero, // Pay in native gas (ETH)
    extraArgs: "0x181dcf10" + extraArgsEncoded.slice(2) // GenericExtraArgsV2 tag + encoded args
  };

  console.log("Message structure:");
  console.log(`  Token: ${sourceChain.shUSD}`);
  console.log(`  Amount: ${ethers.utils.formatUnits(amount, 6)} shUSD`);
  console.log(`  Receiver: ${receiverAddress}`);
  console.log(`  Destination: ${destChain.chainSelector}`);
  console.log();

  // 3. Get fee estimate
  console.log("💰 Step 3: Getting fee estimate...");

  let fee;
  try {
    fee = await router.getFee(destChain.chainSelector, message);
    console.log(`Estimated fee: ${ethers.utils.formatEther(fee)} ETH`);
  } catch (error) {
    console.error("❌ Failed to get fee estimate:");
    console.error(error.message);
    process.exit(1);
  }
  console.log();

  // 4. Send CCIP message
  console.log("🚀 Step 4: Sending cross-chain message...");

  try {
    const tx = await router.ccipSend(destChain.chainSelector, message, {
      value: fee
    });

    console.log(`✅ Transaction sent: ${tx.hash}`);
    console.log();
    console.log("⏳ Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`✅ Confirmed in block ${receipt.blockNumber}`);
    console.log();

    // Extract CCIP message ID from OnRamp logs
    // The CCIPSendRequested event is emitted by the OnRamp contract (last log)
    const onRampLog = receipt.logs[receipt.logs.length - 1];

    if (onRampLog && onRampLog.data) {
      // Message ID is a bytes32 hash at offset 13 (byte 416)
      const data = onRampLog.data;
      const messageIdStart = 2 + (13 * 64); // Skip "0x" prefix + 13 32-byte words
      const messageId = '0x' + data.slice(messageIdStart, messageIdStart + 64);

      console.log("📋 CCIP Message ID:", messageId);
      console.log();
      console.log("🔍 Track your transfer:");
      console.log(`https://ccip.chain.link/msg/${messageId}`);
    } else {
      console.log("⚠️  Could not extract message ID from logs");
      console.log("Check transaction on block explorer for details");
    }

    console.log();
    console.log("✅ BRIDGE COMPLETE!");
    console.log();
    console.log("Your tokens will arrive on the destination chain in ~10-20 minutes.");
    console.log("CCIP messages go through multiple confirmations for security.");

  } catch (error) {
    console.error("❌ Bridge failed:");
    console.error(error.message);

    if (error.reason) {
      console.error("Reason:", error.reason);
    }

    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ BRIDGE FAILED:");
    console.error(error);
    process.exit(1);
  });
