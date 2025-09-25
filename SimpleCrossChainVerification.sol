// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Simplified error definitions
error InvalidInput();
error Unauthorized();
error ContractPaused();
error InsufficientFee();

// Simplified interfaces
interface IClubMembershipQuery {
    function recordCrossChainVerification(
        string memory domainName,
        address user,
        uint32 chainId,
        address tokenAddress,
        uint256 balance,
        uint256 verificationTime
    ) external;
    
    function hasCrossChainVerification(
        string memory domainName,
        address user
    ) external view returns (bool);
}

interface ITokenBasedAccess {
    function getTokenGates(string memory domainName) external view returns (
        address[] memory tokenAddresses,
        uint256[] memory thresholds,
        uint256[] memory tokenIds,
        uint8[] memory tokenTypes,
        uint32[] memory chainIds,
        string[] memory tokenSymbols,
        string[] memory crossChainAddresses
    );
    function isClubInitialized(string memory domainName) external view returns (bool, address);
    function getClubAdmin(string memory domainName) external view returns (address);
}

interface IClubManager {
    function getClub(string memory domainName) external view returns (
        uint256 domainId,
        address admin,
        bool active,
        uint256 memberCount,
        address[] memory members
    );
}

/**
 * @title SimpleCrossChainVerification
 * @dev Simplified cross-chain verification contract - only keep core functionality
 */
