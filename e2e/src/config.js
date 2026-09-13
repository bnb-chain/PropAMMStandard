// All endpoints / addresses / keys in one place. Override via .env / env vars.
// Target environment: this repo's unified PropAMM relayer node (a BSC fork).
//
// NOTE: never hardcode real private keys here. Put them in a local .env file
// (gitignored). See .env.example for the full list of variables.
require("dotenv").config();

const cfg = {
    CHAIN_ID: Number(process.env.CHAIN_ID || 56),

    // The relayer node's HTTP RPC. Must expose pamm alongside eth
    // (--http.api eth,net,web3,pamm); the pamm write method is unauthenticated,
    // so in any real deployment this endpoint must be private.
    RELAYER_RPC: process.env.RELAYER_RPC || "http://127.0.0.1:8545",
    // Optional WS endpoint; the maker prefers it when set. Overlay snapshot
    // subscribe (pamm_subscribe) requires WS.
    RELAYER_WS: process.env.RELAYER_WS || "",
    // Plain chain reads (nonce, block number, receipts). The relayer is a full
    // node, so it doubles as the default.
    PUBLIC_RPC: process.env.PUBLIC_RPC || process.env.RELAYER_RPC || "http://127.0.0.1:8545",
    // Optional vanilla node for the no-overlay counterfactual eth_call.
    COMPARE_RPC: process.env.COMPARE_RPC || "",

    // ===== Deployed contract addresses (see README §2) =====
    ORACLE: process.env.ORACLE || "0x0000000000000000000000000000000000000000",
    ROUTER: process.env.ROUTER || "0x0000000000000000000000000000000000000000",

    // ===== Trading pair =====
    TOKEN_IN: process.env.TOKEN_IN || "0x55d398326f99059fF775485246999027B3197955", // USDT (18d)
    TOKEN_OUT: process.env.TOKEN_OUT || "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB (18d)

    // ===== Private keys (TEST ONLY — set in .env) =====
    MAKER_PK: process.env.MAKER_PK || "",
    TAKER_PK: process.env.TAKER_PK || "",

    // ===== Console API keys (empty = open relayer) =====
    // Sent as the x-api-key header; the relayer resolves the key against the
    // console's permission snapshot in memory. A relayer running with a
    // console rejects quotes without a valid maker key; a taker key unlocks
    // the restricted makers that ticked it (public makers are visible to
    // everyone, no key needed).
    MAKER_API_KEY: process.env.MAKER_API_KEY || "",
    TAKER_API_KEY: process.env.TAKER_API_KEY || "",

    // ===== Maker quote params =====
    // Price: 1e18-scaled "how much tokenOut 1 tokenIn buys", directional per
    // lane (tokenIn -> tokenOut): amountOut = amountIn * price / 1e18.
    // Example: USDT -> WBNB at 900 USDT/WBNB is 1e18/900 ≈ 1111111111111111.
    QUOTE_PRICE: process.env.QUOTE_PRICE || "1000000000000000000", // 1.0
    QUOTE_JITTER_BPS: Number(process.env.QUOTE_JITTER_BPS || 5),
    QUOTE_INTERVAL_MS: Number(process.env.QUOTE_INTERVAL_MS || 3000),
    // 0 = head + 100; the relayer clamps to arriveBlock + MaxQuoteLifeBlocks.
    QUOTE_MAX_BLOCK_NUMBER: Number(process.env.QUOTE_MAX_BLOCK_NUMBER || 0),
    MAKER_GAS_LIMIT: Number(process.env.MAKER_GAS_LIMIT || 120000),
    MAKER_GAS_PRICE: process.env.MAKER_GAS_PRICE || "1000000000", // 1 gwei
    // Also publish accepted quotes through the public txpool (updateOnChain).
    UPDATE_ONCHAIN: Number(process.env.UPDATE_ONCHAIN || 0),
    // Send a cancel (empty tx) for the stream uuid on Ctrl-C.
    MAKER_CANCEL_ON_EXIT: Number(process.env.MAKER_CANCEL_ON_EXIT ?? 1),

    // ===== Taker fill params =====
    TAKER_AMOUNT_IN: process.env.TAKER_AMOUNT_IN || "1000000000000000000", // 1 tokenIn
    TAKER_MIN_OUT: process.env.TAKER_MIN_OUT || "0", // 0 = sim - slippage
    // The relayer bundles the maker's LATEST resting quote, not the simulated
    // frame, so 0 bps reverts on any adverse tick (InsufficientOutput).
    TAKER_SLIPPAGE_BPS: process.env.TAKER_SLIPPAGE_BPS || "50", // 0.50%
    TAKER_TAKE_THRESHOLD: process.env.TAKER_TAKE_THRESHOLD || "0",
    TAKER_GAS_LIMIT: Number(process.env.TAKER_GAS_LIMIT || 200000),
    TAKER_GAS_PRICE: process.env.TAKER_GAS_PRICE || "10000000000", // 10 gwei
    TAKER_POLL_MS: Number(process.env.TAKER_POLL_MS || 1500),
    TAKER_DEDUP: Number(process.env.TAKER_DEDUP ?? 1),
    TAKER_DRY_RUN: Number(process.env.TAKER_DRY_RUN ?? 1),
    TAKER_WATCH_BLOCKS: Number(process.env.TAKER_WATCH_BLOCKS || 120),
    TAKER_LOOP: Number(process.env.TAKER_LOOP || 0),
};

module.exports = cfg;
