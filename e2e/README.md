# PropAMM Relayer E2E Test

> 中文版：[README.zh-CN.md](./README.zh-CN.md)

End-to-end test against a Unified PropAMM Relayer
([BAP-710](https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-710.md)): a maker streams
quotes in over `pamm_sendQuoteUpdateV1`, and the taker is a plain wallet on
standard JSON-RPC:

```
maker (updateState quote tx)
   └─ pamm_sendQuoteUpdateV1 ─▶ relayer simulates next-block + captures write-set
                                   └─ merges into the pricing overlay
taker (plain wallet)
   ├─ eth_call router.quote      ─▶ overlay applied server-side (no stateOverride)
   └─ eth_sendRawTransaction     ─▶ read/write-set match → [quote txs..., fill]
        ExamplePammTaker.swap        bundle → builders; any failure → txpool
        (= transferFrom into the pool + pool.swap, one tx)
```

What each side needs:

| | this e2e |
|---|---|
| maker ingress | `pamm_sendQuoteUpdateV1`, maker API key in `x-api-key` when the relayer runs with a console (else unauthenticated: run the endpoint privately) |
| quote visibility | per maker setting in the console (public, or ticked takers); optional overlay snapshot stream via `pamm_subscribe` / `subscribeNewQuotesV1` (same view as `eth_call`) |
| price ladder | `pamm_getPammPriceLevels` / `subscribePriceLevelsV1`: the router's pairs quoted at a range of sizes on the caller's view, no slot decoding needed |
| taker pricing | plain `eth_call`, optionally with the taker API key in `x-api-key` to also see restricted makers (overlay is server-side; no `stateOverride` / `blockOverride`). Integrators that price off-relayer can apply the stream's `overrides` as `eth_call` `stateDiff`. |
| taker fill | plain `eth_sendRawTransaction` of one push-and-swap tx (`ExamplePammTaker.swap`; the pool is push-payment), same optional header (no bundle submission) |
| ops | `pamm_status`, `pamm_getPammStateOverrides`, `pamm_subscribe` / `subscribeNewQuotesV1` and `subscribePriceLevelsV1` (WS) |

## 1. Relayer and API keys

Point `RELAYER_RPC` (and optionally `RELAYER_WS`) at the relayer — the hosted
one is `https://propamm.bnbchain.org` / `wss://propamm.bnbchain.org`. Get
`MAKER_API_KEY` / `TAKER_API_KEY` from the console
([`docs/onboarding.md`](../docs/onboarding.md) Step 0); they are sent as
`x-api-key`, which the relayer resolves in memory against the console's
permission snapshot. Set `PUBLIC_RPC` to an ordinary BSC RPC: a relayer
deployment may restrict methods other than the PropAMM-relevant ones.

If you run your own relayer instead (the `--propamm` geth fork), expose the
`pamm` namespace (`--http.api eth,net,web3,pamm`, likewise `--ws.api`) and
configure builders and, for authenticated makers and takers, the console.
Without a console, `pamm_sendQuoteUpdateV1` is an unauthenticated write
method — bind the endpoint privately (BAP-710 §4.4). Either way the relayer
only becomes ready after five consecutive chain heads within 3 s (i.e. a
synced node); check `npm run status`.

## 2. Contracts

The harness drives three example contracts; the sources live in
`../contracts/` (`PrioUpdateRegistry.sol`, `ExamplePammRouter.sol`,
`ExamplePammTaker.sol`, see [`contracts/README.md`](../contracts/README.md))
and `src/abi.js` lists the methods it relies on.
[`script/Deploy.s.sol`](../contracts/script/Deploy.s.sol) does steps 1–3 and 5:

1. Use the operator's `PrioUpdateRegistry` (`ORACLE`, on BSC
   `0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB`, the `.env.example` default; the relayer and the
   overlay only know quotes that write the registry your pool reads). Deploy
   your own `PrioUpdateRegistry()` only on a private test setup. It packs a
   strictly-increasing per-lane `seq` into slot 0 and validates nothing else;
   freshness lives in the pool's own lane layout.
2. Deploy `ExamplePammRouter(registry)` — the example pool. It packs
   `(price, maxBlockNumber)` into one lane word and enforces the inclusive
   deadline on read (`StaleUpdate` past it).
3. Authorize the maker: router owner calls `router.addMaker(MAKER)`; verify
   with `router.isMaker(maker)`.
4. Top up the router itself with `TOKEN_OUT` inventory: plain transfer, then
   call `router.sync(TOKEN_OUT)` so it is booked as inventory (swap pays out
   of the router's own reserve; an un-synced top-up would be read as a pushed
   payment by the next swap).
5. Register the pair for discovery: router owner calls
   `router.addPair(TOKEN_IN, TOKEN_OUT)` (once per pair, either order). The
   relayer's price ladder only quotes pairs `getPairs()` reports; pricing and
   fills work without it.
6. Taker side: hold `TOKEN_IN`. Swap is push-payment (per `IPropAMM`): the
   pool consumes `amountIn` already transferred to it. Two ways to fill:
   - **one tx (recommended)**: deploy `ExamplePammTaker` FROM THE TAKER WALLET
     (no constructor args; only the deployer may call its `swap`),
     `TOKEN_IN.approve(taker, amount)` from that wallet, set `TAKER_CONTRACT`. Its `swap` transferFroms straight into the
     pool and calls `pool.swap` atomically. A pool with a taker allowlist
     must allowlist the taker contract, not the wallet.
   - **two txs** (`TAKER_CONTRACT` empty): the wallet transfers `amountIn` to
     the router via `PUBLIC_RPC`, waits, then sends `swap` via the relayer.

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
  and the swap reverts `NoPrice` / `StaleUpdate` on chain (the taker pays
  gas) — identical to sending it to a vanilla node. The taker gates on `pamm_status`
  (`ready && overlaySlots > 0`) before sending to keep this rare.
- **Push-payment**: with `TAKER_CONTRACT` set the fill is one atomic tx and
  nothing ever rests on the pool. Without it, the e2e pushes `TOKEN_IN` to the
  router in one tx and swaps in the next; between the two the pushed balance
  is claimable by anyone who calls `swap` first (the example router is
  permissionless). Use test amounts on that path.
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
