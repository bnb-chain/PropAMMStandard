// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistry} from "../PrioUpdateRegistry.sol";
import {SignedSeqDecoder} from "../SignedSeqDecoder.sol";
import {ExamplePammRouter} from "../ExamplePammRouter.sol";

/// @dev Minimal ERC-1271 wallet: accepts a hash signed by its owner key.
contract Mock1271Wallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(signature[:64], (bytes32, bytes32));
        uint8 v = uint8(signature[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice BAP-710 §7.1 "Signed updates through SignedSeqDecoder", run against ExamplePammRouter as the target.
contract SignedSeqDecoderTest is Test {
    PrioUpdateRegistry registry;
    SignedSeqDecoder signedDecoder;
    ExamplePammRouter pool;

    address tokenIn = makeAddr("USDT");
    address tokenOut = makeAddr("WBNB");
    address otherOut = makeAddr("BTCB");
    address anyRelayer = makeAddr("anyRelayer");

    uint256 makerKey = 0xA11CE;
    uint256 otherKey = 0xB0B;
    address makerSigner;

    uint256 lane1;
    uint256 lane2;
    uint256[] slots;

    function setUp() public {
        vm.roll(1_000);
        registry = new PrioUpdateRegistry();
        signedDecoder = new SignedSeqDecoder(registry);
        pool = new ExamplePammRouter(address(registry));
        makerSigner = vm.addr(makerKey);

        lane1 = pool.laneFor(tokenIn, tokenOut);
        lane2 = pool.laneFor(tokenIn, otherOut);
        slots = new uint256[](1);
        slots[0] = pool.packQuote(1e15, block.number + 10);
    }

    // ---- helpers ----

    function setUpSignedLane() internal {
        pool.bindDecoder(tokenIn, tokenOut, address(signedDecoder));
        pool.setSigner(address(signedDecoder), makerSigner);
    }

    function sign(uint256 key, uint256 lane, uint256 seq, uint256 maxBlock, uint256 maxTimestamp)
        internal
        view
        returns (SignedSeqDecoder.SignedUpdate memory u)
    {
        u = SignedSeqDecoder.SignedUpdate(address(pool), lane, slots, seq, maxBlock, maxTimestamp, "");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, signedDecoder.digest(u));
        u.signature = abi.encodePacked(r, s, v);
    }

    function relay(SignedSeqDecoder.SignedUpdate memory u) internal {
        vm.prank(anyRelayer);
        registry.updateStateWithDecoder(address(pool), u.laneIndex, abi.encode(u));
    }

    // ---- BAP-710 §7.1 ----

    // Anyone may relay a maker-signed update; it lands with the same slot-0 layout as the direct path
    function testSignedUpdateRelayed() public {
        setUpSignedLane();
        relay(sign(makerKey, lane1, 1, block.number + 2, 0));

        vm.prank(address(pool));
        uint256 word = registry.getState(lane1, 1)[0];
        assertEq(word & registry.SLOT0_DATA_MASK(), slots[0]);
        assertEq(word >> registry.SEQ_SHIFT(), 1);

        // ...so the pool prices it with its unchanged read path.
        assertTrue(pool.isActive(tokenIn, tokenOut));
        assertEq(pool.quote(tokenIn, tokenOut, 1_000e18), 1e18);
    }

    // A replayed or older signed payload is not newer than the lane
    function testSignedReplayRejected() public {
        setUpSignedLane();
        SignedSeqDecoder.SignedUpdate memory u = sign(makerKey, lane1, 5, 0, 0);
        relay(u);

        vm.expectRevert(SignedSeqDecoder.BadSeq.selector);
        relay(u);

        u = sign(makerKey, lane1, 4, 0, 0);
        vm.expectRevert(SignedSeqDecoder.BadSeq.selector);
        relay(u);
    }

    // Wrong key, expired payload, payload for another lane, rotated key
    function testSignedUpdateRejections() public {
        setUpSignedLane();

        SignedSeqDecoder.SignedUpdate memory u = sign(otherKey, lane1, 1, 0, 0);
        vm.expectRevert(SignedSeqDecoder.BadSignature.selector);
        relay(u);

        u = sign(makerKey, lane1, 1, block.number, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(SignedSeqDecoder.Expired.selector);
        relay(u);

        u = sign(makerKey, lane1, 1, 0, block.timestamp);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(SignedSeqDecoder.Expired.selector);
        relay(u);

        u = sign(makerKey, lane2, 1, 0, 0);
        vm.prank(anyRelayer);
        vm.expectRevert(SignedSeqDecoder.PayloadMismatch.selector);
        registry.updateStateWithDecoder(address(pool), lane1, abi.encode(u));

        u = sign(makerKey, lane1, 1, 0, 0);
        pool.setSigner(address(signedDecoder), vm.addr(otherKey)); // rotation invalidates unlanded payloads
        vm.expectRevert(SignedSeqDecoder.BadSignature.selector);
        relay(u);
    }

    // The signer may be a contract wallet verified through ERC-1271
    function testSignedUpdateERC1271() public {
        Mock1271Wallet makerMultisig = new Mock1271Wallet(makerSigner);
        pool.bindDecoder(tokenIn, tokenOut, address(signedDecoder));
        pool.setSigner(address(signedDecoder), address(makerMultisig));

        relay(sign(makerKey, lane1, 1, 0, 0)); // signed by the wallet's owner key, verified via isValidSignature
        assertTrue(pool.isActive(tokenIn, tokenOut));

        {
            SignedSeqDecoder.SignedUpdate memory p = sign(otherKey, lane1, 2, 0, 0);
            vm.expectRevert(SignedSeqDecoder.BadSignature.selector);
            relay(p);
        }
    }

    // One bad payload in a relayer's cross-maker batch is skipped, not fatal
    function testSignedBatchSkipsBadElement() public {
        setUpSignedLane();
        PrioUpdateRegistry.DecoderUpdate[] memory ups = new PrioUpdateRegistry.DecoderUpdate[](2);
        ups[0] =
            PrioUpdateRegistry.DecoderUpdate(address(pool), lane1, abi.encode(sign(makerKey, lane1, 1, 0, 0)), 100_000);
        ups[1] =
            PrioUpdateRegistry.DecoderUpdate(address(pool), lane1, abi.encode(sign(otherKey, lane1, 2, 0, 0)), 100_000);

        vm.prank(anyRelayer);
        bool[] memory applied = registry.updateStateWithDecoderBatch(ups);
        assertTrue(applied[0]);
        assertFalse(applied[1]);
    }

    // Binding a decoder closes the direct path on that lane
    function testDecoderLaneClosesDirectPath() public {
        setUpSignedLane();
        address maker = makeAddr("maker");
        pool.addMaker(maker);
        vm.prank(maker);
        vm.expectRevert(PrioUpdateRegistry.DecoderBoundLane.selector);
        registry.updateState(address(pool), lane1, slots, 1);
    }

    // ---- decoder guards ----

    function testOnlyItsRegistryMayCall() public {
        setUpSignedLane();
        bytes memory aux = abi.encode(sign(makerKey, lane1, 1, 0, 0));
        vm.expectRevert(SignedSeqDecoder.NotRegistry.selector);
        signedDecoder.validateAndUnpack(address(pool), lane1, aux);
    }

    function testNoSignerDisablesTarget() public {
        pool.bindDecoder(tokenIn, tokenOut, address(signedDecoder));
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 1, 0, 0);
            vm.expectRevert(SignedSeqDecoder.NoSigner.selector);
            relay(p);
        }

        pool.setSigner(address(signedDecoder), makerSigner);
        relay(sign(makerKey, lane1, 1, 0, 0));
        pool.setSigner(address(signedDecoder), address(0));
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 2, 0, 0);
            vm.expectRevert(SignedSeqDecoder.NoSigner.selector);
            relay(p);
        }
    }

    function testSeqBoundsAndBits() public {
        setUpSignedLane();
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 0, 0, 0);
            vm.expectRevert(SignedSeqDecoder.BadSeq.selector);
            relay(p);
        }
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 1 << 48, 0, 0);
            vm.expectRevert(SignedSeqDecoder.BadSeq.selector);
            relay(p);
        }

        slots[0] = 1 << 208;
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 1, 0, 0);
            vm.expectRevert(SignedSeqDecoder.BadSeq.selector);
            relay(p);
        }
    }

    function testDomainBinding() public {
        // A payload signed for one decoder deployment does not verify on another.
        SignedSeqDecoder otherDecoder = new SignedSeqDecoder(registry);
        pool.bindDecoder(tokenIn, tokenOut, address(otherDecoder));
        pool.setSigner(address(otherDecoder), makerSigner);
        {
            SignedSeqDecoder.SignedUpdate memory p = sign(makerKey, lane1, 1, 0, 0);
            vm.expectRevert(SignedSeqDecoder.BadSignature.selector);
            relay(p); // `sign` hashes against signedDecoder's domain
        }
    }

    function testOnlyOwnerConfiguresSignedLanes() public {
        vm.startPrank(anyRelayer);
        vm.expectRevert(ExamplePammRouter.NotOwner.selector);
        pool.bindDecoder(tokenIn, tokenOut, address(signedDecoder));
        vm.expectRevert(ExamplePammRouter.NotOwner.selector);
        pool.setSigner(address(signedDecoder), anyRelayer);
        vm.stopPrank();
    }
}
