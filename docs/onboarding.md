# PropAMM — Maker & Taker Onboarding

> 中文版：[onboarding.zh-CN.md](./onboarding.zh-CN.md)

This guide walks a market maker and a taker through onboarding onto a
**Unified PropAMM Relayer** deployment:

- **Maker** — get a maker API key, deploy a pool that reads its price from the
  `PrioUpdateRegistry`, register your pool in the console, and stream signed
  quote update transactions.
- **Taker** — get a taker API key (optional for public quotes), price through
  standard EVM RPC against the relayer, and submit ordinary signed
  transactions that fill quotes atomically.

```
maker ── pamm_sendQuoteUpdateV1 (x-api-key) ──▶ relayer
 (signed registry.updateState tx,                │ authorize maker · simulate quote tx
  never broadcast on its own)                    │ capture write-set → per-caller overlay
                                                 ▼
taker ── eth_call / debug_traceCall ──▶ chain state + overlay ──▶ priced result
  │        (x-api-key optional)
  ▼
taker ── eth_sendRawTransaction ──▶ match read slots → owning quotes
                                                 │ [quote txs…, taker tx] re-simulated
                                                 ▼
                                    atomic bundle → every connected builder
```

A quote is a signed, executable `registry.updateState(...)` transaction that
is **never broadcast on its own**. The relayer simulates it once, captures the
storage it writes, and prices takers against that overlay. When a taker
transaction actually *reads* a quoted slot, the relayer prepends the owning
quote tx to the taker tx and broadcasts the pair as one atomic bundle — the
quoted state materializes on chain in the same block, immediately before the
trade. Unfilled quotes never cost gas.

---

## Step 0 — Console account, role and API key

All access is managed by the operator's **PropAMM console** (URL provided by
your operator):

1. **Sign in** with your wallet (one signature; the account is created on
   first sign-in).
2. **Request a role** — `maker` or `taker` — under *Roles & Access*. The
   operator's admin approves it.
3. **Issue an API key** under *API Keys*. Keys are **role-bound** — a key acts
   as the role it was issued for (`pamm_maker_…` / `pamm_taker_…`) — and the
   secret is shown **once** at issuance. Store it safely; rotate or revoke it
   in the console at any time.

Every relayer request authenticates with one header:

| Header | Who | Purpose |
| --- | --- | --- |
| `x-api-key` | maker (required), taker (optional) | Resolved in-memory by the relayer against the console's key table. Quote updates require a **maker** key; a taker key unlocks restricted makers and the taker's builder routing. |

The relayer never calls the console on a request path — it refreshes the
relationship snapshot periodically (about once a minute), so console changes
(key rotation, role revocation, visibility ticks) take effect within one
refresh.

---

## Maker onboarding

### 1. Deploy your pool (the `IPropAMM` + registry integration)

Your pool is the venue takers price and fill against. Two integration
requirements:

- **Implement [`IPropAMM`](../contracts/IPropAMM.sol)** — `isActive`,
  `getPairs`, `quote`, `swap` — so every wallet, aggregator and solver can use
  your pool through one adapter. `swap` is push-payment: the caller transfers
  `amountIn` of `tokenIn` to the pool before the call.
- **Read your price from the [`PrioUpdateRegistry`](../contracts/PrioUpdateRegistry.sol)**.
  The registry stores state per `(target, laneIndex)`; your pool is the
  `target` and reads its own lanes via `getState(laneIndex, count)` /
  `getSlot(laneIndex, slotIndex)`. A natural lane encoding is one lane per
  direction, e.g. `laneFor(tokenIn, tokenOut) = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))`
  — your quoter writes and your pool reads the **same** encoding.

