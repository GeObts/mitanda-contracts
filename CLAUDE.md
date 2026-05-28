# Mi Tanda — Contracts Repo Instructions

Standing instructions for any work in this repo. Re-read before each task.

## Compiler & build

- **Solidity:** 0.8.20 pinned (no `^`, no floating versions)
- **Optimizer:** enabled, 200 runs
- **EVM version:** `paris`
- **OpenZeppelin:** v5.0.2 pinned exactly — do not bump
- Always run `forge fmt` and `forge build` before considering a task done. A task is not done until both succeed cleanly.

## Target chains

- **Mainnets:** Arbitrum One (`42161`) + Base (`8453`)
- **Testnets:** Arbitrum Sepolia (`421614`) + Base Sepolia (`84532`)

## Token allowlist (per chain)

Tokens are an allowlist on `TandaManager`, not hardcoded in `Tanda`. Adding/removing tokens is owner-gated.

| Chain | Token | Address |
|---|---|---|
| Arbitrum One | MXNB | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` |
| Arbitrum One | USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Arbitrum Sepolia | MXNB | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` |
| Base mainnet | USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bda02913` |
| Base Sepolia | USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

## Chainlink VRF v2.5

Native ETH payment (not LINK).

### Coordinators

- **Arbitrum One:** `0x3c0ca683b403e37668ae3dc4fb62f4b29b6f7a3e`
- **Base mainnet:** `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`
- **Testnets:** TBD (added when testnet subscriptions are provisioned)

### Subscription IDs (mainnet)

- **Arbitrum One:** `11240680591437763657426634372631496509334343723905297879968059449257187273316`
- **Base mainnet:** `4676623716448654338207070578936083867210213261505417415016690928850530604801`

## Fee model

Every payout is split:

- **Recipient:** 95% of the pot
- **Platform treasury:** 2%
- **Tanda creator (organizer):** 3%

Fees are deducted at payout time inside `Tanda`. Recipients are credited via pull-payment, never pushed.

- **Initial treasury address:** `0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66`
- Treasury is configurable on `TandaManager` by owner.

### Sponsorship slot — third revenue stream

In addition to the 2%/3% transaction fees, the system has a **sponsorship slot**: sponsors (artists, brands like Bitso) pay **off-chain** to occupy `TandaManager`'s currently-active sponsored-collection slot. While a sponsor holds the slot, every newly-constructed `Tanda` snapshots their `collectionId` and mints receipt NFTs carrying that sponsor's brand art + ERC-2981 royalty payout. The on-chain transaction is just `setActiveCollection(id)`; payment lives off-chain.

## Insurance model (real-funds slash pool)

Every contribution is paired with a per-cycle **insurance premium** so the slash pool has physical funds backing it.

### Constants

- `INSURANCE_BPS = 1000` (10%) — mirrored on `TandaManager` and `Tanda`.
- `premiumPerCycle = contributionAmount * INSURANCE_BPS / BPS_DENOMINATOR`.

For `contributionAmount` = 10 USDC and `INSURANCE_BPS` = 1000, premium = 1 USDC per cycle.

### When premium is charged

- `join()` charges `contributionAmount + premiumPerCycle`. The base contribution covers cycle 1; the premium goes into `insuranceBalance[participant]`.
- `makePayment(cyclesToPay)` charges `(contributionAmount + premiumPerCycle) * cyclesToPay`. Contributions flow to cycle pots at `triggerPayout` time; premiums accumulate in the participant's insurance balance.

### Storage

- `mapping(address => uint256) public insuranceBalance` — per-participant accumulated premiums.
- `uint256 public totalInsuranceReserve` — running sum for monitoring / accounting integrity.

### On default

When `markDefaulter(defaulter)` runs, `insuranceBalance[defaulter]` is moved to `slashedPool` and zeroed; `totalInsuranceReserve` decreases by the same amount. The defaulter's already-paid contributions stay in the cycle-pot stream (they were used by past recipients); only their insurance is forfeited.

### At completion (`_completeTanda`)

1. **Refund insurance** — each still-active participant's `insuranceBalance` is moved to `pendingWithdrawals` and zeroed.
2. **Refund contribution excess** — if `paidUntilCycle > payoutOrder.length` (participant pre-paid before defaults shortened the tanda), refund the unused cycles' contributions.
3. **Distribute `slashedPool`** — physically backed by forfeited insurance:
   - 95% split equally among active participants (pro-rata = equal in a ROSCA).
   - 2% to treasury (also absorbs equal-split rounding dust).
   - 3% to creator.

Defensive: a balance assertion checks `balanceOf(this) >= totalPendingCredits + slashedPool` before distribution. Should never trip; loud failure if accounting drifts.

### Implication

Honest participants get their own insurance back plus a pro-rata share of defaulters' forfeited insurance — a real cash reward for staying paid up. Defaulters lose only their accumulated premiums (not their past contributions, which were already cycled through).

## Tanda privacy & scheduled start

### Scheduled start

A tanda can opt into a delayed start by passing a non-zero `scheduledStart` (Unix timestamp) to `createTanda`:

- **`scheduledStart == 0`** (default): tanda auto-starts as soon as the last seat fills. Original behavior.
- **`scheduledStart > 0`**: must be `>= block.timestamp + 1 days` (1-day minimum lead time, enforced in Manager via `ScheduledStartTooSoon(provided, earliest)`).

If the last seat fills *before* `scheduledStart`, the tanda stays OPEN. Anyone can then call the permissionless **`start()`** function once `block.timestamp >= scheduledStart` to trigger the VRF request and transition to ACTIVE. `start()` reverts with:

- `TandaNotFull()` if seats aren't filled yet
- `ScheduledStartNotReached(currentTime, scheduledStart)` if the time hasn't come

If the last seat fills *after* `scheduledStart`, the auto-start in `join()` / `joinWithInvite()` fires immediately. `start()` is redundant in that case.

### Privacy modes

`ITanda.TandaPrivacy` is the shared enum:

- **`PUBLIC`** — anyone can join via `join()`. Calling `joinWithInvite(...)` reverts `NotPrivateTanda()`.
- **`PRIVATE_TICKETED`** — only invitees holding a creator-signed EIP-712 ticket can join via `joinWithInvite(deadline, signature)`. Calling `join()` reverts `NotPublicTanda()`.

Privacy is set once at `initialize` and cannot be changed.

> **PRIVATE_TICKETED behavior note.** A `PRIVATE_TICKETED` tanda with no signed invites cannot fill. It sits in `OPEN` state indefinitely. This is intentional — the creator is fully responsible for distributing invites. There is no on-chain refund mechanism for the creator's gas spent on creation. Frontend UX should highlight this responsibility before creation.

### EIP-712 invite tickets

The creator pre-signs an `Invite` struct off-chain, scoped to a specific clone via the EIP-712 domain.

**Domain (auto-derived by `EIP712Upgradeable._domainSeparatorV4()`):**

```
name:             "MiTanda"
version:          "1"
chainId:          <current chain ID>
verifyingContract: <this tanda clone's address>
```

**Type:**

```solidity
Invite {
    address invitee;
    uint256 tandaId;
    uint256 deadline;
}
```

A signature from chain X, tanda A, version 1 cannot be replayed on chain Y, tanda B, or under any future version bump.

### Frontend flow (end-to-end)

1. **Creator signs off-chain.** Frontend constructs the typed-data domain + Invite struct, prompts the creator's wallet to sign via `eth_signTypedData_v4`.
2. **Creator distributes the link.** Frontend encodes `(signature, deadline, tandaId, cloneAddress)` in a URL.
3. **Invitee opens the link.** Frontend prompts them to approve `contributionAmount + premium` to the tanda clone.
4. **Invitee submits.** Frontend calls `joinWithInvite(deadline, signature)` on the clone. The contract:
   - Checks `block.timestamp <= deadline`.
   - Computes `ticket = keccak256(msg.sender, tandaId, deadline)`.
   - Verifies `!usedTickets[ticket] && !revokedTickets[ticket]`.
   - Recovers the EIP-712 digest signer via `ECDSA.recover(digest, signature)`.
   - Verifies `signer == creator`.
   - Marks `usedTickets[ticket] = true`, then runs the join logic.

### Replay protection

Tickets are keyed by `keccak256(invitee, tandaId, deadline)` — not by signature bytes — so ticket lookups work even if the signature is never on-chain. Each ticket is single-use. Re-using a redeemed ticket reverts `TicketAlreadyUsed()`.

### Revocation

Creator can call `revokeInvite(invitee, deadline)` at any time to set `revokedTickets[ticket] = true`. Subsequent `joinWithInvite` calls with that ticket revert `InviteAlreadyRevoked()`. Reverts `NotCreator()` if called by anyone else.

The error name `InviteAlreadyRevoked` (vs. the event `InviteRevoked`) is deliberate — Solidity puts events and errors in the same identifier namespace, so they must differ.

> **Ticket-deadline coupling.** Each invite ticket is hashed as `keccak256(invitee, tandaId, deadline)`. Different deadlines for the same `(invitee, tandaId)` pair produce different tickets. If a creator wants to extend an invite's deadline, they must:
>
> 1. Issue a new invite with the new deadline, AND
> 2. Optionally call `revokeInvite(invitee, oldDeadline)` to invalidate the original.
>
> Otherwise both tickets remain valid until expiry. The invitee can still only join once (subsequent attempts hit `AlreadyJoined`), but signed messages with both deadlines circulate. For most cases this is acceptable — the frontend handles deadline management transparently. Creators with high-trust scenarios who issue many invites should track and revoke old deadlines proactively.

### Why `EIP712Upgradeable`

The non-upgradeable OZ `EIP712` stores `_HASHED_NAME` and `_HASHED_VERSION` as constructor-set **immutables**. EIP-1167 clones do NOT run the implementation's constructor, so those immutables would be uninitialized in every clone — every signature verification would fail. `EIP712Upgradeable` moves the same state into ERC-7201 namespaced storage and exposes `__EIP712_init(name, version)` for the initializer. This is the standard pattern for EIP-712 with clones / proxies.

## Contract architecture

Six contracts in `src/` (v2 — replaces the v1 reference in `src/legacy/`).

1. **`MitandaErrors.sol`** — custom errors library. Single source of truth for every revert reason in the system.
2. **`TandaManager.sol`** — singleton per chain (NOT cloned). Holds the `Tanda` implementation address as an immutable and produces per-tanda clones via `Clones.clone(tandaImpl)`. Token allowlist + VRF orchestrator + treasury config + fee config + sponsored-collection registry (rotating single active slot) + pausable.
3. **`Tanda.sol`** — per-tanda state machine, deployed once as an **EIP-1167 implementation contract**. Each `TandaManager.createTanda(...)` call produces a minimal-proxy clone of this implementation, then calls `initialize(...)` to set per-clone storage. Token-agnostic (token passed at init). Pull-payment for all value flows. Automatic timing-based defaulter detection (no creator privilege). Auto-mints NFTs at lifecycle events. Fee deduction on payout (95/2/3 split).
4. **`MitandaPassNFT.sol`** — soulbound ERC-721 implementing EIP-5192. `locked()` returns true; all transfers revert. Minted automatically on `join()`. One per `(participant, tanda)`.
5. **`MitandaReceiptNFT.sol`** — standalone OZ v5 ERC-721 with ERC-2981. NOT upgradeable. **Frozen-at-mint**: when minted, the contract snapshots `{baseURI, royaltyReceiver, royaltyBps}` from the Manager's sponsored collection into per-token local storage. `tokenURI` and `royaltyInfo` always read this per-token snapshot — never the Manager live. Minted automatically on each payout.
6. **`MitandaCompletionNFT.sol`** — soulbound ERC-721 implementing EIP-5192. Batch-minted at tanda completion for non-defaulted participants. Stackable across tandas for reputation. View function `reputationScore(address)` returns count of badges held.

### NFT minting pattern

NFTs are auto-minted in the same transaction as the triggering action (`join`, `triggerPayout`, completion). Users never call mint functions directly. Each NFT contract has an `onlyTanda` modifier that validates `msg.sender` against the Manager's tanda registry.

## Sponsorship slot model

`TandaManager` holds a registry of sponsored collections. Exactly one slot is active at any time; new `Tanda` instances snapshot the active `collectionId` at construction and keep it for their lifetime — even if the Manager later rotates the active slot, that tanda's receipts continue to reference the original ID.

### Manager storage

```solidity
struct SponsoredCollection {
    string name;              // e.g. "Mi Tanda Genesis", "Bitso x Mi Tanda"
    string baseURI;           // ipfs:// or https:// folder
    address royaltyReceiver;  // artist or sponsor brand wallet
    uint96 royaltyBps;        // out of 10_000; e.g. 500 = 5%
    uint256 activatedAt;      // timestamp of registration
    bool exists;
}

