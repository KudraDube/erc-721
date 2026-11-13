// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NFTDrop} from "../src/NFTDrop.sol";

/// @dev Builds the same Merkle tree the contract expects: double hashed leaves and sorted pairs.
abstract contract TreeHelper {
    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _root(address[4] memory u) internal pure returns (bytes32) {
        return _pair(_pair(_leaf(u[0]), _leaf(u[1])), _pair(_leaf(u[2]), _leaf(u[3])));
    }

    function _proof(address[4] memory u, uint256 i) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0) {
            p[0] = _leaf(u[1]);
            p[1] = _pair(_leaf(u[2]), _leaf(u[3]));
        } else if (i == 1) {
            p[0] = _leaf(u[0]);
            p[1] = _pair(_leaf(u[2]), _leaf(u[3]));
        } else if (i == 2) {
            p[0] = _leaf(u[3]);
            p[1] = _pair(_leaf(u[0]), _leaf(u[1]));
        } else {
            p[0] = _leaf(u[2]);
            p[1] = _pair(_leaf(u[0]), _leaf(u[1]));
        }
    }
}

/// @dev Adds two setters so tests can reach states that would take 1000 mints. Logic is untouched.
contract NFTDropHarness is NFTDrop {
    constructor(string memory n, string memory s, string memory h, bytes32 r) NFTDrop(n, s, h, r) {}

    function setTotalMinted(uint256 n) external {
        totalMinted = n;
    }

    function forceMint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @dev A contract buyer that tries to mint again from inside the onERC721Received hook.
contract ReentrantMinter is IERC721Receiver {
    NFTDrop public drop;
    bool public reenterSucceeded;
    bool public reenterFailed;
    bool public sawMintedFlag;
    uint256 public sawTotal;

    constructor(NFTDrop d) {
        drop = d;
    }

    function attack(bytes32[] calldata proof) external payable {
        drop.mint{value: msg.value}(proof);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        sawMintedFlag = drop.hasMinted(address(this));
        sawTotal = drop.totalMinted();
        try drop.mint{value: drop.mintPrice()}(new bytes32[](0)) {
            reenterSucceeded = true;
        } catch {
            reenterFailed = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A contract buyer with no onERC721Received, so _safeMint must refuse it.
contract NoHookBuyer {
    function buy(NFTDrop d, bytes32[] calldata proof) external payable {
        d.mint{value: msg.value}(proof);
    }
}

/// @dev Has no receive function, so it cannot accept ETH.
contract Rejecter {}

/// @dev Plays random minters and an owner against a drop. The invariant tests read its state.
contract NFTDropHandler is Test, TreeHelper {
    NFTDrop public drop;
    address[4] public users;
    uint256 public constant PRICE = 0.05 ether;
    uint256 public withdrawn;
    bool public snapTaken;
    bytes32 public baseSnapshot;

    constructor() {
        users = [makeAddr("hUser0"), makeAddr("hUser1"), makeAddr("hUser2"), makeAddr("hUser3")];
        drop = new NFTDrop("Handler", "HND", "ipfs://hidden", _root(users)); // the handler is the owner
    }

    receive() external payable {}

    function mint(uint256 seed) external {
        uint256 i = seed % 4;
        address actor = users[i];
        bytes32[] memory p = _proof(users, i);
        vm.deal(actor, PRICE);
        vm.prank(actor);
        try drop.mint{value: PRICE}(p) {} catch {}
    }

    function withdraw() external {
        uint256 b = address(drop).balance;
        try drop.withdraw() {
            withdrawn += b;
        } catch {}
    }

    function setBase(uint256 seed) external {
        string memory s = string.concat("ipfs://", vm.toString(seed), "/");
        try drop.setBaseURI(s) {} catch {}
    }

    function reveal() external {
        try drop.reveal() {
            if (!snapTaken) {
                snapTaken = true;
                baseSnapshot = keccak256(bytes(drop.baseURI()));
            }
        } catch {}
    }

    function sumOfBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < 4; i++) {
            sum += drop.balanceOf(users[i]);
        }
    }
}

contract NFTDropTest is Test, TreeHelper {
    NFTDrop drop;
    NFTDropHarness harness;
    NFTDropHandler handler;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve"); // not on the allowlist
    address[4] users;

    uint256 constant PRICE = 0.05 ether;
    string constant HIDDEN = "ipfs://hidden.json";
    string constant BASE = "ipfs://real/";

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    receive() external payable {} // so the test contract, as owner, can withdraw

    function setUp() public {
        users = [alice, bob, carol, dave];
        bytes32 root = _root(users);
        drop = new NFTDrop("Drop", "DRP", HIDDEN, root);
        harness = new NFTDropHarness("Drop", "DRP", HIDDEN, root);

        handler = new NFTDropHandler();
        targetContract(address(handler));
    }

    // helpers

    function _mintAs(NFTDrop d, address who, uint256 index) internal {
        bytes32[] memory p = _proof(users, index);
        vm.deal(who, PRICE);
        vm.prank(who);
        d.mint{value: PRICE}(p);
    }

    function _mintAs(address who, uint256 index) internal {
        _mintAs(drop, who, index);
    }

    // constructor

    function test_constructor_setsEverything() public view {
        assertEq(drop.name(), "Drop");
        assertEq(drop.symbol(), "DRP");
        assertEq(drop.hiddenURI(), HIDDEN);
        assertEq(drop.merkleRoot(), _root(users));
        assertEq(drop.owner(), owner);
        assertEq(drop.MAX_SUPPLY(), 1000);
        assertEq(drop.mintPrice(), PRICE);
        assertEq(drop.totalMinted(), 0);
        assertFalse(drop.revealed());
        assertEq(bytes(drop.baseURI()).length, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(drop.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(drop.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(drop.supportsInterface(0x01ffc9a7)); // ERC165
        assertFalse(drop.supportsInterface(0xffffffff));
    }

    // minting: the happy path

    function test_mint_allowlistedBuyerGetsTokenOne() public {
        _mintAs(alice, 0);

        assertEq(drop.ownerOf(1), alice);
        assertEq(drop.balanceOf(alice), 1);
        assertEq(drop.totalMinted(), 1);
        assertTrue(drop.hasMinted(alice));
    }

    function test_mint_emitsTransferFromZero() public {
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);

        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), alice, 1);
        vm.prank(alice);
        drop.mint{value: PRICE}(p);
    }

    function test_mint_idsAreSequentialAcrossBuyers() public {
        _mintAs(alice, 0);
        _mintAs(bob, 1);
        _mintAs(carol, 2);
        _mintAs(dave, 3);

        assertEq(drop.ownerOf(1), alice);
        assertEq(drop.ownerOf(2), bob);
        assertEq(drop.ownerOf(3), carol);
        assertEq(drop.ownerOf(4), dave);
        assertEq(drop.totalMinted(), 4);
    }

    function test_mint_everyAllowlistedPositionInTheTreeWorks() public {
        for (uint256 i = 0; i < 4; i++) {
            _mintAs(users[i], i);
            assertTrue(drop.hasMinted(users[i]));
        }
    }

    function test_mint_contractHoldsThePayment() public {
        _mintAs(alice, 0);
        _mintAs(bob, 1);

        assertEq(address(drop).balance, 2 * PRICE);
    }

    // minting: who is allowed in

    function test_mint_outsiderWithEmptyProofReverts() public {
        vm.deal(eve, PRICE);
        vm.prank(eve);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(new bytes32[](0));
    }

    function test_mint_outsiderCannotUseSomeoneElsesProof() public {
        bytes32[] memory aliceProof = _proof(users, 0);
        vm.deal(eve, PRICE);

        vm.prank(eve);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(aliceProof);
    }

    function test_mint_allowlistedBuyerCannotUseAnotherSlotsProof() public {
        bytes32[] memory bobProof = _proof(users, 1);
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(bobProof);
    }

    function test_mint_tamperedProofReverts() public {
        bytes32[] memory p = _proof(users, 0);
        p[1] = bytes32(uint256(p[1]) ^ 1);
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(p);
    }

    function test_mint_truncatedProofReverts() public {
        bytes32[] memory p = new bytes32[](1);
        p[0] = _leaf(bob);
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(p);
    }

    function test_mint_onlyOncePerAddress() public {
        _mintAs(alice, 0);

        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert("already minted");
        drop.mint{value: PRICE}(p);
    }

    function test_mint_movingTheTokenAwayDoesNotAllowAnotherMint() public {
        // Documents current behaviour: the limit is per address that minted, not per holder.
        _mintAs(alice, 0);
        vm.prank(alice);
        drop.transferFrom(alice, bob, 1);

        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert("already minted");
        drop.mint{value: PRICE}(p);
    }

    // minting: payment (patch 1, exact price)

    function test_payment_underpayingReverts() public {
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint{value: PRICE - 1}(p);
    }

    function test_payment_overpayingOneWeiReverts() public {
        // The old code accepted this and kept the extra wei forever.
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE + 1);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint{value: PRICE + 1}(p);
    }

    function test_payment_overpayingByALotReverts() public {
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint{value: 10 ether}(p);
    }

    function test_payment_freeMintReverts() public {
        bytes32[] memory p = _proof(users, 0);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint(p);
    }

    function test_payment_aFailedMintKeepsTheBuyersEth() public {
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint{value: PRICE + 1}(p);

        assertEq(alice.balance, 1 ether);
        assertEq(address(drop).balance, 0);
        assertEq(drop.totalMinted(), 0);
        assertFalse(drop.hasMinted(alice));
    }

    // minting: supply

    function test_supply_lastTokenCanBeMintedThenItIsSoldOut() public {
        harness.setTotalMinted(999);

        _mintAs(harness, alice, 0);
        assertEq(harness.ownerOf(1000), alice);
        assertEq(harness.totalMinted(), 1000);

        bytes32[] memory p = _proof(users, 1);
        vm.deal(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert("sold out");
        harness.mint{value: PRICE}(p);
    }

    function test_supply_soldOutRevertsForEveryone() public {
        harness.setTotalMinted(1000);

        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert("sold out");
        harness.mint{value: PRICE}(p);
    }

    // minting: reentrancy and receivers

    function test_receiver_reentrantMintFromTheHookFails() public {
        ReentrantMinter attacker = new ReentrantMinter(drop);
        drop.setMerkleRoot(_leaf(address(attacker))); // one leaf tree, so the proof is empty
        vm.deal(address(attacker), 1 ether);

        attacker.attack{value: PRICE}(new bytes32[](0));

        assertTrue(attacker.reenterFailed());
        assertFalse(attacker.reenterSucceeded());
        assertEq(drop.balanceOf(address(attacker)), 1);
        assertEq(drop.totalMinted(), 1);
    }

    function test_receiver_stateIsAlreadyUpdatedWhenTheHookRuns() public {
        ReentrantMinter attacker = new ReentrantMinter(drop);
        drop.setMerkleRoot(_leaf(address(attacker)));
        vm.deal(address(attacker), 1 ether);

        attacker.attack{value: PRICE}(new bytes32[](0));

        assertTrue(attacker.sawMintedFlag()); // hasMinted was set before _safeMint
        assertEq(attacker.sawTotal(), 1); // the counter had already moved
    }

    function test_receiver_contractWithoutAHookCannotMint() public {
        NoHookBuyer buyer = new NoHookBuyer();
        drop.setMerkleRoot(_leaf(address(buyer)));
        vm.deal(address(buyer), PRICE);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(buyer)));
        buyer.buy{value: PRICE}(drop, new bytes32[](0));

        assertEq(drop.totalMinted(), 0);
        assertFalse(drop.hasMinted(address(buyer)));
    }

    // patch 2: the double hashed leaf

    function test_leaf_singleHashedAllowlistIsRejected() public {
        // An allowlist built with the old single hash no longer matches the contract.
        bytes32 oldStyleRoot = keccak256(abi.encodePacked(alice)); // one leaf tree, old format
        drop.setMerkleRoot(oldStyleRoot);
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(new bytes32[](0));
    }

    function test_leaf_doubleHashedSingleLeafIsAccepted() public {
        drop.setMerkleRoot(_leaf(alice));
        vm.deal(alice, PRICE);

        vm.prank(alice);
        drop.mint{value: PRICE}(new bytes32[](0));
        assertEq(drop.ownerOf(1), alice);
    }

    function test_leaf_theLeafIsNeverTheRawAddress() public {
        drop.setMerkleRoot(bytes32(uint256(uint160(alice)))); // address padded to 32 bytes
        vm.deal(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(new bytes32[](0));
    }

    // owner controls: merkle root

    function test_setMerkleRoot_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        drop.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_setMerkleRoot_oldProofsStopWorking() public {
        drop.setMerkleRoot(bytes32(uint256(1)));

        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(p);
    }

    function test_setMerkleRoot_ownerCanSwapTheListAtAnyTime() public {
        // Documents the trust assumption: the owner can add anyone to the list, even mid-sale.
        _mintAs(alice, 0);
        drop.setMerkleRoot(_leaf(eve));
        vm.deal(eve, PRICE);

        vm.prank(eve);
        drop.mint{value: PRICE}(new bytes32[](0));
        assertEq(drop.ownerOf(2), eve);
    }

    function test_setMerkleRoot_doesNotResetWhoHasMinted() public {
        _mintAs(alice, 0);
        drop.setMerkleRoot(_leaf(alice));

        vm.deal(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert("already minted");
        drop.mint{value: PRICE}(new bytes32[](0));
    }

    // reveal and metadata

    function test_tokenURI_isHiddenBeforeReveal() public {
        _mintAs(alice, 0);

        assertEq(drop.tokenURI(1), HIDDEN);
    }

    function test_tokenURI_nonexistentTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        drop.tokenURI(1);
    }

    function test_tokenURI_tokenZeroNeverExists() public {
        _mintAs(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        drop.tokenURI(0);
    }

    function test_tokenURI_isRealMetadataAfterReveal() public {
        _mintAs(alice, 0);
        drop.setBaseURI(BASE);
        drop.reveal();

        assertTrue(drop.revealed());
        assertEq(drop.tokenURI(1), "ipfs://real/1.json");
    }

    function test_tokenURI_settingTheBaseBeforeRevealDoesNotLeakIt() public {
        _mintAs(alice, 0);
        drop.setBaseURI(BASE);

        assertEq(drop.tokenURI(1), HIDDEN);
    }

    function test_tokenURI_numberFormattingForEdgeIds() public {
        uint256[6] memory ids = [uint256(0), 1, 9, 10, 100, 1000];
        for (uint256 i = 0; i < ids.length; i++) {
            harness.forceMint(alice, ids[i]);
        }
        harness.setBaseURI(BASE);
        harness.reveal();

        assertEq(harness.tokenURI(0), "ipfs://real/0.json");
        assertEq(harness.tokenURI(1), "ipfs://real/1.json");
        assertEq(harness.tokenURI(9), "ipfs://real/9.json");
        assertEq(harness.tokenURI(10), "ipfs://real/10.json");
        assertEq(harness.tokenURI(100), "ipfs://real/100.json");
        assertEq(harness.tokenURI(1000), "ipfs://real/1000.json");
    }

    function test_reveal_onlyOwner() public {
        drop.setBaseURI(BASE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        drop.reveal();
    }

    function test_reveal_requiresABaseURI() public {
        // Without this guard the owner could reveal first, lock setBaseURI, and brick every token.
        vm.expectRevert("base URI not set");
        drop.reveal();
        assertFalse(drop.revealed());
    }

    function test_reveal_canBeCalledAgainWithoutHarm() public {
        drop.setBaseURI(BASE);
        drop.reveal();
        drop.reveal();

        assertTrue(drop.revealed());
    }

    // patch 3: setBaseURI is locked after reveal

    function test_setBaseURI_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        drop.setBaseURI(BASE);
    }

    function test_setBaseURI_canBeChangedManyTimesBeforeReveal() public {
        drop.setBaseURI("ipfs://one/");
        drop.setBaseURI("ipfs://two/");
        assertEq(drop.baseURI(), "ipfs://two/");
    }

    function test_setBaseURI_revertsAfterReveal() public {
        drop.setBaseURI(BASE);
        drop.reveal();

        vm.expectRevert("already revealed");
        drop.setBaseURI("ipfs://rugged/");
    }

    function test_setBaseURI_afterRevealTheMetadataStaysFixed() public {
        _mintAs(alice, 0);
        drop.setBaseURI(BASE);
        drop.reveal();

        vm.expectRevert("already revealed");
        drop.setBaseURI("ipfs://rugged/");

        assertEq(drop.baseURI(), BASE);
        assertEq(drop.tokenURI(1), "ipfs://real/1.json");
    }

    function test_setBaseURI_stillLockedEvenIfRevealIsCalledTwice() public {
        drop.setBaseURI(BASE);
        drop.reveal();
        drop.reveal();

        vm.expectRevert("already revealed");
        drop.setBaseURI("ipfs://rugged/");
    }

    // withdraw

    function test_withdraw_sendsEverythingToTheOwner() public {
        _mintAs(alice, 0);
        _mintAs(bob, 1);
        uint256 before = owner.balance;

        drop.withdraw();

        assertEq(owner.balance, before + 2 * PRICE);
        assertEq(address(drop).balance, 0);
    }

    function test_withdraw_onlyOwner() public {
        _mintAs(alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        drop.withdraw();
    }

    function test_withdraw_withNothingToTakeIsHarmless() public {
        drop.withdraw();
        assertEq(address(drop).balance, 0);
    }

    function test_withdraw_followsTheCurrentOwner() public {
        _mintAs(alice, 0);
        drop.transferOwnership(bob);

        vm.prank(bob);
        drop.withdraw();

        assertEq(bob.balance, PRICE);
    }

    function test_withdraw_revertsIfTheOwnerCannotReceiveEth() public {
        // Documents a footgun: ownership handed to a contract with no receive function locks the funds.
        _mintAs(alice, 0);
        Rejecter rejecter = new Rejecter();
        drop.transferOwnership(address(rejecter));

        vm.prank(address(rejecter));
        vm.expectRevert("withdraw failed");
        drop.withdraw();

        assertEq(address(drop).balance, PRICE);
    }

    // ownership and ERC-721 basics

    function test_ownership_transferWorksAndOldOwnerLosesPower() public {
        drop.transferOwnership(bob);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        drop.setBaseURI(BASE);

        vm.prank(bob);
        drop.setBaseURI(BASE);
    }

    function test_nft_ownerCanTransferAndSellOn() public {
        _mintAs(alice, 0);

        vm.prank(alice);
        drop.transferFrom(alice, eve, 1);

        assertEq(drop.ownerOf(1), eve);
        assertEq(drop.balanceOf(alice), 0);
    }

    // fuzz tests

    function testFuzz_anyWrongPaymentReverts(uint256 value) public {
        value = bound(value, 0, 100 ether);
        vm.assume(value != PRICE);
        bytes32[] memory p = _proof(users, 0);
        vm.deal(alice, 200 ether);

        vm.prank(alice);
        vm.expectRevert("wrong payment");
        drop.mint{value: value}(p);
    }

    function testFuzz_outsidersNeverMint(address who) public {
        vm.assume(who != alice && who != bob && who != carol && who != dave);
        vm.assume(who != address(0));
        bytes32[] memory p = _proof(users, 0); // borrowed from alice
        vm.deal(who, PRICE);

        vm.prank(who);
        vm.expectRevert("not on allowlist");
        drop.mint{value: PRICE}(p);
    }

    function testFuzz_tokenURIFormatsAnyId(uint256 id) public {
        harness.forceMint(alice, id);
        harness.setBaseURI(BASE);
        harness.reveal();

        assertEq(harness.tokenURI(id), string.concat(BASE, vm.toString(id), ".json"));
    }

    function testFuzz_baseURIIsFrozenAfterReveal(string calldata newBase) public {
        drop.setBaseURI(BASE);
        drop.reveal();

        vm.expectRevert("already revealed");
        drop.setBaseURI(newBase);
        assertEq(drop.baseURI(), BASE);
    }

    function testFuzz_withdrawAlwaysEmptiesTheContract(uint8 buyers) public {
        buyers = uint8(bound(buyers, 0, 4));
        for (uint256 i = 0; i < buyers; i++) {
            _mintAs(users[i], i);
        }
        uint256 before = owner.balance;

        drop.withdraw();

        assertEq(address(drop).balance, 0);
        assertEq(owner.balance, before + uint256(buyers) * PRICE);
    }

    // invariants (run against the handler's own drop)

    function invariant_everySaleIsPaidForAndAccountedFor() public view {
        NFTDrop d = handler.drop();
        assertEq(address(d).balance + handler.withdrawn(), d.totalMinted() * handler.PRICE());
    }

    function invariant_totalMintedMatchesTokensHeld() public view {
        assertEq(handler.sumOfBalances(), handler.drop().totalMinted());
    }

    function invariant_supplyNeverExceedsTheMax() public view {
        assertLe(handler.drop().totalMinted(), handler.drop().MAX_SUPPLY());
    }

    function invariant_baseURINeverChangesAfterReveal() public view {
        if (handler.drop().revealed()) {
            assertEq(keccak256(bytes(handler.drop().baseURI())), handler.baseSnapshot());
        }
    }
}