Two registry facts shape your slot layout (full model:
[`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md)):

- **Replay protection is the registry's job.** Every direct write carries a
  48-bit `seq` that must strictly increase per lane; the registry packs it
  into the **top 48 bits of slot 0**, so `slots[0]` gives you 208 data bits
  and slots 1+ are full width. An older or replayed update can never
  overwrite a newer one, whoever submits it.
- **Freshness is your job.** The registry stores no expiry. Pack your own
  deadline into the lane — e.g. slot 0 = `price` plus a `maxBlockNumber`
  within the 208 data bits — and have the pool revert once `block.number`
  passes it. The relayer independently enforces each quote's
  `maxBlockNumber` off-chain, but your pool must not trust that alone:
  on-chain state outlives the relayer's window.

### 2. Authorize your quoting EOA on the registry

Registry updater management is called **by the target** (your pool), so give
your pool an owner-gated helper:

```solidity
function addMaker(address maker) external onlyOwner { REGISTRY.addUpdater(maker); }
function removeMaker(address maker) external onlyOwner { REGISTRY.removeUpdater(maker); }
```

Only an authorized updater can write your pool's lanes
(`registry.updateState(pool, lane, slots, seq)` reverts `NotAuthorized()`
otherwise). Use a **dedicated EOA per quote stream** — see the nonce note in
step 4.

### 3. Register your pool in the console

In the console's *Maker* workspace:

- **Router address** — set it to your deployed pool. Every quote you stream
  is attributed to this venue; takers see it in the overlay's `venues[]` and
  can filter by it. A quote from a maker without a registered router still
  prices takers but carries no venue attribution.
- **Visibility** — `public` (default: every caller, keyed or anonymous, sees
  your quotes) or `restricted` (only the takers you tick). Ticks apply from
  the relayer's next snapshot refresh.

### 4. Stream quotes

One JSON-RPC call per update, HTTP or WebSocket, with your maker key in
`x-api-key` (over WS you can pipeline many calls; responses are correlated by
request id):

```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "pamm_sendQuoteUpdateV1",
  "params": [{
    "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44",
    "seq": 7,
    "tx": "0x02f8...",
    "maxBlockNumber": 54321098
  }]
}
```

- `uuid` (16 bytes) identifies one quote stream — typically one per market.
  A newer `seq` under the same uuid **replaces** the previous quote.
- `tx` is your RLP-encoded signed `registry.updateState(...)` transaction.
  **An empty `tx` (`0x`) cancels the uuid permanently.**
- `maxBlockNumber` is the last block (inclusive) the quote may be filled in;
  `0` and oversized values are clamped to the relayer's per-quote lifetime
  cap.
- The registry-level `seq` inside your tx's calldata and the stream-level
  `seq` in the update envelope are separate counters; keeping them equal is a
  convenient convention.

Requirements on the quote tx — the relayer simulates it on the next block and
rejects it if it fails:

- It must **execute successfully** (a revert is returned as the update error).
- Sign with the EOA's **current on-chain nonce**; since the tx does not land
  on its own, **every update of the stream reuses that nonce**. Once the
  nonce advances on chain (a fill, or any other tx you send), the live quote
  is *consumed* and dropped — sign the next update with the new nonce.
- Keep it a **pure setter**: writes must depend only on calldata. The
  captured write-set is reused as-is until replaced.
- All quote txs from one EOA share a nonce, so two of your streams can never
  be filled in the same bundle — use one EOA per stream if your streams may
  be matched together.
- When filled, the tx lands on chain and pays its own gas at the price you
  signed.

Full request/response schema and every error string:
[`api-guide.md`](./api-guide.md) §2.

### 5. Maker protections

- **Freshness protection** — the relayer timestamps each update on arrival
  and drops quotes older than the operator-configured window (`MaxQuoteAge`)
  on every new block, regardless of `maxBlockNumber`. Keep quoting; a stale
  stream simply stops matching.
- **Write-scope validation** — the operator may restrict quote txs to writing
  storage of the standard contracts only; an out-of-scope write rejects the
  whole update.
- **Cancel semantics** — a cancel takes effect in the relayer immediately,
  but a bundle matched *before* the cancel may still land, bounded by that
  quote's `maxBlockNumber`. Quote with tight deadlines if you re-price fast.

### Maker checklist

| # | Action | Where |
| --- | --- | --- |
| 1 | Sign in, request the `maker` role, get it approved | console |
| 2 | Issue a maker API key (`pamm_maker_…`) | console |
| 3 | Deploy your pool: `IPropAMM` + registry lane reads | you |
| 4 | `pool.addMaker(EOA)` → registry `addUpdater` | you |
| 5 | Fund the pool with inventory | you |
| 6 | Set the pool as your **router address**; choose visibility | console |
| 7 | Stream `pamm_sendQuoteUpdateV1` with `x-api-key` | you → relayer |

---

## Taker onboarding

### 1. Key (optional, but recommended)

Anonymous callers see every **public** maker's quotes. A taker API key adds:

- the **restricted** makers that ticked your account, and
- your **builder routing** choice (below).

Send it as `x-api-key` on every relayer request. An unknown or stale key
never breaks a read — it simply degrades to the anonymous public view.

### 2. Price

Point pricing at the relayer's RPC endpoint. Simulation methods are answered
on **chain state plus your quote overlay** (only at the canonical tip;
explicit `stateOverride` arguments you pass still win over the overlay):

- `eth_call`, `eth_estimateGas`, `debug_traceCall` — quote `IPropAMM.quote`
  / `swap` exactly like any other pool; no PropAMM-specific plumbing.
- `pamm_getPammStateOverrides` — pull your merged overlay as an
  `eth_call`-compatible `stateDiff` (per-venue slices included) if you prefer
  to simulate elsewhere.
- `pamm_subscribe("subscribeNewQuotesV1")` — the same frame pushed on an
  interval over WebSocket.
- `pamm_getPammPriceLevels` / `pamm_subscribe("subscribePriceLevelsV1")` — a
  ready-made price ladder: every pool's pairs quoted at several sizes on your
  view.

### 3. Fill

Sign an ordinary transaction (e.g. calling your route through
`IPropAMM.swap`) and submit it with `eth_sendRawTransaction` to the same
endpoint, `x-api-key` attached. The relayer then:

1. simulates your tx on your overlay and records every storage slot it reads;
2. attributes each quoted slot it read to the freshest owning quote you may
   see;
3. builds `[quote txs…, your tx]`, re-simulates the bundle on clean state
   (quote txs droppable, your tx mandatory);
4. broadcasts it to the connected builders — all of them, or the subset you
   picked in the console.

If any step finds nothing to do — no quote read, over budget, simulation
failure, no builder ack — your transaction **falls through to the normal
txpool**: submitting through the relayer is never worse than a vanilla node.
Two notes:

- a nonce-replacement (speed-up / cancel) of a pending tx is never bundled —
  it goes to the txpool so it can displace the original;
- competing fills of one quote carry the same quote tx; the first bundle to
  land wins and the loser drops on the nonce. Price your tip accordingly.

### 4. Builder routing (optional)

In the console's *Taker → Builder Routing* page, tick the builders your
bundles may go to (by builder product, e.g. `48club`, `blockrazor`). Nothing
ticked = every builder the relayer runs, including builders added later.
Ticking a subset **excludes** the rest: if none of your ticked builders is
configured on a given relayer, your transaction takes the public txpool route
there instead. Changes apply at the relayer's next snapshot refresh.

### Taker checklist

| # | Action | Where |
| --- | --- | --- |
| 1 | Sign in, request the `taker` role, get it approved | console |
| 2 | Issue a taker API key (`pamm_taker_…`) | console |
| 3 | Ask restricted makers to tick your account id | maker's console |
| 4 | (Optional) pick builders under *Builder Routing* | console |
| 5 | Price via `eth_call` etc. with `x-api-key`, fill via `eth_sendRawTransaction` | you → relayer |

---

## Deployment addresses

Provided by your relayer operator:

| Name | Value |
| --- | --- |
| Relayer RPC (HTTP / WS) | *(operator)* |
| Console | *(operator)* |
| `PrioUpdateRegistry` | *(operator; one shared instance per chain)* |
| Your pool / router | *(you — set it in the console after deploying)* |

## References

- [`api-guide.md`](./api-guide.md) — the full relayer API reference.
- [`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md) — lanes, seq,
  decoder-managed lanes, storage layout, errors.
- [BAP-710](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md) —
  architecture and rationale.
