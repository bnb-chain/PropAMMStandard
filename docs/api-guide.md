# PropAMM Relayer — API Guide

> 中文版：[api-guide.zh-CN.md](./api-guide.zh-CN.md)

The Unified PropAMM Relayer is a BNB Chain full node with one extra JSON-RPC
namespace (`pamm_*`) for makers and operators, and PropAMM-aware behavior
behind the standard EVM methods takers already use. This guide is the wire
reference for both sides; the normative specification is
[BAP-710](https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-710.md) §4.4–§4.8.

- Maker: [§2](#2-maker-sending-quotes) — `pamm_sendQuoteUpdateV1`.
- Taker: [§3](#3-taker-pricing-and-filling) — `eth_call` /
  `eth_sendRawTransaction`, plus the overlay and
  price-level streams.
- Ops: [§4](#4-operational-introspection) — `pamm_status`.

---

## 1. Connection & authentication

The relayer serves HTTP and WebSocket JSON-RPC. Subscriptions
(`pamm_subscribe`) are WebSocket-only; everything else works on both.

A deployment MAY restrict JSON-RPC methods other than the ones in this guide.
Keep your existing BSC RPC endpoint for general chain reads
(`eth_chainId`, `eth_blockNumber`, `eth_getTransactionCount`, receipts, …).

One header carries identity:

| Header | Who | Behavior |
| --- | --- | --- |
| `x-api-key` | maker | **Required** for `pamm_sendQuoteUpdateV1`, and must be a console-issued **maker** key. A keyless update is rejected with `missing maker API key (x-api-key header)`, an unknown key with `invalid API key`, and a valid key of the wrong role with `API key is not a maker key`. |
| `x-api-key` | taker | **Required** on every taker-side call (submission, `pamm_` getters and subscriptions) — a missing, unknown or wrong-role key gets a distinct error (first three rows of the table in §3.2). The key decides your view (public makers, plus the restricted makers that ticked you) and your builder routing. |

On WebSocket the header is read once from the upgrade handshake and applies
to every call on that connection.

Keys are issued in the operator's console, role-bound, and verified by the
relayer **in memory** (SHA-256 lookup against a periodically refreshed
snapshot, by default once a minute — no per-request console call). Rotation
and revocation take effect at the next snapshot refresh, including on live
WebSocket connections. If the snapshot was never loaded or is older than
`max(10 × refresh interval, 5 minutes)`, the relayer **fails closed**: it
refuses quote updates and prices or matches no caller on any quote.

Identity is the API key, never the transaction sender: a taker's view and
builder routing come from the key on the request, whoever signed the
transaction.

---

## 2. Maker: sending quotes

### 2.1 Quote model

- **uuid** (16 bytes, hex) identifies one quote stream — typically one per
  market. Generate it randomly.
- **seq** is strictly increasing per uuid (`> 0`). An update with
  `seq <= latest` is dropped (`stale seq`). Updating a quote = same uuid,
  higher seq; each update fully **replaces** the previous one.
- **tx** is the signed quote transaction (EIP-2718 encoding; blob
  transactions are rejected). It SHOULD only write your pool's lanes in the
  `PrioUpdateRegistry`, either as
  - a direct `updateState(...)` / `updateStateBatch(...)` from an updater
    key your pool authorized, or
  - an `updateStateWithDecoder(...)` call carrying a payload signed by your
    pool's signer (BAP-710 §4.2.3), which may be sent from any account.

  The relayer does not inspect calldata; it judges the transaction by its
  next-block simulation and, if the operator configured one, its write scope.
- Per storage slot, when several live quotes visible to a caller write the
  same slot, the **most recently received** one wins — that value prices the
  taker, and that quote is what gets bundled.
- A uuid belongs to the maker account that created it: an update or cancel
  from another maker is refused (`uuid belongs to another maker`).

### 2.2 Requirements on the quote transaction

The relayer simulates the tx on the next block before accepting it:

- It must **execute successfully**; a revert rejects the update with the
  reason in the response `error`.
- Sign with the sender's **current on-chain nonce**; every update of the
  stream reuses that nonce (the tx only lands when filled). Once the nonce
  advances on chain (a fill, or any other tx you send), sign the next update
  with the new nonce: the stale quote keeps pricing takers until that update
  replaces it, and its dead tx is pruned from any bundle at clean-state
  re-simulation.
- Keep it a **pure setter** — storage writes must depend only on calldata.
  The captured write-set is reused as-is until the next update.
- The sending account must hold enough BNB to pass the next-block
  simulation's balance check (gas is only spent when a fill lands the tx).
- The tx must be signed for the relayer's chain id, and its gas limit must
  fit the node's simulation cap.
- The operator may confine quote writes to the standard contracts
  (write-scope); an update writing outside that scope is rejected wholesale.

### 2.3 `pamm_sendQuoteUpdateV1`

One call per update. Over WS, pipeline freely — handlers run concurrently and
responses correlate by JSON-RPC id.

Request `params[0]`:

| Field | Type | Notes |
| --- | --- | --- |
| `uuid` | hex bytes | exactly 16 bytes |
| `seq` | uint64 | strictly increasing per uuid, `> 0` |
| `tx` | hex bytes | EIP-2718-encoded signed tx. **Empty (`0x`) = cancel this uuid** |
| `maxBlockNumber` | uint64 | last block (inclusive) the quote may be filled in. `0` or a value beyond the relayer's lifetime cap is clamped to `head + cap` (reference default: 100 blocks); a value `<=` the current head is rejected |

Your maker identity and pool are not request fields: both come from the API
key and the console (§1).

Response — always a *result*, never a JSON-RPC error, so one bad update never
breaks the call channel. An accepted update has no `error` field:

```json
{ "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44", "seq": 7, "timestamp": 1789323649752 }
```

A rejected one carries the reason:

```json
{ "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44", "seq": 7, "timestamp": 1789323649752, "error": "stale seq" }
```

`timestamp` is the relayer's receive time (unix millis) — the freshness clock
used for slot-level conflict resolution and for the liveness check (§2.5).

Errors, always in the `error` field (reference implementation):

| Error | Meaning |
| --- | --- |
| `missing maker API key (x-api-key header)` | keyless update |
| `invalid API key` | key unknown to the current snapshot (revoked / rotated / mistyped) |
| `API key is not a maker key` | valid key, wrong role (e.g. a taker key) |
| `permission directory unavailable, retry later` | the relayer has no valid console snapshot (fails closed) |
| `uuid must be exactly 16 bytes` / `seq must be > 0` | malformed envelope |
| `tx too short (N bytes); use empty tx (0x) to cancel` | malformed tx field |
| *(transaction decoding error)* | `tx` is not a valid EIP-2718 transaction |
| `blob-tx is not supported as a quote` | blob transaction |
| `quote tx signed for a different chain id` | wrong chain |
| `stale seq` | seq not above the latest accepted for the uuid (also returned for a duplicate cancel) |
| `uuid has been canceled` | the uuid is canceled until the cancel's `maxBlockNumber` (§2.4) — continue under a new uuid |
| `uuid belongs to another maker` | update/cancel of a stream owned by a different account |
| `the maxBlockNumber must be greater than currentBlockNum` | `maxBlockNumber` was at or below the current block when the update arrived |
| `quote expired on arrival` | a new block arrived while the quote was being validated or simulated, and the deadline no longer reaches the next block |
| `quote gas limit above simulation cap` | tx gas limit over the node's cap |
| `quote writes storage outside the allowed scope` | write-scope violation |
| `propamm engine not ready` | not synchronized with the chain head (§4); retry shortly |
| `relayer busy, retry` | simulation concurrency cap reached |
| *(revert reason / nonce or balance error)* | quote tx failed next-block simulation, including registry rejections such as `NotAuthorized()` or `StaleSeq()` |

### 2.4 Canceling

Same uuid, higher seq, empty tx:

```json
{ "uuid": "0x1bd6...1c44", "seq": 8, "tx": "0x", "maxBlockNumber": 0 }
```

The quote stops being fillable immediately. The cancel leaves a
**tombstone** on the uuid until the cancel's own `maxBlockNumber` (with `0`,
clamped to `head + cap`, about 100 blocks by default): until then every
update on that uuid, whatever its `seq`, is rejected with
`uuid has been canceled`, so a delayed pre-cancel update can never revive the
stream. Continue under a fresh uuid. A bundle matched *before* the cancel may
still land, bounded by the canceled quote's `maxBlockNumber`.

### 2.5 Lifecycle

A quote stops being live when any of these happens first:

- **replaced** — same uuid, higher seq;
- **canceled** — empty-tx update (uuid tombstoned, §2.4);
- **expired** — chain passed its `maxBlockNumber`;
- **aged out** — older than the operator's quote-age bound (`maxQuoteAgeMs`
  in `pamm_status`; `0` = disabled, the reference default);
- **revoked** — the maker lost console approval (applies at the next
  block after the relayer's snapshot refresh).

A quote whose sender nonce advanced on chain is **not** dropped: it keeps
pricing takers until your next update replaces it (bundle re-simulation
prunes the dead tx meanwhile) — so re-quote promptly after a fill.

**Keep streaming.** The relayer expects a maker to send continuously. If
your last accepted update or cancel is older than the liveness window
(`makerLivenessMs` in `pamm_status`, 450 ms by default), you are *offline*:
your quotes stay in the pool but price and match nobody until your next
message, which brings all of them back at once. Any accepted update or cancel
from your key counts, so one busy stream keeps every quote of yours live. A
maker that only re-quotes on price changes must still send something several
times a second.

---

## 3. Taker: pricing and filling

### 3.1 The overlay

For every caller the relayer maintains a **view**: the merged, per-slot
freshest write-set of all live quotes from the makers that caller may see —
the public makers plus the restricted makers that ticked the caller's taker
key. The view requires a valid taker key (§1). Simulation methods apply the
view automatically:

| Method | Behavior |
| --- | --- |
| `eth_call` | executed on chain state at the canonical tip **plus** the caller's overlay; explicit `stateOverride` arguments win over the overlay |
| `eth_estimateGas` | same overlay as `eth_call` |
| `eth_simulateV1` | the overlay is applied once, to the base state ahead of the first simulated block |

```text
simulated state = chain state at head + overlay(quotes in the caller's view) + caller's own state overrides
```

- The overlay applies only on the canonical head. Historical blocks,
  non-canonical blocks requested by hash and mid-block traces (`txIndex`) run
  on plain state.
- Calls that touch no PropAMM pool return exactly what a plain node returns.
- While the relayer is not synchronized with the chain head (§4) no overlay
  is applied.

No PropAMM-specific request shape: call a pool's `IPropAMM.quote` like any
other contract, or simulate your whole fill transaction.

### 3.2 `eth_sendRawTransaction`

Submit an ordinary signed transaction. Pools are push-payment
(`IPropAMM.swap` consumes `tokenIn` already transferred to the pool), so a
fill is a contract call that pushes and swaps in one transaction — an
aggregator / router, or the reference `ExamplePammTaker`.

Nothing is bundled on arrival. The relayer runs the cheap checks, returns
the hash, and matches the tx shortly before the next block is expected
(150 ms before it by default, `matchLeadTimeMs` in `pamm_status`), once the
makers have re-quoted after the previous block. Expect up to one block
interval between the hash and the bundle going out.

On arrival the relayer:

1. resolves your identity and view (visible makers + builder routing) from
   one snapshot — a missing, unknown or non-taker key is refused here (§1);
2. checks eligibility: a blob tx, one whose gas limit exceeds the simulation
   cap, one over 128 KB or below its intrinsic gas, one with a bad signature,
   a tx already known to the public txpool through gossip, a replacement of a
   pending tx (same sender and nonce, e.g. speed-up or cancel), a builder
   selection matching no builder (§3.6), or a full queue (4096 txs in total,
   4 per sender) is refused.

Before the next block, one bundle per taker, each sender's txs in nonce
order, it:

3. simulates the tx on your overlay, recording every storage slot read
   (including reads in frames that later revert) — a tx exactly one nonce
   ahead of you is bridged by your held approve (see below), simulated as the
   unit `[approve, tx]`;
4. attributes each quoted slot read to its freshest visible owning quote:
   `quote write-set ∩ taker read-set ≠ ∅ → bundle together`;
5. builds `[quote txs… (oldest received first), your tx]` and re-simulates on
   clean state — quote txs droppable (and physically pruned if they fail),
   your tx mandatory but revertible (see below);
6. sets the bundle's `maxBlockNumber` to the earliest among the matched
   quotes and broadcasts to the selected builders in parallel. Builders keep
   the bundle until that block; the relayer does not rebroadcast or replace
   it.

**Bundled, held or sent alone — never pooled.** Once you have the hash, the
tx goes out. If there is nothing to bundle it with — no quote visible
to you, no collision, it fails on the overlay or in the clean-state
re-simulation, the matched quotes expired — your tx is sent to the builders
**alone**, with no quote tx and marked revertible, and stays includable for
as long as a quote would (100 blocks by default). You get a receipt either
way: a success, or `status: 0x0` if it reverted for lack of a quote. The
relayer never forwards a submission to the public txpool. One exception to
sending: an ERC-20 **approve** that matches no quote is **held** for a few
blocks (`takerHoldBlocks` in `pamm_status`) and rides with your next
transaction as one bundle, or expires; while held it is never pooled or
broadcast. A held tx is acknowledged with its hash like any accepted
submission.

Only two things stop an accepted tx short of the builders, both logged on
the relayer and neither producing a receipt: a nonce more than one ahead of
your account with no held approve to bridge it, and no builder accepting the
bundle. While a tx is queued or being broadcast, a resubmit shares its
outcome rather than producing a second bundle; a different tx with the same
sender and nonce replaces a queued one and is refused against one already
being matched.

Refusals, as the `eth_sendRawTransaction` error message:

| Error | Stage |
| --- | --- |
| `missing taker API key (x-api-key header)` / `invalid API key` / `API key is not an approved taker key` | taker authentication (§1) |
| `permission directory unavailable, retry later` | no valid console snapshot (fails closed) |
| `propamm engine not ready` | not synchronized with the chain head (§4) |
| `blob transactions are not accepted` | blob tx |
| `gas limit above the simulation cap` | over the node's cap |
| `transaction too large` / `intrinsic gas too low` / `invalid transaction sender` | over 128 KB, gas limit below the tx's intrinsic gas, or no recoverable sender |
| `no builder available for this taker` | your builder selection matches none of this relayer's builders |
| `transaction is already in the public txpool` / `nonce too low: …` | the public pool (fed by gossip) already holds the tx or its nonce |
| `too many taker transactions pending the match window` / `too many transactions from this sender pending the match window` | the queue is full (4096 in total, 4 per sender) |
| `a transaction with this nonce is already being matched` | a different tx at the same sender and nonce is being matched right now |

**Visibility.** A bundled tx is private order flow: it is not in the public
txpool and `eth_getTransactionByHash` returns null until a builder lands it.

**Quote movement.** You are bundled with the quotes live when the tx is
matched, just before the block, not the snapshot you simulated. Set `minAmountOut` with room for
that; it is your price protection.

**A landed receipt may be a revert.** Your tx is listed as revertible in the
bundle. If state moves between the relayer's re-simulation and block
building (another fill, a price move), or the relayer could not match it
with any quote and sent it alone, it lands with `status: 0x0` instead of
vanishing. Treat it like a revert from a public RPC. Quote txs are never
allowed to revert. If nothing has landed by the bundle's `maxBlockNumber`
(no builder included it), resubmit.

**Wallets.** Send PropAMM fills to the relayer only, and everything else
through your ordinary RPC: a tx that reads no quoted slot goes to the
builders on its own, never to the txpool. Sending the same tx to a public RPC in
parallel is **not recommended**: if the public copy reaches the node's
txpool first through gossip, the submission is refused as already known and
misses the bundle path.

**Solvers and aggregators** MUST only return PropAMM routes to wallets whose
signed transactions reach the relayer. A PropAMM-dependent tx sent only to a
public BSC RPC reverts for lack of its quote update.

### 3.3 `pamm_getPammStateOverrides`

One-shot pull of the caller's overlay, `eth_call`-compatible. An optional
`params[0]` of `{ "routers": ["0x…"] }` keeps only those venues (and the
merged `overrides` honors the same filter); omitted or empty = every venue
you may see:

```json
{
  "blockNumber": 54321099,
  "millisTimestamp": 1789323649752,
  "overrides": { "0xPool": { "0xSlot": "0xValue" } },
  "venues": [
    { "router": "0xRouter", "overrides": { "0xPool": { "0xSlot": "0xValue" } } }
  ]
}
```

- `blockNumber` — the block being built for (tip + 1).
- `overrides` — the merged view (`account → slot → value`), plugging straight
  into `eth_call`'s `stateDiff` parameter on any node.
- `venues` — the same data sliced by the registered router of the quoting
  maker, for venue-level filtering and attribution.

### 3.4 State-override stream — `pamm_subscribe("subscribeNewQuotesV1")` (WS only)

Takers that run their own simulation infrastructure can consume the state
overrides as a live stream instead of polling: the same frame as
`pamm_getPammStateOverrides`, pushed over WebSocket on a fixed interval
(default 100 ms).

Subscribe with standard Ethereum pub/sub under the `pamm` namespace:

```json
{ "jsonrpc": "2.0", "id": 1, "method": "pamm_subscribe",
  "params": ["subscribeNewQuotesV1", { "routers": [] }] }
```

The result is a subscription id; frames then arrive as `pamm_subscription`
notifications:

```json
{
  "jsonrpc": "2.0",
  "method": "pamm_subscription",
  "params": {
    "subscription": "0xcd0c3e8af590364c09d0fa6a1210faf5",
    "result": {
      "blockNumber": 54321099,
      "millisTimestamp": 1789323649752,
      "overrides": {
        "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
          "0x09c6d2…55f1": "0x00000000000000000000000000000000000000000000000ddf4ae7657b0000"
        }
      },
      "venues": [{
        "router": "0x2a291e911864137801eb582b14fbda874b46ec94",
        "overrides": {
          "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
            "0x09c6d2…55f1": "0x00000000000000000000000000000000000000000000000ddf4ae7657b0000"
          }
        }
      }]
    }
  }
}
```

- **Each frame is a complete snapshot** of every live quote in your view.
  Keep the newest and treat older ones as superseded — no diffing on your
  side.
- `overrides` is the merged view (`account → slot → value`), already
  conflict-resolved: where several quotes write the same slot, the value you
  see is the one a fill would execute against. `venues` is the same data
  sliced per maker router, for venue-level attribution and filtering.
- `routers` narrows the stream to the venues you care about (empty or
  omitted = every venue you may see). The merged `overrides` honors the same
  filter, so the two sections always agree.
- A frame with an empty `overrides` means there are no live quotes for your
  view right now — for example right after a relayer restart.
- Unsubscribe with `pamm_unsubscribe([subscriptionId])`, or just close the
  socket.

**Pricing with a frame.** `overrides` plugs directly into the state-override
parameter of `eth_call` on any node, as `stateDiff`:

```json
{
  "method": "eth_call",
  "params": [
    { "to": "<pool>", "data": "<quote(tokenIn, tokenOut, amountIn) calldata>" },
    "latest",
    {
      "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
        "stateDiff": { "0x09c6d2…55f1": "0x…7b0000" }
      }
    }
  ]
}
```

`blockNumber` is the block the quotes are valid for — the one currently being
built. If a pool checks quote freshness against `block.number` on-chain,
simulate against that block (pass a block override, `eth_call`'s 4th
parameter, on nodes that support it) so a quote at the edge of its deadline
prices correctly.

### 3.5 Price levels

Takers can also consume a live **price-level stream**. Unlike the
state-override stream — raw storage you still have to quote against — these
levels are **already quoted by the relayer and grouped per pool**: a
ready-to-use order book for every pool and pair in your view, refreshed
continuously against the live quote overlay.

Levels come in two variants:

- **`simulated`** — derived from EVM simulations of the pool's
  `quote(tokenIn, tokenOut, amountIn)`. The quoted sizes follow a geometric
  progression, so one ladder covers a wide range of trade sizes.
- **`interpolated`** — intermediate levels generated between the simulated
  quotes using linear interpolation: a more convenient set of sizes at the
  cost of a small approximation error.

Each message is a **complete snapshot**: keep the newest and treat older
ones as superseded. Within a pair, levels ascend by `amountIn`; a direction's
ladder stops at the first size the pool cannot quote. Pairs come from the
pool's `getPairs()`, so a pair the maker did not register has no ladder.

The ladder is computed once per tick (reference default 200 ms;
`priceLevels.intervalMs` in `pamm_status`) on the full overlay, and only while someone consumes it: a live
subscription, or a `pamm_getPammPriceLevels` call within the last 30 seconds.
A pool is in your ladder only if your view includes **every** maker registered
on that pool; a pool with no registered maker is visible to everyone.

Two ways to consume, both returning the same shape:

- `pamm_getPammPriceLevels` — one-shot JSON-RPC pull. The first call after a
  quiet period may take about a second while the ladder is computed;
  `relayer busy, retry` means exactly that.
- `pamm_subscribe("subscribePriceLevelsV1", { "pamms": [] })` — WebSocket
  push of every new snapshot; a non-empty `pamms` list narrows the stream to
  those pool addresses.

```json
{
  "blockNumber": 54321099,
  "millisTimestamp": 1789323649752,
  "pamms": [{
    "pamm": "0x5979458912f80b96d30d4220af8e2e4925a33320",
    "pairs": [{
      "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
      "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      "levels": [
        { "amountIn": "0x989680",  "amountOut": "0x174b67393", "source": "simulated" },
        { "amountIn": "0xaa810a",  "amountOut": "0x1a0781260", "source": "interpolated" },
        { "amountIn": "0xbc6b0a4", "amountOut": "0x1cc38b120", "source": "simulated" }
      ]
    }]
  }]
}
```

#### Single-size quote helpers

Two convenience methods answer "how much tokenOut for this amountIn" straight
off the cached ladder. Like `pamm_getPammPriceLevels`, they keep the ladder
computing, but they never run a simulation of their own:

- `pamm_getPammQuoteVenue(pamm, tokenIn, tokenOut, amountIn)` — the quote on
  one pool. `source` is `simulated` when `amountIn` sits exactly on a ladder
  level, `interpolated` when it falls between two (linear); a size outside
  the quoted range is refused with `amountIn outside the quoted size range`.
- `pamm_getPammQuote(tokenIn, tokenOut, amountIn)` — the best `amountOut`
  across every pool in your ladder, with the `pamm` offering it; refused with
  `no quote for this pair` when nothing in your view covers the pair.

```json
{
  "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
  "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
  "amountIn": "0xa21fe80",
  "amountOut": "0x18b721a60",
  "pamm": "0x5979458912f80b96d30d4220af8e2e4925a33320",
  "source": "interpolated",
  "blockNumber": 54321099,
  "millisTimestamp": 1789323649752
}
```

### 3.6 Builder routing

An approved taker picks, in the console, which builders may receive the
bundles filling its orders (by builder product, e.g. `48club` /
`blockrazor`, or a specific endpoint name). Empty selection = every builder.
The choice travels with the taker's `x-api-key`; a selection matching no
builder connected to a given relayer refuses the submission there
(`no builder available for this taker`) — the exclusion is honored, never
widened.

---

## 4. Operational introspection

### `pamm_status`

```json
{
  "ready": true,
  "targetBlock": 121693514,
  "quotes": 1, "liveQuotes": 1, "overlaySlots": 1,
  "builders": ["48club", "blockrazor"],
  "pendingBundles": 0,
  "pendingTakerTxs": 0,
  "matchLeadTimeMs": 150,
  "heldTakerTxs": 0,
  "takerHoldBlocks": 5,
  "maxQuoteAgeMs": 120000,
  "makerLivenessMs": 450,
  "quoteStreamSubscribers": 0,
  "priceLevels": {
    "intervalMs": 200, "subscribers": 1,
    "pamms": 1, "levels": 45,
    "computedAt": 1789323649752, "lastComputeMs": 12
  },
  "directory": {
    "console": "https://console.example", "loaded": true,
    "snapshotAt": 1789323649752, "generatedAt": "2026-09-13T18:20:49.775Z",
    "makers": 2, "takers": 2, "keys": 4,
    "refreshIntervalMs": 60000, "maxAgeMs": 600000
  },
  "peering": { "url": "redis.internal:6379/0", "channel": "pamm-quotes", "nodeId": "f3a1…", "connected": true, "shared": 41, "received": 0 }
}
```

- `ready` — the relayer is synchronized with the chain (reference rule: five
  consecutive chain heads, each within 3 seconds of wall-clock time) and
  falls back to `false` as soon as a head arrives late. While `false`, quote
  ingest and taker submissions return `propamm engine not ready` and no
  overlay is applied.
- `pendingTakerTxs` / `matchLeadTimeMs` — taker txs waiting to be matched,
  and how long before the expected next block matching runs (§3.2).
- `heldTakerTxs` / `takerHoldBlocks` — unmatched approves currently held, and
  the hold window in blocks (`0` = holding disabled).
- `maxQuoteAgeMs` — the quote-age bound (§2.5); `0` = disabled.
- `makerLivenessMs` — the maker liveness window (§2.5); `0` or negative =
  disabled.
- `directory` — the console snapshot the relayer authorizes against; `loaded`
  false or a `snapshotAt` older than `maxAgeMs` means the relayer is failing
  closed (§1). Absent on a relayer running without a console.
- `peering` — quote sharing with the operator's other relayers; absent when
  not configured.
- `builders` — the configured builder endpoints by name.
- No key material ever appears in the status.

---

## 5. Semantics worth knowing

- **Visibility is a view, not a filter.** Pricing, venue attribution,
  matching and builder routing all resolve from one snapshot per request; per
  slot the freshest quote *the caller may see* wins, so a hidden maker's
  fresher quote never shadows a visible maker's value, and a taker is bundled
  with exactly what priced it.
- **Freshness is block-aligned, liveness is not.** The relayer reaps expired
  and aged quotes on every new block; there is no per-quote age check per
  request because a bundle cannot land before the next block anyway. The one
  sub-block check is per maker: a maker quiet for longer than the liveness
  window is hidden, not reaped, and comes back with its next message (§2.5).
- **Matching runs just before the block.** A taker tx is matched shortly
  before the next block, so it meets quotes the makers signed after the
  previous one (§3.2).
- **Atomicity.** Quote txs are ordered oldest-first so the freshest quote is
  the last writer of every contested slot; quote txs may be dropped but never
  revert; the taker tx is never dropped but may land reverted.
- **Bundled, held or sent alone — never pooled.** A tx that fails the
  arrival checks is refused with the reason. Everything accepted reaches the
  builders: bundled with the quotes it read, held for a few blocks (an
  unmatched approve), or alone and revertible when there is nothing to bundle
  it with. Nothing goes to the public txpool, and nothing vanishes. Keep
  non-PropAMM traffic on your ordinary RPC: a tx that reads no quote lands
  on its own, with no quote behind it.
- **Just-in-time inclusion.** Unmatched quote txs never reach builders or the
  public txpool; a quote costs gas only when it produces a fill.
