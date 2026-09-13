const cfg = require("./config");
const {httpRpc, log} = require("./utils");
const {laneFor, laneBaseSlot, decodeLaneWord} = require("./lane");

// status: one-shot health + overlay snapshot against the relayer.
//   - pamm_status: ready flag, quote/overlay counts, builders, pending bundles;
//   - pamm_getPammStateOverrides: the exact account -> slot -> value view that
//     eth_call simulates on;
//   - when ORACLE/ROUTER/pair are configured, locates OUR lane's storage slot
//     inside the overlay and decodes the packed word back into
//     (seq, maxBlockNumber, price) — proving the maker's quote round-tripped
//     into the pricing overlay intact.

async function main() {
    log("relayer rpc =", cfg.RELAYER_RPC);

    const st = await httpRpc(cfg.RELAYER_RPC, "pamm_status", []);
    log("pamm_status:", JSON.stringify(st, null, 2));

    if (st.directory) {
        log(`directory: console=${st.directory.console} loaded=${st.directory.loaded} makers=${st.directory.makers} takers=${st.directory.takers} keys=${st.directory.keys}${st.directory.lastError ? ` lastError=${st.directory.lastError}` : ""}`);
        if (!cfg.TAKER_API_KEY) log("no TAKER_API_KEY: the overlay snapshot below is the anonymous view (public makers only)");
    }

    // The snapshot is the caller's view: with a console configured, the taker
    // key adds the restricted makers that ticked that taker.
    let ov;
    try {
        ov = await httpRpc(cfg.RELAYER_RPC, "pamm_getPammStateOverrides", [], cfg.TAKER_API_KEY);
    } catch (e) {
        log(`pamm_getPammStateOverrides failed: ${e.message || e} (relayer not ready?)`);
        return;
    }

    const accounts = Object.keys(ov.overrides || {});
    log(`overlay @ block ${ov.blockNumber}: ${accounts.length} account(s)`);
    for (const acct of accounts) {
        const slots = ov.overrides[acct];
        log(`  ${acct}: ${Object.keys(slots).length} slot(s)`);
    }

    if (
        cfg.ORACLE === "0x0000000000000000000000000000000000000000" ||
        cfg.ROUTER === "0x0000000000000000000000000000000000000000"
    ) {
        return; // no pair configured, snapshot only
    }

    // Find our lane's slot under the oracle account (JSON keys may differ in
    // case; normalize).
    const lane = laneFor(cfg.TOKEN_IN, cfg.TOKEN_OUT);
    const slotKey = laneBaseSlot(cfg.ROUTER, lane).toLowerCase();
    const oracleKey = accounts.find((a) => a.toLowerCase() === cfg.ORACLE.toLowerCase());
    const slots = oracleKey ? ov.overrides[oracleKey] : null;
    const wordKey = slots && Object.keys(slots).find((s) => s.toLowerCase() === slotKey);
    if (!wordKey) {
        log(`our lane slot ${slotKey} is NOT in the overlay (no live quote for ${cfg.TOKEN_IN} -> ${cfg.TOKEN_OUT})`);
        return;
    }
    const word = slots[wordKey];
    const decoded = decodeLaneWord(word);
    log(`our lane slot ${slotKey}:`);
    log(`  raw            = ${word}`);
    log(`  seq            = ${decoded.seq}`);
    log(`  maxBlockNumber = ${decoded.maxBlockNumber} (head ${ov.blockNumber}, ${decoded.maxBlockNumber - ov.blockNumber} blocks left)`);
    log(`  price          = ${decoded.price} (1e18-scaled tokenOut per tokenIn)`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
