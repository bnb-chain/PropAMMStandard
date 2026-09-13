# PropAMM Standard

> 中文版：[README.zh-CN.md](./README.zh-CN.md)

The on-chain standard and integration guide for **PropAMM** on BNB Chain — a
builder-neutral execution layer for proprietary AMMs, specified in
[BAP-710](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md).

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
| **PropAMM Oracle** | `PrioUpdateRegistry` — an on-chain registry of maker-published pricing state, organised in per-target *lanes* with replay-protected direct writes and optional decoder-managed lanes | [`contracts/PrioUpdateRegistry.sol`](./contracts/PrioUpdateRegistry.sol) · [model doc](./contracts/PrioUpdateRegistry.md) |
| **PropAMM Pool Interface** | `IPropAMM` — the taker-facing pool surface (`isActive`, `getPairs`, `quote`, `swap`) every integrated pool implements, so wallets, aggregators and solvers need one adapter | [`contracts/IPropAMM.sol`](./contracts/IPropAMM.sol) |
| **Unified PropAMM Relayer** | A BNB Chain full node fork that authorizes makers, overlays live quotes on chain state for taker simulation, matches taker transactions to the quotes they read, and broadcasts `[quote txs…, taker tx]` bundles to every connected builder | operated infrastructure; API in [`docs/api-guide.md`](./docs/api-guide.md) |

## Start here

- **Onboarding (maker & taker)** — [`docs/onboarding.md`](./docs/onboarding.md)
- **Relayer API reference** — [`docs/api-guide.md`](./docs/api-guide.md)
- **Registry model** — [`contracts/PrioUpdateRegistry.md`](./contracts/PrioUpdateRegistry.md)

## Repository layout

```
docs/
  onboarding.md            # Maker & taker onboarding walkthrough
  api-guide.md             # Full relayer API reference
contracts/
  PrioUpdateRegistry.sol   # PropAMM Oracle: lane registry (seq-protected direct
                           # writes, optional decoder-managed lanes)
  PrioUpdateRegistry.md    # Registry model: lanes, seq, decoders, storage layout
  IPropAMM.sol             # PropAMM Pool Interface: isActive / getPairs / quote / swap
```

## Key properties

- **Standard-RPC taker integration** — change the RPC endpoint, not the
  transaction model. `eth_call`, `eth_estimateGas` and `debug_traceCall` are
  answered on chain state *plus* the caller's quote overlay;
  `eth_sendRawTransaction` submits an ordinary signed transaction.
- **Just-in-time execution** — a quote update is never broadcast on its own.
  It is simulated once, its storage writes feed the overlay, and it reaches
  the chain only inside the bundle that fills it.
- **Builder-neutral** — the relayer fans each bundle out to every connected
  builder; builders stay generic atomic-bundle backends with no
  PropAMM-specific code. Takers may narrow the fanout per account.
- **Fail-safe fallback** — every taker failure path (no quotes, no collision,
  simulation failure, no builder) falls through to the normal txpool. The
  relayer never behaves worse than a vanilla node.
- **Access control at the relayer** — maker and taker API keys are issued by
  the operator's console, role-bound, and verified in memory on every
  request; makers choose whether their stream is public or restricted to
  ticked takers.

## References

- [BAP-710 — Unified PropAMM Relayer](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md) — motivation, architecture and specification.
- Upstream inspiration: [flashbots/priority-update-registry](https://github.com/flashbots/priority-update-registry).
