// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PlayerNFT.sol"; // Assuming PlayerNFT.sol is in the same directory or path is configured
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";

/**
 * @title MatchContract
 * @dev Simulates football matches using player NFT attributes and Chainlink VRF for randomness.
 * Awards XP to players based on match performance.
 *
 * ---- Game Logic Overview from Document ----
 * 1. Player Attributes: Attack, Defense, Stamina, Age, Form, Morale from PlayerNFT.
 * 2. Team Strength: Weighted sum of player stats.
 * - Tactical Modifiers: e.g., Aggressive (+10% attack, -15% defense).
 * - Environmental Factors: Home team +5% boost. Weather (simplified). Referee strictness.
 * 3. Match State: Momentum shifts, critical events (shot, foul).
 * - Base Momentum Shift: (HomeAttack - AwayDefense) * Random(0.8–1.2). (Simplified for event-based)
 * - Critical Event Check: Weighted random roll (e.g., Shot 22%, Foul 15%).
 * 4. Goal Prediction (Poisson-based):
 * - Lambda (Expected Goals): HomeAttack * StyleModifier / (AwayDefense + RefereeStrictness) * Random(0.9–1.1).
 * - Post-shot: Accuracy (60% on, 30% off, 10% wood), GK Save (GKSkill * (1-StaminaPenalty)).
 * 5. XP Gain: (Goals * 100 + Passes * 2) / StaminaUsed. (Simplified for on-chain)
 *
 * ---- On-Chain Simplifications ----
 * - Match simulated in segments/events rather than minute-by-minute.
 * - Detailed passing/stamina tracking for XP is abstracted. XP based on participation, goals, win.
 * - Poisson distribution for goals simplified to probability buckets based on Lambda.
 * - Tactical/Environmental factors applied as modifiers to core stats.
 */
