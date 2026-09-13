# PropAMM 标准

> English: [README.md](./README.md)

BNB Chain 上 **PropAMM** 的链上标准与接入指南——一个 builder 中立的
专业做市执行层，规范见
[BAP-710](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md)。

> **Maker 发报价，Taker 发交易，Relayer 组 bundle。**

PropAMM 是由做市商运营、定价来自链下报价而非链上曲线的池子。Maker 把签名的
报价更新交易流式发给 **Unified PropAMM Relayer**；报价一直留在链下，直到某笔
taker 交易真正依赖它，才和这笔交易一起原子落地——在成交前一刻写入链上。
Taker 无需学习任何 bundle API：定价和成交都走标准 EVM JSON-RPC。

## 三层结构

| 层 | 是什么 | 位置 |
| --- | --- | --- |
| **PropAMM Oracle** | `PrioUpdateRegistry`——链上报价状态注册表，按 target 分 *lane* 存储，直写路径带防重放 seq，可选 decoder 托管 lane | [`contracts/PrioUpdateRegistry.sol`](./contracts/PrioUpdateRegistry.sol) · [模型文档](./contracts/PrioUpdateRegistry.md)（英文） |
| **PropAMM Pool 接口** | `IPropAMM`——面向 taker 的统一池子接口（`isActive`、`getPairs`、`quote`、`swap`），钱包、聚合器、solver 只需一个适配器 | [`contracts/IPropAMM.sol`](./contracts/IPropAMM.sol) |
| **Unified PropAMM Relayer** | BNB Chain 全节点分叉：鉴权 maker、把在线报价叠加到链上状态供 taker 模拟、把 taker 交易与其读到的报价撮合成 `[报价 tx…, taker tx]` bundle、广播到所有接入的 builder | 由运营方部署；API 见 [`docs/api-guide.zh-CN.md`](./docs/api-guide.zh-CN.md) |

## 从这里开始

- **接入指南（Maker 与 Taker）** — [`docs/onboarding.zh-CN.md`](./docs/onboarding.zh-CN.md)
- **Relayer API 参考** — [`docs/api-guide.zh-CN.md`](./docs/api-guide.zh-CN.md)
- **注册表模型** — [`contracts/PrioUpdateRegistry.md`](./contracts/PrioUpdateRegistry.md)

## 关键性质

- **Taker 走标准 RPC**——换的是 RPC 端点，不是交易模型。`eth_call`、
  `eth_estimateGas`、`debug_traceCall` 在链上状态 *加* 调用方报价 overlay
  上作答；`eth_sendRawTransaction` 提交的就是一笔普通签名交易。
- **即时执行**——报价更新永不单独广播：只模拟一次，写集进 overlay，
  只有在成交 bundle 里才上链。没被成交的报价不花 gas。
- **Builder 中立**——bundle 并行发往所有接入的 builder；builder 只需通用的
  原子 bundle 能力，无 PropAMM 专用代码。Taker 可按账户收窄扇出。
- **回退安全**——taker 的任何失败路径（无报价、无碰撞、模拟失败、无
  builder）都回落到普通 txpool，永远不比原生节点差。
- **鉴权在 relayer 完成**——maker / taker API Key 由运营方 console 签发、
  绑定角色，relayer 每个请求在内存中校验；maker 自主选择报价流公开或仅对
  勾选的 taker 可见。

## 参考

- [BAP-710 — Unified PropAMM Relayer](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md) — 动机、架构与规范。
- 上游启发：[flashbots/priority-update-registry](https://github.com/flashbots/priority-update-registry)。
