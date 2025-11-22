// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing with 1B supply
 * @dev Deployed on each testnet chain with full supply minted to deployer
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        // Mint 1 billion USDC (with 6 decimals)
        _mint(msg.sender, 1_000_000_000 * 10**6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Allow anyone to mint for testing (remove in production!)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