contract MatchContract is Ownable, VRFConsumerBaseV2, ReentrancyGuard {
    // --- Interfaces ---
    PlayerNFT public playerNFTContract;
    VRFCoordinatorV2Interface internal COORDINATOR;

    // --- Chainlink VRF Variables ---
    uint64 private s_subscriptionId;
    bytes32 private s_keyHash; // Gas lane
    uint32 private constant CALLBACK_GAS_LIMIT = 2500000; // Adjust as needed
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // Min blocks for VRF response
    uint32 private constant NUM_WORDS_PER_SEGMENT = 7; // Number of random words for one match segment simulation
                                                      // Word 0: Momentum/Dominance factor
                                                      // Word 1: Critical Event Type
                                                      // Word 2: Lambda calculation random factor
                                                      // Word 3: Goal count determination (from Lambda)
                                                      // Word 4: Shot accuracy / Outcome
                                                      // Word 5: Goalkeeper reaction / Goal confirmation
                                                      // Word 6: Scorer/Assist determination (simplified)

    // --- Match Configuration ---
    uint8 public constant MAX_PLAYERS_PER_TEAM = 11;
    uint8 public constant MATCH_SEGMENTS = 10; // e.g., 5 segments per half, total 10 "key action" phases

    // --- Structs ---
    struct PlayerInMatch {
        uint256 nftId;
        address owner;
        PlayerNFT.PlayerAttributes attributes; // Snapshot at match start
        uint8 goalsScored;
        // Add more per-match stats if needed (e.g., cards, stamina used if modeled)
    }

    enum MatchStatus { Pending, Setup, Active, Cooldown, Concluded, Failed }
    enum TeamType { Home, Away }

    struct TeamDetails {
        PlayerInMatch[] players;
        uint8 tacticalStyle; // 0: Balanced, 1: Aggressive (e.g. 80), 2: Defensive (e.g. 20)
        uint16 currentAttackPower; // Calculated dynamically
        uint16 currentDefensePower; // Calculated dynamically
        uint8 score;
    }

    struct Match {
        uint256 matchId;
        MatchStatus status;
        TeamDetails homeTeam;
        TeamDetails awayTeam;
        uint8 currentSegment;
        uint256 lastVrfRequestId;
        address initiator; // Who started the match
        uint256 startTime;
        // For referee strictness, weather - can be set at match creation or randomized
        uint8 refereeStrictnessFactor; // e.g., 0-10, higher is stricter
        // Weather could be an enum: Sunny, Rainy. Rainy might give -20% to "action quality"
    }

    // --- State Variables ---
    mapping(uint256 => Match) public matches; // matchId => Match
    uint256 public nextMatchId;

    // For linking VRF requests back to matches and segments
    mapping(uint256 => uint256) public vrfRequestToMatchId; // requestId => matchId

    // --- Constants for Game Logic ---
    // Tactical Modifiers (as percentages)
    uint8 private constant AGGRESSIVE_ATTACK_BOOST = 10; // +10%
    uint8 private constant AGGRESSIVE_DEFENSE_PENALTY = 15; // -15%
    uint8 private constant DEFENSIVE_DEFENSE_BOOST = 10;
    uint8 private constant DEFENSIVE_ATTACK_PENALTY = 15;
    uint8 private constant HOME_TEAM_BOOST_PERCENT = 5; // +5% overall boost

    // Event Weights (total 1000 for easier percentage mapping)
    uint16 private constant EVENT_WEIGHT_SHOT = 350; // 35%
    uint16 private constant EVENT_WEIGHT_FOUL = 200; // 20%
    uint16 private constant EVENT_WEIGHT_POSSESSION_CHANGE = 300; // 30%
    uint16 private constant EVENT_WEIGHT_CORNER = 150; // 15%
    uint16 private constant TOTAL_EVENT_WEIGHT = EVENT_WEIGHT_SHOT + EVENT_WEIGHT_FOUL + EVENT_WEIGHT_POSSESSION_CHANGE + EVENT_WEIGHT_CORNER;

    // XP Constants (Simplified)
    uint64 private constant XP_PER_SEGMENT_PLAYED = 10;
    uint64 private constant XP_PER_GOAL_SCORED = 100;
    uint64 private constant XP_FOR_WINNING_TEAM_PLAYER = 50;
    uint64 private constant XP_FOR_DRAW_TEAM_PLAYER = 20;

    // --- Events ---
    event MatchCreated(uint256 indexed matchId, address indexed initiator, uint256[] homePlayerNftIds, uint256[] awayPlayerNftIds);
    event MatchSegmentSimulating(uint256 indexed matchId, uint8 segmentNumber, uint256 indexed vrfRequestId);
    event GoalScoredEvent(uint256 indexed matchId, TeamType scoringTeam, uint8 newHomeScore, uint8 newAwayScore, uint256 scorerNftId);
    event MatchConcluded(uint256 indexed matchId, uint8 homeScore, uint8 awayScore, TeamType winner);
    event XPAwarded(uint256 indexed matchId, uint256 indexed playerNftId, uint64 xpGained);
    event VRFRequestFailed(uint256 indexed matchId, uint256 indexed vrfRequestId);


    // --- Constructor ---
    constructor(
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        address _playerNFTContractAddress,
        address _initialOwner
    ) VRFConsumerBaseV2(_vrfCoordinator) Ownable(_initialOwner) {
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
        playerNFTContract = PlayerNFT(_playerNFTContractAddress);
        nextMatchId = 1;
    }

    // --- Match Lifecycle ---

    /**
     * @dev Initiates a new match.
     * @param _homePlayerNftIds Array of NFT IDs for the home team.
     * @param _awayPlayerNftIds Array of NFT IDs for the away team.
     * @param _homeTacticalStyle Tactical style for home team (0: Bal, 1: Agg, 2: Def).
     * @param _awayTacticalStyle Tactical style for away team.
     * @param _refereeStrictnessFactor Referee strictness (0-10).
     */
    function createMatch(
        uint256[] memory _homePlayerNftIds,
        uint256[] memory _awayPlayerNftIds,
        uint8 _homeTacticalStyle,
        uint8 _awayTacticalStyle,
        uint8 _refereeStrictnessFactor
    ) public onlyOwner nonReentrant returns (uint256) { // Consider allowing users to initiate if they own all NFTs
        require(_homePlayerNftIds.length > 0 && _homePlayerNftIds.length <= MAX_PLAYERS_PER_TEAM, "Invalid home team size");
        require(_awayPlayerNftIds.length > 0 && _awayPlayerNftIds.length <= MAX_PLAYERS_PER_TEAM, "Invalid away team size");
        require(_homeTacticalStyle <= 2, "Invalid home tactics");
        require(_awayTacticalStyle <= 2, "Invalid away tactics");

        uint256 matchId = nextMatchId++;
        Match storage newMatch = matches[matchId];
        newMatch.matchId = matchId;
        newMatch.status = MatchStatus.Setup;
        newMatch.initiator = msg.sender;
        newMatch.startTime = block.timestamp;
        newMatch.refereeStrictnessFactor = _refereeStrictnessFactor;

        // Populate Home Team
        newMatch.homeTeam.tacticalStyle = _homeTacticalStyle;
        for (uint i = 0; i < _homePlayerNftIds.length; i++) {
            uint256 nftId = _homePlayerNftIds[i];
            // In a real scenario, verify msg.sender's authority or NFT ownership if not onlyOwner
            require(playerNFTContract.ownerOf(nftId) != address(0), "Home NFT not found or burned"); // Basic check
            newMatch.homeTeam.players.push(PlayerInMatch({
                nftId: nftId,
                owner: playerNFTContract.ownerOf(nftId),
                attributes: playerNFTContract.getPlayerAttributes(nftId), // Snapshot attributes
                goalsScored: 0
            }));
        }

        // Populate Away Team
        newMatch.awayTeam.tacticalStyle = _awayTacticalStyle;
        for (uint i = 0; i < _awayPlayerNftIds.length; i++) {
            uint256 nftId = _awayPlayerNftIds[i];
            require(playerNFTContract.ownerOf(nftId) != address(0), "Away NFT not found or burned");
            newMatch.awayTeam.players.push(PlayerInMatch({
                nftId: nftId,
                owner: playerNFTContract.ownerOf(nftId),
                attributes: playerNFTContract.getPlayerAttributes(nftId),
                goalsScored: 0
            }));
        }
        
        // Initial calculation of team powers (can be done before each segment too)
        _calculateTeamPowers(matchId);

        emit MatchCreated(matchId, msg.sender, _homePlayerNftIds, _awayPlayerNftIds);

        // Request VRF for the first segment
        _requestRandomWordsForSegment(matchId);
        return matchId;
    }

    function _requestRandomWordsForSegment(uint256 _matchId) internal {
        Match storage currentMatch = matches[_matchId];
        require(currentMatch.status == MatchStatus.Setup || currentMatch.status == MatchStatus.Active, "Match not in correct state");
        require(currentMatch.currentSegment < MATCH_SEGMENTS, "All segments simulated");

        currentMatch.status = MatchStatus.Active; // Mark as active if it was in setup

        uint256 vrfRequestId = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS_PER_SEGMENT
        );
        currentMatch.lastVrfRequestId = vrfRequestId;
        vrfRequestToMatchId[vrfRequestId] = _matchId;

        emit MatchSegmentSimulating(_matchId, currentMatch.currentSegment, vrfRequestId);
    }

    /**
     * @dev Callback function for Chainlink VRF.
     */
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override nonReentrant {
        uint256 matchId = vrfRequestToMatchId[_requestId];
        require(matchId != 0, "Invalid VRF request ID");
        // Remove mapping to prevent re-entrancy on this requestId
        delete vrfRequestToMatchId[_requestId];


        Match storage currentMatch = matches[matchId];
        require(currentMatch.lastVrfRequestId == _requestId, "Mismatched VRF request ID");
        require(currentMatch.status == MatchStatus.Active, "Match not active");

        // --- Simulate One Match Segment ---
        _simulateSegment(matchId, _randomWords);

        currentMatch.currentSegment++;

        if (currentMatch.currentSegment >= MATCH_SEGMENTS) {
            // All segments done, conclude match
            _concludeMatch(matchId);
        } else {
            // Request VRF for the next segment
            // Add a cooldown or check if owner wants to trigger next to manage gas
            currentMatch.status = MatchStatus.Cooldown; // Optional: allow manual trigger for next segment
            // For auto-progression:
            _requestRandomWordsForSegment(matchId);
        }
    }
    
    // Manual trigger for next segment if Cooldown state is used
    function triggerNextSegment(uint256 _matchId) public onlyOwner { // Or match participants
        Match storage currentMatch = matches[_matchId];
        require(currentMatch.status == MatchStatus.Cooldown, "Not in cooldown");
        _requestRandomWordsForSegment(_matchId);
    }


    // --- Simulation Logic ---
    function _calculateTeamPowers(uint256 _matchId) internal {
        Match storage currentMatch = matches[_matchId];

        // Home Team
        uint256 totalHomeAttack = 0;
        uint256 totalHomeDefense = 0;
        for (uint i = 0; i < currentMatch.homeTeam.players.length; i++) {
            PlayerNFT.PlayerAttributes memory pAttr = currentMatch.homeTeam.players[i].attributes;
            // Apply form/morale modifiers (simplified: form 0-100 -> -25% to +25% effect)
            int16 formEffect = int16(pAttr.form) - 50; // -50 to +50
            totalHomeAttack += (pAttr.attack * (1000 + int256(formEffect) * 5)) / 1000; // formEffect * 0.5%
            totalHomeDefense += (pAttr.defense * (1000 + int256(formEffect) * 5)) / 1000;
        }
        // Apply tactical modifiers
        if (currentMatch.homeTeam.tacticalStyle == 1) { // Aggressive
            totalHomeAttack = (totalHomeAttack * (100 + AGGRESSIVE_ATTACK_BOOST)) / 100;
            totalHomeDefense = (totalHomeDefense * (100 - AGGRESSIVE_DEFENSE_PENALTY)) / 100;
        } else if (currentMatch.homeTeam.tacticalStyle == 2) { // Defensive
            totalHomeAttack = (totalHomeAttack * (100 - DEFENSIVE_ATTACK_PENALTY)) / 100;
            totalHomeDefense = (totalHomeDefense * (100 + DEFENSIVE_DEFENSE_BOOST)) / 100;
        }
        // Apply home team boost
        totalHomeAttack = (totalHomeAttack * (100 + HOME_TEAM_BOOST_PERCENT)) / 100;
        totalHomeDefense = (totalHomeDefense * (100 + HOME_TEAM_BOOST_PERCENT)) / 100;
        
        currentMatch.homeTeam.currentAttackPower = uint16(totalHomeAttack / currentMatch.homeTeam.players.length); // Average
        currentMatch.homeTeam.currentDefensePower = uint16(totalHomeDefense / currentMatch.homeTeam.players.length);


        // Away Team (similar logic, no home boost)
        uint256 totalAwayAttack = 0;
        uint256 totalAwayDefense = 0;
        for (uint i = 0; i < currentMatch.awayTeam.players.length; i++) {
            PlayerNFT.PlayerAttributes memory pAttr = currentMatch.awayTeam.players[i].attributes;
            int16 formEffect = int16(pAttr.form) - 50;
            totalAwayAttack += (pAttr.attack * (1000 + int256(formEffect) * 5)) / 1000;
            totalAwayDefense += (pAttr.defense * (1000 + int256(formEffect) * 5)) / 1000;
        }
        if (currentMatch.awayTeam.tacticalStyle == 1) { // Aggressive
            totalAwayAttack = (totalAwayAttack * (100 + AGGRESSIVE_ATTACK_BOOST)) / 100;
            totalAwayDefense = (totalAwayDefense * (100 - AGGRESSIVE_DEFENSE_PENALTY)) / 100;
        } else if (currentMatch.awayTeam.tacticalStyle == 2) { // Defensive
            totalAwayAttack = (totalAwayAttack * (100 - DEFENSIVE_ATTACK_PENALTY)) / 100;
            totalAwayDefense = (totalAwayDefense * (100 + DEFENSIVE_DEFENSE_BOOST)) / 100;
        }
        currentMatch.awayTeam.currentAttackPower = uint16(totalAwayAttack / currentMatch.awayTeam.players.length);
        currentMatch.awayTeam.currentDefensePower = uint16(totalAwayDefense / currentMatch.awayTeam.players.length);
    }


    function _simulateSegment(uint256 _matchId, uint256[] memory _randomWords) internal {
        Match storage currentMatch = matches[_matchId];
        _calculateTeamPowers(_matchId); // Recalculate powers considering potential dynamic factors if added

        // Determine dominant team for this segment (simplified momentum)
        // Word 0: Momentum/Dominance factor (0-99)
        uint256 momentumRoll = _randomWords[0] % 100;
        int256 attackDifference = int256(currentMatch.homeTeam.currentAttackPower) - int256(currentMatch.awayTeam.currentDefensePower);
        int256 defenseDifference = int256(currentMatch.awayTeam.currentAttackPower) - int256(currentMatch.homeTeam.currentDefensePower);
        
        TeamType attackingTeamThisSegment;
        TeamType defendingTeamThisSegment;

        // Simplified: if home attack > away defense significantly, home more likely to dominate.
        // A more nuanced approach could use relative strengths.
        // (HomeAttack - AwayDefense) vs (AwayAttack - HomeDefense)
        // Example: 50 + (attackDiff / 10) - (defenseDiff / 10) -> gives a value around 50. If > 50, home dominates.
        int256 homeAdvantageScore = 50 + (attackDifference / 5) - (defenseDifference / 5); // Scaled
        if (homeAdvantageScore < 0) homeAdvantageScore = 0;
        if (homeAdvantageScore > 100) homeAdvantageScore = 100;

        if (momentumRoll < uint256(homeAdvantageScore)) {
            attackingTeamThisSegment = TeamType.Home;
            defendingTeamThisSegment = TeamType.Away;
        } else {
            attackingTeamThisSegment = TeamType.Away;
            defendingTeamThisSegment = TeamType.Home;
        }

        // Word 1: Critical Event Type (0 to TOTAL_EVENT_WEIGHT - 1)
        uint256 eventRoll = _randomWords[1] % TOTAL_EVENT_WEIGHT;
        bool shotAttempted = false;

        if (eventRoll < EVENT_WEIGHT_SHOT) { // Shot
            shotAttempted = true;
        } else if (eventRoll < EVENT_WEIGHT_SHOT + EVENT_WEIGHT_FOUL) { // Foul
            // Simple: Foul occurs, maybe increases referee strictness impact for next segment or small chance of card (too complex for now)
            // Reduce attacking team's morale slightly, or defending team's if penalty.
        } else if (eventRoll < EVENT_WEIGHT_SHOT + EVENT_WEIGHT_FOUL + EVENT_WEIGHT_POSSESSION_CHANGE) { // Possession Change
            // Attacking team loses ball, no shot.
        } else { // Corner
            // Treat as a higher chance shot for the attacking team.
            shotAttempted = true; // For simplicity, a corner leads to a shot attempt scenario
        }

        if (shotAttempted) {
            uint16 attackerEffectiveAttack = (attackingTeamThisSegment == TeamType.Home) ? currentMatch.homeTeam.currentAttackPower : currentMatch.awayTeam.currentAttackPower;
            uint16 defenderEffectiveDefense = (defendingTeamThisSegment == TeamType.Home) ? currentMatch.homeTeam.currentDefensePower : currentMatch.awayTeam.currentDefensePower;
            
            // Word 2: Lambda random factor (0-19, for 0.9 to 1.1, scaled by 1000)
            uint256 lambdaRandomFactor = 900 + (_randomWords[2] % 201); // Results in 900 to 1100

            // Lambda (Expected Goals for this one shot event - simplified from per-minute)
            // Base Lambda: AttackerAttack / (DefenderDefense + RefereeMod)
            // RefereeStrictnessFactor 0-10. Let's say each point adds 5 to effective defense.
            uint256 effectiveDefenderStat = defenderEffectiveDefense + (currentMatch.refereeStrictnessFactor * 5);
            if (effectiveDefenderStat == 0) effectiveDefenderStat = 1; // Avoid division by zero

            // Lambda calculation: (Attack * StyleMod (implicit in AttackPower) * RandomFactor) / (Defense + Referee)
            // Simplified: Base chance of scoring from a shot event.
            // Let's use a base 30% chance, modified by attack/defense difference and random factor.
            int256 baseShotSuccessRate = 300; // 30.0% (scaled by 10)
            int256 attackAdvantage = int256(attackerEffectiveAttack) - int256(effectiveDefenderStat);
            baseShotSuccessRate += (attackAdvantage / 2); // Each point of net attack adds 0.1% to success
            baseShotSuccessRate = (int256(baseShotSuccessRate) * int256(lambdaRandomFactor)) / 1000;

            if (baseShotSuccessRate < 50) baseShotSuccessRate = 50; // Min 5% chance
            if (baseShotSuccessRate > 700) baseShotSuccessRate = 700; // Max 70% chance

            // Word 3: Goal outcome based on success rate (0-999)
            uint256 goalRoll = _randomWords[3] % 1000;

            if (goalRoll < uint256(baseShotSuccessRate)) { // Potential Goal! Now check accuracy/GK
                // Word 4: Shot accuracy (0-99)
                // 60% on target, 30% off, 10% woodwork
                uint256 accuracyRoll = _randomWords[4] % 100;
                bool onTarget = false;
                if (accuracyRoll < 60) { // On target
                    onTarget = true;
                } else if (accuracyRoll < 90) { // Off target
                    // No goal
                } else { // Woodwork
                    // No goal
                }

                if (onTarget) {
                    // Goalkeeper reaction
                    // GKSkill (use defender's defense stat as proxy) * (1 - StaminaPenalty (simplified as fixed factor for now))
                    // Save probability = GKSkill (0-255) / 3 (max ~85%)
                    uint16 gkSkill = defenderEffectiveDefense; // Using team defense as proxy for GK
                    uint256 saveProb = (uint256(gkSkill) * 100) / 300; // Scaled by 100, max ~85%
                    if (saveProb > 85) saveProb = 85; // Cap save probability

                    // Word 5: Goalkeeper save roll (0-99)
                    uint256 saveRoll = _randomWords[5] % 100;

                    if (saveRoll >= saveProb) { // GOAL!
                        uint256 scorerNftId = 0;
                        if (attackingTeamThisSegment == TeamType.Home) {
                            currentMatch.homeTeam.score++;
                            // Word 6: Select scorer (0 to team_size - 1)
                            uint256 scorerIndex = _randomWords[6] % currentMatch.homeTeam.players.length;
                            currentMatch.homeTeam.players[scorerIndex].goalsScored++;
                            scorerNftId = currentMatch.homeTeam.players[scorerIndex].nftId;
                        } else {
                            currentMatch.awayTeam.score++;
                            uint256 scorerIndex = _randomWords[6] % currentMatch.awayTeam.players.length;
                            currentMatch.awayTeam.players[scorerIndex].goalsScored++;
                            scorerNftId = currentMatch.awayTeam.players[scorerIndex].nftId;
                        }
                        emit GoalScoredEvent(_matchId, attackingTeamThisSegment, currentMatch.homeTeam.score, currentMatch.awayTeam.score, scorerNftId);
                    }
                }
            }
        }
        // End of segment simulation logic
    }

    function _concludeMatch(uint256 _matchId) internal {
        Match storage currentMatch = matches[_matchId];
        require(currentMatch.status == MatchStatus.Active || currentMatch.status == MatchStatus.Cooldown, "Match not active/cooldown");
        currentMatch.status = MatchStatus.Concluded;

        TeamType winner;
        if (currentMatch.homeTeam.score > currentMatch.awayTeam.score) {
            winner = TeamType.Home;
        } else if (currentMatch.awayTeam.score > currentMatch.homeTeam.score) {
            winner = TeamType.Away;
        } else {
            winner = TeamType.Home; // Draw, but need to assign something; or add a Draw TeamType
        }
        // For XP, a Draw type is better. Let's refine winner determination for XP.
        bool isDraw = currentMatch.homeTeam.score == currentMatch.awayTeam.score;

        emit MatchConcluded(_matchId, currentMatch.homeTeam.score, currentMatch.awayTeam.score, winner);

        // Award XP
        // Home Team Players
        for (uint i = 0; i < currentMatch.homeTeam.players.length; i++) {
            PlayerInMatch storage p = currentMatch.homeTeam.players[i];
            uint64 xpGained = MATCH_SEGMENTS * XP_PER_SEGMENT_PLAYED; // Participation
            xpGained += p.goalsScored * XP_PER_GOAL_SCORED;
            if (isDraw) {
                xpGained += XP_FOR_DRAW_TEAM_PLAYER;
            } else if (winner == TeamType.Home) {
                xpGained += XP_FOR_WINNING_TEAM_PLAYER;
            }
            if (xpGained > 0) {
                playerNFTContract.addXP(p.nftId, xpGained);
                emit XPAwarded(_matchId, p.nftId, xpGained);
            }
        }
        // Away Team Players
        for (uint i = 0; i < currentMatch.awayTeam.players.length; i++) {
            PlayerInMatch storage p = currentMatch.awayTeam.players[i];
            uint64 xpGained = MATCH_SEGMENTS * XP_PER_SEGMENT_PLAYED;
            xpGained += p.goalsScored * XP_PER_GOAL_SCORED;
            if (isDraw) {
                xpGained += XP_FOR_DRAW_TEAM_PLAYER;
            } else if (winner == TeamType.Away) {
                xpGained += XP_FOR_WINNING_TEAM_PLAYER;
            }
            if (xpGained > 0) {
                playerNFTContract.addXP(p.nftId, xpGained);
                emit XPAwarded(_matchId, p.nftId, xpGained);
            }
        }
    }
    
    /**
     * @dev In case VRF fulfillment fails or never comes back, an admin function to resolve.
     * This is a fallback and should ideally not be needed if VRF is reliable.
     */
    function forceFailMatch(uint256 _matchId, uint256 _vrfRequestId) public onlyOwner {
        Match storage currentMatch = matches[_matchId];
        require(currentMatch.status == MatchStatus.Active || currentMatch.status == MatchStatus.Cooldown, "Match not in progress");
        
        // Clean up VRF request mapping if it matches
        if (vrfRequestToMatchId[_vrfRequestId] == _matchId && currentMatch.lastVrfRequestId == _vrfRequestId) {
            delete vrfRequestToMatchId[_vrfRequestId];
        }

        currentMatch.status = MatchStatus.Failed;
        // Optionally, refund entry fees if this match was part of a tournament system
        emit VRFRequestFailed(_matchId, _vrfRequestId);
        // No XP is awarded for failed matches.
    }


    // --- Admin Functions for VRF Config ---
    function setVRFSubscriptionId(uint64 _subscriptionId) public onlyOwner {
        s_subscriptionId = _subscriptionId;
    }

    function setVRFKeyHash(bytes32 _keyHash) public onlyOwner {
        s_keyHash = _keyHash;
    }

    // --- Getters ---
    function getMatchDetails(uint256 _matchId) public view returns (Match memory) {
        return matches[_matchId];
    }

    function getPlayerInMatch(uint256 _matchId, TeamType _team, uint8 _playerIndex) public view returns (PlayerInMatch memory) {
        if (_team == TeamType.Home) {
            require(_playerIndex < matches[_matchId].homeTeam.players.length, "Index out of bounds");
            return matches[_matchId].homeTeam.players[_playerIndex];
        } else {
            require(_playerIndex < matches[_matchId].awayTeam.players.length, "Index out of bounds");
            return matches[_matchId].awayTeam.players[_playerIndex];
        }
    }
}
