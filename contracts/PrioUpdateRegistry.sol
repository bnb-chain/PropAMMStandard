// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Interface for a lane decoder that validates an opaque payload and returns the slot values to store.
/// @dev The registry calls decoders with `STATICCALL`, so a decoder cannot modify state, emit events,
/// transfer value, create contracts, or self-destruct. The static context extends to every call the
/// decoder makes, including calls back into the registry. A decoder may read registry state during
/// validation (for example the lane it is validating for, when the decoder is the target) and observes
/// the lane as it stands before this update is written; in a batch, earlier elements have already been
/// applied. A callback into a registry write entry point that reaches a storage write is a
/// static-context violation: it halts and consumes all gas forwarded to that call. A callback that
/// fails a registry precondition first returns that error normally, and an empty batch returns
/// normally; a nested `updateStateWithDecoder` runs the nested lane's decoder before halting. The
/// return value must be the canonical ABI encoding of exactly one `uint256[]` (head offset 32, no
/// trailing data); anything else is treated as malformed. A decoder should bind its payload to
/// `target` and `laneIndex` when those values are part of its authorization scheme.
interface IPrioUpdateDecoder {
    /// @notice Validates `aux` for `target` and `laneIndex` and returns the slot values to store.
    /// @dev Revert to reject the update. The returned array must have between 1 and 255 entries.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param aux The opaque payload interpreted by the decoder.
    /// @return slots The validated slot values to store.
    function validateAndUnpack(address target, uint256 laneIndex, bytes calldata aux)
        external
        view
        returns (uint256[] memory slots);
}

/// @dev Slot-0 layout on updater-managed lanes, importable by consumers and decoders.
uint256 constant PUR_SEQ_SHIFT = 208;
uint256 constant PUR_MAX_SEQ = (1 << 48) - 1;
uint256 constant PUR_SLOT0_DATA_MASK = (1 << 208) - 1;

