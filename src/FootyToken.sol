// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
/**
 * @title UtilityToken
 * @dev ERC20 token used for in-game transactions like entry fees, NFT upgrades, and prize pools.
 * Inherits from ERC20Burnable to allow for deflationary mechanisms.
 */
contract UtilityToken is ERC20, ERC20Burnable, Ownable {
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
     * @dev Mints new tokens. Can only be called by the owner (e.g., for rewards or specific game events).
     * Consider making this more restrictive or removing if supply is fixed post-initial mint.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // Ownable's transferOwnership, renounceOwnership are inherited.
    // ERC20Burnable's burn, burnFrom are inherited.
}
