const ethers = require("ethers");

// Lane packing shared by maker.js (encode) and status.js (decode). Must match
// ExamplePammRouter / PrioUpdateRegistry:
//
//   laneIndex      = uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)))
//   lane base slot = keccak256(abi.encode(LANE_NAMESPACE, target, laneIndex))
//                    (target = router; the namespace domain-separates lane
//                    storage from everything else in the registry)
//   slot 0 word    = seq(48) | maxBlockNumber(48) | price(160)
//
// The registry writes the direct-path seq into the top 48 bits on every
// update, so the packed word must leave them clear (SeqBitsNotClear
// otherwise); the router masks them out and validates maxBlockNumber
// (inclusive) on read. Mirrors ExamplePammRouter.packQuote.

const PRICE_BITS = 160n;
const PRICE_MASK = (1n << PRICE_BITS) - 1n;
const MAXBLOCK_SHIFT = PRICE_BITS; // 160
const MAXBLOCK_MASK = (1n << 48n) - 1n;
const SEQ_SHIFT = 208n;
const DATA_MASK = (1n << SEQ_SHIFT) - 1n;

// Mirrors the registry's LANE_NAMESPACE = keccak256("PrioUpdateRegistryV2.lane.v1").
const LANE_NAMESPACE = ethers.utils.keccak256(
    ethers.utils.toUtf8Bytes("PrioUpdateRegistryV2.lane.v1")
);

// Lane index for (tokenIn -> tokenOut); must match router.laneFor. Each
// direction is its own lane.
function laneFor(tokenIn, tokenOut) {
    return ethers.utils.solidityKeccak256(["address", "address"], [tokenIn, tokenOut]);
}

// The storage slot the maker's updateState writes (and therefore the exact
// slot that shows up in the relayer's overlay under the ORACLE account).
function laneBaseSlot(target, laneIndex) {
    return ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
            ["bytes32", "address", "uint256"],
            [LANE_NAMESPACE, target, laneIndex]
        )
    );
}

// slots[0] = maxBlockNumber(48) << 160 | price(160). price is 1e18-scaled
// "how much tokenOut 1 tokenIn buys"; maxBlockNumber is the inclusive
// freshness deadline the router validates on read.
function packQuote(price, maxBlockNumber) {
    const p = BigInt(price);
    const m = BigInt(maxBlockNumber);
    if (p <= 0n || p > PRICE_MASK) {
        throw new Error(`price ${p} out of range (1..2^160-1)`);
    }
    if (m > MAXBLOCK_MASK) {
        throw new Error(`maxBlockNumber ${m} does not fit in 48 bits`);
    }
    return ((m << MAXBLOCK_SHIFT) | p).toString();
}

// Decode the lane's slot-0 word back into its fields.
function decodeLaneWord(wordHex) {
    const v = BigInt(wordHex);
    const data = v & DATA_MASK;
    return {
        seq: (v >> SEQ_SHIFT).toString(),
        maxBlockNumber: Number(data >> MAXBLOCK_SHIFT),
        price: (data & PRICE_MASK).toString(),
    };
}

module.exports = {
    laneFor,
    laneBaseSlot,
    packQuote,
    decodeLaneWord,
};
