# PropAMM Relayer API 指南

> English: [api-guide.md](./api-guide.md)

Unified PropAMM Relayer 是一个 BNB Chain 全节点，在标准 RPC 之上多了一个
`pamm_*` JSON-RPC 命名空间（给 maker 和运维用），同时让 taker 常用的几个
标准 EVM 方法带上 PropAMM 语义。本文是两侧的接口参考；规范性定义见
[BAP-710](https://github.com/bnb-chain/BEPs/pull/710) §4.4–§4.8。

- Maker：[§2](#2-maker发送报价)，`pamm_sendQuoteUpdateV1`。
- Taker：[§3](#3-taker定价与成交)，`eth_call` / `debug_traceCall` /
  `eth_sendRawTransaction`，以及 overlay 与价格档位的
  订阅流。
- 运维：[§4](#4-运行状态)，`pamm_status`。

---

## 1. 连接与鉴权

Relayer 同时提供 HTTP 和 WebSocket 两种 JSON-RPC 入口。订阅类方法
（`pamm_subscribe`）只能走 WebSocket，其余方法两种都可以。

部署方可以限制本文以外的 JSON-RPC 方法。通用的链上读取（`eth_chainId`、
`eth_blockNumber`、`eth_getTransactionCount`、回执等）请继续用你现有的
BSC RPC 端点。

身份只靠一个请求头：

| 请求头 | 谁 | 行为 |
| --- | --- | --- |
| `x-api-key` | maker | 调 `pamm_sendQuoteUpdateV1` 时**必须**带，且必须是 console 签发的 **maker** Key。不带 Key 报 `missing maker API key (x-api-key header)`，Key 不认识报 `invalid API key`，角色不对报 `API key is not a maker key`。 |
| `x-api-key` | taker | 其余接口**可选**。带上 taker Key，视图会多出勾选了你的受限 maker，并按你的 builder 路由设置转发。Key 不认识时静默降级为匿名公开视图，读取永远不会因为身份问题被打断。 |

WebSocket 上，请求头只在升级握手时读取一次，对该连接上的每个调用生效。

Key 由 console 签发并绑定角色。Relayer 在内存里校验：对照周期刷新（默认
每分钟一次）的快照做一次 SHA-256 查表，请求路径上不会去访问 console。
轮换和撤销在下一次快照刷新后生效，已经建立的 WebSocket 连接也一样。如果
快照从未加载过，或者比 `max(10 × refresh interval, 5 minutes)` 更旧，
relayer 会 **fail closed**：拒收报价更新，也不再用任何报价给任何调用方
定价或撮合。

身份就是 API Key，而不是交易发送方：taker 的视图和 builder 路由取决于
请求上带的 Key，与交易由谁签名无关。

---

## 2. Maker：发送报价

### 2.1 报价模型

- **uuid**（16 字节 hex）标识一条报价流，通常一个市场一条，随机生成即可。
- **seq** 在同一个 uuid 下严格递增（`> 0`）。`seq` 不高于最新值的更新会
  被丢弃（`stale seq`）。改价就是用同一个 uuid 发更高的 seq，每次更新
  **完全替换**上一条。
- **tx** 是签名报价交易（EIP-2718 编码；不接受 blob 交易）。它应当只写
  你池子在 `PrioUpdateRegistry` 里的 lane，形式为以下两种之一：
  - 由你池子授权的 updater 账户直接调用 `updateState(...)` /
    `updateStateBatch(...)`；或
  - 调用 `updateStateWithDecoder(...)`，携带由你池子的签名者签名的
    payload（BAP-710 §4.2.3），可以从任意账户发送。

  Relayer 不检查 calldata；它只看这笔交易在下一个块上的模拟结果，以及
  （如果运营方配置了）它的写入范围。
- 从槽位的角度看：调用方可见的多条在线报价写了同一个槽时，以**最新收到
  的**那条为准。taker 按那个值定价，成交时进 bundle 的也是那条报价。
- uuid 归创建它的 maker 账户所有，别的 maker 去更新或取消会被拒
  （`uuid belongs to another maker`）。

### 2.2 对报价交易的要求

Relayer 会先在下一个块上模拟，通过了才接受：

- 必须**执行成功**，revert 原因会放进响应的 `error` 字段。
- 用发送方**当前的链上 nonce** 签名。tx 只在成交时才上链，所以这条流的
  每次更新都复用这个 nonce。链上 nonce 一旦前进，在线报价视为**已消耗**
  并被移除，下一条更新要换新 nonce。
- 保持**纯 setter**：写入只依赖 calldata。抓到的写集会被原样复用，直到
  下一次更新。
- 发送账户必须持有足够的 BNB，才能通过下一个块模拟中的余额检查（gas 只在
  成交把这笔 tx 带上链时才真正花掉）。
- 必须按 relayer 所在链的 chain id 签名，gas limit 不能超过节点的模拟
  上限。
- 运营方可能把报价的写入范围限制在标准合约内，越界写的整条更新会被
  拒收。

### 2.3 `pamm_sendQuoteUpdateV1`

一次调用一条更新。WS 上可以随意流水线发送，处理是并发的，响应按
JSON-RPC id 对应。

请求 `params[0]`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `uuid` | hex bytes | 必须 16 字节 |
| `seq` | uint64 | 同 uuid 下严格递增，`> 0` |
| `tx` | hex bytes | EIP-2718 编码的签名交易。**空（`0x`）表示取消该 uuid** |
| `maxBlockNumber` | uint64 | 可成交的最后一个块（含）。填 `0` 或超过 relayer 寿命上限的值，会被钳到「链头 + 上限」（参考默认值：100 个块）；不高于当前链头的值拒收 |

你的 maker 身份和池子都不是请求字段：两者都来自 API Key 和 console
（§1）。

响应始终放在 *result* 里返回，绝不作为 JSON-RPC error，所以一条坏报价
不会打断调用通道。被接受的更新没有 `error` 字段：

```json
{ "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44", "seq": 7, "timestamp": 1789323649752 }
```

被拒收的更新带上原因：

```json
{ "uuid": "0x1bd6cf1ad7a55f1d7e0c8a17b32a1c44", "seq": 7, "timestamp": 1789323649752, "error": "stale seq" }
```

`timestamp` 是 relayer 收到这条更新的时间（unix 毫秒）。槽位冲突裁决和
保鲜窗口用的都是这个时钟。

错误（都通过 `error` 字段返回；以参考实现为准）：

| 错误 | 含义 |
| --- | --- |
| `missing maker API key (x-api-key header)` | 未带 Key |
| `invalid API key` | 当前快照不认识这把 Key（已撤销 / 已轮换 / 填错） |
| `API key is not a maker key` | Key 有效但角色不对（如 taker Key） |
| `permission directory unavailable, retry later` | relayer 没有有效的 console 快照（fail closed） |
| `uuid must be exactly 16 bytes` / `seq must be > 0` | 信封格式错误 |
| `tx too short (N bytes); use empty tx (0x) to cancel` | tx 字段格式错误 |
| *（交易解码错误）* | `tx` 不是合法的 EIP-2718 交易 |
| `blob-tx is not supported as a quote` | blob 交易 |
| `quote tx signed for a different chain id` | 签名的 chain id 与 relayer 所在链不符 |
| `stale seq` | seq 不高于该 uuid 已接受的最新值（重复取消也返回此错误） |
| `uuid has been canceled` | 该 uuid 在取消请求的 `maxBlockNumber` 之前都处于已取消状态（§2.4），请换新 uuid 继续 |
| `uuid belongs to another maker` | 更新或取消了别的账户的报价流 |
| `the maxBlockNumber must be greater than currentBlockNum` | 到达时 `maxBlockNumber` 已不高于当前块 |
| `quote expired on arrival` | 校验或模拟报价期间来了新块，截止块已赶不上下一个块 |
| `quote gas limit above simulation cap` | gas limit 超过模拟上限 |
| `quote writes storage outside the allowed scope` | 写入范围越界 |
| `propamm engine not ready` | 未与链头同步（§4），稍后重试 |
| `relayer busy, retry` | 模拟并发达到上限 |
| *（revert 原因 / nonce 或余额错误）* | 报价 tx 在下一个块上模拟失败，包括 `NotAuthorized()`、`StaleSeq()` 等注册表拒绝 |

### 2.4 取消

用同一个 uuid、更高的 seq、空 tx：

```json
{ "uuid": "0x1bd6...1c44", "seq": 8, "tx": "0x", "maxBlockNumber": 0 }
```

报价立即失效、不再可成交。取消会在该 uuid 上留下一个**墓碑**
（tombstone），直到取消请求自己的 `maxBlockNumber`（填 `0` 时钳到「链头 +
上限」，默认约 100 个块）：在此之前，该 uuid 上的任何更新，无论 `seq`
多大，一律报 `uuid has been canceled`，所以延迟到达的取消前更新永远无法
复活这条流。想继续报价就换新 uuid。取消*之前*已经撮合出去的 bundle 仍
可能落地，最晚到被取消报价的 `maxBlockNumber`。

### 2.5 生命周期

以下任一情况先发生，报价即失效：

- **被替换**：同 uuid 更高 seq；
- **被取消**：空 tx 更新，uuid 留下墓碑（§2.4）；
- **过期**：链越过它的 `maxBlockNumber`；
- **超龄**：超过运营方的报价时效上限（`pamm_status` 中的
  `maxQuoteAgeMs`；`0` 表示关闭，即参考默认值）；
- **被消耗**：发送方链上 nonce 越过报价 tx；
- **被撤权**：maker 失去 console 审批，relayer 快照刷新后的下一个块生效。

---

## 3. Taker：定价与成交

### 3.1 Overlay

Relayer 为每个调用方维护一个**视图**：先确定这个调用方能看到哪些 maker
（公开 maker 人人可见，taker Key 再追加勾选了它的受限 maker），再把这些
maker 的全部在线报价按槽位取最新值，合并成一份写集，这就是 overlay。
模拟类方法会自动套上它：

| 方法 | 行为 |
| --- | --- |
| `eth_call` | 在规范链头的链上状态**加上**调用方 overlay 执行。显式传入的 `stateOverride` 优先于 overlay |
| `debug_traceCall` | 同上（只支持完整的链头后状态） |

```text
simulated state = chain state at head + overlay(quotes in the caller's view) + caller's own state overrides
```

- overlay 只作用于规范链头。历史块、按 hash 请求的非规范块，以及块内
  中间位置的 trace（`txIndex`）都在原状态上执行。
- 没碰到任何 PropAMM 池子的调用，返回结果与普通节点完全一致。
- relayer 未与链头同步时（§4）不套用 overlay。

没有 PropAMM 专用的请求格式，像调任何合约一样调池子的 `IPropAMM.quote`
即可，或者直接模拟你整笔成交交易。

### 3.2 `eth_sendRawTransaction`

提交一笔普通签名交易。池子是 push-payment（`IPropAMM.swap` 消费的是已经转
进池子的 `tokenIn`），所以成交是一笔在同一交易里「推入 + swap」的合约调用：
聚合器 / 路由，或参考实现 `ExamplePammTaker`。relayer 依次：

1. 检查资格：txpool 已知的交易、对 pending 交易的替换（同发送方同
   nonce，如加速或取消）、blob 交易，或 gas limit 超过模拟上限的交易，
   直接进 txpool；
2. 从同一份快照解析你的视图（可见 maker 和 builder 路由）；
3. 在你的 overlay 上模拟，记录读到的每个存储槽（包括之后 revert 的调用
   帧里的读取）；
4. 读到的每个被报价槽位，都对应到你可见范围内最新的那条报价：
   `quote write-set ∩ taker read-set ≠ ∅ → bundle together`；
5. 组装 `[报价 tx…（先收到的在前）, 你的 tx]`，在干净状态上重新模拟。
   报价 tx 允许失败，失败的会被直接剔除；你的 tx 必须成功，bundle 里
   没有任何允许 revert 的成分；
6. bundle 的 `maxBlockNumber` 取所匹配报价中最早的那个，然后并行广播给
   选中的 builder。builder 会保留这个 bundle 直到该块；relayer 不会重新
   广播或替换它。

**回退。** relayer 未同步、你看不到任何报价、模拟失败、没有匹配、匹配到
的报价已过期、所有报价在重新模拟中被剔除，或者没有 builder 接受
bundle，这些情况下交易都走**普通 txpool**，与普通节点完全一样。走这条
路径的 PropAMM 成交没有报价可用，会在链上 revert（发送方付 gas，资金
不动）。

**可见性。** 进了 bundle 的交易属于私有订单流：不在公共 txpool 里，在
builder 让它落地之前，`eth_getTransactionByHash` 返回 null。

**报价变动。** 和你一起进 bundle 的是你的交易*到达*时的在线报价，而不是
你模拟时的那份快照。设置 `minAmountOut` 时要为此留出余量，它就是你的
价格保护。

**钱包。** 只把签名交易发给 relayer，或者先发给 relayer；非 PropAMM
交易会经 relayer 自己的 txpool 转发，所以不需要再单独向公共网络提交。
**不建议**同时把同一笔交易发给公共 RPC：如果公共那份先进了 relayer 的
txpool，这笔交易就成了「already known」，错过 bundle 路径。

**Solver 与聚合器**必须只把 PropAMM 路由返回给签名交易能到达 relayer 的
钱包。只发到公共 BSC RPC 的 PropAMM 依赖交易会因为缺少报价更新而
revert。

### 3.3 `pamm_getPammStateOverrides`

一次性拉取调用方的 overlay，格式与 `eth_call` 兼容：

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

- `blockNumber`：正在构建的目标块（链头 + 1）。
- `overrides`：合并视图（`账户 → 槽 → 值`），可以直接作为任意节点
  `eth_call` 的 `stateDiff` 参数。
- `venues`：同一份数据按报价 maker 登记的 router 切片，用于按 venue 过滤
  和归属。

### 3.4 State-override 订阅流：`pamm_subscribe("subscribeNewQuotesV1")`

自建模拟设施的 taker 可以把 state override 当作实时流来消费，不必轮询。
内容和 `pamm_getPammStateOverrides` 是同一帧，通过 WebSocket 按固定间隔
推送（默认 100ms）。

用 `pamm` 命名空间下的标准 Ethereum pub/sub 订阅：

```json
{ "jsonrpc": "2.0", "id": 1, "method": "pamm_subscribe",
  "params": ["subscribeNewQuotesV1", { "routers": [] }] }
```

返回订阅 id，之后每一帧以 `pamm_subscription` 通知送达：

```json
{
  "jsonrpc": "2.0",
  "method": "pamm_subscription",
  "params": {
    "subscription": "0xcd0c3e8af590364c09d0fa6a1210faf5",
    "result": {
      "blockNumber": 54321099,
      "millisTimestamp": 1789323649752,
      "overrides": {
        "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
          "0x09c6d2…55f1": "0x00000000000000000000000000000000000000000000000ddf4ae7657b0000"
        }
      },
      "venues": [{
        "router": "0x2a291e911864137801eb582b14fbda874b46ec94",
        "overrides": {
          "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
            "0x09c6d2…55f1": "0x00000000000000000000000000000000000000000000000ddf4ae7657b0000"
          }
        }
      }]
    }
  }
}
```

- **每一帧都是完整快照**，包含你视图内所有在线报价。保留最新一帧即可，
  旧的视为被取代，消费端不需要做增量合并。
- `overrides` 是合并视图（`账户 → 槽 → 值`），冲突已经裁决过：多条报价
  写同一个槽时，你看到的值就是成交时会执行的值。`venues` 是同一份数据按
  maker 的 router 切片，用于按 venue 归属和过滤。
- `routers` 参数把流收窄到你关心的 venue，为空或不传表示你可见的全部。
  合并后的 `overrides` 遵守同一过滤，两部分永远一致。
- `overrides` 为空的帧表示此刻你的视图内没有在线报价，例如 relayer
  刚重启。
- 退订用 `pamm_unsubscribe([subscriptionId])`，或者直接断开连接。

**拿到帧之后怎么定价。** 把 `overrides` 直接作为任意节点 `eth_call` 的
state-override 参数（`stateDiff`）传入：

```json
{
  "method": "eth_call",
  "params": [
    { "to": "<pool>", "data": "<quote(tokenIn, tokenOut, amountIn) calldata>" },
    "latest",
    {
      "0x7b484a13a440d0b7312a42c7f3588bb37d4c1b65": {
        "stateDiff": { "0x09c6d2…55f1": "0x…7b0000" }
      }
    }
  ]
}
```

`blockNumber` 是这些报价有效的块，也就是正在构建的那一块。如果池子在
链上按 `block.number` 校验报价新鲜度，就按这个块号模拟（支持的节点可以用
`eth_call` 的第 4 个参数传 block override），临近截止块的报价才能算得准。

### 3.5 价格档位（price levels）

Taker 也可以直接消费**价格档位流**。State-override 流给的是原始存储，
价格还得你自己算；价格档位则是 **relayer 已经替你算好、按 pAMM 分组**的
结果：你视图内每个池子、每个交易对的现成订单簿，随实时报价 overlay 持续
刷新。

档位分两种：

- **`simulated`（模拟档）**：对池子 `quote(tokenIn, tokenOut, amountIn)`
  做 EVM 模拟得到。报价 size 按几何级数分布，一条梯子覆盖从小到大的宽幅
  交易规模。
- **`interpolated`（插值档）**：在相邻两个模拟档之间线性插值生成的中间
  档，用微小的近似误差换来更顺手的 size 集合。

每条消息都是**完整快照**，保留最新一条即可，旧的视为被取代。同一交易对
内档位按 `amountIn` 升序；某个方向的梯子在池子第一个报不出价的 size 处
截止。交易对来自池子的 `getPairs()`，maker 没登记的交易对没有梯子。

梯子每个 tick（参考默认 200 ms；`pamm_status` 中的
`priceLevels.intervalMs`）在完整
overlay 上计算一次，并且只在有人消费时才计算：存在活跃订阅，或者最近
30 秒内有过 `pamm_getPammPriceLevels` 调用。只有当你的视图包含某个池子上
登记的**每一个** maker 时，这个池子才会出现在你的梯子里；没有登记任何
maker 的池子对所有人可见。

两种获取方式，返回同一种结构：

- `pamm_getPammPriceLevels`：一次性 JSON-RPC 拉取。沉寂一段时间后的第一次
  调用可能要等大约一秒，因为梯子需要现场计算；遇到 `relayer busy, retry`
  重试即可。
- `pamm_subscribe("subscribePriceLevelsV1", { "pamms": [] })`：WebSocket
  推送每一份新快照。`pamms` 非空时只保留列出的池子地址。

```json
{
  "blockNumber": 54321099,
  "millisTimestamp": 1789323649752,
  "pamms": [{
    "pamm": "0x5979458912f80b96d30d4220af8e2e4925a33320",
    "pairs": [{
      "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
      "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      "levels": [
        { "amountIn": "0x989680",  "amountOut": "0x174b67393", "source": "simulated" },
        { "amountIn": "0xaa810a",  "amountOut": "0x1a0781260", "source": "interpolated" },
        { "amountIn": "0xbc6b0a4", "amountOut": "0x1cc38b120", "source": "simulated" }
      ]
    }]
  }]
}
```

### 3.6 Builder 路由

获批的 taker 可以在 console 里选择：成交自己订单的 bundle 允许发给哪些
builder（按品牌，如 `48club` / `blockrazor`，或具体的 endpoint 名）。不选
表示全部 builder。这个选择跟着 taker 的 `x-api-key` 走。如果某台 relayer
没有接入任何被选中的 builder，交易在那台上会改走 txpool。排除只会被
遵守，不会被放宽。

---

## 4. 运行状态

### `pamm_status`

```json
{
  "ready": true,
  "targetBlock": 121693514,
  "quotes": 1, "liveQuotes": 1, "overlaySlots": 1,
  "builders": ["48club", "blockrazor"],
  "pendingBundles": 0,
  "maxQuoteAgeMs": 120000,
  "quoteStreamSubscribers": 0,
  "priceLevels": {
    "intervalMs": 200, "subscribers": 1,
    "pamms": 1, "levels": 45,
    "computedAt": 1789323649752, "lastComputeMs": 12
  },
  "directory": {
    "console": "https://console.example", "loaded": true,
    "snapshotAt": 1789323649752, "generatedAt": "2026-09-13T18:20:49.775Z",
    "makers": 2, "takers": 2, "keys": 4,
    "refreshIntervalMs": 60000, "maxAgeMs": 600000
  },
  "peering": { "url": "wss://peer.example", "connected": true, "shared": 41, "received": 0 }
}
```

- `ready`：relayer 已与链同步（参考规则：连续五个链头，每个都在墙上时间
  3 秒以内到达），一旦有链头迟到就退回 `false`。为 `false` 时报价上行会
  返回 `propamm engine not ready`，不套用 overlay，taker 交易走 txpool
  路径。
- `maxQuoteAgeMs`：报价时效上限（§2.5）；`0` 表示关闭。
- `directory`：relayer 鉴权所依赖的 console 快照。`loaded` 为 false 或
  `snapshotAt` 比 `maxAgeMs` 更旧，说明 relayer 正处于 fail closed 状态
  （§1）。relayer 不接 console 运行时没有该字段。
- `peering`：与运营方其他 relayer 之间的报价共享；未配置时没有该字段。
- `builders`：已配置的 builder 名单。
- 状态输出里永远不会出现任何 Key 材料。

---

## 5. 值得了解的语义

- **可见性是视图，不是事后过滤。** 定价、venue 归属、撮合、builder 路由
  都从每个请求各自的一份快照解析；每个槽位取的是*调用方可见*的最新报价，
  所以隐藏 maker 的新报价永远不会遮住可见 maker 的值，taker 成交时进
  bundle 的就是给它定价的那条报价。
- **保鲜按块对齐。** 每个新块清理一次过期、超龄、已消耗的报价；请求路径
  上不做逐请求的时效检查，因为 bundle 反正落不进当前块。
- **原子性。** 报价 tx 旧的在前，最新报价是每个争用槽位的最后写者；
  taker tx 必须成功；PropAMM bundle 里没有任何允许 revert 的成分。
- **回退安全。** 凡是没有以 bundle 结束的路径，都以普通 txpool 结束，所以
  把全部交易都经 relayer 发送，永远不比用普通节点差。
- **即时上链。** 没被撮合的报价 tx 永远不会到达 builder 或公共 txpool；
  报价只有在促成成交时才花 gas。
