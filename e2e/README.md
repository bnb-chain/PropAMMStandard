# PropAMM Relayer E2E Test

End-to-end test for this repo's unified PropAMM relayer: a maker streams
quotes in over `pamm_sendQuoteUpdateV1`, and the taker is a plain wallet on
standard JSON-RPC:

```
maker (updateState quote tx)
   └─ pamm_sendQuoteUpdateV1 ─▶ relayer simulates next-block + captures write-set
                                   └─ merges into the pricing overlay
taker (plain wallet)
   ├─ eth_call router.quote      ─▶ overlay applied server-side (no stateOverride)
   └─ eth_sendRawTransaction     ─▶ read/write-set match → [quote txs..., swap]
        router.swap                  bundle → builders; any failure → txpool
```

What each side needs:

| | this e2e |
|---|---|
| maker ingress | `pamm_sendQuoteUpdateV1`, maker API key in `x-api-key` when the relayer runs with a console (else unauthenticated: run the endpoint privately) |
| quote visibility | per maker setting in the console (public, or ticked takers); optional overlay snapshot stream via `pamm_subscribe` / `subscribeNewQuotesV1` (same view as `eth_call`) |
| price ladder | `pamm_getPammPriceLevels` / `subscribePriceLevelsV1`: the router's pairs quoted at a range of sizes on the caller's view, no slot decoding needed |
| taker pricing | plain `eth_call`, optionally with the taker API key in `x-api-key` to also see restricted makers (overlay is server-side; no `stateOverride` / `blockOverride`). Integrators that price off-relayer can apply the stream's `overrides` as `eth_call` `stateDiff`. |
| taker fill | plain `eth_sendRawTransaction`, same optional header (no bundle submission) |
| ops | `pamm_status`, `pamm_getPammStateOverrides`, `pamm_subscribe` / `subscribeNewQuotesV1` and `subscribePriceLevelsV1` (WS) |

## 1. Node

Build and run this repo's geth with the relayer enabled and the `pamm`
namespace exposed (the relayer never widens the allowlist itself):

```bash
make geth
./build/bin/geth --propamm \
  --propamm.builders "builder-a=https://builder-a.example" \
  --http --http.api eth,net,web3,pamm \
  ...
```

Add `--propamm.console.url https://console.example` and
`GETH_PROPAMM_CONSOLE_KEY=pamm_relayer_…` to scope makers and takers through
the PropAMM console; then set `MAKER_API_KEY` / `TAKER_API_KEY` in `.env`
(API keys issued to approved maker / taker accounts in the console — sent as
`x-api-key`, which the relayer resolves in memory against the console's
permission snapshot). Without a console, `pamm_sendQuoteUpdateV1` is an
unauthenticated write method — bind the HTTP/WS endpoint privately. The
relayer only becomes ready after five consecutive chain heads within 3 s
(i.e. a synced node); check `npm run status`.

## 2. Contracts

The harness drives two example contracts; the sources live in
`./contracts/` (`PrioUpdateRegistry.sol`, `ExamplePammRouter.sol`) and
`src/abi.js` lists the methods it relies on:

1. Deploy `PrioUpdateRegistry()` — the raw slot store. It packs a
   strictly-increasing per-lane `seq` into slot 0 and validates nothing else;
   freshness lives in the router's own lane layout.
2. Deploy `ExamplePammRouter(registry)` — the settlement contract. It packs
   `(price, maxBlockNumber)` into one lane word and enforces the inclusive
   deadline on read (`StaleUpdate` past it).
3. Authorize the maker: router owner calls `router.addMaker(MAKER)`; verify
   with `router.isMaker(maker)`.
4. Top up the router itself with `TOKEN_OUT` inventory (plain transfer; swap
   pays out of the router's own balance).
5. Register the pair for discovery: router owner calls
   `router.addPair(TOKEN_IN, TOKEN_OUT)` (once per pair, either order). The
   relayer's price ladder only quotes pairs `getPairs()` reports; pricing and
   fills work without it.
6. Taker side: hold `TOKEN_IN` and `TOKEN_IN.approve(router, amount)` — swap
   is pull-payment, one approve is all a fill needs.

The maker account must also hold enough BNB to pass the balance check in the
relayer's next-block simulation (gas is only really spent when a fill lands
the quote tx on chain).

## 3. Configure & run

```bash
cp .env.example .env   # fill in ORACLE / ROUTER / MAKER_PK / TAKER_PK
npm install

# Terminal A: stream quotes into the relayer
npm run maker

# Terminal B: check the relayer picked them up (ready, overlay, decoded lane)
npm run status

# Optional: watch the overlay snapshot stream (needs RELAYER_WS)
npm run stream

# Optional: watch the price ladder (streams over RELAYER_WS, polls over HTTP
# otherwise); needs router.addPair for the pair
npm run levels

# Terminal C: price + fill (TAKER_DRY_RUN=1 by default: simulate only)
npm run taker
```

The taker prints the overlay-priced `amountOut` per poll (set `COMPARE_RPC` to
a vanilla node to also print the counterfactual — the same call there reverts
`NoPrice`/`StaleUpdate`). With `TAKER_DRY_RUN=0` it sends the swap once and
watches for landing.

## What to expect

- **While bundled, the tx is invisible**: `eth_getTransactionByHash` returns
  null and it is not in the txpool; it appears when a builder lands the
  bundle. The watcher logs this state explicitly.
- **Fallback executes without the quote**: if the relayer is not ready, there
  is no collision, or all builders are down, the tx goes to the public txpool
  and the swap reverts `NoPrice` on chain (the taker pays gas) — identical to
  sending it to a vanilla node. The taker gates on `pamm_status`
  (`ready && overlaySlots > 0`) before sending to keep this rare.
- **Slippage is your only price protection**: the relayer bundles the maker's
  latest resting quote, not the frame you simulated, so keep
  `TAKER_SLIPPAGE_BPS` > 0.
- **Maker nonce reuse works**: the quote tx is a carrier for the captured
  write-set; the same nonce streams until a fill consumes it (the maker
  refreshes the pending nonce every round). `UPDATE_ONCHAIN=1` publishes quotes
  through the txpool too, which needs bumped/rotated nonces
  ("replacement underpriced" otherwise).
- **Ctrl-C cancels**: the maker sends an empty-tx cancel on exit, tombstoning
  the uuid so stale quotes do not linger until `maxBlockNumber`.
