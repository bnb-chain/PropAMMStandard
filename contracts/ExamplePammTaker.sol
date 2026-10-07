// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPropAMM} from "./IPropAMM.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title ExamplePammTaker
/// @notice Minimal taker for push-payment PropAMM pools ({IPropAMM}): pushes
///         `amountIn` of `tokenIn` into the pool and calls its `swap` in ONE
///         transaction, so a plain wallet never leaves a pushed balance sitting
///         on the pool between two transactions.
///
///         Flow of `swap`:
///           1. `transferFrom(msg.sender, pool, amountIn)` — the caller has
///              approved this contract for `tokenIn`; the tokens go straight to
///              the pool, this contract never holds them;
///           2. `pool.swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient, maxBlockNumber)`
///              — the pool consumes the pushed balance and pays `tokenOut` to
///              `recipient` directly;
///           3. the delivered amount is re-checked as a balance delta on
///              `recipient` (the pool checks `minAmountOut` too; this is belt
///              and braces against a pool that lies about `amountOut`).
///
///         Because this contract is `msg.sender` of the pool call, a pool with a
///         taker allowlist (like the 48club PammRouter's `setTaker`) has to
///         allowlist THIS contract. To keep that allowlisting meaningful, `swap`
///         is restricted to the deployer (`owner`): allowlisting the contract
///         then opens the pool to exactly one wallet, not to everyone. Drop the
///         `onlyOwner` check for a shared, permissionless taker.
///
///         Submitted through the relayer's `eth_sendRawTransaction`, the single
///         tx reads the pool's quoted slot and is bundled behind the owning
///         quote tx like any other fill; on the fallback path it executes
///         without the quote and reverts (NoPrice / NoQuote), leaving nothing
///         on the pool.
contract ExamplePammTaker {
    error NotOwner();
    error TransferFailed();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    /// @notice The only wallet allowed to fill through this contract (the deployer).
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice One fill routed through this contract.
    event Filled(
        address indexed sender,
        address indexed pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    /// @notice Pushes `amountIn` of `tokenIn` from `msg.sender` into `pool` and
    ///         swaps it for `tokenOut`, delivered to `recipient`.
    /// @dev Requires `msg.sender` to have approved this contract for at least
    ///      `amountIn` of `tokenIn`. `maxBlockNumber` is passed through to the
    ///      pool (0 = no caller deadline on the example pools).
    function swap(
        IPropAMM pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 maxBlockNumber
    ) external returns (uint256 amountOut) {
        if (msg.sender != owner) revert NotOwner();
        if (!IERC20(tokenIn).transferFrom(msg.sender, address(pool), amountIn)) revert TransferFailed();

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(recipient);
        amountOut = pool.swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient, maxBlockNumber);
        uint256 delivered = IERC20(tokenOut).balanceOf(recipient) - balanceBefore;
        if (delivered < minAmountOut) revert InsufficientOutput(delivered, minAmountOut);

        emit Filled(msg.sender, address(pool), tokenIn, tokenOut, amountIn, amountOut, recipient);
    }
}
