# PropAMM Standard

> 中文版：[README.zh-CN.md](./README.zh-CN.md)

The on-chain standard and integration guide for **PropAMM** on BNB Chain — a
builder-neutral execution layer for proprietary AMMs, specified in
[BAP-710](https://github.com/bnb-chain/BEPs/pull/710).

> **Maker sends quotes. Taker sends transactions. Relayer builds bundles.**

A PropAMM is a market-maker operated pool whose pricing is driven by
off-chain quotes rather than an on-chain curve. Makers stream signed quote
update transactions to a **Unified PropAMM Relayer**; the quotes stay
off-chain until a taker transaction actually depends on them, then land
atomically in the same bundle, immediately before the trade. Takers never
learn a bundle API: they price and fill through standard EVM JSON-RPC.

## The three layers

| Layer | What it is | Where |
| --- | --- | --- |
| **PropAMM Oracle** | `PrioUpdateRegistry` — an on-chain registry of maker-published pricing state, organised in per-target *lanes* with replay-protected direct writes and optional decoder-managed lanes | [`contracts/PrioUpdateRegistry.sol`](./contracts/PrioUpdateRegistry.sol) · [model doc](./contracts/PrioUpdateRegistry.md) · [`SignedSeqDecoder.sol`](./contracts/SignedSeqDecoder.sol) · BSC: `0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB` |
| **PropAMM Pool Interface** | `IPropAMM` — the taker-facing pool surface (`isActive`, `getPairs`, `quote`, `swap`) every integrated pool implements, so wallets, aggregators and solvers need one adapter. `swap` is push-payment: `tokenIn` is transferred to the pool and consumed in the same transaction | [`contracts/IPropAMM.sol`](./contracts/IPropAMM.sol) |
| **Unified PropAMM Relayer** | A BNB Chain full node fork that authorizes makers, overlays live quotes on chain state for taker simulation, matches taker transactions to the quotes they read, and broadcasts `[quote txs…, taker tx]` bundles to every connected builder | operated infrastructure; API in [`docs/api-guide.md`](./docs/api-guide.md) |

## Start here

- **Onboarding (maker & taker)** — [`docs/onboarding.md`](./docs/onboarding.md)
- **Relayer API reference** — [`docs/api-guide.md`](./docs/api-guide.md)
- **Reference contracts** (layout, fill path, build / test / deploy) — [`contracts/README.md`](./contracts/README.md)
- **Registry model** — [`contracts/PrioUpdateRegistry.md`](./contracts/PrioUpdateRegistry.md)
- **Runnable maker & taker** — [`e2e/README.md`](./e2e/README.md)

## Repository layout

```
docs/
  onboarding.md            # Maker & taker onboarding walkthrough
  api-guide.md             # Full relayer API reference
contracts/                 # Foundry project (solc 0.8.28, cancun)
  PrioUpdateRegistry.sol   # PropAMM Oracle: lane registry (seq-protected direct
                           # writes, optional decoder-managed lanes)
  PrioUpdateRegistry.md    # Registry model: lanes, seq, decoders, storage layout
  SignedSeqDecoder.sol     # Reference decoder: EIP-712 maker-signed updates anyone can relay
  IPropAMM.sol             # PropAMM Pool Interface: isActive / getPairs / quote / swap
  ExamplePammRouter.sol    # Example pool: push-payment IPropAMM priced from the registry
  ExamplePammTaker.sol     # Example taker: transferFrom into the pool + pool.swap in ONE tx
  README.md                # Slot layout, fill path, access control; script/ + test/
  script/Deploy.s.sol      # Deploy registry (optional), pool, taker; authorize maker
  test/                    # Foundry tests incl. the BAP-710 §7.1 / §7.2 cases (signed lanes too)
e2e/
  src/                     # Runnable maker + taker + status / stream / ladder tools (Node.js)
  .env.example             # Config template (copy to .env; never commit secrets)
  README.md                # How to deploy, configure and run the e2e flow
```

> **Naming.** BAP-710 calls the `IPropAMM` contract a *pool* and the contract
> that pushes `tokenIn` and calls `swap` a *router*. The console's "router
> address" and the overlay's `venues[].router` both mean your **pool**, and
> `ExamplePammRouter` is an example pool.

## Key properties

- **Standard-RPC taker integration** — change the RPC endpoint, not the
  transaction model. `eth_call` is answered on chain
  state *plus* the caller's quote overlay;
  `eth_sendRawTransaction` submits an ordinary signed transaction.
- **Push-payment pools** — `IPropAMM.swap` never `transferFrom`s the caller;
  the fill transfers `tokenIn` into the pool and calls `swap` in one
  transaction (an aggregator, or the reference `ExamplePammTaker`). No
  approvals to pools, nothing left resting on a pool.
- **Just-in-time execution** — a quote update is never broadcast on its own.
  It is simulated once, its storage writes feed the overlay, and it reaches
  the chain only inside the bundle that fills it.
- **Builder-neutral** — the relayer fans each bundle out to every connected
  builder; builders stay generic atomic-bundle backends with no
  PropAMM-specific code. Takers may narrow the fanout per account.
- **Fallback safety** — every transaction the relayer cannot bundle (not
  synchronized, no quotes, no collision, simulation failure, no builder)
  continues through the normal txpool. The relayer never behaves worse than
  a vanilla node.
- **Layered freshness** — each quote carries a deadline enforced by the
  relayer and the builders, an optional operator quote-age bound, and an
  optional pool-side expiry check on read; per-lane `seq` stops older updates
  overwriting newer ones on chain.
- **Access control at the relayer** — maker and taker API keys are issued by
  the operator's console, role-bound, and verified in memory on every
  request; makers choose whether their stream is public or restricted to
  ticked takers.

## Security

- **Never commit secrets.** `.env` is gitignored. Use `e2e/.env.example` as a
  template and keep real private keys and API keys local.
- API keys travel in the `x-api-key` header: use the `https://` / `wss://`
  endpoints only. A key is shown once at issuance; rotate or revoke it in the
  console if it leaks.

## References

- [BAP-710 — Unified PropAMM Relayer](https://github.com/bnb-chain/BEPs/pull/710) — motivation, architecture and
  specification.
- Upstream inspiration:
  [flashbots/priority-update-registry](https://github.com/flashbots/priority-update-registry)
  (the registry) and
  [lambdaclass/propamm-router-contracts](https://github.com/lambdaclass/propamm-router-contracts/blob/main/src/interfaces/IPropAMM.sol)
  (the `IPropAMM` pool interface).
