# SherpaVault - Multi-Chain Yield Vault

## Overview

SherpaVault is an extensible multi-chain yield vault built to provide users access to actively managed, delta-neutral yield strategies across both on-chain and off-chain markets. Users deposit USDC on any supported chain and receive interest bearing share tokens (shUSD) that automatically compound all accrued yield. The system maintains synchronized state across all chains through consistent pricing and global accounting, while an operator manages fund deployment and executes the underlying yield strategies. New chains can be progressively integrated into the live system to expand user access, liquidity distribution, and cross-chain connectivity via CCIP.

---

## Architecture

### System Components

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SherpaVault System                            │
│                     Multi-Chain Architecture                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│         ┌──────────────┐              ┌──────────────┐               │
│         │   Ethereum   │              │     Base     │               │
│         │  (Primary)   │              │  (Secondary) │               │
│         ├──────────────┤              ├──────────────┤               │
│         │ SherpaVault  │              │ SherpaVault  │               │
│         │   (shUSD)    │              │   (shUSD)    │               │
│         ├──────────────┤              ├──────────────┤               │
│         │  SherpaUSD   │              │  SherpaUSD   │               │
│         ├──────────────┤              ├──────────────┤               │
│         │    USDC      │              │    USDC      │               │
│         └──────┬───────┘              └───────┬──────┘               │
│                │                              │                      │
│                │       CCIP Network           │                      │
│                │    (Any chain ↔ Any chain)   │                      │
│                │                              │                      │
│                └──────────┬───────────────┬───┘                      │
│                           │               │                          │
│                     ┌─────▼──────┐        │   ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─    │
│                     │  Arbitrum  │        │      Future Chains   │   │
│                     │(Secondary) │        │   │  (Monad, Bera        │
│                     ├────────────┤        └───►   Polygon, etc)  │   │
│                     │SherpaVault │            │                      │
│                     │  (shUSD)   │             ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │
│                     ├────────────┤                                   │
│                     │ SherpaUSD  │   New chains can be added         │
│                     ├────────────┤   to expand system capacity       │
│                     │   USDC     │                                   │
│                     └────────────┘                                   │
│                                                                      │
│  Global State Synchronization (example):                             │
│  • Round 15, Epoch 15 on ALL chains (present and future)             │
│  • Price: 1.05 USDC/shUSD (same everywhere)                          │
│  • Total: 600k Ethereum, 400k Base, 250k Aritrum = 1.25M USDC global │
│      total staked across all chains                                  │
│  • CCIP enables direct bridging between any connected chain pair     │
│   **See "Live System Status" section for actual current values       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

- **SherpaVault**: ERC20 share token (shUSD) representing vault ownership and interest entitlements
- **SherpaUSD**: 1:1 USDC wrapper with epoch-based withdrawals
  - `autoTransfer` mode (disabled by default): When enabled, automatically transfers USDC between wrapper ↔ owner during epoch processing to satisfy current round's deposits / withdrawals
- **Round/Epoch System**: Batched deposits and withdrawals processed at regular intervals
- **Primary/Secondary Chain Hierarchy**: Ethereum calculates global price, others inherit and apply it
- **CCIP Integration**: Burn-and-mint bridging for cross-chain token transfers

### User Journey

**Deposit Flow:**
```
User → vault.depositAndStake(10000 USDC)
  ↓
wrapper.depositToVault() [transfers USDC from user]
  ↓
Vault tracks 10000 USDC as "pending" in current round
  ↓
[Wait for daily round roll]
  ↓
Pending converts to ~9524 shUSD shares (at 1.05 price)
  ↓
User calls vault.maxClaimShares() to get shares in wallet
```

**Withdrawal Flow:**
```
User → vault.unstakeAndWithdraw(5000 shUSD)
  ↓
Vault burns 5000 shUSD shares
  ↓
Converts to 5250 SherpaUSD (at 1.05 price)
  ↓
wrapper.initiateWithdrawalFromVault() [creates receipt]
  ↓
[Wait for epoch increment]
  ↓
User → wrapper.completeWithdrawal()
  ↓
Receives 5250 USDC
```

**Cross-Chain Flow:**
```
User on Ethereum → router.ccipSend() with 100 shUSD
  ↓
Pool burns 100 shUSD on Sepolia
  ↓
CCIP DON processes message (5-20 min)
  ↓
Pool mints 100 shUSD on Base
  ↓
User now has 100 shUSD on Base
```

### Key Concepts

**Rounds vs Epochs:**
- **Round** (Vault): Pricing period, increments when rollToNextRound() is called and global price calculated
- **Epoch** (Wrapper): Withdrawal period, increments after round roll when processWithdrawals() is called
- **Synchronization**: Round N always pairs with Epoch N across all chains

