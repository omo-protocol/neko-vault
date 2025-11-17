# OVault Cross-Chain Flow Diagrams

## Table of Contents
1. [Spoke Chain Deposit Flow](#spoke-chain-deposit-flow)
2. [Hub Chain Direct Deposit](#hub-chain-direct-deposit)
3. [Spoke Chain Withdrawal Flow](#spoke-chain-withdrawal-flow)
4. [Share Token Lifecycle](#share-token-lifecycle)
5. [Morpho Vault V2 Integration](#morpho-vault-v2-integration)

---

## Spoke Chain Deposit Flow

### Overview
User deposits USDT on Arbitrum (spoke) and receives vault shares on Arbitrum.

### Detailed Step-by-Step Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    SPOKE CHAIN (Arbitrum)                                     │
│                                                                               │
│  ┌─────────┐                                                                 │
│  │  User   │  1. Approve AssetOFT to spend 1000 USDT                        │
│  │ (Alice) │     assetOFT.approve(assetOFT, 1000e6)                         │
│  └────┬────┘                                                                 │
│       │                                                                       │
│       │  2. Call send() with compose message                                 │
│       │     assetOFT.send({                                                  │
│       │       dstEid: HYPEREVM_EID,           // Destination: Hub           │
│       │       to: COMPOSER_ADDRESS,            // Recipient: Composer       │
│       │       amountLD: 1000e6,                // 1000 USDT                 │
│       │       composeMsg: encode(              // Compose instructions      │
│       │         receiver: Alice,               // Final share recipient     │
│       │         dstEid: ARBITRUM_EID,          // Return shares here        │
│       │         minShares: 950e18              // Slippage protection        │
│       │       )                                                              │
│       │     }, { value: 0.01 ETH })            // LayerZero gas fee         │
│       ▼                                                                       │
│  ┌──────────────┐                                                            │
│  │  AssetOFT    │  3. Burns 1000 USDT from user                             │
│  │   (USDT)     │     _burn(Alice, 1000e6)                                  │
│  │              │                                                             │
│  │              │  4. Emits LayerZero message                                │
│  │              │     OFTSent(guid, dstEid, 1000e6, composeMsg)             │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  5. LayerZero relayers pick up message                            │
│         │     Message contains: amount + composeMsg                          │
│         │                                                                     │
└─────────┼─────────────────────────────────────────────────────────────────────┘
          │
          │ 🌐 Cross-chain transfer via LayerZero
          │    - DVNs verify message
          │    - Executors deliver message
          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    HUB CHAIN (HyperEVM)                                       │
│                                                                               │
│  ┌──────────────┐                                                            │
│  │  AssetOFT    │  6. Receives lzReceive() callback                         │
│  │   (USDT)     │     - Mints 1000 USDT to Composer                         │
│  │              │     _mint(COMPOSER, 1000e6)                                │
│  │              │                                                             │
│  │              │  7. Calls endpoint.sendCompose()                           │
│  │              │     - Forwards composeMsg to Composer                      │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  8. Composed message sent                                          │
│         ▼                                                                     │
│  ┌──────────────────┐                                                        │
│  │ VaultComposerSync│  9. Receives lzCompose() callback                     │
│  │                  │     Parameters:                                        │
│  │                  │     - _from: AssetOFT address                          │
│  │                  │     - amountReceived: 1000e6                           │
│  │                  │     - composeMsg: (Alice, ARBITRUM_EID, 950e18)       │
│  │                  │                                                         │
│  │                  │  10. Detects AssetOFT sender → DEPOSIT operation      │
│  │                  │                                                         │
│  │                  │  11. Approves VaultV2 to spend USDT                    │
│  │                  │      assetOFT.approve(vaultV2, 1000e6)                │
│  │                  │                                                         │
│  │                  │  12. Calls VaultV2.deposit()                           │
│  │                  │      shares = vault.deposit(1000e6, composer)          │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  13. Deposit request                                               │
│         ▼                                                                     │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │              VaultV2 (Morpho-style ERC-4626)              │               │
│  │                                                            │               │
│  │  14. accrueInterest() - Update total assets               │               │
│  │      - Loops through all adapters                         │               │
│  │      - Calls adapter.realAssets() for each                │               │
│  │      - Accrues performance & management fees              │               │
│  │                                                            │               │
│  │  15. previewDeposit(1000e6) → 950e18 shares              │               │
│  │      shares = assets * totalSupply / totalAssets          │               │
│  │                                                            │               │
│  │  16. Transfer assets from Composer to Vault               │               │
│  │      assetOFT.transferFrom(composer, vault, 1000e6)       │               │
│  │                                                            │               │
│  │  17. Mint shares to Composer                              │               │
│  │      _mint(composer, 950e18)                              │               │
│  │      totalSupply += 950e18                                │               │
│  │                                                            │               │
│  │  18. Allocate to liquidity adapter (if configured)        │               │
│  │      if (liquidityAdapter != 0) {                         │               │
│  │        allocateInternal(liquidityAdapter, data, 1000e6)   │               │
│  │      }                                                     │               │
│  │                                                            │               │
│  │  🔄 Assets may be allocated to Morpho Vault V2:          │               │
│  │     ┌─────────────────────────────────────┐              │               │
│  │     │  MorphoVaultV2Adapter                │              │               │
│  │     │                                       │              │               │
│  │     │  - Receives 1000 USDT from VaultV2   │              │               │
│  │     │  - Approves Morpho vault              │              │               │
│  │     │  - Calls morphoVault.deposit()        │              │               │
│  │     │  - Receives Morpho shares             │              │               │
│  │     │  - Earns yield from Morpho            │              │               │
│  │     └─────────────────────────────────────┘              │               │
│  │                                                            │               │
│  │  Returns: 950e18 shares minted                            │               │
│  └────────────────────────────────┬───────────────────────────┘              │
│                                    │                                          │
│         19. Shares received        │                                          │
│         ◄──────────────────────────┘                                          │
│         │                                                                     │
│  ┌──────┴───────────┐                                                        │
│  │ VaultComposerSync│  20. Check slippage protection                        │
│  │                  │      if (950e18 < minShares) revert!                   │
│  │                  │      ✓ 950e18 >= 950e18 → PASS                        │
│  │                  │                                                         │
│  │                  │  21. Approve ShareOFTAdapter                           │
│  │                  │      vault.approve(shareAdapter, 950e18)               │
│  │                  │                                                         │
│  │                  │  22. Transfer shares to ShareOFTAdapter                │
│  │                  │      vault.transfer(shareAdapter, 950e18)              │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  23. Shares transferred                                            │
│         ▼                                                                     │
│  ┌──────────────────┐                                                        │
│  │ ShareOFTAdapter  │  24. Receives 950e18 vault shares (LOCKED)            │
│  │   (Lockbox)      │      - Shares are now LOCKED in adapter               │
│  │                  │      - Balance: adapter owns 950e18 VaultV2 shares    │
│  │                  │                                                         │
│  │                  │  25. Calls OFT.send() to bridge shares back            │
│  │                  │      shareOFT.send({                                   │
│  │                  │        dstEid: ARBITRUM_EID,                           │
│  │                  │        to: Alice,                                      │
│  │                  │        amountLD: 950e18,                               │
│  │                  │        // NO compose message (simple transfer)         │
│  │                  │      }, { value: 0.01 ETH })                           │
│  │                  │                                                         │
│  │                  │  26. Emits LayerZero message                           │
│  │                  │      OFTSent(guid, ARBITRUM_EID, 950e18)              │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  27. LayerZero relayers pick up message                           │
│         │                                                                     │
└─────────┼─────────────────────────────────────────────────────────────────────┘
          │
          │ 🌐 Cross-chain transfer via LayerZero
          │    - Share adapter KEEPS vault shares locked
          │    - Message sent to mint ShareOFT on spoke
          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    SPOKE CHAIN (Arbitrum)                                     │
│                                                                               │
│  ┌──────────────┐                                                            │
│  │  ShareOFT    │  28. Receives lzReceive() callback                        │
│  │   (vUSDT)    │      - Mints 950e18 ShareOFT to Alice                     │
│  │              │      _mint(Alice, 950e18)                                  │
│  │              │                                                             │
│  │              │  29. Alice now owns 950e18 ShareOFT on Arbitrum           │
│  │              │      - Represents ownership of locked vault shares        │
│  │              │      - Can transfer, trade, or redeem later               │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  30. ShareOFT minted                                               │
│         ▼                                                                     │
│  ┌─────────┐                                                                 │
│  │  User   │  ✅ DEPOSIT COMPLETE!                                          │
│  │ (Alice) │     - Started with: 1000 USDT on Arbitrum                      │
│  │         │     - Ended with: 950 vUSDT shares on Arbitrum                 │
│  │         │     - Can now withdraw anytime to any chain                     │
│  └─────────┘                                                                 │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

### State Changes Summary

| Location | Contract | Before | After | Notes |
|----------|----------|--------|-------|-------|
| Arbitrum | AssetOFT | Alice: 1000 USDT | Alice: 0 USDT | Burned |
| Arbitrum | ShareOFT | Alice: 0 shares | Alice: 950 shares | Minted |
| HyperEVM | AssetOFT | Composer: 0 USDT | Vault: 1000 USDT | Minted then transferred |
| HyperEVM | VaultV2 | Composer: 0 shares | Composer: 0 shares | Minted then transferred |
| HyperEVM | VaultV2 | Adapter: 0 shares | Adapter: 950 shares | **LOCKED** |
| HyperEVM | ShareOFTAdapter | Locked: 0 | Locked: 950 shares | 1:1 backing |
| HyperEVM | Morpho Vault | 0 USDT | 1000 USDT | If liquidity adapter configured |

---

## Hub Chain Direct Deposit

### When user deposits directly on HyperEVM (no cross-chain)

```
┌──────────────────────────────────────────────────────────────┐
│                    HUB CHAIN (HyperEVM)                       │
│                                                               │
│  ┌─────────┐                                                 │
│  │  User   │  1. Has 1000 USDT (AssetOFT) on HyperEVM       │
│  │ (Alice) │                                                  │
│  └────┬────┘                                                 │
│       │                                                       │
│       │  2. Approve VaultV2                                  │
│       │     assetOFT.approve(vaultV2, 1000e6)               │
│       │                                                       │
│       │  3. Deposit directly to vault                        │
│       │     vault.deposit(1000e6, Alice)                     │
│       ▼                                                       │
│  ┌──────────────────────────────────────────┐               │
│  │         VaultV2 (ERC-4626)                │               │
│  │                                            │               │
│  │  4. Transfer USDT from Alice → Vault      │               │
│  │     assetOFT.transferFrom(Alice, vault)   │               │
│  │                                            │               │
│  │  5. Mint shares directly to Alice         │               │
│  │     _mint(Alice, 950e18)                  │               │
│  │                                            │               │
│  │  6. Allocate to Morpho Vault V2            │               │
│  │     if (liquidityAdapter) {                │               │
│  │       allocate(morphoAdapter, 1000e6)      │               │
│  │     }                                      │               │
│  └────────────────────────────────────────────┘               │
│         │                                                     │
│         │  7. Alice receives 950e18 VaultV2 shares          │
│         ▼                                                     │
│  ┌─────────┐                                                 │
│  │  User   │  ✅ Alice owns real VaultV2 shares             │
│  │ (Alice) │     - NOT ShareOFT                              │
│  │         │     - Can redeem directly on hub                │
│  │         │     - OR lock in ShareOFTAdapter for bridging   │
│  └─────────┘                                                 │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

**Key Difference**: Direct deposits on hub create **real VaultV2 shares**, not ShareOFT tokens. User can then:
- Redeem directly on hub
- OR transfer to ShareOFTAdapter → bridge to spoke chain

---

## Spoke Chain Withdrawal Flow

### User withdraws from Arbitrum and receives USDT on Arbitrum

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    SPOKE CHAIN (Arbitrum)                                     │
│                                                                               │
│  ┌─────────┐                                                                 │
│  │  User   │  1. Has 950e18 ShareOFT on Arbitrum                            │
│  │ (Alice) │     Wants to withdraw to USDT                                   │
│  └────┬────┘                                                                 │
│       │                                                                       │
│       │  2. Call ShareOFT.send() with compose message                        │
│       │     shareOFT.send({                                                  │
│       │       dstEid: HYPEREVM_EID,           // Destination: Hub           │
│       │       to: COMPOSER_ADDRESS,            // Recipient: Composer       │
│       │       amountLD: 950e18,                // All shares                 │
│       │       composeMsg: encode(              // Compose instructions      │
│       │         receiver: Alice,               // Final USDT recipient      │
│       │         dstEid: ARBITRUM_EID,          // Return USDT here          │
│       │         minAssets: 1010e6              // Slippage (profit!)        │
│       │       )                                                              │
│       │     }, { value: 0.01 ETH })            // LayerZero gas fee         │
│       ▼                                                                       │
│  ┌──────────────┐                                                            │
│  │  ShareOFT    │  3. Burns 950e18 ShareOFT from Alice                      │
│  │   (vUSDT)    │     _burn(Alice, 950e18)                                  │
│  │              │                                                             │
│  │              │  4. Emits LayerZero message                                │
│  │              │     OFTSent(guid, HYPEREVM_EID, 950e18, composeMsg)      │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  5. LayerZero relayers pick up message                            │
│         │                                                                     │
└─────────┼─────────────────────────────────────────────────────────────────────┘
          │
          │ 🌐 Cross-chain transfer via LayerZero
          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    HUB CHAIN (HyperEVM)                                       │
│                                                                               │
│  ┌──────────────────┐                                                        │
│  │ ShareOFTAdapter  │  6. Receives lzReceive() callback                     │
│  │   (Lockbox)      │     - UNLOCKS 950e18 vault shares                     │
│  │                  │     - Shares released from lockbox                     │
│  │                  │     vault.transfer(COMPOSER, 950e18)                   │
│  │                  │                                                         │
│  │                  │  7. Calls endpoint.sendCompose()                       │
│  │                  │     - Forwards composeMsg to Composer                  │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  8. Shares unlocked and transferred                                │
│         ▼                                                                     │
│  ┌──────────────────┐                                                        │
│  │ VaultComposerSync│  9. Receives lzCompose() callback                     │
│  │                  │     Parameters:                                        │
│  │                  │     - _from: ShareOFTAdapter address                   │
│  │                  │     - amountReceived: 950e18 shares                    │
│  │                  │     - composeMsg: (Alice, ARBITRUM_EID, 1010e6)       │
│  │                  │                                                         │
│  │                  │  10. Detects ShareOFT sender → WITHDRAW operation     │
│  │                  │                                                         │
│  │                  │  11. Calls VaultV2.redeem()                            │
│  │                  │      assets = vault.redeem(950e18, composer, composer) │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  12. Redeem request                                                │
│         ▼                                                                     │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │              VaultV2 (Morpho-style ERC-4626)              │               │
│  │                                                            │               │
│  │  13. accrueInterest() - Update total assets               │               │
│  │      - Calculate accrued yield from Morpho                │               │
│  │      - Accrue fees                                        │               │
│  │                                                            │               │
│  │  14. previewRedeem(950e18) → 1010e6 USDT                 │               │
│  │      assets = shares * totalAssets / totalSupply          │               │
│  │      (User made profit! 1010 > 1000)                      │               │
│  │                                                            │               │
│  │  15. Check liquidity                                      │               │
│  │      idleAssets = assetOFT.balanceOf(vault)               │               │
│  │      if (1010e6 > idleAssets && liquidityAdapter) {       │               │
│  │        // Need to withdraw from Morpho                    │               │
│  │        deallocate(morphoAdapter, needed)                  │               │
│  │      }                                                     │               │
│  │                                                            │               │
│  │  🔄 Deallocate from Morpho Vault V2:                     │               │
│  │     ┌─────────────────────────────────────┐              │               │
│  │     │  MorphoVaultV2Adapter                │              │               │
│  │     │                                       │              │               │
│  │     │  - Vault calls deallocate(1010e6)    │              │               │
│  │     │  - Adapter redeems from Morpho vault  │              │               │
│  │     │  - Receives 1010 USDT (with profit)   │              │               │
│  │     │  - Transfers USDT back to VaultV2     │              │               │
│  │     └─────────────────────────────────────┘              │               │
│  │                                                            │               │
│  │  16. Burn shares from Composer                            │               │
│  │      _burn(composer, 950e18)                              │               │
│  │      totalSupply -= 950e18                                │               │
│  │                                                            │               │
│  │  17. Transfer USDT to Composer                            │               │
│  │      assetOFT.transfer(composer, 1010e6)                  │               │
│  │                                                            │               │
│  │  Returns: 1010e6 USDT                                     │               │
│  └────────────────────────────────┬───────────────────────────┘              │
│                                    │                                          │
│         18. USDT received          │                                          │
│         ◄──────────────────────────┘                                          │
│         │                                                                     │
│  ┌──────┴───────────┐                                                        │
│  │ VaultComposerSync│  19. Check slippage protection                        │
│  │                  │      if (1010e6 < minAssets) revert!                   │
│  │                  │      ✓ 1010e6 >= 1010e6 → PASS                        │
│  │                  │                                                         │
│  │                  │  20. Approve AssetOFT for bridging                     │
│  │                  │      assetOFT.approve(assetOFT, 1010e6)                │
│  │                  │                                                         │
│  │                  │  21. Call AssetOFT.send() to bridge USDT back          │
│  │                  │      assetOFT.send({                                   │
│  │                  │        dstEid: ARBITRUM_EID,                           │
│  │                  │        to: Alice,                                      │
│  │                  │        amountLD: 1010e6,                               │
│  │                  │        // NO compose message                           │
│  │                  │      }, { value: 0.01 ETH })                           │
│  └──────┬───────────┘                                                        │
│         │                                                                     │
│         │  22. AssetOFT burns USDT                                           │
│         ▼                                                                     │
│  ┌──────────────┐                                                            │
│  │  AssetOFT    │  23. Burns 1010e6 USDT from Composer                      │
│  │   (USDT)     │      _burn(composer, 1010e6)                               │
│  │              │                                                             │
│  │              │  24. Emits LayerZero message                               │
│  │              │      OFTSent(guid, ARBITRUM_EID, 1010e6)                  │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  25. LayerZero relayers pick up message                           │
│         │                                                                     │
└─────────┼─────────────────────────────────────────────────────────────────────┘
          │
          │ 🌐 Cross-chain transfer via LayerZero
          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    SPOKE CHAIN (Arbitrum)                                     │
│                                                                               │
│  ┌──────────────┐                                                            │
│  │  AssetOFT    │  26. Receives lzReceive() callback                        │
│  │   (USDT)     │      - Mints 1010e6 USDT to Alice                         │
│  │              │      _mint(Alice, 1010e6)                                  │
│  └──────┬───────┘                                                            │
│         │                                                                     │
│         │  27. USDT minted                                                   │
│         ▼                                                                     │
│  ┌─────────┐                                                                 │
│  │  User   │  ✅ WITHDRAWAL COMPLETE!                                       │
│  │ (Alice) │     - Started with: 950 vUSDT shares on Arbitrum               │
│  │         │     - Ended with: 1010 USDT on Arbitrum                        │
│  │         │     - Profit: 10 USDT (from Morpho yield!)                     │
│  └─────────┘                                                                 │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

### State Changes Summary

| Location | Contract | Before | After | Notes |
|----------|----------|--------|-------|-------|
| Arbitrum | ShareOFT | Alice: 950 shares | Alice: 0 shares | Burned |
| Arbitrum | AssetOFT | Alice: 0 USDT | Alice: 1010 USDT | Minted |
| HyperEVM | ShareOFTAdapter | Locked: 950 shares | Locked: 0 shares | **UNLOCKED** |
| HyperEVM | VaultV2 | totalSupply includes 950 | totalSupply reduced by 950 | Burned |
| HyperEVM | Morpho Vault | 1000 USDT | ~0 USDT | Withdrawn with profit |
| HyperEVM | AssetOFT | Composer: 1010 USDT | Composer: 0 USDT | Burned for bridging |

---

## Share Token Lifecycle

### Understanding the 1:1 Backing Between Chains

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          SHARE TOKEN LIFECYCLE                           │
└─────────────────────────────────────────────────────────────────────────┘

HUB CHAIN (HyperEVM):
┌────────────────────────────────────────────────────────────────┐
│  VaultV2 Shares (Real ERC-20)                                  │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                │
│                                                                 │
│  Total Supply: 10,000 shares                                   │
│                                                                 │
│  Distribution:                                                  │
│  ├─ 5,000 shares: Held by users directly on HyperEVM          │
│  ├─ 3,000 shares: LOCKED in ShareOFTAdapter ◄──┐              │
│  ├─ 1,500 shares: Held by other contracts       │              │
│  └─ 500 shares: Fee recipients                  │              │
│                                                  │              │
│  ShareOFTAdapter (Lockbox)                      │              │
│  ━━━━━━━━━━━━━━━━━━━━━━━━                      │              │
│  Locked Shares: 3,000                           │              │
│  - These shares are LOCKED, not burned          │              │
│  - 1:1 backing for ShareOFT on spoke chains     │              │
│  - Can be unlocked when shares return from spoke│              │
└─────────────────────────────────────────────────┼──────────────┘
                                                   │
                         1:1 Backing Guarantee    │
                                                   │
SPOKE CHAINS (Arbitrum, Plasma, etc.):            │
┌─────────────────────────────────────────────────┼──────────────┐
│  ShareOFT (Synthetic Representation)            │              │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━             │              │
│                                                  │              │
│  Arbitrum:                                       │              │
│  Total Supply: 2,000 ShareOFT ─────────────────►┤              │
│  - Backed by 2,000 locked VaultV2 shares        │              │
│                                                  │              │
│  Plasma:                                         │              │
│  Total Supply: 1,000 ShareOFT ─────────────────►┤              │
│  - Backed by 1,000 locked VaultV2 shares        │              │
│                                                  │              │
│  TOTAL ACROSS ALL SPOKES: 3,000 ShareOFT        │              │
│  LOCKED ON HUB: 3,000 VaultV2 shares ◄──────────┘              │
│                                                                 │
│  ✅ INVARIANT: SUM(spokeShareOFT) = hubLockedShares           │
└─────────────────────────────────────────────────────────────────┘

KEY INSIGHTS:
1. VaultV2 shares are NEVER burned when bridged - only LOCKED
2. ShareOFT tokens are minted on spokes when shares are locked on hub
3. ShareOFT tokens are burned on spokes when shares are unlocked on hub
4. Total VaultV2.totalSupply() never changes due to bridging
5. All ShareOFT is backed 1:1 by real locked vault shares
```

---

## Morpho Vault V2 Integration

### How Assets Flow Through VaultV2 → Morpho Vault V2

```
┌──────────────────────────────────────────────────────────────────────────────┐
│              MORPHO VAULT V2 INTEGRATION (Hub Chain Only)                     │
└──────────────────────────────────────────────────────────────────────────────┘

USER DEPOSITS 1000 USDT VIA CROSS-CHAIN:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Step 1: Cross-chain deposit arrives at VaultV2
┌────────────────────────────────────────┐
│  VaultComposerSync                     │
│  - Receives 1000 USDT                  │
│  - Calls vault.deposit(1000, composer) │
└────────────┬───────────────────────────┘
             │
             ▼
┌────────────────────────────────────────────────────────────────┐
│  VaultV2                                                        │
│                                                                 │
│  1. accrueInterest()                                           │
│     ├─ Loop through all adapters                               │
│     ├─ adapter.realAssets() for each                           │
│     ├─ Update totalAssets                                      │
│     └─ Accrue performance & management fees                    │
│                                                                 │
│  2. previewDeposit(1000 USDT)                                  │
│     shares = 1000 * totalSupply / totalAssets                  │
│     returns 950 shares                                         │
│                                                                 │
│  3. Transfer 1000 USDT: Composer → VaultV2                     │
│     assetOFT.transferFrom(composer, vault, 1000e6)             │
│                                                                 │
│  4. Mint 950 shares to Composer                                │
│     _mint(composer, 950e18)                                    │
│                                                                 │
│  5. Auto-allocate to liquidityAdapter (if configured)          │
│     if (liquidityAdapter != address(0)) {                      │
│       allocateInternal(liquidityAdapter, liquidityData, 1000)  │
│     }                                                           │
└────────────┬───────────────────────────────────────────────────┘
             │
             │ allocate(1000 USDT)
             ▼
┌────────────────────────────────────────────────────────────────┐
│  MorphoVaultV2Adapter (implements IAdapter)                    │
│                                                                 │
│  allocate(bytes data, uint256 assets, bytes4 sig, address)    │
│  {                                                              │
│    1. Receive 1000 USDT from VaultV2                           │
│       (already transferred via safeTransfer)                   │
│                                                                 │
│    2. Approve Morpho vault to spend USDT                       │
│       IERC20(USDT).approve(morphoVault, 1000e6);              │
│                                                                 │
│    3. Deposit into Morpho Vault V2                             │
│       uint256 morphoShares = IMorphoVaultV2(morphoVault)       │
│         .deposit(1000e6, address(this));                       │
│       // Morpho mints shares to adapter                        │
│                                                                 │
│    4. Track allocation                                         │
│       strategyAllocations[strategyId] += 1000e6;               │
│       totalAllocations += 1000e6;                              │
│                                                                 │
│    5. Return market IDs for cap checking                       │
│       bytes32[] memory ids = new bytes32[](1);                 │
│       ids[0] = keccak256(abi.encode("MORPHO_USDC_MARKET"));   │
│       return (ids, int256(1000e6));                            │
│  }                                                              │
└────────────┬───────────────────────────────────────────────────┘
             │
             │ deposit(1000 USDT)
             ▼
┌────────────────────────────────────────────────────────────────┐
│  Morpho Vault V2 (External Protocol)                           │
│                                                                 │
│  Standard ERC-4626 vault that:                                 │
│  - Accepts USDT deposits                                       │
│  - Allocates to multiple Morpho markets                        │
│  - Generates yield through lending                             │
│  - Returns vault shares to depositor                           │
│                                                                 │
│  Vault receives: 1000 USDT                                     │
│  Vault mints: ~990 Morpho vault shares to adapter              │
│  USDT is now earning yield in Morpho markets!                  │
└─────────────────────────────────────────────────────────────────┘


USER WITHDRAWS AFTER YIELD ACCRUAL:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Step 1: Cross-chain withdrawal arrives at VaultV2
┌────────────────────────────────────────┐
│  VaultComposerSync                     │
│  - Receives 950 shares from unlock     │
│  - Calls vault.redeem(950, composer)   │
└────────────┬───────────────────────────┘
             │
             ▼
┌────────────────────────────────────────────────────────────────┐
│  VaultV2                                                        │
│                                                                 │
│  1. accrueInterest()                                           │
│     ├─ Loop through adapters, call realAssets()                │
│     ├─ Morpho adapter reports 1010 USDT worth (profit!)        │
│     ├─ Update totalAssets (increased due to yield)             │
│     └─ Accrue performance & management fees                    │
│                                                                 │
│  2. previewRedeem(950 shares)                                  │
│     assets = 950 * totalAssets / totalSupply                   │
│     returns 1010 USDT (user made profit!)                      │
│                                                                 │
│  3. Check idle liquidity                                       │
│     idleAssets = USDT.balanceOf(vault) = 50 USDT              │
│     needed = 1010 USDT                                         │
│     if (1010 > 50 && liquidityAdapter) {                       │
│       deallocateInternal(liquidityAdapter, data, 960);         │
│     }                                                           │
└────────────┬───────────────────────────────────────────────────┘
             │
             │ deallocate(960 USDT)
             ▼
┌────────────────────────────────────────────────────────────────┐
│  MorphoVaultV2Adapter                                          │
│                                                                 │
│  deallocate(bytes data, uint256 assets, bytes4, address)      │
│  {                                                              │
│    1. Calculate Morpho shares to redeem                        │
│       uint256 morphoShares = IMorphoVaultV2(morphoVault)       │
│         .previewWithdraw(960e6);                               │
│                                                                 │
│    2. Redeem from Morpho Vault V2                              │
│       uint256 usdtReceived = IMorphoVaultV2(morphoVault)       │
│         .redeem(morphoShares, address(this), address(this));   │
│       // Morpho burns shares, returns USDT with profit         │
│                                                                 │
│    3. Track deallocation                                       │
│       strategyAllocations[strategyId] -= 960e6;                │
│       totalAllocations -= 960e6;                               │
│                                                                 │
│    4. Approve VaultV2 to pull USDT back                        │
│       IERC20(USDT).approve(vault, 960e6);                      │
│                                                                 │
│    5. Return market IDs                                        │
│       bytes32[] memory ids = new bytes32[](1);                 │
│       ids[0] = keccak256(abi.encode("MORPHO_USDC_MARKET"));   │
│       return (ids, -int256(960e6));                            │
│  }                                                              │
└────────────┬───────────────────────────────────────────────────┘
             │
             │ redeem(shares) → returns 960 USDT + profit
             ▼
┌────────────────────────────────────────────────────────────────┐
│  Morpho Vault V2                                               │
│                                                                 │
│  - Burns Morpho vault shares from adapter                      │
│  - Withdraws USDT from Morpho markets                          │
│  - Returns 960 USDT to adapter (includes accrued yield)        │
│  - Adapter now has liquid USDT ready for VaultV2              │
└─────────────────────────────────────────────────────────────────┘
             │
             │ USDT transferred back
             ▼
┌────────────────────────────────────────────────────────────────┐
│  VaultV2 (continues withdrawal)                                │
│                                                                 │
│  4. Pull USDT from adapter                                     │
│     USDT.transferFrom(adapter, vault, 960e6)                   │
│     Now vault has: 50 (idle) + 960 (from Morpho) = 1010 USDT  │
│                                                                 │
│  5. Burn user's shares                                         │
│     _burn(composer, 950e18)                                    │
│                                                                 │
│  6. Transfer USDT to composer                                  │
│     USDT.transfer(composer, 1010e6)                            │
│                                                                 │
│  Returns: 1010 USDT (original 1000 + 10 profit!)              │
└─────────────────────────────────────────────────────────────────┘


YIELD TRACKING & REPORTING:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

The adapter continuously reports current value:

┌────────────────────────────────────────────────────────────────┐
│  MorphoVaultV2Adapter.realAssets()                             │
│                                                                 │
│  Called by VaultV2.accrueInterest() every transaction:         │
│                                                                 │
│  function realAssets() external view returns (uint256) {       │
│    // Get current Morpho shares owned by adapter               │
│    uint256 morphoShares = IMorphoVaultV2(morphoVault)          │
│      .balanceOf(address(this));                                │
│                                                                 │
│    // Convert to USDT value (includes accrued yield)           │
│    uint256 usdtValue = IMorphoVaultV2(morphoVault)             │
│      .convertToAssets(morphoShares);                           │
│                                                                 │
│    return usdtValue;                                           │
│    // Example: Initially 1000, later 1010 due to yield         │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘

This allows VaultV2 to:
1. Track real-time value including Morpho yield
2. Calculate accurate share prices
3. Accrue performance fees on Morpho profits
4. Detect losses (if Morpho position decreases)
```

### Key Integration Points

| Component | Responsibility | Key Functions |
|-----------|---------------|---------------|
| **VaultV2** | Core vault logic, share accounting | `deposit()`, `redeem()`, `accrueInterest()` |
| **MorphoVaultV2Adapter** | Interface to Morpho protocol | `allocate()`, `deallocate()`, `realAssets()` |
| **Morpho Vault V2** | Yield generation | `deposit()`, `redeem()`, `convertToAssets()` |
| **VaultComposerSync** | Cross-chain orchestration | `lzCompose()`, routes to VaultV2 |
| **ShareOFTAdapter** | Share lockbox | Lock/unlock vault shares for bridging |

### Morpho Yield Flow

```
User Deposits
     │
     ▼
VaultV2 (mints shares)
     │
     ├─► MorphoVaultV2Adapter.allocate()
     │        │
     │        ▼
     │   Morpho Vault V2 (earns yield in markets)
     │        │
     │        │ [Time passes, yield accrues]
     │        │
     │        ▼
     │   Adapter.realAssets() reports increased value
     │        │
     │        ▼
     ├─── VaultV2.accrueInterest() sees profit
     │        │
     │        ▼
     └─── Share price increases ✅
              │
              │ [User decides to withdraw]
              │
              ▼
     VaultV2.redeem() with higher value
              │
              ▼
     MorphoVaultV2Adapter.deallocate()
              │
              ▼
     Morpho Vault V2 returns USDT + profit
              │
              ▼
     User receives more USDT than deposited ✅
```

---

## Summary

### Key Takeaways

1. **VaultV2 is Unchanged** ✅
   - No modifications needed
   - Works with existing Morpho adapters
   - Cross-chain is purely additive

2. **Share Lockbox Pattern** 🔒
   - Shares are LOCKED on hub, not burned
   - ShareOFT on spokes represents locked shares
   - 1:1 backing maintained at all times

3. **Morpho Integration** 💰
   - Deposits auto-allocate to Morpho Vault V2
   - Yield accrues in Morpho markets
   - Withdrawals pull from Morpho when needed
   - Performance fees applied to Morpho profits

4. **Cross-Chain Security** 🛡️
   - Two-phase slippage protection
   - LayerZero DVN verification
   - Refund mechanisms for failures
   - No custodial trust required

---

**Created**: 2025-01-17  
**Status**: Ready for testnet deployment ✅
