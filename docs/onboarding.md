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
taker ── eth_call ──▶ chain state + overlay ──▶ priced result
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
trade. Unfilled quotes never cost gas, and any taker transaction the relayer
cannot bundle continues through the normal txpool.

The normative specification is
[BAP-710](https://github.com/bnb-chain/BEPs/pull/710); this guide is the
practical walkthrough.

---

## Step 0 — Console account, role and API key

All access is managed by the **PropAMM console**: <https://console.bnbchain.org/>

1. **Sign in** with your wallet (one signature; the account is created on
   first sign-in).
2. **Request a role** — `maker` or `taker` — under *Roles & Access*. The
   operator's admin approves it.
3. **Issue an API key** under *API Keys*. Keys are **role-bound** — a key acts
   as the role it was issued for (`pamm_maker_…` / `pamm_taker_…`) — and the
   secret is shown **once** at issuance. Store it safely; rotate or revoke it
   in the console at any time.

Every relayer request authenticates with one header (on WebSocket, sent once
in the upgrade handshake):

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
  your pool through one adapter. `swap` is **push-payment**: the caller
  transfers `amountIn` of `tokenIn` to the pool and calls `swap` in the same
  transaction; the pool consumes what was pushed and never `transferFrom`s
  the caller. Your pool must therefore tell a pushed payment apart from its
  own inventory (the reference pool books inventory in `reserves` and treats
  any balance above it as the payment; see
  [`ExamplePammRouter.sol`](../contracts/ExamplePammRouter.sol)). Guard
  `swap` against reentrancy, or a `tokenOut` with a transfer hook can spend
  the same push twice. `quote` MUST return what `swap` would deliver for the
  same inputs and state, and MUST revert when the pair is inactive or the
  quote has expired.
- **Read your price from the [`PrioUpdateRegistry`](../contracts/PrioUpdateRegistry.sol)**.
  The registry stores state per `(target, laneIndex)`; your pool is the
  `target` and reads its own lanes via `getState(laneIndex, count)` /
  `getSlot(laneIndex, slotIndex)`. A natural lane encoding is one lane per
  direction, e.g. `laneFor(tokenIn, tokenOut) = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))`
  — your quoter writes and your pool reads the **same** encoding.

The reference pool keeps one word per direction: an inclusive
`maxBlockNumber` packed above a 160-bit price (BAP-710 §4.2.2). Its read path
inside `quote` and `swap` is:

```solidity
uint256 data = registry.getState(laneFor(tokenIn, tokenOut), 1)[0] & SLOT0_DATA_MASK; // drop the seq bits
if (data == 0) revert NoPrice();
if (block.number > data >> 160) revert StaleUpdate();   // pool-enforced expiry
uint256 price = data & ((1 << 160) - 1);                // 1e18-scaled tokenOut per tokenIn
```

and the maker packs the same word off-chain (`pool.packQuote(price,
maxBlockNumber)` is the on-chain reference). Slot layout, fill path and tests:
[`contracts/README.md`](../contracts/README.md).

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
  `maxBlockNumber` off-chain, but your pool must not trust that alone: an
  unlanded quote tx stays includable until its nonce is consumed, so whoever
  holds it can still land it late.

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
step 4. The updater EOA must also hold enough BNB to pass the relayer's
next-block simulation; gas is only spent when a fill lands the quote tx.

**Alternative: signed updates on a decoder lane.** Instead of authorizing an
updater EOA, a pool can bind a decoder to a lane (`registry.setDecoder`,
permanent) and register a signing key with it. Updates are then EIP-712
payloads signed by that key (an EOA, or an ERC-1271 wallet such as a multisig
or MPC custody), and any account may submit them with
`registry.updateStateWithDecoder(...)`. The reference decoder,
[`SignedSeqDecoder`](../contracts/SignedSeqDecoder.sol) (BAP-710 §4.2.3),
ships in this repository, and the reference pool can use it through
`pool.bindDecoder(tokenIn, tokenOut, decoder)` and
`pool.setSigner(decoder, signer)`. It enforces the same strictly increasing per-lane `seq` and the
same slot-0 layout, so the pool reads both kinds of lane identically. The
relayer accepts either kind of quote tx.

### 3. Register your pool in the console

In the console's *Maker* workspace:

- **Router address** — set it to your deployed pool. Every quote you stream
  is attributed to this venue; takers see it in the overlay's `venues[]` and
  can filter by it. A quote from a maker without a registered router still
  prices takers but carries no venue attribution. Attribution comes only from
  the console; a request cannot claim a pool of its own.
- **Visibility** — `public` (default: every caller, keyed or anonymous, sees
  your quotes) or `restricted` (only the takers you tick). Ticks apply from
  the relayer's next snapshot refresh. Restricted quotes are excluded from
  every other caller's simulation, streams and matching. If you do not want
  your quote state visible to everyone, you MUST restrict it.

Also call `pool.addPair(tokenA, tokenB)` for every pair you quote: the
relayer's price ladder only quotes pairs `getPairs()` reports. Pricing and
fills work without it.

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
- `tx` is your signed `registry.updateState(...)` transaction (or
  `updateStateWithDecoder(...)` on a decoder lane). **An empty `tx` (`0x`)
  cancels the uuid**; the uuid then rejects every update until the cancel's
  `maxBlockNumber`, so continue under a new uuid.
- `maxBlockNumber` is the last block (inclusive) the quote may be filled in;
  `0` and oversized values are clamped to `head + 100` blocks (the reference
  default lifetime cap).

Two rules the reference maker ([`e2e/src/maker.js`](../e2e/src/maker.js))
follows and yours should too:

- **One `seq` for both layers.** The registry `seq` inside the calldata must
  exceed the seq the lane stores on chain (it only advances when a quote tx
  lands, i.e. on a fill); the envelope `seq` must exceed the last one you sent
  under the uuid. They are separate counters, but sending **one value, unix
  milliseconds, for both** keeps them monotonic across restarts. Read the on-chain value
  back with `pool.readQuote(tokenIn, tokenOut)`.
- **One deadline for both layers.** Pack the same `maxBlockNumber` into the
  lane word (enforced by your pool) and into the envelope (enforced by the
  relayer and the builders), so the relayer never bundles a quote your pool
  would refuse, and your pool refuses a quote the relayer has already dropped.

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

- **Freshness protection** — four layers bound the age of any filled quote
  (BAP-710 §4.7):
  - the **deadline**: your `maxBlockNumber`; the relayer stops using the
    quote after it, and every bundle carrying it expires at the builders by
    then;
  - the **quote-age bound**: the relayer timestamps each update on arrival
    and, on every new block, drops quotes older than the operator's bound
    regardless of `maxBlockNumber` (`maxQuoteAgeMs` in `pamm_status`; `0`
    means disabled, the reference default — rely on your deadline);
  - **pool-side expiry**: your pool's own deadline check on read (step 1),
    which holds even if a stale update is included;
  - **ordering**: a higher `seq` replaces the older quote in the relayer,
    and the per-lane registry `seq` stops an older update overwriting a
    newer one on chain.
- **Write-scope validation** — the operator may restrict quote txs to writing
  storage of the standard contracts only; an out-of-scope write rejects the
  whole update.
- **Stream ownership** — a uuid belongs to the maker account that created
  it; no other maker can update or cancel it.
- **Cancel semantics** — a cancel takes effect in the relayer immediately,
  but a bundle matched *before* the cancel may still land, bounded by that
  quote's `maxBlockNumber`. Quote with tight deadlines if you re-price fast.
- **Price protection** (a maximum deviation from a reference price) is a
  planned extension, not available yet.

### Maker checklist

| # | Action | Where |
| --- | --- | --- |
| 1 | Sign in, request the `maker` role, get it approved | console |
| 2 | Issue a maker API key (`pamm_maker_…`) | console |
| 3 | Deploy your pool: `IPropAMM` + registry lane reads + deadline check on read (ref. [`ExamplePammRouter.sol`](../contracts/ExamplePammRouter.sol), [`script/Deploy.s.sol`](../contracts/script/Deploy.s.sol)) | you |
| 4 | `pool.addMaker(EOA)` → registry `addUpdater`; fund the EOA with BNB for gas | you |
| 5 | Fund the pool with inventory (reference pool: transfer, then `sync(token)`) | you |
| 6 | `pool.addPair(tokenA, tokenB)` for every pair you quote | you |
| 7 | Set the pool as your **router address**; choose visibility | console |
| 8 | Stream `pamm_sendQuoteUpdateV1` with `x-api-key` (same `maxBlockNumber` in the lane word and the envelope) | you → relayer |

---

## Taker onboarding

### 1. Get a taker API key from the console (optional, but recommended)

Sign in to the [console](https://console.bnbchain.org/), request the `taker`
role, and once it is approved issue a taker key (`pamm_taker_…`) under
*API Keys*. Send it as the `x-api-key` header on every relayer request.

You can also go without a key: anonymous callers see every **public** maker's
quotes. A key additionally gives you:

- quotes from the **restricted** makers that ticked your account, and
- your **builder routing** choice (see step 4).

An unknown or stale key never breaks a read — it simply degrades to the
anonymous public view.

### 2. Get quotes from PropAMM pools

Relayer RPC endpoint: `https://propamm.bnbchain.org` (WebSocket subscriptions
use `wss://` on the same host). Keep your existing BSC RPC for general chain
reads; a relayer deployment may restrict methods beyond the ones described
here. A PropAMM pool's price comes from the makers' quote overlay, which only
the relayer knows. There are three ways to get it, from least to most
integration effort:

**Option A — simulate with `eth_call` directly against the relayer
endpoint.** The simplest: point your pricing RPC at the relayer and call
`IPropAMM.quote` (or simulate your whole fill transaction) exactly like any
other pool; there is no PropAMM-specific request format. `eth_call` is answered on **chain state plus your quote overlay**
(only at the canonical tip; explicit `stateOverride` arguments you pass still
win over the overlay).

**Option B — subscribe to state overrides from the relayer and simulate with
`eth_call` on your own full node.** For takers who run their own simulation
stack and do not want pricing traffic on the relayer:

- one-shot pull: `pamm_getPammStateOverrides`;
- live stream: `pamm_subscribe("subscribeNewQuotesV1")` (WS; a full snapshot
  every 100ms by default — keep only the latest frame).

The returned `overrides` is a merged `account → slot → value` view. Pass it
as the `stateDiff` argument of `eth_call` on your local node and you get the
same quote the relayer would. `venues[]` is the same data sliced by maker
router, for per-venue filtering.

**Option C — read a pool's price directly from price levels.** Takers who do
not want to simulate at all can take a ready-made price ladder: the relayer
has already called `quote` on every pool and pair at several sizes and
returns a level table grouped by pAMM (`amountIn → amountOut`, simulated and
interpolated levels).

- one-shot pull: `pamm_getPammPriceLevels`;
- live stream: `pamm_subscribe("subscribePriceLevelsV1", { "pamms": [...] })`,
  with `pamms` narrowing to the pool addresses you care about.

The ladder only covers pairs the pool reports in `getPairs()`, and a pool
appears only if your view includes every maker registered on it.

All three share the same visibility rules: with a taker key you also see the
restricted makers that ticked you; otherwise only public quotes. Field
details: [`api-guide.md`](./api-guide.md) §3.

### 3. Fill on chain

Once you have a quote you like, sign an ordinary transaction and submit it
with `eth_sendRawTransaction` to the same relayer endpoint, `x-api-key`
attached. No bundle format is needed, and you never assemble quote txs
yourself.

Because pools are push-payment, the fill is a **contract call** that
transfers `amountIn` of `tokenIn` into the pool and calls `IPropAMM.swap` in
the same transaction: an aggregator or router that does this for you, or the
reference [`ExamplePammTaker.sol`](../contracts/ExamplePammTaker.sol)
(`approve` it once, then call its `swap`). A bare wallet call to the pool's
`swap` has nothing pushed and reverts.

On receipt the relayer:

1. resolves your view from your key: which makers' quotes you can see and
   which builders your bundle may go to;
2. simulates the transaction on your quote overlay and records which storage
   slots it reads;
3. for every quoted slot it read, looks up the freshest owning quote tx;
4. places those quote txs in front of yours as `[quote txs…, your tx]` and
   re-simulates the bundle on clean chain state;
5. if the simulation succeeds, broadcasts the bundle to the connected builders
   in parallel.

Things to know before you send real size:

- **`minAmountOut` is your price protection.** You are bundled with the
  quotes live when your tx *arrives*, not the snapshot you simulated, so
  leave room for quote movement.
- **Fallback.** Anything the relayer cannot bundle (not synchronized, no
  matching quote, failed re-simulation, no builder accepts, a nonce
  replacement of a pending tx, …) goes to the normal txpool, exactly as on a
  plain node. A PropAMM fill there executes without its quote and reverts:
  you pay gas, no funds move.
- **Private until landed.** A bundled tx is not in the public txpool;
  `eth_getTransactionByHash` returns null until a builder includes it.
- **Send to the relayer only.** Do not broadcast the same signed tx to a
  public RPC in parallel: if the public copy reaches the relayer's txpool
  first, it is "already known" and misses the bundle path. Non-PropAMM
  transactions sent to the relayer are forwarded through its txpool anyway.
- **Solvers and aggregators** MUST only return PropAMM routes to wallets
  whose signed transactions reach the relayer; the same tx sent only to a
  public BSC RPC reverts.

### 4. Builder routing (optional)

By default the relayer sends your bundle to every builder it is connected
to, including builders added later. To send only to specific ones, tick them
by product in the console's *Taker → Builder Routing* page (e.g. `48club`,
`blockrazor`).

The ticks are an allowlist: anything unticked is never used. If none of your
ticked builders is configured on a given relayer, your transaction goes to
the public txpool there instead. Changes apply at the relayer's next snapshot
refresh.

### Taker checklist

| # | Action | Where |
| --- | --- | --- |
| 1 | Sign in, request the `taker` role, get it approved | console |
| 2 | Issue a taker API key (`pamm_taker_…`) | console |
| 3 | To see a restricted maker's quotes, ask them to tick your account in their console | maker's console |
| 4 | (Optional) tick builders under *Builder Routing* | console |
| 5 | Get quotes with `x-api-key` (any of the three ways in §2) | you → relayer |
| 6 | Fill via `eth_sendRawTransaction` to the relayer only, with a push-and-swap contract call (e.g. `ExamplePammTaker`) and a `minAmountOut` that allows for quote movement | you → relayer |

---

## Deployment addresses

| Name | Value |
| --- | --- |
| Relayer RPC (HTTP) | <https://propamm.bnbchain.org> |
| Relayer RPC (WS, subscription methods) | `wss://propamm.bnbchain.org` |
| Console | <https://console.bnbchain.org/> |
| `PrioUpdateRegistry` (oracle, BSC) | [`0x4EaBe41ccAEcdbb16b7CE67D893E698757D2C9AD`](https://bscscan.com/address/0x4EaBe41ccAEcdbb16b7CE67D893E698757D2C9AD) |
| Your pool / router | *(you — set it in the console after deploying)* |

## References

- [`api-guide.md`](./api-guide.md) — the full relayer API reference.
- [`contracts/README.md`](../contracts/README.md) — reference pool slot
  layout, fill path, access control, build / test / deploy.
- [`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md) — lanes, seq,
  decoder-managed lanes, storage layout, errors.
- [`e2e/README.md`](../e2e/README.md) — runnable maker and taker against a
  live relayer.
- [BAP-710](https://github.com/bnb-chain/BEPs/pull/710) — specification, architecture and rationale.