**Primary vs Secondary Chains:**
- **Primary (Ethereum)**: Calculates global price using aggregated data from all chains, all yield applied during round roll mints sherpaUSD on primary
- **Secondary (Base, Arbitrum)**: Apply price calculated by primary chain at round roll, no sherpaUSD is minted during round rolls
- **Operator Coordination**: The operator orchestrates synchronous pause, round roll, global price application, and withdrawal processing across all chains

**Vault accountingSupply vs shUSD totalSupply:**
- **shUSD totalSupply**: Existing shUSD tokens on a chain (fluctuates with CCIP bridges)
- **accountingSupply**: Logical ownership by a chain (immune to bridges, only changes when vault deposit/withdrawal interactions occur)
- **Price Calculation**: Uses global `accountingSupply` for stability during enroute crosschain transfers
- **Critical Relationship**: shUSD totalSupply + enroute CCIP transfers = accountingSupply

**Vault totalStaked vs Wrapper sherpaUSD totalSupply:**
- **totalStaked**: Total USDC value actively deployed into the strategy and earning yield in the vault (deposits take 1 round to take effect, withdrawals cause immediate effect)
- **sherpaUSD totalSupply**: Total SherpaUSD tokens in circulation, even if they are from pending deposits or unstaked (always 1:1 backed by USDC in wrapper)
- **Critical Relationship**: sherpaUSD totalSupply = totalStaked + totalPending (globally across all chains)

**Access Control & Roles:**
- **Owner**: High-privilege role for system configuration and governance
  - Can update critical parameters (keeper addresses, CCIP pools, deposit limits)
  - Can pause/unpause system in emergencies
  - Should be a multi-sig for security (e.g., Gnosis Safe)
- **Operator** (hot wallet): Day-to-day operational role for executing rounds and rebalancing
  - Executes `rollToNextRound()` and `applyGlobalPrice()` daily
  - Manages liquidity rebalancing across chains
  - Likely a single key for operational efficiency
- **Keeper** (SherpaVault contract): Automated role for vault-wrapper coordination
  - Vault acts as keeper of SherpaUSD wrapper (Operator → Vault → Wrapper delegation)
  - Enables contract-enforced safety checks for multi-chain coordination
  - This architecture ensures atomic operations across vault and wrapper interactions
- **CCIP Pools**: Authorized to mint/burn tokens during cross-chain bridges
- **Purpose**: Separation of duties - Owner controls configuration, Operator handles routine operations, minimizing risk while maintaining operational efficiency

---

## Quick Start

### 1. Setup & Installation

**Prerequisites:**
- Node.js v18.16+
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (install via `curl -L https://foundry.paradigm.xyz | bash` then `foundryup`)

**Toolchain:** This project uses dual tooling:
- **Foundry** - For tests, fuzzing, and fast compilation (`forge test`, `forge build`)
- **Hardhat/Node.js** - For all scripts in `scripts/` directory (deployment, operations, manual testing)

```bash
# Clone repository
git clone https://github.com/hedgemonyxyz/sherpa-vault-smartcontracts.git
cd sherpa-vault-smartcontracts

# Install dependencies
npm install && forge install

# Configure environment
cp .env.example .env
```

**Edit `.env` with required variables:**
```bash
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://...
BASE_SEPOLIA_RPC_URL=https://...
ARBITRUM_SEPOLIA_RPC_URL=https://...

# Optional: Backup RPCs for consensus (up to BACKUP4)
SEPOLIA_RPC_URL_BACKUP=https://...
```

```bash
# Compile contracts
forge build        # Foundry (recommended)
npm run compile    # Hardhat (alternative)
```

### 2. Run Tests

```bash
# Full test suite (156 tests)
forge test

# With gas reporting
forge test --gas-report

# Invariant tests (32.8M fuzz executions)
forge test --match-contract Invariants

# Coverage report
forge coverage
```

### 3. Deployment

**Deploy to testnet:**
```bash
# 1. Deploy vault and wrapper contracts to all chains
# 2. Deploy CCIP pools for cross-chain bridging
# 3. Configure cross-chain routes between pools
# 4. Enable deposits on all chains
# 5. Initialize system with initial USDC deposit
# 6. Execute first round roll to activate the system
```

Deployment scripts are located in `scripts/system-deployment/`. See `scripts/system-deployment/README.md` for detailed deployment procedures.

### 4. Manual Testing (Testnet)

After deployment, test user flows against the deployed system using the testing scripts in `scripts/testing/`:

**Test deposit flow:**
- Simulate user depositing USDC on any chain
- Verify pending deposits are tracked correctly

**Test bridging:**
- Simulate user bridging shUSD tokens between chains
- Verify CCIP message delivery and token minting

**Test withdrawal:**
- Simulate user unstaking and initiating withdrawal
- After epoch increments, complete the withdrawal
- Verify USDC is returned to user

