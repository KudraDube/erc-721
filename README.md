# NFTDrop

An ERC-721 collection with a Merkle allowlist. Only addresses on a pre-approved list can mint, each can mint once, and each pays the exact price. The metadata stays hidden until the owner reveals it, and after that it is locked.

Think of a guest list that fits on a postcard. The contract stores one fingerprint of the whole list (the Merkle root). Each guest brings their own proof that they are on it. However many guests there are, only the fingerprint is stored.

## Why I built it

NFT drops are a common first job for a Solidity developer, and they combine several things I wanted to understand properly: Merkle proofs, payments, the ERC-721 receiver hook and the trust the owner holds over metadata. I wanted to know where a drop can go wrong, and to prove each fix with a test instead of only describing it.

## Status

| Item | State |
|---|---|
| Contract | Complete, patched with the Contracts Pack fixes |
| Tests | Over 50 passing (unit, reentrancy, fuzz, invariant) |
| Audit | None. This is a learning project, **do not deploy with real funds** |

## How it works

| Piece | Job |
|---|---|
| `merkleRoot` | The fingerprint of the allowlist |
| `mint(proof)` | Checks supply, one mint per address, exact price and the proof, then mints the next token id |
| `hasMinted` | Stops an address minting twice |
| `reveal()` | Switches from the hidden placeholder to the real metadata |
| `setBaseURI()` | Sets where the real metadata lives. Locked once revealed. |
| `setMerkleRoot()` | Lets the owner update the allowlist |
| `withdraw()` | Sends the collected ETH to the owner |

Token ids run from 1 to 1000.

## What I patched and why

1. **Exact price.** The original used `msg.value >= mintPrice`, so a buyer who overpaid lost the extra ETH forever. It is now `==`, and an overpayment reverts.
2. **Double-hashed leaf.** The leaf is now `keccak256(bytes.concat(keccak256(abi.encode(msg.sender))))`. A single hash leaves room for a 64 byte internal node to be passed off as a leaf (a second preimage). The off-chain tree must use the same double hash, which the OpenZeppelin `merkle-tree` library does by default.
3. **Metadata locked after reveal.** `setBaseURI` reverts once `revealed` is true, so the owner cannot swap the art after people have bought.
4. **One extra guard.** Because of fix 3, revealing before setting a base URI would lock an empty one in forever. `reveal` now requires a base URI first.

Each fix has tests that fail against the original contract and pass against this one.

## Design decisions

- **Checks, effects, then interaction.** `hasMinted` and `totalMinted` update before `_safeMint`, because `_safeMint` calls the receiver contract and that is the reentrancy door. A test mints from a contract that tries to re-enter, and it fails.
- **Exact payment** instead of refunding the difference, because it is simpler and has no extra call to get wrong.
- **Sorted-pair hashing** from OpenZeppelin, so the order of a pair does not matter.
- **`call` for withdrawals** instead of `transfer`, with the result checked.

## Known limitations

- **The owner can change the allowlist any time with `setMerkleRoot`.** That is a trust assumption. A test documents that the owner can add anyone mid-sale.
- **One mint per address, not per person.** Someone with several wallets on the list can mint several times.
- **Reveal cannot be undone** and there is no way to pause the sale.
- **The price is fixed at 0.05 ETH.** It is a storage variable with no setter, so it could be a constant.
- **Ownership uses plain `Ownable`.** A mistyped transfer cannot be recovered, and `Ownable2Step` would be safer.
- **If the owner is a contract with no `receive` function, `withdraw` fails** and the ETH is stuck. A test documents this.
- **All tokens share one hidden URI** before reveal, and there are no royalties.
- **Not audited.**

## Tests

`test/NFTDrop.t.sol`:

- constructor and ERC-165 support
- minting: the happy path, outsiders, borrowed, tampered and truncated proofs, one mint per address
- the three patches, each with tests that fail on the original
- the receiver hook: a re-entering contract and a contract with no hook
- supply: the 1000th mint and sold out
- reveal, `tokenURI` formatting for edge ids (0, 9, 10, 100, 1000) and the locked base URI
- withdraw and ownership, including the documented footgun
- fuzz tests for wrong payments, outsiders, `tokenURI` formatting of any id and the metadata lock
- 4 invariants after random mints, withdrawals and metadata calls: ETH always matches sales, supply matches tokens held, supply never passes the cap and the base URI never changes after reveal

## Run it

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
```

## What I practised

- building a Merkle tree by hand and checking proofs in Solidity
- why the leaf is double hashed and what a second preimage attack is
- the ERC-721 receiver hook and checks-effects-interactions
- locking an owner power after a one-way switch, and what that can break
- writing tests that document known gaps instead of hiding them
- invariant testing with a handler and a harness contract

## Where this is going

I am a WeThinkCode blockchain graduate building towards a junior Solidity or Web3 role. This repository is one of a set (SimpleDEX, EthVault, MultiSigWallet, P2PEscrow, StakingRewards, TieredPass1155, RegulatedToken, NFTDrop) where each contract comes with tests I can explain line by line.
