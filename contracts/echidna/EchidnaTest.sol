// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../SherpaVault.sol";
import "../SherpaUSD.sol";
import "../MockUSDC.sol";
import "../lib/Vault.sol";

/**
 * @title Echidna Test for SherpaVault
 * @notice Tests critical invariants using Echidna fuzzer
 * @dev Functions prefixed with echidna_ return bool (true = pass, false = fail)
 */
contract EchidnaTest {
    // Contracts
    SherpaVault public vaultSepolia;
    SherpaVault public vaultBase;
    SherpaVault public vaultArbitrum;

    SherpaUSD public wrapperSepolia;
    SherpaUSD public wrapperBase;
    SherpaUSD public wrapperArbitrum;

    MockUSDC public usdc;

    // Test actors (Echidna will use sender addresses from config)
    address public operator = address(0x30000);

    // Constants
    uint256 constant MIN_SUPPLY = 1e6;
    uint256 constant CAP = 10_000_000e6;

    constructor() {
        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy wrappers
        wrapperSepolia = new SherpaUSD(address(usdc), address(0xdead));
        wrapperBase = new SherpaUSD(address(usdc), address(0xdead));
        wrapperArbitrum = new SherpaUSD(address(usdc), address(0xdead));

        // Deploy vaults
        vaultSepolia = deploySherpaVault(address(wrapperSepolia), "Sherpa Sepolia", "svSEP");
        vaultBase = deploySherpaVault(address(wrapperBase), "Sherpa Base", "svBASE");
        vaultArbitrum = deploySherpaVault(address(wrapperArbitrum), "Sherpa Arbitrum", "svARB");

        // Set vaults as keepers
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

        // Fund sender addresses with USDC
        usdc.mint(address(0x10000), 1_000_000e6);
        usdc.mint(address(0x20000), 1_000_000e6);
        usdc.mint(address(0x30000), 1_000_000e6);

        // Pre-approve wrappers (for convenience in fuzzing)
        // Note: In real scenarios, users approve before deposit
        usdc.approve(address(wrapperSepolia), type(uint256).max);
        usdc.approve(address(wrapperBase), type(uint256).max);
        usdc.approve(address(wrapperArbitrum), type(uint256).max);
    }

    function deploySherpaVault(address wrapper, string memory name, string memory symbol)
        internal
        returns (SherpaVault)
    {
        Vault.VaultParams memory params = Vault.VaultParams({
            decimals: 18,
            minimumSupply: uint56(MIN_SUPPLY),
            cap: uint104(CAP)
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

    // =================================================================
    // ECHIDNA INVARIANTS (return bool: true = pass, false = fail)
    // =================================================================

    /**
     * @notice CRITICAL: Global accounting must equal global supply
     * @dev This is the foundation of price calculation accuracy
     */
    function echidna_global_accounting_equals_supply() public view returns (bool) {
        uint256 globalAccounting = getGlobalAccountingSupply();
        uint256 globalSupply = getGlobalTotalSupply();

        // In absence of in-flight bridges (which we don't simulate in this simplified test),
        // accounting should equal supply
        return globalAccounting == globalSupply;
    }

    /**
     * @notice CRITICAL: Global SherpaUSD backing
     * @dev SherpaUSD must equal totalStaked + totalPending
     */
    function echidna_global_sherpaUSD_backing() public view returns (bool) {
        uint256 globalSherpaUSD = getGlobalSherpaUSDBalance();
        uint256 globalStaked = getGlobalTotalStaked();
        uint256 globalPending = getGlobalTotalPending();

        return globalSherpaUSD == (globalStaked + globalPending);
    }

    /**
     * @notice Per-chain SherpaUSD backing
     */
    function echidna_perchain_sherpaUSD_backing() public view returns (bool) {
        // Sepolia
        if (wrapperSepolia.balanceOf(address(vaultSepolia)) !=
            vaultSepolia.totalStaked() + vaultSepolia.totalPending()) {
            return false;
        }

        // Base
        if (wrapperBase.balanceOf(address(vaultBase)) !=
            vaultBase.totalStaked() + vaultBase.totalPending()) {
            return false;
        }

        // Arbitrum
        if (wrapperArbitrum.balanceOf(address(vaultArbitrum)) !=
            vaultArbitrum.totalStaked() + vaultArbitrum.totalPending()) {
            return false;
        }

        return true;
    }

    /**
     * @notice Price consistency across chains
     */
    function echidna_price_consistency() public view returns (bool) {
        uint256 roundSepolia = vaultSepolia.round();
        uint256 roundBase = vaultBase.round();
        uint256 roundArbitrum = vaultArbitrum.round();

        // All chains should be on same round (or max 1 apart during roll)
        uint256 maxRound = roundSepolia > roundBase ? roundSepolia : roundBase;
        maxRound = maxRound > roundArbitrum ? maxRound : roundArbitrum;
        uint256 minRound = roundSepolia < roundBase ? roundSepolia : roundBase;
        minRound = minRound < roundArbitrum ? minRound : roundArbitrum;

        if (maxRound - minRound > 1) {
            return false;
        }

        // If all on same round and round > 0, prices must match
        if (roundSepolia == roundBase && roundBase == roundArbitrum && roundSepolia > 0) {
            uint256 priceSepolia = vaultSepolia.roundPricePerShare(roundSepolia - 1);
            uint256 priceBase = vaultBase.roundPricePerShare(roundBase - 1);
            uint256 priceArbitrum = vaultArbitrum.roundPricePerShare(roundArbitrum - 1);

            if (priceSepolia != priceBase || priceBase != priceArbitrum) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Price never zero after round 2
     */
    function echidna_price_never_zero() public view returns (bool) {
        // Only check if we're at round 2+ (MINIMUM_VALID_ROUND)
        if (vaultSepolia.round() >= 2) {
            uint256 price = vaultSepolia.roundPricePerShare(vaultSepolia.round() - 1);
            if (price == 0) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Pause deadline must be set when paused
     */
    function echidna_pause_deadline_set() public view returns (bool) {
        if (vaultSepolia.isPaused() && vaultSepolia.pauseDeadline() == 0) {
            return false;
        }
        if (vaultBase.isPaused() && vaultBase.pauseDeadline() == 0) {
            return false;
        }
        if (vaultArbitrum.isPaused() && vaultArbitrum.pauseDeadline() == 0) {
            return false;
        }

        return true;
    }

    /**
     * @notice NEW: Epoch never ahead of round
     * @dev This is one of the HIGH priority missing invariants
     */
    function echidna_epoch_never_ahead_of_round() public view returns (bool) {
        if (wrapperSepolia.currentEpoch() > vaultSepolia.round()) {
            return false;
        }
        if (wrapperBase.currentEpoch() > vaultBase.round()) {
            return false;
        }
        if (wrapperArbitrum.currentEpoch() > vaultArbitrum.round()) {
            return false;
        }

        return true;
    }

    /**
     * @notice Accounting supply reasonable magnitude
     * @dev Should never be wildly larger than total deposits
     */
    function echidna_accounting_reasonable() public view returns (bool) {
        uint256 globalAccounting = getGlobalAccountingSupply();

        // Get total USDC minted to all users
        uint256 totalUSDCMinted = usdc.totalSupply();

        // Accounting should never exceed total USDC that could possibly be deposited
        // Allow 10x margin for extreme price movements
        return globalAccounting <= totalUSDCMinted * 10;
    }
}
