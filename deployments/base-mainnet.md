# Mi Tanda — Base Mainnet Deployment

Date: 2026-06-03
Network: **Base (chainId 8453)**
Code: v4 audit-hardened (`_mint` NFTs, `nonReentrant` markDefaulter) — commit `d17e039`.
Rehearsed first on Base Sepolia (see commit `201fc58`).

## Deployed Contracts
- **TandaManager:** `0x74b6Fc121A40C1A3282af6Bd78074AC3C2a32814`
- Tanda implementation: `0x7Ee43871c368901652F9b15A2ed28603Bc7A0bB9`
- MitandaPassNFT: `0xe9A5c185F5ab2A9434a880C92DB8A51014C75e5f`
- MitandaReceiptNFT: `0x0dDb8bC0bD88d7933Dc4B54618768156a3558443`
- MitandaCompletionNFT: `0xCF006fe8E86E7Fd92A7fD2f9E0A64dc4761AfAB3`

Explorer: https://basescan.org/address/0x74b6Fc121A40C1A3282af6Bd78074AC3C2a32814

## Config
- Treasury: `0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66`
- Owner: `0xe4d579f6195c5A4f084132a8250139d7B84b8f63` (deployer)
- Fees: platform 2% / organizer 3% / recipient 95% (200 / 300 bps)
- Allowlisted token: USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bda02913` (no MXNB on Base).
- Genesis sponsored collection (#1) registered + active, royalty receiver = treasury.

## VRF Wiring (Chainlink VRF v2.5, native ETH)
- Coordinator: `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`
- Subscription ID: `96962708632878719095006892215857070533570294314705997602906995270009408934655`
- Gas lane (2 gwei): `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab`
- Callback gas limit: 2,500,000 (== coordinator maxGasLimit)
- Consumer: **the Manager** `0x74b6Fc121A40C1A3282af6Bd78074AC3C2a32814` — registered via
  `addConsumer` tx `0x1dd0427d181df17468263017fbf32768ab811dc69df08ef957d00993a2083e29`
  (verified on-chain). Tanda clones are never consumers; the Manager orchestrates VRF.
- Sub owner: deployer. Native-funded (~0.003 ETH at deploy time; top up for more headroom).

## Deploy
- `forge script Deploy.s.sol --broadcast` (CREATE for impl + 3 NFTs, CREATE2 via Arachnid for
  the Manager, ownership accept, token allowlist, collection setup).
- Broadcast log: `broadcast/Deploy.s.sol/8453/run-latest.json`.

## Verification
- Tanda implementation runtime bytecode is an **exact match** to the local v4 build (the same
  audit-hardened code live on Arbitrum One and rehearsed on Base Sepolia).
- Manager wiring re-checked on-chain: implementation, 3 NFTs, treasury, owner, fees (200/300),
  USDC allowlisted, VRF subId — all correct. All 3 NFTs `manager()` point back to the Manager.

Mi Tanda is now live on **two mainnets**: Arbitrum One (`deployments/arbitrum-one-mainnet.md`)
and Base.
