# Mi Tanda — Contracts

On-chain ROSCA (rotating savings club) dApp targeting Arbitrum One and Base. Mi Tanda brings Latin America's tanda savings tradition onchain with built-in defaulter insurance, automatic NFT receipts, and rotating artist/sponsor collections.

> **Web app lives in a separate repo:** [**GeObts/mitanda-app**](https://github.com/GeObts/mitanda-app) — the Next.js frontend that drives these contracts (create / join / pay / claim / release / defaulter), with fork-verified UI proof. The two repos together are the full project.

## Architecture

Six contracts:

- `MitandaErrors.sol` — single source of truth for all custom errors
- `TandaManager.sol` — singleton factory: token allowlist, VRF orchestrator, fee config, sponsored collection registry
- `Tanda.sol` — per-tanda state machine, deployed as EIP-1167 clones from a single implementation
- `MitandaPassNFT.sol` — soulbound proof-of-membership (EIP-5192)
- `MitandaCompletionNFT.sol` — soulbound completion badge, stackable for reputation
- `MitandaReceiptNFT.sol` — transferable payout receipt with frozen-at-mint sponsored art

Plus `src/interfaces/ITanda.sol` for clone-safe Manager → Tanda calls.

## Key features

- **Insurance model:** 10% premium per cycle, refunded to honest finishers, forfeited by defaulters and split among the honest
- **Sponsored collections:** rotating slot for artists/brands; receipts mint with the active collection's art
- **Private tandas:** EIP-712 signed invite tickets for friend-group tandas with Privy onboarding
- **VRF v2.5:** Chainlink-randomized payout order
- **Pull payments:** all credits land in `pendingWithdrawals`, claimed via `withdraw()`
- **Custom errors throughout:** zero require-strings

## Status

In active development for hackathon submission. Tests and deploy scripts pending.

## Build

```bash
forge build
```

See CLAUDE.md for full architecture documentation.
