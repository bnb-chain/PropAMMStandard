// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrioUpdateRegistry, IPrioUpdateDecoder} from "../PrioUpdateRegistry.sol";
import {ExamplePammRouter} from "../ExamplePammRouter.sol";
import {ExamplePammTaker} from "../ExamplePammTaker.sol";
import {IPropAMM} from "../IPropAMM.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev ERC20 that calls `onTokenReceived` on the recipient after a transfer, like an ERC777 hook.
contract HookERC20 is MockERC20 {
    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) HookReceiver(to).onTokenReceived();
        return true;
    }
}

interface HookReceiver {
    function onTokenReceived() external;
}

/// @dev Recipient that tries to spend the same pushed payment twice by re-entering `swap`.
contract ReentrantRecipient is HookReceiver {
    ExamplePammRouter public immutable pool;
    address public immutable tokenIn;
    address public immutable tokenOut;
    bool public reentered;

    constructor(ExamplePammRouter pool_, address tokenIn_, address tokenOut_) {
        pool = pool_;
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    function onTokenReceived() external {
        if (reentered) return;
        reentered = true;
        pool.swap(tokenIn, tokenOut, 1e18, 0, address(this), 0);
    }
}

/// @dev Decoder that accepts any payload as a raw uint256[].
contract PassThroughDecoder is IPrioUpdateDecoder {
    function validateAndUnpack(address, uint256, bytes calldata aux) external pure returns (uint256[] memory) {
        return abi.decode(aux, (uint256[]));
    }
}

contract ExamplePammRouterTest is Test {
    PrioUpdateRegistry registry;
    ExamplePammRouter pool;
    ExamplePammRouter otherPool;
    MockERC20 usdt;
    MockERC20 wbnb;

    address maker = makeAddr("maker");
    address user = makeAddr("user");
    address anyone = makeAddr("anyone");

    uint256 constant PRICE = 1e15; // 1 USDT buys 0.001 WBNB
    uint256 lane;
    uint256[] slots;

    function setUp() public {
        vm.roll(1_000);
        registry = new PrioUpdateRegistry();
        pool = new ExamplePammRouter(address(registry));
        otherPool = new ExamplePammRouter(address(registry));
        usdt = new MockERC20();
        wbnb = new MockERC20();
        lane = pool.laneFor(address(usdt), address(wbnb));

        pool.addMaker(maker);
        wbnb.mint(address(pool), 100e18);
        pool.sync(address(wbnb));

        slots = new uint256[](1);
        slots[0] = pool.packQuote(PRICE, block.number + 2);
    }

    // ---- helpers ----

    function writeQuote(uint256 price, uint256 maxBlockNumber, uint48 seq) internal {
        uint256[] memory s = new uint256[](1);
        s[0] = pool.packQuote(price, maxBlockNumber);
        vm.prank(maker);
        registry.updateState(address(pool), lane, s, seq);
    }

    function pushIn(uint256 amount) internal {
        usdt.mint(address(pool), amount);
    }

    // =====================================================================
    // BAP-710 §7.1 — Priority Update Registry (direct path)
    // =====================================================================

    function testUnauthorizedUpdaterRejected() public {
        vm.prank(anyone);
        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.updateState(address(pool), lane, slots, 1);
    }

    function testAddMakerAuthorizesOnRegistry() public view {
        assertTrue(pool.isMaker(maker));
        assertTrue(registry.isUpdater(address(pool), maker));
        assertFalse(registry.isUpdater(address(otherPool), maker));
    }

    function testOnlyOwnerManagesMakers() public {
        vm.prank(anyone);
        vm.expectRevert(ExamplePammRouter.NotOwner.selector);
        pool.addMaker(anyone);

        pool.removeMaker(maker);
        vm.prank(maker);
        vm.expectRevert(PrioUpdateRegistry.NotAuthorized.selector);
        registry.updateState(address(pool), lane, slots, 1);
    }

    function testAuthorizedUpdateAndRead() public {
        vm.prank(maker);
        registry.updateState(address(pool), lane, slots, 1);

        vm.prank(address(pool));
        uint256[] memory got = registry.getState(lane, 1);
        assertEq(got[0] & registry.SLOT0_DATA_MASK(), slots[0]);
        assertEq(got[0] >> registry.SEQ_SHIFT(), 1);

        (uint256 price, uint256 maxBlockNumber, uint256 seq) = pool.readQuote(address(usdt), address(wbnb));
        assertEq(price, PRICE);
        assertEq(maxBlockNumber, block.number + 2);
        assertEq(seq, 1);
    }

    function testStaleSeqRejected() public {
        vm.startPrank(maker);
        registry.updateState(address(pool), lane, slots, 2);
        vm.expectRevert(PrioUpdateRegistry.StaleSeq.selector);
        registry.updateState(address(pool), lane, slots, 2);
        vm.expectRevert(PrioUpdateRegistry.StaleSeq.selector);
        registry.updateState(address(pool), lane, slots, 1);
        vm.stopPrank();
    }

    function testSeqBitsMustBeClear() public {
        slots[0] = 1 << 208;
        vm.prank(maker);
        vm.expectRevert(PrioUpdateRegistry.SeqBitsNotClear.selector);
        registry.updateState(address(pool), lane, slots, 1);
    }

    function testPackQuoteKeepsSeqBitsClear() public {
        uint256 word = pool.packQuote((1 << 160) - 1, (1 << 48) - 1);
        assertEq(word >> 208, 0);
        vm.expectRevert(ExamplePammRouter.QuoteOverflow.selector);
        pool.packQuote(1 << 160, 1);
        vm.expectRevert(ExamplePammRouter.QuoteOverflow.selector);
        pool.packQuote(1, 1 << 48);
        vm.expectRevert(ExamplePammRouter.QuoteOverflow.selector);
        pool.packQuote(0, 1);
    }

    function testBatchSkipsInvalidElement() public {
        PrioUpdateRegistry.Update[] memory ups = new PrioUpdateRegistry.Update[](2);
        ups[0] = PrioUpdateRegistry.Update(address(pool), lane, slots, 1);
        ups[1] = PrioUpdateRegistry.Update(address(otherPool), lane, slots, 1); // maker not authorized there
        vm.prank(maker);
        bool[] memory applied = registry.updateStateBatch(ups);
        assertTrue(applied[0]);
        assertFalse(applied[1]);
    }

    function testDecoderLaneClosesDirectPath() public {
        PassThroughDecoder decoder = new PassThroughDecoder();
        vm.prank(address(pool));
        registry.setDecoder(lane, address(decoder));

        vm.prank(maker);
        vm.expectRevert(PrioUpdateRegistry.DecoderBoundLane.selector);
        registry.updateState(address(pool), lane, slots, 1);

        // Anyone may relay on a decoder lane; the decoder alone decides validity.
        vm.prank(anyone);
        registry.updateStateWithDecoder(address(pool), lane, abi.encode(slots));
        assertEq(pool.quote(address(usdt), address(wbnb), 1_000e18), 1e18);
    }

    function testResetLaneReopensSeq() public {
        uint48 maxSeq = uint48(registry.MAX_SEQ());
        vm.prank(maker);
        registry.updateState(address(pool), lane, slots, maxSeq);
        vm.prank(maker);
        vm.expectRevert(PrioUpdateRegistry.StaleSeq.selector); // lane is stuck at MAX_SEQ
        registry.updateState(address(pool), lane, slots, maxSeq);

        vm.prank(address(pool));
        registry.resetLane(lane);
        assertFalse(pool.isActive(address(usdt), address(wbnb)));

        vm.prank(maker);
        registry.updateState(address(pool), lane, slots, 1);
        assertTrue(pool.isActive(address(usdt), address(wbnb)));
    }

    // =====================================================================
    // BAP-710 §7.2 — PropAMM Pool Interface
    // =====================================================================

    function testQuoteMatchesSwap() public {
        writeQuote(PRICE, block.number + 2, 1);
        uint256 expected = pool.quote(address(usdt), address(wbnb), 1_000e18);
        pushIn(1_000e18);
        uint256 out = pool.swap(address(usdt), address(wbnb), 1_000e18, expected, user, block.number);
        assertEq(out, expected);
        assertEq(wbnb.balanceOf(user), expected);
    }

    function testSwapSlippageAndDeadline() public {
        writeQuote(PRICE, block.number + 2, 1);

        pushIn(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ExamplePammRouter.InsufficientOutput.selector, 1e18, type(uint256).max));
        pool.swap(address(usdt), address(wbnb), 1_000e18, type(uint256).max, user, block.number);

        vm.expectRevert(abi.encodeWithSelector(ExamplePammRouter.SwapExpired.selector, block.number, block.number - 1));
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, user, block.number - 1);
    }

    function testStaleLaneReverts() public {
        writeQuote(PRICE, block.number, 1); // maxBlockNumber = this block
        assertTrue(pool.isActive(address(usdt), address(wbnb)));

        vm.roll(block.number + 1);
        assertFalse(pool.isActive(address(usdt), address(wbnb)));
        vm.expectRevert(ExamplePammRouter.StaleUpdate.selector);
        pool.quote(address(usdt), address(wbnb), 1_000e18);

        pushIn(1_000e18);
        vm.expectRevert(ExamplePammRouter.StaleUpdate.selector);
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, user, 0);
    }

    function testInactiveWithoutQuote() public {
        // What a taker sees on a plain node, or on the txpool fallback path: no quote on chain.
        assertFalse(pool.isActive(address(usdt), address(wbnb)));
        vm.expectRevert(ExamplePammRouter.NoPrice.selector);
        pool.quote(address(usdt), address(wbnb), 1_000e18);
    }

    function testLanesAreDirectional() public {
        writeQuote(PRICE, block.number + 2, 1);
        assertTrue(pool.isActive(address(usdt), address(wbnb)));
        assertFalse(pool.isActive(address(wbnb), address(usdt)));
    }

    function testQuoteNeedsNoBalanceOrAllowance() public {
        writeQuote(PRICE, block.number + 2, 1);
        vm.prank(anyone); // holds nothing, approved nothing
        assertEq(pool.quote(address(usdt), address(wbnb), 1_000e18), 1e18);
    }

    function testGetPairsCanonicalAndUnique() public {
        pool.addPair(address(wbnb), address(usdt));
        IPropAMM.TokenPair[] memory pairs = pool.getPairs();
        assertEq(pairs.length, 1);
        assertLt(uint160(pairs[0].token0), uint160(pairs[0].token1));

        vm.expectRevert(ExamplePammRouter.PairExists.selector);
        pool.addPair(address(usdt), address(wbnb));
    }

    // ---- push-payment accounting ----

    function testSwapRequiresPushedInput() public {
        writeQuote(PRICE, block.number + 2, 1);
        pushIn(999e18);
        vm.expectRevert(abi.encodeWithSelector(ExamplePammRouter.InsufficientInput.selector, 1_000e18, 999e18));
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, user, 0);
    }

    function testSwapBooksPaymentAsInventory() public {
        writeQuote(PRICE, block.number + 2, 1);
        pushIn(1_000e18);
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, user, 0);
        assertEq(pool.reserves(address(usdt)), 1_000e18);
        assertEq(pool.reserves(address(wbnb)), 99e18);

        // The same payment cannot be spent twice.
        vm.expectRevert(abi.encodeWithSelector(ExamplePammRouter.InsufficientInput.selector, 1_000e18, 0));
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, user, 0);
    }

    function testUnsyncedTopUpIsReadAsPayment() public {
        // Inventory transferred in without sync() is indistinguishable from a pushed payment.
        writeQuote(PRICE, block.number + 2, 1);
        usdt.mint(address(pool), 1_000e18);
        vm.prank(anyone);
        pool.swap(address(usdt), address(wbnb), 1_000e18, 0, anyone, 0);
        assertEq(wbnb.balanceOf(anyone), 1e18);
    }

    function testReentrantSwapBlocked() public {
        HookERC20 hookOut = new HookERC20();
        ExamplePammRouter hookPool = new ExamplePammRouter(address(registry));
        hookPool.addMaker(maker);
        hookOut.mint(address(hookPool), 100e18);
        hookPool.sync(address(hookOut));

        uint256[] memory s = new uint256[](1);
        s[0] = hookPool.packQuote(PRICE, block.number + 2);
        uint256 hookLane = hookPool.laneFor(address(usdt), address(hookOut));
        vm.prank(maker);
        registry.updateState(address(hookPool), hookLane, s, 1);

        ReentrantRecipient attacker = new ReentrantRecipient(hookPool, address(usdt), address(hookOut));
        usdt.mint(address(hookPool), 1e18);
        vm.expectRevert(ExamplePammRouter.Reentrancy.selector);
        hookPool.swap(address(usdt), address(hookOut), 1e18, 0, address(attacker), 0);
    }

    // ---- ExamplePammTaker: push and swap in one transaction ----

    function testTakerFillsInOneTx() public {
        writeQuote(PRICE, block.number + 2, 1);
        vm.startPrank(user);
        ExamplePammTaker taker = new ExamplePammTaker();
        usdt.mint(user, 1_000e18);
        usdt.approve(address(taker), 1_000e18);
        uint256 out = taker.swap(pool, address(usdt), address(wbnb), 1_000e18, 1e18, user, block.number);
        vm.stopPrank();

        assertEq(out, 1e18);
        assertEq(wbnb.balanceOf(user), 1e18);
        assertEq(usdt.balanceOf(user), 0);
        assertEq(pool.reserves(address(usdt)), 1_000e18); // nothing left resting as an unbooked push
    }

    function testTakerWithoutQuoteRevertsAtomically() public {
        // Fallback path: the fill executes without the quote update and reverts; the push reverts with it.
        vm.startPrank(user);
        ExamplePammTaker taker = new ExamplePammTaker();
        usdt.mint(user, 1_000e18);
        usdt.approve(address(taker), 1_000e18);
        vm.expectRevert(ExamplePammRouter.NoPrice.selector);
        taker.swap(pool, address(usdt), address(wbnb), 1_000e18, 0, user, 0);
        vm.stopPrank();
        assertEq(usdt.balanceOf(user), 1_000e18);
        assertEq(usdt.balanceOf(address(pool)), 0);
    }

    function testTakerOnlyOwner() public {
        vm.prank(user);
        ExamplePammTaker taker = new ExamplePammTaker();
        vm.prank(anyone);
        vm.expectRevert(ExamplePammTaker.NotOwner.selector);
        taker.swap(pool, address(usdt), address(wbnb), 1, 0, anyone, 0);
    }
}
