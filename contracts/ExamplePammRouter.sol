// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPropAMM} from "./IPropAMM.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal read/write interface for the PrioUpdateRegistry (direct updater
///      path). Note that getState reads the lane keyed by msg.sender — when this
///      contract calls it, msg.sender = this contract, so it reads its own
///      "target = router" lane. The registry stores raw words and a per-lane
///      48-bit sequence number in the top bits of slot 0; it does NOT validate
///      freshness — that is this contract's job on read.
interface IPrioUpdateRegistry {
    function getState(uint256 laneIndex, uint256 count) external view returns (uint256[] memory slots);
    function addUpdater(address updater) external;
    function removeUpdater(address updater) external;
    function isUpdater(address target, address updater) external view returns (bool);
    function setDecoder(uint256 laneIndex, address decoder) external;
}

/// @dev The one call this contract makes on a SignedSeqDecoder (BAP-710 §4.2.3).
interface ISignerRegistry {
    function setSigner(address signer) external;
}

/// @title ExamplePammRouter
/// @notice Minimal PropAMM pool whose prices come from the PrioUpdateRegistry.
///         It implements {IPropAMM}, so wallets, aggregators and solvers price
///         and fill it like any other pool. (The name is historical: in
///         BAP-710 terms this contract is the *pool*, the registry *target*
///         and the "router address" a maker registers in the console; a
///         "router" in BAP-710 is the contract that pushes `tokenIn` to the
///         pool and calls `swap`, such as {ExamplePammTaker}.)
///
///         Registry model (PrioUpdateRegistry, direct updater path):
///           - This contract is the `target` in the registry. registry.getState reads the lane keyed by
///             msg.sender, so when this contract calls it, it reads its own "target = router" lane.
///           - The maker is an updater authorized by this contract: after deploy, the owner calls addMaker(maker),
///             and this contract (as itself) calls registry.addUpdater(maker), writing isUpdater[router][maker] = true.
///           - To quote, the maker calls
///               registry.updateState(router, laneFor(tokenIn, tokenOut), [packQuote(price, maxBlockNumber)], seq)
///             with a strictly increasing uint48 `seq` (unix milliseconds work well and survive restarts).
///             The registry packs `seq` into the top 48 bits of slot 0 and rejects stale or replayed
///             direct updates (StaleSeq); the packed word must therefore leave those bits clear, which
///             packQuote guarantees. The relayer simulates this tx to capture the registry's storage
///             diff and prices takers on the resulting overlay.
///           - Freshness is enforced by THIS contract on read: the packed word carries an inclusive
///             maxBlockNumber, and reads past it revert StaleUpdate(). The registry stores the word
///             verbatim and checks nothing against the block header.
///
///         Lane layout (one updater-managed word, slot 0):
///           bits [208, 255]  seq            — written by the registry on every direct update; masked out here
///           bits [160, 207]  maxBlockNumber — uint48, inclusive freshness deadline, validated on read
///           bits [0, 159]    price          — 1e18-scaled "how much tokenOut 1 tokenIn buys"
///
///         Payment model: push-payment, as {IPropAMM.swap} specifies. The caller
///         transfers `amountIn` of `tokenIn` to this contract BEFORE calling
///         `swap`; `swap` checks the pushed balance and pays out `tokenOut`
///         from this contract's own inventory. Inventory is tracked in
///         `reserves[token]`: whatever the contract holds above its reserve is
///         what the caller pushed in for the current swap. After a swap both
///         tokens are re-synced to the actual balances, so any excess pushed
///         simply joins the inventory.
///
///         Funding: transfer `tokenOut` to this contract, then call `sync(token)`
///         so the top-up is booked as inventory. Until it is synced, a top-up is
///         indistinguishable from a pushed payment and the next `swap` of that
///         token would consume it as the caller's `amountIn`.
///
///         Atomicity: a contract caller (an aggregator router, a solver, or
///         {ExamplePammTaker}) pushes and swaps in one transaction. A plain EOA
///         needs two transactions (transfer, then swap); between them the
///         pushed balance is claimable by anyone who calls `swap` first. The
///         e2e taker's two-tx fallback does exactly that with test amounts; do
///         not do it with real size.
///
///         Reentrancy: `swap` and `sync` share a transient lock (BAP-710 §8.1).
///         Without it, a `tokenOut` with a transfer hook could re-enter `swap`
///         before the payment is booked and spend the same pushed `tokenIn`
///         twice.
contract ExamplePammRouter is IPropAMM {
    address public owner;
    IPrioUpdateRegistry public immutable oracle;

    /// @dev Mirrors the registry's PUR_SEQ_SHIFT / PUR_SLOT0_DATA_MASK: the top 48 bits of an
    ///      updater-managed slot 0 belong to the registry's sequence number.
    uint256 internal constant SEQ_SHIFT = 208;
    uint256 internal constant SLOT0_DATA_MASK = (1 << 208) - 1;

    /// @dev Layout of the 208 data bits: maxBlockNumber above the price.
    uint256 internal constant MAXBLOCK_SHIFT = 160;
    uint256 internal constant MAX_BLOCK_MASK = (1 << 48) - 1;
    uint256 internal constant PRICE_MASK = (1 << 160) - 1;

    /// @notice Price is scaled by 1e18, meaning "how much tokenOut 1 tokenIn buys".
    uint256 internal constant PRICE_SCALE = 1e18;

    /// @dev Pairs registered through addPair, each once with token0 < token1,
    ///      for off-chain discovery (getPairs); pricing itself is per-lane and
    ///      needs no registration.
    TokenPair[] internal _pairs;
    mapping(bytes32 => bool) internal _pairKnown;

    /// @notice Inventory this contract considers its own, per token. Balance above it is a pushed payment.
    mapping(address => uint256) public reserves;

    error NotOwner();
    error NoPrice();
    error SameToken();
    error PairExists();
    error ZeroAmount();
    error InsufficientInput(uint256 required, uint256 pushed);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error SwapExpired(uint256 blockNumber, uint256 maxBlockNumber);
    error StaleUpdate();
    error QuoteOverflow();
    error TransferFailed();
    error Reentrancy();

    /// @dev Held for the duration of `swap` / `sync`; transient, so it costs no storage write.
    bool private transient _locked;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _oracle) {
        owner = msg.sender;
        oracle = IPrioUpdateRegistry(_oracle);
    }

    /*
     * Maker authorization (this contract is the registry's target and authorizes the maker as an updater)
     */

    /// @notice Authorize `maker` to write quote lanes on behalf of this contract. Equivalent to registry.addUpdater(maker) (msg.sender = router).
    function addMaker(address maker) external onlyOwner {
        oracle.addUpdater(maker);
    }

    /// @notice Revoke `maker`'s write permission. Equivalent to registry.removeUpdater(maker).
    function removeMaker(address maker) external onlyOwner {
        oracle.removeUpdater(maker);
    }

    /// @notice Check whether a maker is authorized (i.e. registry.isUpdater[router][maker]).
    function isMaker(address maker) external view returns (bool) {
        return oracle.isUpdater(address(this), maker);
    }

    /*
     * Signed updates (optional; BAP-710 §4.2.3). Both calls must come from the target itself, hence
     * these owner-gated wrappers.
     */

    /// @notice PERMANENTLY binds `decoder` (e.g. SignedSeqDecoder) to the (tokenIn -> tokenOut) lane. From
    ///         then on that lane takes only relayed `updateStateWithDecoder` writes validated by the decoder;
    ///         `updateState` from makers reverts DecoderBoundLane. The read path is unchanged, since
    ///         SignedSeqDecoder stores the same slot-0 layout (seq in the top 48 bits).
    function bindDecoder(address tokenIn, address tokenOut, address decoder) external onlyOwner {
        oracle.setDecoder(laneFor(tokenIn, tokenOut), decoder);
    }

    /// @notice Registers the key (EOA, or ERC-1271 contract) whose EIP-712 signatures `decoder` accepts for
    ///         every lane of this contract. Zero disables signed updates; a new key invalidates every unlanded
    ///         payload signed by the old one.
    function setSigner(address decoder, address signer) external onlyOwner {
        ISignerRegistry(decoder).setSigner(signer);
    }

    /*
     * Pair discovery (advisory; consumed by off-chain tooling such as the
     * relayer's price ladder, never by the swap path)
     */

    /// @notice Register a supported pair for getPairs, in canonical order (token0 < token1).
    function addPair(address tokenA, address tokenB) external onlyOwner {
        if (tokenA == tokenB) revert SameToken();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 key = keccak256(abi.encodePacked(token0, token1));
        if (_pairKnown[key]) revert PairExists();
        _pairKnown[key] = true;
        _pairs.push(TokenPair({token0: token0, token1: token1}));
    }

    /*
     * Pricing
     */

    /// @notice The lane index for a (tokenIn -> tokenOut) pair. The maker (write) and this contract (read) must use the same encoding.
    function laneFor(address tokenIn, address tokenOut) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenIn, tokenOut)));
    }

    /// @notice Packs a quote into the lane word the maker submits via registry.updateState.
    /// @dev The top 48 bits stay clear for the registry's seq (a word with them set is rejected by the
    ///      registry as SeqBitsNotClear). Off-chain makers mirror this packing.
    /// @param price 1e18-scaled tokenOut per tokenIn; must fit in 160 bits and be non-zero.
    /// @param maxBlockNumber Inclusive last block the quote may price or fill in; must fit in 48 bits.
    function packQuote(uint256 price, uint256 maxBlockNumber) public pure returns (uint256 word) {
        if (price == 0 || price > PRICE_MASK || maxBlockNumber > MAX_BLOCK_MASK) revert QuoteOverflow();
        word = (maxBlockNumber << MAXBLOCK_SHIFT) | price;
    }

    /// @notice Raw view of the lane for a pair: no freshness validation, zeros for a never-written lane.
    /// @dev For debugging and off-chain tooling; on-chain consumers use quote/swap, which validate.
    function readQuote(address tokenIn, address tokenOut)
        external
        view
        returns (uint256 price, uint256 maxBlockNumber, uint256 seq)
    {
        uint256 word = _laneWord(tokenIn, tokenOut);
        price = word & PRICE_MASK;
        maxBlockNumber = (word & SLOT0_DATA_MASK) >> MAXBLOCK_SHIFT;
        seq = word >> SEQ_SHIFT;
    }

    /// @dev Reads the lane's slot 0 from the registry (msg.sender = this contract, so it reads the
    ///      "target = router" lane). The registry returns zero for a never-written lane and never
    ///      reverts on this read.
    function _laneWord(address tokenIn, address tokenOut) internal view returns (uint256 word) {
        uint256[] memory slots = oracle.getState(laneFor(tokenIn, tokenOut), 1);
        word = slots[0];
    }

    /// @dev Reads the price and enforces freshness. The registry stores the word verbatim (plus its
    ///      seq bits), so the maxBlockNumber packed by the maker is validated here, on read:
    ///      block.number <= maxBlockNumber (inclusive), past it the read reverts StaleUpdate().
    function _price(address tokenIn, address tokenOut) internal view returns (uint256 price) {
        uint256 data = _laneWord(tokenIn, tokenOut) & SLOT0_DATA_MASK;
        if (data == 0) revert NoPrice();
        if (block.number > data >> MAXBLOCK_SHIFT) revert StaleUpdate();
        price = data & PRICE_MASK;
        if (price == 0) revert NoPrice();
    }

    /*
     * IPropAMM
     */

    /// @inheritdoc IPropAMM
    function isActive(address tokenIn, address tokenOut) external view override returns (bool active) {
        uint256 data = _laneWord(tokenIn, tokenOut) & SLOT0_DATA_MASK;
        active = (data & PRICE_MASK) != 0 && block.number <= data >> MAXBLOCK_SHIFT;
    }

    /// @inheritdoc IPropAMM
    /// @dev Lanes are derived on the fly from `(tokenIn, tokenOut)`, so a pair
    ///      prices whether or not it is registered; getPairs only reports the
    ///      pairs the owner registered through addPair (each once, token0 <
    ///      token1). Register the pairs you quote so off-chain consumers can
    ///      discover them.
    function getPairs() external view override returns (TokenPair[] memory pairs) {
        pairs = _pairs;
    }

    /// @inheritdoc IPropAMM
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        amountOut = (amountIn * _price(tokenIn, tokenOut)) / PRICE_SCALE;
    }

    /// @inheritdoc IPropAMM
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 maxBlockNumber
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        // Caller deadline (BAP-710 §4.3: SHOULD be checked when no router enforces it). The lane read
        // below independently reverts StaleUpdate() past the maker's packed deadline;
        // `maxBlockNumber == 0` skips this check.
        if (maxBlockNumber != 0 && block.number > maxBlockNumber) {
            revert SwapExpired(block.number, maxBlockNumber);
        }

        amountOut = (amountIn * _price(tokenIn, tokenOut)) / PRICE_SCALE;

        // Push-payment: the caller already transferred `amountIn` of `tokenIn`
        // here. Whatever we hold above our booked reserve is that payment.
        uint256 pushed = _pushed(tokenIn);
        if (pushed < amountIn) revert InsufficientInput(amountIn, pushed);

        // Pay out `tokenOut` from our own inventory, measuring what was actually
        // delivered as a balance delta.
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        if (!IERC20(tokenOut).transfer(recipient, amountOut)) revert TransferFailed();
        amountOut = IERC20(tokenOut).balanceOf(recipient) - balanceBefore;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        // Book the payment (and any excess pushed) as inventory; record the payout.
        _sync(tokenIn);
        _sync(tokenOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Books this contract's whole `token` balance as inventory. Call it right after
    ///         transferring a top-up in; permissionless because it can only raise the reserve
    ///         to what the contract actually holds.
    function sync(address token) external nonReentrant {
        _sync(token);
    }

    function _sync(address token) internal {
        reserves[token] = IERC20(token).balanceOf(address(this));
    }

    /// @dev Balance above the booked reserve: the payment pushed in for the current swap.
    function _pushed(address token) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserve = reserves[token];
        return balance > reserve ? balance - reserve : 0;
    }

    /// @notice Withdraw inventory. To top up this contract, transfer the token to it and call `sync`.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        _sync(token);
    }
}
