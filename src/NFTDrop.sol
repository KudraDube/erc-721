// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract NFTDrop is ERC721, Ownable {

    // ============ CUSTOM: STATE VARIABLES ============
    uint256 public constant MAX_SUPPLY = 1000;
    uint256 public mintPrice = 0.05 ether;
    uint256 public totalMinted;

    bytes32 public merkleRoot;              
    mapping(address => bool) public hasMinted;

    bool public revealed;
    string public hiddenURI;              
    string public baseURI;                 
    // ============ BORROWED: CONSTRUCTOR ============
    // ERC721's constructor sets name/symbol. Ownable's constructor sets the deployer as owner.
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _hiddenURI,
        bytes32 _merkleRoot
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        hiddenURI = _hiddenURI;
        merkleRoot = _merkleRoot;
    }

    // ============ CUSTOM LOGIC ============

    /// @notice Mint one NFT if the caller is on the allowlist and pays the price.
    /// @param proof The Merkle proof showing msg.sender's leaf is part of the tree.
    function mint(bytes32[] calldata proof) external payable {
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(!hasMinted[msg.sender], "already minted");
        require(msg.value >= mintPrice, "insufficient payment");

      
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "not on allowlist");

        hasMinted[msg.sender] = true;
        totalMinted++;

  
        _safeMint(msg.sender, totalMinted);
    }

    /// @notice Owner flips the reveal switch once mint is done.
    function reveal() external onlyOwner {
        revealed = true;
    }

    /// @notice Owner can update the base URI once the real metadata is uploaded.
    function setBaseURI(string calldata _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    /// @notice Owner can update the allowlist without redeploying the contract.
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /// @notice Returns metadata URI for a token — placeholder before reveal, real after.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // reverts if token doesn't exist (OZ v5 helper)

        if (!revealed) {
            return hiddenURI;
        }
        return string(abi.encodePacked(baseURI, _toString(tokenId), ".json"));
    }

    /// @notice Owner withdraws all funds collected from minting.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "withdraw failed");
    }

   
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
