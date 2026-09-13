const WebSocket = require("ws");

// A minimal JSON-RPC over WebSocket client, compatible with go-ethereum's rpc
// server. Supports both plain calls (many concurrent calls on one connection)
// and pamm_subscribe notifications.
class WsRpc {
    // apiKey, when set, is sent as the x-api-key header on the upgrade
    // request; the relayer captures it once per connection and resolves it
    // against its current permission snapshot on every call.
    constructor(url, apiKey) {
        this.url = url;
        this.apiKey = apiKey ? String(apiKey) : "";
        this.nextId = 0;
        this.pending = new Map(); // id -> { resolve, reject }
        this.subs = new Map(); // subscription id -> handler
        this.ws = null;
    }

    connect() {
        return new Promise((resolve, reject) => {
            const headers = this.apiKey ? {"x-api-key": this.apiKey} : {};
            this.ws = new WebSocket(this.url, {handshakeTimeout: 10000, headers});
            const onErr = (e) => reject(e);
            this.ws.once("open", () => {
                this.ws.removeListener("error", onErr);
                resolve();
            });
            this.ws.once("error", onErr);
            this.ws.on("message", (data) => this._onMessage(data.toString()));
            this.ws.on("close", () => {
                for (const [, p] of this.pending) p.reject(new Error("ws closed"));
                this.pending.clear();
                this.subs.clear();
            });
        });
    }

    _onMessage(raw) {
        let msg;
        try {
            msg = JSON.parse(raw);
        } catch {
            return;
        }
        // go-ethereum subscription notifications: {method: "<ns>_subscription", params: {subscription, result}}
        if (msg.method && msg.params && msg.params.subscription && this.subs.has(msg.params.subscription)) {
            this.subs.get(msg.params.subscription)(msg.params.result);
            return;
        }
        if (msg.id !== undefined && this.pending.has(msg.id)) {
            const p = this.pending.get(msg.id);
            this.pending.delete(msg.id);
            if (msg.error) {
                p.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
            } else {
                p.resolve(msg.result);
            }
        }
    }

    call(method, params = []) {
        const id = ++this.nextId;
        const payload = JSON.stringify({jsonrpc: "2.0", id, method, params});
        return new Promise((resolve, reject) => {
            this.pending.set(id, {resolve, reject});
            this.ws.send(payload, (err) => {
                if (err) {
                    this.pending.delete(id);
                    reject(err);
                }
            });
        });
    }

    // subscribe issues namespace_subscribe and routes later notifications to
    // onUpdate. Returns the subscription id; call unsubscribe(id) to stop.
    async subscribe(namespace, name, params, onUpdate) {
        const args = [name, ...(params || [])];
        const subId = await this.call(`${namespace}_subscribe`, args);
        this.subs.set(subId, onUpdate);
        return subId;
    }

    async unsubscribe(namespace, subId) {
        this.subs.delete(subId);
        return this.call(`${namespace}_unsubscribe`, [subId]);
    }

    close() {
        if (this.ws) this.ws.close();
    }
}

module.exports = {WsRpc};
