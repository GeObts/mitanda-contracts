// SPDX-License-Identifier: MIT
pragma solidity =0.8.20 ^0.8.20;

// lib/openzeppelin-contracts/contracts/utils/Address.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error AddressInsufficientBalance(address account);

    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert AddressInsufficientBalance(address(this));
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedInnerCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {FailedInnerCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert AddressInsufficientBalance(address(this));
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {FailedInnerCall}) in case of an
     * unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {FailedInnerCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {FailedInnerCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/cryptography/ECDSA.sol)

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    /**
     * @dev The signature derives the `address(0)`.
     */
    error ECDSAInvalidSignature();

    /**
     * @dev The signature has an invalid length.
     */
    error ECDSAInvalidSignatureLength(uint256 length);

    /**
     * @dev The signature has an S value that is in the upper half order.
     */
    error ECDSAInvalidSignatureS(bytes32 s);

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with `signature` or an error. This will not
     * return address(0) without also returning an error description. Errors are documented using an enum (error type)
     * and a bytes32 providing additional information about the error.
     *
     * If no error is returned, then the address can be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError, bytes32) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, signature);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     */
    function tryRecover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address, RecoverError, bytes32) {
        unchecked {
            bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            // We do not check for an overflow here since the shift operation results in 0 or 1.
            uint8 v = uint8((uint256(vs) >> 255) + 27);
            return tryRecover(hash, v, r, s);
        }
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     */
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, r, vs);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError, bytes32) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }

        return (signer, RecoverError.NoError, bytes32(0));
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, v, r, s);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Optionally reverts with the corresponding custom error according to the `error` argument provided.
     */
    function _throwError(RecoverError error, bytes32 errorArg) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert ECDSAInvalidSignature();
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert ECDSAInvalidSignatureLength(uint256(errorArg));
        } else if (error == RecoverError.InvalidSignatureS) {
            revert ECDSAInvalidSignatureS(errorArg);
        }
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC1271.sol)

/**
 * @dev Interface of the ERC1271 standard signature validation method for
 * contracts as defined in https://eips.ethereum.org/EIPS/eip-1271[ERC-1271].
 */
interface IERC1271 {
    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param hash      Hash of the data to be signed
     * @param signature Signature byte array associated with _data
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/IERC20Permit.sol)

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 *
 * ==== Security Considerations
 *
 * There are two important considerations concerning the use of `permit`. The first is that a valid permit signature
 * expresses an allowance, and it should not be assumed to convey additional meaning. In particular, it should not be
 * considered as an intention to spend the allowance in any specific way. The second is that because permits have
 * built-in replay protection and can be submitted by anyone, they can be frontrun. A protocol that uses permits should
 * take this into consideration and allow a `permit` call to fail. Combining these two aspects, a pattern that may be
 * generally recommended is:
 *
 * ```solidity
 * function doThingWithPermit(..., uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
 *     try token.permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
 *     doThing(..., value);
 * }
 *
 * function doThing(..., uint256 value) public {
 *     token.safeTransferFrom(msg.sender, address(this), value);
 *     ...
 * }
 * ```
 *
 * Observe that: 1) `msg.sender` is used as the owner, leaving no ambiguity as to the signer intent, and 2) the use of
 * `try/catch` allows the permit to fail and makes the code tolerant to frontrunning. (See also
 * {SafeERC20-safeTransferFrom}).
 *
 * Additionally, note that smart contract wallets (such as Argent or Safe) are not able to produce permit signatures, so
 * contracts should have entry points that don't rely on permit.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     *
     * CAUTION: See Security Considerations above.
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC5267.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC5267.sol)

interface IERC5267 {
    /**
     * @dev MAY be emitted to signal that the domain could have changed.
     */
    event EIP712DomainChanged();

    /**
     * @dev returns the fields and values that describe the domain separator used by this contract for EIP-712
     * signature.
     */
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}

// src/interfaces/ITanda.sol

/// @title  ITanda
/// @author Mi Tanda
/// @notice Minimal interface exposing the entry points `TandaManager`
///         needs to call into a `Tanda` clone, plus the shared
///         `TandaPrivacy` enum and `InitParams` struct.
/// @dev    Each `Tanda` is an EIP-1167 clone of a single implementation
///         contract. The implementation's constructor calls
///         `_disableInitializers()`; per-clone state is set via
///         `initialize(...)` immediately after `Clones.clone(...)`.
interface ITanda {
    /// @notice Membership policy for a tanda.
    /// @dev    PUBLIC: anyone may call `join()`.
    ///         PRIVATE_TICKETED: only invitees holding a creator-signed
    ///         EIP-712 invite may call `joinWithInvite(deadline, signature)`.
    enum TandaPrivacy {
        PUBLIC,
        PRIVATE_TICKETED
    }

    /// @notice One-shot initializer parameters. Passed by
    ///         `TandaManager.createTanda` immediately after cloning.
    /// @dev    Grouped into a struct because the parameter set is large;
    ///         keeps the call site readable and lets us add fields
    ///         without changing the public selector layout.
    /// @param tandaId               Monotonic ID assigned by the Manager.
    /// @param token                 ERC-20 used for contributions, payouts,
    ///                              insurance premiums, and fee transfers.
    /// @param contributionAmount    Per-cycle base contribution, in `token`
    ///                              base units. Premium is layered on top
    ///                              automatically (10% of this amount).
    /// @param payoutInterval        Seconds between consecutive payouts.
    /// @param participantCount      Number of seats; also the original
    ///                              count of payout cycles.
    /// @param gracePeriod           Seconds after a cycle's deadline during
    ///                              which a late contributor is still
    ///                              recoverable. Past this window,
    ///                              `markDefaulter` becomes callable.
    /// @param manager               Address of the deploying `TandaManager`.
    /// @param creator               The tanda's organizer / signer of invites.
    /// @param sponsoredCollectionId Snapshot of the Manager's active
    ///                              collection ID at creation time. `0` is
    ///                              permitted (go-dark mode).
    /// @param scheduledStart        Earliest block timestamp at which the
    ///                              tanda may transition to ACTIVE. `0`
    ///                              means "start immediately when full".
    ///                              Positive values must satisfy
    ///                              `>= block.timestamp + 1 days` (validated
    ///                              by Manager).
    /// @param privacy               Membership policy. PUBLIC or
    ///                              PRIVATE_TICKETED.
    struct InitParams {
        uint256 tandaId;
        address token;
        uint256 contributionAmount;
        uint256 payoutInterval;
        uint16 participantCount;
        uint256 gracePeriod;
        address manager;
        address creator;
        uint256 sponsoredCollectionId;
        uint256 scheduledStart;
        TandaPrivacy privacy;
        /// @custom:doc passNFT       Soulbound Pass NFT singleton.
        ///                           Auto-minted on `join` /
        ///                           `joinWithInvite`; flagged on
        ///                           `markDefaulter`.
        address passNFT;
        /// @custom:doc receiptNFT    Transferable Receipt NFT singleton.
        ///                           Minted on each cycle payout with
        ///                           frozen-at-mint sponsored metadata.
        address receiptNFT;
        /// @custom:doc completionNFT Soulbound Completion NFT singleton.
        ///                           Batch-minted at tanda completion
        ///                           to every still-active participant.
        address completionNFT;
    }

    /// @notice One-shot initializer called by `TandaManager.createTanda`
    ///         immediately after cloning. Guarded by OZ v5's `initializer`
    ///         modifier on the implementation, so it can only run once per
    ///         clone.
    function initialize(InitParams calldata params) external;

    /// @notice Delivers a VRF-resolved random seed to the Tanda so it can
    ///         compute its payout order.
    /// @dev    Called from `TandaManager.fulfillRandomWords` after the
    ///         Chainlink VRF v2.5 coordinator delivers randomness for this
    ///         tanda. The Tanda guards this entry point with its
    ///         `onlyManager` modifier.
    /// @param randomSeed Random seed used to derive the payout order.
    function assignPayoutOrder(uint256 randomSeed) external;

    /// @notice Enroll the tanda's creator as the first participant at
    ///         creation (charge-at-create). Called once by
    ///         `TandaManager.createTanda` AFTER it has transferred the
    ///         creator's first contribution + insurance premium into the
    ///         clone — so the Tanda only records state and mints the Pass
    ///         NFT; it does NOT pull funds itself. Guarded by `onlyManager`.
    /// @param creator The tanda's creator (the `createTanda` caller).
    function enrollCreator(address creator) external;
}

// lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (proxy/utils/Initializable.sol)

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```solidity
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 *
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Storage of the initializable contract.
     *
     * It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions
     * when using with upgradeable contracts.
     *
     * @custom:storage-location erc7201:openzeppelin.storage.Initializable
     */
    struct InitializableStorage {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        uint64 _initialized;
        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /**
     * @dev The contract is already initialized.
     */
    error InvalidInitialization();

    /**
     * @dev The contract is not initializing.
     */
    error NotInitializing();

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint64 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that in the context of a constructor an `initializer` may be invoked any
     * number of times. This behavior in the constructor can be useful during testing and is not expected to be used in
     * production.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        // Cache values to avoid duplicated sloads
        bool isTopLevelCall = !$._initializing;
        uint64 initialized = $._initialized;

        // Allowed calls:
        // - initialSetup: the contract is not in the initializing state and no previous version was
        //                 initialized
        // - construction: the contract is initialized at version 1 (no reininitialization) and the
        //                 current contract is just being deployed
        bool initialSetup = initialized == 0 && isTopLevelCall;
        bool construction = initialized == 1 && address(this).code.length == 0;

        if (!initialSetup && !construction) {
            revert InvalidInitialization();
        }
        $._initialized = 1;
        if (isTopLevelCall) {
            $._initializing = true;
        }
        _;
        if (isTopLevelCall) {
            $._initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: Setting the version to 2**64 - 1 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint64 version) {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    /**
     * @dev Reverts if the contract is not in an initializing state. See {onlyInitializing}.
     */
    function _checkInitializing() internal view virtual {
        if (!_isInitializing()) {
            revert NotInitializing();
        }
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing) {
            revert InvalidInitialization();
        }
        if ($._initialized != type(uint64).max) {
            $._initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint64) {
        return _getInitializableStorage()._initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _getInitializableStorage()._initializing;
    }

    /**
     * @dev Returns a pointer to the storage namespace.
     */
    // solhint-disable-next-line var-name-mixedcase
    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/math/Math.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// src/MitandaErrors.sol

/// @title  MitandaErrors
/// @author Mi Tanda
/// @notice Single source of truth for every custom error used across the
///         Mi Tanda system. No contract in `src/` may use require-strings;
///         every revert must reference an error declared here.
/// @dev    File-level errors — import directly with
///         `import "./MitandaErrors.sol";` and use `revert ErrorName(args);`
///         from any contract.
///
///         Errors provided by OpenZeppelin v5 (Ownable, Pausable,
///         ReentrancyGuard, ERC721, etc.) are NOT redefined here — those
///         contracts surface their own errors and we let them through.

// ─────────────────────────────────────────────────────────────────────────────
// Shared — used by multiple contracts
// ─────────────────────────────────────────────────────────────────────────────

/// @notice An address argument was the zero address where non-zero is required.
error ZeroAddress();

/// @notice A numeric argument was zero where a positive value is required.
error ZeroAmount();

/// @notice Caller is not a Tanda contract registered in the Manager.
/// @dev    Used by NFT contracts' `onlyTanda` modifier. The modifier looks
///         up `msg.sender` in `TandaManager.tandaIdToAddress` and reverts
///         with this error if no match is found.
error CallerNotTanda();

/// @notice Caller is not the `TandaManager` contract.
/// @dev    Used by `Tanda.onlyManager` (e.g. VRF callback delivery from
///         the Manager).
error CallerNotManager();

/// @notice Caller is not the creator of this tanda.
/// @dev    Used by `Tanda.revokeInvite`.
error NotCreator();

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — token allowlist
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Token is not on the allowlist; cannot be used for new tandas.
error TokenNotAllowlisted(address token);

/// @notice Token is already on the allowlist; cannot add twice.
error TokenAlreadyAllowlisted(address token);

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — sponsored collection registry
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Royalty basis points exceeds the configured cap.
/// @param actual Submitted royalty value.
/// @param max    Hard cap (1000 = 10%).
error RoyaltyTooHigh(uint96 actual, uint96 max);

/// @notice Sponsored collection ID does not exist in the registry.
/// @dev    ID 0 is reserved as "unset" and will always trip this error
///         when passed to a function that requires an existing collection
///         (registerCollection assigns from 1 upward; setActiveCollection
///         rejects 0 — use clearActiveCollection() to enter no-sponsor mode).
error UnknownCollection(uint256 collectionId);

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — tanda factory parameter validation
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Tanda ID does not exist in the Manager registry.
error UnknownTanda(uint256 tandaId);

/// @notice Contribution amount is below the configured minimum.
error ContributionTooLow(uint256 actual, uint256 minimum);

/// @notice Payout interval is outside the allowed `[min, max]` range.
error PayoutIntervalOutOfRange(uint256 actual, uint256 min, uint256 max);

/// @notice Participant count is outside the allowed `[min, max]` range.
error ParticipantCountOutOfRange(uint16 actual, uint16 min, uint16 max);

/// @notice Grace period is outside the allowed `[min, max]` range.
error GracePeriodOutOfRange(uint256 actual, uint256 min, uint256 max);

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — state machine
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Tanda state does not match what the action requires.
/// @param expected Required state code (0=OPEN, 1=ACTIVE, 2=COMPLETED).
/// @param actual   State code at call time.
error WrongTandaState(uint8 expected, uint8 actual);

/// @notice Tanda has already reached its participant cap.
error TandaFull();

/// @notice Caller is already a participant of this tanda.
error AlreadyJoined();

/// @notice Caller is not a participant of this tanda.
/// @dev    Distinct from `DefaultedParticipant` so frontends can show
///         the right message ("you're not in this tanda" vs. "you were
///         marked defaulter and lost your seat").
error NotParticipant();

/// @notice Caller (or `participant` argument) joined the tanda but was
///         marked as a defaulter. Their seat is forfeited; insurance
///         has been moved to the slash pool.
error DefaultedParticipant();

/// @notice `markDefaulter` was called on a participant who is paid up.
error NotDefaulter(address participant);

/// @notice `markDefaulter` was called on a participant already marked.
error AlreadyMarkedDefaulter(address participant);

/// @notice `markDefaulter` was called before the grace period expired.
/// @param currentTime Block timestamp at call time.
/// @param expiresAt   Earliest timestamp at which the default is enforceable.
error GracePeriodNotExpired(uint256 currentTime, uint256 expiresAt);

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — scheduled start
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Scheduled start is positive but earlier than the minimum
///         lead time (`block.timestamp + 1 days`).
/// @param provided Submitted scheduled-start timestamp.
/// @param earliest Earliest accepted timestamp.
error ScheduledStartTooSoon(uint256 provided, uint256 earliest);

/// @notice `start()` was called before the scheduled-start timestamp.
/// @param currentTime    Block timestamp at call time.
/// @param scheduledStart Required earliest start time.
error ScheduledStartNotReached(uint256 currentTime, uint256 scheduledStart);

/// @notice `start()` was called while the tanda still has empty seats.
error TandaNotFull();

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — privacy & invite tickets
// ─────────────────────────────────────────────────────────────────────────────

/// @notice `join()` was called on a `PRIVATE_TICKETED` tanda. Use
///         `joinWithInvite(deadline, signature)` instead.
error NotPublicTanda();

/// @notice `joinWithInvite(...)` was called on a `PUBLIC` tanda. Use
///         `join()` instead.
error NotPrivateTanda();

/// @notice The invite's deadline has passed.
/// @param currentTime Block timestamp at call time.
/// @param deadline    Invite's expiration timestamp.
error InviteExpired(uint256 currentTime, uint256 deadline);

/// @notice The recovered EIP-712 signer is not the tanda creator.
error InviteSignerNotCreator();

/// @notice This invite ticket has already been redeemed.
error TicketAlreadyUsed();

/// @notice This invite ticket was revoked by the creator.
error InviteAlreadyRevoked();

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — payments & payouts
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Requested cycles to pay exceeds remaining unpaid cycles.
error CyclesOutOfRange(uint256 requested, uint256 maxAllowed);

/// @notice The payout time for the current cycle has not yet been reached.
/// @param currentTime Block timestamp at call time.
/// @param readyAt     Earliest block timestamp the payout is permitted.
error PayoutNotReady(uint256 currentTime, uint256 readyAt);

/// @notice Payout order has not yet been assigned by the VRF callback.
error PayoutOrderNotAssigned();

/// @notice Payout order has already been assigned; cannot reassign.
error PayoutOrderAlreadyAssigned();

/// @notice One or more participants is in default for the current cycle.
/// @dev    Detected by automatic timing-based defaulter logic. Payout is
///         blocked until the default is resolved (slash or grace-period
///         catch-up).
error DefaultersOutstanding();

/// @notice The pull-payment balance for the caller is zero.
error NothingToClaim();

/// @notice The contract holds less than the requested amount.
/// @param needed    Required amount.
/// @param available Current contract balance of the relevant token.
error InsufficientContractBalance(uint256 needed, uint256 available);

// ─────────────────────────────────────────────────────────────────────────────
// NFTs — Pass, Completion, Receipt
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Transfer attempted on a soulbound token (EIP-5192 locked).
/// @dev    Used by `MitandaPassNFT` and `MitandaCompletionNFT`. All
///         transfer, safeTransfer, and approval functions revert with
///         this error.
error SoulboundTransferDisabled();

/// @notice A pass NFT has already been minted for this `(participant, tandaId)` pair.
error PassAlreadyMinted(address participant, uint256 tandaId);

/// @notice A completion NFT has already been minted for this
///         `(participant, tandaId)` pair.
error CompletionAlreadyMinted(address participant, uint256 tandaId);

/// @notice Receipt NFT mint referenced a collection ID that doesn't
///         exist in the Manager's registry.
/// @dev    Distinct from `UnknownCollection` (Manager-emitted) so the
///         frontend can tell the NFT contract apart from the Manager.
error ReceiptCollectionNotFound(uint256 collectionId);

/// @notice Default fallback baseURI on the Receipt NFT was empty.
/// @dev    Used by `MitandaReceiptNFT`'s constructor and
///         `setDefaultFallbackBaseURI`. Distinct from `ZeroAddress` —
///         this is about string content, not an address.
error EmptyBaseURI();

// lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/SignedMath.sol)

/**
 * @dev Standard signed math utilities missing in the Solidity language.
 */
library SignedMath {
    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // must be unchecked in order to support `n = type(int256).min`
            return uint256(n >= 0 ? n : -n);
        }
    }
}

// lib/openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /// @custom:storage-location erc7201:openzeppelin.storage.ReentrancyGuard
    struct ReentrancyGuardStorage {
        uint256 _status;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ReentrancyGuardStorageLocation = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function _getReentrancyGuardStorage() private pure returns (ReentrancyGuardStorage storage $) {
        assembly {
            $.slot := ReentrancyGuardStorageLocation
        }
    }

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if ($._status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        $._status = ENTERED;
    }

    function _nonReentrantAfter() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        return $._status == ENTERED;
    }
}

// lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/cryptography/SignatureChecker.sol)

/**
 * @dev Signature verification helper that can be used instead of `ECDSA.recover` to seamlessly support both ECDSA
 * signatures from externally owned accounts (EOAs) as well as ERC1271 signatures from smart contract wallets like
 * Argent and Safe Wallet (previously Gnosis Safe).
 */
library SignatureChecker {
    /**
     * @dev Checks if a signature is valid for a given signer and data hash. If the signer is a smart contract, the
     * signature is validated against that smart contract using ERC1271, otherwise it's validated using `ECDSA.recover`.
     *
     * NOTE: Unlike ECDSA signatures, contract signatures are revocable, and the outcome of this function can thus
     * change through time. It could return true at block N and false at block N+1 (or the opposite).
     */
    function isValidSignatureNow(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(hash, signature);
        return
            (error == ECDSA.RecoverError.NoError && recovered == signer) ||
            isValidERC1271SignatureNow(signer, hash, signature);
    }

    /**
     * @dev Checks if a signature is valid for a given signer and data hash. The signature is validated
     * against the signer smart contract using ERC1271.
     *
     * NOTE: Unlike ECDSA signatures, contract signatures are revocable, and the outcome of this function can thus
     * change through time. It could return true at block N and false at block N+1 (or the opposite).
     */
    function isValidERC1271SignatureNow(
        address signer,
        bytes32 hash,
        bytes memory signature
    ) internal view returns (bool) {
        (bool success, bytes memory result) = signer.staticcall(
            abi.encodeCall(IERC1271.isValidSignature, (hash, signature))
        );
        return (success &&
            result.length >= 32 &&
            abi.decode(result, (bytes32)) == bytes32(IERC1271.isValidSignature.selector));
    }
}

// lib/openzeppelin-contracts/contracts/utils/Strings.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Strings.sol)

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    uint8 private constant ADDRESS_LENGTH = 20;

    /**
     * @dev The `value` string doesn't fit in the specified `length`.
     */
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), HEX_DIGITS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `int256` to its ASCII `string` decimal representation.
     */
    function toStringSigned(int256 value) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "", toString(SignedMath.abs(value)));
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) {
            revert StringsInsufficientHexLength(value, length);
        }
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal
     * representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), ADDRESS_LENGTH);
    }

    /**
     * @dev Returns true if the two strings are equal.
     */
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/cryptography/MessageHashUtils.sol)

/**
 * @dev Signature message hash utilities for producing digests to be consumed by {ECDSA} recovery or signing.
 *
 * The library provides methods for generating a hash of a message that conforms to the
 * https://eips.ethereum.org/EIPS/eip-191[EIP 191] and https://eips.ethereum.org/EIPS/eip-712[EIP 712]
 * specifications.
 */
library MessageHashUtils {
    /**
     * @dev Returns the keccak256 digest of an EIP-191 signed data with version
     * `0x45` (`personal_sign` messages).
     *
     * The digest is calculated by prefixing a bytes32 `messageHash` with
     * `"\x19Ethereum Signed Message:\n32"` and hashing the result. It corresponds with the
     * hash signed when using the https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`] JSON-RPC method.
     *
     * NOTE: The `messageHash` parameter is intended to be the result of hashing a raw message with
     * keccak256, although any bytes32 value can be safely used because the final digest will
     * be re-hashed.
     *
     * See {ECDSA-recover}.
     */
    function toEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32 digest) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, "\x19Ethereum Signed Message:\n32") // 32 is the bytes-length of messageHash
            mstore(0x1c, messageHash) // 0x1c (28) is the length of the prefix
            digest := keccak256(0x00, 0x3c) // 0x3c is the length of the prefix (0x1c) + messageHash (0x20)
        }
    }

    /**
     * @dev Returns the keccak256 digest of an EIP-191 signed data with version
     * `0x45` (`personal_sign` messages).
     *
     * The digest is calculated by prefixing an arbitrary `message` with
     * `"\x19Ethereum Signed Message:\n" + len(message)` and hashing the result. It corresponds with the
     * hash signed when using the https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`] JSON-RPC method.
     *
     * See {ECDSA-recover}.
     */
    function toEthSignedMessageHash(bytes memory message) internal pure returns (bytes32) {
        return
            keccak256(bytes.concat("\x19Ethereum Signed Message:\n", bytes(Strings.toString(message.length)), message));
    }

    /**
     * @dev Returns the keccak256 digest of an EIP-191 signed data with version
     * `0x00` (data with intended validator).
     *
     * The digest is calculated by prefixing an arbitrary `data` with `"\x19\x00"` and the intended
     * `validator` address. Then hashing the result.
     *
     * See {ECDSA-recover}.
     */
    function toDataWithIntendedValidatorHash(address validator, bytes memory data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"19_00", validator, data));
    }

    /**
     * @dev Returns the keccak256 digest of an EIP-712 typed data (EIP-191 version `0x01`).
     *
     * The digest is calculated from a `domainSeparator` and a `structHash`, by prefixing them with
     * `\x19\x01` and hashing the result. It corresponds to the hash signed by the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`] JSON-RPC method as part of EIP-712.
     *
     * See {ECDSA-recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32 digest) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, hex"19_01")
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    /**
     * @dev An operation with an ERC20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data);
        if (returndata.length != 0 && !abi.decode(returndata, (bool))) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool))) && address(token).code.length > 0;
    }
}

// lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/cryptography/EIP712.sol)

/**
 * @dev https://eips.ethereum.org/EIPS/eip-712[EIP 712] is a standard for hashing and signing of typed structured data.
 *
 * The encoding scheme specified in the EIP requires a domain separator and a hash of the typed structured data, whose
 * encoding is very generic and therefore its implementation in Solidity is not feasible, thus this contract
 * does not implement the encoding itself. Protocols need to implement the type-specific encoding they need in order to
 * produce the hash of their typed data using a combination of `abi.encode` and `keccak256`.
 *
 * This contract implements the EIP 712 domain separator ({_domainSeparatorV4}) that is used as part of the encoding
 * scheme, and the final step of the encoding to obtain the message digest that is then signed via ECDSA
 * ({_hashTypedDataV4}).
 *
 * The implementation of the domain separator was designed to be as efficient as possible while still properly updating
 * the chain id to protect against replay attacks on an eventual fork of the chain.
 *
 * NOTE: This contract implements the version of the encoding known as "v4", as implemented by the JSON RPC method
 * https://docs.metamask.io/guide/signing-data.html[`eth_signTypedDataV4` in MetaMask].
 *
 * NOTE: In the upgradeable version of this contract, the cached values will correspond to the address, and the domain
 * separator of the implementation contract. This will cause the {_domainSeparatorV4} function to always rebuild the
 * separator from the immutable values, which is cheaper than accessing a cached version in cold storage.
 */
