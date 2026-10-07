const ethers = require("ethers");
const cfg = require("./config");
const {routerIface, takerIface, erc20Iface, decodeRevert} = require("./abi");
const {httpRpc, log, sleep} = require("./utils");

// taker: exercises the relayer's whole point — the taker is a PLAIN wallet.
// There is no quote stream, no stateOverride plumbing and no bundle
// submission (all deliberately absent from the relayer):
//
//   1. price with a standard eth_call against the relayer — the quote overlay
//      is applied server-side, so router.quote returns the maker's live price
//      with zero extra parameters (a vanilla node reverts NoPrice/StaleUpdate
//      on the same call; set COMPARE_RPC to print that counterfactual);
//   2. fill: the router is push-payment (IPropAMM). With TAKER_CONTRACT set
//      (contracts/ExamplePammTaker.sol) the fill is ONE tx: the contract
//      transferFroms TOKEN_IN straight into the pool and calls pool.swap, so
//      nothing ever rests on the pool. Without it, a plain wallet first
//      transfers amountIn to the router with an ordinary tx (sent to
//      PUBLIC_RPC, waited to land), then sends router.swap — and between the
//      two the pushed balance is claimable by anyone who calls swap first
//      (fine for test amounts, not for real size). Either way the fill tx
//      goes to the relayer with a standard eth_sendRawTransaction; it
//      simulates it on the overlay, records its SLOAD read-set, intersects
//      with quote write-sets, and ships an atomic [quote txs..., fill] bundle
//      to its builders; on any failure path it falls back to the txpool;
//   3. watch for landing: while the bundle is with the builders the tx is
//      invisible (eth_getTransactionByHash returns null, it is NOT in the
//      pool); it appears when a builder lands the bundle. We poll receipts
//      until it lands or TAKER_WATCH_BLOCKS passes.
//
// CAUTION (live mode): if the tx falls back to the public txpool (relayer not
// ready, no collision, all builders down), it executes WITHOUT the quote state
// and the swap reverts NoPrice on chain — the taker pays that gas. That is the
// documented fallback behavior (never worse than a vanilla node, which would
// do exactly the same). Keep TAKER_DRY_RUN=1 until pamm_status looks healthy.

function assertConfig() {
    const miss = [];
    if (!cfg.TAKER_PK) miss.push("TAKER_PK");
    if (cfg.ROUTER === "0x0000000000000000000000000000000000000000") miss.push("ROUTER");
    if (cfg.TOKEN_OUT === "0x0000000000000000000000000000000000000000") miss.push("TOKEN_OUT");
    if (miss.length) {
        throw new Error(`missing config: ${miss.join(", ")} (set in .env)`);
    }
}

function revertMsg(e) {
    const decoded = decodeRevert(e.data);
    return decoded ? `${decoded}` : e.message || String(e);
}

// Calls against the relayer carry the taker's console-issued API key
// (x-api-key): with a console configured, that is what unlocks the restricted
// makers that ticked us (public makers are visible without it).
const relayerRpc = (method, params) => httpRpc(cfg.RELAYER_RPC, method, params, cfg.TAKER_API_KEY);

// eth_call on `rpc`; returns amountOut (BigInt) or throws with a decoded
// revert reason. No stateOverride and no blockOverride: on the relayer the
// overlay is already in the call state, and the call runs at the tip whose
// number is always <= the quote's maxBlockNumber.
async function simulateQuote(rpc) {
    const data = routerIface.encodeFunctionData("quote", [
        cfg.TOKEN_IN,
        cfg.TOKEN_OUT,
        cfg.TAKER_AMOUNT_IN,
    ]);
    const apiKey = rpc === cfg.RELAYER_RPC ? cfg.TAKER_API_KEY : "";
    const result = await httpRpc(rpc, "eth_call", [{to: cfg.ROUTER, data}, "latest"], apiKey);
    if (!result || result === "0x") throw new Error("empty result");
    const [amountOut] = routerIface.decodeFunctionResult("quote", result);
    return BigInt(amountOut.toString());
}

