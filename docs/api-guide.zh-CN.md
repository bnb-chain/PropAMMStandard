# PropAMM Relayer — API 指南

> English: [api-guide.md](./api-guide.md)

Unified PropAMM Relayer 是一个 BNB Chain 全节点，额外提供一个 `pamm_*`
JSON-RPC 命名空间（maker 与运维用），并让 taker 常用的标准 EVM 方法带上
PropAMM 语义。本文是两侧的 wire 参考。

- Maker：[§2](#2-maker发送报价) — `pamm_sendQuoteUpdateV1`。
- Taker：[§3](#3-taker定价与成交) — `eth_call` / `eth_estimateGas` /
  `debug_traceCall` / `eth_sendRawTransaction`，以及 overlay 与价格梯子流。
- 运维：[§4](#4-运维自省) — `pamm_status`。

---

## 1. 连接与鉴权

Relayer 同时提供 HTTP 和 WebSocket JSON-RPC。订阅（`pamm_subscribe`）仅
WebSocket；其余两者皆可。

一个请求头承载身份：

| 请求头 | 谁 | 行为 |
| --- | --- | --- |
| `x-api-key` | maker | `pamm_sendQuoteUpdateV1` **必须**。必须是 console 签发的 **maker** Key：不带 Key 拒收（`missing maker API key (x-api-key header)`），未知 Key 报 `invalid API key`，角色不对报 `API key is not a maker key`。 |
| `x-api-key` | taker | 其余接口**可选**。taker Key 把视图扩展到勾选了你的受限 maker，并应用你的 builder 路由。未知 Key 静默降级为匿名公开视图——身份永远不打断读取。 |

Key 由运营方 console 签发、绑定角色，relayer **在内存中**校验（对照周期
刷新的快照做一次 SHA-256 查表——请求路径不回源 console）。轮换与撤销在下
一次快照刷新后生效，对存活的 WebSocket 连接同样生效。

---

## 2. Maker：发送报价

### 2.1 报价模型

- **uuid**（16 字节，hex）标识一条报价流——通常一个市场一条，随机生成。
- **seq** 同 uuid 下严格递增（`> 0`）。`seq <= 最新值` 的更新被丢弃
  （`stale seq`）。改价 = 同 uuid、更高 seq；每次更新**完全替换**上一条。
- **tx** 是 RLP 编码的签名报价交易——一笔写你池子 lane 的
  `PrioUpdateRegistry.updateState(...)`。Blob 交易拒收。
- 按槽位看：当调用方可见的多条在线报价写同一个槽时，**最新收到的**赢——
  taker 按那个值定价，成交时捆的也是那条报价。
- uuid 归创建它的 maker 账户所有：别的 maker 更新或取消会被拒
  （`uuid belongs to another maker`）。

### 2.2 对报价交易的要求

Relayer 在下一个块上模拟后才接受：

- 必须**执行成功**；revert 原因放进响应的 `error`。
- 用发送方的**当前链上 nonce** 签名；这条流的每次更新都复用该 nonce（tx
  只在成交时上链）。链上 nonce 一旦前进，在线报价视为**已消耗**并移除；
  下一条更新换新 nonce。
- 保持**纯 setter**——写入只依赖 calldata。写集被原样复用直到下一次更新。
- 必须按 relayer 的 chain id 签名，gas limit 不得超过节点的模拟上限。
- 运营方可能把报价写入限制在标准合约内（写域）；越界写整条拒收。

### 2.3 `pamm_sendQuoteUpdateV1`

一次调用一条更新。WS 上可自由流水线——处理是并发的，响应按 JSON-RPC id
对应。

请求 `params[0]`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `uuid` | hex bytes | 必须 16 字节 |
| `seq` | uint64 | 同 uuid 严格递增，`> 0` |
| `tx` | hex bytes | RLP 编码签名交易。**空（`0x`）= 取消该 uuid** |
| `maxBlockNumber` | uint64 | 可成交的最后一个块（含）。`0` 或超过 relayer 寿命上限的值被钳到 `当前块 + 上限`；`<=` 当前块拒收 |
| `updateOnChain` | bool，可选 | 接受后额外把报价 tx 发进公共 txpool（持续上链可见），而不是留在 relayer 内部等撮合 |

响应——始终作为 *result* 返回，绝不作为 JSON-RPC error，所以一条坏报价
不会打断调用通道：

```json
{ "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44", "seq": 7, "timestamp": 1789323649752, "error": "" }
```

`timestamp` 是 relayer 的接收时间（unix 毫秒）——槽位冲突裁决和保鲜窗口
用的就是这个时钟。

错误（除注明外都在 `error` 字段）：

| 错误 | 含义 |
| --- | --- |
| `missing maker API key (x-api-key header)` | 未带 Key |
| `invalid API key` | 当前快照不认识这把 Key（已撤销 / 已轮换 / 打错） |
| `API key is not a maker key` | Key 有效但角色不对（如 taker Key） |
| `permission directory unavailable, retry later` | relayer 没有有效 console 快照（fail closed） |
| `uuid must be exactly 16 bytes` / `seq must be > 0` | 信封格式错误 |
| `tx too short (N bytes); use empty tx (0x) to cancel` | tx 字段格式错误 |
| `blob-tx is not supported as a quote` | blob 交易 |
| `quote tx signed for a different chain id` | 链错了 |
| `stale seq` | seq 不高于该 uuid 已接受的最新值 |
| `uuid has been canceled` | 已取消的 uuid 永久退役——换新 uuid |
| `uuid belongs to another maker` | 动了别人的报价流 |
| `the maxBlockNumber must be greater than currentBlockNum` | 到达时已过期 |
| `quote expired on arrival` | 截止块解析后低于下一个块 |
| `quote gas limit above simulation cap` | gas limit 超模拟上限 |
| `quote writes storage outside the allowed scope` | 写域越界 |
| `propamm engine not ready` | 节点预热 / 追块中；稍后重试 |
| `relayer busy, retry` | 模拟并发达到上限 |
| `on-chain quote updates not available on this node` | 请求了 `updateOnChain` 但该节点不支持 |
| *（revert 原因 / nonce 错误）* | 报价 tx 下块模拟失败 |

### 2.4 取消

同 uuid、更高 seq、空 tx：

```json
{ "uuid": "0x1bd6...1c44", "seq": 8, "tx": "0x", "maxBlockNumber": 0 }
```

报价立即离池，uuid **永久退役**（此后一律 `uuid has been canceled`）——
换新 uuid 继续。取消*之前*已撮合的 bundle 仍可能落地，上限是该报价的
`maxBlockNumber`。

### 2.5 生命周期

以下任一先发生，报价即离池：

- **被替换**——同 uuid 更高 seq；
- **被取消**——空 tx 更新（uuid 退役）；
- **过期**——链越过其 `maxBlockNumber`；
- **超龄**——超过运营方的保鲜窗口（`MaxQuoteAge`）；
- **被消耗**——发送方链上 nonce 越过报价 tx；
- **被撤权**——maker 失去 console 审批（relayer 快照刷新后的下一个块生效）。

---

## 3. Taker：定价与成交

### 3.1 Overlay

Relayer 为每个调用方维护一个**视图**：该调用方可见的 maker（公开 maker
人人可见；taker Key 追加勾选了它的受限 maker）全部在线报价按槽位取最新的
合并写集。模拟类方法自动应用视图：

| 方法 | 行为 |
| --- | --- |
| `eth_call` | 在规范链头的链上状态 **加** 调用方 overlay 上执行；显式传入的 `stateOverride` 优先于 overlay；历史块用原状态 |
| `eth_estimateGas` | 同上 |
| `debug_traceCall` | 同上（仅完整链头后状态） |

没有 PropAMM 专用请求格式：像调任何合约一样调池子的
`IPropAMM.quote` / `swap`。

### 3.2 `eth_sendRawTransaction`

提交一笔普通签名交易。relayer 依次：

1. 从同一份快照解析你的视图（可见 maker + builder 路由）；
2. 在你的 overlay 上模拟，记录读到的每个存储槽；
3. 把读到的每个被报价槽位归属到可见范围内最新的那条报价；
4. 组装 `[报价 tx…（旧在前）, 你的 tx]`，干净状态复模拟——报价 tx 可
   丢弃（丢弃即物理剔除），你的 tx 必须成功，全程无 revertible；
5. bundle 的截止块钳到所匹配报价中最早的 `maxBlockNumber`，并行广播给
   选中的 builder。

回退语义：relayer 未就绪、没读到报价、模拟失败或没有 builder 接受时，
交易走**普通 txpool**——永远不比原生节点差。对 pending 交易的同 nonce
替换始终直接进 txpool，以便顶掉原交易。

### 3.3 `pamm_getPammStateOverrides`

一次性拉取调用方 overlay，`eth_call` 兼容：

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

- `blockNumber`——正在构建的目标块（链头 + 1）。
- `overrides`——合并视图（`账户 → 槽 → 值`），直接塞进任意节点
  `eth_call` 的 `stateDiff` 参数。
- `venues`——同一数据按报价 maker 登记的 router 切片，用于按 venue 过滤
  与归属。

### 3.4 `pamm_subscribe("subscribeNewQuotesV1")`——仅 WS

订阅期间按固定间隔（默认 100ms）推送同一帧。可选过滤：
`{ "routers": ["0x…"] }` 只保留这些 venue；空 / 缺省 = 你视图内全部。

```json
{ "jsonrpc": "2.0", "id": 1, "method": "pamm_subscribe",
  "params": ["subscribeNewQuotesV1", { "routers": [] }] }
```

### 3.5 价格梯子

现成的价格档位——所有 PropAMM 池的交易对在多个 size 上按**你的**视图
定价，有需求时按固定 tick 重新模拟：

- `pamm_getPammPriceLevels`——一次性拉取（闲置后的第一次调用会等一个
  tick）。
- `pamm_subscribe("subscribePriceLevelsV1", { "pamms": [] })`——每 tick
  WS 推送；过滤器只保留列出的池子地址。

```json
{
  "blockNumber": 54321099,
  "millisTimestamp": 1789323649752,
  "pamms": [{
    "pamm": "0xPool",
    "pairs": [{
      "tokenIn": "0xA", "tokenOut": "0xB",
      "levels": [
        { "amountIn": "0xde0b6b3a7640000", "amountOut": "0x…", "source": "simulated" },
        { "amountIn": "0x1bc16d674ec80000", "amountOut": "0x…", "source": "interpolated" }
      ]
    }]
  }]
}
```

### 3.6 Builder 路由

获批的 taker 在 console 里选择成交自己订单的 bundle 允许发给哪些 builder
（按品牌，如 `48club` / `blockrazor`，或具体 endpoint 名）。不选 = 全部
builder。选择跟着 taker 的 `x-api-key` 走；如果某台 relayer 上没有配置
任何被选中的 builder，交易在那台上改走 txpool——排除只会被遵守，不会被
放宽。

---

## 4. 运维自省

### `pamm_status`

```json
{
  "ready": true,
  "targetBlock": 121693514,
  "quotes": 1, "liveQuotes": 1, "overlaySlots": 1,
  "builders": ["48club", "blockrazor"],
  "pendingBundles": 0,
  "maxQuoteAgeMs": 120000,
  "onChainUpdates": true,
  "directory": {
    "console": "https://console.example", "loaded": true,
    "snapshotAt": 1789323649752, "generatedAt": "2026-09-13T18:20:49.775Z",
    "makers": 2, "takers": 2, "keys": 4,
    "refreshIntervalMs": 60000, "maxAgeMs": 600000
  },
  "peering": { "url": "wss://peer.example", "connected": true, "shared": 41, "received": 0 }
}
```

- `ready`——节点已在新鲜链头上完成预热；为 `false` 时报价上行返回
  `propamm engine not ready`，taker 走原生路径。
- `directory`——relayer 鉴权所依赖的 console 快照；`loaded` 为 false 或
  `snapshotAt` 过旧说明正在 fail closed。
- `builders`——按名字列出的已配置 builder。
- 状态里永远不出现任何 Key 材料。

---

## 5. 值得了解的语义

- **可见性是视图，不是事后过滤。** 定价、venue 归属、撮合、builder 路由
  都从每请求一份的快照解析；按槽位取*调用方可见*的最新报价，所以隐藏
  maker 的更新报价永远不会遮住可见 maker 的值，taker 捆的就是给它定价的
  那条报价。
- **保鲜按块对齐。** 每个新块清一次过期 / 超龄 / 已消耗的报价；请求路径
  不做逐次age检查——bundle 反正落不进当前块。
- **原子性。** 报价 tx 旧在前，最新报价是每个争用槽的最后写者；taker tx
  必须成功；PropAMM bundle 里没有任何 revertible 成分。