abstract contract EIP712Upgradeable is Initializable, IERC5267 {
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @custom:storage-location erc7201:openzeppelin.storage.EIP712
    struct EIP712Storage {
        /// @custom:oz-renamed-from _HASHED_NAME
        bytes32 _hashedName;
        /// @custom:oz-renamed-from _HASHED_VERSION
        bytes32 _hashedVersion;

        string _name;
        string _version;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EIP712StorageLocation = 0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;

    function _getEIP712Storage() private pure returns (EIP712Storage storage $) {
        assembly {
            $.slot := EIP712StorageLocation
        }
    }

    /**
     * @dev Initializes the domain separator and parameter caches.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP 712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    function __EIP712_init(string memory name, string memory version) internal onlyInitializing {
        __EIP712_init_unchained(name, version);
    }

    function __EIP712_init_unchained(string memory name, string memory version) internal onlyInitializing {
        EIP712Storage storage $ = _getEIP712Storage();
        $._name = name;
        $._version = version;

        // Reset prior values in storage if upgrading
        $._hashedName = 0;
        $._hashedVersion = 0;
    }

    /**
     * @dev Returns the domain separator for the current chain.
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash(), block.chainid, address(this)));
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * )));
     * address signer = ECDSA.recover(digest, signature);
     * ```
     */
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /**
     * @dev See {IERC-5267}.
     */
    function eip712Domain()
        public
        view
        virtual
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        EIP712Storage storage $ = _getEIP712Storage();
        // If the hashed name and version in storage are non-zero, the contract hasn't been properly initialized
        // and the EIP712 domain is not reliable, as it will be missing name and version.
        require($._hashedName == 0 && $._hashedVersion == 0, "EIP712: Uninitialized");

        return (
            hex"0f", // 01111
            _EIP712Name(),
            _EIP712Version(),
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /**
     * @dev The name parameter for the EIP712 domain.
     *
     * NOTE: This function reads from storage by default, but can be redefined to return a constant value if gas costs
     * are a concern.
     */
    function _EIP712Name() internal view virtual returns (string memory) {
        EIP712Storage storage $ = _getEIP712Storage();
        return $._name;
    }

    /**
     * @dev The version parameter for the EIP712 domain.
     *
     * NOTE: This function reads from storage by default, but can be redefined to return a constant value if gas costs
     * are a concern.
     */
    function _EIP712Version() internal view virtual returns (string memory) {
        EIP712Storage storage $ = _getEIP712Storage();
        return $._version;
    }

    /**
     * @dev The hash of the name parameter for the EIP712 domain.
     *
     * NOTE: In previous versions this function was virtual. In this version you should override `_EIP712Name` instead.
     */
    function _EIP712NameHash() internal view returns (bytes32) {
        EIP712Storage storage $ = _getEIP712Storage();
        string memory name = _EIP712Name();
        if (bytes(name).length > 0) {
            return keccak256(bytes(name));
        } else {
            // If the name is empty, the contract may have been upgraded without initializing the new storage.
            // We return the name hash in storage if non-zero, otherwise we assume the name is empty by design.
            bytes32 hashedName = $._hashedName;
            if (hashedName != 0) {
                return hashedName;
            } else {
                return keccak256("");
            }
        }
    }

    /**
     * @dev The hash of the version parameter for the EIP712 domain.
     *
     * NOTE: In previous versions this function was virtual. In this version you should override `_EIP712Version` instead.
     */
    function _EIP712VersionHash() internal view returns (bytes32) {
        EIP712Storage storage $ = _getEIP712Storage();
        string memory version = _EIP712Version();
        if (bytes(version).length > 0) {
            return keccak256(bytes(version));
        } else {
            // If the version is empty, the contract may have been upgraded without initializing the new storage.
            // We return the version hash in storage if non-zero, otherwise we assume the version is empty by design.
            bytes32 hashedVersion = $._hashedVersion;
            if (hashedVersion != 0) {
                return hashedVersion;
            } else {
                return keccak256("");
            }
        }
    }
}

// src/Tanda.sol

/// @notice Minimum slice of `TandaManager` that a Tanda needs to read at
///         runtime. We intentionally do NOT import the concrete
///         `TandaManager` to avoid coupling the build order; the
///         interface stays right here in the Tanda file because it is
///         only used here.
/// @dev    Fee basis points and the insurance bps are mirrored as
///         constants on `Tanda` itself (see `PLATFORM_FEE_BPS` etc.)
///         to avoid external calls per payout and to keep stack
///         pressure manageable. The deploy script MUST verify that
///         Manager's and Tanda's constants agree before going live.
interface ITandaManager {
    function treasury() external view returns (address);
    function requestRandomnessForTanda(uint256 tandaId) external;
}

/// @notice Soulbound Pass NFT entry points the Tanda calls on join /
///         defaulter mark. Singleton; address snapshotted at init.
interface IMitandaPassNFT {
    function mint(address participant, uint256 tandaId) external returns (uint256);
    function markDefaulted(address participant, uint256 tandaId) external;
}

/// @notice Transferable Receipt NFT entry point used on each cycle
///         payout. Singleton; address snapshotted at init.
interface IMitandaReceiptNFT {
    function mintReceipt(address recipient, uint256 tandaId, uint256 cycle, uint256 collectionId)
        external
        returns (uint256);
}

/// @notice Soulbound Completion NFT entry point used at tanda
///         completion. Singleton; address snapshotted at init.
interface IMitandaCompletionNFT {
    function batchMint(address[] calldata participants, uint256 tandaId) external returns (uint256[] memory);
}

/// @title  Tanda
/// @author Mi Tanda
/// @notice Per-tanda state machine. **EIP-1167 implementation contract**:
///         deployed once per chain, then cloned by `TandaManager.createTanda`
///         and initialized via `initialize(InitParams)`. Holds the
///         contributions, executes the cycle payouts, enforces defaulter
///         timing, and credits all outflows via the pull-payment pattern.
/// @dev    Uses OZ v5 upgradeable variants `Initializable`,
///         `ReentrancyGuardUpgradeable`, `EIP712Upgradeable` (from the
///         openzeppelin-contracts-upgradeable package). The upgradeable
///         variants use ERC-7201 namespaced storage, leaving slot 0+
///         entirely free for `Tanda`'s own state. `EIP712Upgradeable`
///         is required (vs. the non-upgradeable `EIP712`) because the
///         non-upgradeable version sets `_HASHED_NAME` and
///         `_HASHED_VERSION` as immutables in its constructor, which
///         never runs for clones, breaking signature verification.
///
///         **Insurance model (real-funds slash pool):** every contribution
///         is paired with a 10% insurance premium (`INSURANCE_BPS`).
///         Premiums accumulate in `insuranceBalance[participant]` and the
///         running `totalInsuranceReserve`. On default, the defaulter's
///         insurance moves to `slashedPool` (physical funds, not
///         notional). On completion, every still-active participant's
///         insurance is refunded to their `pendingWithdrawals`, then
///         `slashedPool` is split 95% / 2% / 3% across active
///         participants, treasury, and creator. The 95% slash share is
///         the honest-participant reward for staying paid up.
///
///         **Scheduled start:** a tanda may optionally specify a
///         `scheduledStart` timestamp at init. If `scheduledStart == 0`
///         the tanda auto-starts when the last seat fills. Otherwise,
///         filling the seats keeps the tanda OPEN until
///         `block.timestamp >= scheduledStart`, at which point anyone
///         can call `start()`. `scheduledStart` (when nonzero) must be
///         at least `block.timestamp + 1 days` at creation time —
///         enforced by `TandaManager.createTanda`.
///
///         **Privacy modes:** `PUBLIC` tandas accept any caller via
///         `join()`. `PRIVATE_TICKETED` tandas only accept callers
///         holding a creator-signed EIP-712 invite via
///         `joinWithInvite(deadline, signature)`. Tickets are keyed by
///         `(invitee, tandaId, deadline)`, single-use, and revocable by
///         the creator via `revokeInvite`.
///
///         **Cycle accounting invariants** (subtle — refer back here when
///         reading the code in three months):
///
///         - `participantCount` is set once in `initialize` and never
///           changes. It is the original seat count.
///         - `activeParticipantCount` starts at 0, increments on each
///           `join`, and decrements on each `markDefaulter`. It is the
///           count of participants still in good standing — NOT the
///           number of cycles remaining.
///         - `payoutOrder.length` starts at `participantCount` when the
///           VRF callback populates it via `assignPayoutOrder`. It
///           decreases by 1 each time a future-slot defaulter is pruned
///           by `_removeFromPayoutOrder`; past-slot defaulters
///           (defaulters who already received their pot before
///           defaulting) keep their slot, so `payoutOrder.length` may
///           exceed `activeParticipantCount`.
///         - **`payoutOrder.length` is the source of truth for total
///           cycles the tanda will run.** Not `participantCount`, not
///           `activeParticipantCount`.
///         - `currentCycle > payoutOrder.length` is the completion
///           trigger inside `triggerPayout`.
///         - `makePayment` cap = `payoutOrder.length - paidUntilCycle`
///           after VRF, or `participantCount - paidUntilCycle` before
///           VRF (clamped to ≥0 if defaulter pruning has dropped
///           `payoutOrder.length` below a pre-paid participant's
///           `paidUntilCycle`).
///         - Per-cycle pot at `triggerPayout` =
///           `contributionAmount * activeParticipantCount`. The pot
///           shrinks as defaulters are marked.
contract Tanda is ITanda, Initializable, ReentrancyGuardUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants — mirror of `TandaManager` fee + insurance config
    // (must be kept in lockstep with Manager; deploy script verifies all four)
    // ─────────────────────────────────────────────────────────────────────

    uint16 public constant PLATFORM_FEE_BPS = 200; // 2%
    uint16 public constant ORGANIZER_FEE_BPS = 300; // 3%
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant INSURANCE_BPS = 1_000; // 10% — per-cycle premium

    /// @notice EIP-712 typehash for an Invite struct. Domain is set via
    ///         `__EIP712_init("MiTanda", "1")` in `initialize`; the
    ///         domain separator therefore includes `chainId` and this
    ///         clone's address — so an invite signed for tanda A on
    ///         chain X cannot be replayed on tanda B or chain Y.
    bytes32 private constant INVITE_TYPEHASH = keccak256("Invite(address invitee,uint256 tandaId,uint256 deadline)");

    // ─────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────

    enum TandaState {
        OPEN, // accepting joins
        ACTIVE, // running cycles
        COMPLETED // all scheduled cycles paid, slash pool distributed
    }

    struct Participant {
        address addr;
        uint256 paidUntilCycle; // last cycle they have paid for (incl. join)
        bool isActive; // false once marked defaulter
        uint256 joinTimestamp;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Storage — set in initialize()
    // ─────────────────────────────────────────────────────────────────────

    uint256 public tandaId;
    address public token;
    uint256 public contributionAmount;
    uint256 public payoutInterval;
    uint16 public participantCount;
    uint256 public gracePeriod;
    address public manager;
    address public creator;

    /// @notice Snapshot of `TandaManager.activeCollectionId` at the moment
    ///         this clone was initialized. Permanent for the lifetime of
    ///         this tanda. `0` means the tanda was created during a
    ///         no-sponsor (go-dark) period; receipt mints will fall back
    ///         to `MitandaReceiptNFT.defaultFallbackBaseURI`.
    uint256 public sponsoredCollectionId;

    /// @notice Earliest block timestamp at which the tanda may transition
    ///         to ACTIVE. `0` means "start immediately when full".
    uint256 public scheduledStart;

    /// @notice Membership policy. PUBLIC accepts `join()` from any
    ///         address; PRIVATE_TICKETED only accepts `joinWithInvite`
    ///         calls backed by a creator-signed EIP-712 invite.
    TandaPrivacy public privacy;

    /// @notice Singleton NFT contracts wired by the Manager at clone
    ///         init. Stored as regular slots (not immutable — clones
    ///         can't have immutables). Set once in `initialize` and
    ///         never reassigned. NFT calls are unconditional: if any
    ///         of these is zero or misconfigured, every lifecycle
    ///         action that touches the NFT will revert — the intended
    ///         failure mode.
    address public passNFT;
    address public receiptNFT;
    address public completionNFT;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — lifecycle state
    // ─────────────────────────────────────────────────────────────────────

    TandaState public state;
    uint256 public startTimestamp;

    /// @notice Current cycle index, 1-based. Starts at 1 when state
    ///         transitions to ACTIVE. Incremented after each payout.
    ///         When `currentCycle > payoutOrder.length` the tanda
    ///         transitions to COMPLETED.
    uint256 public currentCycle;

    /// @notice Count of participants still in good standing. Decremented
    ///         on `markDefaulter`. NOT the source of truth for total
    ///         cycles — `payoutOrder.length` is, since past-defaulter
    ///         slots (defaulters who already received their pot) are
    ///         kept in `payoutOrder` to preserve historical cycle-index
    ///         mappings, so `payoutOrder.length` may exceed
    ///         `activeParticipantCount` after a past-paid defaulter is
    ///         marked.
    uint16 public activeParticipantCount;

    Participant[] public participants;

    /// @notice address → `index + 1` into `participants`. Zero means
    ///         "not a participant".
    mapping(address => uint256) public addressToParticipantIndex;

    bool public payoutOrderAssigned;

    /// @notice Pre-shuffled list of participant indices in payout order.
    ///         `payoutOrder[k-1]` is the recipient slot for cycle `k`.
    uint256[] public payoutOrder;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — pull-payment ledger
    // ─────────────────────────────────────────────────────────────────────

    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPendingCredits;

    /// @notice Pool of forfeited insurance from defaulters. Distributed
    ///         95% / 2% / 3% at completion. Physical funds.
    uint256 public slashedPool;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — insurance reserve
    // ─────────────────────────────────────────────────────────────────────

    mapping(address => uint256) public insuranceBalance;
    uint256 public totalInsuranceReserve;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — invite tickets (PRIVATE_TICKETED only)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Ticket fingerprint (`keccak256(invitee, tandaId, deadline)`)
    ///         → whether it has been redeemed by a `joinWithInvite` call.
    mapping(bytes32 => bool) public usedTickets;

    /// @notice Ticket fingerprint → whether the creator revoked the invite
    ///         before redemption.
    mapping(bytes32 => bool) public revokedTickets;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event ParticipantJoined(address indexed participant, uint256 timestamp);
    event ParticipantJoinedViaInvite(address indexed participant, uint256 timestamp, uint256 deadline);
    event InviteRevoked(address indexed invitee, uint256 deadline);
    event PaymentMade(address indexed participant, uint256 cyclesPaid, uint256 amount, uint256 timestamp);
    event TandaStarted(uint256 startTimestamp);
    event PayoutOrderAssigned(uint256[] order, uint256 timestamp);
    event PayoutCredited(
        address indexed recipient,
        address indexed treasury,
        address indexed creator,
        uint256 recipientAmount,
        uint256 treasuryAmount,
        uint256 creatorAmount,
        uint256 cycle,
        uint256 timestamp
    );
    event ParticipantDefaulted(
        address indexed participant, uint256 cycle, uint256 forfeitedInsurance, uint256 timestamp
    );
    event InsuranceRefunded(address indexed participant, uint256 amount);
    event ContributionExcessRefunded(address indexed participant, uint256 excessCycles, uint256 amount);
    event SlashPoolDistributed(
        uint256 totalPool, uint256 perActiveParticipant, uint256 treasuryShare, uint256 creatorShare, uint256 dust
    );
    event TandaCompleted(uint256 completionTimestamp);
    /// @notice Emitted when a tanda completes via full collapse — every
    ///         participant defaulted, no honest survivors. The treasury
    ///         absorbs the entire remaining token balance; all prior
    ///         pendingWithdrawals and insurance balances are forfeited.
    event FullCollapse(address indexed treasury, uint256 amount);
    event Withdrawn(address indexed claimant, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor — implementation only
    // ─────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────

    /// @notice One-shot initializer called by `TandaManager.createTanda`
    ///         immediately after cloning. Sets per-clone parameters,
    ///         initializes `ReentrancyGuardUpgradeable`, and sets up
    ///         the EIP-712 domain ("MiTanda", "1").
    /// @dev    Manager already validates parameter ranges + scheduled-
    ///         start lead time before calling; the checks here are
    ///         defense-in-depth, focused on "non-zero" invariants we
    ///         cannot recover from later.
    function initialize(InitParams calldata params) external override initializer {
        if (params.token == address(0)) revert ZeroAddress();
        if (params.manager == address(0)) revert ZeroAddress();
        if (params.creator == address(0)) revert ZeroAddress();
        if (params.contributionAmount == 0) revert ZeroAmount();
        if (params.passNFT == address(0)) revert ZeroAddress();
        if (params.receiptNFT == address(0)) revert ZeroAddress();
        if (params.completionNFT == address(0)) revert ZeroAddress();

        __ReentrancyGuard_init();
        __EIP712_init("MiTanda", "1");

        tandaId = params.tandaId;
        token = params.token;
        contributionAmount = params.contributionAmount;
        payoutInterval = params.payoutInterval;
        participantCount = params.participantCount;
        gracePeriod = params.gracePeriod;
        manager = params.manager;
        creator = params.creator;
        sponsoredCollectionId = params.sponsoredCollectionId;
        scheduledStart = params.scheduledStart;
        privacy = params.privacy;
        passNFT = params.passNFT;
        receiptNFT = params.receiptNFT;
        completionNFT = params.completionNFT;

        state = TandaState.OPEN;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyManager() {
        if (msg.sender != manager) revert CallerNotManager();
        _;
    }

    modifier onlyParticipant() {
        uint256 idxPlus1 = addressToParticipantIndex[msg.sender];
        if (idxPlus1 == 0) revert NotParticipant();
        if (!participants[idxPlus1 - 1].isActive) revert DefaultedParticipant();
        _;
    }

    modifier onlyInState(TandaState expected) {
        if (state != expected) revert WrongTandaState(uint8(expected), uint8(state));
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: join (PUBLIC tandas)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Reserve a seat in a PUBLIC tanda by paying the first
    ///         contribution + insurance premium. The contribution counts
    ///         as cycle 1's payment; `paidUntilCycle` is set to 1.
    /// @dev    Reverts if the tanda is PRIVATE_TICKETED — callers must
    ///         use `joinWithInvite` instead. When the last seat fills,
    ///         the tanda auto-starts (transitions to ACTIVE and requests
    ///         VRF randomness) IF `scheduledStart == 0` or
    ///         `block.timestamp >= scheduledStart`. Otherwise the tanda
    ///         stays OPEN; anyone can call `start()` after the scheduled
    ///         time.
    /// @custom:reverts WrongTandaState  if not OPEN.
    /// @custom:reverts NotPublicTanda   if privacy is PRIVATE_TICKETED.
    /// @custom:reverts TandaFull        if all seats are filled.
    /// @custom:reverts AlreadyJoined    if caller is already a participant.
    /// @custom:emits   ParticipantJoined.
    /// @custom:emits   TandaStarted (if this join triggers auto-start).
    function join() external nonReentrant onlyInState(TandaState.OPEN) {
        if (privacy != TandaPrivacy.PUBLIC) revert NotPublicTanda();
        _joinInternal(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: joinWithInvite (PRIVATE_TICKETED tandas)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Redeem a creator-signed EIP-712 invite to join a
    ///         PRIVATE_TICKETED tanda.
    /// @dev    The signature must be over the typed struct
    ///         `Invite(address invitee, uint256 tandaId, uint256 deadline)`
    ///         with `invitee == msg.sender`. The EIP-712 domain is
    ///         `("MiTanda", "1", chainId, address(this))` — so an invite
    ///         is bound to a specific tanda clone on a specific chain.
    ///         Tickets are keyed by `keccak256(msg.sender, tandaId,
    ///         deadline)`; each is single-use and may be pre-revoked by
    ///         the creator via `revokeInvite`.
    /// @param deadline  Latest `block.timestamp` at which this invite is
    ///                  still redeemable.
    /// @param signature Creator's signature over the EIP-712 typed-data
    ///                  digest. Validated via SignatureChecker, so either a
    ///                  65-byte EOA ECDSA signature or an ERC-1271
    ///                  smart-account signature is accepted.
    /// @custom:reverts WrongTandaState         if not OPEN.
    /// @custom:reverts NotPrivateTanda         if privacy is PUBLIC.
    /// @custom:reverts InviteExpired           if `block.timestamp > deadline`.
    /// @custom:reverts TicketAlreadyUsed       if already redeemed.
    /// @custom:reverts InviteAlreadyRevoked    if the creator revoked it.
    /// @custom:reverts InviteSignerNotCreator  if the recovered signer is not the creator.
    /// @custom:reverts TandaFull               if all seats are filled.
    /// @custom:reverts AlreadyJoined           if caller is already a participant.
    /// @custom:emits   ParticipantJoined.
    /// @custom:emits   ParticipantJoinedViaInvite.
    function joinWithInvite(uint256 deadline, bytes calldata signature)
        external
        nonReentrant
        onlyInState(TandaState.OPEN)
    {
        if (privacy != TandaPrivacy.PRIVATE_TICKETED) revert NotPrivateTanda();
        if (block.timestamp > deadline) revert InviteExpired(block.timestamp, deadline);

        bytes32 ticket = keccak256(abi.encode(msg.sender, tandaId, deadline));
        if (usedTickets[ticket]) revert TicketAlreadyUsed();
        if (revokedTickets[ticket]) revert InviteAlreadyRevoked();

        bytes32 structHash = keccak256(abi.encode(INVITE_TYPEHASH, msg.sender, tandaId, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        // SignatureChecker validates both EOA (ECDSA) and ERC-1271 smart-account
        // signatures, so smart-account creators (e.g. Privy) can issue invites.
        // The creator's account is always deployed by redeem time (they sent the
        // createTanda tx), so plain ERC-1271 is sufficient — no ERC-6492 needed.
        if (!SignatureChecker.isValidSignatureNow(creator, digest, signature)) {
            revert InviteSignerNotCreator();
        }

        // Mark used BEFORE joining (CEI: state writes before external call
        // in _joinInternal's safeTransferFrom).
        usedTickets[ticket] = true;

        _joinInternal(msg.sender);

        emit ParticipantJoinedViaInvite(msg.sender, block.timestamp, deadline);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal: shared join logic
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Common path for both `join` and `joinWithInvite`. NOT
    ///      `nonReentrant` itself — that guard is on the public entry
    ///      points so legitimate internal composition isn't blocked.
    function _joinInternal(address participant) internal {
        if (activeParticipantCount >= participantCount) revert TandaFull();
        if (addressToParticipantIndex[participant] != 0) revert AlreadyJoined();

        uint256 premium = _premiumPerCycle();
        uint256 chargeAmount = contributionAmount + premium;

        participants.push(
            Participant({addr: participant, paidUntilCycle: 1, isActive: true, joinTimestamp: block.timestamp})
        );
        addressToParticipantIndex[participant] = participants.length;
        activeParticipantCount++;

        insuranceBalance[participant] += premium;
        totalInsuranceReserve += premium;

        emit ParticipantJoined(participant, block.timestamp);

        // Soulbound EIP-5192 Pass NFT — minted BEFORE the token transfer
        // so the NFT existence tracks join-attempt, not transfer-success.
        // If the safeTransferFrom below reverts, the whole tx (incl. this
        // mint) rolls back atomically.
        IMitandaPassNFT(passNFT).mint(participant, tandaId);

        IERC20(token).safeTransferFrom(participant, address(this), chargeAmount);

        // Auto-start when seats fill — IF either auto-start is enabled
        // (`scheduledStart == 0`) or the scheduled time has arrived.
        if (activeParticipantCount == participantCount) {
            if (scheduledStart == 0 || block.timestamp >= scheduledStart) {
                _startTanda();
            }
        }
    }

    /// @dev Per-cycle insurance premium derived from `contributionAmount`
    ///      and `INSURANCE_BPS`. Integer division — for very small
    ///      `contributionAmount` the premium may be zero.
    function _premiumPerCycle() internal view returns (uint256) {
        return (contributionAmount * INSURANCE_BPS) / BPS_DENOMINATOR;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Manager: enrollCreator (charge-at-create)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Enroll the creator as the first participant at creation.
    /// @dev    Called exactly once by `TandaManager.createTanda`, AFTER the
    ///         Manager has already pulled the creator's first contribution +
    ///         insurance premium into this clone (the creator approves the
    ///         Manager, not the not-yet-deployed clone). So this mirrors
    ///         `_joinInternal` EXACTLY except:
    ///           - it does NOT `safeTransferFrom` (the Manager funded the
    ///             clone), and
    ///           - it never auto-starts (a single participant can never fill
    ///             a tanda — `participantCount` is always >= 2).
    ///         `paidUntilCycle = 1` (cycle 1 covered) and the premium lands
    ///         in `insuranceBalance`, identical to a normal join.
    /// @custom:reverts CallerNotManager if not called by the Manager.
    /// @custom:reverts WrongTandaState  if not OPEN.
    /// @custom:reverts NotCreator       if `creator_` is not the recorded creator.
    /// @custom:reverts AlreadyJoined    if the creator is already enrolled.
    /// @custom:emits   ParticipantJoined.
    function enrollCreator(address creator_) external override onlyManager onlyInState(TandaState.OPEN) {
        if (creator_ != creator) revert NotCreator();
        if (addressToParticipantIndex[creator_] != 0) revert AlreadyJoined();

        uint256 premium = _premiumPerCycle();

        participants.push(
            Participant({addr: creator_, paidUntilCycle: 1, isActive: true, joinTimestamp: block.timestamp})
        );
        addressToParticipantIndex[creator_] = participants.length;
        activeParticipantCount++;

        insuranceBalance[creator_] += premium;
        totalInsuranceReserve += premium;

        emit ParticipantJoined(creator_, block.timestamp);

        // Soulbound Pass NFT. The clone is already registered in the Manager
        // (registration precedes initialize in createTanda), so onlyTanda passes.
        IMitandaPassNFT(passNFT).mint(creator_, tandaId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: start() — scheduled-start trigger
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Start a tanda that filled its seats before its
    ///         `scheduledStart` deadline. Permissionless.
    /// @dev    No-op for `scheduledStart == 0` tandas (those auto-start
    ///         in `_joinInternal` when the last seat fills). For
    ///         `scheduledStart > 0`, callable once both:
    ///           - all seats are filled (`activeParticipantCount == participantCount`)
    ///           - `block.timestamp >= scheduledStart`
    ///         A pause on `TandaManager` will indirectly block this by
    ///         causing the subsequent `requestRandomnessForTanda` call
    ///         to revert.
    /// @custom:reverts WrongTandaState           if not OPEN.
    /// @custom:reverts TandaNotFull              if seats not full yet.
    /// @custom:reverts ScheduledStartNotReached  if before scheduled start.
    /// @custom:emits   TandaStarted.
    function start() external nonReentrant onlyInState(TandaState.OPEN) {
        if (activeParticipantCount < participantCount) revert TandaNotFull();
        if (scheduledStart > 0 && block.timestamp < scheduledStart) {
            revert ScheduledStartNotReached(block.timestamp, scheduledStart);
        }
        _startTanda();
    }

    function _startTanda() internal {
        state = TandaState.ACTIVE;
        startTimestamp = block.timestamp;
        currentCycle = 1;

        emit TandaStarted(block.timestamp);

        ITandaManager(manager).requestRandomnessForTanda(tandaId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Creator: revokeInvite
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Revoke a previously-issued invite ticket. Only callable
    ///         by the creator. The ticket fingerprint is computed
    ///         exactly as `joinWithInvite` would — so an invite can be
    ///         revoked even if the signature is not yet on-chain.
    /// @dev    No state-machine check; revocation may happen at any time
    ///         and is harmless after the tanda has started (since
    ///         `joinWithInvite` already reverts on non-OPEN states).
    /// @param invitee   Address named in the original invite.
    /// @param deadline  Deadline named in the original invite.
    /// @custom:reverts NotCreator if `msg.sender != creator`.
    /// @custom:emits   InviteRevoked.
    function revokeInvite(address invitee, uint256 deadline) external {
        if (msg.sender != creator) revert NotCreator();
        bytes32 ticket = keccak256(abi.encode(invitee, tandaId, deadline));
        revokedTickets[ticket] = true;
        emit InviteRevoked(invitee, deadline);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: makePayment
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pay contribution + insurance premium for one or more
    ///         upcoming cycles. A participant may pay 1 cycle ahead
    ///         (typical) or multiple cycles ahead (pre-fund).
    /// @dev    The cap is `totalCycles - paidUntilCycle` where
    ///         `totalCycles` = `payoutOrder.length` (after VRF) or
    ///         `participantCount` (before VRF). When defaulters prune
    ///         future slots, the cap shrinks. Pre-paid excess (if any)
    ///         is refunded at completion via `_refundActiveParticipants`.
    ///
    ///         Each cycle paid charges `contributionAmount + premium`
    ///         where `premium = contributionAmount * INSURANCE_BPS /
    ///         BPS_DENOMINATOR`. The base flows to that cycle's pot at
    ///         `triggerPayout` time; the premium accumulates in
    ///         `insuranceBalance[msg.sender]`.
    /// @custom:reverts WrongTandaState   if not ACTIVE.
    /// @custom:reverts NotParticipant    if caller never joined or has been marked defaulter.
    /// @custom:reverts ZeroAmount        if `cyclesToPay == 0`.
    /// @custom:reverts CyclesOutOfRange  if requested exceeds the remaining cycle cap.
    /// @custom:emits   PaymentMade — `amount` includes contribution + premium.
    function makePayment(uint256 cyclesToPay) external nonReentrant onlyInState(TandaState.ACTIVE) onlyParticipant {
        if (cyclesToPay == 0) revert ZeroAmount();

        Participant storage p = participants[addressToParticipantIndex[msg.sender] - 1];

        uint256 totalCycles = payoutOrderAssigned ? payoutOrder.length : participantCount;
        uint256 cap = totalCycles > p.paidUntilCycle ? totalCycles - p.paidUntilCycle : 0;
        if (cyclesToPay > cap) revert CyclesOutOfRange(cyclesToPay, cap);

        uint256 premium = _premiumPerCycle();
        uint256 contributionTotal = contributionAmount * cyclesToPay;
        uint256 premiumTotal = premium * cyclesToPay;
        uint256 chargeTotal = contributionTotal + premiumTotal;

        p.paidUntilCycle += cyclesToPay;
        insuranceBalance[msg.sender] += premiumTotal;
        totalInsuranceReserve += premiumTotal;

        IERC20(token).safeTransferFrom(msg.sender, address(this), chargeTotal);

        emit PaymentMade(msg.sender, cyclesToPay, chargeTotal, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: markDefaulter
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Permissionlessly mark a participant as defaulted on the
    ///         current cycle. Anyone may call.
    /// @dev    On success: `participant.isActive = false`,
    ///         `activeParticipantCount--`, their accumulated insurance
    ///         is moved to `slashedPool`, and (if their slot in
    ///         `payoutOrder` is still pending) it is removed via O(n)
    ///         left-shift.
    /// @dev    If pruning drives `payoutOrder.length < currentCycle`
    ///         (no remaining cycles can pay out), the tanda
    ///         auto-completes in the same transaction via
    ///         `_completeTanda`. With surviving actives, normal
    ///         completion runs; with zero actives, full collapse
    ///         sweeps the entire token balance to treasury
    ///         (`FullCollapse` event). Defensive: the
    ///         `payoutOrderAssigned` guard prevents auto-completion
    ///         in the (unreachable in practice) window before the
    ///         VRF callback assigns the payout order.
    /// @custom:reverts WrongTandaState           if not ACTIVE.
    /// @custom:reverts NotParticipant            if `participant` isn't in the tanda.
    /// @custom:reverts AlreadyMarkedDefaulter    if already inactive.
    /// @custom:reverts NotDefaulter              if `paidUntilCycle >= currentCycle`.
    /// @custom:reverts GracePeriodNotExpired     if called before deadline + grace.
    /// @custom:emits   ParticipantDefaulted, plus TandaCompleted or FullCollapse if auto-completion fires.
    function markDefaulter(address participant) external onlyInState(TandaState.ACTIVE) {
        uint256 idxPlus1 = addressToParticipantIndex[participant];
        if (idxPlus1 == 0) revert NotParticipant();
        uint256 idx = idxPlus1 - 1;

        Participant storage p = participants[idx];
        if (!p.isActive) revert AlreadyMarkedDefaulter(participant);
        if (p.paidUntilCycle >= currentCycle) revert NotDefaulter(participant);

        uint256 expiresAt = startTimestamp + currentCycle * payoutInterval + gracePeriod;
        if (block.timestamp <= expiresAt) revert GracePeriodNotExpired(block.timestamp, expiresAt);

        p.isActive = false;
        activeParticipantCount--;

        uint256 forfeitedInsurance = insuranceBalance[participant];
        if (forfeitedInsurance > 0) {
            insuranceBalance[participant] = 0;
            totalInsuranceReserve -= forfeitedInsurance;
            slashedPool += forfeitedInsurance;
        }

        if (payoutOrderAssigned) {
            _removeFromPayoutOrder(idx);
        }

        emit ParticipantDefaulted(participant, currentCycle, forfeitedInsurance, block.timestamp);

        // Pass NFT flag last: if it fails (it shouldn't — the Pass NFT's
        // `markDefaulted` is a silent no-op when the pass doesn't exist),
        // Tanda's own `isActive = false` state has already been written
        // and the event emitted. The pass NFT itself stays soulbound on
        // the participant as reputation evidence; only its `isDefaulted`
        // flag flips.
        IMitandaPassNFT(passNFT).markDefaulted(participant, tandaId);

        // Auto-complete: pruning may have driven `payoutOrder.length`
        // below `currentCycle`, meaning no payouts remain. Without this,
        // the next `triggerPayout` would access `payoutOrder[currentCycle-1]`
        // out of bounds and the tanda would be stuck in ACTIVE forever.
        // The `payoutOrderAssigned` clause prevents auto-completion in
        // the (in-practice unreachable) window before VRF callback fires.
        if (payoutOrderAssigned && payoutOrder.length < currentCycle) {
            _completeTanda();
        }
    }

    /// @dev Remove `participantIndex` from `payoutOrder` IF its slot is
    ///      at or after `currentCycle`. Past slots stay.
    function _removeFromPayoutOrder(uint256 participantIndex) internal {
        uint256 len = payoutOrder.length;
        for (uint256 i = currentCycle - 1; i < len; i++) {
            if (payoutOrder[i] == participantIndex) {
                for (uint256 j = i; j < len - 1; j++) {
                    payoutOrder[j] = payoutOrder[j + 1];
                }
                payoutOrder.pop();
                return;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: triggerPayout
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Settle the current cycle: credit recipient (95%),
    ///         treasury (2%), creator (3%). Permissionless once payout
    ///         time has arrived and all active participants have paid up.
    /// @dev    Reverts with `DefaultersOutstanding` if any active hasn't
    ///         paid this cycle. Cure: `markDefaulter(...)` once grace
    ///         expires, then re-call.
    function triggerPayout() external nonReentrant onlyInState(TandaState.ACTIVE) {
        if (!payoutOrderAssigned) revert PayoutOrderNotAssigned();

        uint256 readyAt = startTimestamp + currentCycle * payoutInterval;
        if (block.timestamp < readyAt) revert PayoutNotReady(block.timestamp, readyAt);

        if (!_allActiveParticipantsPaid()) revert DefaultersOutstanding();

        uint256 cyclePaid = currentCycle;
        address recipient = participants[payoutOrder[cyclePaid - 1]].addr;
        address treasuryAddr = ITandaManager(manager).treasury();

        uint256 pot = contributionAmount * activeParticipantCount;
        uint256 platformAmount = (pot * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 organizerAmount = (pot * ORGANIZER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 recipientAmount = pot - platformAmount - organizerAmount;

        currentCycle = cyclePaid + 1;
        _settleCyclePayout(recipient, treasuryAddr, recipientAmount, platformAmount, organizerAmount, cyclePaid);

        // Receipt NFT mint with frozen-at-mint baseURI + ERC-2981 royalty.
        // `cyclePaid` is the cycle that just paid out (NOT the new
        // `currentCycle`). `sponsoredCollectionId` may be 0 — Receipt
        // NFT handles go-dark via its default fallback URI.
        IMitandaReceiptNFT(receiptNFT).mintReceipt(recipient, tandaId, cyclePaid, sponsoredCollectionId);

        if (currentCycle > payoutOrder.length) {
            _completeTanda();
        }
    }

    function _settleCyclePayout(
        address recipient,
        address treasuryAddr,
        uint256 recipientAmount,
        uint256 platformAmount,
        uint256 organizerAmount,
        uint256 cyclePaid
    ) internal {
        _credit(recipient, recipientAmount);
        _credit(treasuryAddr, platformAmount);
        _credit(creator, organizerAmount);

        emit PayoutCredited(
            recipient,
            treasuryAddr,
            creator,
            recipientAmount,
            platformAmount,
            organizerAmount,
            cyclePaid,
            block.timestamp
        );
    }

    function _allActiveParticipantsPaid() internal view returns (bool) {
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            Participant storage p = participants[i];
            if (p.isActive && p.paidUntilCycle < currentCycle) return false;
        }
        return true;
    }

    /// @dev Two completion paths:
    ///      1. Normal (`activeParticipantCount > 0`): refund insurance
    ///         and excess contributions to actives, distribute slash
    ///         pool 95/2/3, mint Completion NFTs.
    ///      2. Full collapse (`activeParticipantCount == 0`): every
    ///         participant defaulted. Existing pendingWithdrawals and
    ///         insurance balances are forfeited; the entire token
    ///         balance sweeps to treasury. No Completion NFTs minted.
    function _completeTanda() internal {
        if (activeParticipantCount == 0) {
            _fullCollapse();
            return;
        }

        state = TandaState.COMPLETED;
        _refundActiveParticipants();
        if (slashedPool > 0) {
            _distributeSlashPool();
        }
        emit TandaCompleted(block.timestamp);

        // Completion NFTs minted LAST so all financial state is final
        // before badges are issued. Build the active-participants array
        // by scanning `participants` once and collecting `isActive`
        // addresses. `activeParticipantCount == 0` produces an empty
        // array, which `MitandaCompletionNFT.batchMint` handles as a
        // no-op — no defensive branching needed here.
        uint256 activeCount = activeParticipantCount;
        address[] memory actives = new address[](activeCount);
        uint256 outIdx = 0;
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            if (participants[i].isActive) {
                actives[outIdx] = participants[i].addr;
                outIdx++;
            }
        }
        IMitandaCompletionNFT(completionNFT).batchMint(actives, tandaId);
    }

    /// @dev Full-collapse settlement: every participant defaulted.
    ///      Platform is lender-of-last-resort — the entire token
    ///      balance (including any pendingWithdrawals that were
    ///      credited but never withdrawn) sweeps to treasury. All
    ///      prior credits and insurance balances are zeroed.
    function _fullCollapse() internal {
        address treasuryAddr = ITandaManager(manager).treasury();

        // Zero every per-address credit and insurance balance — full
        // collapse forfeits every existing claim. The token balance
        // is the only thing that matters; credits are rebuilt from it.
        uint256 n = participants.length;
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i].addr;
            delete pendingWithdrawals[p];
            delete insuranceBalance[p];
        }
        delete pendingWithdrawals[creator];
        delete pendingWithdrawals[treasuryAddr];

        // Sweep entire token balance to treasury.
        uint256 sweepable = IERC20(token).balanceOf(address(this));
        pendingWithdrawals[treasuryAddr] = sweepable;
        totalPendingCredits = sweepable;

        slashedPool = 0;
        totalInsuranceReserve = 0;

        state = TandaState.COMPLETED;

        emit FullCollapse(treasuryAddr, sweepable);
        // No Completion NFTs minted — by definition nobody completed honestly.
    }

    /// @dev Refund each active participant's insurance balance + any
    ///      contribution paid for cycles that didn't run.
    function _refundActiveParticipants() internal {
        uint256 totalCyclesRun = payoutOrder.length;
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            Participant storage p = participants[i];
            if (!p.isActive) continue;

            uint256 ins = insuranceBalance[p.addr];
            if (ins > 0) {
                insuranceBalance[p.addr] = 0;
                totalInsuranceReserve -= ins;
                _credit(p.addr, ins);
                emit InsuranceRefunded(p.addr, ins);
            }

            if (p.paidUntilCycle > totalCyclesRun) {
                uint256 excessCycles = p.paidUntilCycle - totalCyclesRun;
                uint256 excessAmount = excessCycles * contributionAmount;
                _credit(p.addr, excessAmount);
                emit ContributionExcessRefunded(p.addr, excessCycles, excessAmount);
            }
        }
    }

    /// @dev Distribute the slashed pool 95% / 2% / 3% at completion.
    ///      Pool is physically backed by forfeited insurance.
    function _distributeSlashPool() internal {
        uint256 pool = slashedPool;
        slashedPool = 0;

        uint256 needed = totalPendingCredits + pool;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < needed) revert InsufficientContractBalance(needed, balance);

        address treasuryAddr = ITandaManager(manager).treasury();
        uint256 platformShare = (pool * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 organizerShare = (pool * ORGANIZER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 recipientPool = pool - platformShare - organizerShare;

        uint256 perActive = recipientPool / activeParticipantCount;
        uint256 dust = recipientPool - (perActive * activeParticipantCount);

        _credit(treasuryAddr, platformShare + dust);
        _credit(creator, organizerShare);

        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            if (participants[i].isActive) {
                _credit(participants[i].addr, perActive);
            }
        }

        emit SlashPoolDistributed(pool, perActive, platformShare + dust, organizerShare, dust);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Manager → Tanda: VRF callback
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Receive a VRF-resolved random seed and derive payout
    ///         order via Fisher–Yates shuffle.
    /// @custom:reverts CallerNotManager             if `msg.sender != manager`.
    /// @custom:reverts WrongTandaState              if not ACTIVE.
    /// @custom:reverts PayoutOrderAlreadyAssigned   if already shuffled.
    /// @custom:emits   PayoutOrderAssigned.
    function assignPayoutOrder(uint256 randomSeed) external override onlyManager onlyInState(TandaState.ACTIVE) {
        if (payoutOrderAssigned) revert PayoutOrderAlreadyAssigned();

        uint256 n = participantCount;
        payoutOrder = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            payoutOrder[i] = i;
        }

        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(randomSeed, i))) % (i + 1);
            (payoutOrder[i], payoutOrder[j]) = (payoutOrder[j], payoutOrder[i]);
        }

        payoutOrderAssigned = true;
        emit PayoutOrderAssigned(payoutOrder, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: withdraw (pull-payment claim)
    // ─────────────────────────────────────────────────────────────────────

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingWithdrawals[msg.sender] = 0;
        totalPendingCredits -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[to] += amount;
        totalPendingCredits += amount;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }

    function getParticipant(uint256 index) external view returns (Participant memory) {
        return participants[index];
    }

    function getAllParticipants() external view returns (Participant[] memory) {
        return participants;
    }

    function isParticipant(address account) external view returns (bool) {
        return addressToParticipantIndex[account] != 0;
    }

    function isActiveParticipant(address account) external view returns (bool) {
        uint256 idxPlus1 = addressToParticipantIndex[account];
        if (idxPlus1 == 0) return false;
        return participants[idxPlus1 - 1].isActive;
    }

    function getPayoutOrder() external view returns (uint256[] memory) {
        if (!payoutOrderAssigned) revert PayoutOrderNotAssigned();
        return payoutOrder;
    }

    /// @notice Returns the contract's token balance and the sum of all
    ///         outstanding claims. `balance - outstanding` equals the
    ///         current cycle's in-flight contributions.
    function getAccountingSnapshot()
        external
        view
        returns (
            uint256 balance,
            uint256 outstanding,
            uint256 pendingCredits,
            uint256 slashPool,
            uint256 insuranceReserve
        )
    {
        balance = IERC20(token).balanceOf(address(this));
        pendingCredits = totalPendingCredits;
        slashPool = slashedPool;
        insuranceReserve = totalInsuranceReserve;
        outstanding = pendingCredits + slashPool + insuranceReserve;
    }

    /// @notice Domain separator for EIP-712 invite signatures. Each
    ///         clone has its own separator (includes `address(this)`).
    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The EIP-712 typehash for an Invite. Exposed for frontends
    ///         that want to sanity-check the struct layout matches.
    function inviteTypehash() external pure returns (bytes32) {
        return INVITE_TYPEHASH;
    }
}
