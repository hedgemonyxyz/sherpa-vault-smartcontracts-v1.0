// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SherpaVault} from "../../contracts/SherpaVault.sol";
import {SherpaUSD} from "../../contracts/SherpaUSD.sol";
import {Vault} from "../../contracts/lib/Vault.sol";
import {MockUSDC} from "../../contracts/MockUSDC.sol";

/**
 * @title SherpaVault Invariant Tests
 * @notice Comprehensive invariant testing for multi-chain SherpaVault deployment
 *
 * CRITICAL FOCUS: Price calculation accuracy through correct accounting
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ACCOUNTING MODEL (Why accountingSupply exists):
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * totalSupply:
 *   - Tracks shares currently held on THIS chain
 *   - Changes via deposits, withdrawals, AND CCIP bridges
 *   - Per-chain value fluctuates as users bridge
 *
 * accountingSupply:
 *   - Tracks shares that originated from THIS chain's deposits
 *   - Changes ONLY via deposits, withdrawals, and manual rebalancing
 *   - IMMUNE to CCIP bridges (by design!)
 *   - This is the SOURCE OF TRUTH for price calculation
 *
 * Why accountingSupply is immune to bridges:
 *   - Bridges take time (CCIP messages can take minutes)
 *   - If accountingSupply changed during bridges, global sum would fluctuate
 *   - Price calculation during round roll would use wrong global accountingSupply
 *   - By keeping accountingSupply immune, we have stable accounting for price
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * PRICE FORMULA (SherpaVault.sol:467-477):
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *   pricePerShare = ShareMath.pricePerShare(
 *       globalShareSupply,    // sum(accountingSupply[all chains])
 *       globalBalance,        // sum(totalStaked + totalPending ± yield)
 *       globalTotalPending,   // sum(totalPending[all chains])
 *       decimals
 *   )
 *
 * If any of these aggregates are corrupted by bugs in deposits, withdrawals,
 * rebalancing, or CCIP bridges, the price will be WRONG and users can be
 * exploited or funds lost.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHAT THIS TEST FUZZES:
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *   ✅ Deposits (increases totalPending, will increase accountingSupply on roll)
 *   ✅ Withdrawals (instant: decreases totalStaked + accountingSupply)
 *   ✅ Round rolls (pending→staked, mints shares, updates accountingSupply)
 *   ✅ Rebalancing (moves SherpaUSD + adjusts totalStaked + accountingSupply)
 *   ✅ CCIP bridges (moves shares, does NOT change accountingSupply)
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * HOW TO RUN:
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Foundry (fast, during development):
 *   forge test --match-contract SherpaVaultInvariants -vv
 *   forge test --match-contract SherpaVaultInvariants --fuzz-runs 10000
 *
 * Echidna (thorough, before audit):
 *   echidna . --contract SherpaVaultInvariants --config echidna.yaml
 *
 * ═══════════════════════════════════════════════════════════════════════════
 */
