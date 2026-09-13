const ethers = require("ethers");
const cfg = require("./config");
const {WsRpc} = require("./wsrpc");
const {oracleIface} = require("./abi");
const {httpRpc, log} = require("./utils");
const {laneFor, packQuote} = require("./lane");

// maker: periodically builds a quote transaction calling
// registry.updateState(router, lane, [packQuote(price, maxBlockNumber)], seq),
// serializes it and pushes it to the RELAYER via pamm_sendQuoteUpdateV1. The
// relayer simulates the tx on the next-block env, captures its storage
// write-set, and merges it into the overlay that prices every eth_call and
// matches every taker on this node.
//
// One seq feeds both consumers: the relayer requires it strictly increasing
// per uuid, and the registry requires it strictly increasing per lane
// (uint48, packed into slot 0's top bits — an on-chain replay of an older
// update is rejected as StaleSeq). Deriving it from unix milliseconds keeps
// it monotonic across maker restarts, when a plain counter would restart
// below the seq already stored on chain.
//
// Things to know about the ingress:
//   - endpoint is the relayer's own RPC (HTTP or WS). With a console
//     configured the relayer requires the maker's console-issued API key in
//     the x-api-key header (MAKER_API_KEY here), resolves it in memory
//     against the console's permission snapshot, and attributes the quote to
//     that maker's registered router; without one the namespace is
//     unauthenticated and the node must expose it privately;
//   - per-update errors come back IN-BAND (resp.error), never as a JSON-RPC
//     error, so a bad quote does not break the stream;
//   - optional updateOnChain additionally publishes the quote through the
//     public txpool (needs bumped/rotated nonces to avoid "replacement
//     underpriced");
//   - on Ctrl-C we send a cancel (empty tx) so the uuid tombstones instead of
//     lingering until maxBlockNumber.
//
// The quote tx normally never lands on chain on its own (it is a carrier for
// the captured state diff), so the same nonce is reused across the stream; seq
// increases monotonically within the uuid. Once a fill lands the quote tx in a
// bundle, the on-chain nonce advances — hence the pending-nonce refresh every
// round.

function assertConfig() {
    const miss = [];
    if (!cfg.MAKER_PK) miss.push("MAKER_PK");
    if (cfg.ORACLE === "0x0000000000000000000000000000000000000000") miss.push("ORACLE");
    if (cfg.ROUTER === "0x0000000000000000000000000000000000000000") miss.push("ROUTER");
    if (cfg.TOKEN_OUT === "0x0000000000000000000000000000000000000000") miss.push("TOKEN_OUT");
    if (miss.length) {
        throw new Error(`missing config: ${miss.join(", ")} (set in .env)`);
    }
}

function jitterPrice(basePrice, bps) {
    if (!bps) return basePrice;
    const delta = Math.floor((Math.random() * 2 - 1) * bps); // [-bps, +bps]
    const base = BigInt(basePrice);
    return (base + (base * BigInt(delta)) / 10000n).toString();
}

// pamm calls go over WS when RELAYER_WS is set, else plain HTTP.
function makeRelayerClient() {
    if (cfg.RELAYER_WS) {
        const ws = new WsRpc(cfg.RELAYER_WS, cfg.MAKER_API_KEY);
        return {
            kind: `ws ${cfg.RELAYER_WS}`,
            connect: () => ws.connect(),
            call: (method, params) => ws.call(method, params),
            close: () => ws.close(),
        };
    }
    return {
        kind: `http ${cfg.RELAYER_RPC}`,
        connect: async () => {},
        call: (method, params) => httpRpc(cfg.RELAYER_RPC, method, params, cfg.MAKER_API_KEY),
        close: () => {},
    };
}