/// @notice Stores raw per-target state written by authorized updaters or target-selected decoders.
/// @dev The registry does not interpret, generate, or validate freshness metadata. A target that requires
/// a timestamp, block number, or other validity marker must include it in its own slot layout and
/// validate it when reading. The one thing the registry does store and check is the direct path's
/// sequence number: every direct write carries a 48-bit `seq` that the registry stores in the top 48
/// bits of slot 0 and requires to increase, so on updater-managed lanes slot 0 holds 208 bits of data
/// and slots 1 and up are full width. Nothing on the direct path is checked against the block header.
/// Decoder-managed lanes are free-form: their decoder defines the layout and any sequencing, and may
/// read the lane via `getSlotOf` to do so. Writes only replace the supplied slot prefix.
contract PrioUpdateRegistry {
    event UpdaterAdded(address indexed target, address indexed updater);
    event UpdaterRemoved(address indexed target, address indexed updater);
    event DecoderSet(address indexed target, uint256 indexed laneIndex, address indexed decoder);
    event LaneReset(address indexed target, uint256 indexed laneIndex);

    /// @notice Thrown when `msg.sender` is not authorized to update state on behalf of `target`.
    error NotAuthorized();
    /// @notice Thrown when `slots` has length zero.
    error EmptySlots();
    /// @notice Thrown when `slots` has more than 255 entries.
    error TooManySlots();
    /// @notice Thrown when a read requests a slot outside the 255-slot lane region.
    error SlotIndexOutOfRange();
    /// @notice Thrown when a decoder returns an empty slot array.
    error DecoderReturnedNoSlots();
    /// @notice Thrown when a decoder has already been set for the lane.
    error DecoderAlreadySet();
    /// @notice Thrown when a decoder update is requested for a lane without a decoder.
    error DecoderNotSet();
    /// @notice Thrown when the updater path is used for a lane that has a decoder.
    error DecoderBoundLane();
    /// @notice Thrown when `decoder` is the zero address.
    error ZeroDecoder();
    /// @notice Thrown when `decoder` has no code at registration time.
    error DecoderHasNoCode();
    /// @notice Thrown when a decoder returns data that does not ABI-decode as a `uint256[]`.
    error DecoderReturnedMalformed();
    /// @notice Thrown when a direct update's `seq` is not strictly above the lane's stored seq (including
    /// `seq == 0`, since a fresh lane stores 0).
    error StaleSeq();
    /// @notice Thrown when a direct update's `slots[0]` does not leave its top 48 bits clear for `seq`.
    error SeqBitsNotClear();
    /// @notice Thrown when a caller that is neither the target nor the lane's decoder reads a lane by target.
    error NotLaneReader();

    /// @notice One element of a direct batch write. Fields mirror `updateState`.
    struct Update {
        address target;
        uint256 laneIndex;
        uint256[] slots;
        uint48 seq;
    }

    /// @notice One element of a decoder batch write. Fields mirror `updateStateWithDecoder`, plus a gas cap.
    /// @dev `gasLimit` bounds the gas forwarded to this element's decoder; 0 forwards all available gas.
    /// Relayers batching across makers should set it so one looping decoder cannot exhaust the batch.
    struct DecoderUpdate {
        address target;
        uint256 laneIndex;
        bytes aux;
        uint256 gasLimit;
    }

    /// @notice Maximum number of raw storage words in a lane.
    /// @dev The bound prevents reads or writes from escaping the lane's reserved storage region.
    uint256 internal constant MAX_SLOTS = 255;

    /// @dev Domain-separates lane storage from Solidity mapping storage and other hashed storage regions.
    bytes32 private constant LANE_NAMESPACE = keccak256("PrioUpdateRegistryV2.lane.v1");

    /// @notice Slot-0 layout on updater-managed lanes: the sequence number occupies the top 48 bits.
    /// Consumers mask their data with `SLOT0_DATA_MASK` and read the seq as `slot0 >> SEQ_SHIFT`. The
    /// file-level constants `PUR_SEQ_SHIFT`, `PUR_MAX_SEQ`, `PUR_SLOT0_DATA_MASK` are the same values for
    /// contracts that import this file; these getters exist for off-chain and cross-contract readers.
    uint256 public constant SEQ_SHIFT = PUR_SEQ_SHIFT;
    uint256 public constant MAX_SEQ = PUR_MAX_SEQ;
    uint256 public constant SLOT0_DATA_MASK = PUR_SLOT0_DATA_MASK;

    /// @dev Gas reserved before a batch element's write is attempted: per returned slot, a fresh cold
    /// SSTORE plus loop overhead; plus a base for what follows the write. Verified by a gas sweep in the
    /// tests: below the reserve the element is skipped, above it the element lands, with no band in
    /// between where the call runs out of gas.
    uint256 private constant WRITE_GAS_PER_SLOT = 23_000; // cold zero->nonzero SSTORE 22,100 + loop
    uint256 private constant WRITE_GAS_BASE = 40_000; // bookkeeping after the write and result encoding

    /// @dev Upper bound on decoder return data copied into memory: 8,256 bytes, the ABI encoding of a
    /// `uint256[]` with 256 elements (so a 256-slot return is copied and then rejected as `TooManySlots`
    /// rather than silently discarded). Anything longer
    /// is discarded entirely and classified as malformed, so a decoder cannot force unbounded memory
    /// expansion on the caller: per element the caller allocates at most this much, and the decoded array
    /// aliases that copy.
    uint256 private constant MAX_DECODER_RETURN = 64 + 32 * (MAX_SLOTS + 1);

    /// @notice Tracks whether `updater` is authorized to write state on behalf of `target`.
    /// @dev Each target manages its own set of updaters via `addUpdater` and `removeUpdater`.
    mapping(address target => mapping(address updater => bool)) public isUpdater;

    /// @notice Returns the decoder permanently assigned to `target` and `laneIndex`, or zero if none is set.
    /// @dev A non-zero decoder marks the lane as decoder-managed and disables direct updater writes.
    mapping(address target => mapping(uint256 laneIndex => address decoder)) public laneDecoder;

    /// @notice Authorizes `updater` to write state on behalf of `msg.sender`.
    /// @dev The stored authorization is idempotent. The event is emitted even if `updater` is already authorized.
    /// @param updater The address being granted write authorization.
    function addUpdater(address updater) external {
        isUpdater[msg.sender][updater] = true;
        emit UpdaterAdded(msg.sender, updater);
    }

    /// @notice Revokes authorization for `updater` to write state on behalf of `msg.sender`.
    /// @dev The stored authorization is idempotent. The event is emitted even if `updater` is not authorized.
    /// @param updater The address whose write authorization is being revoked.
    function removeUpdater(address updater) external {
        isUpdater[msg.sender][updater] = false;
        emit UpdaterRemoved(msg.sender, updater);
    }

    /// @notice Permanently assigns `decoder` to `msg.sender` at `laneIndex` and clears the lane's slot 0.
    /// @dev Once set, the decoder cannot be removed or replaced and direct updater writes to the lane are disabled.
    /// The code-length check only applies at registration time. A proxy decoder may still change behavior.
    /// @param laneIndex The lane to assign the decoder to, scoped to `msg.sender`.
    /// @param decoder The contract that validates and unpacks updates for the lane.
    function setDecoder(uint256 laneIndex, address decoder) external {
        if (decoder == address(0)) revert ZeroDecoder();
        if (decoder.code.length == 0) revert DecoderHasNoCode();
        if (laneDecoder[msg.sender][laneIndex] != address(0)) revert DecoderAlreadySet();
        laneDecoder[msg.sender][laneIndex] = decoder;
        // Binding switches the lane's layout to the decoder's. Clear slot 0 so direct-path data (and its
        // packed seq) never survives into a layout that does not expect it; trailing slots keep their
        // words until the decoder's first write, as with any shorter write.
        uint256 slot0 = _laneBase(msg.sender, laneIndex);
        assembly {
            sstore(slot0, 0)
        }
        emit DecoderSet(msg.sender, laneIndex, decoder);
    }

    /// @notice Clears slot 0 of `msg.sender`'s updater-managed lane, including its stored sequence
    /// number, so the next direct write may carry any `seq >= 1` again.
    /// @dev Recovery path for a lane whose seq was pushed to `MAX_SEQ` or far ahead by mistake: with no
    /// other way to lower a stored seq, such a lane would otherwise be unusable on the direct path
    /// forever. Only the lane owner can call it, and only on a lane without a decoder: a decoder that
    /// keeps its replay defence in slot 0 must not have it wiped from underneath it. Note that a reset
    /// also reopens any of the owner's earlier direct updates that never landed, since their seq is
    /// above zero again; rotate the updater when you reset if such updates may still be in flight.
    /// Readers see slot 0 as zero until the next write.
    /// @param laneIndex The lane to reset, scoped to `msg.sender`.
    // Assembly is used to clear the lane's slot 0 directly.
    // slither-disable-next-line assembly
    function resetLane(uint256 laneIndex) external {
        if (laneDecoder[msg.sender][laneIndex] != address(0)) revert DecoderBoundLane();
        uint256 slot0 = _laneBase(msg.sender, laneIndex);
        assembly {
            sstore(slot0, 0)
        }
        emit LaneReset(msg.sender, laneIndex);
    }

    /*
     * State
     */

    /// @notice Writes raw slot values for `target` at `laneIndex`.
    /// @dev `msg.sender` must be an authorized updater for `target`, and the lane must not have a decoder.
    /// The registry performs no freshness or application-level validation on the slot values, and no
    /// ordering validation beyond `seq`. Each supplied word is stored verbatim except that `seq` is written
    /// into the top 48 bits of slot 0. A shorter write does not clear words left by an earlier
    /// longer write. Whether a call succeeds depends only on calldata, the two registry mappings, and the
    /// lane's stored slot 0 (through `seq`); nothing is checked against the block header.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The raw slot values to write. Length must be in `[1, 255]`. The top 48 bits of
    /// `slots[0]` must be zero; the registry stores `seq` there. Slots 1 and up are full width.
    /// @param seq Per-lane monotonic sequence number (required; the `uint48` type bounds it, so a value that
    /// does not fit is rejected by ABI decoding before any registry check). Must be strictly greater than the
    /// seq in the top 48 bits of the lane's stored slot 0 (a fresh lane stores 0, so the first write needs
    /// `seq >= 1`), and is written into those bits, so a target reads it back from slot 0 and an older or
    /// replayed direct update can never overwrite a newer one, whoever submits it. Reading the stored word
    /// costs nothing extra because slot 0 is written anyway. The stored seq can only go up; a lane pushed
    /// to `MAX_SEQ` (or far ahead by mistake) is recovered by the target with `resetLane`. Decoder-managed
    /// lanes are not subject to this rule; their decoder defines the layout.
    function updateState(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq) external {
        _updateState(target, laneIndex, slots, seq);
    }

    /// @notice Applies several direct writes. Each element is checked exactly as `updateState`, but a
    /// failing element is skipped rather than reverting the call.
    /// @dev An element is skipped if `msg.sender` is not an updater for its target, its
    /// lane has a decoder, its slot count is outside `[1, 255]`, its `slots[0]` has seq bits set, or its
    /// `seq` is not above the lane's stored seq. A `seq` that does not fit in 48 bits is rejected by ABI
    /// decoding and reverts the whole call, not just the element. Elements are applied in order, so a
    /// later element targeting the same lane overwrites an earlier one. An empty batch is a no-op.
    /// @param updates The direct writes to apply.
    /// @return applied `applied[i]` is true if element `i` was written.
    function updateStateBatch(Update[] calldata updates) external returns (bool[] memory applied) {
        uint256 count = updates.length;
        applied = new bool[](count);
        for (uint256 i; i < count; ++i) {
            Update calldata u = updates[i];
            applied[i] = _tryUpdateState(u.target, u.laneIndex, u.slots, u.seq);
        }
    }

    /// @notice Validates an opaque payload with the lane's decoder and stores the slots it returns.
    /// @dev Anyone may relay an update. The decoder is responsible for authorization and all
    /// application-level validation, including freshness and replay protection. The decoder is reached
    /// with `STATICCALL`, so the only persistent state this function writes is the target's own lane.
    /// A shorter decoded update does not clear words left by an earlier longer update.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The decoder-managed lane to write, scoped to `target`.
    /// @param aux The opaque payload passed to the lane's decoder.
    function updateStateWithDecoder(address target, uint256 laneIndex, bytes calldata aux) external {
        _updateStateWithDecoder(target, laneIndex, aux);
    }

    /// @notice Applies several decoder writes. Each element is checked exactly as
    /// `updateStateWithDecoder`, but a failing element is skipped rather than reverting the call.
    /// @dev Anyone may relay a batch, so one transaction can carry payloads for many targets and makers.
    /// An element is skipped if its lane has no decoder, its decoder reverts or runs out of the gas
    /// forwarded to it (`gasLimit`, or all available gas when 0), its return data is not a well-formed
    /// `uint256[]`, or the returned slot count is outside `[1, 255]`. A decoder cannot persist any
    /// external state during validation; it can influence later elements only through the lane its own
    /// element writes (which a later decoder may read) and through gas. `gasLimit` bounds the gas its
    /// decoder executes; the caller-side cost of copying and decoding its return is bounded by
    /// `MAX_DECODER_RETURN`, memory is reused across elements so a long batch does not accumulate
    /// memory-expansion cost, and an element whose returned slots the remaining gas cannot cover (at a
    /// worst-case cold-SSTORE rate) is skipped rather than attempted, so a large return cannot revert
    /// the batch. With `gasLimit` zero an element may still take 63/64 of the remaining gas, so the
    /// elements after it are starved and skipped: set a cap to keep them isolated. Elements are applied in order.
    /// An empty batch is a no-op.
    /// @param updates The decoder writes to apply.
    /// @return applied `applied[i]` is true if element `i` was written.
    // Assembly is used to reset the free memory pointer between elements; nothing allocated inside an
    // iteration is referenced after it.
    // slither-disable-next-line assembly
    function updateStateWithDecoderBatch(DecoderUpdate[] calldata updates) external returns (bool[] memory applied) {
        uint256 count = updates.length;
        applied = new bool[](count);
        uint256 freeMem;
        assembly ("memory-safe") {
            freeMem := mload(0x40)
        }
        for (uint256 i; i < count; ++i) {
            DecoderUpdate calldata u = updates[i];
            (DecodeStatus status, uint256[] memory slots) = _runDecoder(u.target, u.laneIndex, u.aux, u.gasLimit);
            // `gasLimit` bounds the decoder; the registry's own write is bounded by the returned slot
            // count (<= 255) and is skipped, not attempted, when the remaining gas cannot cover it, so a
            // large return cannot turn into an out-of-gas revert of the whole batch.
            if (status == DecodeStatus.Ok && gasleft() >= slots.length * WRITE_GAS_PER_SLOT + WRITE_GAS_BASE) {
                _writeSlotsMemory(u.target, u.laneIndex, slots);
                applied[i] = true;
            }
            // Release this element's scratch memory (`data`, `ret`, `slots`) for the next one.
            assembly {
                mstore(0x40, freeMem)
            }
        }
    }

    /// @notice Returns one raw slot from `msg.sender`'s lane, or zero if it has never been written.
    /// @dev Reads are scoped to `msg.sender`; a caller cannot use this function to read another target's lane.
    /// No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param slotIndex The zero-based slot index. Must be less than 255.
    /// @return value The raw stored value.
    // Assembly is used to read the lane's computed storage slot directly.
    // slither-disable-next-line assembly
    function getSlot(uint256 laneIndex, uint256 slotIndex) external view returns (uint256 value) {
        if (slotIndex >= MAX_SLOTS) revert SlotIndexOutOfRange();
        uint256 slot = _laneBase(msg.sender, laneIndex) + slotIndex;
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Returns one raw slot from `target`'s lane. Callable by `target` itself or by the decoder
    /// bound to that lane, so a shared decoder can read the lane it validates for (for example to
    /// enforce a sequence number) without being the target.
    /// @param target The lane owner.
    /// @param laneIndex The lane to read, scoped to `target`.
    /// @param slotIndex The zero-based slot index. Must be less than 255.
    /// @return value The raw stored value.
    // Assembly is used to read the lane's computed storage slot directly.
    // slither-disable-next-line assembly
    function getSlotOf(address target, uint256 laneIndex, uint256 slotIndex) external view returns (uint256 value) {
        if (msg.sender != target && msg.sender != laneDecoder[target][laneIndex]) revert NotLaneReader();
        if (slotIndex >= MAX_SLOTS) revert SlotIndexOutOfRange();
        uint256 slot = _laneBase(target, laneIndex) + slotIndex;
        assembly {
            value := sload(slot)
        }
    }

    /// @notice Returns a contiguous range of raw slots from `msg.sender`'s lane.
    /// @dev Reads are scoped to `msg.sender`. The returned range is
    /// `[slotIndex, slotIndex + slotCount)`. Unwritten words return zero, and words left by a
    /// shorter overwrite remain visible. No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param slotIndex The zero-based index of the first slot to return.
    /// @param slotCount The number of slots to return. The requested range must fit within 255 slots.
    /// @return slots The requested raw stored slot values.
    function getSlots(uint256 laneIndex, uint256 slotIndex, uint256 slotCount)
        external
        view
        returns (uint256[] memory slots)
    {
        return _readSlots(msg.sender, laneIndex, slotIndex, slotCount);
    }

    /// @notice Returns the first `count` raw slots from `msg.sender`'s lane.
    /// @dev Reads are scoped to `msg.sender`. The registry does not store a lane length, so the caller
    /// supplies `count`. Unwritten words return zero, and words left by a shorter overwrite remain visible.
    /// No freshness or application-level validation is performed.
    /// @param laneIndex The lane to read, scoped to `msg.sender`.
    /// @param count The number of slots to return. Must not exceed 255.
    /// @return slots The raw stored slot values.
    function getState(uint256 laneIndex, uint256 count) external view returns (uint256[] memory slots) {
        return _readSlots(msg.sender, laneIndex, 0, count);
    }

    /// @notice Runs every check of the direct path and returns the error selector the single call would
    /// revert with, or zero if the write may proceed. Shared by `updateState` (reverts on non-zero) and
    /// `updateStateBatch` (skips on non-zero), so the two paths cannot drift.
    /// @dev Order: the free calldata shape checks, then the two authorization reads, then the seq
    /// compare, so a rejected element costs as little as possible. The seq check reads the lane's slot 0;
    /// the write that follows would pay that slot's cold access anyway.
    // Assembly is used to read the lane's slot 0 directly.
    // slither-disable-next-line assembly
    function _checkDirect(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq)
        internal
        view
        returns (bytes4 err)
    {
        uint256 slotCount = slots.length;
        if (slotCount == 0) return EmptySlots.selector;
        if (slotCount > MAX_SLOTS) return TooManySlots.selector;
        if (slots[0] >> PUR_SEQ_SHIFT != 0) return SeqBitsNotClear.selector;
        if (!isUpdater[target][msg.sender]) return NotAuthorized.selector;
        if (laneDecoder[target][laneIndex] != address(0)) return DecoderBoundLane.selector;
        uint256 slot0 = _laneBase(target, laneIndex);
        uint256 stored;
        assembly {
            stored := sload(slot0)
        }
        // A never-written lane stores 0, so the first write needs seq >= 1 and seq == 0 always fails.
        if (seq <= stored >> PUR_SEQ_SHIFT) return StaleSeq.selector;
        return 0;
    }

    /// @notice Body of `updateState`: reverts with the selector `_checkDirect` returns, else writes.
    // Assembly is used to revert with a bare four-byte custom-error selector.
    // slither-disable-next-line assembly
    function _updateState(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq) internal {
        bytes4 err = _checkDirect(target, laneIndex, slots, seq);
        if (err != 0) {
            assembly ("memory-safe") {
                mstore(0, err)
                revert(0, 4)
            }
        }
        _writeSlotsCalldata(target, laneIndex, slots, seq);
    }

    /// @notice Body of one `updateStateBatch` element: returns false instead of reverting.
    function _tryUpdateState(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq)
        internal
        returns (bool)
    {
        if (_checkDirect(target, laneIndex, slots, seq) != 0) return false;
        _writeSlotsCalldata(target, laneIndex, slots, seq);
        return true;
    }

    /// @dev Outcome of running a lane's decoder on a payload. `CallFailed` leaves the decoder's revert
    /// data in the return buffer for the single-call path to bubble.
    enum DecodeStatus {
        Ok,
        NoDecoder,
        CallFailed,
        Malformed,
        NoSlots,
        TooMany
    }

    /// @notice Runs the lane's decoder and validates its return. Shared by `updateStateWithDecoder`
    /// (maps every non-`Ok` status to a revert) and `updateStateWithDecoderBatch` (skips on non-`Ok`),
    /// so the two paths cannot drift.
    function _runDecoder(address target, uint256 laneIndex, bytes calldata aux, uint256 gasLimit)
        internal
        view
        returns (DecodeStatus status, uint256[] memory slots)
    {
        address decoder = laneDecoder[target][laneIndex];
        if (decoder == address(0)) return (DecodeStatus.NoDecoder, slots);
        (bool ok, bytes memory ret) = _callDecoder(decoder, target, laneIndex, aux, gasLimit);
        if (!ok) return (DecodeStatus.CallFailed, slots);
        bool wellFormed;
        (wellFormed, slots) = _decodeSlots(ret);
        if (!wellFormed) return (DecodeStatus.Malformed, slots);
        if (slots.length == 0) return (DecodeStatus.NoSlots, slots);
        if (slots.length > MAX_SLOTS) return (DecodeStatus.TooMany, slots);
        return (DecodeStatus.Ok, slots);
    }

    /// @notice Body of `updateStateWithDecoder`. A decoder revert is bubbled unchanged.
    // Assembly is used to bubble the decoder's full revert data straight from the return buffer.
    // slither-disable-next-line assembly
    function _updateStateWithDecoder(address target, uint256 laneIndex, bytes calldata aux) internal {
        (DecodeStatus status, uint256[] memory slots) = _runDecoder(target, laneIndex, aux, 0);
        if (status == DecodeStatus.NoDecoder) revert DecoderNotSet();
        if (status == DecodeStatus.CallFailed) {
            // Bubble the decoder's complete revert data (empty for an exceptional halt). The return
            // buffer still holds it: no external call has happened since.
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        if (status == DecodeStatus.Malformed) revert DecoderReturnedMalformed();
        if (status == DecodeStatus.NoSlots) revert DecoderReturnedNoSlots();
        if (status == DecodeStatus.TooMany) revert TooManySlots();
        _writeSlotsMemory(target, laneIndex, slots);
    }

    /// @notice STATICCALLs `decoder.validateAndUnpack` with at most `gasLimit` gas (0 = all available)
    /// and, on success, copies the return data if it is at most `MAX_DECODER_RETURN` bytes; a longer return is
    /// treated as empty. On failure nothing is copied and `ret` is empty; the revert data stays in the
    /// return buffer for the caller to bubble.
    /// @dev The only external interaction in the contract. An over-cap return is never copied, so a decoder
    /// cannot force unbounded memory expansion on the caller. A `gasLimit`
    /// above the gas available is capped by the EVM (EIP-150), it does not fail.
    // Assembly is used to cap the gas forwarded and the return data copied.
    // slither-disable-next-line assembly
    function _callDecoder(address decoder, address target, uint256 laneIndex, bytes calldata aux, uint256 gasLimit)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        bytes memory data = abi.encodeCall(IPrioUpdateDecoder.validateAndUnpack, (target, laneIndex, aux));
        uint256 gas_ = gasLimit == 0 ? gasleft() : gasLimit;
        uint256 maxRet = MAX_DECODER_RETURN;
        assembly ("memory-safe") {
            ok := staticcall(gas_, decoder, add(data, 32), mload(data), 0, 0)
            let size := 0
            if ok {
                size := returndatasize()
                // An over-cap return is copied as EMPTY (not truncated), so it always classifies as
                // malformed rather than possibly truncating into a canonical-looking array.
                if gt(size, maxRet) { size := 0 }
            }
            ret := mload(0x40)
            mstore(ret, size)
            returndatacopy(add(ret, 32), 0, size)
            mstore(0x40, add(add(ret, 32), and(add(size, 31), not(31))))
        }
    }

    /// @notice Checks that `ret` is exactly the ABI encoding of one `uint256[]` and decodes it.
    /// @dev Shape: word 0 is the head offset (must be 32), word 1 the length `n`, followed by exactly `n`
    /// words. Checking the shape first means the array can be aliased in place (no second copy and no
    /// decode revert), so a malformed return can be skipped in a batch instead of reverting the whole call.
    // Assembly is used to read the head words and to alias the validated array without copying.
    // slither-disable-next-line assembly
    function _decodeSlots(bytes memory ret) internal pure returns (bool wellFormed, uint256[] memory slots) {
        if (ret.length < 64) return (false, slots);
        uint256 offset;
        uint256 n;
        assembly ("memory-safe") {
            offset := mload(add(ret, 32))
            n := mload(add(ret, 64))
        }
        if (offset != 32) return (false, slots);
        if ((ret.length - 64) / 32 != n || (ret.length - 64) % 32 != 0) return (false, slots);
        // `ret` is exactly [len][32][n][n words]; `ret + 64` is therefore a valid `uint256[]` head.
        assembly ("memory-safe") {
            slots := add(ret, 64)
        }
        wellFormed = true;
    }

    /// @notice Returns the base storage slot for `target` and `laneIndex`.
    /// @dev Slot `i` of the lane is stored at `_laneBase(target, laneIndex) + i` for `0 <= i < 255`.
    function _laneBase(address target, uint256 laneIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(LANE_NAMESPACE, target, laneIndex)));
    }

    /// @notice Reads a contiguous range of raw slots for `target` at `laneIndex`.
    /// @dev The range check uses subtraction to avoid overflowing `slotIndex + slotCount`.
    // Assembly is used to read each computed storage slot directly.
    // slither-disable-next-line assembly
    function _readSlots(address target, uint256 laneIndex, uint256 slotIndex, uint256 slotCount)
        internal
        view
        returns (uint256[] memory slots)
    {
        if (slotIndex > MAX_SLOTS || slotCount > MAX_SLOTS - slotIndex) revert SlotIndexOutOfRange();

        slots = new uint256[](slotCount);
        if (slotCount == 0) return slots;

        uint256 base = _laneBase(target, laneIndex) + slotIndex;
        for (uint256 i; i < slotCount; ++i) {
            uint256 slot = base + i;
            uint256 value;
            assembly {
                value := sload(slot)
            }
            slots[i] = value;
        }
    }

    /// @notice Writes calldata slot values for `target` at `laneIndex`, verbatim except that `seq` is packed
    /// into the top 48 bits of slot 0.
    /// @dev Does not perform authorization or application-level validation. The caller must enforce
    /// the appropriate write path before invoking this function.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The raw slot values to write. The caller (`_checkDirect`) has already bounded the
    /// length to `[1, 255]` and validated `seq`.
    /// @param seq Sequence number OR-ed into the top 48 bits of slot 0.
    // Assembly is used to store words directly from calldata without copying the array to memory.
    // slither-disable-next-line assembly
    function _writeSlotsCalldata(address target, uint256 laneIndex, uint256[] calldata slots, uint48 seq) internal {
        uint256 count = slots.length;
        uint256 base = _laneBase(target, laneIndex);
        assembly {
            let offset := slots.offset
            sstore(base, or(shl(PUR_SEQ_SHIFT, seq), calldataload(offset)))
            for { let i := 1 } lt(i, count) { i := add(i, 1) } {
                sstore(add(base, i), calldataload(add(offset, mul(i, 0x20))))
            }
        }
    }

    /// @notice Writes decoder-returned slot values verbatim for `target` at `laneIndex`.
    /// @dev Does not perform decoder selection or application-level validation. The caller must invoke
    /// the registered decoder before calling this function.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param slots The decoder-returned slot values. The caller (`_runDecoder`) has already bounded the
    /// length to `[1, 255]`.
    // Assembly is used to store each memory word at its computed lane slot.
    // slither-disable-next-line assembly
    function _writeSlotsMemory(address target, uint256 laneIndex, uint256[] memory slots) internal {
        uint256 count = slots.length;
        uint256 base = _laneBase(target, laneIndex);
        for (uint256 i; i < count; ++i) {
            uint256 value = slots[i];
            uint256 slot = base + i;
            assembly {
                sstore(slot, value)
            }
        }
    }
}
