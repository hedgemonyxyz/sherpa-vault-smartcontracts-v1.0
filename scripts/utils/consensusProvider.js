const { ethers } = require("ethers");
require("dotenv").config();

/**
 * Consensus-Based RPC Provider
 *
 * Queries multiple RPC providers in parallel and returns results only when
 * a consensus threshold is met. Critical for operations like:
 * - Reading vault balances before rolling rounds
 * - Verifying state across chains
 * - Setting global prices
 *
 * Usage:
 *   const { queryWithConsensus } = require('./utils/consensusProvider');
 *   const balance = await queryWithConsensus('sepolia', async (provider) => {
 *     const vault = new ethers.Contract(address, abi, provider);
 *     return await vault.totalAssets();
 *   });
 */

// Define multiple RPC URLs for each chain
const RPC_URLS = {
  sepolia: [
    process.env.SEPOLIA_RPC_URL,
    process.env.SEPOLIA_RPC_URL_2,
    process.env.SEPOLIA_RPC_URL_3,
    // Public fallbacks
    "https://rpc.sepolia.org",
    "https://ethereum-sepolia-rpc.publicnode.com",
  ].filter(Boolean),

  base: [
    process.env.BASE_SEPOLIA_RPC_URL,
    process.env.BASE_SEPOLIA_RPC_URL_2,
    process.env.BASE_SEPOLIA_RPC_URL_3,
    // Public fallbacks
    "https://sepolia.base.org",
    "https://base-sepolia-rpc.publicnode.com",
  ].filter(Boolean),

  arbitrum: [
    process.env.ARBITRUM_SEPOLIA_RPC_URL,
    process.env.ARBITRUM_SEPOLIA_RPC_URL_2,
    process.env.ARBITRUM_SEPOLIA_RPC_URL_3,
    // Public fallbacks
    "https://sepolia-rollup.arbitrum.io/rpc",
    "https://arbitrum-sepolia-rpc.publicnode.com",
  ].filter(Boolean),
};

/**
 * Query multiple RPCs in parallel and return consensus result
 *
 * @param {string} chain - Chain name (sepolia, base, arbitrum)
 * @param {Function} queryFn - Async function that takes a provider and returns a value
 * @param {Object} options - Configuration options
 * @param {number} options.minConsensus - Minimum number of matching responses (default: 2)
 * @param {number} options.timeout - Timeout per RPC in ms (default: 10000)
 * @param {boolean} options.requireMajority - Require majority of RPCs to agree (default: false)
 * @returns {Promise<any>} Consensus value
 * @throws {Error} If consensus not reached
 */
