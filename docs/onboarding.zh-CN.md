# PropAMM — Maker 与 Taker 接入指南

> English: [onboarding.md](./onboarding.md)

本指南带做市商（maker）和成交方（taker）完成 **Unified PropAMM Relayer**
的接入：

- **Maker** — 领取 maker API Key，部署一个从 `PrioUpdateRegistry` 读价的
  池子，在 console 登记池子地址，然后流式发送签名报价更新交易。
- **Taker** — 领取 taker API Key（只吃公开报价可不带），在 relayer 上用
  标准 EVM RPC 定价，用普通签名交易原子成交。

```
maker ── pamm_sendQuoteUpdateV1（x-api-key）──▶ relayer
（签名的 registry.updateState tx，                │ 鉴权 maker · 模拟报价 tx
  永不单独广播）                                  │ 抓取写集 → 每调用方 overlay
                                                 ▼
taker ── eth_call / debug_traceCall ──▶ 链上状态 + overlay ──▶ 定价结果
  │        （x-api-key 可选）
  ▼
taker ── eth_sendRawTransaction ──▶ 读槽匹配 → 归属报价
                                                 │ [报价 tx…, taker tx] 干净状态复模拟
                                                 ▼
                                    原子 bundle → 所有接入的 builder
```

报价是一笔签名可执行的 `registry.updateState(...)` 交易，**永不单独广播**。
Relayer 模拟一次、抓取它写的存储槽，用这份 overlay 给 taker 定价。当某笔
taker 交易真正*读到*被报价的槽位时，relayer 把归属的报价 tx 排在 taker tx
前面，作为一个原子 bundle 广播——报价状态与成交同块落地、紧挨在成交之前。
未被成交的报价不花 gas。

---

## 第 0 步 — Console 账户、角色与 API Key

全部准入由运营方的 **PropAMM console** 管理（地址由运营方提供）：

1. **钱包签名登录**（一次签名，首次登录自动建账户）。
2. 在 *Roles & Access* **申请角色**——`maker` 或 `taker`——由运营方管理员
   审批。
3. 在 *API Keys* **签发 API Key**。Key **绑定角色**（`pamm_maker_…` /
   `pamm_taker_…`），明文只在签发时显示**一次**；可随时在 console 轮换或
   撤销。

所有 relayer 请求用一个请求头鉴权：

| 请求头 | 谁 | 用途 |
| --- | --- | --- |
| `x-api-key` | maker（必须）、taker（可选） | relayer 在内存中对照 console 的 Key 表解析。报价上行必须是 **maker** Key；taker Key 解锁勾选了你的受限 maker，并携带你的 builder 路由选择。 |

Relayer 的请求路径从不回源 console——它周期性（约每分钟）刷新关系快照，
console 上的变更（换 Key、撤角色、勾选可见性）在下一次刷新后生效。

---

## Maker 接入

### 1. 部署池子（`IPropAMM` + 注册表集成）

你的池子就是 taker 定价和成交的场所（venue）。两个硬性要求：

- **实现 [`IPropAMM`](../contracts/IPropAMM.sol)**——`isActive`、`getPairs`、
  `quote`、`swap`——让所有钱包、聚合器、solver 用同一个适配器接入。`swap`
  是 push-payment：调用方先把 `amountIn` 的 `tokenIn` 转给池子再调用。
- **从 [`PrioUpdateRegistry`](../contracts/PrioUpdateRegistry.sol) 读价**。
  注册表按 `(target, laneIndex)` 存储；你的池子是 `target`，通过
  `getState(laneIndex, count)` / `getSlot(laneIndex, slotIndex)` 读自己的
  lane。自然的编码是一个交易方向一条 lane：
  `laneFor(tokenIn, tokenOut) = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))`
  ——报价端写、池子端读，**必须同一个编码**。

