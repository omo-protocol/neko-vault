// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IAutomatedWithdrawalController, IOnchainStrategyValuer} from "../controllers/StrategyControllerInterfaces.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IUniversalValuerOffchain} from "../adapters/interfaces/IUniversalValuerOffchain.sol";

/// @title NoOpStrategyAgent
/// @notice Minimal on-chain agent registered on `UniversalAdapterEscrow.setStrategy`. The sleeve
///         requires the agent to expose `IOnchainStrategyValuer.quoteCurrentAssets` — we proxy
///         that to `UniversalValuerOffchain.getValue(strategyId)`. Automation callbacks return
///         empty, so the sleeve's try/catch falls through to plain allocate/deallocate.
///         This agent is deliberately stateless and non-privileged. All strategy execution
///         actually happens on Ritual (via `MultiLegController` / `PtLoopController`); on Base the
///         agent is just a bytecode-level interface conformance point.
contract NoOpStrategyAgent is IAutomatedWithdrawalController, IOnchainStrategyValuer {
    address public immutable valuer;
    bytes32 public immutable strategyId;

    constructor(address valuer_, bytes32 strategyId_) {
        valuer = valuer_;
        strategyId = strategyId_;
    }

    /// @inheritdoc IOnchainStrategyValuer
    function quoteCurrentAssets() external view override returns (uint256 assets, bool healthy) {
        try IUniversalValuerOffchain(valuer).getValue(strategyId) returns (uint256 v) {
            return (v, true);
        } catch {
            return (0, false);
        }
    }

    /// @inheritdoc IAutomatedWithdrawalController
    function quoteAutomaticAllocation(uint256)
        external
        pure
        override
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        return new IUniversalAdapterEscrow.Call[](0);
    }

    /// @inheritdoc IAutomatedWithdrawalController
    function quoteAutomaticWithdrawal(uint256)
        external
        pure
        override
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        return new IUniversalAdapterEscrow.Call[](0);
    }
}
