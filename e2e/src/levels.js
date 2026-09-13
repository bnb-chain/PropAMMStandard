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
    const pamms = (frame && frame.pamms) || [];
    log(`#${n} block=${frame.blockNumber} ts=${frame.millisTimestamp} pamms=${pamms.length}`);
    for (const p of pamms) {
        log(`  pamm ${p.pamm}: ${p.pairs.length} direction(s)`);
        for (const pair of p.pairs) {
            const sim = pair.levels.filter((l) => l.source === "simulated").length;
            log(`    ${pair.tokenIn} -> ${pair.tokenOut}: ${pair.levels.length} level(s), ${sim} simulated`);
            for (const l of pair.levels) {
                const amountIn = BigInt(l.amountIn);
                const amountOut = BigInt(l.amountOut);
                // 1e18-scaled out/in ratio, shown with 6 decimals; only a
                // sanity print — the tokens' decimals are not looked up.
                const ratio = amountIn === 0n ? 0n : (amountOut * 1000000n) / amountIn;
                log(`      ${l.source.padEnd(12)} in=${amountIn} out=${amountOut} out/in=${(Number(ratio) / 1e6).toFixed(6)}`);
            }
        }
    }
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