### 5. Operations

Daily operations for live systems:

**Round roll (coordinates all chains):**
- The operator executes daily round rolls across all chains
- Calls `rollToNextRound()` on primary chain to calculate global price
- Calls `applyGlobalPrice()` on secondary chains to sync pricing
- Calls `processWithdrawals()` on all chains to advance epochs

**Rebalance liquidity:**
- The operator can rebalance SherpaUSD reserves between chains as needed
- Uses wrapper's `transferToChain()` function for cross-chain transfers
- Maintains adequate liquidity on each chain for withdrawal processing

Operational procedures and scripts are proprietary to the operator.

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/FUNCTION_REFERENCE.md](docs/FUNCTION_REFERENCE.md) | Complete API documentation for all contract functions |
| [scripts/system-deployment/README.md](scripts/system-deployment/README.md) | System deployment scripts reference |

**Note:** Operational procedures are proprietary and not included in this public repository.

---

### Unit & Invariant Test Results

```
╭───────────────────────────+────────+────────+─────────╮
│ Test Suite                │ Passed │ Failed │ Skipped │
├═══════════════════════════╪════════╪════════╪═════════┤
│ ShareMathTest             │ 24     │ 0      │ 0       │
│ SherpaUSDTest             │ 48     │ 0      │ 0       │
│ SherpaVaultTest           │ 67     │ 0      │ 0       │
│ SherpaVaultRebalancingTest│ 7      │ 0      │ 0       │
│ SherpaVaultInvariants     │ 10     │ 0      │ 0       │
╰───────────────────────────┴────────┴────────┴─────────╯

Total: 156/156 tests passing 
Invariant Testing: 32,768,000 fuzz executions across 10 invariants
```

---

### Known / Intentional System Limitations

- Round 1 deposits cannot be claimed (security feature to prevent price manipulation)
- Initial round roll cannot be called on any chain until primary chain has atleast 1 USDC in deposits
- Instant unstake only works for current round deposits (by design)
- CCIP bridges take 5-20 minutes (Chainlink network latency)
- Operator role must execute critical functions (required for daily operations)
- Centralized operations
   - No contract enforced round progression timeframes (operator manually rolls with script)
   - Operator manages all deposited funds directly
   - Owner / Operator has system pause capabilities
   - shUSD share price calculation accuracy is depedent upon offchain script logic
   - No deposits or withdrawals can finalize until operator manually interacts with the system

**Unit Test Environment:**
- Tests use mock USDC on each chain (not real USDC contracts)
- CCIP bridges are instant (no network latency)
- Multi-chain simulation via separate vault instances (not real chains)

See `test/README.md` (Section: Known Test Limitations) for complete list.

---

## Project Structure

```
smartcontracts/
├── contracts/
│   ├── SherpaVault.sol          # Core vault contract (shUSD ERC20)
│   ├── SherpaUSD.sol            # USDC wrapper with epoch withdrawals
│   ├── lib/
│   │   ├── ShareMath.sol        # Math library for share calculations
│   │   └── Vault.sol            # Data structures
│   └── external/
│       ├── ReentrancyGuard.sol  # OpenZeppelin reentrancy protection
│       └── ChainlinkPoolImport.sol  # CCIP pool interface
├── scripts/
│   ├── core/                       # Core operational scripts (proprietary)
│   ├── system-deployment/          # Deployment scripts for vaults, wrappers, and CCIP
│   │   └── README.md              # Deployment procedures
│   ├── testing/                    # Manual testing scripts for testnet
│   ├── utils/                      # Utility modules for scripts
│   └── config/                     # Configuration files
├── test/
│   ├── SherpaVault.t.sol        # 67 tests
│   ├── SherpaUSD.t.sol          # 48 tests
│   ├── ShareMath.t.sol          # 24 tests
│   ├── SherpaVaultRebalancing.t.sol  # 7 tests
│   └── invariant/
│       └── SherpaVaultInvariants.t.sol  # 10 invariants, 32.8M fuzz calls
├── docs/
│   └── FUNCTION_REFERENCE.md    # Complete API documentation
└── deployments/
    └── deployment.json          # Current deployment addresses
```

---


## Contact & Resources

- **Documentation:** See `docs/FUNCTION_REFERENCE.md` for complete API documentation
- **Tests:** See `/test` directory for comprehensive test suite
- **Deployment Info:** `deployments/deployment.json`
- **Block Explorers:**
  - Sepolia: https://sepolia.etherscan.io
  - Base Sepolia: https://sepolia.basescan.org
  - Arbitrum Sepolia: https://sepolia.arbiscan.io
- **CCIP Explorer:** https://ccip.chain.link/

---

**Built with:**
- Solidity 0.8.24
- Foundry / Forge
- Chainlink CCIP
- OpenZeppelin Contracts
- Ethers.js v5
