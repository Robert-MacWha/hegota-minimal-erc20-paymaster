// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MerkleTree
/// @notice Pure incremental append-only Merkle tree math.
library MerkleTree {
    uint256 internal constant DEPTH = 20;

    struct Tree {
        bytes32[DEPTH] filledSubtrees;
        uint256 nextLeafIndex;
        bytes32 root;
    }

    function insert(Tree storage self, bytes32 leaf) internal returns (uint256 index) {
        index = self.nextLeafIndex;
        require(index < 2 ** DEPTH, "MerkleTree: tree full");

        bytes32[DEPTH] memory zeros_ = zeros();
        uint256 idx = index;
        bytes32 currentHash = leaf;
        for (uint256 i = 0; i < DEPTH; i++) {
            if (idx % 2 == 0) {
                self.filledSubtrees[i] = currentHash;
                currentHash = keccak256(abi.encodePacked(currentHash, zeros_[i]));
            } else {
                currentHash = keccak256(abi.encodePacked(self.filledSubtrees[i], currentHash));
            }
            idx /= 2;
        }

        self.root = currentHash;
        self.nextLeafIndex = index + 1;
    }

    function verifyProof(bytes32 leaf, uint256 index, bytes32[] memory proof, bytes32 expectedRoot)
        internal
        pure
        returns (bool)
    {
        require(proof.length == DEPTH, "MerkleTree: bad proof length");
        bytes32 hash = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < DEPTH; i++) {
            if (idx % 2 == 0) {
                hash = keccak256(abi.encodePacked(hash, proof[i]));
            } else {
                hash = keccak256(abi.encodePacked(proof[i], hash));
            }
            idx /= 2;
        }
        return hash == expectedRoot;
    }

    function zeros() private pure returns (bytes32[DEPTH] memory zeros_) {
        zeros_[0] = bytes32(0);
        for (uint256 i = 1; i < DEPTH; i++) {
            zeros_[i] = keccak256(abi.encodePacked(zeros_[i - 1], zeros_[i - 1]));
        }
    }
}
