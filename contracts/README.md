# contracts: PropAMM Standard reference contracts

The on-chain half of [BAP-710](https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-710.md):
the **PropAMM Oracle** (`PrioUpdateRegistry`, §4.2) with its reference
signed-update decoder (`SignedSeqDecoder`, §4.2.3), the **PropAMM Pool
Interface** (`IPropAMM`, §4.3), and a minimal example pool and taker that
the [e2e harness](../e2e/) drives against a live relayer.

> **Deployed (BSC mainnet).** `PrioUpdateRegistry`:
> [`0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB`](https://bscscan.com/address/0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB).
> Its runtime bytecode matches `PrioUpdateRegistry.sol` here byte for byte
> apart from the compiler metadata hash.

The registry is shared infrastructure: one instance per chain, operated by
the relayer operator. Makers deploy only their pool against it.

| File | What |
| --- | --- |
| `PrioUpdateRegistry.sol` | The registry. Per-`(target, laneIndex)` lanes of up to 255 words, a strictly increasing 48-bit `seq` in the top bits of slot 0 on the direct path, optional decoder-managed lanes, non-atomic batches. No freshness checks: expiry belongs to the pool. Model: [`PrioUpdateRegistry.md`](./PrioUpdateRegistry.md). |
| `SignedSeqDecoder.sol` | Reference decoder for maker-signed updates that anyone may relay: EIP-712, ECDSA or ERC-1271, strictly increasing per-lane `seq`, optional `maxBlock` / `maxTimestamp` write bounds. One deployment serves every target of one registry. From the [registry V2 draft](https://gist.github.com/quintuskilbourn/179a0a11c1859376899fb75112e6d614), with only the imports adapted to this registry. |
| `IPropAMM.sol` | The standard pool interface: `isActive` / `getPairs` / `quote` / push-payment `swap`. |
| `ExamplePammRouter.sol` | Example pool. Implements `IPropAMM` and prices from one registry word per direction, with a pool-enforced `maxBlockNumber`. Holds its own inventory. |
| `ExamplePammTaker.sol` | Example taker. Pushes `tokenIn` into the pool and calls `swap` in one transaction, for its owner only. |
| `script/Deploy.s.sol` | Deploys the registry (optional), the pool, a `SignedSeqDecoder` (optional) and the taker (optional). It also authorizes a maker and registers a pair. |
| `test/ExamplePammRouter.t.sol` | Foundry tests: the BAP-710 §7.1 registry cases (direct path), the §7.2 pool cases, push-payment accounting, reentrancy, and the one-transaction taker. |
| `test/SignedSeqDecoder.t.sol` | Foundry tests: the BAP-710 §7.1 signed-update cases (relay, replay, wrong key, expiry, lane mismatch, key rotation, ERC-1271, batch skip, direct path closed), plus the decoder's registry, signer, seq and domain guards. |

> **Naming.** `ExamplePammRouter` is a *pool* in BAP-710 terms: the
> `IPropAMM` contract, the registry `target`, and the address a maker enters
> as its **router address** in the console. In BAP-710, a *router* is
> whatever calls the pool's `swap` after pushing `tokenIn`, such as an
> aggregator router or `ExamplePammTaker`.

## Build and test

```bash
cd contracts
forge install foundry-rs/forge-std vectorized/solady --no-git   # once; lib/ is gitignored
forge test -vv
```

`foundry.toml` pins solc 0.8.28 and `evm_version = "cancun"`. The example
pool uses a `transient` reentrancy lock (`tstore`), which BSC supports.
`SignedSeqDecoder` uses solady's `EIP712` and `SignatureCheckerLib`.

## Deploy

```bash
cd contracts
ORACLE=0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB MAKER=<maker EOA> TOKEN_A=<token> TOKEN_B=<token> \
  forge script script/Deploy.s.sol --rpc-url $RPC --private-key $OWNER_PK --broadcast
```

Then fund the pool. Transfer `tokenOut` to it and call `pool.sync(tokenOut)`
so the top-up is booked as inventory. Leave `ORACLE` empty only on a private
test chain, because a fresh registry is unknown to the relayer operator.

## Registry in one paragraph

A lane is `(target, laneIndex)`. The pool is the target, and
`laneIndex = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))`
(`pool.laneFor`). The lane's base slot is
`keccak256(abi.encode(keccak256("PrioUpdateRegistryV2.lane.v1"), target, laneIndex))`.

A direct write is `updateState(target, laneIndex, slots, uint48 seq)`. The
registry requires all of the following:

- `msg.sender` is an updater for `target` (`NotAuthorized`).
- `slots[0] >> 208 == 0` (`SeqBitsNotClear`).
- `seq` is strictly above the seq stored in slot 0 (`StaleSeq`). A fresh lane
  stores 0, so the first write needs `seq >= 1`.

It then stores `slots[0] | (seq << 208)`. Nothing in the registry looks at the
block header, so any deadline is the pool's business.

`getState` / `getSlot` read the lane of `msg.sender`, so only the pool can
read its own lanes on-chain. Off-chain, use `pool.readQuote`.

## Example pool slot-0 layout (208 payload bits)

```
bits [208,255] : seq            48  written by the registry; masked out by the pool
bits [160,207] : maxBlockNumber 48  inclusive deadline, enforced by the pool (StaleUpdate)
bits [0,159]   : price         160  1e18-scaled tokenOut per 1 tokenIn, for this lane's direction
```

`pool.packQuote(price, maxBlockNumber)` produces the payload with range
checks. The maker passes `[payload]` as `slots`. This is the layout BAP-710
§4.2.2 uses as its example. Pricing is `amountOut = amountIn * price / 1e18`.
A lane is one direction, so quote both directions to make a pair two-sided.

## Filling (push payment)

The caller transfers `amountIn` of `tokenIn` to the pool and calls
`swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient, maxBlockNumber)`
**in the same transaction**. The pool then does the following:

1. Reads its lane and reverts `NoPrice` (never written) or `StaleUpdate`
   (past the packed deadline).
2. Treats its balance above `reserves[tokenIn]` as the payment
   (`InsufficientInput` if short).
3. Pays `tokenOut` from its own inventory and checks the delivered amount
   against `minAmountOut` (`InsufficientOutput`).
4. Books both balances as the new reserves and emits `IPropAMM.Swapped`.

`maxBlockNumber == 0` skips the caller deadline (the packed quote deadline
still applies). `swap` and `sync` share a transient lock, so a `tokenOut`
transfer hook cannot re-enter and spend the same push twice (BAP-710 §8.1).

`ExamplePammTaker.swap(pool, …)` does the push with `transferFrom` straight
from its owner into the pool and calls `pool.swap`, all in one transaction.
On the relayer's fallback path (no quote bundled), the swap reverts
`NoPrice` / `StaleUpdate` and the push reverts with it, so nothing is left on
the pool.

## Access control

- **Pool `owner`** (the deployer) controls:
  - maker authorization: `addMaker` / `removeMaker`, which call the registry's
    `addUpdater` / `removeUpdater` with `msg.sender = pool`;
  - pair discovery: `addPair`, which feeds the advisory `getPairs`;
  - signed lanes: `bindDecoder` / `setSigner` (see below);
  - withdrawals: `sweep`.
- **Anyone** may call `swap`, since the example pool has no taker allowlist.
  Anyone may also call `sync`, which can only raise reserves to the actual
  balance.
- **`ExamplePammTaker`** fills only for its deployer. Drop the owner check
  to make it a shared, permissionless taker.

## Signed updates (optional)

Instead of authorizing an updater EOA, a pool can take maker-signed updates
that **anyone** may relay (BAP-710 §4.2.3). The setup is two calls, both of
which must come from the pool itself:

```solidity
pool.bindDecoder(tokenIn, tokenOut, decoder); // registry.setDecoder(laneFor(tokenIn, tokenOut), decoder): PERMANENT
pool.setSigner(decoder, signer);              // decoder.setSigner(signer): EOA, or ERC-1271 contract; covers all lanes
```

The maker signs the EIP-712 typed data
`SignedUpdate(address target,uint256 laneIndex,uint256[] slots,uint256 seq,uint256 maxBlock,uint256 maxTimestamp)`
under the domain `("SignedSeqDecoder", "1", chainId, decoder)`. `slots` is
hashed as `keccak256(abi.encodePacked(slots))`, and `decoder.digest(u)`
returns the digest to sign. The quote tx is then
`registry.updateStateWithDecoder(pool, laneIndex, abi.encode(u))`, sent from
any account. The relayer treats it like any other quote tx.

- The decoder packs `seq` into the top 48 bits of slot 0, the same layout
  as the direct path, so the pool's read path does not change.
- A bound lane rejects `updateState` (`DecoderBoundLane`). Binding clears
  slot 0, so the lane's seq restarts at 0.
- `maxBlock` / `maxTimestamp` are write-time bounds on the payload (0 means
  unchecked). They do not replace the pool's own deadline check on read.
- `setSigner(newKey)` invalidates every unlanded payload signed by the old
  key, and `setSigner(address(0))` disables signed updates for the pool.
- The e2e maker uses the direct updater path only.
