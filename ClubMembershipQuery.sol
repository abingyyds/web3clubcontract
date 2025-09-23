// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Use named imports, only import the contract itself, avoid interface duplicate declarations
import {ClubManager} from "./ClubManager.sol";
import "./PermanentMembership.sol";
import {TemporaryMembership} from "./TemporaryMembership.sol";
import {TokenBasedAccess, IMembershipQuery} from "./TokenBasedAccess.sol";  // Import interface directly from TokenBasedAccess

// Define custom errors
error CMQNotAuthorized();
error CMQInvalidDomain(string domainName);
error CMQInvalidVerification();

enum TokenType { ERC20, ERC721, ERC1155, CROSSCHAIN }

/**
 * @title ClubMembershipQuery
 * @dev Provides query functions for club memberships
 */
contract ClubMembershipQuery {
    ClubManager private _clubManager;
    ClubPassFactory private _passFactory;
    TemporaryMembership private _tempMembership;
    TokenBasedAccess private _tokenAccess;
    
    // 跨链验证合约地址
    address public crossChainVerificationContract;
    
    // 跨链验证记录存储: domainName => user => chainId => record
    mapping(string => mapping(address => mapping(uint32 => CrossChainVerificationRecord))) private _crossChainRecords;
    
    struct MembershipStatus {
        bool isMember;
        uint256 expirationDate; // 0 indicates permanent member or token-based member
        string membershipType;  // "permanent", "temporary", "token-based"
    }
    
    struct ClubMembershipConditions {
        // Club basic information
        string clubName;
        address clubOwner;
        
        // Permanent membership information
        address permanentMembershipContract;
        bool hasPermanentMembership;
        
        // Token requirements
        address tokenAddress;
        uint256 requiredTokenAmount;
        bool isNFT;
        bool hasTokenRequirement;
        
        // Temporary membership information
        address temporaryMembershipContract;
        uint256 membershipPrice;
        uint256 quarterPrice;
        uint256 yearPrice;
        
        // 修改为数组结构
        TokenRequirement[] tokenRequirements;
    }
    
    struct TokenRequirement {
        address tokenAddress;
        uint256 requiredAmount;
        bool isNFT;
        uint8 tokenType;  // 对应TokenType枚举
        uint32 chainId;   // 修复：使用uint32而不是string
        string symbol;
    }
    
    // 跨链验证记录结构
    struct CrossChainVerificationRecord {
        address user;
        uint32 chainId;
        string tokenAddress;
        uint256 actualBalance;
        uint256 verificationTime;
        bool isActive;
    }
    
    // 事件定义
    event CrossChainVerificationRecorded(
        string indexed domainName,
        address indexed user,
        uint32 chainId,
        uint256 balance
    );
    
    event CrossChainVerificationRemoved(
        string indexed domainName,
        address indexed user,
        uint32 chainId
    );
    
    // 修饰符：仅允许跨链验证合约调用
    modifier onlyCrossChainContract() {
        if (msg.sender != crossChainVerificationContract) revert CMQNotAuthorized();
        _;
    }
    
    constructor(address clubManager) {
        _clubManager = ClubManager(clubManager);
        
        // Use getClubContracts to get contract addresses
        (address pass, address temp, address token) = ClubManager(clubManager).getClubContracts("");
        
        _passFactory = ClubPassFactory(payable(pass));
        _tempMembership = TemporaryMembership(payable(temp));
        _tokenAccess = TokenBasedAccess(token);
    }
    
    /**
     * @dev Standardize domain name format, ensure domain name is valid and format is unified
     * @param domainName Input domain name
     * @return Standardized domain name prefix
     */
    function standardizeDomainName(string memory domainName) public pure returns (string memory) {
        bytes memory domainBytes = bytes(domainName);
        
        // If empty return empty
        if (domainBytes.length == 0) return "";
        
        // Remove .web3.club suffix (if exists)
        string memory result = _removeSuffix(domainName);
        domainBytes = bytes(result);
        
        if (domainBytes.length == 0) return "";
        
        // Simple validation of characters in domain name
        for (uint i = 0; i < domainBytes.length; i++) {
            bytes1 b = domainBytes[i];
            
            // Allow a-z, 0-9, _ characters
            if (!(
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x5F                    // _
            )) {
                return ""; // Return empty to indicate invalid
            }
        }
        
        // Domain name is valid, return prefix
        return result;
    }
    
    /**
     * @dev Remove .web3.club suffix
     * @param fullDomain Full domain name that may contain suffix
     * @return Domain name prefix
     */
    function _removeSuffix(string memory fullDomain) internal pure returns (string memory) {
        bytes memory domainBytes = bytes(fullDomain);
        
        // Check .web3.club suffix
        string memory suffix = ".web3.club";
        bytes memory suffixBytes = bytes(suffix);
        
        if (domainBytes.length <= suffixBytes.length) {
            return fullDomain; // Too short to contain suffix
        }
        
        // Check if it ends with .web3.club
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
     * @dev Get CLUB's PASS card contract address through ClubPassFactory
     * @param domainName Domain name
     * @return passAddress PASS card contract address
     */
    function getClubPassAddress(string memory domainName) public view returns (address passAddress) {
        try _passFactory.getClubPassContract(domainName) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }
    
    /**
     * @dev Check user's membership status in PASS card contract
     * @param domainName Domain name
     * @param user User address
     * @return Whether is a member
     */
    function checkPassCardMembership(string memory domainName, address user) public view returns (bool) {
        address passAddr = getClubPassAddress(domainName);
        if (passAddr == address(0)) return false;
        
        try ClubPassCard(passAddr).hasMembership(user) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    
    /**
     * @dev Get all clubs a user is a member of
     * @param user Address of the user
     * @return userClubs Array of club domain names
     */
    function getUserClubs(address user) external view returns (string[] memory userClubs) {
        return _clubManager.getUserClubs(user);
    }
    
    /**
     * @dev Get all clubs joined by the user and their expiration dates
     * @param user User address
     * @return domainNames Array of club domain names
     * @return statuses Array of corresponding membership statuses
     */
    function getUserMemberships(address user) public view returns (string[] memory domainNames, MembershipStatus[] memory statuses) {
        string[] memory userClubs = _clubManager.getUserClubs(user);
        domainNames = userClubs;
        statuses = new MembershipStatus[](userClubs.length);
        
        for (uint256 i = 0; i < userClubs.length; i++) {
            (bool isClubMember, uint256 expiration, string memory memberType) = _checkMembership(user, userClubs[i]);
            statuses[i] = MembershipStatus(isClubMember, expiration, memberType);
        }
        
        return (domainNames, statuses);
    }
    
    /**
     * @dev Check user's membership status in a specific club
     * @param user User address
     * @param domainName Domain name of the club
     * @return status Membership status
     */
    function checkUserMembership(address user, string memory domainName) public view returns (MembershipStatus memory status) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) {
            return MembershipStatus(false, 0, "");
        }
        
        (bool memberStatus, uint256 expiration, string memory memberType) = _checkMembership(user, standardized);
        return MembershipStatus(memberStatus, expiration, memberType);
    }
    
    /**
     * @dev Get club membership conditions
     * @param domainName Domain name of the club
     * @return conditions Club membership conditions
     */
    function getClubMembershipConditions(string memory domainName) public view returns (ClubMembershipConditions memory conditions) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) revert CMQInvalidDomain(standardized);
        
        // Initialize return structure with default values
        conditions.clubName = standardized;
        conditions.clubOwner = _clubManager.getClubAdmin(standardized);
        
        // Get shared contracts - 只获取需要使用的两个地址
        (address perm, address temp,) = _clubManager.getClubContracts(standardized);
        
        // Permanent membership information
        address passContract = getClubPassAddress(standardized);
        conditions.permanentMembershipContract = passContract != address(0) ? passContract : perm;
        conditions.hasPermanentMembership = true;
        
        // Temporary membership information
        conditions.temporaryMembershipContract = temp;
        if (temp != address(0)) {
            conditions.membershipPrice = _tempMembership.getClubPrice(standardized);
            conditions.quarterPrice = _tempMembership.getClubQuarterPrice(standardized);
            conditions.yearPrice = _tempMembership.getClubYearPrice(standardized);
        } else {
            conditions.membershipPrice = 0;
            conditions.quarterPrice = 0;
            conditions.yearPrice = 0;
        }
        
        // Token requirements
        conditions.tokenAddress = address(0);
        conditions.requiredTokenAmount = 0;
        conditions.isNFT = false;
        conditions.hasTokenRequirement = false;
        
        // 获取总门槛数量
        uint256 gateCount = _tokenAccess.getTokenGateCount(standardized);
        
        // 创建临时数组来存储有效的TokenRequirement
        TokenRequirement[] memory tempRequirements = new TokenRequirement[](gateCount);
        uint256 validCount = 0;
        
        // 填充临时数组
        for (uint256 i = 0; i < gateCount; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address tokenAddress, 
                uint256 threshold,
                uint256, // 省略变量名
                uint8 tokenType,
                uint32 chainId,  // 修复：使用uint32
                string memory tokenSymbol,
                string memory // 省略变量名
            ) {
                // 使用索引赋值而不是push
                tempRequirements[validCount] = TokenRequirement({
                    tokenAddress: tokenAddress,
                    requiredAmount: threshold,
                    isNFT: (tokenType == 1 || tokenType == 2), // ERC721或ERC1155
                    tokenType: tokenType,
                    chainId: chainId,
                    symbol: tokenSymbol
                });
                validCount++;
            } catch {}
        }
        
        // 创建确切大小的最终数组
        conditions.tokenRequirements = new TokenRequirement[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            conditions.tokenRequirements[i] = tempRequirements[i];
        }
        
        return conditions;
    }
    
    /**
     * @dev Check detailed membership status by domain name
     * @param user User address
     * @param domainName Domain name of the club
     * @return isPermanent Whether is a permanent member
     * @return isTemporary Whether is a temporary member
     * @return isTokenBased Whether is a token-based member
     */
    function checkDetailedMembership(address user, string memory domainName) external view returns (
        bool isPermanent,
        bool isTemporary,
        bool isTokenBased,
        bool isCrossChain
    ) {
        if (!_isDomainValid(domainName)) {
            return (false, false, false, false);
        }
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Check various membership qualifications
        isPermanent = checkPassCardMembership(standardized, user);
        
        try _tempMembership.hasActiveMembership(standardized, user) returns (bool result) {
            isTemporary = result;
        } catch {}
        
        try _tokenAccess.hasActiveMembership(standardized, user) returns (bool result) {
            isTokenBased = result;
        } catch {}
        
        // Check cross-chain verification
        isCrossChain = hasCrossChainVerification(standardized, user);
        
        return (isPermanent, isTemporary, isTokenBased, isCrossChain);
    }
    
    /**
     * @dev Get membership card message signature data
     * @param user User address
     * @param domainName Domain name of the club
     * @return message Message string
     * @return signature Signature
     */
    function getMembershipMessage(address user, string memory domainName) external view returns (string memory message, bytes memory signature) {
        string memory standardized = standardizeDomainName(domainName);
        // This function will generate a membership card message and signature
        // This is just a placeholder implementation
        message = string(abi.encodePacked(
            "Web3Club Member: ", 
            standardized, 
            " - ", 
            _toAsciiString(user), 
            " at ", 
            _uint2str(block.timestamp)
        ));
        
        // Actual signature requires private key, this is not implemented
        signature = new bytes(0);
        
        return (message, signature);
    }
    
    /**
     * @dev Check if the domain is initialized
     */
    function isClubInitialized(string memory domainName) internal view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        try _clubManager.isClubInitialized(standardized) returns (bool initialized) {
            return initialized;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Return whether the user is CURRENTLY an active member (considering expiration)
     */
    function hasActiveMembership(string memory domainName, address account) public view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        
        // First case: Through independent PASS card contract
        if (checkPassCardMembership(standardized, account)) {
            return true;
        }
        
        // Second case: Through temporary membership contract - MODIFIED
        try _tempMembership.isMembershipActive(standardized, account) returns (bool result) {
            if (result) return true;
        } catch {
            // Error handling: Continue to check other contracts  
        }
        
        // Third case: Through token access contract
        try _tokenAccess.hasActiveMembership(standardized, account) returns (bool result) {
            if (result) return true;
        } catch {
            // Error handling: Continue
        }
        
        // Fourth case: Through cross-chain verification
        if (hasCrossChainVerification(standardized, account)) {
            return true;
        }
        
        return false;
    }
    
    /**
     * @dev 检查是否为俱乐部成员（总判定）
     */
    function isMember(string memory domainName, address account) external view returns (bool) {
        return hasActiveMembership(domainName, account);
    }
    
    /**
     * @dev 检查是否为永久会员
     */
    function isPermanentMember(string memory domainName, address user) external view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        return checkPassCardMembership(standardized, user);
    }
    
    /**
     * @dev 检查是否为临时会员
     */
    function isTemporaryMember(string memory domainName, address user) external view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        
        try _tempMembership.isMembershipActive(standardized, user) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev 检查是否为本链代币会员
     */
    function isTokenBasedMember(string memory domainName, address user) external view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        
        try _tokenAccess.hasActiveMembership(standardized, user) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev 检查是否为跨链会员
     */
    function isCrossChainMember(string memory domainName, address user) external view returns (bool) {
        return hasCrossChainVerification(domainName, user);
    }
    
    // ===== Internal Helper Functions =====
    
    /**
     * @dev Check if the domain is valid
     */
    function _isDomainValid(string memory domainName) internal view returns (bool) {
        if (bytes(domainName).length == 0) return false;
        
        string memory standardized = standardizeDomainName(domainName);
        try _clubManager.isClubInitialized(standardized) returns (bool initialized) {
            return initialized;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Internal function to check membership status
     * @param user User address
     * @param domainName Domain name of the club
     * @return memberStatus Whether is a member that is CURRENTLY ACTIVE
     * @return expirationDate Expiration date (0 indicates permanent or token-based)
     * @return membershipType Membership type
     */
    function _checkMembership(address user, string memory domainName) internal view returns (bool memberStatus, uint256 expirationDate, string memory membershipType) {
        string memory standardized = standardizeDomainName(domainName);
        bool isPermanent = false;
        bool isTokenBased = false;
        uint256 expiry = 0;
        
        // Check PASS card membership qualification
        isPermanent = checkPassCardMembership(standardized, user);
        if (isPermanent) {
            membershipType = "permanent";
            return (true, 0, membershipType);
        }
        
        // Check temporary membership - MODIFIED
        try _tempMembership.isMembershipActive(standardized, user) returns (bool active) {
            // 使用isMembershipActive检查是否临时会员且在有效期内
            if (active) {
                try _tempMembership.getMembershipExpiry(standardized, user) returns (uint256 _expiry) {
                    expiry = _expiry;
                } catch {}
                membershipType = "temporary";
                return (true, expiry, membershipType);
            } else {
                // 如果不活跃但曾是会员，获取过期时间用于显示
                try _tempMembership.hasMembership(standardized, user) returns (bool wasMember) {
                    if (wasMember) {
                        try _tempMembership.getMembershipExpiry(standardized, user) returns (uint256 _expiry) {
                            expiry = _expiry;
                        } catch {}
                        membershipType = "temporary-expired";
                        return (false, expiry, membershipType); // 这里返回false表示不再活跃
                    }
                } catch {}
            }
        } catch {}
        
        // Check token holdings
        try _tokenAccess.hasActiveMembership(standardized, user) returns (bool result) {
            isTokenBased = result;
            if (isTokenBased) {
                membershipType = "token-based";
                return (true, 0, membershipType);
            }
        } catch {}
        
        // Check cross-chain verification
        if (hasCrossChainVerification(standardized, user)) {
            membershipType = "cross-chain";
            return (true, 0, membershipType);
        }
        
        return (false, 0, "");
    }
    
    /**
     * @dev Convert uint to string
     */
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        
        uint256 j = _i;
        uint256 length;
        
        while (j != 0) {
            length++;
            j /= 10;
        }
        
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        
        return string(bstr);
    }
    
    /**
     * @dev Convert address to ASCII string
     */
    function _toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint(uint160(x)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = _char(hi);
            s[2*i+1] = _char(lo);            
        }
        return string(abi.encodePacked("0x", s));
    }
    
    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }
    
    /**
     * @dev 将address转换为字符串
     */
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
    
    // ===== 跨链验证功能 =====
    
    /**
     * @dev 设置跨链验证合约地址（仅管理员）
     * @param _crossChainContract 跨链验证合约地址
     */
    function setCrossChainVerificationContract(address _crossChainContract) external {
        // 检查权限：仅ClubManager的owner可以调用
        if (msg.sender != _clubManager.owner()) revert CMQNotAuthorized();
        if (_crossChainContract == address(0)) revert CMQInvalidVerification();
        
        crossChainVerificationContract = _crossChainContract;
    }
    
    /**
     * @dev 记录跨链验证结果（仅跨链验证合约可调用）
     * @param domainName 俱乐部域名
     * @param user 用户地址
     * @param chainId 链ID
     * @param tokenAddress 代币地址
     * @param balance 实际余额
     * @param verificationTime 验证时间
     */
    function recordCrossChainVerification(
        string memory domainName,
        address user,
        uint32 chainId,
        address tokenAddress,
        uint256 balance,
        uint256 verificationTime
    ) external onlyCrossChainContract {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) revert CMQInvalidDomain(standardized);
        if (user == address(0)) revert CMQInvalidVerification();
        
        // Query自己判断是否符合门槛
        uint256 gateCount = _tokenAccess.getTokenGateCount(standardized);
        bool shouldHaveAccess = false;
        
        for (uint256 i = 0; i < gateCount; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address,
                uint256 threshold,
                uint256,
                uint8 tokenType,
                uint32 gateChainId,
                string memory,
                string memory crossChainAddress
            ) {
                // 检查是否为匹配的跨链门槛
                if (tokenType == uint8(TokenType.CROSSCHAIN) && gateChainId == chainId) {
                    // 检查地址匹配
                    string memory tokenAddressStr = _addressToString(tokenAddress);
                    bool addressMatch = _compareStringsIgnoreCase(tokenAddressStr, crossChainAddress);
                    
                    // 检查余额是否满足门槛
                    if (addressMatch && balance >= threshold) {
                        shouldHaveAccess = true;
                        break;
                    }
                }
            } catch {}
        }
        
        if (shouldHaveAccess) {
            // 符合门槛，记录验证结果
            _crossChainRecords[standardized][user][chainId] = CrossChainVerificationRecord({
                user: user,
                chainId: chainId,
                tokenAddress: _addressToString(tokenAddress),
                actualBalance: balance,
                verificationTime: verificationTime,
                isActive: true
            });
            emit CrossChainVerificationRecorded(standardized, user, chainId, balance);
        } else {
            // 不符合门槛，删除记录（清理内存）
            delete _crossChainRecords[standardized][user][chainId];
            emit CrossChainVerificationRemoved(standardized, user, chainId);
        }
    }
    
    
    /**
     * @dev 移除跨链验证记录（仅跨链验证合约可调用）
     * @param domainName 俱乐部域名
     * @param user 用户地址
     * @param chainId 链ID
     */
    function removeCrossChainVerification(
        string memory domainName,
        address user,
        uint32 chainId
    ) external onlyCrossChainContract {
        string memory standardized = standardizeDomainName(domainName);
        
        // 删除验证记录
        delete _crossChainRecords[standardized][user][chainId];
        
        emit CrossChainVerificationRemoved(standardized, user, chainId);
    }
    
    /**
     * @dev 检查用户是否有有效的跨链验证
     * @param domainName 俱乐部域名
     * @param user 用户地址
     * @return 是否有有效的跨链验证
     */
    function hasCrossChainVerification(string memory domainName, address user) public view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        
        // 获取该俱乐部的跨链代币门槛
        uint256 gateCount = _tokenAccess.getTokenGateCount(standardized);
        
        for (uint256 i = 0; i < gateCount; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address,
                uint256 threshold,
                uint256,
                uint8 tokenType,
                uint32 chainId,
                string memory,
                string memory crossChainAddress
            ) {
                // 只检查跨链代币（使用枚举值而不是硬编码）
                if (tokenType == uint8(TokenType.CROSSCHAIN)) {
                    // 使用门槛中的chainId查询对应的验证记录
                    CrossChainVerificationRecord memory record = _crossChainRecords[standardized][user][chainId];
                    
                    // 检查记录是否存在且活跃
                    if (record.isActive && record.user != address(0)) {
                        // 检查地址是否匹配（忽略大小写）
                        bool addressMatch = _compareStringsIgnoreCase(record.tokenAddress, crossChainAddress);
                        
                        // 检查地址匹配且余额满足门槛
                        if (addressMatch && record.actualBalance >= threshold) {
                            return true;
                        }
                    }
                }
            } catch {
                // 静默忽略错误，继续下一个门槛
            }
        }
        
        return false;
    }
    
    /**
     * @dev 获取用户的跨链验证详情
     * @param domainName 俱乐部域名
     * @param user 用户地址
     * @param chainId 链ID
     * @return 验证记录
     */
    function getCrossChainVerificationRecord(
        string memory domainName,
        address user,
        uint32 chainId
    ) external view returns (CrossChainVerificationRecord memory) {
        string memory standardized = standardizeDomainName(domainName);
        return _crossChainRecords[standardized][user][chainId];
    }
    
    /**
     * @dev 获取用户所有的跨链验证记录
     * @param domainName 俱乐部域名
     * @param user 用户地址
     * @return chainIds 链ID数组
     * @return records 对应的验证记录数组
     */
    function getAllCrossChainVerifications(
        string memory domainName,
        address user
    ) external view returns (uint32[] memory chainIds, CrossChainVerificationRecord[] memory records) {
        return _getAllCrossChainVerificationsInternal(domainName, user);
    }
    
    /**
     * @dev 内部函数：获取用户所有的跨链验证记录（减少Stack深度）
     */
    function _getAllCrossChainVerificationsInternal(
        string memory domainName,
        address user
    ) internal view returns (uint32[] memory, CrossChainVerificationRecord[] memory) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) {
            return (new uint32[](0), new CrossChainVerificationRecord[](0));
        }
        
        return _processGateRecords(standardized, user);
    }
    
    /**
     * @dev 处理门槛记录（进一步拆分函数）
     */
    function _processGateRecords(
        string memory standardized,
        address user
    ) internal view returns (uint32[] memory chainIds, CrossChainVerificationRecord[] memory records) {
        uint256 gateCount = _tokenAccess.getTokenGateCount(standardized);
        
        // 第一步：计算有效记录数量
        uint256 validCount = _countValidRecords(standardized, user, gateCount);
        
        // 第二步：创建结果数组
        chainIds = new uint32[](validCount);
        records = new CrossChainVerificationRecord[](validCount);
        
        // 第三步：填充数组
        _fillResultArrays(standardized, user, gateCount, chainIds, records);
        
        return (chainIds, records);
    }
    
    /**
     * @dev 计算有效记录数量
     */
    function _countValidRecords(
        string memory standardized,
        address user,
        uint256 gateCount
    ) internal view returns (uint256 count) {
        for (uint256 i = 0; i < gateCount; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address, uint256, uint256, uint8 tokenType, uint32 chainId, string memory, string memory
            ) {
                if (tokenType == 3 && _crossChainRecords[standardized][user][chainId].user != address(0)) {
                    count++;
                }
            } catch {}
        }
    }
    
    /**
     * @dev 填充结果数组
     */
    function _fillResultArrays(
        string memory standardized,
        address user,
        uint256 gateCount,
        uint32[] memory chainIds,
        CrossChainVerificationRecord[] memory records
    ) internal view {
        uint256 index = 0;
        for (uint256 i = 0; i < gateCount && index < chainIds.length; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address, uint256, uint256, uint8 tokenType, uint32 chainId, string memory, string memory
            ) {
                if (tokenType == 3) {
                    CrossChainVerificationRecord storage record = _crossChainRecords[standardized][user][chainId];
                    if (record.user != address(0)) {
                        chainIds[index] = chainId;
                        records[index] = record;
                        index++;
                    }
                }
            } catch {}
        }
    }
    
    /**
     * @dev 忽略大小写比较字符串
     */
    function _compareStringsIgnoreCase(string memory a, string memory b) internal pure returns (bool) {
        bytes memory aBytes = bytes(a);
        bytes memory bBytes = bytes(b);
        
        if (aBytes.length != bBytes.length) return false;
        
        for (uint i = 0; i < aBytes.length; i++) {
            bytes1 aChar = aBytes[i];
            bytes1 bChar = bBytes[i];
            
            // 转换为小写比较
            if (aChar >= 0x41 && aChar <= 0x5A) aChar = bytes1(uint8(aChar) + 32); // A-Z -> a-z
            if (bChar >= 0x41 && bChar <= 0x5A) bChar = bytes1(uint8(bChar) + 32); // A-Z -> a-z
            
            if (aChar != bChar) return false;
        }
        
        return true;
    }
} 