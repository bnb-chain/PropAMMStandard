// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PrioUpdateRegistry} from "../PrioUpdateRegistry.sol";
import {ExamplePammRouter} from "../ExamplePammRouter.sol";
import {ExamplePammTaker} from "../ExamplePammTaker.sol";
import {SignedSeqDecoder} from "../SignedSeqDecoder.sol";

/// @notice Deploys the example stack for the e2e. Env:
///   ORACLE              existing PrioUpdateRegistry, or empty/zero to deploy a fresh one
///   MAKER               quoting EOA to authorize as a registry updater (optional)
///   TOKEN_A, TOKEN_B    pair to register for getPairs() (optional)
///   DEPLOY_SIGNED_DECODER=1  also deploy a SignedSeqDecoder for ORACLE (one serves every target of that
///                       registry). Binding a lane to it is permanent, so the script does not do it: call
///                       pool.bindDecoder(tokenIn, tokenOut, decoder) and pool.setSigner(decoder, signer) yourself.
///   DEPLOY_TAKER=1      also deploy ExamplePammTaker; it is owned by the broadcaster, so run
///                       this with the TAKER wallet's key if you want that wallet to fill through it
/// Run with the pool owner's key: `forge script script/Deploy.s.sol --rpc-url $RPC --broadcast`.
/// Fund the pool afterwards: transfer tokenOut to it, then call `sync(tokenOut)`.
contract Deploy is Script {
    function run() external {
        address oracle = vm.envOr("ORACLE", address(0));
        address maker = vm.envOr("MAKER", address(0));
        address tokenA = vm.envOr("TOKEN_A", address(0));
        address tokenB = vm.envOr("TOKEN_B", address(0));
        bool deployTaker = vm.envOr("DEPLOY_TAKER", false);
        bool deployDecoder = vm.envOr("DEPLOY_SIGNED_DECODER", false);

        vm.startBroadcast();
        if (oracle == address(0)) {
            oracle = address(new PrioUpdateRegistry());
            console2.log("PrioUpdateRegistry", oracle);
        }
        ExamplePammRouter pool = new ExamplePammRouter(oracle);
        console2.log("ExamplePammRouter", address(pool));
        if (maker != address(0)) pool.addMaker(maker);
        if (tokenA != address(0) && tokenB != address(0)) pool.addPair(tokenA, tokenB);
        if (deployDecoder) {
            SignedSeqDecoder decoder = new SignedSeqDecoder(PrioUpdateRegistry(oracle));
            console2.log("SignedSeqDecoder", address(decoder));
        }
        if (deployTaker) {
            ExamplePammTaker taker = new ExamplePammTaker();
            console2.log("ExamplePammTaker", address(taker));
        }
        vm.stopBroadcast();
    }
}
