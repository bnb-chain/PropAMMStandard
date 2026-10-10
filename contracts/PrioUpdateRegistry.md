# PrioUpdateRegistry — model and storage layout

The **PropAMM Oracle**: an on-chain registry holding maker-published pricing
state for PropAMM pools. Pools read their own state from it at execution
time; makers (or anyone relaying a signed payload, on decoder lanes) write
it. The registry stores raw words and enforces exactly two things —
**authorization** and **write ordering** — everything application-level
(price layout, freshness, decoding) belongs to the target and its decoder.

Source: [`PrioUpdateRegistry.sol`](./PrioUpdateRegistry.sol). Specification:
[BAP-710](https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-710.md) §4.2.

## Lanes

State is stored per `(target, laneIndex)` — a **lane** — where `target` is
the pool contract and `laneIndex` is any `uint256` (e.g.
`keccak256(abi.encodePacked(tokenIn, tokenOut))` for one lane per trading
direction). A lane is up to **255 words** of raw storage.

Lane storage is namespaced to keep it disjoint from Solidity mappings and
other hashed regions:

```
laneBase(target, laneIndex) = keccak256(abi.encode(keccak256("PrioUpdateRegistryV2.lane.v1"), target, laneIndex))
slot i of the lane          = laneBase + i          (0 <= i < 255)
```

A write replaces only the supplied prefix: a shorter write leaves the words a
longer earlier write put beyond it. Readers see unwritten words as zero.

## Two write paths

### Direct path (updater-managed lanes)

```solidity
function updateState(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq) external;
function updateStateBatch(Update[] calldata updates) external returns (bool[] memory applied);
```

- **Authorization** — `msg.sender` must be an updater for `target`. Each
  target manages its own set: `addUpdater` / `removeUpdater` (called *by the
  target*), queryable via `isUpdater(target, updater)`.
- **Write ordering (replay protection)** — every direct write carries a
  48-bit `seq` that must be **strictly greater** than the lane's stored seq.
  The registry packs `seq` into the **top 48 bits of slot 0**; consumers read
  data as `slot0 & SLOT0_DATA_MASK` and the seq as `slot0 >> SEQ_SHIFT`
  (constants exported both as getters and as file-level Solidity constants
  `PUR_SEQ_SHIFT` / `PUR_MAX_SEQ` / `PUR_SLOT0_DATA_MASK`). Consequently
  `slots[0]` carries **208 data bits** (its top 48 bits must be zero —
  `SeqBitsNotClear` otherwise); slots 1+ are full width. A replayed or
  out-of-order update can never overwrite a newer one, whoever submits it.
- **No freshness** — the registry never checks the block header. A target
  that needs expiry packs a deadline (e.g. `maxBlockNumber`) into its own
  layout and validates it on read.
- `updateStateBatch` applies elements in order and **skips** a failing
  element instead of reverting (returns `applied[]`), so one transaction can
  carry many lanes' updates.
- `resetLane(laneIndex)` — target-only recovery: clears the lane's slot 0
  (including the stored seq) so the direct path accepts `seq >= 1` again.
  Meant for a lane whose seq was pushed to `MAX_SEQ` or far ahead by mistake.
  A reset also re-arms any of the owner's earlier unlanded updates — rotate
  the updater when resetting if such updates may still be in flight.

### Decoder path (decoder-managed lanes)

```solidity
function setDecoder(uint256 laneIndex, address decoder) external;              // by the target, permanent
function updateStateWithDecoder(address target, uint256 laneIndex, bytes calldata aux) external;
function updateStateWithDecoderBatch(DecoderUpdate[] calldata updates) external returns (bool[] memory applied);
```

A target may permanently bind an [`IPrioUpdateDecoder`](./PrioUpdateRegistry.sol)
to a lane. From then on:

- direct updater writes to that lane are disabled (`DecoderBoundLane`);
- **anyone** may relay an update: the registry `STATICCALL`s
  `decoder.validateAndUnpack(target, laneIndex, aux)` and stores the
  `uint256[]` it returns. The decoder owns authorization, layout, freshness
  and replay protection (it may read the lane it validates for via
  `getSlotOf` to enforce its own sequencing);
- the static context means a decoder cannot modify state, and the registry
  bounds the gas it forwards (`gasLimit` per batch element; `0` = all) and
  the return data it copies, so a misbehaving decoder can only fail its own
  element. The batch skips failing elements like the direct batch.

The decoder path is what makes third-party relaying safe: a signed payload
(`aux`) travels through any submitter, and its validity is decided entirely
by the decoder the target chose. BAP-710 §4.2.3 specifies the reference
decoder, [`SignedSeqDecoder`](./SignedSeqDecoder.sol): EIP-712
payloads signed by the target's registered signer (ECDSA or ERC-1271), bound
to chain, decoder, target and lane, with the same strictly increasing `seq`
packed into the top 48 bits of slot 0 as the direct path, so pools read both
kinds of lane identically.

## Reads

```solidity
function getState(uint256 laneIndex, uint256 count) external view returns (uint256[] memory);
function getSlots(uint256 laneIndex, uint256 slotIndex, uint256 slotCount) external view returns (uint256[] memory);
function getSlot(uint256 laneIndex, uint256 slotIndex) external view returns (uint256);
function getSlotOf(address target, uint256 laneIndex, uint256 slotIndex) external view returns (uint256);
```

Reads are **scoped to `msg.sender`**: a pool reads its own lanes (the
registry has no lane length, so the caller says how many words it wants).
`getSlotOf` is the one exception — callable by the target itself or by the
decoder bound to that lane, so a shared decoder can read the lane it
validates for. Off-chain readers use `eth_call` with `from = target` (or read
the storage slots directly at the layout above).

No read performs freshness or application-level validation; a pool checks
its own deadline word after reading.

## Errors

| Error | Path | Meaning |
| --- | --- | --- |
| `NotAuthorized()` | direct | `msg.sender` is not an updater for `target` |
| `EmptySlots()` / `TooManySlots()` | both | slot count outside `[1, 255]` |
| `SeqBitsNotClear()` | direct | `slots[0]` top 48 bits not zero |
| `StaleSeq()` | direct | `seq` not strictly above the stored seq (a fresh lane stores 0, so the first write needs `seq >= 1`) |
| `DecoderBoundLane()` | direct | direct write to a decoder-managed lane |
| `SlotIndexOutOfRange()` | reads | requested range escapes the 255-slot lane |
| `NotLaneReader()` | `getSlotOf` | caller is neither the target nor the lane's decoder |
| `ZeroDecoder()` / `DecoderHasNoCode()` / `DecoderAlreadySet()` | `setDecoder` | invalid or repeated binding |
| `DecoderNotSet()` | decoder | decoder write to a lane without a decoder |
| `DecoderReturnedMalformed()` / `DecoderReturnedNoSlots()` | decoder | return data is not one canonical `uint256[]`, or it is empty |

`updateStateWithDecoder` bubbles the decoder's own revert data unchanged, so
a decoder can surface application errors (e.g. a stale signature) directly to
the relayer.

## Events

`UpdaterAdded(target, updater)`, `UpdaterRemoved(target, updater)`,
`DecoderSet(target, laneIndex, decoder)`, `LaneReset(target, laneIndex)`.

## Layout guidance for pools

A minimal single-slot quote lane on the direct path:

```
slot 0 (208 data bits):  [ price : uint160 ][ maxBlockNumber : uint48 ]   ← low 208 bits
                         [ seq : uint48 ]                                 ← written by the registry
```

The pool reads slot 0, masks with `PUR_SLOT0_DATA_MASK`, unpacks price and
deadline, and reverts once `block.number > maxBlockNumber`. The registry
guarantees the word was written by an authorized updater and is the newest
accepted write; the pool guarantees it is still fresh.
