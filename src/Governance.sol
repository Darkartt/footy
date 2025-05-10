// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GovernanceToken
 * @dev ERC20 token used for voting on league rules, fee structures, and other governance proposals.
 * Staking this token can yield returns from match fee revenue.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GovernanceToken is ERC20, Ownable {
    // --- State Variables ---
    // Potentially add staking mechanisms and reward distribution logic here or in a separate StakingContract.

    // --- Constructor ---
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address initialOwner
    ) ERC20(name, symbol) Ownable(initialOwner) {
        _mint(initialOwner, initialSupply * (10**decimals()));
    }

    // --- Functions ---
    /**
     * @dev Mints new tokens. Can only be called by the owner.
     * Typically, governance token supply might be fixed or have a very controlled inflation schedule.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // Future additions:
    // - delegate(address delegatee)
    // - vote(uint proposalId, bool support)
    // - Staking functions: stake(), unstake(), claimRewards()
}

/**
 * @title PlayerNFT
 * @dev ERC721 token representing unique football players with on-chain and off-chain metadata.
 * Supports dynamic evolution based on XP and metadata tiers.
 */
