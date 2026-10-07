# PropAMM Relayer 端到端测试

> English: [README.md](./README.md)

针对 Unified PropAMM Relayer
（[BAP-710](https://github.com/bnb-chain/BEPs/pull/710)）的端到端测试：maker
通过 `pamm_sendQuoteUpdateV1` 流式发入报价，taker 是一个走标准 JSON-RPC 的
普通钱包：

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

两侧各需要什么：

| | 本 e2e |
|---|---|
| maker 上行 | `pamm_sendQuoteUpdateV1`，relayer 接了 console 时在 `x-api-key` 里带 maker API Key（否则不鉴权：请私有部署该端点） |
| 报价可见性 | 由 maker 在 console 设置（公开，或仅勾选的 taker）；可选通过 `pamm_subscribe` / `subscribeNewQuotesV1` 订阅 overlay 快照流（与 `eth_call` 同一视图） |
| 价格梯子 | `pamm_getPammPriceLevels` / `subscribePriceLevelsV1`：在调用方视图上按一系列 size 对 router 的交易对报价，无需解码槽位 |
| taker 定价 | 普通 `eth_call`，可选在 `x-api-key` 里带 taker API Key 以额外看到受限 maker（overlay 在服务端套用；不需要 `stateOverride` / `blockOverride`）。不在 relayer 上定价的接入方可以把订阅流里的 `overrides` 作为 `eth_call` 的 `stateDiff` 传入。 |
| taker 成交 | 普通 `eth_sendRawTransaction`，发一笔「推入 + swap」交易（`ExamplePammTaker.swap`；池子是 push-payment），可选请求头同上（不提交 bundle） |
| 运维 | `pamm_status`、`pamm_getPammStateOverrides`、`pamm_subscribe` / `subscribeNewQuotesV1` 和 `subscribePriceLevelsV1`（WS） |

## 1. Relayer 与 API Key

把 `RELAYER_RPC`（以及可选的 `RELAYER_WS`）指向 relayer，托管实例是
`https://propamm.bnbchain.org` / `wss://propamm.bnbchain.org`。从 console 获取
`MAKER_API_KEY` / `TAKER_API_KEY`（见
[`docs/onboarding.zh-CN.md`](../docs/onboarding.zh-CN.md) 第 0 步）；它们以
`x-api-key` 发送，relayer 在内存中对照 console 的权限快照解析。把
`PUBLIC_RPC` 设为一个普通的 BSC RPC：relayer 部署方可能限制 PropAMM 相关
方法以外的方法。

如果改为自己运行 relayer（`--propamm` geth 分叉），需要开放 `pamm` 命名空间
（`--http.api eth,net,web3,pamm`，`--ws.api` 同理），配置 builder，并为
鉴权的 maker 和 taker 配置 console。没有 console 时，
`pamm_sendQuoteUpdateV1` 是不鉴权的写方法，请把端点绑定在私有网络
（BAP-710 §4.4）。无论哪种方式，relayer 都要在连续五个链头各自 3 s 内到达
（即节点已同步）之后才会就绪；用 `npm run status` 检查。

## 2. 合约

测试脚手架驱动三个示例合约；源码在 `../contracts/`
（`PrioUpdateRegistry.sol`、`ExamplePammRouter.sol`、`ExamplePammTaker.sol`，
见 [`contracts/README.md`](../contracts/README.md)（英文）），`src/abi.js`
列出了它用到的方法。
[`script/Deploy.s.sol`](../contracts/script/Deploy.s.sol) 完成第 1–3 步和第
5 步：

1. 使用运营方的 `PrioUpdateRegistry`（`ORACLE`，BSC 上为
   `0x4EaBe41ccAEcdbb16b7CE67D893E698757D2C9AD`，即 `.env.example` 的
   默认值；relayer 和 overlay 只认写入你池子所读注册表的报价）。只有在私有测试环境里才自己部署
   `PrioUpdateRegistry()`。它把按 lane 严格递增的 `seq` 打包进 slot 0，
   除此之外什么都不校验；保鲜由池子自己的 lane 布局负责。
2. 部署 `ExamplePammRouter(registry)`，即示例池子。它把
   `(price, maxBlockNumber)` 打包进一个 lane 字，并在读取时执行含当块的
   截止检查（超过即 `StaleUpdate`）。
3. 授权 maker：router owner 调用 `router.addMaker(MAKER)`；用
   `router.isMaker(maker)` 验证。
4. 给 router 本身补充 `TOKEN_OUT` 库存：普通转账，然后调用
   `router.sync(TOKEN_OUT)` 把它记为库存（swap 从 router 自己的储备里付款；
   没 sync 的补仓会被下一次 swap 当作推入的付款）。
5. 登记交易对以便被发现：router owner 调用
   `router.addPair(TOKEN_IN, TOKEN_OUT)`（每个交易对一次，顺序不限）。
   relayer 的价格梯子只为 `getPairs()` 报告的交易对报价；不登记也不影响
   定价和成交。
6. Taker 侧：持有 `TOKEN_IN`。Swap 是 push-payment（按 `IPropAMM`）：池子
   消费的是已经转给它的 `amountIn`。两种成交方式：
   - **一笔交易（推荐）**：务必用 taker 钱包部署 `ExamplePammTaker`（无构造参数；
     只有部署者能调它的 `swap`），从该钱包调用
     `TOKEN_IN.approve(taker, amount)`，设置 `TAKER_CONTRACT`。它的 `swap`
     直接 transferFrom 进池子，并原子地调用 `pool.swap`。带 taker 白名单的
     池子必须把 taker 合约（而不是钱包）加入白名单。
   - **两笔交易**（`TAKER_CONTRACT` 留空）：钱包先经 `PUBLIC_RPC` 把
     `amountIn` 转给 router，等待确认，再经 relayer 发送 `swap`。

Maker 账户还必须持有足够的 BNB，才能通过 relayer 下一个块模拟中的余额检查
（gas 只在成交把报价 tx 带上链时才真正花掉）。

## 3. 配置与运行

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

taker 每轮轮询打印按 overlay 定价的 `amountOut`（把 `COMPARE_RPC` 设为一个
原生节点，还会打印反事实结果：同样的调用在那里会 revert
`NoPrice`/`StaleUpdate`）。设置 `TAKER_DRY_RUN=0` 时，它发送一次 swap 并
观察是否落地。

## 预期现象

- **进了 bundle 的交易不可见**：`eth_getTransactionByHash` 返回 null，交易
  也不在 txpool 里；builder 让 bundle 落地后才出现。观察器会明确记录这个
  状态。
- **回退时没有报价可用**：如果 relayer 未就绪、没有碰撞，或所有 builder
  都不可用，交易会进公共 txpool，swap 在链上 revert `NoPrice` /
  `StaleUpdate`（taker 付 gas），与发给原生节点完全一样。taker 发送前会
  先检查 `pamm_status`（`ready && overlaySlots > 0`），让这种情况尽量少见。
- **Push-payment**：设置了 `TAKER_CONTRACT` 时，成交是一笔原子交易，池子
  上永远不会残留余额。不设时，e2e 先用一笔交易把 `TOKEN_IN` 推给 router，
  下一笔再 swap；两笔之间，推入的余额谁先调 `swap` 谁就能拿走（示例
  router 不设权限）。走这条路径请用测试金额。
- **滑点是你唯一的价格保护**：relayer 打包的是 maker 最新的在线报价，而不是
  你模拟的那一帧，所以保持 `TAKER_SLIPPAGE_BPS` > 0。
- **Maker 复用 nonce 没问题**：报价 tx 只是所抓写集的载体；同一个 nonce
  一直流式复用，直到某次成交把它消耗掉（maker 每一轮都会刷新 pending
  nonce）。`UPDATE_ONCHAIN=1` 会让报价同时经 txpool 发布，这需要提高或
  轮换 nonce（否则报 "replacement underpriced"）。
- **Ctrl-C 即取消**：maker 退出时发送一条空 tx 取消，给该 uuid 留下墓碑，
  这样过期报价不会一直挂到 `maxBlockNumber`。
