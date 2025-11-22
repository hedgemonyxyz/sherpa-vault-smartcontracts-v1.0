# System Deployment Scripts

Scripts for deploying the complete SherpaVault multi-chain system across Ethereum Sepolia, Base Sepolia, and Arbitrum Sepolia.

## Core Deployment Scripts

Run these scripts in sequence for a fresh deployment:

| Script | Purpose |
|--------|---------|
| `deployFreshSystem-all3chains.js` | Deploy vaults and wrappers on all 3 chains |
| `deployAllCCIPPools.js` | Deploy CCIP pools for cross-chain bridging |
| `configureAllPoolRoutes.js` | Configure cross-chain routing between pools |
| `enableDepositsAllChains.js` | Enable deposits and verify system health |
| `deployerInitialize1usdc.js` | Initialize primary vault with 1 USDC (required) |


## Quick Start

```bash
# Deploy system
node scripts/system-deployment/deployFreshSystem-all3chains.js
node scripts/system-deployment/deployAllCCIPPools.js
node scripts/system-deployment/configureAllPoolRoutes.js
node scripts/system-deployment/enableDepositsAllChains.js

# Initialize
node scripts/system-deployment/deployerInitialize1usdc.js sepolia
# First round roll performed by operator
```

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `verifyAllContracts.js` | Verify contracts on block explorers |
| `verifyPoolAuthorization.js` | Check pool authorization status |
| `setOperatorAllChains.js` | Set operator address on all chains |
| `transferOwnershipToMultiSig.js` | Transfer ownership to multi-sig wallets |
| `preFlightCheck.js` | Comprehensive system verification |

## Subdirectories

- **`add-chain/`** - Scripts for adding new chains to existing deployment
- **`single-chain/`** - Individual chain deployment utilities
- **`args/`** - Constructor arguments for contract verification

## Documentation

For additional information, see the main README.md and contract source code.

## Prerequisites

- Compiled contracts: `npx hardhat compile`
- ETH on all 3 testnets (~0.5 ETH each)
- Mock USDC for initialization
- `.env` configured with RPC URLs and private key

## Important Notes

- Scripts are **idempotent** where possible (safe to re-run on failure)
- Each script updates `deployments/deployment.json` automatically
- Old deployments are backed up before any changes
- Scripts use Token Admin Registry as source of truth for pool addresses
- All contracts must be verified before production use

## Rollback

If deployment fails, restore previous system:

```bash
# Find latest backup
ls -lt deployments/deployment-backup-*.json | head -1

# Restore
cp deployments/deployment-backup-YYYY-MM-DD*.json deployments/deployment.json
```

Old contracts continue to work - scripts automatically use addresses from `deployment.json`.
