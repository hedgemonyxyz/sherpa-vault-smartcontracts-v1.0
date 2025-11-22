# Function Reference: SherpaVault & SherpaUSD

Comprehensive documentation of all functions in the SherpaVault multi-chain yield vault system.

---

## Table of Contents

- [SherpaVault.sol (shUSD / Vault)](#sherpavaultsol-shusd--vault)
  - [User-Facing Functions](#user-facing-functions)
  - [Operator Functions](#operator-functions)
  - [Owner Functions](#owner-functions)
  - [CCIP Functions](#ccip-functions)
  - [View Functions](#view-functions)
  - [Internal Functions](#internal-functions)
- [SherpaUSD.sol (sherpaUSD / USDC Wrapper)](#sherpausdsol-sherpausd--usdc-wrapper)
  - [User Functions](#user-functions)
  - [Keeper Functions](#keeper-functions)
  - [Operator Functions](#operator-functions-1)
  - [Owner Functions](#owner-functions-1)
  - [View Functions](#view-functions-1)

---

# SherpaVault.sol (shUSD / Vault)

**Note**: SherpaVault inherits from OpenZeppelin's `ERC20` and `Ownable` contracts, which provide standard functions like `transfer()`, `transferFrom()`, `approve()`, `increaseAllowance()`, `decreaseAllowance()`, `renounceOwnership()`, and `owner()`. These inherited functions are not explicitly documented here but are available on the contract. This reference focuses on custom vault-specific functions.

## User-Facing Functions

### depositAndStake()
```solidity
function depositAndStake(uint104 amount, address creditor) external nonReentrant whenNotPaused
```

**Purpose**: Deposits USDC and stakes for vault shares (shUSD)

**Parameters**:
- `amount` - Amount of USDC to deposit (6 decimals)
- `creditor` - Address to receive the stake receipt (usually msg.sender)

**Returns**: None (emits `Stake` event)

**Access**: Public, requires deposits enabled and system not paused

**Behavior**:
- Transfers USDC from user via SherpaUSD wrapper
- Updates user's stake receipt for current round
- Tracks pending deposits in `vaultState.totalPending`
- Deposits convert to shares when round rolls

**Reverts**:
- `DepositsDisabled()` - Deposits are paused
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `CapExceeded()` - Deposit would exceed vault cap
- `MinimumSupplyNotMet()` - Would violate minimum supply
- `SystemPaused()` - System is paused during round roll

**Used by**:
- Users depositing funds
- Tested in: `test_depositAndStake()`, `test_rollRound()`, multi-chain tests

**Related functions**: `_stakeInternal()`, `SherpaUSD.depositToVault()`

---

### maxClaimShares()
```solidity
function maxClaimShares() external nonReentrant whenNotPaused
```

**Purpose**: Claims all available shares from vault custody to user's wallet

**Parameters**: None

**Returns**: None (emits `ClaimShares` event)

**Access**: Public, requires system not paused

**Behavior**:
- Calculates unclaimed shares from stake receipt
- Transfers all shares from vault custody to user's wallet
- Updates stake receipt to clear claimed amount
- Does NOT burn shares, just transfers custody from vault to entitled user

**Reverts**:
- `SystemPaused()` - System is paused

**Used by**:
- Users claiming their shares after deposits convert
- Tested in: `test_maxClaimShares()`, `test_claimShares()`

**Related functions**: `claimShares()`, `_claimShares()`

---

### claimShares()
```solidity
function claimShares(uint256 numShares) external nonReentrant whenNotPaused
```

**Purpose**: Claims specific amount of shares from vault custody to user's wallet

**Parameters**:
- `numShares` - Number of shares to claim

**Returns**: None (emits `ClaimShares` event)

**Access**: Public, requires system not paused

**Behavior**:
- Validates user has sufficient unclaimed shares
- Transfers specified shares from vault custody to user's wallet
- Updates stake receipt

**Reverts**:
- `AmountMustBeGreaterThanZero()` - numShares is zero
- `InsufficientBalance()` - User doesn't have enough unclaimed shares
- `SystemPaused()` - System is paused

**Used by**:
- Users claiming partial shares
- Tested in: `test_claimShares()`

**Related functions**: `maxClaimShares()`, `_claimShares()`

---

### unstakeAndWithdraw()
```solidity
function unstakeAndWithdraw(uint256 sharesToUnstake, uint256 minAmountOut) external nonReentrant whenNotPaused
```

**Purpose**: Unstake shares and initiate withdrawal through wrapper (two-step flow)

**Parameters**:
- `sharesToUnstake` - Number of shUSD shares to burn
- `minAmountOut` - Minimum wrapped tokens to receive (slippage protection)

**Returns**: None (emits `Unstake` and `WithdrawalInitiated` events)

**Access**: Public, requires system not paused

**Behavior**:
- Auto-claims any unclaimed shares
- Burns shUSD shares from user
- Converts shares to SherpaUSD at previous round's price
- Sends SherpaUSD to wrapper contract
- Wrapper burns the SherpaUSD and creates withdrawal receipt for user
- User must call `completeWithdrawal()` on wrapper after epoch increments to receive USDC

**Reverts**:
- `AmountMustBeGreaterThanZero()` - sharesToUnstake is zero
- `InvalidRound()` - Round < 2 (no price available)
- `SlippageExceeded()` - Amount out < minAmountOut
- `InsufficientReserves()` - Vault lacks SherpaUSD reserves
- `MinimumSupplyNotMet()` - Would violate minimum supply
- `SystemPaused()` - System is paused

**Used by**:
- Users withdrawing through wrapper (standard flow)
- Tested in: `test_unstakeAndWithdraw()`, `test_completeWithdrawal()`

**Related functions**: `_unstake()`, `SherpaUSD.initiateWithdrawalFromVault()`, `SherpaUSD.completeWithdrawal()`

---

### unstake()
```solidity
function unstake(uint256 sharesToUnstake, uint256 minAmountOut) external nonReentrant whenNotPaused
```

**Purpose**: Unstake shares and receive SherpaUSD directly (bypasses wrapper)

**Parameters**:
- `sharesToUnstake` - Number of shUSD shares to burn
- `minAmountOut` - Minimum wrapped tokens value (slippage protection)

**Returns**: None (emits `Unstake` event)

**Access**: Public, requires `allowIndependence` enabled and system not paused

**Behavior**:
- Auto-claims any unclaimed shares
- Burns shUSD shares from user
- Converts shares to SherpaUSD at previous round's price
- Sends SherpaUSD directly to user (NO epoch delay)

**Reverts**:
- `IndependenceNotAllowed()` - Owner hasn't enabled direct unstaking
- `AmountMustBeGreaterThanZero()` - sharesToUnstake is zero
- `InvalidRound()` - Round < 2
- `SlippageExceeded()` - Amount out < minAmountOut
- `InsufficientReserves()` - Vault lacks SherpaUSD reserves
- `MinimumSupplyNotMet()` - Would violate minimum supply
- `SystemPaused()` - System is paused

**Used by**:
- Advanced users who want immediate SherpaUSD
- Tested in: `test_unstake()`

**Related functions**: `_unstake()`, `setAllowIndependence()`

---

### instantUnstake()
```solidity
function instantUnstake(uint104 amount) external nonReentrant whenNotPaused
```

**Purpose**: Instantly unstake PENDING deposits (current round only) with NO FEE

**Parameters**:
- `amount` - Amount of pending stake to instantly withdraw

**Returns**: None (emits `InstantUnstake` event)

**Access**: Public, requires `allowIndependence` enabled and system not paused

**Behavior**:
- Only works for deposits in current round (before round rolls)
- Returns SherpaUSD 1:1 (no share conversion, no fee)
- Reduces `stakeReceipt.amount` and `vaultState.totalPending`
- Sends SherpaUSD directly to user
- "Instant" means no waiting for round roll to mint shares, but user still needs to wait for epoch increment to convert SherpaUSD → USDC
- Saves one round/epoch of waiting compared to normal unstake flow

**Reverts**:
- `IndependenceNotAllowed()` - Owner hasn't enabled independence
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `InvalidRound()` - Stake not from current round
- `InsufficientBalance()` - Amount > pending stake
- `MinimumSupplyNotMet()` - Would violate minimum supply
- `SystemPaused()` - System is paused

**Used by**:
- Users exiting before round rollover
- Tested in: `test_instantUnstake()`

**Related functions**: `_instantUnstake()`, `instantUnstakeAndWithdraw()`

---

### instantUnstakeAndWithdraw()
```solidity
function instantUnstakeAndWithdraw(uint104 amount) external nonReentrant whenNotPaused
```

**Purpose**: Instantly unstake pending deposits and initiate withdrawal through wrapper

**Parameters**:
- `amount` - Amount of pending stake to instantly withdraw

**Returns**: None (emits `InstantUnstake` and `WithdrawalInitiated` events)

**Access**: Public, requires system not paused

**Behavior**:
- Same as `instantUnstake()` but routes through wrapper
- Sends SherpaUSD to wrapper contract
- Wrapper burns SherpaUSD and creates withdrawal receipt for user
- User must call `completeWithdrawal()` after epoch increments to receive USDC
- "Instant" means no waiting for round roll to mint shares, but still requires one epoch increment for withdrawal finalization
- Saves one round/epoch of waiting compared to normal unstakeAndWithdraw flow

**Reverts**: Same as `instantUnstake()` (except no `IndependenceNotAllowed`)

**Used by**:
- Users exiting current round through wrapper
- Tested in: `test_instantUnstakeAndWithdraw()`

**Related functions**: `_instantUnstake()`, `SherpaUSD.initiateWithdrawalFromVault()`

---

## Operator Functions

### rollToNextRound()
```solidity
function rollToNextRound(
    uint256 yield,
    bool isYieldPositive,
    uint256 globalTotalStaked,
    uint256 globalShareSupply,
    uint256 globalTotalPending
) external onlyOperator nonReentrant
```

**Purpose**: PRIMARY CHAIN: Calculate global price using operator-provided totals from all chains

**Parameters**:
- `yield` - Total yield across all chains
- `isYieldPositive` - Whether yield is positive or negative
- `globalTotalStaked` - Total staked across all chains
- `globalShareSupply` - Total share supply across all chains
- `globalTotalPending` - Total pending deposits across all chains

**Returns**: None (emits `RoundRolled` event)

**Access**: Operator or owner only, primary chain only

**Behavior**:
- Calculates global price per share using multi-chain totals
- Sets `roundPricePerShare[currentRound]`
- Increments round number
- Mints shares for local pending deposits
- Adjusts local SherpaUSD balance based on yield
- Adds pending to `totalStaked`
- Clears `vaultState.totalPending`

**Reverts**:
- `OnlyPrimaryChain()` - Called on secondary chain
- `MinimumSupplyNotMet()` - Total balance < minimum supply
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Automated round roll operations (operator wallet)
- Tested in: `test_rollToNextRound()`, `test_rollRoundWithYield()`

**Related functions**: `_rollInternal()`, `_adjustBalanceAndEmit()`, `applyGlobalPrice()`

---

### applyGlobalPrice()
```solidity
function applyGlobalPrice(uint256 newRound, uint256 globalPricePerShare) external onlyOperator nonReentrant
```

**Purpose**: SECONDARY CHAIN: Apply global price calculated by primary chain

**Parameters**:
- `newRound` - The round number to advance to (must be currentRound + 1)
- `globalPricePerShare` - The global price calculated by primary chain

**Returns**: None (emits `GlobalPriceApplied` and `RoundRolled` events)

**Access**: Operator or owner only, secondary chains only

**Behavior**:
- Sets `roundPricePerShare[currentRound]` to global price
- Mints shares for local pending deposits using global price
- Adds pending to `totalStaked`
- Clears `vaultState.totalPending`
- Increments round number
- **Note**: Does NOT adjust local SherpaUSD balance (yield is only applied on primary chain)

**Reverts**:
- `OnlySecondaryChain()` - Called on primary chain
- `MinimumSupplyNotMet()` - New total staked < minimum supply
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Automated round roll operations after primary chain completes
- Tested in: `test_applyGlobalPrice()`

**Related functions**: `rollToNextRound()`

---

### setSystemPaused()
```solidity
function setSystemPaused(bool _isPaused) external onlyOperator
```

**Purpose**: Toggle system pause state to block user interactions during critical operations

**Parameters**:
- `_isPaused` - True to pause all user interactions, false to unpause

**Returns**: None (emits `SystemPausedToggled` event)

**Access**: Operator or owner only

**Behavior**:
- Pauses: depositAndStake, unstake, unstakeAndWithdraw, instantUnstake, instantUnstakeAndWithdraw, claimShares, maxClaimShares
- Does NOT pause: owner functions, view functions, CCIP functions
- Sets auto-unpause deadline to 24 hours from now
- Auto-unpauses after deadline to prevent permanent freeze

**Reverts**:
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Operator to prevent state changes during round transitions and rebalancing operations
- Tested in: `test_systemPause()`, `test_autoUnpause()`

**Related functions**: `emergencyUnpause()`, `whenNotPaused()` modifier

---

### processWrapperWithdrawals()
```solidity
function processWrapperWithdrawals() external onlyOperator
```

**Purpose**: Process withdrawals on SherpaUSD wrapper (increments epoch)

**Parameters**: None

**Returns**: None

**Access**: Operator or owner only

**Behavior**:
- Calls `SherpaUSD.processWithdrawals()`
- Increments wrapper epoch
- Makes queued withdrawals claimable
- Should be called after each round roll to keep epochs synchronized
- **autoTransfer functionality** (if enabled on wrapper):
  - **Coverage transfer** (withdrawals > deposits): Automatically pulls USDC from owner → wrapper to cover withdrawal deficit
  - **Acquisition transfer** (deposits > withdrawals): Automatically sends surplus USDC from wrapper → owner
  - If disabled (default): Operator manually executes coverage/acquisition transfers

**Reverts**:
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Operator after rolling all chains
- Tested in: `test_processWrapperWithdrawals()`

**Related functions**: `SherpaUSD.processWithdrawals()`

**Architecture**: Vault acts as gatekeeper to enforce correct ordering of round rolls and epoch processing

---

### adjustTotalStaked()
```solidity
function adjustTotalStaked(int256 adjustment) external onlyOperator
```

**Purpose**: Adjust totalStaked during SherpaUSD reserves rebalancing operations

**Parameters**:
- `adjustment` - Positive to increase totalStaked, negative to decrease (must match sherpaUSD minted/burned)

**Returns**: None

**Access**: Operator or owner only

**Behavior**:
- Increases or decreases `totalStaked` to match actual reserves after sherpaUSD mint/burn
- Must be called AFTER `SherpaUSD.ownerMint()` or `SherpaUSD.ownerBurn()`
- **Validation**: Validates adjustment matches approved amount from wrapper:
  - Queries `approvedTotalStakedAdjustment` from SherpaUSD
  - Requires `abs(adjustment) == approved` (exact match)
  - Consumes approval via `consumeTotalStakedApproval()`
  - Prevents operator from adjusting without corresponding mint/burn
- **Critical**: Adjustment amount must EXACTLY equal the amount passed to `ownerMint()` or `ownerBurn()`
- Part of atomic rebalancing sequence: pause → mint/burn → adjust accounting supply → adjust totalStaked → verify → unpause
- Works in tandem with `adjustAccountingSupply()` to maintain system invariants
- Used for cross-chain reserves management

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Adjustment is zero
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Operator during cross-chain reserves rebalancing
- Tested in: `test_adjustTotalStaked()`

**Related functions**: `adjustAccountingSupply()`, `SherpaUSD.ownerMint()`, `SherpaUSD.ownerBurn()`

---

### adjustAccountingSupply()
```solidity
function adjustAccountingSupply(int256 adjustment) external onlyOperator
```

**Purpose**: Adjust accounting supply during SherpaUSD reserves rebalancing operations

**Parameters**:
- `adjustment` - Positive to increase, negative to decrease (must match sherpaUSD mint/burn amount divided by current price)

**Returns**: None (emits `AccountingSupplyAdjusted` event)

**Access**: Operator or owner only

**Behavior**:
- Adjusts `accountingSupply` (logical shares per chain) during sherpaUSD reserves rebalancing
- **NOT used for user CCIP bridges** - accountingSupply is immune to user bridge activity
- **Used during operator rebalancing** - when operator calls `SherpaUSD.ownerMint()` or `SherpaUSD.ownerBurn()` to rebalance reserves between chains
- **Validation**: Validates adjustment calculation matches expected shares:
  - Queries `approvedAccountingAdjustment` from SherpaUSD (the minted/burned amount)
  - Calculates expected shares: `ShareMath.assetToShares(approved, roundPricePerShare[round-1], decimals)`
  - Requires `abs(adjustment) == expectedShares` (exact match)
  - Consumes approval via `consumeAccountingApproval()`
  - Prevents operator from using incorrect price or calculations
- **Critical**: Adjustment amount must EXACTLY equal the amount passed to `ownerMint()`/`ownerBurn()` divided by current round price
- Part of atomic rebalancing sequence: pause → mint/burn → adjust accounting supply → adjust totalStaked → verify → unpause
- Works in tandem with `adjustTotalStaked()` to maintain system invariants

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Adjustment is zero
- `OnlyOperator()` - Not operator or owner

**Used by**:
- Operator during cross-chain reserves rebalancing
- Tested in: `test_adjustAccountingSupply()`

**Related functions**: `adjustTotalStaked()`, `SherpaUSD.ownerMint()`, `SherpaUSD.ownerBurn()`

---

## Owner Functions

### setCap()
```solidity
function setCap(uint104 newCap) external onlyOwner
```

**Purpose**: Update vault capacity limit on this specific chain

**Parameters**:
- `newCap` - New capacity in USDC (6 decimals) for this chain only

**Returns**: None (emits `CapSet` event)

**Access**: Owner only

**Behavior**:
- Sets capacity limit for this specific chain's vault
- Each chain has independent cap that must be set separately
- Does NOT affect caps on other chains
- Total system capacity = sum of all chain caps

**Reverts**:
- `CapMustBeGreaterThanZero()` - newCap is zero

**Used by**: Owner for per-chain capacity management

---

### setPrimaryChain()
```solidity
function setPrimaryChain(uint64 chainSelector, bool _isPrimary) external onlyOwner
```

**Purpose**: Designate this vault as primary or secondary chain

**Parameters**:
- `chainSelector` - CCIP chain selector for primary chain
- `_isPrimary` - True if this is primary chain, false if secondary

**Returns**: None (emits `PrimaryChainSet` event)

**Access**: Owner only

**Behavior**:
- Primary chain calls `rollToNextRound()`
- Secondary chains call `applyGlobalPrice()`
- Configuration determines which vault calculates global price

**Used by**: Initial deployment setup

---

### setDepositsEnabled()
```solidity
function setDepositsEnabled(bool enabled) external onlyOwner
```

**Purpose**: Enable or disable deposits on this vault

**Parameters**:
- `enabled` - True to enable deposits, false to disable

**Returns**: None (emits `DepositsToggled` event)

**Access**: Owner only

**Behavior**:
- When false, `depositAndStake()` reverts with `DepositsDisabled()`
- When true, deposits are allowed (unless system is paused)
- More granular control than `setSystemPaused()` - only affects deposits, not withdrawals/redemptions
- **Note**: Operator typically uses `setSystemPaused()` instead, which is more comprehensive

**Used by**:
- Owner for manual deposit control

---

### setAllowIndependence()
```solidity
function setAllowIndependence(bool _allowIndependence) external onlyOwner
```

**Purpose**: Enable or disable direct unstaking (bypassing wrapper)

**Parameters**:
- `_allowIndependence` - True to allow direct unstaking, false to require wrapper

**Returns**: None (emits `AllowIndependenceSet` event)

**Access**: Owner only

**Behavior**:
- When true, users can call `unstake()` and `instantUnstake()` directly
- When false, users must use `unstakeAndWithdraw()` and `instantUnstakeAndWithdraw()`

**Used by**: Owner for user experience control

---

### setStableWrapper()
```solidity
function setStableWrapper(address newWrapper) external onlyOwner
```

**Purpose**: Update the SherpaUSD wrapper contract address

**Parameters**:
- `newWrapper` - Address of new SherpaUSD wrapper

**Returns**: None (emits `StableWrapperUpdated` event)

**Access**: Owner only

**Behavior**:
- Updates vault's wrapper address to point to new SherpaUSD contract
- Use with extreme caution - affects all deposits/withdrawals
- **Required during deployment**: Vault constructor requires wrapper address, so deployment uses temporary placeholder then updates to real wrapper

**Deployment usage**:
1. Deploy vault with temporary wrapper (deployer address as placeholder)
2. Deploy actual SherpaUSD wrapper
3. Call `setStableWrapper()` to update vault with real wrapper address

**Reverts**:
- `AddressMustBeNonZero()` - newWrapper is zero address

**Used by**:
- Initial deployment to connect vault to wrapper
- Emergency wrapper contract upgrades (rare)

---

### rescueTokens()
```solidity
function rescueTokens(address token, uint256 amount) external onlyOwner
```

**Purpose**: Rescue tokens accidentally sent to the vault

**Parameters**:
- `token` - Address of token to rescue
- `amount` - Amount to rescue

**Returns**: None (emits `TokensRescued` event)

**Access**: Owner only

**Behavior**:
- Can rescue any ERC20 token EXCEPT stableWrapper (SherpaUSD)
- SECURITY: Cannot rescue user funds (stableWrapper is protected)

**Reverts**:
- `AddressMustBeNonZero()` - token is zero address
- `AmountMustBeGreaterThanZero()` - amount is zero
- `CannotRescueWrapperToken()` - Attempted to rescue SherpaUSD (user funds)

**Used by**: Emergency recovery of mistakenly sent tokens

---

### setOperator()
```solidity
function setOperator(address newOperator) external onlyOwner
```

**Purpose**: Set or change the operator address for automated operations on this chain

**Parameters**:
- `newOperator` - Address of new operator wallet

**Returns**: None (emits `OperatorUpdated` event)

**Access**: Owner only

**Behavior**:
- Operator can call: rollToNextRound, applyGlobalPrice, setSystemPaused, adjustTotalStaked, adjustAccountingSupply, processWrapperWithdrawals
- Operator is hot wallet for daily automation
- Owner is multi-sig for strategic decisions
- Must be called separately on each chain's vault and wrapper

**Reverts**:
- `AddressMustBeNonZero()` - newOperator is zero address

**Used by**: Post-deployment setup and operator rotation

---

### transferOwnership()
```solidity
function transferOwnership(address newOwner) external onlyOwner
```

**Purpose**: Transfer ownership to a new address (typically multi-sig wallet)

**Parameters**:
- `newOwner` - Address of new owner (typically multi-sig)

**Returns**: None (emits `OwnershipTransferred` event)

**Access**: Owner only (inherited from OpenZeppelin `Ownable`)

**Behavior**:
- Transfers all owner-level privileges to new address
- Current owner loses all owner permissions immediately
- **Critical**: Must be called on both vault AND wrapper for each chain
- Part of production deployment transition from deployer EOA to multi-sig governance

**Used by**: Production deployment to transition to multi-sig governance

---

### addCCIPPool()
```solidity
function addCCIPPool(address pool) external onlyOwner
```

**Purpose**: Authorize a CCIP pool address to mint/burn tokens

**Parameters**:
- `pool` - Address of CCIP token pool (BurnFromMintTokenPool)

**Returns**: None (emits `CCIPPoolAdded` event)

**Access**: Owner only

**Behavior**:
- Pool can call `mint()`, `burn()`, `burnFrom()` for cross-chain transfers
- Required for CCIP bridging functionality
- Each chain needs its pool authorized

**Reverts**:
- `AddressMustBeNonZero()` - pool is zero address

**Used by**: CCIP deployment operations

**Architecture**: See `CCIP-ARCHITECTURE.md`

---

### removeCCIPPool()
```solidity
function removeCCIPPool(address pool) external onlyOwner
```

**Purpose**: Deauthorize a CCIP pool address

**Parameters**:
- `pool` - Address of CCIP token pool to remove

**Returns**: None (emits `CCIPPoolRemoved` event)

**Access**: Owner only

**Behavior**: Pool can no longer mint/burn tokens

**Used by**: Emergency removal of compromised pool

---

## CCIP Functions

These functions implement the `IBurnMintERC20` interface required by Chainlink CCIP `BurnFromMintTokenPool`.

### mint()
```solidity
function mint(address account, uint256 amount) external override
```

**Purpose**: Mint tokens - callable only by authorized CCIP pools

**Parameters**:
- `account` - Address to mint to
- `amount` - Amount to mint

**Returns**: None

**Access**: Authorized CCIP pools only

**Behavior**:
- Called by pool on destination chain during cross-chain transfer
- Increases ERC20 `totalSupply()` but NOT `accountingSupply`
- `accountingSupply` tracks logical ownership, immune to CCIP transfers

**Reverts**:
- `OnlyCCIPPool()` - Caller not authorized pool

**Used by**: CCIP pool during releaseOrMint on destination chain

**Architecture**: See `CCIP-ARCHITECTURE.md` for full flow

---

### burn(uint256 amount)
```solidity
function burn(uint256 amount) external override
```

**Purpose**: Burn tokens from sender - callable by CCIP pools

**Parameters**:
- `amount` - Amount to burn from msg.sender

**Returns**: None

**Access**: Authorized CCIP pools only

**Behavior**:
- Decreases ERC20 `totalSupply()` but NOT `accountingSupply`

**Reverts**:
- `OnlyCCIPPool()` - Caller not authorized pool

**Used by**: CCIP pool during lockOrBurn on source chain

---

### burn(address account, uint256 amount)
```solidity
function burn(address account, uint256 amount) external override
```

**Purpose**: Burn tokens from address - callable by CCIP pools

**Parameters**:
- `account` - Address to burn from
- `amount` - Amount to burn

**Returns**: None

**Access**: Authorized CCIP pools only

**Reverts**:
- `OnlyCCIPPool()` - Caller not authorized pool

**Used by**: CCIP pool during lockOrBurn on source chain

---

### burnFrom()
```solidity
function burnFrom(address account, uint256 amount) external override
```

**Purpose**: Burn tokens using allowance - callable by CCIP pools

**Parameters**:
- `account` - Address to burn from
- `amount` - Amount to burn

**Returns**: None

**Access**: Authorized CCIP pools only

**Behavior**:
- Spends pool's allowance from account
- Pool must have been granted allowance first

**Reverts**:
- `OnlyCCIPPool()` - Caller not authorized pool

**Used by**: CCIP pool during lockOrBurn on source chain

**Note**: Pool must have self-allowance: `vault.approve(pool, type(uint256).max)`

---

## View Functions

### cap()
```solidity
function cap() public view returns (uint256)
```

**Purpose**: Get vault capacity limit

**Returns**: Capacity in USDC (6 decimals)

**Used by**: UI to show vault limits, operator to check capacity

---

### round()
```solidity
function round() public view returns (uint256)
```

**Purpose**: Get current round number

**Returns**: Current round (starts at 1)

**Used by**: All operations, UI, tests

---

### totalPending()
```solidity
function totalPending() public view returns (uint256)
```

**Purpose**: Get total pending deposits for current round

**Returns**: Pending deposits in USDC (6 decimals)

**Used by**: Operator to calculate shares to mint during round roll

---

### decimals()
```solidity
function decimals() public view override returns (uint8)
```

**Purpose**: Get token decimals

**Returns**: 6 (same as USDC)

**Used by**: ERC20 standard compliance

---

### getReserveAmount()
```solidity
function getReserveAmount() external view returns (uint256)
```

**Purpose**: Get available SherpaUSD reserves in this vault

**Returns**: Amount of SherpaUSD held by vault

**Used by**: Operator checking if reserves need adjustment

---

### getReserveLevel()
```solidity
function getReserveLevel() external view returns (uint256)
```

**Purpose**: Get reserve level as percentage of cap

**Returns**: Percentage (0-100) of reserves available

**Used by**: UI to show reserve health, operator planning rebalancing

---

### accountVaultBalance()
```solidity
function accountVaultBalance(address account) external view returns (uint256)
```

**Purpose**: Get total vault balance (asset value) for an account

**Parameters**:
- `account` - Address to check

**Returns**: Total asset value (pending + shares value in wrapped tokens)

**Behavior**:
- Combines pending deposits with share value at current price
- Uses previous round's price (current round price isn't set until roll)
- Includes: pending amount + unclaimed shares + claimed shares

**Used by**: UI to show user's total vault balance

---

### shares()
```solidity
function shares(address account) external view returns (uint256)
```

**Purpose**: Get total shares for an account (claimed + unclaimed)

**Parameters**:
- `account` - Address to check

**Returns**: Total shares (in wallet + in vault custody)

**Used by**: UI to show user's total shares

---

### pauseTimeRemaining()
```solidity
function pauseTimeRemaining() external view returns (uint256)
```

**Purpose**: Get remaining time until auto-unpause (in seconds)

**Returns**: Seconds remaining until auto-unpause (0 if not paused or already expired)

**Used by**: UI to show when system will auto-unpause

---

### shareBalancesHeldByAccount()
```solidity
function shareBalancesHeldByAccount(address account) external view returns (uint256)
```

**Purpose**: Get shares held in user's wallet (already claimed)

**Parameters**:
- `account` - Address to check

**Returns**: Shares in wallet

**Used by**: UI to show claimed shares

---

### shareBalancesHeldByVault()
```solidity
function shareBalancesHeldByVault(address account) external view returns (uint256)
```

**Purpose**: Get shares held by vault for user (pending redemption)

**Parameters**:
- `account` - Address to check

**Returns**: Shares in vault custody (unclaimed)

**Used by**: UI to show shares available to claim

---

### stableWrapper()
```solidity
function stableWrapper() public view returns (address)
```

**Purpose**: Get address of the SherpaUSD wrapper contract

**Returns**: SherpaUSD wrapper contract address

**Used by**: Operations to query wrapper address, UI for contract interactions

---

### totalStaked()
```solidity
function totalStaked() public view returns (uint256)
```

**Purpose**: Get total USDC backing shares on this chain

**Returns**: Total staked USDC (6 decimals)

**Used by**: Operator to calculate global totals during round roll, rebalancing operations

---

### lastRollTimestamp()
```solidity
function lastRollTimestamp() public view returns (uint256)
```

**Purpose**: Get timestamp of last round roll

**Returns**: Unix timestamp of last round roll

**Used by**: Monitoring tools checking time since last roll

---

### accountingSupply()
```solidity
function accountingSupply() public view returns (uint256)
```

**Purpose**: Get logical shares tracked per chain (immune to CCIP transfers)

**Returns**: Accounting supply (logical shares for this chain)

**Behavior**:
- Tracks logical ownership of shares per chain
- NOT affected by user CCIP bridges (user bridges only move physical tokens)
- Only adjusted during operator reserves rebalancing via `adjustAccountingSupply()`

**Used by**: Operator to calculate global share supply during round roll, system audits

---

### primaryChainSelector()
```solidity
function primaryChainSelector() public view returns (uint64)
```

**Purpose**: Get CCIP chain selector of the primary chain

**Returns**: CCIP chain selector (e.g., 16015286601757825753 for Sepolia)

**Used by**: Operations checking primary chain identity

---

### isPrimaryChain()
```solidity
function isPrimaryChain() public view returns (bool)
```

**Purpose**: Check if this vault is on the primary chain

**Returns**: True if primary chain, false if secondary

**Used by**: Operations determining which round roll function to call

---

### operator()
```solidity
function operator() public view returns (address)
```

**Purpose**: Get operator wallet address

**Returns**: Operator wallet address (hot wallet for automation)

**Used by**: Operations verifying operator identity, access control checks

---

### depositsEnabled()
```solidity
function depositsEnabled() public view returns (bool)
```

**Purpose**: Check if deposits are currently enabled

**Returns**: True if deposits enabled, false if disabled

**Used by**: UI to show deposit availability, operations checking state

---

### allowIndependence()
```solidity
function allowIndependence() public view returns (bool)
```

**Purpose**: Check if direct unstaking (bypassing wrapper) is allowed

**Returns**: True if `unstake()` and `instantUnstake()` are enabled, false otherwise

**Used by**: UI to show available withdrawal paths

---

### isPaused()
```solidity
function isPaused() public view returns (bool)
```

**Purpose**: Check if system is paused

**Returns**: True if system paused, false otherwise

**Used by**: UI to show system status, operations checking if operations are blocked

---

### pauseDeadline()
```solidity
function pauseDeadline() public view returns (uint256)
```

**Purpose**: Get timestamp when auto-unpause will occur

**Returns**: Unix timestamp of auto-unpause deadline (0 if not paused)

**Used by**: UI to show when system will auto-unpause, monitoring tools

---

### stakeReceipts()
```solidity
function stakeReceipts(address account) public view returns (StakeReceipt)
```

**Purpose**: Get stake receipt for an account

**Parameters**:
- `account` - Address to check

**Returns**: StakeReceipt struct containing:
- `amount` - Pending deposit amount (not yet converted to shares)
- `unclaimedShares` - Shares minted but not yet transferred to user wallet
- `round` - Round in which the stake was made

**Used by**: UI to show user's pending deposits and unclaimed shares

---

### roundPricePerShare()
```solidity
function roundPricePerShare(uint256 roundNumber) public view returns (uint256)
```

**Purpose**: Get price per share for a specific round

**Parameters**:
- `roundNumber` - Round number to query

**Returns**: Price per share for that round (6 decimals)

**Used by**: Operations calculating share conversions, UI showing historical prices

---

### ccipPools()
```solidity
function ccipPools(address pool) public view returns (bool)
```

**Purpose**: Check if an address is an authorized CCIP pool

**Parameters**:
- `pool` - Address to check

**Returns**: True if authorized to mint/burn tokens, false otherwise

**Used by**: Operations verifying CCIP pool authorization

---

### vaultParams()
```solidity
function vaultParams() public view returns (VaultParams)
```

**Purpose**: Get vault parameters

**Returns**: VaultParams struct containing:
- `decimals` - Token decimals (6)
- `minimumSupply` - Minimum total supply required
- `cap` - Maximum capacity for this chain

**Used by**: Operations checking vault configuration

---

### vaultState()
```solidity
function vaultState() public view returns (VaultState)
```

**Purpose**: Get current vault state

**Returns**: VaultState struct containing:
- `round` - Current round number
- `totalPending` - Total pending deposits for current round

**Used by**: Operations querying vault state

---

## Internal Functions

### _stakeInternal()
```solidity
function _stakeInternal(uint104 amount, address creditor) private
```

**Purpose**: Internal stake logic called by `depositAndStake()`

**Behavior**:
- Updates stake receipt for creditor
- Tracks pending deposits
- Validates cap and minimum supply

**Used by**: `depositAndStake()`

---

### _claimShares()
```solidity
function _claimShares(uint256 numShares, bool isMax) internal
```

**Purpose**: Internal claim logic (auto-claims unclaimed shares before unstaking)

**Parameters**:
- `numShares` - Number of shares to claim (ignored if isMax)
- `isMax` - If true, claims all unclaimed shares

**Behavior**:
- Calculates unclaimed shares from receipt
- Transfers shares from vault custody to user's wallet
- Updates stake receipt to reflect redemption
- **Auto-claim**: Called automatically by `_unstake()` before burning shares

**Used by**:
- Direct: `claimShares()`, `maxClaimShares()`, `_unstake()`
- Indirect (via `_unstake()`): `unstake()`, `unstakeAndWithdraw()`

---

### _unstake()
```solidity
function _unstake(uint256 sharesToUnstake, address recipient, uint256 minAmountOut) internal returns (uint256)
```

**Purpose**: Internal unstake logic

**Parameters**:
- `sharesToUnstake` - Number of shares to burn
- `recipient` - Address to receive SherpaUSD (user or wrapper)
- `minAmountOut` - Minimum wrapped tokens to receive

**Returns**: Amount of wrapped tokens transferred

**Behavior**:
- Auto-claims any unclaimed shares
- Burns shares
- Converts to SherpaUSD at previous round's price
- Checks reserves and minimum supply
- Transfers SherpaUSD to recipient

**Used by**: `unstake()`, `unstakeAndWithdraw()`

---

### _instantUnstake()
```solidity
function _instantUnstake(uint104 amount, address recipient) internal
```

**Purpose**: Internal instant unstake logic (NO FEE)

**Parameters**:
- `amount` - Amount to instantly unstake
- `recipient` - Address to receive SherpaUSD

**Behavior**:
- Only works on pending deposits (stakeReceipt.amount) in current round
- Returns tokens 1:1 (no share conversion)
- Reduces pending amount and totalPending
- Maintains minimum supply requirement

**Used by**: `instantUnstake()`, `instantUnstakeAndWithdraw()`

---

### _rollInternal()
```solidity
function _rollInternal(
    uint256 yield,
    bool isYieldPositive,
    uint256 globalTotalStaked,
    uint256 globalShareSupply,
    uint256 globalTotalPending
) internal
```

**Purpose**: Core round roll logic (primary chain only)

**Behavior**:
- Calculates global price per share using multi-chain totals
- Sets roundPricePerShare for current round
- Mints shares for local pending deposits
- **Adjusts local SherpaUSD balance based on yield (primary chain only)**
- Increments round number
- Adds pending to `totalStaked`
- Clears `vaultState.totalPending`

**Note**: Only called on primary chain via `rollToNextRound()`. Secondary chains use `applyGlobalPrice()` which does NOT adjust SherpaUSD balance.

**Used by**: `rollToNextRound()` (primary chain only)

---

### _adjustBalanceAndEmit()
```solidity
function _adjustBalanceAndEmit(
    uint256 currentBalance,
    uint256 balance,
    uint256 currentRound,
    uint256 newPricePerShare,
    uint256 mintShares,
    uint256 yield,
    bool isYieldPositive
) internal
```

**Purpose**: Adjust SherpaUSD balance for yield and emit events

**Behavior**:
- If yield positive: mints SherpaUSD to vault
- If yield negative: burns SherpaUSD from vault
- Emits RoundRolled event with appropriate parameters

**Used by**: `_rollInternal()`

---

### _ccipReceive()
```solidity
function _ccipReceive(Client.Any2EVMMessage memory message) internal override
```

**Purpose**: Handle incoming CCIP messages

**Behavior**: Currently reserved for future functionality (vault coordination happens via operator)

**Used by**: CCIP OffRamp when messages arrive

---

### emergencyUnpause()
```solidity
function emergencyUnpause() external
```

**Purpose**: Emergency unpause callable by anyone after deadline

**Access**: Public (anyone can call after deadline)

**Behavior**:
- Allows anyone to rescue system if owner key lost
- Only works after 24-hour auto-unpause deadline
- Clears pause state

**Reverts**:
- Requires system is paused
- Requires deadline has been reached
- Requires deadline is set

**Used by**: Emergency recovery if operator/owner keys lost

---

# SherpaUSD.sol (sherpaUSD / USDC Wrapper)

**Note**: SherpaUSD inherits from OpenZeppelin's `ERC20` and `Ownable` contracts, which provide standard functions like `transfer()`, `transferFrom()`, `approve()`, `increaseAllowance()`, `decreaseAllowance()`, `renounceOwnership()`, and `owner()`. These inherited functions are not explicitly documented here but are available on the contract. This reference focuses on custom wrapper-specific functions.

## User Functions

### initiateWithdrawal()
```solidity
function initiateWithdrawal(uint224 amount) external nonReentrant
```

**Purpose**: Initiate withdrawal directly on wrapper (bypasses vault) - edge case function

**Parameters**:
- `amount` - Amount of sherpaUSD to withdraw

**Returns**: None (emits `WithdrawalInitiated` event)

**Access**: Public

**Behavior**:
- Burns sherpaUSD directly from user's wallet
- Creates/updates withdrawal receipt with current epoch
- User must wait for epoch to increment before calling `completeWithdrawal()`
- **Direct path**: User holds sherpaUSD and withdraws without vault interaction

**When users would have sherpaUSD**:
- **Only if `allowIndependence = true`**: Owner enables direct unstaking on vault
- User calls `vault.unstake()` or `vault.instantUnstake()` to receive sherpaUSD directly
- User then calls this function to convert sherpaUSD → USDC
- **Unlikely scenario**: This requires owner to enable `allowIndependence`, which is typically disabled

**Normal vault flow** (does NOT call this function):
1. User calls `vault.unstakeAndWithdraw()`
2. Vault calls `initiateWithdrawalFromVault()` (different function, not this one)

**Direct wrapper flow** (calls this function):
1. Owner enables `vault.setAllowIndependence(true)`
2. User calls `vault.unstake()` → receives sherpaUSD
3. User calls `wrapper.initiateWithdrawal()` (this function) → burns sherpaUSD, creates receipt
4. User calls `wrapper.completeWithdrawal()` → receives USDC

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `InsufficientBalance()` - User balance < amount

**Used by**:
- Edge case: Users with sherpaUSD who bypass vault withdrawal flow
- Tested in: `test_initiateWithdrawal()`

**Related functions**: `completeWithdrawal()`, `initiateWithdrawalFromVault()`, `vault.setAllowIndependence()`, `vault.unstake()`

---

### completeWithdrawal()
```solidity
function completeWithdrawal() external nonReentrant
```

**Purpose**: Complete withdrawal after epoch passes

**Parameters**: None

**Returns**: None (emits `Withdrawn` event)

**Access**: Public

**Behavior**:
- Checks withdrawal receipt epoch != current epoch
- Transfers USDC to user
- Clears withdrawal receipt

**Reverts**:
- `CannotCompleteWithdrawalInSameEpoch()` - Epoch hasn't incremented yet
- `AmountMustBeGreaterThanZero()` - No withdrawal receipt

**Used by**:
- Users claiming USDC after epoch increments
- Tested in: `test_completeWithdrawal()`

**Related functions**: `initiateWithdrawal()`, `initiateWithdrawalFromVault()`

---

## Keeper Functions

Note: "Keeper" is the vault contract itself. These functions are called by SherpaVault.

### depositToVault()
```solidity
function depositToVault(address from, uint256 amount) external nonReentrant onlyKeeper
```

**Purpose**: Vault deposits USDC from user and mints sherpaUSD to keeper (vault)

**Parameters**:
- `from` - User depositing USDC
- `amount` - Amount of USDC to deposit

**Returns**: None (emits `DepositToVault` event)

**Access**: Keeper (vault) only

**Behavior**:
- Transfers USDC from user to wrapper
- Mints sherpaUSD to keeper (vault)
- Tracks deposit amount for epoch

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `NotKeeper()` - Caller is not keeper

**Used by**: `SherpaVault.depositAndStake()`

**Related functions**: `SherpaVault.depositAndStake()`

---

### initiateWithdrawalFromVault()
```solidity
function initiateWithdrawalFromVault(address from, uint224 amount) external nonReentrant onlyKeeper
```

**Purpose**: Initiate withdrawal from vault (called by vault on behalf of user)

**Parameters**:
- `from` - User address to create withdrawal receipt for
- `amount` - Amount to withdraw

**Returns**: None (emits `WithdrawalInitiated` event)

**Access**: Keeper (vault) only

**Behavior**:
- Burns sherpaUSD from wrapper contract's balance
- Creates withdrawal receipt for user
- User calls `completeWithdrawal()` after epoch increments

**Call flow** (from `vault.unstakeAndWithdraw()`):
1. Vault burns user's shUSD shares
2. Vault transfers sherpaUSD from vault → wrapper contract
3. Vault calls `wrapper.initiateWithdrawalFromVault(user, amount)`
4. Wrapper burns sherpaUSD from its own balance (that vault just transferred)
5. Wrapper creates withdrawal receipt for user

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `NotKeeper()` - Caller is not keeper

**Used by**: `SherpaVault.unstakeAndWithdraw()`, `SherpaVault.instantUnstakeAndWithdraw()`

**Related functions**: `completeWithdrawal()`

---

### processWithdrawals()
```solidity
function processWithdrawals() external onlyKeeper nonReentrant
```

**Purpose**: Process withdrawals and roll to next epoch (keeper only)

**Parameters**: None

**Returns**: None (emits `WithdrawalsProcessed` event)

**Access**: Keeper (vault) only

**Behavior**:
- If `autoTransfer` enabled: automatically transfers USDC to/from owner
  - If withdrawals > deposits: pulls USDC from owner
  - If deposits > withdrawals: sends excess to owner
- Increments `currentEpoch`
- Resets `depositAmountForEpoch` and `withdrawalAmountForEpoch` to 0
- Makes all pending withdrawals claimable

**Reverts**:
- `NotKeeper()` - Caller is not keeper

**Used by**: `SherpaVault.processWrapperWithdrawals()`

**Related functions**: `SherpaVault.processWrapperWithdrawals()`, `setAutoTransfer()`

**Architecture**: Epochs must stay synchronized with rounds across all chains

---

### permissionedMint()
```solidity
function permissionedMint(address to, uint256 amount) external onlyKeeper
```

**Purpose**: Permissioned mint for positive yield (keeper only)

**Parameters**:
- `to` - Address to mint to (usually vault)
- `amount` - Amount to mint

**Returns**: None (emits `PermissionedMint` event)

**Access**: Keeper (vault) only

**Behavior**: Mints sherpaUSD into primary chain vault when vault has positive yield

**Reverts**:
- `NotKeeper()` - Caller is not keeper

**Used by**: `SherpaVault._adjustBalanceAndEmit()` when yield is positive (primary chain only)

---

### permissionedBurn()
```solidity
function permissionedBurn(address from, uint256 amount) external onlyKeeper
```

**Purpose**: Permissioned burn for negative yield (keeper only)

**Parameters**:
- `from` - Address to burn from (usually vault)
- `amount` - Amount to burn

**Returns**: None (emits `PermissionedBurn` event)

**Access**: Keeper (vault) only

**Behavior**: Burns sherpaUSD from primary chain vault when vault has negative yield

**Reverts**:
- `NotKeeper()` - Caller is not keeper

**Used by**: `SherpaVault._adjustBalanceAndEmit()` when yield is negative (primary chain only)

---

## Operator Functions

### ownerMint()
```solidity
function ownerMint(address to, uint256 amount) external onlyOperator
```

**Purpose**: Operator-level mint for **share-sync rebalancing** (CCIP bridging of user shares)

**Parameters**:
- `to` - Address to mint to (usually vault)
- `amount` - Amount of sherpaUSD to mint

**Returns**: None (emits `PermissionedMint` event)

**Access**: Operator or owner only

**Behavior**:
- Mints sherpaUSD on destination chain during **share-sync rebalancing** (both shares AND backing move together)
- **Automatically sets adjustment approvals** for the vault:
  - `approvedTotalStakedAdjustment[to] = amount` (backing adjustment)
  - `approvedAccountingAdjustment[to] = amount` (share ownership adjustment)
- Part of atomic rebalancing sequence: pause → **mint sherpaUSD** → adjust accounting supply → adjust totalStaked → verify → unpause
- **Critical**: Must call BOTH `SherpaVault.adjustAccountingSupply()` and `SherpaVault.adjustTotalStaked()` after minting to maintain system invariants
- **Validation**: Vault adjustment functions will validate against these approvals and consume them
- Minted amount must EXACTLY match the subsequent totalStaked adjustment
- Minted amount divided by current price must EXACTLY match the accountingSupply adjustment
- **Use case**: CCIP bridging when users move shUSD shares between chains (both backing and share ownership move)

**When to use**:
- **Share-sync rebalancing**: Use `ownerMint()`/`ownerBurn()` when BOTH shares and backing need to move
  - Example: CCIP bridging - user moves shUSD from Chain A to Chain B
  - Adjusts: `totalStaked` (backing location) AND `accountingSupply` (share ownership location)
- **NOT for yield rebalancing**: Do NOT use for yield-induced backing imbalances
  - Use `ownerMintAssetOnly()`/`ownerBurnAssetOnly()` instead (see below)

**Reverts**:
- `OnlyOperator()` - Not operator or owner
- `ApprovalNotConsumed()` - Previous approvals not consumed (enforces atomicity, prevents accounting corruption)

**Important**: Approvals must be consumed (via `consumeTotalStakedApproval()` and `consumeAccountingApproval()`) before calling this function again. This enforcement prevents accounting corruption from batched operations (Audit Issue #13 fix).

**Related functions**: `ownerBurn()`, `ownerMintAssetOnly()`, `ownerBurnAssetOnly()`, `SherpaVault.adjustAccountingSupply()`, `SherpaVault.adjustTotalStaked()`, `approvedTotalStakedAdjustment()`, `approvedAccountingAdjustment()`

---

### ownerBurn()
```solidity
function ownerBurn(address from, uint256 amount) external onlyOperator
```

**Purpose**: Operator-level burn for **share-sync rebalancing** (CCIP bridging of user shares)

**Parameters**:
- `from` - Address to burn from (usually vault)
- `amount` - Amount of sherpaUSD to burn

**Returns**: None (emits `PermissionedBurn` event)

**Access**: Operator or owner only

**Behavior**:
- Burns sherpaUSD on source chain during **share-sync rebalancing** (both shares AND backing move together)
- **Automatically sets adjustment approvals** for the vault:
  - `approvedTotalStakedAdjustment[from] = amount` (backing adjustment)
  - `approvedAccountingAdjustment[from] = amount` (share ownership adjustment)
- Part of atomic rebalancing sequence: pause → **burn sherpaUSD** → adjust accounting supply → adjust totalStaked → verify → unpause
- **Critical**: Must call BOTH `SherpaVault.adjustAccountingSupply()` and `SherpaVault.adjustTotalStaked()` after burning to maintain system invariants
- **Validation**: Vault adjustment functions will validate against these approvals and consume them
- Burned amount must EXACTLY match the subsequent totalStaked adjustment (negative)
- Burned amount divided by current price must EXACTLY match the accountingSupply adjustment (negative)
- **Use case**: CCIP bridging when users move shUSD shares between chains (both backing and share ownership move)

**When to use**:
- **Share-sync rebalancing**: Use `ownerMint()`/`ownerBurn()` when BOTH shares and backing need to move
  - Example: CCIP bridging - user moves shUSD from Chain A to Chain B
  - Adjusts: `totalStaked` (backing location) AND `accountingSupply` (share ownership location)
- **NOT for yield rebalancing**: Do NOT use for yield-induced backing imbalances
  - Use `ownerMintAssetOnly()`/`ownerBurnAssetOnly()` instead (see below)

**Reverts**:
- `OnlyOperator()` - Not operator or owner
- `ApprovalNotConsumed()` - Previous approvals not consumed (enforces atomicity, prevents accounting corruption)

**Important**: Approvals must be consumed (via `consumeTotalStakedApproval()` and `consumeAccountingApproval()`) before calling this function again. This enforcement prevents accounting corruption from batched operations (Audit Issue #13 fix).

**Related functions**: `ownerMint()`, `ownerMintAssetOnly()`, `ownerBurnAssetOnly()`, `SherpaVault.adjustAccountingSupply()`, `SherpaVault.adjustTotalStaked()`, `approvedTotalStakedAdjustment()`, `approvedAccountingAdjustment()`

---

### ownerMintAssetOnly()
```solidity
function ownerMintAssetOnly(address to, uint256 amount) external onlyOperator
```

**Purpose**: Operator-level mint for **asset-only rebalancing** (yield-induced backing imbalances)

**Parameters**:
- `to` - Address to mint to (usually vault)
- `amount` - Amount of sherpaUSD to mint

**Returns**: None (emits `PermissionedMint` and `RebalanceApprovalSet` events)

**Access**: Operator or owner only

**Behavior**:
- Mints sherpaUSD on destination chain during **asset-only rebalancing** (only backing moves, shares stay put)
- **Only sets totalStaked approval** (NOT accountingSupply approval):
  - `approvedTotalStakedAdjustment[to] = amount` (backing adjustment)
  - `approvedAccountingAdjustment[to] = 0` (NO share ownership adjustment)
- **Critical difference from `ownerMint()`**: Does NOT adjust `accountingSupply` because share ownership doesn't change
- Part of atomic yield rebalancing sequence: pause → **mint sherpaUSD** → adjust totalStaked only → verify → unpause
- **Important**: Only call `SherpaVault.adjustTotalStaked()` after minting (NOT `adjustAccountingSupply()`)
- **Validation**: Vault's `adjustTotalStaked()` validates against approval and consumes it
- Minted amount must EXACTLY match the subsequent totalStaked adjustment

**When to use**:
- **Yield-induced rebalancing**: Use `ownerMintAssetOnly()`/`ownerBurnAssetOnly()` when yield creates backing imbalance
  - Example: Yield earned on primary chain creates 60/40 backing split but users deposited 50/50
  - Need to rebalance backing to match user deposits WITHOUT changing share ownership
  - Adjusts: `totalStaked` (backing location) ONLY, NOT `accountingSupply` (share ownership unchanged)
- **NOT for CCIP bridging**: Do NOT use for user share movements across chains
  - Use `ownerMint()`/`ownerBurn()` instead (adjusts both totalStaked and accountingSupply)

**Reverts**:
- `OnlyOperator()` - Not operator or owner
- `ApprovalNotConsumed()` - Previous approvals not consumed (enforces atomicity, prevents accounting corruption)

**Important**: Approvals must be consumed (via `consumeTotalStakedApproval()` and `consumeAccountingApproval()`) before calling this function again. This enforcement prevents accounting corruption from batched operations (Audit Issue #13 fix).

**Related functions**: `ownerMint()`, `ownerBurnAssetOnly()`, `SherpaVault.adjustTotalStaked()`, `consumeTotalStakedApproval()`

---

### ownerBurnAssetOnly()
```solidity
function ownerBurnAssetOnly(address from, uint256 amount) external onlyOperator
```

**Purpose**: Operator-level burn for **asset-only rebalancing** (yield-induced backing imbalances)

**Parameters**:
- `from` - Address to burn from (usually vault)
- `amount` - Amount of sherpaUSD to burn

**Returns**: None (emits `PermissionedBurn` and `RebalanceApprovalSet` events)

**Access**: Operator or owner only

**Behavior**:
- Burns sherpaUSD on source chain during **asset-only rebalancing** (only backing moves, shares stay put)
- **Only sets totalStaked approval** (NOT accountingSupply approval):
  - `approvedTotalStakedAdjustment[from] = amount` (backing adjustment)
  - `approvedAccountingAdjustment[from] = 0` (NO share ownership adjustment)
- **Critical difference from `ownerBurn()`**: Does NOT adjust `accountingSupply` because share ownership doesn't change
- Part of atomic yield rebalancing sequence: pause → **burn sherpaUSD** → adjust totalStaked only → verify → unpause
- **Important**: Only call `SherpaVault.adjustTotalStaked()` after burning (NOT `adjustAccountingSupply()`)
- **Validation**: Vault's `adjustTotalStaked()` validates against approval and consumes it
- Burned amount must EXACTLY match the subsequent totalStaked adjustment (negative)

**When to use**:
- **Yield-induced rebalancing**: Use `ownerMintAssetOnly()`/`ownerBurnAssetOnly()` when yield creates backing imbalance
  - Example: Yield earned on primary chain creates uneven backing distribution
  - Rebalance backing to maintain proportional reserves WITHOUT changing where users deposited
  - Adjusts: `totalStaked` (backing location) ONLY, NOT `accountingSupply` (share ownership unchanged)
- **NOT for CCIP bridging**: Do NOT use for user share movements across chains
  - Use `ownerMint()`/`ownerBurn()` instead (adjusts both totalStaked and accountingSupply)

**Reverts**:
- `OnlyOperator()` - Not operator or owner
- `ApprovalNotConsumed()` - Previous approvals not consumed (enforces atomicity, prevents accounting corruption)

**Important**: Approvals must be consumed (via `consumeTotalStakedApproval()` and `consumeAccountingApproval()`) before calling this function again. This enforcement prevents accounting corruption from batched operations (Audit Issue #13 fix).

**Related functions**: `ownerBurn()`, `ownerMintAssetOnly()`, `SherpaVault.adjustTotalStaked()`, `consumeTotalStakedApproval()`

---

### transferAsset()
```solidity
function transferAsset(address to, uint256 amount) external onlyOperator
```

**Purpose**: Transfer USDC from wrapper to external address (acquisition transfers)

**Parameters**:
- `to` - Destination address (typically owner/operator wallet)
- `amount` - Amount of USDC to transfer

**Returns**: None (emits `AssetTransferred` event)

**Access**: Operator or owner only

**Behavior**:
- Transfers USDC from wrapper contract to specified address
- **Primary use**: Acquisition transfers during round rolls (when deposits > withdrawals)

**Acquisition transfer flow** (deposits > withdrawals):
1. Round rolls, epoch increments via `processWrapperWithdrawals()`
2. Wrapper has surplus USDC (more deposits than withdrawals)
3. Operator acquires surplus
4. Operator calls `wrapper.transferAsset(ownerAddress, surplus)`
5. Surplus USDC transferred from wrapper → owner wallet

**Coverage transfer flow** (withdrawals > deposits):
- NOT handled by this function
- Operator directly transfers USDC via `USDC.transfer(wrapper, deficit)` from owner wallet → wrapper

**Reverts**:
- `AmountMustBeGreaterThanZero()` - Amount is zero
- `OnlyOperator()` - Not operator or owner

**Used by**: Operator for acquisition transfers (wrapper → owner)

---

### consumeTotalStakedApproval()
```solidity
function consumeTotalStakedApproval(address vault) external
```

**Purpose**: Consume approval for totalStaked adjustment (called by vault)

**Parameters**:
- `vault` - Address of the vault consuming the approval

**Returns**: None

**Access**: Only callable by the vault itself

**Behavior**:
- Clears `approvedTotalStakedAdjustment[vault]` to 0
- Called by `SherpaVault.adjustTotalStaked()` after validating adjustment
- Prevents reuse of approvals

**Reverts**:
- `"Only vault can consume"` - Caller is not the vault address

**Used by**: `SherpaVault.adjustTotalStaked()` during reserves rebalancing

**Related functions**: `ownerMint()`, `ownerBurn()`, `approvedTotalStakedAdjustment()`

---

### consumeAccountingApproval()
```solidity
function consumeAccountingApproval(address vault) external
```

**Purpose**: Consume approval for accounting adjustment (called by vault)

**Parameters**:
- `vault` - Address of the vault consuming the approval

**Returns**: None

**Access**: Only callable by the vault itself

**Behavior**:
- Clears `approvedAccountingAdjustment[vault]` to 0
- Called by `SherpaVault.adjustAccountingSupply()` after validating adjustment
- Prevents reuse of approvals

**Reverts**:
- `"Only vault can consume"` - Caller is not the vault address

**Used by**: `SherpaVault.adjustAccountingSupply()` during reserves rebalancing

**Related functions**: `ownerMint()`, `ownerBurn()`, `approvedAccountingAdjustment()`

---

## Owner Functions

### setKeeper()
```solidity
function setKeeper(address _keeper) external onlyOwner
```

**Purpose**: Set new keeper address (vault contract)

**Parameters**:
- `_keeper` - New keeper address

**Returns**: None (emits `KeeperSet` event)

**Access**: Owner only

**Reverts**:
- `AddressMustBeNonZero()` - _keeper is zero address

**Used by**: Initial deployment or vault upgrade

---

### setOperator()
```solidity
function setOperator(address newOperator) external onlyOwner
```

**Purpose**: Set or change the operator address for automated operations on this chain

**Parameters**:
- `newOperator` - Address of new operator wallet

**Returns**: None (emits `OperatorUpdated` event)

**Access**: Owner only

**Behavior**:
- Operator can call: ownerMint, ownerBurn, transferAsset
- Must be set on both vault AND wrapper for each chain
- Same operator address typically used across all chains

**Reverts**:
- `AddressMustBeNonZero()` - newOperator is zero address

**Used by**: Post-deployment setup and operator rotation

---

### transferOwnership()
```solidity
function transferOwnership(address newOwner) external onlyOwner
```

**Purpose**: Transfer ownership to a new address (typically multi-sig wallet)

**Parameters**:
- `newOwner` - Address of new owner (typically multi-sig)

**Returns**: None (emits `OwnershipTransferred` event)

**Access**: Owner only (inherited from OpenZeppelin `Ownable`)

**Behavior**:
- Transfers all owner-level privileges to new address
- Current owner loses all owner permissions immediately
- **Critical**: Must be called on both vault AND wrapper for each chain
- Part of production deployment transition from deployer EOA to multi-sig governance

**Used by**: Production deployment to transition to multi-sig governance

---

### setAutoTransfer()
```solidity
function setAutoTransfer(bool _enabled) external onlyOwner
```

**Purpose**: Enable or disable automatic USDC transfers in processWithdrawals()

**Parameters**:
- `_enabled` - True to enable automatic transfers, false for manual control

**Returns**: None (emits `AutoTransferSet` event)

**Access**: Owner only

**Behavior**:
- When true: `processWithdrawals()` automatically pulls/sends USDC from/to owner
- When false: Manual USDC management required

**Used by**: Owner to control USDC flow automation

---

## View Functions

### decimals()
```solidity
function decimals() public pure override returns (uint8)
```

**Purpose**: Returns token decimals (same as USDC)

**Returns**: 6

**Used by**: ERC20 standard compliance

---

### currentEpoch()
```solidity
function currentEpoch() public view returns (uint32)
```

**Purpose**: Get current epoch number

**Returns**: Current epoch number

**Used by**:
- Operations checking epoch synchronization across chains
- Users checking when withdrawals become claimable

---

### autoTransfer()
```solidity
function autoTransfer() public view returns (bool)
```

**Purpose**: Check if automatic USDC transfers are enabled

**Returns**: True if autoTransfer enabled, false otherwise

**Behavior**:
- When true: `processWithdrawals()` automatically handles coverage/acquisition transfers
- When false: Manual transfers required

**Used by**: Operations checking transfer mode configuration

---

### withdrawalAmountForEpoch()
```solidity
function withdrawalAmountForEpoch() public view returns (uint256)
```

**Purpose**: Get total withdrawal amount queued for current epoch

**Returns**: Total USDC amount of queued withdrawals (6 decimals)

**Used by**:
- Operations calculating coverage/deficit for current epoch

---

### depositAmountForEpoch()
```solidity
function depositAmountForEpoch() public view returns (uint256)
```

**Purpose**: Get total deposit amount for current epoch

**Returns**: Total USDC amount deposited in current epoch (6 decimals)

**Used by**:
- Operations calculating acquisition/surplus for current epoch

---

### asset()
```solidity
function asset() public view returns (address)
```

**Purpose**: Get address of the underlying asset (USDC)

**Returns**: USDC contract address

**Used by**: Operations querying underlying asset, UI for token interactions

---

### keeper()
```solidity
function keeper() public view returns (address)
```

**Purpose**: Get keeper address (vault contract)

**Returns**: Keeper address (SherpaVault contract address)

**Used by**: Operations verifying keeper identity, access control checks

---

### operator()
```solidity
function operator() public view returns (address)
```

**Purpose**: Get operator wallet address

**Returns**: Operator wallet address (hot wallet for automation)

**Used by**: Operations verifying operator identity, access control checks

---

### withdrawalReceipts()
```solidity
function withdrawalReceipts(address account) public view returns (WithdrawalReceipt)
```

**Purpose**: Get withdrawal receipt for an account

**Parameters**:
- `account` - Address to check

**Returns**: WithdrawalReceipt struct containing:
- `amount` - Amount of USDC queued for withdrawal
- `epoch` - Epoch when withdrawal was initiated

**Used by**: UI to show user's pending withdrawals and claimable amounts

---

### approvedTotalStakedAdjustment()
```solidity
function approvedTotalStakedAdjustment(address vault) public view returns (uint256)
```

**Purpose**: Get approved adjustment amount for totalStaked

**Parameters**:
- `vault` - Vault address to check approval for

**Returns**: Approved amount for totalStaked adjustment (0 if none)

**Behavior**:
- Set by `ownerMint()` and `ownerBurn()` during rebalancing
- Consumed by `SherpaVault.adjustTotalStaked()` after validation
- Prevents operator from adjusting totalStaked without corresponding mint/burn

**Used by**:
- `SherpaVault.adjustTotalStaked()` for validation
- Operations/UI for checking approval status

**Related functions**: `ownerMint()`, `ownerBurn()`, `consumeTotalStakedApproval()`

---

### approvedAccountingAdjustment()
```solidity
function approvedAccountingAdjustment(address vault) public view returns (uint256)
```

**Purpose**: Get approved adjustment amount for accountingSupply

**Parameters**:
- `vault` - Vault address to check approval for

**Returns**: Approved SherpaUSD amount for accountingSupply adjustment (0 if none)

**Behavior**:
- Set by `ownerMint()` and `ownerBurn()` during rebalancing
- Consumed by `SherpaVault.adjustAccountingSupply()` after calculation validation
- Vault converts this to expected shares using current price for validation
- Prevents operator from adjusting accountingSupply with incorrect calculations

**Used by**:
- `SherpaVault.adjustAccountingSupply()` for validation
- Operations/UI for checking approval status

**Related functions**: `ownerMint()`, `ownerBurn()`, `consumeAccountingApproval()`

---

## Summary

### Key Function Patterns

**User Journey - Deposit**:
1. User calls `vault.depositAndStake(amount, user)`
2. Vault calls `wrapper.depositToVault(user, amount)`
3. Wrapper transfers USDC from user, mints sherpaUSD to vault
4. User's pending deposit tracked until round rolls
5. When round rolls, pending converts to shares at new price

**User Journey - Withdraw (Standard)**:
1. User calls `vault.unstakeAndWithdraw(shares, minOut)`
2. Vault burns shares, converts to sherpaUSD at previous round's price
3. Vault calls `wrapper.initiateWithdrawalFromVault(user, amount)`
4. Wrapper burns sherpaUSD, creates withdrawal receipt for user
5. After epoch increments (via `vault.processWrapperWithdrawals()`), user calls `wrapper.completeWithdrawal()`
6. Wrapper transfers USDC to user

**Round Roll - Multi-Chain**:
1. Operator calls `vault.setDepositsEnabled(false)` on all chains
2. Operator queries totalStaked, totalSupply, totalPending from all chains
3. Operator calls `sepoliaVault.rollToNextRound(yield, isPositive, globalTotalStaked, globalSupply, globalPending)`
4. Operator calls `baseVault.applyGlobalPrice(newRound, globalPrice)`
5. Operator calls `arbitrumVault.applyGlobalPrice(newRound, globalPrice)`
6. Operator calls `vault.processWrapperWithdrawals()` on all chains (increments epochs)
7. Operator calls `vault.setDepositsEnabled(true)` on all chains

**Access Control Hierarchy**:
- **User**: depositAndStake, claimShares, unstake, withdraw
- **Operator** (hot wallet): rollToNextRound, applyGlobalPrice, setSystemPaused, processWrapperWithdrawals, adjustTotalStaked, adjustAccountingSupply, ownerMint, ownerBurn, transferAsset
- **Owner** (multi-sig): All admin functions, setOperator, setCap, setPrimaryChain, setDepositsEnabled, etc.
- **Keeper** (vault contract): Calls wrapper functions on behalf of users

**CCIP Integration**:
- Vault implements `IBurnMintERC20` (mint, burn, burnFrom)
- Pool calls these during lockOrBurn (source) and releaseOrMint (destination)
- `accountingSupply` tracks logical ownership (immune to CCIP burns/mints)
- `totalSupply()` reflects physical tokens on chain (affected by CCIP)

---

## Testing Coverage

All functions are covered by tests in `test/`:
- `TestSherpaVault.t.sol` - Core vault functionality
- `TestSherpaUSD.t.sol` - Wrapper functionality
- `TestMultiChain.t.sol` - Cross-chain coordination
- `TestInvariantSherpaVault.t.sol` - Property-based invariant testing

See contract comments for detailed test coverage analysis.

---

## Related Documentation

For additional information, see the main README.md and contract source code.
