# Felix Vanilla Markets: Morpho Blue v1 Fork

## Overview
Felix Vanilla Markets are forked **1:1 from Morpho Blue v1 markets**.

## Architecture
Felix Vanilla Markets are built directly on the Morpho lending stack, specifically leveraging the standard Morpho smart contracts for core functionality:
- Borrowing
- Lending  
- Liquidations

This includes deploying isolated markets that mirror Morpho Blue's v1 architecture, which introduced:
- Permissionless, over-collateralized lending pools
- Utilization-based floating rates
- Support for Ethereum and compatible chains (e.g., Base)

## Implementation Details
Official Felix documentation confirms that Vanilla Markets use the Morpho contract for operations on **HyperEVM** (Hyperliquid's EVM layer), with mechanics matching Morpho Blue v1's design:

### Core Mechanics
- **Health factor calculations**
- **Liquidation incentives** 
- **Piecewise linear APR curves**

### Liquidation Protocol
Liquidations in Vanilla follow the exact Morpho protocol logic:
- Third-party bots can seize collateral at a discount when borrower's health factor drops below `1.0`
- Uses the same formulas:
  - `repaidShares`
  - `seizedAssets`

## Key Features
This 1:1 fork allows Felix to inherit Morpho Blue v1's efficiency and risk management while adapting for assets on HyperEVM:
- **HYPE**
- **UBTC**
- **ETH**
- **USDC**
- **feUSD**

### Design Characteristics
- **No redemption mechanics**
- **Block-by-block variable APRs** driven by utilization: `U = Total Borrows / Total Supply`
- **Lender APY formula**: `Borrow APR × U - protocol spread`

## Technical Foundation
- Morpho Blue v1's codebase is **open-sourced under GPL**
- Enables permissionless deployments
- Felix's implementation is a direct adaptation, evidenced by:
  - Shared liquidation bot compatibility
  - Identical yield mechanics

## Version Context
While Morpho has evolved (e.g., v2 for fixed-rate loans and MetaMorpho vaults), Felix Vanilla sticks to the **v1 model** for its core markets, rolled out in **May 2025**.

## Advantages
This setup provides enhanced capital efficiency over traditional CDPs like feUSD:
- Lower max LTVs
- No swap slippage for asset-native borrowing



---
description: For any questions, join the Felix Discord, and reach out to contributors.
---

# Market 2: Vanilla

## Overview

The Vanilla Markets is a borrow and lend market built on Morpho.

* **Borrowers** deposit HYPE or other assets as collateral and can borrow USDhl, USDT0, USDe, etc.
* **Lenders** deposit assets to earn borrower interest.

#### Markets

| Market | Market ID | Liquidation Discount |
|--------|-----------|---------------------|
| UETH / USDT0 | 0xf9f0473b23ebeb82c83078f0f0f77f27ac534c9fb227cb4366e6057b6163ffbf | |
| UETH / USDhl | 0xb5b215bd2771f5ed73125bf6a02e7b743fadc423dfbb095ad59df047c50d3e81 | |
| kHYPE / HYPE | 0x64e7db7f042812d4335947a7cdf6af1093d29478aff5f1ccd93cc67f8aadfddc | |
| kHYPE / USDhl | 0xc0a3063a0a7755b7d58642e9a6d3be1c05bc974665ef7d3b158784348d4e17c5 | |
| kHYPE / USDT0 | 0x78f6b57d825ef01a5dc496ad1f426a6375c685047d07a30cd07ac5107ffc7976 | |
| WHYPE / USDe | 0x292f0a3ddfb642fbaadf258ebcccf9e4b0048a9dc5af93036288502bde1a71b1 | 12.67% |
| WHYPE / USDT0 | 0xace279b5c6eff0a1ce7287249369fa6f4d3d32225e1629b04ef308e0eb568fb0 | 12.67% |
| WHYPE / USDhl | 0x96c7abf76aed53d50b2cc84e2ed17846e0d1c4cc28236d95b6eb3b12dcc86909 | 12.67% |
| UBTC / USDe | 0x5fe3ac84f3a2c4e3102c3e6e9accb1ec90c30f6ee87ab1fcafc197b8addeb94c | 7.41% |
| UBTC / USDT0 | 0x707dddc200e95dc984feb185abf1321cabec8486dca5a9a96fb5202184106e54 | 7.41% |
| UBTC / USDhl | 0x87272614b7a2022c31ddd7bba8eb21d5ab40a6bcbea671264d59dc732053721d | 7.41% |
| wstHYPE / HYPE | 0xe9a9bb9ed3cc53f4ee9da4eea0370c2c566873d5de807e16559a99907c9ae227 | |
| wstHYPE / USDT0 | 0xb39e45107152f02502c001a46e2d3513f429d2363323cdaffbc55a951a69b998 | |
| wstHYPE / USDhl | 0x1f79fe1822f6bfe7a70f8e7e5e768efd0c3f10db52af97c2f14e4b71e3130e70 | |
| hwHLP / USDhl | 0xe500760b79e397869927a5275d64987325faae43326daf6be5a560184e30a521 | |
| hwHLP / USDT0 | 0x86d7bc359391486de8cd1204da45c53d6ada60ab9764450dc691e1775b2e8d69 | |
| wHLP / USDhl | 0x920244a8682a53b17fe15597b63abdaa3aecec44e070379c5e43897fb9f42a2b | |
| wHLP / USDT0 | 0xd4fd53f612eaf411a1acea053cfa28cbfeea683273c4133bf115b47a20130305 | |
| kHYPE-PT / HYPE | 0x1df0d0ebcdc52069692452cb9a3e5cf6c017b237378141eaf08a05ce17205ed6 | |
| kHYPE-PT / USDT0 | 0x888679b2af61343a4c7c0da0639fc5ca5fc5727e246371c4425e4d634c09e1f6 | |
| kHYPE-PT / USDhl | 0xe0a1de770a9a72a083087fe1745c998426aaea984ddf155ea3d5fbba5b759713 | |

#### Lending Vaults

| Vault | Address |
|-------|---------|
| USDe | 0x835febf893c6dddee5cf762b0f8e31c5b06938ab |
| USDT0 | 0xfc5126377f0efc0041c0969ef9ba903ce67d151e |
| USDT0 (Frontier) | 0x9896a8605763106e57A51aa0a97Fe8099E806bb3 |
| USDhl | 0x9c59a9389D8f72DE2CdAf1126F36EA4790E2275e |
| USDhl (Frontier) | 0x66c71204B70aE27BE6dC3eb41F9aF5868E68fDb6 |
| HYPE | 0x2900ABd73631b2f60747e687095537B673c06A76 |

## Liquidations

Vanilla Markets are built on the standard Morpho smart contracts, which means liquidations follow the same mechanism as on Ethereum Mainnet or Base. Liquidations occur when a borrower's health factor falls below 1.

Any third party—typically bots or keepers—can call the `liquidate` function to repay a portion of a borrower's debt and seize a corresponding amount of collateral at a discount.

The relevant contract for liquidations of Vanilla Markets on HyperEVM is the **Morpho contract**, deployed at:

```
0x68e37de8d93d3496ae143f2e900490f6280c57cd
```

[View on Purrsec](https://purrsec.com/address/0x68e37de8d93d3496ae143f2e900490f6280c57cd/contract)

### Liquidate Function

* **Contract:** Morpho Blue Core
* **Purpose:** Liquidates an undercollateralized borrower's position by seizing collateral in exchange for repaying a portion of their debt. This helps maintain protocol solvency and allows liquidators to earn a liquidation bonus.
* **Function Signature:**

```solidity
liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
) external returns (uint256 seizedAssetsOut, uint256 repaidAssetsOut);
```

**Parameters:**

* `marketParams`: Struct containing the market's configuration (collateral/loan asset addresses, oracle, lltv, etc.)
* `borrower`: The address of the user being liquidated.
* `seizedAssets`: The amount of collateral (in collateral token units) to seize. Set this to `0` if you're specifying `repaidShares` instead.
* `repaidShares`: The amount of debt shares to repay. Set this to `0` if you're specifying `seizedAssets` instead.
* `data`: Optional payload for advanced integrations. Used for callbacks or flash logic.

**Return Values:**

* `seizedAssetsOut`: The actual amount of collateral seized.
* `repaidAssetsOut`: The actual amount of loan token paid to repay the borrower's debt.

**Notes:**

* **Either `seizedAssets` or `repaidShares` must be set to zero**. The protocol computes the corresponding value based on price and the liquidation incentive.
* Only undercollateralized positions (health factor < 1) are eligible for liquidation.
* A liquidation incentive is applied to reward the liquidator with a discount on the seized collateral.
* A `onMorphoLiquidate` callback is supported if `data.length > 0`.

**Example Use Case:**  
If a liquidator wants to repay a borrower's debt worth 1,000 USDT0, they can call `liquidate(...)` with:

* `repaidShares` ≈ equivalent to 1,000 USDT0 worth of shares (calculated based on market totals)
* `seizedAssets = 0`
* Let the protocol compute the amount of collateral to seize (based on current oracle price and incentive factor)

### Open Source Bots

#### Liquidation Bot 1

**By:** [morpho-labs](https://github.com/morpho-labs/)

**Languages and Tools:** Typescript & Solidity

**Description:** A simple, fast, and easily deployable liquidation bot for the Morpho protocol. This bot is entirely based on RPC calls and is designed to be easy to configure, customizable, and ready to deploy on any EVM-compatible chain.

**Repository:** [Morpho-liquidation-bot](https://github.com/morpho-org/morpho-blue-liquidation-bot)

#### Liquidation Bot 2

**By:** [morpho-labs](https://github.com/morpho-labs/)

**Languages and Tools:** Typescript & Solidity

**Description:** This contribution presents a simple implementation of a liquidation bot that can liquidate unhealthy position on Morpho. Using Typescript and Solidity.

**Repository:** [Morpho-liquidation-bot-educational](https://github.com/morpho-org/morpho-liquidation-bot-educational)

#### Liquidation Bot 3

**By:** [etherhood](https://github.com/etherhood/)

**Languages and Tools:** Rust & Solidity

**Description:** This contribution presents a detailed strategy for liquidations using Rust and Solidity.

**Repository:** [Liquidator-Morpho](https://github.com/etherhood/Liquidator-Morpho)

#### Liquidation Bot 4

**By:** [zach030](https://github.com/zach030/)

**Languages and Tools:** Go & Solidity

**Description:** This contribution presents a detailed strategy for liquidations using Go and Solidity.

**Repository:** [morpho-liquidator-bot](https://github.com/zach030/morpho-liquidator-bot)