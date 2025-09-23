// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 验证器接口
interface IVerifier {
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[1] calldata input
    ) external view returns (bool);
}

contract ProofOfOwnership {
    // 合约拥有者
    address public owner;
    // 费用收集地址
    address public feeCollector;
    
    // 用户证明结构
    struct UserProof {
        bytes32 hash;
        uint256 remainingUses;
        uint256 timestamp;
    }
    
    // 用户证明映射
    mapping(address => UserProof) public userProofs;
    
    // 哈希到地址的映射（记录每个哈希的创建者）
    mapping(bytes32 => address) public hashDeployers;
    
    // 单次使用费用（直接以wei为单位）
    uint256 public singleUseFee;
    
    // 验证器合约
    IVerifier public immutable verifier;
    
    // 事件
    event ProofStored(address indexed user, bytes32 hash, uint256 remainingUses, uint256 totalFee);
    event ProofVerified(address indexed user, bytes32 hash, uint256 newRemainingUses);
    event SingleUseFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    
    // 错误定义
    error InvalidUsageCount();
    error InsufficientFee();
    error NoRemainingUses();
    error HashMismatch();
    error InvalidProof();
    
    // 修饰器
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    constructor(address _verifier, address _feeCollector) {
        owner = msg.sender;
        verifier = IVerifier(_verifier);
        feeCollector = _feeCollector;
        
        // 设置默认单次使用费用为0.001 ETH (1,000,000,000,000,000 wei)
        singleUseFee = 1000000000000000;
    }
    
    // 存储证明并支付费用
    // _usageCount 是普通数字，例如想购买3次验证机会，就填写3
    function storeProof(bytes32 _hash, uint256 _usageCount) external payable {
        if (_usageCount == 0) {
            revert InvalidUsageCount();
        }
        
        // 计算总费用 = 单次费用 * 使用次数
        uint256 totalFee = singleUseFee * _usageCount;
        if (msg.value < totalFee) {
            revert InsufficientFee();
        }
        
        // 如果用户已有证明，需要先清除旧证明
        if (userProofs[msg.sender].remainingUses > 0) {
            delete userProofs[msg.sender];
        }
        
        // 存储新证明
        userProofs[msg.sender] = UserProof({
            hash: _hash,
            remainingUses: _usageCount, // 直接使用输入的次数
            timestamp: block.timestamp
        });
        
        // 记录哈希的部署者（如果之前没有记录）
        if (hashDeployers[_hash] == address(0)) {
            hashDeployers[_hash] = msg.sender;
        }
        
        // 转移费用
        (bool success, ) = feeCollector.call{value: msg.value}("");
        require(success, "Fee transfer failed");
        
        emit ProofStored(msg.sender, _hash, _usageCount, totalFee);
    }
    
    // 验证证明并扣除使用次数
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[1] calldata input
    ) external returns (bool) {
        // 获取用户证明
        UserProof storage proof = userProofs[msg.sender];
        
        // 检查使用次数
        if (proof.remainingUses == 0) {
            revert NoRemainingUses();
        }
        
        // 验证哈希值
        bytes32 hasher = bytes32(input[0]);
        if (proof.hash != hasher) {
            revert HashMismatch();
        }
        
        // 验证零知识证明
        bool isValid = verifier.verifyProof(a, b, c, input);
        if (!isValid) {
            revert InvalidProof();
        }
        
        // 扣除使用次数
        proof.remainingUses--;
        
        emit ProofVerified(msg.sender, hasher, proof.remainingUses);
        
        return true;
    }
    
    // 查询剩余使用次数
    function getRemainingUses(address _user) external view returns (uint256) {
        return userProofs[_user].remainingUses;
    }
    
    // 设置单次使用费用（直接以wei为单位）
    // 例如：设置为900000000000000表示0.0009 ETH，设置为1000000000000000表示0.001 ETH
    function setSingleUseFee(uint256 _newFee) external onlyOwner {
        emit SingleUseFeeUpdated(singleUseFee, _newFee);
        singleUseFee = _newFee;
    }
    
    // 更新费用收集地址
    function setFeeCollector(address _newCollector) external onlyOwner {
        emit FeeCollectorUpdated(feeCollector, _newCollector);
        feeCollector = _newCollector;
    }
    
    // 获取用户证明信息
    function getUserProof(address _user) external view returns (
        bytes32 hash,
        uint256 remainingUses,
        uint256 timestamp
    ) {
        UserProof memory proof = userProofs[_user];
        return (proof.hash, proof.remainingUses, proof.timestamp);
    }
    
    // 计算指定次数的总费用（单位：wei）
    function calculateTotalFee(uint256 _usageCount) external view returns (uint256) {
        return singleUseFee * _usageCount;
    }
    
    // 根据哈希值查询部署者地址
    function getHashDeployer(bytes32 _hash) external view returns (address) {
        return hashDeployers[_hash];
    }
    
    // 查询指定地址部署的所有哈希值
    function isHashDeployedByUser(bytes32 _hash, address _user) external view returns (bool) {
        return hashDeployers[_hash] == _user;
    }
} 