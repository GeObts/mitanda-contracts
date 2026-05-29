# Mi Tanda Base Sepolia — Live Test Run
Date: 2026-05-28
Network: Base Sepolia (chainId 84532)

## Deployed Contracts (all verified on Basescan)
- TandaManager: 0x6341E995bb0C665A36971368E4D5860A2ad46E2a
- Tanda implementation: 0x52ff9dBb6124E3EBCEbA75A875A43d1752c0F277
- MitandaPassNFT: 0x00e904e04156d13Eb35D8404053e2eDE02aDAB96
- MitandaReceiptNFT: 0x1CB29BCb3Dc1bF7B4A7083F779c488BF4a55573d
- MitandaCompletionNFT: 0x7Ee43871c368901652F9b15A2ed28603Bc7A0bB9

## Live Test Tanda
- Tanda address: 0xa0B74E35889686Fb4056FAE0B96F7b51cCb33972
- tandaId: 1
- Contribution: 5 USDC per cycle
- 3 participants: Alice/Bob/Carol
- Payout order: [1, 0, 2] → Bob, Alice, Carol
- Status: ACTIVE, cycle 1 payable at startTimestamp + 86400

## VRF Wiring
- Subscription ID: 48186721464479422715819618384301755026938302239233192020450741762336434827114
- Add consumer tx: 0xb005e2a5c32823d20269207fa202363207c8708f9ce4aaca2a48a50932668d3c
- Fund tx: 0xf6dbc1bf923f65965526f36be17012fdf51fe7a1af9a7ee1ed7fee8ec62ee572
- Subscription balance: 0.04 ETH

## What Was Proven
- CREATE2 deterministic deployer integration
- EIP-1167 clone deployment + initialization on real chain
- Manager → Tanda → NFT call path
- Real Circle USDC transferFrom against fresh clone
- Chainlink VRF v2.5 end-to-end (request → callback → Fisher-Yates → state transition)
- 2 gwei gas lane is correct and fulfills
- 2.5M callback gas limit has ample headroom for 3-participant shuffle
- Soulbound Pass NFT minting via onlyTanda gate