// One-shot preflight on the taker wallet: TOKEN_IN balance, and the allowance
// to TAKER_CONTRACT when the one-tx path is used. Warnings only. Whether the
// pool can actually fill is not checked here: the poll loop's eth_call of
// router.quote through the relayer is that check (it reverts NoPrice /
// NoQuote when nothing is live).
async function preflight(taker) {
    const call = async (to, data) => httpRpc(cfg.PUBLIC_RPC, "eth_call", [{to, data}, "latest"]);
    try {
        const [bal] = erc20Iface.decodeFunctionResult(
            "balanceOf",
            await call(cfg.TOKEN_IN, erc20Iface.encodeFunctionData("balanceOf", [taker]))
        );
        if (BigInt(bal.toString()) < BigInt(cfg.TAKER_AMOUNT_IN)) {
            log(`WARN: taker TOKEN_IN balance ${bal} < amountIn ${cfg.TAKER_AMOUNT_IN}`);
        }
        if (cfg.TAKER_CONTRACT) {
            const [allowance] = erc20Iface.decodeFunctionResult(
                "allowance",
                await call(cfg.TOKEN_IN, erc20Iface.encodeFunctionData("allowance", [taker, cfg.TAKER_CONTRACT]))
            );
            if (BigInt(allowance.toString()) < BigInt(cfg.TAKER_AMOUNT_IN)) {
                log(`WARN: taker allowance to TAKER_CONTRACT ${allowance} < amountIn ${cfg.TAKER_AMOUNT_IN} (approve first)`);
            }
        }
    } catch (e) {
        log(`preflight checks skipped: ${e.message || e}`);
    }
}

async function pammStatus() {
    try {
        return await relayerRpc("pamm_status", []);
    } catch (e) {
        return null;
    }
}

// Wait for a plain tx sent through PUBLIC_RPC to land; returns its status.
async function waitReceipt(txHash, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const receipt = await httpRpc(cfg.PUBLIC_RPC, "eth_getTransactionReceipt", [txHash]);
        if (receipt) return receipt.status === "0x1";
        if (Date.now() > deadline) throw new Error(`tx ${txHash} not mined within ${timeoutMs}ms`);
        await sleep(1000);
    }
}

async function signTx(wallet, nonce, to, data, gasLimit) {
    return wallet.signTransaction({
        chainId: cfg.CHAIN_ID,
        type: 0,
        to,
        value: 0,
        nonce,
        gasPrice: ethers.BigNumber.from(cfg.TAKER_GAS_PRICE),
        gasLimit: ethers.BigNumber.from(gasLimit),
        data,
    });
}