async function main() {
    assertConfig();

    const wallet = new ethers.Wallet(cfg.MAKER_PK);
    log("maker address =", wallet.address);
    log("oracle        =", cfg.ORACLE);
    log("router(target)=", cfg.ROUTER);
    log("pair          =", `${cfg.TOKEN_IN} -> ${cfg.TOKEN_OUT}`);
    log("price         =", `${cfg.QUOTE_PRICE} (1e18-scaled tokenOut per tokenIn)`);
    log("updateOnChain =", cfg.UPDATE_ONCHAIN ? "on" : "off");
    log("maker key     =", cfg.MAKER_API_KEY ? "set" : "none (open relayer)");

    const laneIndex = laneFor(cfg.TOKEN_IN, cfg.TOKEN_OUT);
    log("laneIndex     =", laneIndex);

    const cli = makeRelayerClient();
    await cli.connect();
    log("connected to relayer:", cli.kind);

    const fetchNonce = async () => {
        const nonceHex = await httpRpc(cfg.PUBLIC_RPC, "eth_getTransactionCount", [
            wallet.address,
            "pending",
        ]);
        return parseInt(nonceHex, 16);
    };
    const fetchBlockNumber = async () => {
        const bnHex = await httpRpc(cfg.PUBLIC_RPC, "eth_blockNumber", []);
        return parseInt(bnHex, 16);
    };
    let nonce = await fetchNonce();
    log("maker nonce   =", nonce);
    let headBlock = await fetchBlockNumber();
    log("maker block   =", headBlock);

    // All quotes in the stream share one uuid (16 bytes); seq is monotonic.
    const uuid = ethers.utils.hexlify(ethers.utils.randomBytes(16));
    log("quote uuid    =", uuid);

    let seq = 0;
    const sendOnce = async () => {
        // Strictly increasing and restart-safe: unix millis, bumped by one
        // when two frames land in the same millisecond. Shared by the relayer
        // (per-uuid ordering) and the registry (per-lane StaleSeq guard).
        seq = Math.max(seq + 1, Date.now());
        const price = jitterPrice(cfg.QUOTE_PRICE, cfg.QUOTE_JITTER_BPS);

        // Refresh nonce/head each round; on RPC hiccups reuse the last values.
        try {
            nonce = await fetchNonce();
        } catch (e) {
            log(`quote seq=${seq} fetch nonce failed, reuse ${nonce}: ${e.message || e}`);
        }
        try {
            headBlock = await fetchBlockNumber();
        } catch (e) {
            log(`quote seq=${seq} fetch block failed, reuse ${headBlock}: ${e.message || e}`);
        }
        // Inclusive deadline; the relayer clamps to head + MaxQuoteLifeBlocks.
        // One value feeds both the packed word (validated on chain by the
        // router) and the relayer's quote lifetime, so the two deadlines can
        // never diverge.
        const maxBlockNumber = cfg.QUOTE_MAX_BLOCK_NUMBER || headBlock + 100;

        // updateState(router, lane, [packQuote(price, maxBlockNumber)], seq);
        // requires isUpdater[router][maker] = true (router.addMaker at deploy
        // time). The freshness deadline lives inside the packed word; the
        // registry stores it verbatim and the router validates it on read.
        const data = oracleIface.encodeFunctionData("updateState", [
            cfg.ROUTER,
            laneIndex,
            [packQuote(price, maxBlockNumber)],
            seq,
        ]);

        const rawTx = await wallet.signTransaction({
            chainId: cfg.CHAIN_ID,
            type: 0, // legacy
            to: cfg.ORACLE,
            value: 0,
            nonce,
            gasPrice: ethers.BigNumber.from(cfg.MAKER_GAS_PRICE),
            gasLimit: ethers.BigNumber.from(cfg.MAKER_GAS_LIMIT),
            data,
        });

        const args = {
            uuid,
            seq,
            tx: rawTx,
            maxBlockNumber,
        };
        if (cfg.UPDATE_ONCHAIN) args.updateOnChain = true;

        try {
            const resp = await cli.call("pamm_sendQuoteUpdateV1", [args]);
            // Per-update errors are in-band (resp.error), so a rejected quote
            // never breaks the call channel.
            if (resp && resp.error) {
                log(`quote seq=${seq} price=${price} REJECTED: ${resp.error}`);
            } else {
                log(`quote seq=${seq} price=${price} maxBlockNumber=${maxBlockNumber} ok ts=${resp && resp.timestamp}`);
            }
        } catch (e) {
            log(`quote seq=${seq} send failed: ${e.message || e}`);
        }
    };

    await sendOnce();
    const timer = setInterval(sendOnce, cfg.QUOTE_INTERVAL_MS);

    process.on("SIGINT", async () => {
        clearInterval(timer);
        if (cfg.MAKER_CANCEL_ON_EXIT) {
            // Empty tx = cancel: the uuid tombstones until its height expiry,
            // and no late pre-cancel update can resurrect it.
            seq = Math.max(seq + 1, Date.now());
            try {
                const resp = await cli.call("pamm_sendQuoteUpdateV1", [
                    {uuid, seq, tx: "0x", maxBlockNumber: headBlock + 100},
                ]);
                if (resp && resp.error) {
                    log(`cancel seq=${seq} REJECTED: ${resp.error}`);
                } else {
                    log(`cancel seq=${seq} sent, uuid tombstoned`);
                }
            } catch (e) {
                log(`cancel failed: ${e.message || e}`);
            }
        }
        cli.close();
        log("maker stopped");
        process.exit(0);
    });
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
