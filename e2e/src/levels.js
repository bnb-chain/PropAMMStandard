const cfg = require("./config");
const {httpRpc, log, sleep} = require("./utils");
const {WsRpc} = require("./wsrpc");

// levels: consume the relayer's PropAMM price ladder. Over WS (RELAYER_WS
// set) it subscribes to pamm_subscribe / subscribePriceLevelsV1 and prints
// every frame; otherwise it polls pamm_getPammPriceLevels over HTTP every
// LEVELS_POLL_MS. TAKER_API_KEY, when set, is the caller's view (restricted
// makers included); without it this is the anonymous public view.
//
// Each frame is a complete snapshot: one entry per PropAMM contract with at
// least one quotable pair, one ladder per (tokenIn -> tokenOut) direction,
// levels ascending by amountIn, each either simulated (the contract's
// quote() on the caller's overlay) or interpolated between two simulated
// neighbours. The contract must report its pairs through getPairs() — with
// the example router, register them once with router.addPair(tokenA, tokenB).

const POLL_MS = Number(process.env.LEVELS_POLL_MS || 2000);

function httpToWs(url) {
    if (!url) return "";
    if (url.startsWith("ws://") || url.startsWith("wss://")) return url;
    if (url.startsWith("https://")) return "wss://" + url.slice("https://".length);
    if (url.startsWith("http://")) return "ws://" + url.slice("http://".length);
    return url;
}

let n = 0;
function printFrame(frame) {
    n++;
    // Print the frame exactly as the API returned it (amounts stay hex).
    log(`#${n}`);
    console.log(JSON.stringify(frame, null, 2));
}

async function main() {
    const wsUrl = cfg.RELAYER_WS || "";
    if (wsUrl && !wsUrl.startsWith("http")) {
        log("relayer ws =", wsUrl, cfg.TAKER_API_KEY ? "(taker key)" : "(anonymous)");
        const rpc = new WsRpc(wsUrl, cfg.TAKER_API_KEY);
        await rpc.connect();
        const subId = await rpc.subscribe("pamm", "subscribePriceLevelsV1", [{}], printFrame);
        log("subscribed", subId);
        process.on("SIGINT", async () => {
            try {
                await rpc.unsubscribe("pamm", subId);
            } catch {
                // connection may already be gone
            }
            rpc.close();
            process.exit(0);
        });
        return;
    }

    log("relayer rpc =", cfg.RELAYER_RPC, cfg.TAKER_API_KEY ? "(taker key)" : "(anonymous)", `poll=${POLL_MS}ms`);
    log("tip: set RELAYER_WS to stream instead of polling");
    for (;;) {
        try {
            // The first call after idle waits for one simulation tick.
            const frame = await httpRpc(cfg.RELAYER_RPC, "pamm_getPammPriceLevels", [], cfg.TAKER_API_KEY);
            printFrame(frame);
        } catch (e) {
            log(`pamm_getPammPriceLevels failed: ${e.message || e}`);
        }
        await sleep(POLL_MS);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