async function sendSwap(wallet, amountOut) {
    const nonceHex = await httpRpc(cfg.PUBLIC_RPC, "eth_getTransactionCount", [
        wallet.address,
        "pending",
    ]);
    const nonce = parseInt(nonceHex, 16);

    const configuredMinOut = BigInt(cfg.TAKER_MIN_OUT);
    const slippageBps = BigInt(cfg.TAKER_SLIPPAGE_BPS);
    const minOut =
        configuredMinOut > 0n
            ? configuredMinOut
            : (amountOut * (10000n - slippageBps)) / 10000n;

    if (cfg.TAKER_CONTRACT) {
        // One tx: ExamplePammTaker.swap(pool, ...) pushes and swaps atomically.
        const raw = await signTx(
            wallet,
            nonce,
            cfg.TAKER_CONTRACT,
            takerIface.encodeFunctionData("swap", [
                cfg.ROUTER,
                cfg.TOKEN_IN,
                cfg.TOKEN_OUT,
                cfg.TAKER_AMOUNT_IN,
                minOut.toString(),
                wallet.address,
                0,
            ]),
            cfg.TAKER_GAS_LIMIT
        );
        const hash = ethers.utils.keccak256(raw);
        if (cfg.TAKER_DRY_RUN) {
            log(`[dry-run] NOT sent: taker-contract swap=${hash} nonce=${nonce} amountOut=${amountOut} minOut=${minOut}`);
            return null;
        }
        const returned = await relayerRpc("eth_sendRawTransaction", [raw]);
        log(`swap sent via ${cfg.TAKER_CONTRACT}: hash=${returned} nonce=${nonce} amountOut=${amountOut} minOut=${minOut}`);
        return hash;
    }

    // Step 1 (push): TOKEN_IN.transfer(router, amountIn) — an ordinary tx via
    // PUBLIC_RPC that must land before the swap can consume it.
    const pushRaw = await signTx(
        wallet,
        nonce,
        cfg.TOKEN_IN,
        erc20Iface.encodeFunctionData("transfer", [cfg.ROUTER, cfg.TAKER_AMOUNT_IN]),
        80000
    );
    const pushHash = ethers.utils.keccak256(pushRaw);

    // Step 2 (swap): swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient,
    // maxBlockNumber). maxBlockNumber 0 skips the caller deadline — the lane
    // read inside already enforces the maker's deadline.
    const swapRaw = await signTx(
        wallet,
        nonce + 1,
        cfg.ROUTER,
        routerIface.encodeFunctionData("swap", [
            cfg.TOKEN_IN,
            cfg.TOKEN_OUT,
            cfg.TAKER_AMOUNT_IN,
            minOut.toString(),
            wallet.address,
            0,
        ]),
        cfg.TAKER_GAS_LIMIT
    );
    const swapHash = ethers.utils.keccak256(swapRaw);

    if (cfg.TAKER_DRY_RUN) {
        log(`[dry-run] NOT sent: push=${pushHash} swap=${swapHash} nonce=${nonce},${nonce + 1} amountOut=${amountOut} minOut=${minOut}`);
        return null;
    }

    await httpRpc(cfg.PUBLIC_RPC, "eth_sendRawTransaction", [pushRaw]);
    log(`push sent: hash=${pushHash} nonce=${nonce} amountIn=${cfg.TAKER_AMOUNT_IN} -> router, waiting to land...`);
    if (!(await waitReceipt(pushHash, 90000))) {
        throw new Error(`push tx ${pushHash} reverted; swap not sent`);
    }
    log("push landed");

    // A standard raw submission; the relayer does the matching internally.
    const returned = await relayerRpc("eth_sendRawTransaction", [swapRaw]);
    log(`swap sent: hash=${returned} nonce=${nonce + 1} amountOut=${amountOut} minOut=${minOut}`);
    return swapHash;
}

// Poll until the tx lands or watchBlocks pass. While the bundle is with the
// builders the tx is invisible (not in pool, hash lookup null) — that state is
// logged explicitly so it does not read as a lost tx.
async function watchLanding(txHash) {
    const startHex = await httpRpc(cfg.PUBLIC_RPC, "eth_blockNumber", []);
    const start = parseInt(startHex, 16);
    let lastSeen = "";
    for (;;) {
        await sleep(1500);
        const receipt = await httpRpc(cfg.PUBLIC_RPC, "eth_getTransactionReceipt", [txHash]);
        if (receipt) {
            const ok = receipt.status === "0x1";
            log(`LANDED block=${parseInt(receipt.blockNumber, 16)} status=${ok ? "success" : "REVERTED"} gasUsed=${parseInt(receipt.gasUsed, 16)}`);
            if (!ok) {
                log("  reverted on chain: most likely landed via txpool fallback without the quote (NoPrice), the resting quote ticked past minOut (InsufficientOutput), or someone consumed the pushed balance first (InsufficientInput)");
            }
            return ok;
        }
        const head = parseInt(await httpRpc(cfg.PUBLIC_RPC, "eth_blockNumber", []), 16);
        const pooled = await httpRpc(cfg.PUBLIC_RPC, "eth_getTransactionByHash", [txHash]);
        const state = pooled ? "in txpool (fallback path)" : "invisible (bundled with builders, or dropped)";
        if (state !== lastSeen) {
            log(`waiting: head=${head} tx ${state}`);
            lastSeen = state;
        }
        if (head - start > cfg.TAKER_WATCH_BLOCKS) {
            log(`gave up after ${cfg.TAKER_WATCH_BLOCKS} blocks: bundle expired unlanded (or builders dropped it); the relayer prunes it at the quote deadline, after which a resubmit re-runs the pipeline`);
            return false;
        }
    }
}

