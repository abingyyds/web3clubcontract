// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// 简化的错误定义
error InvalidInput();
error Unauthorized();
error ContractPaused();
error InsufficientFee();

// 简化的接口
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
 * @dev 简化的跨链验证合约 - 只保留核心功能
 */
contract SimpleCrossChainVerification is Ownable, Pausable {
    
    // 合约地址
    address public membershipQueryContract;
    address public tokenAccessContract;
    address public clubManagerContract;
    
    // 机器人地址映射
    mapping(address => bool) public authorizedBots;
    
    // 费用机制
    uint256 public verificationFee = 0.001 ether;
    address public feeRecipient;
    bool public feeEnabled = true;
    
    // 简化的事件
    event VerificationRequested(
        address indexed user,
        string domainName,          // 移除indexed，保持原始字符串
        uint32 indexed chainId,
        address tokenAddress,
        string requestId
    );
    
    event VerificationCompleted(
        address indexed user,
        string domainName,          // 移除indexed，保持原始字符串
        uint32 indexed chainId,
        bool success,
        uint256 balance,
        uint256 threshold
    );
    
    event BotAuthorized(address indexed bot, bool authorized);
    event FeeUpdated(uint256 newFee    );
    
    // 调试事件
    event VerificationDebug(
        address indexed user,
        string domainName,
        uint32 chainId,
        address tokenAddress,
        uint256 balance,
        string message
    );
    
    // 批量检查事件
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
    
    // ===== 管理员功能 =====
    
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
    
    // ===== 核心功能：用户验证请求 =====
    
    /**
     * @dev 用户发起跨链验证请求 - 核心功能
     * @param domainName 俱乐部名称
     * @param chainId 要验证的链ID
     * @param tokenAddress 要验证的代币地址
     */
    function requestVerification(
        string memory domainName,
        uint32 chainId,
        address tokenAddress
    ) external payable whenNotPaused2 {
        if (bytes(domainName).length == 0 || chainId == 0) revert InvalidInput();
        
        // 检查费用
        if (feeEnabled && msg.value < verificationFee) revert InsufficientFee();
        
        // 转账费用
        if (feeEnabled && verificationFee > 0) {
            (bool success,) = feeRecipient.call{value: verificationFee}("");
            require(success, "Fee transfer failed");
            
            // 退还多余费用
            if (msg.value > verificationFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - verificationFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        // 检查俱乐部是否存在
        (bool initialized,) = ITokenBasedAccess(tokenAccessContract).isClubInitialized(domainName);
        if (!initialized) revert InvalidInput();
        
        // 发布事件供机器人监听
        emit VerificationRequested(msg.sender, domainName, chainId, tokenAddress, "");
    }
    
    // ===== 机器人功能：处理验证 =====
    
    /**
     * @dev 机器人处理验证请求 - 核心功能
     * @param user 用户地址
     * @param domainName 俱乐部名称
     * @param chainId 链ID
     * @param tokenAddress 代币地址
     * @param actualBalance 查询到的实际余额
     */
    function processVerification(
        address user,
        string memory domainName,
        uint32 chainId,
        address tokenAddress,
        uint256 actualBalance
    ) external onlyAuthorizedBot whenNotPaused2 {
        
        // Cross合约不做判断，直接把数据传给Query让Query判断
        emit VerificationDebug(user, domainName, chainId, tokenAddress, actualBalance, "Sending data to Query");
        
        // 调用Query合约记录验证数据（让Query自己判断是否符合门槛）
        IClubMembershipQuery(membershipQueryContract).recordCrossChainVerification(
            domainName,
            user,
            chainId,
            tokenAddress,
            actualBalance,
            block.timestamp
        );
        
        emit VerificationDebug(user, domainName, chainId, tokenAddress, actualBalance, "Data sent to Query");
        
        // 发布验证完成事件
        emit VerificationCompleted(user, domainName, chainId, true, actualBalance, 0);
    }
    
    // ===== 查询功能 =====
    
    function getVerificationFeeInfo() external view returns (uint256 fee, address recipient, bool enabled) {
        return (verificationFee, feeRecipient, feeEnabled);
    }
    
    /**
     * @dev 获取合约配置状态 - 调试用
     * @return membershipQuery ClubMembershipQuery合约地址
     * @return tokenAccess TokenBasedAccess合约地址
     */
    function getContractAddresses() external view returns (address membershipQuery, address tokenAccess) {
        return (membershipQueryContract, tokenAccessContract);
    }
    
    function isSupportedChainId(uint32 chainId) public pure returns (bool) {
        return chainId == 1 || chainId == 137 || chainId == 56 || chainId == 42161 || 
               chainId == 10 || chainId == 43114 || chainId == 11155111 || chainId == 80001;
    }
    
    
    /**
     * @dev 查询俱乐部的跨链代币门槛 - 帮助调试合约调用
     * @param domainName 俱乐部名称
     * @return chainIds 链ID数组
     * @return tokenAddresses 代币地址数组
     * @return crossChainAddresses 跨链地址数组
     * @return thresholds 门槛数组
     * @return symbols 代币符号数组
     */
    function getClubCrossChainRequirements(string memory domainName) external view returns (
        uint32[] memory chainIds,
        address[] memory tokenAddresses,
        string[] memory crossChainAddresses,
        uint256[] memory thresholds,
        string[] memory symbols
    ) {
        // 调用TokenBasedAccess获取门槛
        (
            address[] memory allTokenAddresses,
            uint256[] memory allThresholds,
            ,
            uint8[] memory tokenTypes,
            uint32[] memory allChainIds,
            string[] memory tokenSymbols,
            string[] memory allCrossChainAddresses
        ) = ITokenBasedAccess(tokenAccessContract).getTokenGates(domainName);
        
        // 统计跨链代币数量
        uint256 crossChainCount = 0;
        for (uint256 i = 0; i < tokenTypes.length; i++) {
            if (tokenTypes[i] == 3) { // CROSSCHAIN type
                crossChainCount++;
            }
        }
        
        // 创建结果数组
        chainIds = new uint32[](crossChainCount);
        tokenAddresses = new address[](crossChainCount);
        crossChainAddresses = new string[](crossChainCount);
        thresholds = new uint256[](crossChainCount);
        symbols = new string[](crossChainCount);
        
        // 填充结果
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
     * @dev 俱乐部管理员批量检查指定成员的跨链资格
     * @param domainName 俱乐部名称
     * @param members 要检查的成员地址数组
     */
    function batchCheckMembers(
        string memory domainName,
        address[] memory members
    ) external payable {
        // 检查俱乐部是否存在
        (bool initialized,) = ITokenBasedAccess(tokenAccessContract).isClubInitialized(domainName);
        if (!initialized) revert InvalidInput();
        
        // 权限检查：只有俱乐部管理员可以调用
        (, address clubAdmin,,,) = IClubManager(clubManagerContract).getClub(domainName);
        require(msg.sender == clubAdmin, "Only club admin can batch check");
        
        // 计算批量检查费用（自动计算成员数量*费用）
        uint256 totalFee = verificationFee * members.length;
        
        // 检查费用
        if (feeEnabled && msg.value < totalFee) revert InsufficientFee();
        
        // 转账费用
        if (feeEnabled && totalFee > 0) {
            (bool success,) = feeRecipient.call{value: totalFee}("");
            require(success, "Fee transfer failed");
            
            // 退还多余费用
            if (msg.value > totalFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - totalFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        // 发出批量检查事件，机器人监听并处理
        for (uint256 i = 0; i < members.length; i++) {
            emit BatchCheckRequested(members[i], domainName);
        }
    }
    
    /**
     * @dev 计算批量检查费用
     * @param memberCount 成员数量
     * @return totalFee 总费用
     */
    function calculateBatchFee(uint256 memberCount) external view returns (uint256 totalFee) {
        return verificationFee * memberCount;
    }
    
    /**
     * @dev 俱乐部管理员批量检查所有跨链成员
     * @param domainName 俱乐部名称
     */
    function batchCheckAllMembers(string memory domainName) external payable {
        // 权限检查：只有俱乐部管理员可以调用
        (, address clubAdmin,,,) = IClubManager(clubManagerContract).getClub(domainName);
        require(msg.sender == clubAdmin, "Only club admin can batch check");
        
        // 从ClubManager获取所有成员
        (,,,, address[] memory allMembers) = IClubManager(clubManagerContract).getClub(domainName);
        
        // 统计有跨链记录的成员数量
        uint256 crossChainCount = 0;
        for (uint256 i = 0; i < allMembers.length; i++) {
            try IClubMembershipQuery(membershipQueryContract).hasCrossChainVerification(domainName, allMembers[i]) returns (bool hasRecord) {
                if (hasRecord) {
                    crossChainCount++;
                }
            } catch {}
        }
        
        // 计算费用：只对有跨链记录的成员收费
        uint256 totalFee = verificationFee * crossChainCount;
        
        // 必须支付费用
        if (feeEnabled && msg.value < totalFee) revert InsufficientFee();
        
        // 转账费用给feeRecipient（不是机器人）
        if (feeEnabled && totalFee > 0) {
            (bool success,) = feeRecipient.call{value: totalFee}("");
            require(success, "Fee transfer failed");
            
            // 退还多余费用
            if (msg.value > totalFee) {
                (bool refundSuccess,) = msg.sender.call{value: msg.value - totalFee}("");
                require(refundSuccess, "Refund failed");
            }
        }
        
        // 只对有跨链记录的成员发出检查事件
        for (uint256 i = 0; i < allMembers.length; i++) {
            try IClubMembershipQuery(membershipQueryContract).hasCrossChainVerification(domainName, allMembers[i]) returns (bool hasRecord) {
                if (hasRecord) {
                    emit BatchCheckRequested(allMembers[i], domainName);
                }
            } catch {}
        }
    }
    
    // ===== 内部函数 =====
    
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
        // 转换为小写后比较
        return keccak256(abi.encodePacked(_toLowerCase(a))) == keccak256(abi.encodePacked(_toLowerCase(b)));
    }
    
    /**
     * @dev 将字符串转换为小写
     */
    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        
        for (uint i = 0; i < bStr.length; i++) {
            // 如果是大写字母A-F，转换为小写
            if (bStr[i] >= 0x41 && bStr[i] <= 0x46) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        
        return string(bLower);
    }
    
}