两个注册表事实决定你的槽位布局（完整模型见
[`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md)）：

- **防重放是注册表的事。** 每次直写带一个 48 位 `seq`，同一 lane 必须严格
  递增；注册表把它打包进 **slot 0 的最高 48 位**——所以 `slots[0]` 只有
  208 个数据位，slot 1 起全宽。旧的或重放的更新永远盖不掉新的，无论谁提交。
- **保鲜是你的事。** 注册表不存任何过期信息。把截止块打包进你自己的布局
  ——例如 slot 0 的 208 个数据位里放 `price` + `maxBlockNumber`——池子在
  `block.number` 超过后 revert。Relayer 在链下也会独立执行报价的
  `maxBlockNumber`，但池子不能只依赖它：链上状态比 relayer 的窗口活得久。

### 2. 在注册表上授权报价 EOA

注册表的 updater 管理必须**由 target 调用**（你的池子），所以给池子加一个
owner 限定的辅助方法：

```solidity
function addMaker(address maker) external onlyOwner { REGISTRY.addUpdater(maker); }
function removeMaker(address maker) external onlyOwner { REGISTRY.removeUpdater(maker); }
```

只有授权的 updater 能写你池子的 lane（否则
`registry.updateState(pool, lane, slots, seq)` revert `NotAuthorized()`）。
**每条报价流用独立 EOA**——见第 4 步的 nonce 说明。

### 3. 在 console 登记池子

在 console 的 *Maker* 工作区：

- **Router 地址**——填你部署的池子。你发的每条报价都归属到这个 venue；
  taker 在 overlay 的 `venues[]` 里能看到并按它过滤。没登记 router 的
  maker，报价仍参与定价，但没有 venue 归属。
- **可见性**——`public`（默认：任何调用方，带不带 Key 都能看到你的报价）
  或 `restricted`（只有你勾选的 taker）。勾选在 relayer 下一次快照刷新后
  生效。

### 4. 流式发报价

一次 JSON-RPC 调用一条更新，HTTP 或 WebSocket，maker Key 放 `x-api-key`
（WS 上可以流水线并发，响应按请求 id 对应）：

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

- `uuid`（16 字节）标识一条报价流——通常一个市场一条。同 uuid 下更高的
  `seq` **完全替换**上一条报价。
- `tx` 是 RLP 编码的签名 `registry.updateState(...)` 交易。**空 `tx`
  （`0x`）永久取消该 uuid。**
- `maxBlockNumber` 是报价可成交的最后一个块（含）；`0` 或超限值被钳到
  relayer 的单报价寿命上限。
- 交易 calldata 里注册表层面的 `seq` 和更新信封里流层面的 `seq` 是两个
  计数器；保持相等是个方便的约定。

对报价 tx 的要求——relayer 会在下一个块上模拟，失败即拒收：

- 必须**执行成功**（revert 原因会在响应的 error 里返回）。
- 用 EOA 的**当前链上 nonce** 签名；因为 tx 不会单独上链，**这条流的每次
  更新都复用这个 nonce**。一旦链上 nonce 前进（成交了，或你从该账户发了
  别的交易），在线报价即视为*已消耗*并移除——下一条更新换新 nonce。
- 保持**纯 setter**：写入只依赖 calldata。抓取的写集会被原样复用直到被
  替换。
- 同一 EOA 的所有报价 tx 共享一个 nonce，所以你的两条流不可能在同一个
  bundle 里同时成交——可能被一起撮合的流请用不同 EOA。
- 成交时 tx 上链，按你签名的 gas 价自付 gas。

完整请求 / 响应 schema 和全部错误串：[`api-guide.zh-CN.md`](./api-guide.zh-CN.md) §2。

### 5. Maker 保护

- **保鲜保护**——relayer 给每条更新盖收到时间戳，每个新块把超过运营方
  配置窗口（`MaxQuoteAge`）的报价清出池子，与 `maxBlockNumber` 无关。持续
  报价即可；过期的流只是不再撮合。
- **写域校验**——运营方可把报价 tx 的写入限制在标准合约内；越界写整条
  拒收。
- **取消语义**——取消在 relayer 内立即生效，但取消*之前*已撮合的 bundle
  仍可能落地，上限是该报价的 `maxBlockNumber`。高频改价请把截止块收紧。

### Maker 清单

| # | 动作 | 在哪 |
| --- | --- | --- |
| 1 | 登录、申请 `maker` 角色、等审批 | console |
| 2 | 签发 maker API Key（`pamm_maker_…`） | console |
| 3 | 部署池子：`IPropAMM` + 注册表 lane 读取 | 你 |
| 4 | `pool.addMaker(EOA)` → 注册表 `addUpdater` | 你 |
| 5 | 给池子备好库存 | 你 |
| 6 | 在 console 填 **Router 地址**、选可见性 | console |
| 7 | 带 `x-api-key` 流式发送 `pamm_sendQuoteUpdateV1` | 你 → relayer |

---

## Taker 接入

### 1. Key（可选，但建议）

匿名调用方能看到所有**公开** maker 的报价。taker API Key 额外带来：

- 勾选了你账户的**受限** maker，以及
- 你的 **builder 路由**选择（见下）。

每个 relayer 请求都带上 `x-api-key`。未知或失效的 Key 不会打断读取——
只是降级为匿名公开视图。

### 2. 定价

把定价指向 relayer 的 RPC 端点。模拟类方法在**链上状态加你的报价
overlay** 上作答（只在规范链头生效；你显式传的 `stateOverride` 参数仍
优先于 overlay）：

- `eth_call`、`eth_estimateGas`、`debug_traceCall`——像任何普通池子一样
  调 `IPropAMM.quote` / `swap`，没有 PropAMM 专用的请求格式。
- `pamm_getPammStateOverrides`——把你的合并 overlay 以 `eth_call` 兼容的
  `stateDiff` 形式拉走（含按 venue 切片），想去别的节点模拟就用它。
- `pamm_subscribe("subscribeNewQuotesV1")`——同一帧按固定间隔 WS 推送。
- `pamm_getPammPriceLevels` / `pamm_subscribe("subscribePriceLevelsV1")`——
  现成的价格梯子：所有池子的交易对在多个 size 上按你的视图报价。

### 3. 成交

签一笔普通交易（例如走 `IPropAMM.swap` 的路由），带着 `x-api-key` 用
`eth_sendRawTransaction` 发到同一个端点。relayer 会：

1. 从同一份快照解析你的视图（可见 maker + builder 路由）；
2. 在你的 overlay 上模拟这笔交易，记录读到的每个存储槽；
3. 把读到的每个被报价槽位归属到你可见的最新报价；
4. 组装 `[报价 tx…, 你的 tx]`，在干净状态上复模拟（报价 tx 可丢弃、你的
   tx 必须成功）；
5. 并行广播给接入的 builder——全部，或你在 console 勾选的子集。

任何一步没有可做的事——没读到报价、超预算、模拟失败、没有 builder 接受
——你的交易**回落到普通 txpool**：走 relayer 永远不比原生节点差。两点
注意：

- 对 pending 交易的同 nonce 替换（加速 / 取消）永不进 bundle——它走
  txpool 以便顶掉原交易；
- 同一报价的竞争成交携带同一笔报价 tx，先落地的 bundle 赢，输家因 nonce
  失败出局。小费自己权衡。

### 4. Builder 路由（可选）

在 console 的 *Taker → Builder Routing* 页勾选允许接收你 bundle 的
builder（按品牌，如 `48club`、`blockrazor`）。不勾 = relayer 接的全部
builder（含以后新增的）。勾选子集即**排除**其余：某台 relayer 上没有配置
任何你勾的 builder 时，你的交易在那里改走公共 txpool。变更在 relayer
下一次快照刷新后生效。

### Taker 清单

| # | 动作 | 在哪 |
| --- | --- | --- |
| 1 | 登录、申请 `taker` 角色、等审批 | console |
| 2 | 签发 taker API Key（`pamm_taker_…`） | console |
| 3 | 请受限 maker 勾选你的账户 id | 对方的 console |
| 4 | （可选）在 *Builder Routing* 勾 builder | console |
| 5 | 带 `x-api-key` 用 `eth_call` 等定价、`eth_sendRawTransaction` 成交 | 你 → relayer |

---

## 部署地址

由运营方提供：

| 名称 | 值 |
| --- | --- |
| Relayer RPC（HTTP / WS） | *（运营方）* |
| Console | *（运营方）* |
| `PrioUpdateRegistry` | *（运营方；每条链一个共享实例）* |
| 你的池子 / router | *（你——部署后填进 console）* |

## 参考

- [`api-guide.zh-CN.md`](./api-guide.zh-CN.md) — 完整 relayer API 参考。
- [`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md) — lane、seq、
  decoder lane、存储布局与错误（英文）。
- [BAP-710](https://github.com/asiawildboar/BEPs/blob/a237e9f756afaaf20aea120e7172ad84e7ae5c70/BAPs/BAP-710.md) —
  架构与设计依据。
