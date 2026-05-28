// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TandaManager} from "../src/TandaManager.sol";
import {Tanda} from "../src/Tanda.sol";
import {MitandaPassNFT} from "../src/MitandaPassNFT.sol";
import {MitandaReceiptNFT} from "../src/MitandaReceiptNFT.sol";
import {MitandaCompletionNFT} from "../src/MitandaCompletionNFT.sol";

/// @title  Mi Tanda — multi-chain deploy script
/// @notice One-shot deploy: implementation, three NFTs, Manager via
///         CREATE2 with deterministic salt, ownership handoff, token
///         allowlist, and sponsored-collection #1 setup.
/// @dev    Determinism contract: same Manager address on every chain.
///         Required to achieve it:
///         1. Same `_initialOwner` (=deployer EOA) on every chain.
///         2. Same deployer EOA AND same starting nonce — predicted NFT
///            addresses depend on `(deployer, nonce)`. Use a fresh
///            deployer dedicated to Mi Tanda; do not mix other tx
///            traffic on it between chain runs.
///         3. Same VRF coordinator address per chain (already chain-
///            specific) and same `_treasury`, `_subscriptionId`,
///            `_gasLane`, `_callbackGasLimit` — all of these end up in
///            the Manager's init code via constructor args.
///
///         If any of those vary across chains, the CREATE2 address
///         changes. The script asserts the deployed Manager address
///         matches the prediction, so a mismatch reverts loudly.
///
/// @custom:run
///         forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast
contract Deploy is Script {
    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    /// @dev Arachnid's deterministic deployer — canonical address on
    ///      every major EVM chain. Calldata layout: 32-byte salt ||
    ///      init code. Deploys via CREATE2 with `msg.sender = this`.
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Salt for the Manager CREATE2. Bump the version segment if
    ///      a future Manager re-deploy needs a different address.
    bytes32 internal constant MANAGER_SALT = keccak256("MiTanda.v1.Manager");

    string internal constant DEFAULT_FALLBACK_URI = "ipfs://QmReplaceWithRealCID";
    uint32 internal constant DEFAULT_CALLBACK_GAS = 2_500_000;

    /// @dev Initial sponsored collection: name, royalty bps.
    string internal constant COLLECTION_NAME = "Mi Tanda Genesis";
    uint96 internal constant COLLECTION_ROYALTY_BPS = 250; // 2.5%

    // ─────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────

    struct ChainConfig {
        string name;
        address vrfCoordinator;
        bytes32 gasLane;
        address usdc; // address(0) if not applicable on this chain
        address mxnb; // address(0) if not applicable on this chain
    }

    struct Predicted {
        address tandaImpl;
        address passNFT;
        address receiptNFT;
        address completionNFT;
        address manager;
    }

    struct DeployedContracts {
        Tanda tandaImpl;
        MitandaPassNFT passNFT;
        MitandaReceiptNFT receiptNFT;
        MitandaCompletionNFT completionNFT;
        TandaManager manager;
    }

    // ─────────────────────────────────────────────────────────────────
    // Entry point
    // ─────────────────────────────────────────────────────────────────

    function run() external {
        // 1. Read env
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        uint32 callbackGas = uint32(vm.envOr("CALLBACK_GAS_LIMIT", uint256(DEFAULT_CALLBACK_GAS)));
        string memory fallbackURI = vm.envOr("INITIAL_FALLBACK_BASE_URI", DEFAULT_FALLBACK_URI);

        ChainConfig memory cfg = _chainConfig(block.chainid);

        // 2. Pre-flight checks
        _preflightChecks(cfg, treasury, subId, deployer);

        // 3. Predict addresses
        uint256 startNonce = vm.getNonce(deployer);
        Predicted memory pred =
            _predict(deployer, startNonce, cfg, subId, callbackGas, treasury, deployer);

        _logPredictions(cfg, deployer, treasury, startNonce, pred);

        // 4. Broadcast deploys
        vm.startBroadcast(deployerPk);
        DeployedContracts memory d = _deployAll(cfg, treasury, subId, callbackGas, fallbackURI, deployer, pred);
        _ownershipHandoffAndSetup(d.manager, cfg, treasury, fallbackURI, deployer);
        vm.stopBroadcast();

        // 5. Post-deploy verification (view only, no broadcast)
        _verify(d, cfg, treasury, deployer);

        // 6. Write JSON deployment record
        _writeDeploymentJson(cfg, deployer, treasury, d, subId, callbackGas);

        // 7. Post-deploy instructions
        _logPostDeployInstructions(cfg, address(d.manager), subId);
    }

    // ─────────────────────────────────────────────────────────────────
    // Pre-flight
    // ─────────────────────────────────────────────────────────────────

    function _preflightChecks(ChainConfig memory cfg, address treasury, uint256 subId, address deployer)
        internal
        view
    {
        require(deployer != address(0), "deployer is zero - check DEPLOYER_PRIVATE_KEY");
        require(treasury != address(0), "TREASURY_ADDRESS is zero");
        require(subId != 0, "VRF_SUBSCRIPTION_ID is zero - create a subscription at vrf.chain.link");
        require(cfg.vrfCoordinator != address(0), "chain config missing vrfCoordinator");
        require(cfg.gasLane != bytes32(0), "chain config missing gasLane - see TODO in _chainConfig");
        require(
            DETERMINISTIC_DEPLOYER.code.length > 0,
            "Arachnid deterministic deployer not present on this chain (expected 0x4e59...)"
        );
        // A token is required so we can allowlist at least one — either USDC or MXNB.
        require(cfg.usdc != address(0) || cfg.mxnb != address(0), "chain config: no token to allowlist");
    }

    // ─────────────────────────────────────────────────────────────────
    // Chain config
    // ─────────────────────────────────────────────────────────────────

    function _chainConfig(uint256 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 8453) {
            // Base mainnet
            return ChainConfig({
                name: "Base",
                vrfCoordinator: 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634,
                // 30 gwei keyHash per Chainlink VRF v2.5 docs. VERIFY at
                // https://docs.chain.link/vrf/v2-5/supported-networks#base-mainnet
                gasLane: 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70,
                usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                mxnb: address(0)
            });
        } else if (chainId == 84532) {
            // Base Sepolia
            return ChainConfig({
                name: "Base Sepolia",
                vrfCoordinator: 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE,
                // TODO: Fill in Base Sepolia gas lane keyHash from
                // https://docs.chain.link/vrf/v2-5/supported-networks#base-sepolia-testnet
                // Set to bytes32(0) so pre-flight reverts loudly until set.
                gasLane: bytes32(0),
                usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
                mxnb: address(0)
            });
        } else if (chainId == 42161) {
            // Arbitrum One
            return ChainConfig({
                name: "Arbitrum One",
                vrfCoordinator: 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e,
                // 30 gwei keyHash per Chainlink VRF v2.5 docs. VERIFY at
                // https://docs.chain.link/vrf/v2-5/supported-networks#arbitrum-mainnet
                gasLane: 0x9e9e46732b32662b9adc6f3abdf6c5e926a666f174a786439a95e1ac1e9da8a7,
                usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                mxnb: 0xF197FFC28c23E0309B5559e7a166f2c6164C80aA
            });
        } else if (chainId == 421614) {
            // Arbitrum Sepolia
            return ChainConfig({
                name: "Arbitrum Sepolia",
                vrfCoordinator: 0x5CE8D5A2BC84beb22a398CCA51996F7930313D61,
                // TODO: Fill in Arbitrum Sepolia gas lane keyHash from
                // https://docs.chain.link/vrf/v2-5/supported-networks#arbitrum-sepolia-testnet
                gasLane: bytes32(0),
                usdc: address(0), // no canonical USDC on Arbitrum Sepolia
                mxnb: 0xF197FFC28c23E0309B5559e7a166f2c6164C80aA
            });
        } else {
            revert("Unsupported chain");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Address prediction
    // ─────────────────────────────────────────────────────────────────

    /// @dev NFTs use CREATE so address = f(deployer, nonce). Manager
    ///      uses CREATE2 via Arachnid so address = f(deployer of CREATE2,
    ///      salt, init code hash). Init code embeds the NFT addresses,
    ///      so NFTs must be predicted first.
    function _predict(
        address deployer,
        uint256 startNonce,
        ChainConfig memory cfg,
        uint256 subId,
        uint32 callbackGas,
        address treasury,
        address initialOwner
    ) internal pure returns (Predicted memory p) {
        p.tandaImpl = _computeCreateAddress(deployer, startNonce);
        p.passNFT = _computeCreateAddress(deployer, startNonce + 1);
        p.receiptNFT = _computeCreateAddress(deployer, startNonce + 2);
        p.completionNFT = _computeCreateAddress(deployer, startNonce + 3);

        bytes memory initCode = _managerInitCode(
            p.tandaImpl,
            cfg.vrfCoordinator,
            subId,
            cfg.gasLane,
            callbackGas,
            treasury,
            p.passNFT,
            p.receiptNFT,
            p.completionNFT,
            initialOwner
        );

        p.manager = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, MANAGER_SALT, keccak256(initCode))
                    )
                )
            )
        );
    }

    function _managerInitCode(
        address tandaImpl,
        address vrfCoordinator,
        uint256 subId,
        bytes32 gasLane,
        uint32 callbackGas,
        address treasury,
        address passNFT,
        address receiptNFT,
        address completionNFT,
        address initialOwner
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(TandaManager).creationCode,
            abi.encode(
                tandaImpl,
                vrfCoordinator,
                subId,
                gasLane,
                callbackGas,
                treasury,
                passNFT,
                receiptNFT,
                completionNFT,
                initialOwner
            )
        );
    }

    /// @dev RLP-encode (deployer, nonce) and keccak256 it, take last 20
    ///      bytes. Mirrors `vm.computeCreateAddress` but as a pure helper
    ///      so the prediction can run in pure contexts and be exercised
    ///      in unit tests without cheat-code access.
    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        bytes memory rlp;
        if (nonce == 0x00) {
            rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        } else if (nonce <= 0xff) {
            rlp = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            rlp = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            rlp = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce));
        } else {
            rlp = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce));
        }
        return address(uint160(uint256(keccak256(rlp))));
    }

    // ─────────────────────────────────────────────────────────────────
    // Deploy + ownership
    // ─────────────────────────────────────────────────────────────────

    function _deployAll(
        ChainConfig memory cfg,
        address treasury,
        uint256 subId,
        uint32 callbackGas,
        string memory fallbackURI,
        address deployer,
        Predicted memory pred
    ) internal returns (DeployedContracts memory d) {
        // 1. Tanda implementation
        d.tandaImpl = new Tanda();
        require(address(d.tandaImpl) == pred.tandaImpl, "Deploy: tandaImpl address mismatch");

        // 2. NFTs — each carries the predicted Manager address (immutable)
        d.passNFT = new MitandaPassNFT(pred.manager, deployer);
        require(address(d.passNFT) == pred.passNFT, "Deploy: passNFT address mismatch");

        d.receiptNFT = new MitandaReceiptNFT(pred.manager, deployer, fallbackURI);
        require(address(d.receiptNFT) == pred.receiptNFT, "Deploy: receiptNFT address mismatch");

        d.completionNFT = new MitandaCompletionNFT(pred.manager, deployer);
        require(address(d.completionNFT) == pred.completionNFT, "Deploy: completionNFT address mismatch");

        // 3. Manager via Arachnid CREATE2
        bytes memory initCode = _managerInitCode(
            address(d.tandaImpl),
            cfg.vrfCoordinator,
            subId,
            cfg.gasLane,
            callbackGas,
            treasury,
            address(d.passNFT),
            address(d.receiptNFT),
            address(d.completionNFT),
            deployer // _initialOwner — propose ownership to the EOA
        );
        (bool ok,) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(MANAGER_SALT, initCode));
        require(ok, "Deploy: CREATE2 deployment failed");
        require(pred.manager.code.length > 0, "Deploy: Manager not at predicted address");
        d.manager = TandaManager(pred.manager);
    }

    /// @dev CRITICAL ORDERING: acceptOwnership() MUST run before any
    ///      owner-only setup call. At entry, the Manager's owner is
    ///      Arachnid's CREATE2 deployer; pendingOwner = the EOA
    ///      (set by Manager constructor via transferOwnership).
    function _ownershipHandoffAndSetup(
        TandaManager manager,
        ChainConfig memory cfg,
        address treasury,
        string memory fallbackURI,
        address deployer
    ) internal {
        // Step 1: Finalize ownership transfer.
        manager.acceptOwnership();
        require(manager.owner() == deployer, "Deploy: ownership handoff failed");

        // Step 2: Owner-only setup. Reverts "Only callable by owner" if
        // step 1 was skipped — fail-loud guarantee.
        if (cfg.usdc != address(0)) {
            manager.allowlistToken(cfg.usdc);
        }
        if (cfg.mxnb != address(0)) {
            manager.allowlistToken(cfg.mxnb);
        }

        uint256 collectionId = manager.registerCollection(
            COLLECTION_NAME,
            fallbackURI,
            treasury, // royalty receiver — Mi Tanda treasury for the Genesis collection
            COLLECTION_ROYALTY_BPS
        );
        require(collectionId == 1, "Deploy: expected first collection id == 1");
        manager.setActiveCollection(collectionId);
    }

    // ─────────────────────────────────────────────────────────────────
    // Verification
    // ─────────────────────────────────────────────────────────────────

    function _verify(DeployedContracts memory d, ChainConfig memory cfg, address treasury, address deployer)
        internal
        view
    {
        // Manager wiring
        require(d.manager.tandaImplementation() == address(d.tandaImpl), "verify: tandaImpl mismatch");
        require(d.manager.passNFT() == address(d.passNFT), "verify: passNFT mismatch");
        require(d.manager.receiptNFT() == address(d.receiptNFT), "verify: receiptNFT mismatch");
        require(d.manager.completionNFT() == address(d.completionNFT), "verify: completionNFT mismatch");
        require(d.manager.treasury() == treasury, "verify: treasury mismatch");
        require(d.manager.owner() == deployer, "verify: owner mismatch");

        // Fee config matches the standing constants
        require(d.manager.PLATFORM_FEE_BPS() == 200, "verify: PLATFORM_FEE_BPS != 200");
        require(d.manager.ORGANIZER_FEE_BPS() == 300, "verify: ORGANIZER_FEE_BPS != 300");

        // Token allowlist
        if (cfg.usdc != address(0)) {
            require(d.manager.isAllowedToken(cfg.usdc), "verify: USDC not allowlisted");
        }
        if (cfg.mxnb != address(0)) {
            require(d.manager.isAllowedToken(cfg.mxnb), "verify: MXNB not allowlisted");
        }

        // NFTs point back to Manager
        require(d.passNFT.manager() == address(d.manager), "verify: passNFT.manager mismatch");
        require(d.receiptNFT.manager() == address(d.manager), "verify: receiptNFT.manager mismatch");
        require(d.completionNFT.manager() == address(d.manager), "verify: completionNFT.manager mismatch");

        // Sponsored collection #1 is active
        (uint256 activeId,) = d.manager.getActiveCollection();
        require(activeId == 1, "verify: active collection id != 1");
    }

    // ─────────────────────────────────────────────────────────────────
    // JSON output
    // ─────────────────────────────────────────────────────────────────

    function _writeDeploymentJson(
        ChainConfig memory cfg,
        address deployer,
        address treasury,
        DeployedContracts memory d,
        uint256 subId,
        uint32 callbackGas
    ) internal {
        string memory contractsObj = "contracts";
        vm.serializeAddress(contractsObj, "TandaManager", address(d.manager));
        vm.serializeAddress(contractsObj, "TandaImplementation", address(d.tandaImpl));
        vm.serializeAddress(contractsObj, "MitandaPassNFT", address(d.passNFT));
        vm.serializeAddress(contractsObj, "MitandaReceiptNFT", address(d.receiptNFT));
        string memory contractsJson = vm.serializeAddress(contractsObj, "MitandaCompletionNFT", address(d.completionNFT));

        string memory tokensObj = "tokens";
        string memory tokensJson = "{}";
        if (cfg.usdc != address(0)) {
            tokensJson = vm.serializeAddress(tokensObj, "USDC", cfg.usdc);
        }
        if (cfg.mxnb != address(0)) {
            tokensJson = vm.serializeAddress(tokensObj, "MXNB", cfg.mxnb);
        }

        string memory vrfObj = "vrf";
        vm.serializeAddress(vrfObj, "coordinator", cfg.vrfCoordinator);
        vm.serializeString(vrfObj, "subscriptionId", vm.toString(subId));
        vm.serializeBytes32(vrfObj, "gasLane", cfg.gasLane);
        string memory vrfJson = vm.serializeUint(vrfObj, "callbackGasLimit", callbackGas);

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "chainName", cfg.name);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "treasury", treasury);
        vm.serializeString(root, "contracts", contractsJson);
        vm.serializeString(root, "tokens", tokensJson);
        vm.serializeString(root, "vrf", vrfJson);
        string memory finalJson = vm.serializeUint(root, "deployedAt", block.timestamp);

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, path);

        console.log("Deployment JSON written to:", path);
    }

    // ─────────────────────────────────────────────────────────────────
    // Logging
    // ─────────────────────────────────────────────────────────────────

    function _logPredictions(
        ChainConfig memory cfg,
        address deployer,
        address treasury,
        uint256 startNonce,
        Predicted memory p
    ) internal pure {
        console.log("");
        console.log("==== Mi Tanda Deploy ====");
        console.log("Chain:        ", cfg.name);
        console.log("Deployer:     ", deployer);
        console.log("Deployer nonce:", startNonce);
        console.log("Treasury:     ", treasury);
        console.log("VRF coord:    ", cfg.vrfCoordinator);
        console.log("");
        console.log("Predicted addresses:");
        console.log("  TandaImpl:    ", p.tandaImpl);
        console.log("  PassNFT:      ", p.passNFT);
        console.log("  ReceiptNFT:   ", p.receiptNFT);
        console.log("  CompletionNFT:", p.completionNFT);
        console.log("  Manager:      ", p.manager);
        console.log("");
    }

    function _logPostDeployInstructions(ChainConfig memory cfg, address manager, uint256 subId) internal pure {
        console.log("");
        console.log("==== POST-DEPLOY STEPS ====");
        console.log("");
        console.log("1. Add Manager as VRF consumer:");
        console.log("   cast send", cfg.vrfCoordinator);
        console.log("     'addConsumer(uint256,address)'");
        console.log("     subId:  ", subId);
        console.log("     manager:", manager);
        console.log("     --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY");
        console.log("");
        console.log("2. Fund VRF subscription with native ETH:");
        console.log("   cast send", cfg.vrfCoordinator);
        console.log("     'fundSubscriptionWithNative(uint256)'");
        console.log("     subId:  ", subId);
        console.log("     --value 0.1ether --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY");
        console.log("");
        console.log("3. Verify contracts on the block explorer:");
        console.log("   forge verify-contract <address> <ContractName> --chain", cfg.name);
        console.log("   (run for: TandaManager, Tanda impl, MitandaPassNFT, MitandaReceiptNFT, MitandaCompletionNFT)");
        console.log("");
        console.log("4. Update Receipt NFT fallback baseURI to the real CID (if INITIAL_FALLBACK_BASE_URI was the placeholder):");
        console.log("   cast send <receiptNFT> 'setDefaultFallbackBaseURI(string)' 'ipfs://<realCID>'");
        console.log("===========================");
    }
}
