// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Verifier interface
interface IVerifier {
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[1] calldata input
    ) external view returns (bool);
}

contract ProofOfOwnership {
    // Contract owner
    address public owner;
    // Fee collection address
    address public feeCollector;
    
    // User proof structure
    struct UserProof {
        bytes32 hash;
        uint256 remainingUses;
        uint256 timestamp;
    }
    
    // User proof mapping
    mapping(address => UserProof) public userProofs;
    
    // Hash to address mapping (records the creator of each hash)
    mapping(bytes32 => address) public hashDeployers;
    
    // Hash activation status mapping (controlled by hash deployer)
    mapping(bytes32 => bool) public hashActiveStatus;
    
    // Single use fee (directly in wei)
    uint256 public singleUseFee;
    
    // Verifier contract
    IVerifier public immutable verifier;
    
    // Events
    event ProofStored(address indexed user, bytes32 hash, uint256 remainingUses, uint256 totalFee);
    event ProofVerified(address indexed user, bytes32 hash, uint256 newRemainingUses);
    event SingleUseFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event AuthorizationStatusChanged(address indexed user, bytes32 hash, bool isActive);
    
    // Error definitions
    error InvalidUsageCount();
    error InsufficientFee();
    error NoRemainingUses();
    error HashMismatch();
    error InvalidProof();
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    constructor(address _verifier, address _feeCollector) {
        owner = msg.sender;
        verifier = IVerifier(_verifier);
        feeCollector = _feeCollector;
        
        // Set default single use fee to 0.001 ETH (1,000,000,000,000,000 wei)
        singleUseFee = 1000000000000000;
    }
    
    // Store proof and pay fee
    // _usageCount is a regular number, for example, if you want to buy 3 verification opportunities, fill in 3
    function storeProof(bytes32 _hash, uint256 _usageCount) external payable {
        if (_usageCount == 0) {
            revert InvalidUsageCount();
        }
        
        // Calculate total fee = single fee * usage count
        uint256 totalFee = singleUseFee * _usageCount;
        if (msg.value < totalFee) {
            revert InsufficientFee();
        }
        
        // If user already has proof, need to clear old proof first
        if (userProofs[msg.sender].remainingUses > 0) {
            delete userProofs[msg.sender];
        }
        
        // Store new proof
        userProofs[msg.sender] = UserProof({
            hash: _hash,
            remainingUses: _usageCount, // Directly use the input count
            timestamp: block.timestamp
        });
        
        // Record the deployer of the hash (if not recorded before)
        if (hashDeployers[_hash] == address(0)) {
            hashDeployers[_hash] = msg.sender;
            hashActiveStatus[_hash] = true; // Default to active when first deployed
        }
        
        // Transfer fee
        (bool success, ) = feeCollector.call{value: msg.value}("");
        require(success, "Fee transfer failed");
        
        emit ProofStored(msg.sender, _hash, _usageCount, totalFee);
    }
    
    // Verify proof and deduct usage count, returns hash deployer address and verification result
    function verifyProof(
        uint[2] calldata a,
        uint[2][2] calldata b,
        uint[2] calldata c,
        uint[1] calldata input
    ) external returns (address hashDeployer, bool isValid) {
        // Get user proof
        UserProof storage proof = userProofs[msg.sender];
        
        // Check usage count
        if (proof.remainingUses == 0) {
            revert NoRemainingUses();
        }
        
        // Verify hash value
        bytes32 hasher = bytes32(input[0]);
        if (proof.hash != hasher) {
            revert HashMismatch();
        }
        
        // Check if hash is active (controlled by hash deployer)
        if (!hashActiveStatus[hasher]) {
            revert InvalidProof();
        }
        
        // Verify zero-knowledge proof
        bool proofValid = verifier.verifyProof(a, b, c, input);
        if (!proofValid) {
            revert InvalidProof();
        }
        
        // Deduct usage count
        proof.remainingUses--;
        
        emit ProofVerified(msg.sender, hasher, proof.remainingUses);
        
        // Return hash deployer address
        return (hashDeployers[hasher], true);
    }
    
    // Query remaining usage count
    function getRemainingUses(address _user) external view returns (uint256) {
        return userProofs[_user].remainingUses;
    }
    
    // Set single use fee (directly in wei)
    // For example: setting to 900000000000000 represents 0.0009 ETH, setting to 1000000000000000 represents 0.001 ETH
    function setSingleUseFee(uint256 _newFee) external onlyOwner {
        emit SingleUseFeeUpdated(singleUseFee, _newFee);
        singleUseFee = _newFee;
    }
    
    // Update fee collection address
    function setFeeCollector(address _newCollector) external onlyOwner {
        emit FeeCollectorUpdated(feeCollector, _newCollector);
        feeCollector = _newCollector;
    }
    
    // Get user proof information
    function getUserProof(address _user) external view returns (
        bytes32 hash,
        uint256 remainingUses,
        uint256 timestamp
    ) {
        UserProof memory proof = userProofs[_user];
        return (proof.hash, proof.remainingUses, proof.timestamp);
    }
    
    // Hash deployer controls the validity of their hash
    function setHashActive(bytes32 _hash, bool _isActive) external {
        require(hashDeployers[_hash] == msg.sender, "Only hash deployer can control this hash");
        
        hashActiveStatus[_hash] = _isActive;
        
        emit AuthorizationStatusChanged(msg.sender, _hash, _isActive);
    }
    
    // Calculate total fee for specified count (unit: wei)
    function calculateTotalFee(uint256 _usageCount) external view returns (uint256) {
        return singleUseFee * _usageCount;
    }
    
    // Query deployer address by hash value
    function getHashDeployer(bytes32 _hash) external view returns (address) {
        return hashDeployers[_hash];
    }
    
    // Query all hash values deployed by specified address
    function isHashDeployedByUser(bytes32 _hash, address _user) external view returns (bool) {
        return hashDeployers[_hash] == _user;
    }
    
    // For DAPP developers: Check if a hash is active and get its information
    function getHashStatus(bytes32 _hash) external view returns (
        bool isActive,
        address deployer,
        bool exists
    ) {
        address hashDeployer = hashDeployers[_hash];
        bool hashExists = hashDeployer != address(0);
        
        return (
            hashActiveStatus[_hash],
            hashDeployer,
            hashExists
        );
    }
} 