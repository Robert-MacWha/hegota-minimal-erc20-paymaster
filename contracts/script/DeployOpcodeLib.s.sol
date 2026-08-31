// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

/// @notice Deploys OpcodeLib via CREATE2.
/// Usage:
///   forge script script/DeployOpcodeLib.s.sol --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast
contract DeployOpcodeLibScript is Script {
    bytes32 constant OPCODELIB_SALT = keccak256("SimpleAccount/OpcodeLib");

    function run() external returns (address opcodeLib) {
        // vm.deployCode/getCode both require a non-null ABI in the artifact,
        // which standalone Yul objects don't get, so read the bytecode
        // straight out of the artifact JSON and deploy it manually.
        string memory artifact = vm.readFile("out/OpcodeLib.yul/OpcodeLib.json");
        bytes memory opcodeLibInitcode = vm.parseJsonBytes(artifact, ".bytecode.object");

        address predicted = vm.computeCreate2Address(OPCODELIB_SALT, keccak256(opcodeLibInitcode));

        vm.startBroadcast();

        if (predicted.code.length > 0) {
            opcodeLib = predicted;
        } else {
            bytes32 salt = OPCODELIB_SALT;
            assembly {
                opcodeLib := create2(0, add(opcodeLibInitcode, 0x20), mload(opcodeLibInitcode), salt)
            }
            require(opcodeLib == predicted, "OpcodeLib deployment failed");
        }

        vm.stopBroadcast();

        console.log("opcodeLib:", opcodeLib);
    }
}
