// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IWeb3ClubRegistry {
    enum DomainStatus { Available, Active, Frozen, Reclaimed }
    
    function getDomainStatus(string memory name) external view returns (DomainStatus);
    function getDomainInfo(string memory name) external view returns (uint256 registrationTime, uint256 expiryTime, address registrant);
    function nftContract() external view returns (address);
    function governanceContract() external view returns (address);
    function isRegistered(string memory name) external view returns (bool);
}

interface IWeb3ClubNFT is IERC721 {
    function getDomainName(uint256 tokenId) external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getTokenId(string memory domainName) external view returns (uint256);
    function getDomainInfo(string memory domainName) external view returns (DomainInfo memory);
    
    struct DomainInfo {
        uint256 registrationTime;
        uint256 expiryTime;
        address registrant;
    }
}

interface IMembershipContract {
    function initializeClub(string memory domainName, address admin) external;
    function initializeClub(string memory domainName, address admin, string memory name, string memory symbol, string memory baseURI) external;
    function updateClubAdmin(string memory domainName, address newAdmin) external;
    function hasActiveMembership(string memory domainName, address account) external view returns (bool);
    function hasActiveMembershipByDomain(string memory domainName, address account) external view returns (bool);
    function uninitializeClub(string memory domainName) external;
    function isClubInitialized(string memory domainName) external view returns (bool initialized, address admin);
}

// Additional interfaces for specific contracts
interface ITokenBasedAccess is IMembershipContract {
    function getClubAdmin(string memory domainName) external view returns (address);
    function getTokenGate(string memory domainName) external view returns (address tokenAddress, uint256 threshold);
    function checkAndUpdateAccess(string memory domainName, address user) external returns (bool);
}

// Minimal error codes
error NotAdmin();
error ZeroAddress();
error ClubExists();
error NotActive();
error NotMember();
error NotDomainOwner();
error DomainAlreadyHasClub();
error InvalidDomainId();
error ContractPaused();
error NotAuthorized();
error DomainError(string reason);
error InitializationError(string contractName, string reason);

// Add new interfaces
interface IClubPassFactory {
    function createClubPassContract(
        string memory domainName,
        address admin,
        string memory name,
        string memory symbol,
        string memory baseURI
    ) external returns (address);
    
    function getClubPassContract(string memory domainName) external view returns (address);
    
    // Simplified comments
    function queryClubMembership(
        string memory domainName, 
        address account
    ) external view returns (
        bool isMember,
        bool isActive,
        uint256 tokenId,
        uint256 memberCount
    );
}

// Add ClubManager's own interface definition for external contract calls
interface IClubManager {
    function updateMembership(address user, string memory domainName, bool status) external returns (bool);
    function recordClubPassCollection(string memory domainName, address collectionAddress) external;
}

interface ClubPassCard {
    function updateAdmin(address newAdmin) external;
}

