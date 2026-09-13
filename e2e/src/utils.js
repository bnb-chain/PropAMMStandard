const axios = require("axios");

// Plain HTTP JSON-RPC. On an error response, the thrown Error carries the
// error's `data` field (revert data for eth_call) as err.data. apiKey, when
// set, travels as the x-api-key header: the console-issued maker or taker
// API key a relayer running with a console resolves to the account.
async function httpRpc(rpcUrl, method, params, apiKey) {
    const headers = {"content-type": "application/json"};
    if (apiKey) headers["x-api-key"] = String(apiKey);
    const r = await axios.post(
        rpcUrl,
        {jsonrpc: "2.0", id: 1, method, params},
        {headers, timeout: 15000}
    );
    if (r.data && r.data.error) {
        const e = r.data.error;
        const err = new Error(`${method} rpc error: ${e.message || JSON.stringify(e)}`);
        if (e.data !== undefined) err.data = e.data;
        throw err;
    }
    return r.data ? r.data.result : undefined;
}

function now() {
    const d = new Date();
    const hh = String(d.getUTCHours()).padStart(2, "0");
    const mm = String(d.getUTCMinutes()).padStart(2, "0");
    const ss = String(d.getUTCSeconds()).padStart(2, "0");
    const ms = String(d.getUTCMilliseconds()).padStart(3, "0");
    return `${hh}:${mm}:${ss}.${ms}`;
}

function log(...args) {
    console.log(`[${now()}]`, ...args);
}

function hexNum(n) {
    return "0x" + BigInt(n).toString(16);
}

function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

module.exports = {
    httpRpc,
    now,
    log,
    hexNum,
    sleep,
};