contract SimpleCrossChainVerification is Ownable, Pausable {
    
    // Contract addresses
    address public membershipQueryContract;
    address public tokenAccessContract;
    address public clubManagerContract;
    
    // Bot address mapping
    mapping(address => bool) public authorizedBots;
    
    // Fee mechanism
    uint256 public verificationFee = 0.001 ether;
    address public feeRecipient;
    bool public feeEnabled = true;
    
    // Simplified events
    event VerificationRequested(
        address indexed user,
        string domainName,          // Remove indexed, keep original string
        uint32 indexed chainId,
        address tokenAddress,
        string requestId
    );
    
    event VerificationCompleted(
        address indexed user,
        string domainName,          // Remove indexed, keep original string
        uint32 indexed chainId,
        bool success,
        uint256 balance,
        uint256 threshold
    );
    
    event BotAuthorized(address indexed bot, bool authorized);
    event FeeUpdated(uint256 newFee    );
    
    // Debug events
    event VerificationDebug(
        address indexed user,
        string domainName,
        uint32 chainId,
        address tokenAddress,
        uint256 balance,
        string message
    );
    
    // Batch check events
    event BatchCheckRequested(
        address indexed user,
        string domainName
    );
    
    modifier onlyAuthorizedBot() {
        if (!authorizedBots[msg.sender]) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused2() {
        if (paused()) revert ContractPaused();
        _;
    }
    
    constructor(
        address _membershipQuery,
        address _tokenAccess,
        address _clubManager,
        address _feeRecipient
    ) Ownable(msg.sender) {
        if (_membershipQuery == address(0) || _tokenAccess == address(0) || _clubManager == address(0) || _feeRecipient == address(0)) {
            revert InvalidInput();
        }
        
        membershipQueryContract = _membershipQuery;
        tokenAccessContract = _tokenAccess;
        clubManagerContract = _clubManager;
        feeRecipient = _feeRecipient;
    }
    
    // ===== Administrator functions =====
    
    function setBotAuthorization(address bot, bool authorized) external onlyOwner {
        if (bot == address(0)) revert InvalidInput();
        authorizedBots[bot] = authorized;
        emit BotAuthorized(bot, authorized);
    }
    
    function setVerificationFee(uint256 newFee) external onlyOwner {
        verificationFee = newFee;
        emit FeeUpdated(newFee);
    }
    
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidInput();
        feeRecipient = newRecipient;
    }
    
    function setFeeEnabled(bool enabled) external onlyOwner {
        feeEnabled = enabled;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ===== Core functionality: User verification request =====
    
    /**
     * @dev User initiates cross-chain verification request - core functionality
     * @param domainName Club name
     * @param chainId Chain ID to verify
     * @param tokenAddress Token address to verify
     */
    function requestVerification(
        string memory domainName,
        uint32 chainId,
        address tokenAddress
    ) external payable whenNotPaused2 {
        if (bytes(domainName).length == 0 || chainId == 0) revert InvalidInput();
        
        // Check fee
        if (feeEnabled && msg.value < verificationFee) revert InsufficientFee();
        
        // Transfer fee
        if (feeEnabled && verificationFee > 0) {
            (bool success,) = feeRecipient.call{value: verificationFee}("");
            require(success, "Fee transfer failed");
            
            // Refund excess fee
            if (msg.value > verificationFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - verificationFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        
        (bool initialized,) = ITokenBasedAccess(tokenAccessContract).isClubInitialized(domainName);
        if (!initialized) revert InvalidInput();
        
        // Emit event for bot listening
        emit VerificationRequested(msg.sender, domainName, chainId, tokenAddress, "");
    }
    
    // ===== Bot functions: Process verification =====
    
    /**
     * @dev 
     * @param user User address
     * @param domainName Club name
     * @param chainId Chain ID
     * @param tokenAddress Token address
     * @param actualBalance Actual balance queried
     */
    function processVerification(
        address user,
        string memory domainName,
        uint32 chainId,
        address tokenAddress,
        uint256 actualBalance
    ) external onlyAuthorizedBot whenNotPaused2 {
        
        // Cross-contract does not make judgments, directly pass data to Query for Query to judge
        emit VerificationDebug(user, domainName, chainId, tokenAddress, actualBalance, "Sending data to Query");
        
        // Call Query contract to record verification data (let Query judge whether it meets the threshold by itself)
        IClubMembershipQuery(membershipQueryContract).recordCrossChainVerification(
            domainName,
            user,
            chainId,
            tokenAddress,
            actualBalance,
            block.timestamp
        );
        
        emit VerificationDebug(user, domainName, chainId, tokenAddress, actualBalance, "Data sent to Query");
        
        // Emit verification completed event
        emit VerificationCompleted(user, domainName, chainId, true, actualBalance, 0);
    }
    

    
    function getVerificationFeeInfo() external view returns (uint256 fee, address recipient, bool enabled) {
        return (verificationFee, feeRecipient, feeEnabled);
    }
    
    /**
     * @dev Get contract configuration status - for debugging
     * @return membershipQuery ClubMembershipQuery contract address
     * @return tokenAccess TokenBasedAccess contract address
     */
    function getContractAddresses() external view returns (address membershipQuery, address tokenAccess) {
        return (membershipQueryContract, tokenAccessContract);
    }
    
    function isSupportedChainId(uint32 chainId) public pure returns (bool) {
        return chainId == 1 || chainId == 137 || chainId == 56 || chainId == 42161 || 
               chainId == 10 || chainId == 43114 || chainId == 11155111 || chainId == 80001;
    }
    
    
    /**
     * @dev Query cross-chain token thresholds for clubs - help debug contract calls
     * @param domainName Club name
     * @return chainIds Chain ID array
     * @return tokenAddresses Token address array
     * @return crossChainAddresses Cross-chain address array
     * @return thresholds Threshold array
     * @return symbols Token symbol array
     */
    function getClubCrossChainRequirements(string memory domainName) external view returns (
        uint32[] memory chainIds,
        address[] memory tokenAddresses,
        string[] memory crossChainAddresses,
        uint256[] memory thresholds,
        string[] memory symbols
    ) {
        // Call TokenBasedAccess to get thresholds
        (
            address[] memory allTokenAddresses,
            uint256[] memory allThresholds,
            ,
            uint8[] memory tokenTypes,
            uint32[] memory allChainIds,
            string[] memory tokenSymbols,
            string[] memory allCrossChainAddresses
        ) = ITokenBasedAccess(tokenAccessContract).getTokenGates(domainName);
        

        uint256 crossChainCount = 0;
        for (uint256 i = 0; i < tokenTypes.length; i++) {
            if (tokenTypes[i] == 3) { // CROSSCHAIN type
                crossChainCount++;
            }
        }
        

        chainIds = new uint32[](crossChainCount);
        tokenAddresses = new address[](crossChainCount);
        crossChainAddresses = new string[](crossChainCount);
        thresholds = new uint256[](crossChainCount);
        symbols = new string[](crossChainCount);
        

        uint256 index = 0;
        for (uint256 i = 0; i < tokenTypes.length; i++) {
            if (tokenTypes[i] == 3) {
                chainIds[index] = allChainIds[i];
                tokenAddresses[index] = allTokenAddresses[i];
                crossChainAddresses[index] = allCrossChainAddresses[i];
                thresholds[index] = allThresholds[i];
                symbols[index] = tokenSymbols[i];
                index++;
            }
        }
    }
    
    /**
     * @dev Club administrator batch checks cross-chain qualifications of specified members
     * @param domainName Club name
     * @param members Member address array to check
     */
    function batchCheckMembers(
        string memory domainName,
        address[] memory members
    ) external payable {
        // Check if club exists
        (bool initialized,) = ITokenBasedAccess(tokenAccessContract).isClubInitialized(domainName);
        if (!initialized) revert InvalidInput();
        
        // Permission check: Only club administrator can call
        (, address clubAdmin,,,) = IClubManager(clubManagerContract).getClub(domainName);
        require(msg.sender == clubAdmin, "Only club admin can batch check");
        
        // Calculate batch check fee (automatically calculate member count * fee)
        uint256 totalFee = verificationFee * members.length;
        
        // Check fee
        if (feeEnabled && msg.value < totalFee) revert InsufficientFee();
        
        // Transfer fee
        if (feeEnabled && totalFee > 0) {
            (bool success,) = feeRecipient.call{value: totalFee}("");
            require(success, "Fee transfer failed");
            
            // Refund excess fee
            if (msg.value > totalFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - totalFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        // Emit batch check events, bots listen and process
        for (uint256 i = 0; i < members.length; i++) {
            emit BatchCheckRequested(members[i], domainName);
        }
    }
    
    /**
     * @dev Calculate batch check fee
     * @param memberCount Number of members
     * @return totalFee Total fee
     */
    function calculateBatchFee(uint256 memberCount) external view returns (uint256 totalFee) {
        return verificationFee * memberCount;
    }
    
    /**
     * @dev Club administrator batch checks all cross-chain members
     * @param domainName Club name
     */
    function batchCheckAllMembers(string memory domainName) external payable {
        // Permission check: Only club administrator can call
        (, address clubAdmin,,,) = IClubManager(clubManagerContract).getClub(domainName);
        require(msg.sender == clubAdmin, "Only club admin can batch check");
        
        // Get all members from ClubManager
        (,,,, address[] memory allMembers) = IClubManager(clubManagerContract).getClub(domainName);
        
        // Count members with cross-chain records
        uint256 crossChainCount = 0;
        for (uint256 i = 0; i < allMembers.length; i++) {
            try IClubMembershipQuery(membershipQueryContract).hasCrossChainVerification(domainName, allMembers[i]) returns (bool hasRecord) {
                if (hasRecord) {
                    crossChainCount++;
                }
            } catch {}
        }
        
        // Calculate fee: only charge members with cross-chain records
        uint256 totalFee = verificationFee * crossChainCount;
        
        // Must pay fee
        if (feeEnabled && msg.value < totalFee) revert InsufficientFee();
        
        // Transfer fee to feeRecipient (not bots)
        if (feeEnabled && totalFee > 0) {
            (bool success,) = feeRecipient.call{value: totalFee}("");
            require(success, "Fee transfer failed");
            
            // Refund excess fee
            if (msg.value > totalFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - totalFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        // Only emit check events for members with cross-chain records
        for (uint256 i = 0; i < allMembers.length; i++) {
            try IClubMembershipQuery(membershipQueryContract).hasCrossChainVerification(domainName, allMembers[i]) returns (bool hasRecord) {
                if (hasRecord) {
                    emit BatchCheckRequested(allMembers[i], domainName);
                }
            } catch {}
        }
    }
    
    // ===== Internal functions =====
    
    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(addr);
        bytes memory stringBytes = new bytes(42);
        
        stringBytes[0] = '0';
        stringBytes[1] = 'x';
        
        for (uint i = 0; i < 20; i++) {
            bytes1 leftNibble = bytes1(uint8(uint(uint8(addressBytes[i])) / 16 + 48));
            bytes1 rightNibble = bytes1(uint8(uint(uint8(addressBytes[i])) % 16 + 48));
            if (uint8(leftNibble) > 57) leftNibble = bytes1(uint8(leftNibble) + 39);
            if (uint8(rightNibble) > 57) rightNibble = bytes1(uint8(rightNibble) + 39);
            stringBytes[2+i*2] = leftNibble;
            stringBytes[2+i*2+1] = rightNibble;
        }
        
        return string(stringBytes);
    }
    
    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        // Compare after converting to lowercase
        return keccak256(abi.encodePacked(_toLowerCase(a))) == keccak256(abi.encodePacked(_toLowerCase(b)));
    }
    
    /**
     * @dev Convert string to lowercase
     */
    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        
        for (uint i = 0; i < bStr.length; i++) {
            // If it is an uppercase letter A-F, convert to lowercase
            if (bStr[i] >= 0x41 && bStr[i] <= 0x46) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        
        return string(bLower);
    }
    
}
