// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal ERC-1271 smart-contract wallet for tests. `isValidSignature`
///         returns the EIP-1271 magic value iff the signature ECDSA-recovers to
///         `owner`. Mirrors how a real smart account (e.g. Privy) validates a
///         signature it produced. Implements `onERC721Received` so it can hold
///         the soulbound Pass NFT minted when it joins / creates a tanda — as a
///         real smart-account wallet does.
contract ERC1271Wallet {
    bytes4 internal constant MAGIC = 0x1626ba7e; // bytes4(keccak256("isValidSignature(bytes32,bytes)"))

    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return MAGIC;
        }
        return 0xffffffff;
    }

    /// @dev ERC-721 receiver hook — returns its selector so `_safeMint` to this
    ///      wallet succeeds (the Pass NFT is soulbound; it just needs to land).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
