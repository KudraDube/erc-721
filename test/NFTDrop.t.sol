// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/NFTDrop.sol";

contract NFTDropTest is Test {
    NFTDrop public drop;
    address owner = address(this);
    address alice = address(0x1);
    address bob = address(0x2); // NOT on the allowlist, for negative testing

    // For a real test you'd generate this tree with a JS/TS script (e.g. merkletreejs)
    // and hardcode the root + each address's proof here. Placeholder shown.
    bytes32 merkleRoot = 0x0; // TODO: paste generated root
    bytes32[] aliceProof;     // TODO: paste generated proof array

    function setUp() public {
        drop = new NFTDrop("Test Drop", "TDROP", "ipfs://hidden.json", merkleRoot);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function test_MintSucceedsForAllowlistedAddress() public {
        vm.prank(alice);
        drop.mint{value: 0.05 ether}(aliceProof);
        assertEq(drop.balanceOf(alice), 1);
        assertEq(drop.totalMinted(), 1);
    }

    function test_MintRevertsForNonAllowlistedAddress() public {
        vm.prank(bob);
        vm.expectRevert("not on allowlist");
        drop.mint{value: 0.05 ether}(aliceProof); // wrong proof for bob
    }

    function test_MintRevertsOnDoubleMint() public {
        vm.startPrank(alice);
        drop.mint{value: 0.05 ether}(aliceProof);
        vm.expectRevert("already minted");
        drop.mint{value: 0.05 ether}(aliceProof);
        vm.stopPrank();
    }

    function test_MintRevertsOnInsufficientPayment() public {
        vm.prank(alice);
        vm.expectRevert("insufficient payment");
        drop.mint{value: 0.01 ether}(aliceProof);
    }

    function test_TokenURIReturnsHiddenBeforeReveal() public {
        vm.prank(alice);
        drop.mint{value: 0.05 ether}(aliceProof);
        assertEq(drop.tokenURI(1), "ipfs://hidden.json");
    }

    function test_TokenURIReturnsRealAfterReveal() public {
        vm.prank(alice);
        drop.mint{value: 0.05 ether}(aliceProof);

        drop.setBaseURI("ipfs://revealed/");
        drop.reveal();
        assertEq(drop.tokenURI(1), "ipfs://revealed/1.json");
    }

    function test_OnlyOwnerCanReveal() public {
        vm.prank(alice);
        vm.expectRevert(); // Ownable custom error in v5
        drop.reveal();
    }

    function test_WithdrawSendsBalanceToOwner() public {
        vm.prank(alice);
        drop.mint{value: 0.05 ether}(aliceProof);

        uint256 before = owner.balance;
        drop.withdraw();
        assertEq(owner.balance, before + 0.05 ether);
    }
}
