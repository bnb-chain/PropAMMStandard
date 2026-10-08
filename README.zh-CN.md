# PropAMM 标准

> English: [README.md](./README.md)

BNB Chain 上 **PropAMM** 的链上标准与接入指南——一个 builder 中立的
专业做市执行层，规范见
[BAP-710](https://github.com/bnb-chain/BEPs/pull/710)。

> **Maker 发报价，Taker 发交易，Relayer 组 bundle。**

PropAMM 是由做市商运营、定价来自链下报价而非链上曲线的池子。Maker 把签名的
报价更新交易流式发给 **Unified PropAMM Relayer**；报价一直留在链下，直到某笔
taker 交易真正依赖它，才和这笔交易一起原子落地——在成交前一刻写入链上。
Taker 无需学习任何 bundle API：定价和成交都走标准 EVM JSON-RPC。

## 三层结构

| 层 | 是什么 | 位置 |
| --- | --- | --- |
| **PropAMM Oracle** | `PrioUpdateRegistry`——链上报价状态注册表，按 target 分 *lane* 存储，直写路径带防重放 seq，可选 decoder 托管 lane | [`contracts/PrioUpdateRegistry.sol`](./contracts/PrioUpdateRegistry.sol) · [模型文档](./contracts/PrioUpdateRegistry.md)（英文） · [`SignedSeqDecoder.sol`](./contracts/SignedSeqDecoder.sol) · BSC：`0x9c2bE1De299346914aB7f466AF9D2F58Cd775BAB` |
| **PropAMM Pool 接口** | `IPropAMM`——面向 taker 的统一池子接口（`isActive`、`getPairs`、`quote`、`swap`），钱包、聚合器、solver 只需一个适配器。`swap` 是 push-payment：`tokenIn` 在同一笔交易里先转进池子、再被消费 | [`contracts/IPropAMM.sol`](./contracts/IPropAMM.sol) |
| **Unified PropAMM Relayer** | BNB Chain 全节点分叉：鉴权 maker、把在线报价叠加到链上状态供 taker 模拟、把 taker 交易与其读到的报价撮合成 `[报价 tx…, taker tx]` bundle、广播到所有接入的 builder | 由运营方部署；API 见 [`docs/api-guide.zh-CN.md`](./docs/api-guide.zh-CN.md) |

## 从这里开始

- **接入指南（Maker 与 Taker）** — [`docs/onboarding.zh-CN.md`](./docs/onboarding.zh-CN.md)
- **Relayer API 参考** — [`docs/api-guide.zh-CN.md`](./docs/api-guide.zh-CN.md)
- **参考合约**（布局、成交路径、构建 / 测试 / 部署） — [`contracts/README.md`](./contracts/README.md)（英文）
- **注册表模型** — [`contracts/PrioUpdateRegistry.md`](./contracts/PrioUpdateRegistry.md)
- **可运行的 maker 与 taker** — [`e2e/README.zh-CN.md`](./e2e/README.zh-CN.md)

## 仓库结构

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

> **命名。** BAP-710 把 `IPropAMM` 合约称为 *pool*，把推入 `tokenIn` 并调用
> `swap` 的合约称为 *router*。console 里的「Router 地址」和 overlay 的
> `venues[].router` 指的都是你的**池子**，`ExamplePammRouter` 是一个示例池子。

## 关键性质

- **Taker 走标准 RPC**——换的是 RPC 端点，不是交易模型。`eth_call`
  在链上状态 *加* 调用方报价 overlay 上作答；`eth_sendRawTransaction` 提交的就是一笔普通签名交易。
- **池子 push-payment**——`IPropAMM.swap` 从不对调用方 `transferFrom`；
  成交是在一笔交易里把 `tokenIn` 转进池子并调 `swap`（聚合器，或参考实现
  `ExamplePammTaker`）。不需要对池子授权，池子上也不会残留任何推入余额。
- **即时执行**——报价更新永不单独广播：只模拟一次，写集进 overlay，
  只有在成交 bundle 里才上链。没被成交的报价不花 gas。
- **Builder 中立**——bundle 并行发往所有接入的 builder；builder 只需通用的
  原子 bundle 能力，无 PropAMM 专用代码。Taker 可按账户收窄扇出。
- **回退安全**——relayer 无法组 bundle 的任何交易（未同步、无报价、无碰撞、
  模拟失败、无 builder）都继续走普通 txpool，永远不比原生节点差。
- **分层保鲜**——每条报价带一个由 relayer 和 builder 执行的截止块，另有
  可选的运营方报价时效上限，以及可选的池子读取时过期检查；按 lane 的
  `seq` 防止旧更新在链上覆盖新更新。
- **鉴权在 relayer 完成**——maker / taker API Key 由运营方 console 签发、
  绑定角色，relayer 每个请求在内存中校验；maker 自主选择报价流公开或仅对
  勾选的 taker 可见。

## 安全

- **永远不要提交密钥。** `.env` 已被 gitignore。以 `e2e/.env.example` 为
  模板，真实私钥和 API Key 只留在本地。
- API Key 通过 `x-api-key` 请求头传输：只用 `https://` / `wss://` 端点。
  Key 只在签发时显示一次；一旦泄露，在 console 轮换或撤销。

## 参考

- [BAP-710 — Unified PropAMM Relayer](https://github.com/bnb-chain/BEPs/pull/710) — 动机、架构与
  规范。
- 上游启发：
  [flashbots/priority-update-registry](https://github.com/flashbots/priority-update-registry)
  （注册表）与
  [lambdaclass/propamm-router-contracts](https://github.com/lambdaclass/propamm-router-contracts/blob/main/src/interfaces/IPropAMM.sol)
  （`IPropAMM` 池子接口）。
