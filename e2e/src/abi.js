const ethers = require("ethers");

// Only the methods used by the e2e suite are listed here. The two example
// contracts (sources in ../contracts and ../../contracts):
//   ORACLE = PrioUpdateRegistry. The maker targets the router and calls
//   updateState(router, laneIndex, [packQuote(price, maxBlockNumber)], seq)
//   to write its quote lane. The registry stores the word verbatim, packs the
//   strictly-increasing uint48 seq into the top 48 bits of slot 0 (StaleSeq /
//   SeqBitsNotClear otherwise), and validates NO freshness — that is the
//   router's job on read.
const ORACLE_ABI = [
    "function updateState(address target, uint256 laneIndex, uint256[] slots, uint48 seq)",
    "function getState(uint256 laneIndex, uint256 count) view returns (uint256[] slots)",
    "function addUpdater(address updater)",
    "function removeUpdater(address updater)",
    "function isUpdater(address target, address updater) view returns (bool)",
    "error NotAuthorized()",
    "error StaleSeq()",
    "error SeqBitsNotClear()",
    "error EmptySlots()",
    "error TooManySlots()",
];

// ExamplePammRouter: quote to price, swap to fill (both exact-input,
// push-payment per IPropAMM: the caller transfers amountIn of tokenIn to the
// router BEFORE calling swap; swap checks the balance pushed above the
// router's booked inventory and pays tokenOut from that inventory; funding is
// transfer + sync(token) on the contract, not something the e2e calls). Its
// lane slot 0 is
//   bits [208,255] : seq            (registry-written, masked out by the router)
//   bits [160,207] : maxBlockNumber (inclusive freshness deadline, validated on read)
//   bits [0,159]   : price          (1e18-scaled "tokenOut per 1 tokenIn")
// Reads past the deadline revert StaleUpdate(); swap enforces slippage
// on-chain (InsufficientOutput when amountOut < minAmountOut).
const ROUTER_ABI = [
    "function quote(address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256 amountOut)",
    "function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 maxBlockNumber) returns (uint256 amountOut)",
    "function laneFor(address tokenIn, address tokenOut) pure returns (uint256)",
    "function readQuote(address tokenIn, address tokenOut) view returns (uint256 price, uint256 maxBlockNumber, uint256 seq)",
    "function isActive(address tokenIn, address tokenOut) view returns (bool)",
    "function packQuote(uint256 price, uint256 maxBlockNumber) pure returns (uint256)",
    "function addMaker(address maker)",
    "function removeMaker(address maker)",
    "function isMaker(address maker) view returns (bool)",
    "function addPair(address tokenA, address tokenB)",
    "function getPairs() view returns (tuple(address token0, address token1)[] pairs)",
    "event Swapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient)",
    "error NoPrice()",
    "error ZeroAmount()",
    "error InsufficientInput(uint256 required, uint256 pushed)",
    "error InsufficientOutput(uint256 amountOut, uint256 minAmountOut)",
    "error SwapExpired(uint256 blockNumber, uint256 maxBlockNumber)",
    "error StaleUpdate()",
    "error QuoteOverflow()",
    "error TransferFailed()",
    "error NotOwner()",
    "error SameToken()",
    "error PairExists()",
];

// ExamplePammTaker: one-tx push + swap against any IPropAMM pool. The caller
// approves it for tokenIn; it transferFroms straight into the pool and calls
// pool.swap, tokenOut going to recipient.
const TAKER_ABI = [
    "function swap(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 maxBlockNumber) returns (uint256 amountOut)",
    "event Filled(address indexed sender, address indexed pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient)",
    "function owner() view returns (address)",
    "error NotOwner()",
    "error TransferFailed()",
    "error InsufficientOutput(uint256 amountOut, uint256 minAmountOut)",
];

const ERC20_ABI = [
    "function transfer(address to, uint256 amount) returns (bool)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function balanceOf(address account) view returns (uint256)",
];

const oracleIface = new ethers.utils.Interface(ORACLE_ABI);
const routerIface = new ethers.utils.Interface(ROUTER_ABI);
const takerIface = new ethers.utils.Interface(TAKER_ABI);
const erc20Iface = new ethers.utils.Interface(ERC20_ABI);

// Best-effort decode of eth_call revert data against the router + oracle
// custom errors; returns e.g. "NoPrice()" / "InsufficientOutput(1,2)" or null.
function decodeRevert(data) {
    if (!data || typeof data !== "string" || data.length < 10) return null;
    for (const iface of [routerIface, oracleIface]) {
        for (const frag of Object.values(iface.errors)) {
            if (data.startsWith(iface.getSighash(frag))) {
                try {
                    const args = iface.decodeErrorResult(frag, data);
                    return `${frag.name}(${args.map((a) => a.toString()).join(",")})`;
                } catch {
                    return `${frag.name}(?)`;
                }
            }
        }
    }
    // Error(string)
    if (data.startsWith("0x08c379a0")) {
        try {
            const [reason] = ethers.utils.defaultAbiCoder.decode(
                ["string"],
                "0x" + data.slice(10)
            );
            return `Error(${JSON.stringify(reason)})`;
        } catch {
            /* fall through */
        }
    }
    return null;
}

module.exports = {
    ORACLE_ABI,
    ROUTER_ABI,
    TAKER_ABI,
    ERC20_ABI,
    oracleIface,
    routerIface,
    takerIface,
    erc20Iface,
    decodeRevert,
};
