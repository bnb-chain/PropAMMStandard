// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "solady/utils/EIP712.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {IPrioUpdateDecoder, PrioUpdateRegistry, PUR_SEQ_SHIFT, PUR_MAX_SEQ} from "./PrioUpdateRegistry.sol";

/// @notice Reference decoder for relayed, maker-signed updates (BAP-710 §4.2.3): the registry-side
/// replacement for V1's `batchUpdateStateWithSignature`. One deployment serves any number of targets; each target binds it to
/// its lanes with `setDecoder` and registers its signer with `setSigner`.
/// @dev The payload is `abi.encode(SignedUpdate)`. The decoder verifies an EIP-712 signature over the
/// update (ECDSA for an EOA signer, ERC-1271 when the signer has code, which includes an EOA that has
/// delegated code under EIP-7702), checks the deadline, reads the lane's current seq through `getSlotOf`
/// and requires the new one to be strictly higher, and returns the slots with the seq packed into the
/// top 48 bits of slot 0, the same layout the direct path uses, so a consumer reads both kinds of lane
/// identically. Anyone may relay a payload; replaying it is rejected as not newer. The decoder runs under
/// STATICCALL and keeps no state beyond the signer registry; all sequencing state lives in the lane.
contract SignedSeqDecoder is IPrioUpdateDecoder, EIP712 {
    struct SignedUpdate {
        address target;
        uint256 laneIndex;
        uint256[] slots; // slots[0] must leave its top 48 bits clear
        uint256 seq; // 48-bit, strictly increasing per lane
        uint256 maxBlock; // 0 = unchecked
        uint256 maxTimestamp; // 0 = unchecked
        bytes signature;
    }

    error NotRegistry();
    error NoSigner();
    error BadSignature();
    error Expired();
    error BadSeq();
    error PayloadMismatch();

    event SignerSet(address indexed target, address indexed signer);

    PrioUpdateRegistry public immutable registry;

    /// @notice The key that must sign updates for `target`; zero disables the target.
    mapping(address target => address signer) public signerOf;

    /// @dev Source: https://gist.github.com/quintuskilbourn/179a0a11c1859376899fb75112e6d614, adapted to
    ///      the registry in this directory (imports only; logic unchanged).
    bytes32 public constant UPDATE_TYPEHASH = keccak256(
        "SignedUpdate(address target,uint256 laneIndex,uint256[] slots,uint256 seq,uint256 maxBlock,uint256 maxTimestamp)"
    );

    constructor(PrioUpdateRegistry registry_) {
        registry = registry_;
    }

    /// @notice Registers the signer for `msg.sender`'s lanes. Called by the target itself.
    function setSigner(address signer) external {
        signerOf[msg.sender] = signer;
        emit SignerSet(msg.sender, signer);
    }

    /// @notice The EIP-712 digest a maker signs. The domain's verifying contract is this decoder, which
    /// only accepts calls from the registry it was built for, so a signature cannot be replayed onto
    /// another chain, decoder or registry.
    function digest(SignedUpdate memory u) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                UPDATE_TYPEHASH,
                u.target,
                u.laneIndex,
                keccak256(abi.encodePacked(u.slots)),
                u.seq,
                u.maxBlock,
                u.maxTimestamp
            )
        );
        return _hashTypedData(structHash);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IPrioUpdateDecoder
    // slither-disable-next-line timestamp
    function validateAndUnpack(address target, uint256 laneIndex, bytes calldata aux)
        external
        view
        returns (uint256[] memory slots)
    {
        // Only the registry this decoder was built for may drive it: the seq it reads (and the lane
        // the registry then writes) must belong to the same registry, else a payload accepted here
        // could be replayed through another registry that binds this decoder.
        if (msg.sender != address(registry)) revert NotRegistry();
        SignedUpdate memory u = abi.decode(aux, (SignedUpdate));
        if (u.target != target || u.laneIndex != laneIndex) revert PayloadMismatch();

        address signer = signerOf[target];
        if (signer == address(0)) revert NoSigner();
        if (!SignatureCheckerLib.isValidSignatureNow(signer, digest(u), u.signature)) revert BadSignature();

        if (u.maxBlock != 0 && block.number > u.maxBlock) revert Expired();
        // slither-disable-next-line timestamp
        if (u.maxTimestamp != 0 && block.timestamp > u.maxTimestamp) revert Expired();

        slots = u.slots;
        if (slots.length == 0) revert BadSeq();
        if (u.seq == 0 || u.seq > PUR_MAX_SEQ) revert BadSeq();
        if (slots[0] >> PUR_SEQ_SHIFT != 0) revert BadSeq();
        uint256 stored = registry.getSlotOf(target, laneIndex, 0);
        if (u.seq <= stored >> PUR_SEQ_SHIFT) revert BadSeq();

        slots[0] |= u.seq << PUR_SEQ_SHIFT;
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedSeqDecoder";
        version = "1";
    }
}