mapping(uint256 => SponsoredCollection) public collections;
uint256 public nextCollectionId;       // monotonic; starts at 1 — ID 0 reserved as "unset"
uint256 public activeCollectionId;     // currently-active slot
```

### Manager owner functions

- `registerCollection(name, baseURI, royaltyReceiver, royaltyBps) -> collectionId` — adds a slot but does NOT activate it. Validates `royaltyReceiver != 0`, `royaltyBps <= 1000` (10% cap).
- `setActiveCollection(collectionId)` — switches the active slot. Emits `ActiveCollectionChanged(oldId, newId)`. Validates the collection exists.
- `forceUpdateCollectionBaseURI(collectionId, newBaseURI)` — emergency only (e.g. lost IPFS pin). Emits `CollectionBaseURIForceUpdated(collectionId, oldURI, newURI)`. **Does NOT affect already-minted receipts** because each receipt reads its own frozen snapshot. Only future mints under that collection ID see the new URI.

### Tanda snapshot

`Tanda` exposes `uint256 public immutable sponsoredCollectionId;`, set in the constructor to `manager.activeCollectionId()`. If `activeCollectionId == 0` at construction (no sponsor active), the tanda still works; receipts fall back to a default URI in the Receipt NFT contract — graceful, never reverts.

### Frozen-at-mint guarantee

The Receipt NFT stores per-token `{ frozenBaseURI, frozenRoyaltyReceiver, frozenRoyaltyBps }` at mint time. Once minted, a receipt's art and royalty payout cannot be retroactively changed by Manager slot rotation. Implication: forceful URI updates and slot rotations are forward-only.

## Deployment model

Two-step deployment per chain — `Tanda` is an EIP-1167 implementation that all per-tanda clones delegate to.

1. **Deploy the `Tanda` implementation once.** Verify on the explorer. Save the address.
2. **Deploy `TandaManager`** passing the step-1 address as `_tandaImplementation`, plus the VRF coordinator, subscription ID, gas lane, callback gas limit, and treasury.

Every subsequent `createTanda(...)` call on `TandaManager` produces a minimal-proxy clone via `Clones.clone(tandaImpl)` and immediately invokes `initialize(...)` on the clone. Only the implementation contract holds runtime logic; every clone has its own storage.

### Tanda lifecycle

- **Constructor:** empty body that calls `_disableInitializers()` (OZ v5 `Initializable` pattern). The implementation itself can never be used as a tanda.
- **`initialize(...)`:** guarded by the `initializer` modifier. Called exactly once by `TandaManager.createTanda` immediately after `Clones.clone`. All per-tanda state is set here.
- **Storage:** regular storage slots, **NOT immutable** (proxies can't have immutables). Each clone has its own slot for `tandaId`, `token`, `contributionAmount`, `payoutInterval`, `participantCount`, `gracePeriod`, `manager`, `creator`, `sponsoredCollectionId`, etc.

### `initialize` parameters

```solidity
function initialize(
    uint256 tandaId,
    address token,
    uint256 contributionAmount,
    uint256 payoutInterval,
    uint16  participantCount,
    uint256 gracePeriod,
    address manager,
    address creator,
    uint256 sponsoredCollectionId
) external initializer;
```

`TandaManager` is responsible for passing trusted values: `manager = address(this)`, `creator = msg.sender`, `sponsoredCollectionId = activeCollectionId` snapshotted at the moment of `createTanda`.

### `ITanda` interface

Lives at `src/interfaces/ITanda.sol`. `TandaManager` imports `ITanda` for typed calls into clones (`initialize`, `assignPayoutOrder`). Manager **never** imports the concrete `Tanda` contract — this is what makes the two files compilable in either order.

### Implementation immutability

`tandaImplementation` is **immutable per Manager instance**. Upgrading Tanda logic requires deploying a new Manager pointed at the new implementation. Existing tandas continue to operate on the original (Manager + implementation) pair. This is intentional — protects users from owner-driven logic substitution.

### v2 considerations (deferred, non-blocking)

- **Per-token contribution minimums.** Currently `createTanda` only enforces `contributionAmount > 0`. A future version may add `mapping(address => uint256) minContribution` on `TandaManager` (settable per allowlisted token), so each token can carry its own minimum (e.g., 10 USDC vs 100 MXNB). Backward-compatible — wouldn't affect existing tandas.

## Workflow rules

- **Custom errors only.** Every revert uses an error from `MitandaErrors.sol`. No `require("string")` anywhere in `src/`.
- **Pull-payment mandatory.** All value transfers credit balances first; recipients call `withdraw()`. Never push.
- **Deploy-script constant verification.** The deploy script MUST assert that `TandaManager.PLATFORM_FEE_BPS()`, `ORGANIZER_FEE_BPS()`, `BPS_DENOMINATOR()`, and `INSURANCE_BPS()` each equal the same-named constant on the `Tanda` implementation. Any mismatch must abort the deploy — the two contracts must be built and shipped as a matched pair.
- **Dust convention.**
  - Cycle pot rounding dust → **recipient** (the 95% share absorbs it via `pot - platform - organizer`).
  - Slash pool rounding dust → **treasury** (the 2% share absorbs it).
  - Insurance premium charges are exact at the input level (`premiumPerCycle * cyclesToPay`); no dust possible.
- **EIP-5192 for soulbound NFTs.** `locked(tokenId)` returns `true`; transfer functions revert with a custom error.
- **ERC-2981 for Receipt NFT royalties.** Per-collection royalty receiver + bps, **frozen on the token at mint time**. The Receipt NFT never reads the Manager live for `tokenURI` or `royaltyInfo` — both come from per-token storage.
- **No Superrare / SovereignBatchMint integration.** Receipt NFT is a standalone OZ v5 ERC-721 + ERC-2981. Don't import, inherit, or comment-reference Superrare patterns.
- **Tests before deploy scripts.** No deploy script lands without test coverage of the contracts it deploys.
- **Never deploy without me reviewing the script first.** This includes testnet broadcasts. Show the script and the intended `--rpc-url` / `--broadcast` plan; wait for approval.
- **Never commit `.env` or any secrets.** No mnemonic, no raw private key, no API key in tracked files.
- **`src/legacy/` is reference only.** NEVER compile, test, deploy, or import from `src/legacy/`. Excluded from build in `foundry.toml`.
- When unsure whether something is a contract-logic change vs. an environmental fix (imports, pragmas, remappings), stop and ask. Don't change contract semantics on your own.
