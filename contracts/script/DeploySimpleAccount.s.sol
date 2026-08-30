// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SimpleAccount} from "../src/SimpleAccount.sol";

/// @notice Deploys OpcodeLib (via CREATE2, so its address is stable and the
///         same deployment is reused on repeat runs instead of duplicated) +
///         a fresh SimpleAccount, and funds it (see `SimpleAccount.receive`
///         for why it needs a balance).
///
/// Env: OWNER (address whose signature SimpleAccount will require over each
///      frame tx's sig_hash), PRIVATE_KEY (also used as the CREATE2 deployer
///      address for OpcodeLib - must match the key passed to --private-key),
///      FUND_WEI (optional, default 0.001 ETH - keep this small on a real
///      devnet balance).
/// Usage:
///   forge script script/DeploySimpleAccount.s.sol --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast
contract DeploySimpleAccountScript is Script {
    bytes32 constant OPCODELIB_SALT = keccak256("SimpleAccount/OpcodeLib");

    function run() external {
        address owner = vm.envAddress("OWNER");
        uint256 fundWei = vm.envOr("FUND_WEI", uint256(0.001 ether));

        // vm.deployCode/getCode both require a non-null ABI in the artifact,
        // which standalone Yul objects don't get, so read the bytecode
        // straight out of the artifact JSON and deploy it manually.
        string memory artifact = vm.readFile("out/OpcodeLib.yul/OpcodeLib.json");
        bytes memory opcodeLibInitcode = vm.parseJsonBytes(artifact, ".bytecode.object");

        // The 2-arg overload assumes the standard CREATE2 deployer proxy,
        // which is also what forge's broadcaster routes a script's own
        // `create2` through - not the EOA broadcaster address directly.
        address predicted = vm.computeCreate2Address(OPCODELIB_SALT, keccak256(opcodeLibInitcode));

        vm.startBroadcast();

        address opcodeLib;
        if (predicted.code.length > 0) {
            // Same salt + same bytecode already deployed - reuse it rather
            // than reverting on a CREATE2 collision.
            opcodeLib = predicted;
        } else {
            bytes32 salt = OPCODELIB_SALT;
            assembly {
                opcodeLib := create2(0, add(opcodeLibInitcode, 0x20), mload(opcodeLibInitcode), salt)
            }
            require(opcodeLib == predicted, "OpcodeLib deployment failed");
        }

        SimpleAccount account = new SimpleAccount(owner, opcodeLib);
        (bool ok,) = address(account).call{value: fundWei}("");
        require(ok, "funding transfer failed");

        vm.stopBroadcast();

        console.log("opcodeLib:", opcodeLib);
        console.log("account:", address(account));
    }
}
