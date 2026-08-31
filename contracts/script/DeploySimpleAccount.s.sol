// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SimpleAccount} from "../src/SimpleAccount.sol";
import {DeployOpcodeLibScript} from "./DeployOpcodeLib.s.sol";

/// @notice Deploys OpcodeLib + a fresh funded SimpleAccount.
/// Usage:
///   forge script script/DeploySimpleAccount.s.sol --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast
contract DeploySimpleAccountScript is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        uint256 fundWei = vm.envOr("FUND_WEI", uint256(0.001 ether));

        address opcodeLib = new DeployOpcodeLibScript().run();

        vm.startBroadcast();

        SimpleAccount account = new SimpleAccount(owner, opcodeLib);
        (bool ok,) = address(account).call{value: fundWei}("");
        require(ok, "funding transfer failed");

        vm.stopBroadcast();

        console.log("opcodeLib:", opcodeLib);
        console.log("account:", address(account));
    }
}
