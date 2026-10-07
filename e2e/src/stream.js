const cfg = require("./config");
const {log} = require("./utils");
const {WsRpc} = require("./wsrpc");

// stream: subscribe to the relayer's overlay snapshot push
// (pamm_subscribe / subscribeNewQuotesV1) and print each frame raw, exactly
// as the API returned it (one summary line, then the full JSON). Needs
// RELAYER_WS with the pamm namespace exposed (--ws --ws.api ...pamm).
// TAKER_API_KEY, when set, is the caller's view (restricted makers included);
// without it this is the anonymous public view.

function httpToWs(url) {
    if (!url) return "";
    if (url.startsWith("ws://") || url.startsWith("wss://")) return url;
    if (url.startsWith("https://")) return "wss://" + url.slice("https://".length);
    if (url.startsWith("http://")) return "ws://" + url.slice("http://".length);
    return url;
}

async function main() {
    const wsUrl = cfg.RELAYER_WS || httpToWs(cfg.RELAYER_RPC);
    if (!wsUrl || wsUrl.startsWith("http")) {
        log("set RELAYER_WS (e.g. ws://127.0.0.1:8546) — overlay snapshot subscribe is WS/IPC only");
        process.exit(1);
    }

    log("relayer ws =", wsUrl, cfg.TAKER_API_KEY ? "(taker key)" : "(anonymous)");
    const rpc = new WsRpc(wsUrl, cfg.TAKER_API_KEY);
    await rpc.connect();

    let n = 0;
    const subId = await rpc.subscribe("pamm", "subscribeNewQuotesV1", [{}], (frame) => {
        n++;
        const accounts = Object.keys((frame && frame.overrides) || {});
        const venues = (frame && frame.venues) || [];
        log(
            `#${n} block=${frame.blockNumber} ts=${frame.millisTimestamp} accounts=${accounts.length} venues=${venues.length}`
        );
        // Print the frame exactly as the API returned it: this is the
        // eth_call-compatible stateDiff a taker would apply on its own node.
        console.log(JSON.stringify(frame, null, 2));
    });
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
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