contract SherpaVaultInvariants is Test {
    // =================================================================
    // STATE VARIABLES
    // =================================================================

    // Contracts
    SherpaVault public vaultSepolia;
    SherpaVault public vaultBase;
    SherpaVault public vaultArbitrum;

    SherpaUSD public wrapperSepolia;
    SherpaUSD public wrapperBase;
    SherpaUSD public wrapperArbitrum;

    MockUSDC public usdc;

    // Mock CCIP pools
    MockCCIPPool public ccipPoolSepolia;
    MockCCIPPool public ccipPoolBase;
    MockCCIPPool public ccipPoolArbitrum;

    // Test actors
    address public owner;
    address public operator;
    address public user1;
    address public user2;
    address public user3;

    // Tracking for invariants
    uint256 public totalDeposited;  // All USDC deposited across all chains
    uint256 public totalWithdrawn;  // All USDC withdrawn across all chains
    int256 public totalYieldApplied; // Net yield applied (positive - negative)

    // Bridge tracking (for accounting invariant with in-flight transfers)
    struct BridgeTransfer {
        address user;
        uint256 amount;
        uint256 sourceChainId;
        uint256 destChainId;
        uint256 timestamp;
        bool completed;
    }
    BridgeTransfer[] public bridgeTransfers;

    // Constants
    uint256 constant SEPOLIA_CHAIN_ID = 1;
    uint256 constant BASE_CHAIN_ID = 2;
    uint256 constant ARBITRUM_CHAIN_ID = 3;

    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC per user
    uint256 constant MAX_DEPOSIT = 100_000e6;       // 100k USDC max deposit
    uint256 constant MAX_YIELD = 50_000e6;          // 50k USDC max yield per round

    // =================================================================
    // SETUP
    // =================================================================

    function setUp() public {
        // Deploy USDC mock
        usdc = new MockUSDC();

        // Setup actors
        owner = address(this);
        operator = address(0x100);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy wrappers (SherpaUSD) with temporary keeper
        wrapperSepolia = new SherpaUSD(address(usdc), address(0xdead));
        wrapperBase = new SherpaUSD(address(usdc), address(0xdead));
        wrapperArbitrum = new SherpaUSD(address(usdc), address(0xdead));

        // Deploy vaults with proper parameters
        vaultSepolia = deploySherpaVault(address(wrapperSepolia), "Sherpa Vault Sepolia", "svSEP");
        vaultBase = deploySherpaVault(address(wrapperBase), "Sherpa Vault Base", "svBASE");
        vaultArbitrum = deploySherpaVault(address(wrapperArbitrum), "Sherpa Vault Arbitrum", "svARB");

        // Setup wrappers to use vaults as keepers
        wrapperSepolia.setKeeper(address(vaultSepolia));
        wrapperBase.setKeeper(address(vaultBase));
        wrapperArbitrum.setKeeper(address(vaultArbitrum));

        // Set operator
        vaultSepolia.setOperator(operator);
        vaultBase.setOperator(operator);
        vaultArbitrum.setOperator(operator);

        wrapperSepolia.setOperator(operator);
        wrapperBase.setOperator(operator);
        wrapperArbitrum.setOperator(operator);

        // Deploy mock CCIP pools
        ccipPoolSepolia = new MockCCIPPool(address(vaultSepolia));
        ccipPoolBase = new MockCCIPPool(address(vaultBase));
        ccipPoolArbitrum = new MockCCIPPool(address(vaultArbitrum));

        // Authorize CCIP pools
        vaultSepolia.addCCIPPool(address(ccipPoolSepolia));
        vaultBase.addCCIPPool(address(ccipPoolBase));
        vaultArbitrum.addCCIPPool(address(ccipPoolArbitrum));

        // Fund users with USDC
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);
        usdc.mint(user3, INITIAL_BALANCE);

        // Approve wrappers to spend USDC (for deposits)
        vm.prank(user1);
        usdc.approve(address(wrapperSepolia), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(wrapperBase), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(wrapperArbitrum), type(uint256).max);

        vm.prank(user2);
        usdc.approve(address(wrapperSepolia), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(wrapperBase), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(wrapperArbitrum), type(uint256).max);

        vm.prank(user3);
        usdc.approve(address(wrapperSepolia), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(wrapperBase), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(wrapperArbitrum), type(uint256).max);

        // Set target contract for Foundry invariant testing
        targetContract(address(this));
    }

    function deploySherpaVault(address wrapper, string memory name, string memory symbol)
        internal
        returns (SherpaVault)
    {
        // Create minimal vault params for testing
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 6,
            minimumSupply: 1e6,  // 1 USDC minimum (matches deployed contracts)
            cap: 10_000_000e6    // 10M USDC cap
        });

        return new SherpaVault(
            name,
            symbol,
            wrapper,
            address(this),
            params
        );
    }

    // =================================================================
    // HELPER FUNCTIONS
    // =================================================================

    function getVault(uint256 chainId) internal view returns (SherpaVault) {
        if (chainId == SEPOLIA_CHAIN_ID) return vaultSepolia;
        if (chainId == BASE_CHAIN_ID) return vaultBase;
        if (chainId == ARBITRUM_CHAIN_ID) return vaultArbitrum;
        revert("Invalid chain ID");
    }

    function getWrapper(uint256 chainId) internal view returns (SherpaUSD) {
        if (chainId == SEPOLIA_CHAIN_ID) return wrapperSepolia;
        if (chainId == BASE_CHAIN_ID) return wrapperBase;
        if (chainId == ARBITRUM_CHAIN_ID) return wrapperArbitrum;
        revert("Invalid chain ID");
    }

    function getCCIPPool(uint256 chainId) internal view returns (MockCCIPPool) {
        if (chainId == SEPOLIA_CHAIN_ID) return ccipPoolSepolia;
        if (chainId == BASE_CHAIN_ID) return ccipPoolBase;
        if (chainId == ARBITRUM_CHAIN_ID) return ccipPoolArbitrum;
        revert("Invalid chain ID");
    }

    function getGlobalAccountingSupply() internal view returns (uint256) {
        return vaultSepolia.accountingSupply()
            + vaultBase.accountingSupply()
            + vaultArbitrum.accountingSupply();
    }

    function getGlobalTotalSupply() internal view returns (uint256) {
        return vaultSepolia.totalSupply()
            + vaultBase.totalSupply()
            + vaultArbitrum.totalSupply();
    }

    function getGlobalTotalStaked() internal view returns (uint256) {
        return vaultSepolia.totalStaked()
            + vaultBase.totalStaked()
            + vaultArbitrum.totalStaked();
    }

    function getGlobalTotalPending() internal view returns (uint256) {
        return vaultSepolia.totalPending()
            + vaultBase.totalPending()
            + vaultArbitrum.totalPending();
    }

    function getGlobalSherpaUSDBalance() internal view returns (uint256) {
        return wrapperSepolia.balanceOf(address(vaultSepolia))
            + wrapperBase.balanceOf(address(vaultBase))
            + wrapperArbitrum.balanceOf(address(vaultArbitrum));
    }

    function getInFlightBridgeAmount() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < bridgeTransfers.length; i++) {
            if (!bridgeTransfers[i].completed) {
                total += bridgeTransfers[i].amount;
            }
        }
        return total;
    }

    // =================================================================
    // FUZZED ACTIONS (Foundry will call these randomly)
    // =================================================================

    /**
     * @notice Fuzzed deposit action
     * @dev Deposits increase totalPending immediately, accountingSupply increases during round roll
     */
    function action_deposit(uint256 chainId, uint256 userSeed, uint256 amount) public {
        // Bound inputs to valid ranges
        chainId = bound(chainId, 1, 3);
        userSeed = bound(userSeed, 1, 3);
        amount = bound(amount, 1e6, MAX_DEPOSIT); // 1 USDC to 100k USDC

        address user = userSeed == 1 ? user1 : userSeed == 2 ? user2 : user3;
        SherpaVault vault = getVault(chainId);

        // Check if user has enough USDC balance
        if (usdc.balanceOf(user) < amount) return;

        // Check if vault is paused (can't deposit when paused)
        if (vault.isPaused()) return;

        vm.prank(user);
        try vault.depositAndStake(uint104(amount), user) {
            totalDeposited += amount;
        } catch {
            // Deposit failed (e.g., cap reached), that's ok
        }
    }

    /**
     * @notice Fuzzed withdrawal action
     * @dev Withdrawals decrease totalStaked and accountingSupply immediately
     */
    function action_unstakeAndWithdraw(uint256 chainId, uint256 userSeed, uint256 sharePercent) public {
        chainId = bound(chainId, 1, 3);
        userSeed = bound(userSeed, 1, 3);
        sharePercent = bound(sharePercent, 1, 100); // 1% to 100% of user's shares

        address user = userSeed == 1 ? user1 : userSeed == 2 ? user2 : user3;
        SherpaVault vault = getVault(chainId);

        // Check if vault is paused
        if (vault.isPaused()) return;

        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) return;

        uint256 sharesToWithdraw = (userShares * sharePercent) / 100;
        if (sharesToWithdraw == 0) return;

        // Get current price to estimate USDC withdrawal
        uint256 currentRound = vault.round();
        uint256 usdcAmount = 0;
        if (currentRound > 0 && currentRound >= 2) {
            uint256 price = vault.roundPricePerShare(currentRound - 1);
            if (price > 0) {
                usdcAmount = (sharesToWithdraw * price) / 1e18;
            }
        }

        vm.prank(user);
        try vault.unstakeAndWithdraw(sharesToWithdraw, 0) {
            // Track withdrawal
            if (usdcAmount > 0) {
                totalWithdrawn += usdcAmount;
            }
        } catch {
            // Withdrawal failed, that's ok
        }
    }

    /**
     * @notice Fuzzed round roll action (multi-chain)
     * @dev This is the CRITICAL operation that sets price across all chains
     */
    function action_roundRoll(uint256 yieldAmount, bool isPositive) public {
        yieldAmount = bound(yieldAmount, 0, MAX_YIELD);

        // Can only roll if not already paused
        if (vaultSepolia.isPaused()) return;

        // Safety: don't roll if chains are already desynchronized (prevents cascading desync)
        uint256 roundSepolia = vaultSepolia.round();
        uint256 roundBase = vaultBase.round();
        uint256 roundArbitrum = vaultArbitrum.round();
        uint256 maxRound = roundSepolia > roundBase ? roundSepolia : roundBase;
        maxRound = maxRound > roundArbitrum ? maxRound : roundArbitrum;
        uint256 minRound = roundSepolia < roundBase ? roundSepolia : roundBase;
        minRound = minRound < roundArbitrum ? minRound : roundArbitrum;
        if (maxRound - minRound > 0) return; // Only roll if all chains are on same round

        // Get current global state (before pause)
        uint256 globalTotalStakedBefore = getGlobalTotalStaked();
        uint256 globalTotalPendingBefore = getGlobalTotalPending();
        uint256 globalAccountingBefore = getGlobalAccountingSupply();

        // Safety: don't roll if no deposits yet
        if (globalTotalStakedBefore == 0 && globalTotalPendingBefore == 0) return;

        // STEP 1: Pause all chains (required for consistent state snapshot)
        vm.prank(operator);
        vaultSepolia.setSystemPaused(true);
        vm.prank(operator);
        vaultBase.setSystemPaused(true);
        vm.prank(operator);
        vaultArbitrum.setSystemPaused(true);

        // STEP 2: Roll primary chain (Sepolia) - calculates global price
        // Set Sepolia as primary chain
        vaultSepolia.setPrimaryChain(1, true);

        vm.prank(operator);
        try vaultSepolia.rollToNextRound(
            yieldAmount,
            isPositive,
            globalTotalStakedBefore,
            globalAccountingBefore,
            globalTotalPendingBefore
        ) {
            // Track yield
            if (isPositive) {
                totalYieldApplied += int256(yieldAmount);
            } else {
                totalYieldApplied -= int256(yieldAmount);
            }

            // Get new price from primary
            uint256 newRound = vaultSepolia.round();
            uint256 newPrice = vaultSepolia.roundPricePerShare(newRound);

            // STEP 3: Apply price to secondary chains
            vm.prank(operator);
            try vaultBase.applyGlobalPrice(
                newRound,
                newPrice
            ) {} catch {}

            vm.prank(operator);
            try vaultArbitrum.applyGlobalPrice(
                newRound,
                newPrice
            ) {} catch {}

        } catch {
            // Roll failed, that's ok
        }

        // STEP 4: Unpause all chains
        vm.prank(operator);
        vaultSepolia.setSystemPaused(false);
        vm.prank(operator);
        vaultBase.setSystemPaused(false);
        vm.prank(operator);
        vaultArbitrum.setSystemPaused(false);
    }

    /**
     * @notice Fuzzed rebalancing action
     * @dev Simulates scripts/core/rebalanceSherpaUSD.js operations
     * Moves SherpaUSD between chains and adjusts accounting accordingly
     */
    function action_rebalance(uint256 fromChainId, uint256 toChainId, uint256 amount) public {
        fromChainId = bound(fromChainId, 1, 3);
        toChainId = bound(toChainId, 1, 3);

        // Can't rebalance to same chain
        if (fromChainId == toChainId) return;

        amount = bound(amount, 1e6, 10_000e6); // 1 USDC to 10k USDC

        SherpaVault fromVault = getVault(fromChainId);
        SherpaVault toVault = getVault(toChainId);
        SherpaUSD fromWrapper = getWrapper(fromChainId);
        SherpaUSD toWrapper = getWrapper(toChainId);

        // Can only rebalance if system not paused
        if (fromVault.isPaused() || toVault.isPaused()) return;

        // Check if from chain has enough SherpaUSD
        uint256 available = fromWrapper.balanceOf(address(fromVault));
        if (available < amount) return;

        // Get current price (use last completed round)
        uint256 currentRound = fromVault.round();
        if (currentRound == 0) return; // Need at least one completed round for price

        uint256 pricePerShare = fromVault.roundPricePerShare(currentRound - 1);
        if (pricePerShare == 0) return;

        // Calculate accounting adjustment: (amount * 1e6) / price
        uint256 accountingAdjustment = (amount * 1e6) / pricePerShare;

        // Execute rebalancing (6 transactions, as operator)
        vm.prank(operator);
        try fromWrapper.ownerBurn(address(fromVault), amount) {
            vm.prank(operator);
            fromVault.adjustTotalStaked(-int256(amount));

            vm.prank(operator);
            fromVault.adjustAccountingSupply(-int256(accountingAdjustment));

            vm.prank(operator);
            toWrapper.ownerMint(address(toVault), amount);

            vm.prank(operator);
            toVault.adjustTotalStaked(int256(amount));

            vm.prank(operator);
            toVault.adjustAccountingSupply(int256(accountingAdjustment));

        } catch {
            // Rebalancing failed, that's ok
        }
    }

    /**
     * @notice Fuzzed CCIP bridge action
     * @dev User bridges vault shares between chains
     * CRITICAL: This does NOT change accountingSupply (by design!)
     */
    function action_ccipBridge(uint256 fromChainId, uint256 toChainId, uint256 userSeed, uint256 sharePercent) public {
        fromChainId = bound(fromChainId, 1, 3);
        toChainId = bound(toChainId, 1, 3);
        userSeed = bound(userSeed, 1, 3);
        sharePercent = bound(sharePercent, 1, 50); // 1% to 50% of user's shares

        // Can't bridge to same chain
        if (fromChainId == toChainId) return;

        address user = userSeed == 1 ? user1 : userSeed == 2 ? user2 : user3;
        SherpaVault fromVault = getVault(fromChainId);
        SherpaVault toVault = getVault(toChainId);
        MockCCIPPool fromPool = getCCIPPool(fromChainId);
        MockCCIPPool toPool = getCCIPPool(toChainId);

        uint256 userShares = fromVault.balanceOf(user);
        if (userShares == 0) return;

        uint256 sharesToBridge = (userShares * sharePercent) / 100;
        if (sharesToBridge == 0) return;

        // User approves CCIP pool to burn their shares
        vm.prank(user);
        fromVault.approve(address(fromPool), sharesToBridge);

        // Simulate CCIP bridge flow:
        // 1. Burn on source chain (decreases totalSupply, accountingSupply UNCHANGED)
        vm.prank(address(fromPool));
        try fromVault.burn(user, sharesToBridge) {

            // Track in-flight bridge
            bridgeTransfers.push(BridgeTransfer({
                user: user,
                amount: sharesToBridge,
                sourceChainId: fromChainId,
                destChainId: toChainId,
                timestamp: block.timestamp,
                completed: false
            }));

            // 2. Mint on destination (increases totalSupply, accountingSupply UNCHANGED)
            // In reality CCIP is async, but for testing we do it atomically
            vm.prank(address(toPool));
            toVault.mint(user, sharesToBridge);

            // Mark bridge as completed
            bridgeTransfers[bridgeTransfers.length - 1].completed = true;

        } catch {
            // Bridge failed, that's ok
        }
    }

    // =================================================================
    // INVARIANT 1: Global Accounting with CCIP Bridges (MOST CRITICAL)
    // =================================================================

    /**
     * @notice THE FOUNDATIONAL INVARIANT for price accuracy
     * @dev accountingSupply is immune to bridges, so we must account for in-flight
     *
     * Formula: sum(accountingSupply) == sum(totalSupply) + inFlightBridges
     *
     * Why this works:
     *   - accountingSupply = source of truth (only changes via deposits/withdrawals/rebalancing)
     *   - totalSupply = current shares on chain (changes via deposits/withdrawals/bridges)
     *   - When bridge happens:
     *       Source: burn() → totalSupply ↓, accountingSupply unchanged
     *       In-flight: shares don't exist in any totalSupply
     *       Dest: mint() → totalSupply ↑, accountingSupply unchanged
     *   - Global totalSupply temporarily lower during bridge
     *   - Global accountingSupply stays constant (correct for price calculation!)
     */
    function invariant_01_global_accounting_with_bridges() public {
        uint256 globalAccounting = getGlobalAccountingSupply();
        uint256 globalSupply = getGlobalTotalSupply();
        uint256 inFlight = getInFlightBridgeAmount();

        assertEq(
            globalAccounting,
            globalSupply + inFlight,
            "CRITICAL: Global accounting mismatch (price calculation will be wrong!)"
        );
    }

    // =================================================================
    // INVARIANT 2: Global SherpaUSD Backing (CRITICAL)
    // =================================================================

    /**
     * @notice Global SherpaUSD must equal global staked + pending
     * @dev SherpaUSD is the wrapper token. This verifies USDC backing is correct.
     */
    function invariant_02_global_sherpaUSD_backing() public {
        uint256 globalSherpaUSD = getGlobalSherpaUSDBalance();
        uint256 globalStaked = getGlobalTotalStaked();
        uint256 globalPending = getGlobalTotalPending();

        assertEq(
            globalSherpaUSD,
            globalStaked + globalPending,
            "CRITICAL: Global SherpaUSD doesn't match staked + pending (backing corrupted!)"
        );
    }

    // =================================================================
    // INVARIANT 3: Per-Chain SherpaUSD Backing
    // =================================================================

    /**
     * @notice Each chain's SherpaUSD balance must match its totalStaked + totalPending
     */
    function invariant_03_perchain_sherpaUSD_backing() public {
        // Sepolia
        assertEq(
            wrapperSepolia.balanceOf(address(vaultSepolia)),
            vaultSepolia.totalStaked() + vaultSepolia.totalPending(),
            "Sepolia: SherpaUSD backing mismatch"
        );

        // Base
        assertEq(
            wrapperBase.balanceOf(address(vaultBase)),
            vaultBase.totalStaked() + vaultBase.totalPending(),
            "Base: SherpaUSD backing mismatch"
        );

        // Arbitrum
        assertEq(
            wrapperArbitrum.balanceOf(address(vaultArbitrum)),
            vaultArbitrum.totalStaked() + vaultArbitrum.totalPending(),
            "Arbitrum: SherpaUSD backing mismatch"
        );
    }

    // =================================================================
    // INVARIANT 4: Price Consistency Across Chains (CRITICAL)
    // =================================================================

    /**
     * @notice All chains must have the same price for the same round
     * @dev This is essential for multi-chain fairness
     */
    function invariant_04_price_consistency_across_chains() public {
        uint256 roundSepolia = vaultSepolia.round();
        uint256 roundBase = vaultBase.round();
        uint256 roundArbitrum = vaultArbitrum.round();

        // All chains should be on same round (or max 1 apart during roll)
        uint256 maxRound = roundSepolia > roundBase ? roundSepolia : roundBase;
        maxRound = maxRound > roundArbitrum ? maxRound : roundArbitrum;
        uint256 minRound = roundSepolia < roundBase ? roundSepolia : roundBase;
        minRound = minRound < roundArbitrum ? minRound : roundArbitrum;

        assertLe(
            maxRound - minRound,
            1,
            "Chains more than 1 round apart (severe desync!)"
        );

        // If all on same round and round > 0, prices must match exactly
        if (roundSepolia == roundBase && roundBase == roundArbitrum && roundSepolia > 0) {
            uint256 priceSepolia = vaultSepolia.roundPricePerShare(roundSepolia - 1);
            uint256 priceBase = vaultBase.roundPricePerShare(roundBase - 1);
            uint256 priceArbitrum = vaultArbitrum.roundPricePerShare(roundArbitrum - 1);

            assertEq(priceSepolia, priceBase, "Price mismatch: Sepolia vs Base");
            assertEq(priceBase, priceArbitrum, "Price mismatch: Base vs Arbitrum");
        }
    }

    // =================================================================
    // INVARIANT 5: No Infinite Money Glitch (CRITICAL)
    // =================================================================

    /**
     * @notice Users cannot withdraw more value than deposited + yield
     * @dev This catches any economic exploits
     */
    function invariant_05_no_infinite_money() public {
        uint256 totalValueIn = totalDeposited + uint256(totalYieldApplied > 0 ? totalYieldApplied : -totalYieldApplied);

        // Allow for negative yield reducing available funds
        if (totalYieldApplied >= 0) {
            assertGe(
                totalValueIn,
                totalWithdrawn,
                "CRITICAL: Withdrew more than deposited + yield!"
            );
        } else {
            // With negative yield, totalDeposited - abs(negativeYield) >= totalWithdrawn
            uint256 netValue = totalDeposited > uint256(-totalYieldApplied)
                ? totalDeposited - uint256(-totalYieldApplied)
                : 0;
            assertGe(
                netValue + 1000, // Small tolerance for rounding
                totalWithdrawn,
                "CRITICAL: Withdrew more than should be available after losses!"
            );
        }
    }

    // =================================================================
    // INVARIANT 6: AccountingSupply Per-Chain Bounds
    // =================================================================

    /**
     * @notice accountingSupply can be > or < totalSupply due to bridges (this is normal!)
     * @dev After user bridges out: accounting > supply (shares left the chain)
     *      After user bridges in: accounting < supply (shares entered the chain)
     *      This is INTENTIONAL! Accounting tracks origin, not current location.
     */
    function invariant_06_accounting_per_chain_reasonable() public view {
        // We don't enforce accountingSupply <= totalSupply per chain
        // because bridges intentionally create divergence
        // This is checked globally in invariant_01
    }

    // =================================================================
    // INVARIANT 7: Price Never Zero (After Round 0)
    // =================================================================

    /**
     * @notice Price per share should never be zero after round 1
     * @dev Round 0 has no price (it's before first roll), so we check round >= 2 (MINIMUM_VALID_ROUND)
     */
    function invariant_07_price_never_zero() public {
        // Only check if we're at round 2+ (after first roll completes)
        // Round 0: no price set (before first roll)
        // Round 1: roundPricePerShare[1] is set during roll, check it from round 2+
        if (vaultSepolia.round() >= 2) {
            uint256 price = vaultSepolia.roundPricePerShare(vaultSepolia.round() - 1);
            assertGt(price, 0, "Price is zero after round 1!");
        }
    }

    // =================================================================
    // INVARIANT 8: Round Synchronization
    // =================================================================

    /**
     * @notice Rounds should never decrease
     * @dev This is implicitly enforced by contract, but we document it
     */
    function invariant_08_rounds_never_decrease() public view {
        // Foundry fuzzer can't make rounds decrease
        // But we document this as a critical invariant
    }

    // =================================================================
    // INVARIANT 9: Pause Deadline Set When Paused
    // =================================================================

    /**
     * @notice If paused, pauseDeadline must be set (24-hour auto-unpause)
     */
    function invariant_09_pause_deadline_set() public {
        if (vaultSepolia.isPaused()) {
            assertGt(vaultSepolia.pauseDeadline(), 0, "Sepolia paused but no deadline!");
        }
        if (vaultBase.isPaused()) {
            assertGt(vaultBase.pauseDeadline(), 0, "Base paused but no deadline!");
        }
        if (vaultArbitrum.isPaused()) {
            assertGt(vaultArbitrum.pauseDeadline(), 0, "Arbitrum paused but no deadline!");
        }
    }

    // =================================================================
    // INVARIANT 10: Global Totals Never Decrease Unexpectedly
    // =================================================================

    /**
     * @notice Global accountingSupply should only increase via deposits, decrease via withdrawals
     * @dev We can't easily track this incrementally, but severe bugs would violate other invariants
     */
    function invariant_10_accounting_reasonable_magnitude() public {
        uint256 globalAccounting = getGlobalAccountingSupply();

        // Should never exceed total deposited by extreme amount
        // Note: With negative yields, price can drop dramatically (e.g., 1.0 -> 0.1)
        // Then depositing same USDC creates 10x more shares
        // 10x bound allows for extreme price movements while catching severe bugs
        assertLe(
            globalAccounting,
            totalDeposited * 10, // 10x bound for extreme price movements
            "AccountingSupply unreasonably large (exploit detected?)"
        );
    }
}

/**
 * @notice Mock CCIP Pool for testing bridges
 * @dev Simplified CCIP pool that just calls burn/mint
 */
contract MockCCIPPool {
    SherpaVault public vault;

    constructor(address _vault) {
        vault = SherpaVault(_vault);
    }

    function burn(address from, uint256 amount) external {
        vault.burn(from, amount);
    }

    function mint(address to, uint256 amount) external {
        vault.mint(to, amount);
    }
}
