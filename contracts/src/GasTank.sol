// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FrameOps} from "./lib/FrameOps.sol";
import {MerkleTree} from "./lib/MerkleTree.sol";

/// @title GasTank
/// @notice Permissionless ETH gas tank for EIP-8141 frame
/// transactions. Deposits become UTXO-style notes that can be spent by the
/// owner in later transactions.
///
/// @dev Creates a Merkle tree of notes, publishing the current root as a recent root
/// so it's accessible without storage reads in verify frames. When a note is spent:
///
///   (a) the verify frame requires the note's inclusion in the merkle tree,
///   (b) the note is nullified by the transaction's keyed nonce.
///
/// Immediately after a successful verify call, settle can be called to deposit the remaining
/// ETH into a new note for the owner.
///
/// Expected call pattern: verify() -> settle() -> execute()*
contract GasTank {
    using FrameOps for address;
    using MerkleTree for MerkleTree.Tree;

    bytes32 constant SOURCE_SALT = bytes32(0);

    address public immutable opcodeLib;
    uint256 public immutable FEE;
    bytes32 public immutable SOURCE_ID;

    MerkleTree.Tree private tree;

    event Deposit(address indexed owner, uint256 amount, bytes32 salt, uint256 index, bytes32 newRoot);
    event Spend(address indexed owner, uint256 newAmount, bytes32 newSalt, uint256 index, bytes32 newRoot);

    constructor(address _opcodeLib, uint256 _fee) {
        opcodeLib = _opcodeLib;
        FEE = _fee;
        SOURCE_ID = keccak256(abi.encodePacked(address(this), SOURCE_SALT));
    }

    /// Deposits ETH into the GasTank, creating a new note for `owner` with the
    /// given `salt`.
    function deposit(address owner, bytes32 salt) external payable {
        uint256 index = tree.insert(_leaf(owner, msg.value, salt));
        FrameOps.publishRecentRoot(SOURCE_SALT, tree.root);
        emit Deposit(owner, msg.value, salt, index, tree.root);
    }

    /// Verifies that the note can be spent and approves the transaction for payment.
    function verify(
        address owner,
        uint256 amount,
        bytes32 salt,
        uint256 leafIndex,
        bytes32[] calldata proof,
        uint256 rootRefIndex,
        uint256 sigIndex
    ) external {
        _verify(owner, amount, salt, leafIndex, proof, rootRefIndex, sigIndex, FEE);
        _requireSettleThenExecuteFollows(opcodeLib.txParam(0x0A));
        opcodeLib.approve(FrameOps.Scope.ExecutionAndPayment);
    }

    /// Withdraws all ETH from the GasTank to the given address, after verifying that the note can be spent.
    function withdraw(
        address payable to,
        address owner,
        uint256 amount,
        bytes32 salt,
        uint256 leafIndex,
        bytes32[] calldata proof,
        uint256 rootRefIndex,
        uint256 sigIndex
    ) external {
        _verify(owner, amount, salt, leafIndex, proof, rootRefIndex, sigIndex, FEE);

        (bool success,) = to.call{value: amount}("");
        require(success, "GasTank: transfer failed");
    }

    /// Creates a new note for the owner with the remaining balance after a spend,
    /// and publishes the new root.
    function settle(bytes32 newSalt) external {
        uint256 prevIndex = opcodeLib.txParam(0x0A) - 1;
        require(opcodeLib.frameParam(prevIndex, 0) == uint256(uint160(address(this))), "GasTank: prior frame target");
        require(opcodeLib.frameParam(prevIndex, 2) == 1, "GasTank: prior frame not VERIFY");
        require(
            bytes4(bytes32(opcodeLib.frameDataLoad(0, prevIndex))) == this.verify.selector,
            "GasTank: prior frame not verify()"
        );

        address owner = address(uint160(opcodeLib.frameDataLoad(4, prevIndex)));
        uint256 amount = opcodeLib.frameDataLoad(36, prevIndex);

        uint256 newAmount = amount - opcodeLib.txParam(0x06) - FEE;
        uint256 index = tree.insert(_leaf(owner, newAmount, newSalt));
        FrameOps.publishRecentRoot(SOURCE_SALT, tree.root);
        emit Spend(owner, newAmount, newSalt, index, tree.root);
    }

    /// Executes a value-less call to `target` with `data`.
    function execute(address target, bytes calldata data) external {
        (bool success,) = target.call(data);
        require(success, "GasTank: execute failed");
    }

    /// Publishes the current Merkle root of the GasTank's note tree as a recent root.
    ///
    /// @dev Can be used if the tree's root has timed out of the recent roots.
    function refreshRoot() external {
        FrameOps.publishRecentRoot(SOURCE_SALT, tree.root);
    }

    /// Returns the current Merkle root of the GasTank's note tree.
    function root() external view returns (bytes32) {
        return tree.root;
    }

    /// Returns the next leaf index that will be used for a new deposit.
    function nextLeafIndex() external view returns (uint256) {
        return tree.nextLeafIndex;
    }

    /// Verifies that the note can be spent, and that the transaction is authorized to spend it.
    function _verify(
        address owner,
        uint256 amount,
        bytes32 salt,
        uint256 leafIndex,
        bytes32[] calldata proof,
        uint256 rootRefIndex,
        uint256 sigIndex,
        uint256 fee
    ) private {
        bytes32 leaf = _leaf(owner, amount, salt);

        require(opcodeLib.sigParam(sigIndex, 0) == uint256(uint160(owner)), "GasTank: bad signature");
        require(opcodeLib.sigParam(sigIndex, 2) == 0, "GasTank: signature must cover whole tx");

        require(opcodeLib.recentRootRefLoad(0, rootRefIndex) == uint256(SOURCE_ID), "GasTank: wrong root source");
        bytes32 refRoot = bytes32(opcodeLib.recentRootRefLoad(2, rootRefIndex));
        require(MerkleTree.verifyProof(leaf, leafIndex, proof, refRoot), "GasTank: bad proof");

        uint256 maxCost = opcodeLib.txParam(0x06);
        require(amount >= maxCost + fee, "GasTank: insufficient note balance");

        require(opcodeLib.nonceKeyLoad(0) == uint256(leaf), "GasTank: note not nullified");
    }

    /// Requires that the frames after `selfIndex` are allowed frames.
    function _requireSettleThenExecuteFollows(uint256 selfIndex) private {
        uint256 frameCount = opcodeLib.txParam(0x09);
        require(frameCount > selfIndex + 1, "GasTank: settle frame missing");
        _requireFrameIs(selfIndex + 1, this.settle.selector);

        for (uint256 i = selfIndex + 2; i < frameCount; i++) {
            _requireFrameIs(i, this.execute.selector);
        }
    }

    /// Requires that the frame at `frameIndex` targets this contract and calls `selector`.
    function _requireFrameIs(uint256 frameIndex, bytes4 selector) private {
        require(
            opcodeLib.frameParam(frameIndex, 0) == uint256(uint160(address(this))), "GasTank: restricted frame target"
        );
        require(
            bytes4(bytes32(opcodeLib.frameDataLoad(0, frameIndex))) == selector, "GasTank: restricted frame selector"
        );
    }

    /// Computes the Merkle leaf for a given note.
    function _leaf(address owner, uint256 amount, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, amount, salt));
    }
}
