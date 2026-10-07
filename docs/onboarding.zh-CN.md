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
（签名的 registry.updateState tx,                 │ 鉴权 maker · 模拟报价 tx
  永不单独广播）                                   │ 抓取写集 → 每调用方 overlay
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
前面，作为一个原子 bundle 广播。报价状态与成交同块落地，紧挨在成交之前。
未被成交的报价不花 gas；relayer 无法组 bundle 的任何 taker 交易都继续走
普通 txpool。

规范性定义见 [BAP-710](https://github.com/bnb-chain/BEPs/pull/710)；本指南
是实操层面的分步说明。

---

## 第 0 步 — Console 账户、角色与 API Key

全部准入由 **PropAMM console** 管理：<https://console.bnbchain.org/>

1. **钱包签名登录**（一次签名，首次登录自动建账户）。
2. 在 *Roles & Access* **申请角色**（`maker` 或 `taker`），由运营方管理员
   审批。
3. 在 *API Keys* **签发 API Key**。Key **绑定角色**（`pamm_maker_…` /
   `pamm_taker_…`），明文只在签发时显示**一次**；可随时在 console 轮换或
   撤销。

所有 relayer 请求用一个请求头鉴权（WebSocket 上只在升级握手时发送
一次）：

| 请求头 | 谁 | 用途 |
| --- | --- | --- |
| `x-api-key` | maker（必须）、taker（可选） | relayer 在内存中对照 console 的 Key 表解析。报价上行必须是 **maker** Key；taker Key 解锁勾选了你的受限 maker，并携带你的 builder 路由选择。 |

Relayer 的请求路径从不回源 console。它周期性（约每分钟）刷新关系快照，
console 上的变更（换 Key、撤角色、勾选可见性）在下一次刷新后生效。

---

## Maker 接入

### 1. 部署池子（`IPropAMM` + 注册表集成）

你的池子就是 taker 定价和成交的场所（venue）。两个硬性要求：

- **实现 [`IPropAMM`](../contracts/IPropAMM.sol)**（`isActive`、`getPairs`、
  `quote`、`swap`），让所有钱包、聚合器、solver 用同一个适配器接入。`swap`
  是 **push-payment**：调用方在同一笔交易里先把 `amountIn` 的 `tokenIn`
  转给池子、再调 `swap`；池子只消费已推入的余额，从不对调用方
  `transferFrom`。因此池子必须能区分「推进来的付款」和「自己的库存」（参考
  实现用 `reserves` 记账，高出记账的余额即视为付款，见
  [`ExamplePammRouter.sol`](../contracts/ExamplePammRouter.sol)）。`swap`
  要防重入，否则带转账钩子的 `tokenOut` 可以把同一笔推入花两次。`quote`
  必须返回在相同输入和状态下 `swap` 会交付的数量，并且在交易对未激活或
  报价已过期时必须 revert。
- **从 [`PrioUpdateRegistry`](../contracts/PrioUpdateRegistry.sol) 读价**。
  注册表按 `(target, laneIndex)` 存储；你的池子是 `target`，通过
  `getState(laneIndex, count)` / `getSlot(laneIndex, slotIndex)` 读自己的
  lane。自然的编码是一个交易方向一条 lane：
  `laneFor(tokenIn, tokenOut) = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))`
  报价端写、池子端读，**必须用同一个编码**。

参考池子每个方向只用一个字（word）：低 160 位是价格，其上打包截止块
`maxBlockNumber`（含该块）（BAP-710 §4.2.2）。它在 `quote` 和 `swap` 里的
读取路径是：

```solidity
uint256 data = registry.getState(laneFor(tokenIn, tokenOut), 1)[0] & SLOT0_DATA_MASK; // drop the seq bits
if (data == 0) revert NoPrice();
if (block.number > data >> 160) revert StaleUpdate();   // pool-enforced expiry
uint256 price = data & ((1 << 160) - 1);                // 1e18-scaled tokenOut per tokenIn
```

maker 在链下按同样方式打包这个字（链上参考是 `pool.packQuote(price,
maxBlockNumber)`）。槽位布局、成交路径和测试见
[`contracts/README.md`](../contracts/README.md)（英文）。

两个注册表事实决定你的槽位布局（完整模型见
[`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md)）：

- **防重放是注册表的事。** 每次直写带一个 48 位 `seq`，同一 lane 必须严格
  递增；注册表把它打包进 **slot 0 的最高 48 位**，所以 `slots[0]` 只有
  208 个数据位，slot 1 起全宽。旧的或重放的更新永远盖不掉新的，无论谁提交。
- **保鲜是你的事。** 注册表不存任何过期信息。把截止块打包进你自己的布局，
  例如 slot 0 的 208 个数据位里放 `price` + `maxBlockNumber`，池子在
  `block.number` 超过后 revert。Relayer 在链下也会独立执行报价的
  `maxBlockNumber`，但池子不能只依赖它：没落地的报价 tx 在其 nonce 被
  消耗之前一直可以被打包，谁拿着它都还能晚些让它落地。

### 2. 在注册表上授权报价 EOA

注册表的 updater 管理必须**由 target 调用**（你的池子），所以给池子加一个
owner 限定的辅助方法：

```solidity
function addMaker(address maker) external onlyOwner { REGISTRY.addUpdater(maker); }
function removeMaker(address maker) external onlyOwner { REGISTRY.removeUpdater(maker); }
```

只有授权的 updater 能写你池子的 lane（否则
`registry.updateState(pool, lane, slots, seq)` revert `NotAuthorized()`）。
**每条报价流用独立 EOA**，原因见第 4 步的 nonce 说明。updater EOA 还必须
持有足够的 BNB，才能通过 relayer 的下一个块模拟；gas 只在成交把报价 tx
带上链时才花掉。

**另一种方式：decoder lane 上的签名更新。** 不授权 updater EOA，池子也可以
给一条 lane 绑定 decoder（`registry.setDecoder`，永久生效），并在 decoder
上登记一把签名 Key。此后的更新是由这把 Key 签名的 EIP-712 payload（签名方
可以是 EOA，也可以是 ERC-1271 钱包，如多签或 MPC 托管），任何账户都可以用
`registry.updateStateWithDecoder(...)` 提交。参考 decoder
[`SignedSeqDecoder`](../contracts/SignedSeqDecoder.sol)（BAP-710 §4.2.3）已
随本仓库提供，参考池子可以通过 `pool.bindDecoder(tokenIn, tokenOut, decoder)`
和 `pool.setSigner(decoder, signer)` 使用它。它执行同样
的按 lane 严格递增 `seq` 和同样的 slot 0 布局，所以池子读两种 lane 的方式
完全相同。Relayer 两种报价 tx 都接受。

### 3. 在 console 登记池子

在 console 的 *Maker* 工作区：

- **Router 地址**：填你部署的池子。你发的每条报价都归属到这个 venue；
  taker 在 overlay 的 `venues[]` 里能看到并按它过滤。没登记 router 的
  maker，报价仍参与定价，但没有 venue 归属。归属只来自 console，请求
  本身不能声明自己的池子。
- **可见性**：`public`（默认：任何调用方，带不带 Key 都能看到你的报价）
  或 `restricted`（只有你勾选的 taker）。勾选在 relayer 下一次快照刷新后
  生效。受限报价不会进入任何其他调用方的模拟、订阅流和撮合。如果不希望
  你的报价状态对所有人可见，就必须设为受限。

另外，对你报价的每个交易对都调用 `pool.addPair(tokenA, tokenB)`：relayer
的价格梯子只为 `getPairs()` 报告的交易对报价。不调用也不影响定价和成交。

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

- `uuid`（16 字节）标识一条报价流，通常一个市场一条。同 uuid 下更高的
  `seq` **完全替换**上一条报价。
- `tx` 是你签名的 `registry.updateState(...)` 交易（decoder lane 上则是
  `updateStateWithDecoder(...)`）。**空 `tx`（`0x`）取消该 uuid**；此后
  直到取消请求的 `maxBlockNumber`，该 uuid 拒收一切更新，所以请换新 uuid
  继续。
- `maxBlockNumber` 是报价可成交的最后一个块（含）；`0` 或超限值被钳到
  「链头 + 100」个块（参考默认的寿命上限）。

参考 maker（[`e2e/src/maker.js`](../e2e/src/maker.js)）遵循下面两条规则，
你的 maker 也应遵循：

- **两层共用一个 `seq`。** calldata 里的注册表 `seq` 必须大于该 lane 在
  链上存的 seq（它只在报价 tx 落地时才前进，也就是成交时）；信封里的
  `seq` 必须大于你在该 uuid 下发过的上一个值。两者是独立的计数器，但
  **两边都发同一个值，即 unix 毫秒**，就能在重启前后都保持单调。链上值
  可以用 `pool.readQuote(tokenIn, tokenOut)` 读回。
- **两层共用一个截止块。** 把同一个 `maxBlockNumber` 同时打包进 lane 字
  （由你的池子执行）和信封（由 relayer 和 builder 执行），这样 relayer
  永远不会把你池子会拒绝的报价放进 bundle，relayer 已经丢弃的报价你的
  池子也会拒绝。

对报价 tx 的要求。relayer 会在下一个块上模拟，失败即拒收：

- 必须**执行成功**（revert 原因会在响应的 error 里返回）。
- 用 EOA 的**当前链上 nonce** 签名；因为 tx 不会单独上链，**这条流的每次
  更新都复用这个 nonce**。一旦链上 nonce 前进（成交了，或你从该账户发了
  别的交易），在线报价即视为*已消耗*并移除，下一条更新换新 nonce。
- 保持**纯 setter**：写入只依赖 calldata。抓取的写集会被原样复用直到被
  替换。
- 同一 EOA 的所有报价 tx 共享一个 nonce，所以你的两条流不可能在同一个
  bundle 里同时成交。可能被一起撮合的流请用不同 EOA。
- 成交时 tx 上链，按你签名的 gas 价自付 gas。

完整请求 / 响应 schema 和全部错误串：[`api-guide.zh-CN.md`](./api-guide.zh-CN.md) §2。

### 5. Maker 保护

- **保鲜保护**：四层机制共同约束任何被成交报价的年龄（BAP-710 §4.7）：
  - **截止块**：你的 `maxBlockNumber`；过了这个块 relayer 不再使用该报价，
    携带它的每个 bundle 届时也在 builder 端过期；
  - **报价时效上限**：relayer 给每条更新盖收到时间戳，每个新块把超过运营
    方上限的报价清掉，与 `maxBlockNumber` 无关（`pamm_status` 中的
    `maxQuoteAgeMs`；`0` 表示关闭，即参考默认值，此时请依赖你的截止块）；
  - **池子端过期检查**：你的池子在读取时自己做的截止块检查（第 1 步），
    即使过期的更新被打包上链也依然有效；
  - **顺序**：更高的 `seq` 在 relayer 内替换旧报价，按 lane 的注册表
    `seq` 防止旧更新在链上覆盖新更新。
- **写入范围校验**：运营方可把报价 tx 的写入限制在标准合约内；越界写整条
  拒收。
- **报价流归属**：uuid 归创建它的 maker 账户所有，别的 maker 无法更新或
  取消。
- **取消语义**：取消在 relayer 内立即生效，但取消*之前*已撮合的 bundle
  仍可能落地，上限是该报价的 `maxBlockNumber`。高频改价请把截止块收紧。
- **价格保护**（相对参考价格的最大偏离）是计划中的扩展，目前尚未提供。

### Maker 清单

| # | 动作 | 在哪 |
| --- | --- | --- |
| 1 | 登录、申请 `maker` 角色、等审批 | console |
| 2 | 签发 maker API Key（`pamm_maker_…`） | console |
| 3 | 部署池子：`IPropAMM` + 注册表 lane 读取 + 读取时的截止块检查（参考 [`ExamplePammRouter.sol`](../contracts/ExamplePammRouter.sol)、[`script/Deploy.s.sol`](../contracts/script/Deploy.s.sol)） | 你 |
| 4 | `pool.addMaker(EOA)` → 注册表 `addUpdater`；给 EOA 充 BNB 付 gas | 你 |
| 5 | 给池子备好库存（参考池：先转账，再调 `sync(token)`） | 你 |
| 6 | 对报价的每个交易对调用 `pool.addPair(tokenA, tokenB)` | 你 |
| 7 | 在 console 填 **Router 地址**、选可见性 | console |
| 8 | 带 `x-api-key` 流式发送 `pamm_sendQuoteUpdateV1`（lane 字和信封里用同一个 `maxBlockNumber`） | 你 → relayer |

---

## Taker 接入

### 1. 在 console 获取 taker API Key（可选，但建议）

在 [console](https://console.bnbchain.org/) 登录、申请 `taker` 角色，审批
通过后在 *API Keys* 签发一个 taker Key（`pamm_taker_…`），之后每个
relayer 请求都放在 `x-api-key` 请求头里。

不带 Key 也能用：匿名调用方能看到所有**公开** maker 的报价。带 Key 额外
带来：

- 勾选了你账户的**受限** maker 的报价，以及
- 你的 **builder 路由**选择（见第 4 步）。

未知或失效的 Key 不会打断读取，只是降级为匿名公开视图。

### 2. 获取 PropAMM Pool 的报价

Relayer RPC 端点：`https://propamm.bnbchain.org`（WS 订阅走同一主机的
`wss://`）。通用的链上读取请继续用你现有的 BSC RPC；relayer 部署方可能
限制这里所述以外的方法。PropAMM 池子的价格来自 maker 的报价 overlay，只有
relayer 知道；拿到报价有三种方式，按接入成本从低到高：

**方式 A：直接对 relayer 端点发 `eth_call` 模拟。** 最简单：把定价
RPC 指向 relayer，像调任何普通池子一样调 `IPropAMM.quote`（或直接模拟你
整笔成交交易），没有 PropAMM 专用的请求格式。`eth_call`、`debug_traceCall`
都在**链上状态加你的报价 overlay** 上作答（只对规范链头生效；你显式传的
`stateOverride` 参数仍优先于 overlay）。

**方式 B：从 relayer 订阅 state override，在本地全节点用 `eth_call`
模拟。** 适合自建模拟设施、不想把定价流量打到 relayer 的 taker：

- 一次性拉取：`pamm_getPammStateOverrides`；
- 实时流：`pamm_subscribe("subscribeNewQuotesV1")`（WS，默认每 100ms 推
  一帧完整快照，保留最新一帧即可）。

返回的 `overrides` 是 `账户 → 槽 → 值` 的合并视图，直接塞进本地节点
`eth_call` 的 `stateDiff` 参数即可得到与 relayer 一致的报价；`venues[]`
是同一数据按 maker router 的切片，用于按 venue 过滤。

**方式 C：通过 price levels 直接获取一个池子的价格。** 不想自己模拟的
taker 可以要现成的价格梯子：relayer 已经替你对每个池子、每个交易对在多个
size 上调过 `quote`，返回按 pAMM 分组的档位表（`amountIn → amountOut`，
含模拟档与插值档）。

- 一次性拉取：`pamm_getPammPriceLevels`；
- 实时流：`pamm_subscribe("subscribePriceLevelsV1", { "pamms": [...] })`，
  `pamms` 收窄到你关心的池子地址。

价格梯子只覆盖池子在 `getPairs()` 中报告的交易对，并且只有当你的视图包含
池子上登记的每个 maker 时，这个池子才会出现。

三种方式共用同一套可见性：带 taker Key 时包含勾选了你的受限 maker，否则
只有公开报价。字段细节见 [`api-guide.zh-CN.md`](./api-guide.zh-CN.md) §3。

### 3. 成交上链

拿到满意的报价后，签一笔普通交易，用 `eth_sendRawTransaction` 发到同一个
relayer 端点，请求头照样带上 `x-api-key`。不需要任何 bundle 格式，也不需要
自己拼报价 tx。

因为池子是 push-payment，成交必须是一笔**合约调用**：在同一笔交易里把
`amountIn` 的 `tokenIn` 转进池子、再调 `IPropAMM.swap`——可以是替你做这件事
的聚合器 / 路由，也可以是参考实现
[`ExamplePammTaker.sol`](../contracts/ExamplePammTaker.sol)（`approve` 它一次，
然后调它的 `swap`）。钱包直接调池子的 `swap` 没有任何推入余额，会 revert。

Relayer 收到后会做这几件事：

1. 按你的 Key 确定你的视图：能看到哪些 maker 的报价、bundle 允许发给哪些
   builder；
2. 在你的报价 overlay 上模拟这笔交易，记录它读到了哪些存储槽；
3. 只要读到了被报价的槽位，就把对应的最新一条报价 tx 找出来；
4. 把这些报价 tx 排在你的交易前面，组成 `[报价 tx…, 你的 tx]`，在干净的
   链上状态上重新模拟一遍；
5. 模拟成功的话，把这个 bundle 并行发给接入的 builder。

真正大额下单之前需要知道：

- **`minAmountOut` 是你的价格保护。** 和你一起进 bundle 的是你的交易
  *到达*时的在线报价，而不是你模拟时的那份快照，所以要为报价变动留出
  余量。
- **回退。** relayer 无法组 bundle 的一切（未同步、没有匹配的报价、重新
  模拟失败、没有 builder 接受、对 pending 交易的 nonce 替换……）都走普通
  txpool，与普通节点完全一样。在那里 PropAMM 成交没有报价可用，会
  revert：你付 gas，资金不动。
- **落地前保持私有。** 进了 bundle 的交易不在公共 txpool 里；在 builder
  打包它之前，`eth_getTransactionByHash` 返回 null。
- **只发给 relayer。** 不要把同一笔签名交易同时广播到公共 RPC：如果公共
  那份先进了 relayer 的 txpool，它就成了「already known」，错过 bundle
  路径。发给 relayer 的非 PropAMM 交易反正也会经它的 txpool 转发。
- **Solver 与聚合器**必须只把 PropAMM 路由返回给签名交易能到达 relayer
  的钱包；同一笔交易只发到公共 BSC RPC 会 revert。

### 4. Builder 路由（可选）

默认情况下，relayer 会把你的 bundle 发给它接入的全部 builder，包括以后
新增的。如果只想发给指定的几家，在 console 的 *Taker → Builder Routing*
页按品牌勾选（如 `48club`、`blockrazor`）。

勾选是白名单：没勾的一律不发。如果某台 relayer 上一个你勾的 builder 都
没有，你的交易在那台 relayer 上会直接走公共 txpool。变更在 relayer 下一次
刷新快照后生效。

### Taker 清单

| # | 动作 | 在哪 |
| --- | --- | --- |
| 1 | 登录、申请 `taker` 角色、等审批 | console |
| 2 | 签发 taker API Key（`pamm_taker_…`） | console |
| 3 | 需要受限 maker 的报价时，请对方在 console 勾选你的账户 | 对方的 console |
| 4 | （可选）在 *Builder Routing* 勾选 builder | console |
| 5 | 带 `x-api-key` 取报价（§2 三种方式任选） | 你 → relayer |
| 6 | 用 `eth_sendRawTransaction` 只发给 relayer 成交：一笔「推入 + swap」的合约调用（如 `ExamplePammTaker`），`minAmountOut` 为报价变动留出余量 | 你 → relayer |

---

## 部署地址

| 名称 | 值 |
| --- | --- |
| Relayer RPC（HTTP） | <https://propamm.bnbchain.org> |
| Relayer RPC（WS，订阅类方法） | `wss://propamm.bnbchain.org` |
| Console | <https://console.bnbchain.org/> |
| `PrioUpdateRegistry`（oracle，BSC） | [`0x4EaBe41ccAEcdbb16b7CE67D893E698757D2C9AD`](https://bscscan.com/address/0x4EaBe41ccAEcdbb16b7CE67D893E698757D2C9AD) |
| 你的池子 / router | *（你自己部署，部署后填进 console）* |

## 参考

- [`api-guide.zh-CN.md`](./api-guide.zh-CN.md) — 完整 relayer API 参考。
- [`contracts/README.md`](../contracts/README.md) — 参考池子的槽位布局、
  成交路径、权限控制，以及构建 / 测试 / 部署（英文）。
- [`PrioUpdateRegistry.md`](../contracts/PrioUpdateRegistry.md) — lane、seq、
  decoder lane、存储布局与错误（英文）。
- [`e2e/README.zh-CN.md`](../e2e/README.zh-CN.md) — 对接在线 relayer 的
  可运行 maker 与 taker。
- [BAP-710](https://github.com/bnb-chain/BEPs/pull/710) — 规范、架构与设计依据。
