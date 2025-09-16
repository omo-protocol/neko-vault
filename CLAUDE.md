# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

This is a Foundry-based Solidity project. Use these commands:

- **Build**: `forge build` or `make forge ARGS="build"`
- **Test all**: `forge test` or `make forge ARGS="test"`
- **Test single file**: `forge test --match-path test/SpecificTest.sol`
- **Test with gas report**: `forge test --gas-report`
- **Coverage**: `forge coverage`
- **Format code**: `forge fmt`
- **Clean artifacts**: `forge clean`

The Makefile provides a convenience wrapper that uses the `no_via_ir` profile: `make forge ARGS="<command>"`.

## Architecture Overview

### Core Components

**VaultV2** (`src/VaultV2.sol`): Main ERC-4626 compliant vault contract that enables non-custodial asset allocation to various DeFi protocols. Key features:
- ERC-4626 and ERC-2612 (permit) compliant
- Role-based access control (Owner, Curator, Allocators, Sentinels)
- Timelocked configuration changes for security
- Caps system for risk management
- Fee structure (performance and management fees)

**VaultV2Factory** (`src/VaultV2Factory.sol`): Factory for deploying vault instances using CREATE2 for deterministic addresses.

### Adapter System

Adapters enable vaults to allocate to different protocols while maintaining a unified interface:

- **MorphoMarketV1Adapter**: Allocates to Morpho Market v1
- **MorphoVaultV1Adapter**: Allocates to Morpho Vault v1 (supports v1.0 and v1.1)
- **PendleV2Adapter**: Allocates to Pendle V2 (recent addition)

All adapters implement `IAdapter` interface and are deployed via corresponding factory contracts.

### Key Mechanisms

**Caps System**: ID-based allocation limits with absolute and relative caps to manage risk exposure across markets with shared risk factors.

**Liquidity Management**: Idle liquidity + optional liquidity adapter ensure withdrawal availability.

**Force Deallocate**: Permissionless function allowing in-kind redemptions to guarantee exits even when liquidity is constrained.

**Timelocks**: All curator configuration changes are timelockable for non-custodial guarantees. Functions can be "abdicated" by setting timelock to `type(uint256).max`.

### Project Structure

- `src/`: Core contracts
  - `adapters/`: Adapter contracts and interfaces
  - `interfaces/`: All interface definitions
  - `libraries/`: Utility libraries (ErrorsLib, EventsLib, MathLib, etc.)
  - `imports/`: External contract imports
- `test/`: Comprehensive test suite including unit and integration tests
  - `integration/`: Protocol-specific integration tests
  - `mocks/`: Test mock contracts

## Foundry Configuration

- Uses `via_ir` optimization by default for better gas efficiency
- High optimization runs (100,000) for production deployment
- Specific compilation profiles for imported contracts
- Fuzz testing with 2,048 runs
- EVM version: Cancun