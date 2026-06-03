# Mi Tanda — Arbitrum One Mainnet Deployment

Date: 2026-06-03
Network: **Arbitrum One (chainId 42161)**
Code: v4 audit-hardened (`_mint` NFTs, `nonReentrant` markDefaulter) — see commit `d17e039`.

## Deployed Contracts
- **TandaManager:** `0xa88aB3B81D9cA6BB556104B72e73b722D3abE678`
- Tanda implementation: `0xD55c72B7fF4777D382Bd69b9B27Cc1da799d119d`
- MitandaPassNFT: `0x52ff9dBb6124E3EBCEbA75A875A43d1752c0F277`
- MitandaReceiptNFT: `0x00e904e04156d13Eb35D8404053e2eDE02aDAB96`
- MitandaCompletionNFT: `0x1CB29BCb3Dc1bF7B4A7083F779c488BF4a55573d`

Explorer: https://arbiscan.io/address/0xa88aB3B81D9cA6BB556104B72e73b722D3abE678

## Config
- Treasury: `0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66`
- Owner: `0xe4d579f6195c5A4f084132a8250139d7B84b8f63` (deployer)
- Fees: platform 2% / organizer 3% / recipient 95% (200 / 300 bps)
- Allowlisted tokens (real mainnet):
  - USDC: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`
  - MXNB: `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA`
- Genesis sponsored collection (#1) registered + active, royalty receiver = treasury.

## VRF Wiring (Chainlink VRF v2.5, native ETH)
- Coordinator: `0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e`
- Subscription ID: `39124666372397226298450322444773052468399208338933848659824100593694266892739`
- Gas lane (2 gwei): `0x9e9e46732b32662b9adc6f3abdf6c5e926a666d174a4d6b8e39c4cca76a38897`
- Callback gas limit: 2,500,000 (== coordinator maxGasLimit)
- Consumer: **the Manager** `0xa88aB3B81D9cA6BB556104B72e73b722D3abE678` — registered (consumer list verified on-chain). The Tanda clones are never consumers; the Manager orchestrates VRF and forwards the seed to each clone via `assignPayoutOrder`.
- Sub owner: deployer (so `addConsumer` was authorized).

## Deploy
- Method: `forge script Deploy.s.sol --broadcast` (CREATE for impl + 3 NFTs, CREATE2 via Arachnid for the Manager, ownership accept, token allowlist, collection setup).
- Total gas cost: ~0.000243 ETH.
- Broadcast log: `broadcast/Deploy.s.sol/42161/run-latest.json`.

## Verification
- Tanda implementation runtime bytecode is an **exact match** to the local v4 build (byte-for-byte the audit-hardened code that passed the 91-test suite and the full fork lifecycle).
- Manager wiring re-checked on-chain: implementation, all 3 NFTs, treasury, owner, fees (200/300), USDC + MXNB allowlisted, VRF subId — all correct.
- All 3 NFTs `manager()` point back to the Manager and mint via `_mint` (no `onERC721Received` callback in join/payout/completion).

## Note on lifecycle testing
The full ROSCA lifecycle — create → join → VRF auto-start → per-cycle pay/payout/claim → defaulter handling + insurance → completion with no trapped funds — was proven end-to-end **through the real app UI** on an Anvil fork of these exact v4 contracts (see the `mitanda-app` repo `e2e-evidence/`). The mainnet implementation bytecode is identical to what was tested.
