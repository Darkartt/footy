// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract PlayerNFT is ERC721, ERC721URIStorage, ERC721Burnable, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

    // --- Structs ---
    enum MetadataTier { Bronze, Silver, Gold, Legendary, Mythic } // Added Bronze and Mythic for more levels

    struct PlayerAttributes {
        uint8 attack;       // 0-255, represents shooting, dribbling etc.
        uint8 defense;      // 0-255, represents tackling, positioning etc.
        uint8 stamina;      // 0-255, endurance
        uint8 positionalSpecialization; // Could be an enum or category ID
        uint8 age;          // Player's age
        uint8 form;         // 0-100
        uint8 morale;       // 0-100
        uint64 xp;          // Experience points
        MetadataTier tier;  // Current metadata tier
        string customData;  // For other flexible data, e.g., visual traits
    }

    // --- Mappings ---
    mapping(uint256 => PlayerAttributes) private _playerAttributes;
    mapping(MetadataTier => uint64) public xpThresholds; // XP needed to reach a tier

    // --- Events ---
    event PlayerMinted(uint256 indexed tokenId, address indexed owner, PlayerAttributes attributes);
    event PlayerXPUpdated(uint256 indexed tokenId, uint64 newXP, uint64 oldXP);
    event PlayerTierUpgraded(uint256 indexed tokenId, MetadataTier newTier, MetadataTier oldTier);
    event PlayerAttributesUpgraded(uint256 indexed tokenId); // For specific stat boosts

    // --- Constructor ---
    constructor(
        string memory name,
        string memory symbol,
        address initialOwner
    ) ERC721(name, symbol) Ownable(initialOwner) {
        // Initialize XP thresholds for tier upgrades
        xpThresholds[MetadataTier.Bronze] = 0; // Base tier
        xpThresholds[MetadataTier.Silver] = 1000;
        xpThresholds[MetadataTier.Gold] = 5000;
        xpThresholds[MetadataTier.Legendary] = 20000;
        xpThresholds[MetadataTier.Mythic] = 100000;
    }

    // --- URI Storage ---
    /**
     * @dev Base URI for computing token URI. Ends with a '/'.
     * Example: "https://api.mygame.com/nfts/"
     * The final URI will be baseURI + tokenId + ".json"
     */
    string private _baseTokenURI;

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @dev Sets the base URI for all token IDs.
     * @param baseURI_ The new base URI.
     */
    function setBaseURI(string memory baseURI_) public onlyOwner {
        _baseTokenURI = baseURI_;
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     * Overridden to use ERC721URIStorage's _setTokenURI if a specific URI is set,
     * otherwise constructs it from _baseURI and tokenId.
     */
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        _requireOwned(tokenId); // or _requireMinted for ERC721 v5.0
        string memory currentTokenURI = ERC721URIStorage.tokenURI(tokenId);

        if (bytes(currentTokenURI).length > 0) {
            return currentTokenURI;
        }
        // If no specific URI is set, construct it from the base URI
        if (bytes(_baseTokenURI).length == 0) {
            return ""; // Or revert if base URI must be set
        }
        return string(abi.encodePacked(_baseTokenURI, Strings.toString(tokenId), ".json"));
    }

    // --- Minting ---
    /**
     * @dev Mints a new player NFT with specified attributes.
     * Only callable by the owner (e.g., game administrator or via a minting contract).
     */
    function safeMint(address to, PlayerAttributes memory attributes, string memory uri) public onlyOwner returns (uint256) {
        uint256 tokenId = _tokenIdCounter.current();
        _safeMint(to, tokenId);
        if (bytes(uri).length > 0) {
            _setTokenURI(tokenId, uri); // For individual, pre-generated metadata JSONs
        }
        _playerAttributes[tokenId] = attributes;
        _playerAttributes[tokenId].tier = MetadataTier.Bronze; // Start at Bronze or determine by initial XP

        _tokenIdCounter.increment();
        emit PlayerMinted(tokenId, to, attributes);
        return tokenId;
    }

    // --- Player Evolution ---
    /**
     * @dev Adds XP to a player. Can only be called by an authorized address (e.g., a match contract).
     * This function should check for tier upgrades.
     * The formula from the doc: XP_gain = (Goals * 100 + Passes * 2) / StaminaUsed
     * This implies StaminaUsed cannot be 0. The caller (match contract) should ensure this.
     */
    function addXP(uint256 tokenId, uint64 xpGained) public onlyOwner { // Consider a specific role instead of just onlyOwner
        _requireOwned(tokenId); // or _requireMinted
        PlayerAttributes storage player = _playerAttributes[tokenId];
        uint64 oldXP = player.xp;
        player.xp += xpGained;
        emit PlayerXPUpdated(tokenId, player.xp, oldXP);

        _checkAndUpgradeTier(tokenId, player);
    }

    /**
     * @dev Internal function to check and upgrade player tier based on XP.
     */
    function _checkAndUpgradeTier(uint256 tokenId, PlayerAttributes storage player) internal {
        MetadataTier oldTier = player.tier;
        MetadataTier newTier = player.tier; // Start with current tier

        // Iterate upwards to find the highest achievable tier
        if (player.tier < MetadataTier.Mythic && player.xp >= xpThresholds[MetadataTier.Mythic]) {
            newTier = MetadataTier.Mythic;
        } else if (player.tier < MetadataTier.Legendary && player.xp >= xpThresholds[MetadataTier.Legendary]) {
            newTier = MetadataTier.Legendary;
        } else if (player.tier < MetadataTier.Gold && player.xp >= xpThresholds[MetadataTier.Gold]) {
            newTier = MetadataTier.Gold;
        } else if (player.tier < MetadataTier.Silver && player.xp >= xpThresholds[MetadataTier.Silver]) {
            newTier = MetadataTier.Silver;
        }
        // Bronze is the base, no check needed for it as an upgrade target

        if (newTier != oldTier) {
            player.tier = newTier;
            emit PlayerTierUpgraded(tokenId, newTier, oldTier);
            // Potentially update metadata URI or trigger an event for off-chain metadata update
            // For on-chain attributes, the tier change itself is the update.
        }
    }

    /**
     * @dev Upgrades a specific attribute of a player (e.g., stamina boost).
     * This would typically be called after a payment in UtilityToken to a separate contract.
     * For simplicity, making it onlyOwner here.
     */
    function upgradeAttribute(uint256 tokenId, uint8 newStamina, uint8 newAttack, uint8 newDefense) public onlyOwner {
        _requireOwned(tokenId); // or _requireMinted
        PlayerAttributes storage player = _playerAttributes[tokenId];
        
        // Add validation: new stats should generally be better or within limits
        if (newStamina > player.stamina) player.stamina = newStamina; // Example: only allow increase
        if (newAttack > player.attack) player.attack = newAttack;
        if (newDefense > player.defense) player.defense = newDefense;

        // Ensure stats don't exceed max values (e.g., 255 for uint8)
        // player.stamina = newStamina > 255 ? 255 : newStamina; // More robust way

        emit PlayerAttributesUpgraded(tokenId);
    }

    // --- Getters ---
    function getPlayerAttributes(uint256 tokenId) public view returns (PlayerAttributes memory) {
        _requireOwned(tokenId); // or _requireMinted
        return _playerAttributes[tokenId];
    }

    function getPlayerTier(uint256 tokenId) public view returns (MetadataTier) {
        _requireOwned(tokenId); // or _requireMinted
        return _playerAttributes[tokenId].tier;
    }

    // --- ERC721URIStorage Overrides ---
    /**
     * @dev See {IERC721URIStorage-setTokenURI}.
     * Only callable by the owner.
     */
    function setTokenURI(uint256 tokenId, string memory _tokenURI) public onlyOwner {
        _requireOwned(tokenId); // or _requireMinted
        ERC721URIStorage._setTokenURI(tokenId, _tokenURI);
    }
    
    // --- ERC721 Overrides ---
    // The following functions are overrides required by Solidity.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 amount)
        internal
        override(ERC721)
    {
        super._increaseBalance(account, amount);
    }

    // --- ERC721URIStorage Overrides for Solidity 0.8.20+ ---
    // ERC721URIStorage's _setTokenURI and tokenURI are already handled.
    // ERC721's _burn is inherited from ERC721Burnable.

    // --- Ownable ---
    // transferOwnership and renounceOwnership are inherited.

    // --- Supports Interface ---
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

/**
 * @title Tournament
 * @dev Manages tournament entries, prize distribution, and interactions with other game contracts.
 * This is an expanded version of the contract snippet from the document.
 */
