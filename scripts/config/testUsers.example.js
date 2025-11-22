/**
 * Central Test User Configuration - EXAMPLE FILE
 *
 * This is a template file. Copy this to testUsers.js and add your actual test user
 * private keys. The testUsers.js file is gitignored to prevent committing private keys.
 *
 * Setup:
 * 1. Copy this file: cp testUsers.example.js testUsers.js
 * 2. Replace placeholder private keys with your actual test wallet keys
 * 3. Never commit testUsers.js to version control
 *
 * Used by:
 * - scripts/testing/singleUserDeposit-universalChain.js
 * - scripts/testing/singleUserClaimShares-universalChain.js
 * - scripts/testing/singleUserBridgeTokens.js
 * - scripts/analysis/checkUserStake.js
 * - scripts/testing/simulateUserDeposits.js
 */

const TEST_USERS = [
  {
    name: "Vault User #1",
    address: "0x0000000000000000000000000000000000000001",
    key: "0x0000000000000000000000000000000000000000000000000000000000000001"
  },
  {
    name: "Vault User #2",
    address: "0x0000000000000000000000000000000000000002",
    key: "0x0000000000000000000000000000000000000000000000000000000000000002"
  },
  {
    name: "Vault User #3",
    address: "0x0000000000000000000000000000000000000003",
    key: "0x0000000000000000000000000000000000000000000000000000000000000003"
  },
  {
    name: "Vault User #4",
    address: "0x0000000000000000000000000000000000000004",
    key: "0x0000000000000000000000000000000000000000000000000000000000000004"
  },
  {
    name: "Vault User #5",
    address: "0x0000000000000000000000000000000000000005",
    key: "0x0000000000000000000000000000000000000000000000000000000000000005"
  },
  {
    name: "Vault User #6",
    address: "0x0000000000000000000000000000000000000006",
    key: "0x0000000000000000000000000000000000000000000000000000000000000006"
  },
  {
    name: "Vault User #7",
    address: "0x0000000000000000000000000000000000000007",
    key: "0x0000000000000000000000000000000000000000000000000000000000000007"
  },
  {
    name: "Vault User #8",
    address: "0x0000000000000000000000000000000000000008",
    key: "0x0000000000000000000000000000000000000000000000000000000000000008"
  },
  {
    name: "Vault User #9",
    address: "0x0000000000000000000000000000000000000009",
    key: "0x0000000000000000000000000000000000000000000000000000000000000009"
  },
  {
    name: "Vault User #10",
    address: "0x000000000000000000000000000000000000000a",
    key: "0x000000000000000000000000000000000000000000000000000000000000000a"
  }
];

/**
 * Get test user by number (1-10)
 * @param {number} userNumber - User number (1-10)
 * @returns {object} User object with name, address, and key
 */
function getTestUser(userNumber) {
  if (userNumber < 1 || userNumber > TEST_USERS.length) {
    throw new Error(`Invalid user number: ${userNumber}. Must be between 1 and ${TEST_USERS.length}`);
  }
  return TEST_USERS[userNumber - 1];
}

/**
 * Get test user by address
 * @param {string} address - User address
 * @returns {object|null} User object or null if not found
 */
function getTestUserByAddress(address) {
  return TEST_USERS.find(user => user.address.toLowerCase() === address.toLowerCase()) || null;
}

/**
 * Get all test user addresses
 * @returns {string[]} Array of user addresses
 */
function getAllTestUserAddresses() {
  return TEST_USERS.map(user => user.address);
}

module.exports = {
  TEST_USERS,
  getTestUser,
  getTestUserByAddress,
  getAllTestUserAddresses
};