async function main() {
    assertConfig();

    const wallet = new ethers.Wallet(cfg.TAKER_PK);
    log("taker address =", wallet.address);
    log("router        =", cfg.ROUTER);
    log("pair          =", `${cfg.TOKEN_IN} -> ${cfg.TOKEN_OUT}`);
    log("amountIn      =", cfg.TAKER_AMOUNT_IN);
    log("minOut        =", BigInt(cfg.TAKER_MIN_OUT) > 0n ? cfg.TAKER_MIN_OUT : `sim - ${cfg.TAKER_SLIPPAGE_BPS}bps`);
    log("relayer rpc   =", cfg.RELAYER_RPC);
    log("fill via      =", cfg.TAKER_CONTRACT ? `${cfg.TAKER_CONTRACT} (one tx)` : "wallet (push tx, then swap tx)");
    log("dryRun        =", cfg.TAKER_DRY_RUN ? "on (no tx sent)" : "off");
    log("taker key     =", cfg.TAKER_API_KEY ? "set" : "none (public makers only)");

    await preflight(wallet.address);

    const takeThreshold = BigInt(cfg.TAKER_TAKE_THRESHOLD);
    let lastQuoteKey = "";

    for (;;) {
        // Gate on relayer health first: not ready / empty overlay means a live
        // send would fall back to the txpool and revert NoPrice on chain.
        const st = await pammStatus();
        if (!st || !st.ready || !(st.overlaySlots > 0)) {
            log(`relayer not matchable (ready=${st ? st.ready : "?"} overlaySlots=${st ? st.overlaySlots : "?"}), waiting for maker quotes...`);
            await sleep(cfg.TAKER_POLL_MS);
            continue;
        }

        let amountOut;
        try {
            amountOut = await simulateQuote(cfg.RELAYER_RPC);
        } catch (e) {
            log(`quote sim failed on relayer: ${revertMsg(e)}`);
            await sleep(cfg.TAKER_POLL_MS);
            continue;
        }

        let compare = "";
        if (cfg.COMPARE_RPC) {
            try {
                compare = ` | vanilla=${await simulateQuote(cfg.COMPARE_RPC)}`;
            } catch (e) {
                compare = ` | vanilla reverts ${revertMsg(e)}`; // expected: NoPrice/StaleUpdate
            }
        }
        log(`overlay quote: amountOut=${amountOut} (quotes=${st.quotes} overlaySlots=${st.overlaySlots})${compare}`);

        if (amountOut < takeThreshold) {
            log(`  skip: amountOut < threshold(${takeThreshold})`);
            await sleep(cfg.TAKER_POLL_MS);
            continue;
        }

        const quoteKey = `${amountOut}`;
        if (cfg.TAKER_DEDUP && quoteKey === lastQuoteKey) {
            await sleep(cfg.TAKER_POLL_MS);
            continue;
        }
        lastQuoteKey = quoteKey;

        let txHash = null;
        try {
            txHash = await sendSwap(wallet, amountOut);
        } catch (e) {
            log(`swap send failed: ${revertMsg(e)}`);
        }

        if (txHash) {
            await watchLanding(txHash);
            if (!cfg.TAKER_LOOP) {
                log("fired once, exiting (set TAKER_LOOP=1 to keep going)");
                return;
            }
            lastQuoteKey = ""; // re-arm after a live attempt
        }
        await sleep(cfg.TAKER_POLL_MS);
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
