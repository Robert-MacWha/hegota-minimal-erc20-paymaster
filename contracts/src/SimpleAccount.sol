// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FrameOps} from "./FrameOps.sol";

/// @title SimpleAccount
/// @notice Minimal owner-signature-gated custom spender rule for EIP-8141
/// frame transactions.
/// @dev Unlike Simple7702Account, the recovered signer is checked against an
/// immutable `owner` rather than `address(this)`.
contract SimpleAccount {
    using FrameOps for address;

    address public immutable owner;
    address public immutable opcodeLib;

    constructor(address _owner, address _opcodeLib) {
        require(_owner != address(0) && _opcodeLib != address(0), "zero address");
        owner = _owner;
        opcodeLib = _opcodeLib;
    }

    receive() external payable {}

    /// @notice Validate a 65-byte signature (r || s || v) over this frame
    /// tx's sig_hash, and approve execution + payment if it matches
    /// `owner`.
    /// @dev The signature is taken as signatures[0] in the ARBITRARY scheme,
    /// which is excluded from sig_hash so can be referenced without circularity.
    function validate() external {
        bytes memory sig = opcodeLib.sigDataCopy(0, 65, 0);
        require(sig.length == 65, "bad signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        uint256 sigHash = opcodeLib.txParam(0x08); // sig_hash
        address recovered = ecrecover(bytes32(sigHash), v, r, s);
        require(recovered != address(0) && recovered == owner, "bad signature");

        opcodeLib.approve("", FrameOps.Scope.ExecutionAndPayment);
    }
}
