# PropAMM Relayer — API Guide

> 中文版：[api-guide.zh-CN.md](./api-guide.zh-CN.md)

The Unified PropAMM Relayer is a BNB Chain full node with one extra JSON-RPC
namespace (`pamm_*`) for makers and operators, and PropAMM-aware behavior
behind the standard EVM methods takers already use. This guide is the wire
reference for both sides; the normative specification is
[BAP-710](https://github.com/bnb-chain/BEPs/pull/710) §4.4–§4.8.

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
| `x-api-key` | taker | **Optional** everywhere else. A taker key widens the caller's view with the restricted makers that ticked it and applies the taker's builder routing. An unknown key silently degrades to the anonymous public view — identity never breaks a read. |

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
  advances on chain, the live quote is treated as **consumed** and removed;
  sign the next update with the new nonce.
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
used for slot-level conflict resolution and the maker freshness window.

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
- **consumed** — the sender's on-chain nonce advanced past the quote tx;
- **revoked** — the maker lost console approval (applies at the next
  block after the relayer's snapshot refresh).

---

## 3. Taker: pricing and filling

### 3.1 The overlay

For every caller the relayer maintains a **view**: the merged, per-slot
freshest write-set of all live quotes from the makers that caller may see
(public makers for everyone; plus the restricted makers that ticked the
caller's taker key). Simulation methods apply the view automatically:

| Method | Behavior |
| --- | --- |
| `eth_call` | executed on chain state at the canonical tip **plus** the caller's overlay; explicit `stateOverride` arguments win over the overlay |

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
aggregator / router, or the reference `ExamplePammTaker`. The relayer:

1. checks eligibility: a tx already known to the txpool, a replacement of a
   pending tx (same sender and nonce, e.g. speed-up or cancel), a blob tx,
   or one whose gas limit exceeds the simulation cap goes straight to the
   txpool;
2. resolves your view (visible makers + builder routing) from one snapshot;
3. simulates the tx on your overlay, recording every storage slot read
   (including reads in frames that later revert);
4. attributes each quoted slot read to its freshest visible owning quote:
   `quote write-set ∩ taker read-set ≠ ∅ → bundle together`;
5. builds `[quote txs… (oldest received first), your tx]` and re-simulates on
   clean state — quote txs droppable (and physically pruned if they fail),
   your tx mandatory, nothing revertible;
6. sets the bundle's `maxBlockNumber` to the earliest among the matched
   quotes and broadcasts to the selected builders in parallel. Builders keep
   the bundle until that block; the relayer does not rebroadcast or replace
   it.

**Fallback.** If the relayer is not synchronized, no quote is visible to you,
the simulation fails, nothing matches, the matched quotes have expired, every
quote is dropped in re-simulation, or no builder accepts the bundle, the tx
goes to the **normal txpool** exactly as on a plain node. A PropAMM fill on
that path executes without its quote and reverts on chain (the sender pays
gas; no funds move).

**Visibility.** A bundled tx is private order flow: it is not in the public
txpool and `eth_getTransactionByHash` returns null until a builder lands it.

**Quote movement.** You are bundled with the quotes live when your tx
*arrives*, not the snapshot you simulated. Set `minAmountOut` with room for
that; it is your price protection.

**Wallets.** Send the signed tx to the relayer only, or to the relayer first;
non-PropAMM transactions are forwarded through the relayer's own txpool, so a
separate public submission is not needed. Sending the same tx to a public RPC
in parallel is **not recommended**: if the public copy reaches the relayer's
txpool first, the tx is "already known" and misses the bundle path.

**Solvers and aggregators** MUST only return PropAMM routes to wallets whose
signed transactions reach the relayer. A PropAMM-dependent tx sent only to a
public BSC RPC reverts for lack of its quote update.

### 3.3 `pamm_getPammStateOverrides`

One-shot pull of the caller's overlay, `eth_call`-compatible:

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

### 3.6 Builder routing

An approved taker picks, in the console, which builders may receive the
bundles filling its orders (by builder product, e.g. `48club` /
`blockrazor`, or a specific endpoint name). Empty selection = every builder.
The choice travels with the taker's `x-api-key`; a selection matching no
builder connected to a given relayer sends the tx down that relayer's
txpool path instead — the exclusion is honored, never widened.

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
  "maxQuoteAgeMs": 120000,
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
  "peering": { "url": "wss://peer.example", "connected": true, "shared": 41, "received": 0 }
}
```

- `ready` — the relayer is synchronized with the chain (reference rule: five
  consecutive chain heads, each within 3 seconds of wall-clock time) and
  falls back to `false` as soon as a head arrives late. While `false`, quote
  ingest returns `propamm engine not ready`, no overlay is applied and taker
  transactions take the txpool path.
- `maxQuoteAgeMs` — the quote-age bound (§2.5); `0` = disabled.
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
- **Freshness is block-aligned.** The relayer reaps expired / aged / consumed
  quotes on every new block; there is no per-request age check because a
  bundle cannot land before the next block anyway.
- **Atomicity.** Quote txs are ordered oldest-first so the freshest quote is
  the last writer of every contested slot; the taker tx is mandatory; nothing
  in a PropAMM bundle is revertible.
- **Fallback safety.** Every path that does not end in a bundle ends in the
  normal txpool, so routing all transactions through the relayer is never
  worse than using a plain node.
- **Just-in-time inclusion.** Unmatched quote txs never reach builders or the
  public txpool; a quote costs gas only when it produces a fill.
