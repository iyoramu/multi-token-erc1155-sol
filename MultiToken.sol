// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Advanced Multi-Token ERC-1155 Contract
 * @dev Combines fungible and non-fungible tokens with modern features
 */
contract MultiToken is ERC1155, Ownable, ERC1155Supply, ERC1155URIStorage, ReentrancyGuard {
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using Counters for Counters.Counter;

    // Token types
    enum TokenType { FUNGIBLE, NON_FUNGIBLE }

    // Token details
    struct TokenInfo {
        TokenType tokenType;
        uint256 maxSupply; // 0 for unlimited
        uint256 mintPrice;
        bool transferable;
        bool burnable;
        string name;
        string symbol;
    }

    // NFT Collection details
    struct CollectionInfo {
        string name;
        string symbol;
        string contractURI;
    }

    // State variables
    mapping(uint256 => TokenInfo) private _tokenInfo;
    mapping(uint256 => bytes32) private _merkleRoots;
    mapping(uint256 => mapping(address => bool)) private _whitelistClaimed;
    mapping(address => EnumerableSet.UintSet) private _holderTokens;
    mapping(uint256 => address) private _creators;
    mapping(uint256 => uint256) private _royaltyBps; // Basis points (1/100th of a percent)

    Counters.Counter private _tokenIdCounter;
    CollectionInfo private _collectionInfo;
    string private _baseURI;
    address private _royaltyRecipient;
    uint256 private _maxBatchSize = 20;

    // Events
    event TokenCreated(
        uint256 indexed tokenId,
        TokenType tokenType,
        string name,
        string symbol,
        uint256 maxSupply
    );
    event TokensMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 amount
    );
    event WhitelistMerkleRootSet(uint256 indexed tokenId, bytes32 merkleRoot);
    event RoyaltyInfoUpdated(uint256 indexed tokenId, address recipient, uint256 bps);
    event BatchSizeUpdated(uint256 newMaxBatchSize);

    constructor(
        string memory name,
        string memory symbol,
        string memory contractURI_,
        string memory baseURI_,
        address initialOwner
    ) ERC1155(baseURI_) Ownable(initialOwner) {
        _collectionInfo = CollectionInfo(name, symbol, contractURI_);
        _baseURI = baseURI_;
        _royaltyRecipient = initialOwner;
    }

    // Modifiers
    modifier validToken(uint256 tokenId) {
        require(_tokenInfo[tokenId].tokenType != TokenType(0), "Token does not exist");
        _;
    }

    modifier onlyTokenCreator(uint256 tokenId) {
        require(_creators[tokenId] == msg.sender || owner() == msg.sender, "Not token creator");
        _;
    }

    // Token management functions
    function createToken(
        TokenType tokenType,
        string memory name,
        string memory symbol,
        uint256 maxSupply,
        uint256 mintPrice,
        bool transferable,
        bool burnable,
        string memory tokenURI
    ) external onlyOwner returns (uint256) {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();

        _tokenInfo[tokenId] = TokenInfo({
            tokenType: tokenType,
            maxSupply: maxSupply,
            mintPrice: mintPrice,
            transferable: transferable,
            burnable: burnable,
            name: name,
            symbol: symbol
        });

        _creators[tokenId] = msg.sender;

        if (bytes(tokenURI).length > 0) {
            _setURI(tokenId, tokenURI);
        }

        emit TokenCreated(tokenId, tokenType, name, symbol, maxSupply);
        return tokenId;
    }

    function mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory data
    ) external payable validToken(tokenId) nonReentrant {
        TokenInfo memory token = _tokenInfo[tokenId];
        
        require(token.tokenType == TokenType.FUNGIBLE, "Use mintNFT for non-fungible tokens");
        require(msg.value >= token.mintPrice * amount, "Insufficient payment");
        
        if (token.maxSupply > 0) {
            require(totalSupply(tokenId) + amount <= token.maxSupply, "Exceeds max supply");
        }

        _mint(to, tokenId, amount, data);
        _holderTokens[to].add(tokenId);
        
        emit TokensMinted(to, tokenId, amount);
    }

    function mintNFT(
        address to,
        uint256 tokenId,
        string memory tokenURI,
        bytes memory data
    ) external payable validToken(tokenId) nonReentrant {
        TokenInfo memory token = _tokenInfo[tokenId];
        
        require(token.tokenType == TokenType.NON_FUNGIBLE, "Use mint for fungible tokens");
        require(msg.value >= token.mintPrice, "Insufficient payment");
        
        if (token.maxSupply > 0) {
            require(totalSupply(tokenId) + 1 <= token.maxSupply, "Exceeds max supply");
        }

        _mint(to, tokenId, 1, data);
        _holderTokens[to].add(tokenId);
        
        if (bytes(tokenURI).length > 0) {
            _setURI(tokenId, tokenURI);
        }
        
        emit TokensMinted(to, tokenId, 1);
    }

    function mintBatch(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bytes memory data
    ) external payable nonReentrant {
        require(tokenIds.length == amounts.length, "Length mismatch");
        require(tokenIds.length <= _maxBatchSize, "Exceeds max batch size");

        uint256 totalPrice = 0;
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            TokenInfo memory token = _tokenInfo[tokenId];
            
            require(token.tokenType == TokenType.FUNGIBLE, "Use mintNFT for non-fungible tokens");
            totalPrice += token.mintPrice * amounts[i];
            
            if (token.maxSupply > 0) {
                require(totalSupply(tokenId) + amounts[i] <= token.maxSupply, "Exceeds max supply");
            }
        }
        
        require(msg.value >= totalPrice, "Insufficient payment");
        
        _mintBatch(to, tokenIds, amounts, data);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _holderTokens[to].add(tokenIds[i]);
            emit TokensMinted(to, tokenIds[i], amounts[i]);
        }
    }

    // Whitelist functions
    function setWhitelistMerkleRoot(uint256 tokenId, bytes32 merkleRoot) external onlyOwner validToken(tokenId) {
        _merkleRoots[tokenId] = merkleRoot;
        emit WhitelistMerkleRootSet(tokenId, merkleRoot);
    }

    function mintWhitelist(
        uint256 tokenId,
        uint256 amount,
        bytes32[] calldata merkleProof,
        bytes memory data
    ) external payable validToken(tokenId) nonReentrant {
        TokenInfo memory token = _tokenInfo[tokenId];
        
        require(_merkleRoots[tokenId] != bytes32(0), "Whitelist not enabled");
        require(!_whitelistClaimed[tokenId][msg.sender], "Already claimed");
        require(msg.value >= token.mintPrice * amount, "Insufficient payment");
        
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(merkleProof, _merkleRoots[tokenId], leaf), "Invalid proof");

        if (token.maxSupply > 0) {
            require(totalSupply(tokenId) + amount <= token.maxSupply, "Exceeds max supply");
        }

        _whitelistClaimed[tokenId][msg.sender] = true;
        _mint(msg.sender, tokenId, amount, data);
        _holderTokens[msg.sender].add(tokenId);
        
        emit TokensMinted(msg.sender, tokenId, amount);
    }

    // Royalty functions
    function setRoyaltyInfo(
        uint256 tokenId,
        address recipient,
        uint256 bps
    ) external onlyTokenCreator(tokenId) {
        require(bps <= 10000, "Royalty exceeds 100%");
        _royaltyBps[tokenId] = bps;
        _royaltyRecipient = recipient;
        emit RoyaltyInfoUpdated(tokenId, recipient, bps);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        validToken(tokenId)
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = _royaltyRecipient;
        royaltyAmount = (salePrice * _royaltyBps[tokenId]) / 10000;
    }

    // URI functions
    function uri(uint256 tokenId) public view override(ERC1155, ERC1155URIStorage) returns (string memory) {
        return ERC1155URIStorage.uri(tokenId);
    }

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        _baseURI = newBaseURI;
    }

    function setTokenURI(uint256 tokenId, string memory tokenURI) external onlyTokenCreator(tokenId) {
        _setURI(tokenId, tokenURI);
    }

    function contractURI() public view returns (string memory) {
        return _collectionInfo.contractURI;
    }

    function setContractURI(string memory newContractURI) external onlyOwner {
        _collectionInfo.contractURI = newContractURI;
    }

    // Batch operations
    function setMaxBatchSize(uint256 newMaxBatchSize) external onlyOwner {
        require(newMaxBatchSize > 0, "Batch size must be > 0");
        _maxBatchSize = newMaxBatchSize;
        emit BatchSizeUpdated(newMaxBatchSize);
    }

    // Token information functions
    function getTokenInfo(uint256 tokenId) external view validToken(tokenId) returns (TokenInfo memory) {
        return _tokenInfo[tokenId];
    }

    function getCollectionInfo() external view returns (CollectionInfo memory) {
        return _collectionInfo;
    }

    function getTokensByOwner(address owner) external view returns (uint256[] memory) {
        return _holderTokens[owner].values();
    }

    function getCreator(uint256 tokenId) external view validToken(tokenId) returns (address) {
        return _creators[tokenId];
    }

    function getRoyaltyInfo(uint256 tokenId) external view validToken(tokenId) returns (address, uint256) {
        return (_royaltyRecipient, _royaltyBps[tokenId]);
    }

    // Overrides
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];
            uint256 amount = values[i];

            // Update holder tokens for transfers
            if (from != address(0)) {
                if (balanceOf(from, tokenId) == 0) {
                    _holderTokens[from].remove(tokenId);
                }
            }

            if (to != address(0)) {
                _holderTokens[to].add(tokenId);
            }

            // Check transfer restrictions
            if (from != address(0) && to != address(0)) {
                require(_tokenInfo[tokenId].transferable, "Token not transferable");
            }
        }
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        // Additional checks can be added here if needed
    }

    // Withdraw funds
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }

    // Burn function
    function burn(
        address account,
        uint256 tokenId,
        uint256 amount
    ) external {
        require(
            account == msg.sender || isApprovedForAll(account, msg.sender),
            "Caller is not owner nor approved"
        );
        require(_tokenInfo[tokenId].burnable, "Token not burnable");
        
        _burn(account, tokenId, amount);
        
        if (balanceOf(account, tokenId) == 0) {
            _holderTokens[account].remove(tokenId);
        }
    }

    // ERC-1155 Receiver support
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