contract ClubManager is Ownable, Pausable, IERC721Receiver {
    using Counters for Counters.Counter;
    using Strings for uint256;
    
    // Domain expiration status enumeration
    enum DomainTransitionStatus {
        None,
        Pending,
        Accepted,
        Rejected
    }
    
    // Domain transition period record structure
    struct DomainTransition {
        address previousOwner;
        DomainTransitionStatus status;
        uint256 transitionTimestamp;
        uint256 oldTokenId;         // Record old TokenID
        bool nftDestroyed;          // Record if NFT has been destroyed
    }
    
    // Domain transition period mapping
    mapping(string => DomainTransition) private _domainTransitions;
    
    // Set automatic domain inheritance strategy
    enum AutoInheritancePolicy {
        Prompt,    // Prompt user to manually decide whether to inherit
        Always,    // Automatically inherit from previous club
        Never      // Never inherit from previous club
    }
    
    // Global and user automatic inheritance policy configuration
    AutoInheritancePolicy public autoInheritancePolicy = AutoInheritancePolicy.Prompt;
    mapping(address => AutoInheritancePolicy) private _userAutoInheritancePolicy;
    
    // Events
    event ClubCreated(string domainName, address admin, uint256 domainId, string name, string symbol, string description);
    event AdminChanged(string domainName, address oldAdmin, address newAdmin);
    event ActiveChanged(string domainName, bool active);
    event MembershipChanged(address user, string domainName, bool status);
    event MembershipStatusUpdated(address member, string domainName, bool status);
    event DomainOwnershipChanged(string domainName, address oldOwner, address newOwner);
    event EmergencyPause(bool paused);
    event MembershipContractsUpdated(address perm, address temp, address token);
    event DomainExpired(string domainName, address previousOwner);
    event DomainReregistered(string domainName, address newOwner, address oldOwner);
    event ClubInheritanceDecision(string domainName, bool accepted);
    event MembershipRemovalAttempted(address user, string domainName, string reason);
    event ClubPassCollectionRegistered(string indexed domainName, address collectionAddress);
    event ClubMetadataUpdated(string indexed domainName, string name, string symbol, string description, string logoURL, string bannerURL, string baseURI);
    
    IWeb3ClubNFT public nftContract;
    IWeb3ClubRegistry public registryContract;
    
    // Store membership contract addresses
    address public tempMembershipAddr;
    address public tokenAccessAddr;
    
    // ClubPass factory contract address - new permanent membership system
    address public clubPassFactory;
    
    // Platform fee configuration (global)
    address public platformTreasury;   // Platform revenue receiver
    uint16 public platformFeeBps;      // Platform fee in basis points (0-10000)
    
    struct Club {
        uint256 domainId;   // Bind to ID of NFT of secondary domain
        address admin;
        bool active;
        uint256 memberCount;
        address[] members;
        address[] adminTransferHistory;  // Management change history
        mapping(address => bool) memberStatus;
        // Club metadata
        string name;        // Club name
        string symbol;      // Club symbol
        string description; // Club description
        string logoURL;     // Logo URL
        string bannerURL;   // Banner URL
        string baseURI;     // Base metadata URI
    }
    
    Counters.Counter private _clubIdCounter;
    mapping(string => Club) private _clubs;
    mapping(uint256 => string) private _domainIdToName;
    mapping(address => string[]) private _userClubs;
    mapping(string => mapping(address => bool)) private _clubMembers;
    

    
    // CLUB permanent membership contract address mapping
    mapping(string => address) private _clubPassCollections;
    
    modifier onlyClubAdmin(string memory domainName) {
        if (!isClubActive(domainName)) revert NotActive();
        if (msg.sender != _clubs[domainName].admin && msg.sender != owner()) revert NotAdmin();
        _;
    }
    
    modifier onlyDomainOwner(string memory domainName) {
        uint256 domainId = getDomainId(domainName);
        if (msg.sender != nftContract.ownerOf(domainId)) revert NotDomainOwner();
        _;
    }
    
    modifier whenNotPaused2() {
        if (paused()) revert ContractPaused();
        _;
    }
    
    // Domain name format constant - keep this field for reference only, no longer used for modifying domain names
    string public constant DOMAIN_SUFFIX = ".web3.club";
    
    constructor() Ownable(msg.sender) {
        // All contract addresses will be set via setAllContracts function after deployment
    }
    
    // NFT reception logic
    function onERC721Received(
        address, 
        address from, 
        uint256 tokenId, 
        bytes calldata
    ) external override returns (bytes4) {
        // Confirm that it's from our trusted NFT contract
        if (msg.sender != address(nftContract)) {
            return this.onERC721Received.selector;
        }
        

        
        // Get domain name - directly get full domain name from NFT
        string memory domainName;
        try nftContract.getDomainName(tokenId) returns (string memory name) {
            domainName = standardizeDomainName(name); // Standardize domain name (remove suffix)
            // Update domain ID mapping
            _domainIdToName[tokenId] = domainName;
            
            // Check if domain name already has club, if so update admin
            if (isClubInitialized(domainName)) {
                // Update admin
                if (_clubs[domainName].admin == from) {
                    _clubs[domainName].admin = address(this);
                    _clubs[domainName].adminTransferHistory.push(address(this));
                    emit AdminChanged(domainName, from, address(this));
                }
            }
        } catch {
            // Ignore errors
        }
        
        return this.onERC721Received.selector;
    }
    
    /**
     * @dev Generate default base URI for club
     * @param domainName Domain name prefix
     * @return Default base URI
     */
    function _generateDefaultBaseURI(string memory domainName) internal pure returns (string memory) {
        return string(abi.encodePacked("https://", domainName, ".web3.club/"));
    }
    
    /**
     * @dev Initialize subcontracts
     */
    function _initializeSubcontracts(
        string memory domainName, 
        address admin, 
        string memory name, 
        string memory symbol, 
        string memory baseURI
    ) internal returns (bool) {
        // Mark initialization status
        bool passContractCreated = false;
        bool tempInitialized = false;

        // 1. Create independent permanent membership PASS card contract
        if (clubPassFactory != address(0)) {
            try IClubPassFactory(clubPassFactory).createClubPassContract(
                domainName, 
                admin, 
                name, 
                symbol, 
                baseURI
            ) returns (address passContractAddress) {
                if (passContractAddress != address(0)) {
                    // Record PASS card contract address
                    _clubPassCollections[domainName] = passContractAddress;
                    
                    passContractCreated = true;
                    emit ClubPassCollectionRegistered(domainName, passContractAddress);
                } else {
                    revert InitializationError("PassFactory", "Contract creation failed");
                }
            } catch Error(string memory reason) {
                revert InitializationError("PassFactory", reason);
            } catch {
                revert InitializationError("PassFactory", "Unknown error");
            }
        } else {
            revert InitializationError("PassFactory", "Factory address is zero");
        }

        // 2. Temporary membership contract initialization (use provided name/symbol without auto suffix)
        string memory tempName = name;
        string memory tempSymbol = symbol;
        
        try IMembershipContract(tempMembershipAddr).initializeClub(
            domainName, 
            admin, 
            tempName, 
            tempSymbol, 
            baseURI
        ) {
            tempInitialized = true;
        } catch {
            _rollbackInitialization(domainName, passContractCreated, false);
            revert InitializationError("TemporaryMembership", "Initialization failed");
        }
        
        // 3. Token access contract initialization
        try IMembershipContract(tokenAccessAddr).initializeClub(domainName, admin) {
            return true; // All initializations successful
        } catch {
            _rollbackInitialization(domainName, passContractCreated, tempInitialized);
            revert InitializationError("TokenBasedAccess", "Initialization failed");
        }
    }
    
    /**
     * @dev Rollback initialization
     */
    function _rollbackInitialization(string memory domainName, bool passContractCreated, bool tempInitialized) internal {
        if (passContractCreated) {
            // Note: Once a PASS card contract is created, it cannot be revoked, but this event can be recorded
        }
        if (tempInitialized) {
            try IMembershipContract(tempMembershipAddr).uninitializeClub(domainName) {} catch {}
        }
    }
    
    /**
     * @dev Generate symbol from domain name
     */
    function _getSymbol(string memory name) internal pure returns (string memory) {
        bytes memory nameBytes = bytes(name);
        uint256 length = nameBytes.length > 5 ? 5 : nameBytes.length;
        
        bytes memory symbolBytes = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            symbolBytes[i] = nameBytes[i];
        }
        
        return string(symbolBytes);
    }
    
    /**
     * @dev Club admin transfer
     */
    function transferAdmin(string memory domainName, address newAdmin) external whenNotPaused2 {
        if (newAdmin == address(0)) revert ZeroAddress();
        
        if (msg.sender != _clubs[domainName].admin && msg.sender != nftContract.ownerOf(_clubs[domainName].domainId)) revert NotAdmin();
        
        _updateClubAdmin(domainName, newAdmin);
    }
    
    /**
     * @dev Internal function for updating club admin address
     */
    function _updateClubAdmin(string memory domainName, address newAdmin) internal {
        string memory standardized = standardizeDomainName(domainName);
        
        // Check if club exists
        if (!isClubInitialized(standardized)) {
            return;
        }
        
        address oldAdmin = _clubs[standardized].admin;
        _clubs[standardized].admin = newAdmin;
        
        // Record management change history
        _clubs[standardized].adminTransferHistory.push(newAdmin);
        
        // Update management of membership contract
        if (tempMembershipAddr != address(0)) {
            try IMembershipContract(tempMembershipAddr).updateClubAdmin(standardized, newAdmin) {} catch {}
        }
        
        if (tokenAccessAddr != address(0)) {
            try IMembershipContract(tokenAccessAddr).updateClubAdmin(standardized, newAdmin) {} catch {}
        }
        
        // 添加此部分：更新永久会员证合约的管理员
        address passCollection = _clubPassCollections[standardized];
        if (passCollection != address(0)) {
            try ClubPassCard(passCollection).updateAdmin(newAdmin) {} catch {}
        }
        
        // Keep permanent membership contract address, ensuring it cannot be changed
        if (passCollection != address(0)) {
            emit ClubPassCollectionRegistered(standardized, passCollection);
        }
        
        emit AdminChanged(standardized, oldAdmin, newAdmin);
    }
    
    /**
     * @dev Set club active status
     */
    function setClubActive(string memory domainName, bool active) external onlyOwner {
        if (!isClubInitialized(domainName)) revert DomainError("Club not initialized");
        
        _clubs[domainName].active = active;
        emit ActiveChanged(domainName, active);
    }
    
    /**
     * @dev Update club metadata (only club admin can call)
     */
    function updateClubMetadata(
        string memory domainName,
        string memory name,
        string memory symbol,
        string memory description,
        string memory logoURL,
        string memory bannerURL,
        string memory baseURI
    ) external onlyClubAdmin(domainName) {
        string memory standardized = standardizeDomainName(domainName);
        
        // Check required fields
        if (bytes(name).length == 0) {
            revert DomainError("Club name cannot be empty");
        }
        if (bytes(symbol).length == 0) {
            revert DomainError("Club symbol cannot be empty");
        }
        
        // Update metadata
        _clubs[standardized].name = name;
        _clubs[standardized].symbol = symbol;
        _clubs[standardized].description = description;
        _clubs[standardized].logoURL = logoURL;
        _clubs[standardized].bannerURL = bannerURL;
        
        // Update baseURI if provided, otherwise keep existing
        if (bytes(baseURI).length > 0) {
            _clubs[standardized].baseURI = baseURI;
        }
        
        emit ClubMetadataUpdated(standardized, name, symbol, description, logoURL, bannerURL, baseURI);
    }
    
    /**
     * @dev Check if club is initialized
     */
    function isClubInitialized(string memory domainName) public view returns (bool) {
        if (bytes(domainName).length == 0) return false;
        
        // Check standardized domain name (this function no longer calls standardizeDomainName, as this could lead to recursive calls)
        return _clubs[domainName].admin != address(0);
    }
    
    /**
     * @dev Check if club is active
     */
    function isClubActive(string memory domainName) public view returns (bool) {
        return isClubInitialized(domainName) && _clubs[domainName].active;
    }
    
    /**
     * @dev Get club basic information
     */
    function getClub(string memory domainName) public view returns (uint256 domainId, address admin, bool active, uint256 memberCount, address[] memory members) {
        string memory standardized = getValidDomainName(domainName);
        if (!isClubInitialized(standardized)) revert DomainError("Club not initialized");
        Club storage club = _clubs[standardized];
        return (club.domainId, club.admin, club.active, club.memberCount, club.members);
    }
    
    /**
     * @dev Get club detailed information including metadata
     */
    function getClubDetails(string memory domainName) public view returns (
        uint256 domainId,
        address admin,
        bool active,
        uint256 memberCount,
        string memory name,
        string memory symbol,
        string memory description,
        string memory logoURL,
        string memory bannerURL,
        string memory baseURI
    ) {
        string memory standardized = getValidDomainName(domainName);
        if (!isClubInitialized(standardized)) revert DomainError("Club not initialized");
        Club storage club = _clubs[standardized];
        return (
            club.domainId,
            club.admin,
            club.active,
            club.memberCount,
            club.name,
            club.symbol,
            club.description,
            club.logoURL,
            club.bannerURL,
            club.baseURI
        );
    }
    
    /**
     * @dev Get club admin
     */
    function getClubAdmin(string memory domainName) public view returns (address) {
        string memory standardized = getValidDomainName(domainName);
        if (!isClubInitialized(standardized)) revert DomainError("Club not initialized");
        return _clubs[standardized].admin;
    }
    

    
    /**
     * @dev Get all club names for a user
     * @param user User address
     * @return Array of club names user belongs to
     */
    function getUserClubs(address user) public view returns (string[] memory) {
        return _userClubs[user];
    }
    
    /**
     * @dev Get user club ID list (compatible with old interface)
     */
    function getUserClubIds(address user) public view returns (uint256[] memory) {
        string[] memory domainNames = _userClubs[user];
        uint256[] memory clubIds = new uint256[](domainNames.length);
        
        for (uint256 i = 0; i < domainNames.length; i++) {
            clubIds[i] = getDomainId(domainNames[i]);
        }
        
        return clubIds;
    }
    
    /**
     * @dev Get club membership contract address
     * @return pass PASS card contract address
     * @return temp Temporary membership contract address
     * @return token Token access contract address
     */
    function getClubContracts(string memory domainName) public view returns (address pass, address temp, address token) {
        string memory standardized = standardizeDomainName(domainName);
        
        // Get CLUB's exclusive PASS card contract address
        pass = _clubPassCollections[standardized];
        
        // If there is no exclusive PASS card contract, return factory address
        if (pass == address(0)) {
            pass = clubPassFactory;
        }
        
        return (pass, tempMembershipAddr, tokenAccessAddr);
    }
    
    /**
     * @dev Check if user is club member
     * @param domainName Club name
     * @param user User address
     * @return Whether user is member
     */
    function isMember(string memory domainName, address user) public view returns (bool) {
        if (user == address(0)) return false;
        
        string memory standardized = standardizeDomainName(domainName);
        if (bytes(standardized).length == 0) return false;
            
        if (!isClubInitialized(standardized)) return false;
        
        // Check permanent membership
        if (clubPassFactory != address(0)) {
            try IClubPassFactory(clubPassFactory).queryClubMembership(standardized, user) returns (
                bool hasMembership,
                bool isActive,
                uint256,
                uint256
            ) {
                if (hasMembership && isActive) return true;
            } catch {}
        }
        
        // Check temporary membership
        if (tempMembershipAddr != address(0)) {
            try IMembershipContract(tempMembershipAddr).hasActiveMembership(standardized, user) returns (bool hasTemp) {
                if (hasTemp) return true;
            } catch {}
        }
        
        // Check token membership
        if (tokenAccessAddr != address(0)) {
            try IMembershipContract(tokenAccessAddr).hasActiveMembership(standardized, user) returns (bool hasToken) {
                if (hasToken) return true;
            } catch {}
        }
        
        return false;
    }
    
    /**
     * @dev Update member status - following Web3 decentralized spirit, only add member, cannot remove member
     * @param user User address
     * @param domainName Club name
     * @param status Member status (Web3 spirit, false status will be ignored)
     * @return Whether successful
     */
    function updateMembership(address user, string memory domainName, bool status) external returns (bool) {
        if (user == address(0)) revert ZeroAddress();
        
        string memory standardized = standardizeDomainName(domainName);
        if (bytes(standardized).length == 0) revert DomainError("Invalid domain name");
        
        // Permission check: Only allow membership contract or admin to call
        // Add checkPASS card contract permission logic
        address passCollection = _clubPassCollections[standardized];
        if (msg.sender != tempMembershipAddr && 
            msg.sender != tokenAccessAddr && 
            msg.sender != passCollection &&
            msg.sender != clubPassFactory &&
            msg.sender != owner()) revert NotAuthorized();
            
        if (!isClubInitialized(standardized)) revert DomainError("Club not initialized");
        
        // If it's a request to remove member, return true but do not execute operation
        if (!status) {
            emit MembershipRemovalAttempted(user, standardized, "Operation blocked: Web3 principles prevent membership revocation");
            return true;
        }
        
        // Current status
        bool currentStatus = _clubMembers[standardized][user];
        
        // If status changes (only support adding member)
        if (!currentStatus && status) {
            _clubMembers[standardized][user] = true;
            
            // Check if user is already in club list
            bool found = false;
            for (uint256 i = 0; i < _userClubs[user].length; i++) {
                if (keccak256(bytes(_userClubs[user][i])) == keccak256(bytes(standardized))) {
                    found = true;
                    break;
                }
            }
            
            // If not in list, add
            if (!found) {
                _userClubs[user].push(standardized);
            }
            
            // Add user to club member list
            bool memberFound = false;
            for (uint256 i = 0; i < _clubs[standardized].members.length; i++) {
                if (_clubs[standardized].members[i] == user) {
                    memberFound = true;
                    break;
                }
            }
            
            if (!memberFound) {
                _clubs[standardized].members.push(user);
                _clubs[standardized].memberCount++;
            }
            
            emit MembershipChanged(user, standardized, true);
        }
        
        return true;
    }
    

    
    /**
     * @dev Handle domain expiry
     */
    function handleDomainExpiry(string memory domainName) external {
        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) revert DomainError("Invalid domain name");
        
        // Check domain status through Registry
        IWeb3ClubRegistry.DomainStatus status;
        try registryContract.getDomainStatus(standardDomain) returns (IWeb3ClubRegistry.DomainStatus _status) {
            status = _status;
        } catch {
            revert DomainError("Failed to check domain status");
        }
        
        // Only process expired domains (frozen or reclaimed status)
        if (status != IWeb3ClubRegistry.DomainStatus.Frozen && status != IWeb3ClubRegistry.DomainStatus.Reclaimed) {
            revert DomainError("Domain has not expired");
        }
        
        // If domain name is not bound to any club, do nothing
        if (!isClubInitialized(standardDomain)) {
            revert DomainError("Domain is not bound to any club");
        }
        
        // Record previous owner and current TokenID
        address previousOwner = _clubs[standardDomain].admin;
        uint256 currentTokenId = _clubs[standardDomain].domainId;
                
        // Check if NFT exists
        bool nftExists = true;
        try nftContract.ownerOf(currentTokenId) returns (address) {
            // NFT still exists
        } catch {
            // NFT does not exist or has been destroyed
            nftExists = false;
        }
        
        // Set transition status
        _domainTransitions[standardDomain] = DomainTransition({
            previousOwner: previousOwner,
            status: DomainTransitionStatus.Pending,
            transitionTimestamp: block.timestamp,
            oldTokenId: currentTokenId,
            nftDestroyed: !nftExists
        });
        
        // Disable club
        _clubs[standardDomain].active = false;
        
        emit DomainExpired(standardDomain, previousOwner);
    }

    /**
     * @dev Handle domain reregistration
     */
    function handleDomainReregistration(string memory domainName) external {
        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) revert DomainError("Invalid domain name");
        
        // Verify domain name is valid and active
        IWeb3ClubRegistry.DomainStatus status;
        try registryContract.getDomainStatus(standardDomain) returns (IWeb3ClubRegistry.DomainStatus _status) {
            status = _status;
        } catch {
            revert DomainError("Failed to check domain status");
        }
        
        if (status != IWeb3ClubRegistry.DomainStatus.Active) {
            revert DomainError("Domain must be active to handle reregistration");
        }
        
        // Get current TokenID and owner
        uint256 newTokenId;
        address newOwner;
        
        try nftContract.getTokenId(standardDomain) returns (uint256 tokenId) {
            if (tokenId == 0) {
                revert DomainError("Invalid token ID");
            }
            newTokenId = tokenId;
            
            try nftContract.ownerOf(tokenId) returns (address owner) {
                newOwner = owner;
            } catch {
                revert DomainError("Failed to get domain owner");
            }
        } catch {
            revert DomainError("Failed to get domain token ID");
        }
        
        if (newOwner != msg.sender) {
            revert NotDomainOwner();
        }
        
        // Check if in transition period
        DomainTransition storage transition = _domainTransitions[standardDomain];
        if (transition.status == DomainTransitionStatus.None) {
            // Check if club exists but not recorded transition status (possibly because we missed expiry handling)
            if (isClubInitialized(standardDomain)) {
                // Create a default transition status record
                uint256 oldTokenId = _clubs[standardDomain].domainId;
                address oldAdmin = _clubs[standardDomain].admin;
                
                transition.previousOwner = oldAdmin;
                transition.status = DomainTransitionStatus.Pending;
                transition.transitionTimestamp = block.timestamp;
                transition.oldTokenId = oldTokenId;
                transition.nftDestroyed = (oldTokenId != newTokenId); // Assume TokenID change indicates NFT destroyed
            } else {
                // If club does not exist, create a new one
                // This situation may be because the domain was not previously associated with a club
                return;
            }
        }
        
        // Check if TokenID changes (indicates NFT destroyed and reregistered)
        bool tokenIdChanged = (transition.oldTokenId != 0 && transition.oldTokenId != newTokenId);
        
        // If TokenID changes, update mapping
        if (tokenIdChanged) {
            // Remove domain from old TokenID mapping
            delete _domainIdToName[transition.oldTokenId];
            
            // Update to new mapping
            _domainIdToName[newTokenId] = standardDomain;
            
            // Update club record TokenID
            _clubs[standardDomain].domainId = newTokenId;
        }
        
        // Update admin
        _updateClubAdmin(standardDomain, newOwner);
        
        // Keep all members, activate club
        _clubs[standardDomain].active = true;
        transition.status = DomainTransitionStatus.Accepted;
        
        emit ClubInheritanceDecision(standardDomain, true);
        emit DomainReregistered(standardDomain, newOwner, transition.previousOwner);
    }
    
    /**
     * @dev Emergency pause and recovery
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPause(true);
    }
    
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyPause(false);
    }
    
    /**
     * @dev Set platform treasury address
     */
    function setPlatformTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        platformTreasury = _treasury;
    }
    
    /**
     * @dev Set platform fee (basis points). Max 10000 (100%).
     */
    function setPlatformFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= 10000, "BPS>10000");
        platformFeeBps = _bps;
    }

    /**
     * @dev Set all contract addresses at once
     * @param _registry Registry contract address (optional, use address(0) to skip)
     * @param _nft NFT contract address (optional, use address(0) to skip)
     * @param _passFactory PASS card factory contract address (optional, use address(0) to skip)
     * @param _temp Temporary membership contract address (optional, use address(0) to skip)
     * @param _token Token access contract address (optional, use address(0) to skip)
     */
    function setAllContracts(
        address _registry,
        address _nft,
        address _passFactory,
        address _temp,
        address _token
    ) external onlyOwner {
        if (_registry != address(0)) {
            registryContract = IWeb3ClubRegistry(_registry);
            
            // Try to get NFT contract from registry if NFT address not provided
            if (_nft == address(0)) {
                try registryContract.nftContract() returns (address nftAddress) {
                    if (nftAddress != address(0)) {
                        nftContract = IWeb3ClubNFT(nftAddress);
                    }
                } catch {}
            }
        }
        
        if (_nft != address(0)) {
            nftContract = IWeb3ClubNFT(_nft);
        }
        
        if (_passFactory != address(0)) {
            clubPassFactory = _passFactory;
        }
        
        if (_temp != address(0)) {
            tempMembershipAddr = _temp;
        }
        
        if (_token != address(0)) {
            tokenAccessAddr = _token;
        }
        
        emit MembershipContractsUpdated(_passFactory, _temp, _token);
    }
    
    /**
     * @dev Quick setup for all required contracts (convenience function)
     */
    function setupContracts(
        address _registry,
        address _passFactory,
        address _temp,
        address _token
    ) external onlyOwner {
        if (_registry == address(0) || _passFactory == address(0) || _temp == address(0) || _token == address(0)) revert ZeroAddress();
        
        // Set contracts directly
        registryContract = IWeb3ClubRegistry(_registry);
        clubPassFactory = _passFactory;
        tempMembershipAddr = _temp;
        tokenAccessAddr = _token;
        
        // Try to get NFT contract from registry
        try registryContract.nftContract() returns (address nftAddress) {
            if (nftAddress != address(0)) {
                nftContract = IWeb3ClubNFT(nftAddress);
            }
        } catch {}
        
        emit MembershipContractsUpdated(_passFactory, _temp, _token);
    }

    /**
     * @dev Standardize domain name format, ensure domain name is valid and uniform
     * @param input Input domain name
     * @return Standardized domain name prefix (without suffix)
     */
    function standardizeDomainName(string memory input) public pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        
        // If empty, return empty
        if (inputBytes.length == 0) return "";
        
        // Remove .web3.club suffix (if exists)
        string memory result = _getDomainPrefixInternal(input);
        inputBytes = bytes(result);
        
        if (inputBytes.length == 0) return "";
        
        // Simple domain name character validation
        for (uint i = 0; i < inputBytes.length; i++) {
            bytes1 b = inputBytes[i];
            
            // Allow a-z, 0-9, _ These characters
            if (!(
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x5F                    // _
            )) {
                return ""; // Return empty indicating invalid
            }
        }
        
        // Domain name is valid, return prefix
        return result;
    }
    
    /**
     * @dev Get domain name prefix (without .web3.club suffix)
     * @param fullDomain Possible full domain name containing suffix
     * @return Domain name prefix
     */
    function _getDomainPrefixInternal(string memory fullDomain) internal pure returns (string memory) {
        bytes memory domainBytes = bytes(fullDomain);
        
        // Check .web3.club suffix
        string memory suffix = ".web3.club";
        bytes memory suffixBytes = bytes(suffix);
        
        if (domainBytes.length <= suffixBytes.length) {
            return fullDomain; // Too short to contain suffix
        }
        
        // Check if ends with .web3.club
        bool hasSuffix = true;
        for (uint i = 0; i < suffixBytes.length; i++) {
            if (domainBytes[domainBytes.length - suffixBytes.length + i] != suffixBytes[i]) {
                hasSuffix = false;
                break;
            }
        }
        
        if (hasSuffix) {
            // Remove suffix
            bytes memory prefixBytes = new bytes(domainBytes.length - suffixBytes.length);
            for (uint i = 0; i < prefixBytes.length; i++) {
                prefixBytes[i] = domainBytes[i];
            }
            return string(prefixBytes);
        } else {
            // No suffix, return directly
            return fullDomain;
        }
    }
    
    /**
     * @dev Check if domain is valid
     * @param domainName Domain to check
     * @return Whether domain is valid
     */
    function isDomainValid(string memory domainName) public pure returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        return bytes(standardized).length > 0;
    }
    
    /**
     * @dev Get standardized domain name, revert if invalid
     * @param domainName Input domain name
     * @return Standardized domain name
     */
    function getValidDomainName(string memory domainName) public pure returns (string memory) {
        string memory standardized = standardizeDomainName(domainName);
        if (bytes(standardized).length == 0) revert DomainError("Invalid domain name");
        return standardized;
    }

    function getDomainOwner(uint256 domainId) public view returns (address) {
        try nftContract.ownerOf(domainId) returns (address owner) {
            return owner;
        } catch {
            revert DomainError("Failed to get domain owner");
        }
    }

    function isDomainBound(string memory domainName) public view returns (bool) {
        return _clubs[domainName].admin != address(0);
    }

    /**
     * @dev Get domain corresponding NFT ID
     * @param domainName Domain name
     * @return Domain corresponding NFT ID, return 0 if domain name is invalid or not registered
     */
    function getDomainId(string memory domainName) public view returns (uint256) {
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) return 0;
        
        try nftContract.getTokenId(standardDomain) returns (uint256 tokenId) {
            // Check if tokenId is valid
            if (tokenId == 0) return 0;
            
            // Check if token exists and current caller is owner
            try nftContract.ownerOf(tokenId) returns (address) {
                return tokenId;
            } catch {
                return 0; // Token does not exist
            }
        } catch {
            return 0; // Contract call failed
        }
    }


        
    /**
     * @dev Validate domain, simplify error handling
     */
    function _validateDomain(string memory domainName) internal view returns (uint256 domainId, address owner) {
        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) revert DomainError("Invalid domain");
        
        // Check domain status
        try registryContract.getDomainStatus(standardDomain) returns (IWeb3ClubRegistry.DomainStatus status) {
            if (status != IWeb3ClubRegistry.DomainStatus.Active) 
                revert DomainError("Domain not active");
        } catch {
            revert DomainError("Failed to check domain status");
        }
        
        // Get TokenID
        try nftContract.getTokenId(standardDomain) returns (uint256 tokenId) {
            if (tokenId == 0) revert DomainError("Domain not found"); 
            domainId = tokenId;
        
            // Get owner
            try nftContract.ownerOf(tokenId) returns (address _owner) {
                owner = _owner;
                
                // Verify caller
                if (msg.sender != owner) revert NotDomainOwner();
                
                // Check if domain is bound to club
                if (isDomainBound(standardDomain)) revert DomainAlreadyHasClub();
                
                // Check domain expiry time
                try nftContract.getDomainInfo(standardDomain) returns (
                    IWeb3ClubNFT.DomainInfo memory domainInfo
                ) {
                    if (domainInfo.expiryTime > 0 && domainInfo.expiryTime < block.timestamp) revert DomainError("Domain expired");
                } catch {
                    revert DomainError("Failed to get domain info");
                }
                
                return (domainId, owner);
            } catch {
                revert DomainError("Failed to get owner");
            }
        } catch {
            revert DomainError("Failed to get token ID");
        }
    }

    /**
     * @dev Create club
     */
    function createClub(
        string memory domainName,
        string memory name,
        string memory symbol,
        string memory description,
        string memory logoURL,
        string memory bannerURL,
        string memory baseURI
    ) external whenNotPaused2 returns (bool) {
        // Check input domain name format
        if (bytes(domainName).length == 0) {
            revert DomainError("Empty domain name");
        }
        
        // Check required fields
        if (bytes(name).length == 0) {
            revert DomainError("Club name cannot be empty");
        }
        if (bytes(symbol).length == 0) {
            revert DomainError("Club symbol cannot be empty");
        }

        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) {
            revert DomainError("Invalid domain name");
        }
        
        // 1. Verify domain ownership
        (uint256 domainId, address owner) = _validateDomain(standardDomain);
        
        // 2. Use provided club information or generate defaults
        string memory finalBaseURI = bytes(baseURI).length > 0 ? baseURI : _generateDefaultBaseURI(standardDomain);
        
        // 3. Initialize subcontracts
        bool success = _initializeSubcontracts(standardDomain, owner, name, symbol, finalBaseURI);
        
        // 4. Update main contract state
        if (success) {
            // Initialize Club structure field
            _clubs[standardDomain].domainId = domainId;
            _clubs[standardDomain].admin = owner;
            _clubs[standardDomain].active = true;
            _clubs[standardDomain].memberCount = 0;
            _clubs[standardDomain].members = new address[](0);
            _clubs[standardDomain].adminTransferHistory = new address[](0);
            _clubs[standardDomain].adminTransferHistory.push(owner);
            
            // Store club metadata
            _clubs[standardDomain].name = name;
            _clubs[standardDomain].symbol = symbol;
            _clubs[standardDomain].description = description;
            _clubs[standardDomain].logoURL = logoURL;
            _clubs[standardDomain].bannerURL = bannerURL;
            _clubs[standardDomain].baseURI = finalBaseURI;
            
            _domainIdToName[domainId] = standardDomain;
            
            // Add user as club member
            _clubMembers[standardDomain][owner] = true;
            _userClubs[owner].push(standardDomain);
            
            emit ClubCreated(standardDomain, owner, domainId, name, symbol, description);
            emit MembershipChanged(owner, standardDomain, true);
            
            return true;
        } else {
            revert InitializationError("Subcontracts", "Initialization failed");
        }
    }



    /**
     * @dev Decide whether to inherit the membership of the previous club
     */
    function decideClubInheritance(string memory domainName, bool accept) external onlyDomainOwner(domainName) {
        string memory standardized = standardizeDomainName(domainName);
        
        DomainTransition storage transition = _domainTransitions[standardized];
        if (transition.status != DomainTransitionStatus.Pending) revert DomainError("Domain is not in pending transition");
        
        _clubs[standardized].active = true;
        transition.status = DomainTransitionStatus.Accepted;
        
        emit ClubInheritanceDecision(standardized, accept);
    }
    
    /**
     * @dev Sync contract address
     * Update NFT contract address and governance contract address from Registry contract
     */
    function syncContractsFromRegistry() external onlyOwner {
        require(address(registryContract) != address(0), "Registry contract not set");
        
        // Get NFT contract address
        address nftAddr = registryContract.nftContract();
        if (nftAddr != address(0)) {
            // Update NFT contract address
            nftContract = IWeb3ClubNFT(nftAddr);
        }
        
        // Get governance contract address
        address govAddr = registryContract.governanceContract();
        if (govAddr != address(0)) {
            // Here, governance contract address can be updated if ClubManager needs
        }
    }




    
    /**
     * @dev Record CLUB permanent membership contract address
     */
    function recordClubPassCollection(string memory domainName, address collectionAddress) external {
        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) revert DomainError("Invalid domain name");
        
        // Only allow PASS card factory to call this function
        if (msg.sender != clubPassFactory) revert NotAuthorized();
        
        // If address has already been recorded and is not zero address, do not allow changes
        if (_clubPassCollections[standardDomain] != address(0)) {
            // Keep existing address, do not change
            return;
        }
        
        _clubPassCollections[standardDomain] = collectionAddress;
        emit ClubPassCollectionRegistered(standardDomain, collectionAddress);
    }

    /**
     * @dev Get CLUB permanent membership contract address
     */
    function getClubPassCollection(string memory domainName) external view returns (address) {
        // Standardize domain name
        string memory standardDomain = standardizeDomainName(domainName);
        if (bytes(standardDomain).length == 0) return address(0);
        
        return _clubPassCollections[standardDomain];
    }




}