async function queryWithConsensus(chain, queryFn, options = {}) {
  const {
    minConsensus = 2,
    timeout = 10000,
    requireMajority = false,
  } = options;

  const rpcUrls = RPC_URLS[chain];
  if (!rpcUrls || rpcUrls.length === 0) {
    throw new Error(`No RPC URLs configured for ${chain}`);
  }

  console.log(`🔍 Querying ${rpcUrls.length} RPCs for ${chain}...`);

  // Query all RPCs in parallel with timeout
  const results = await Promise.allSettled(
    rpcUrls.map(async (url) => {
      const provider = new ethers.providers.JsonRpcProvider(url);

      // Race between query and timeout
      const queryPromise = queryFn(provider);
      const timeoutPromise = new Promise((_, reject) =>
        setTimeout(() => reject(new Error("Timeout")), timeout)
      );

      return Promise.race([queryPromise, timeoutPromise]);
    })
  );

  // Extract successful results
  const successful = results
    .map((result, index) => ({
      rpcIndex: index,
      rpcUrl: rpcUrls[index].substring(0, 50),
      success: result.status === "fulfilled",
      value: result.status === "fulfilled" ? result.value : null,
      error: result.status === "rejected" ? result.reason?.message : null,
    }))
    .filter(r => r.success);

  if (successful.length === 0) {
    throw new Error(
      `All RPCs failed for ${chain}:\n` +
      results.map((r, i) => `  ${i}: ${r.reason?.message}`).join("\n")
    );
  }

  // Group by value (handle BigNumber comparisons)
  const groups = {};
  for (const result of successful) {
    const key = serializeValue(result.value);
    if (!groups[key]) {
      groups[key] = {
        value: result.value,
        count: 0,
        rpcs: [],
      };
    }
    groups[key].count++;
    groups[key].rpcs.push(result.rpcUrl);
  }

  // Find the most common value
  const sorted = Object.values(groups).sort((a, b) => b.count - a.count);
  const consensus = sorted[0];

  console.log(`  ✅ ${successful.length}/${rpcUrls.length} RPCs responded`);
  console.log(`  📊 Consensus: ${consensus.count}/${successful.length} agree`);

  // Check if consensus threshold met
  if (consensus.count < minConsensus) {
    throw new Error(
      `Consensus not reached for ${chain}. ` +
      `Need ${minConsensus} matching responses, got ${consensus.count}. ` +
      `Responses:\n` +
      sorted.map(g => `  ${g.count}x: ${deserializeValue(g.value)}`).join("\n")
    );
  }

  // Check if majority required
  if (requireMajority && consensus.count <= successful.length / 2) {
    throw new Error(
      `Majority consensus not reached for ${chain}. ` +
      `Got ${consensus.count}/${successful.length} agreements.`
    );
  }

  // Log any disagreements
  if (sorted.length > 1) {
    console.log(`  ⚠️  Found ${sorted.length} different responses:`);
    sorted.forEach((g, i) => {
      console.log(`    ${i + 1}. ${g.count}x: ${deserializeValue(g.value)}`);
      g.rpcs.forEach(rpc => console.log(`       - ${rpc}`));
    });
  }

  return consensus.value;
}

/**
 * Query multiple chains with consensus
 *
 * @param {string[]} chains - Array of chain names
 * @param {Function} queryFn - Async function that takes (chain, provider) and returns a value
 * @param {Object} options - Same as queryWithConsensus
 * @returns {Promise<Object>} Object with chain names as keys, consensus values as values
 */
async function queryMultipleChainsWithConsensus(chains, queryFn, options = {}) {
  const results = {};

  for (const chain of chains) {
    console.log(`\n${"=".repeat(70)}`);
    console.log(`Querying ${chain.toUpperCase()}`);
    console.log("=".repeat(70));

    results[chain] = await queryWithConsensus(
      chain,
      (provider) => queryFn(chain, provider),
      options
    );
  }

  return results;
}

/**
 * Serialize a value for comparison (handles BigNumbers, arrays, objects)
 */
function serializeValue(value) {
  if (value === null || value === undefined) {
    return "null";
  }
  if (ethers.BigNumber.isBigNumber(value)) {
    return value.toString();
  }
  if (Array.isArray(value)) {
    return JSON.stringify(value.map(v => serializeValue(v)));
  }
  if (typeof value === "object") {
    const sorted = Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = serializeValue(value[key]);
        return acc;
      }, {});
    return JSON.stringify(sorted);
  }
  return String(value);
}

/**
 * Deserialize a value for display (truncate long strings)
 */
function deserializeValue(value) {
  const str = serializeValue(value);
  return str.length > 100 ? str.substring(0, 100) + "..." : str;
}

/**
 * Get a standard provider (uses first configured RPC)
 * For non-critical reads where consensus isn't needed
 */
function getProvider(chain) {
  const rpcUrls = RPC_URLS[chain];
  if (!rpcUrls || rpcUrls.length === 0) {
    throw new Error(`No RPC URLs configured for ${chain}`);
  }
  return new ethers.providers.JsonRpcProvider(rpcUrls[0]);
}

/**
 * Get a wallet with consensus provider
 * For writes, you don't need consensus (single provider is fine)
 */
function getWallet(chain, privateKey) {
  const provider = getProvider(chain);
  const key = privateKey.startsWith("0x") ? privateKey : "0x" + privateKey;
  return new ethers.Wallet(key, provider);
}

module.exports = {
  queryWithConsensus,
  queryMultipleChainsWithConsensus,
  getProvider,
  getWallet,
  RPC_URLS,
};
