// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {IScheduler, IRitualWallet} from "../../interfaces/ritual/IScheduler.sol";

/// @notice External library that a controller delegatecalls to set up tick + valuation schedules.
///         Kept external (not inlined) to keep the controller runtime under EIP-170.
library SchedulerSetupLib {
    error InvalidConfig();

    /// @notice Per-batch numCalls for re-extension. Scheduler enforces `numCalls × frequency ≤ 10000`,
    ///         so the controller picks frequencies that satisfy `100 × tickFreq ≤ 10000` and similarly
    ///         for valuation. Defaults: tickFreq ≤ 100 (e.g. 100 = ~35s @ 350ms blocks).
    uint32 internal constant EXTEND_NUM_CALLS = 100;
    uint32 internal constant EXTEND_TTL = 100;

    /// @notice Re-schedule a stream when the caller is near the end of its current batch.
    ///         Returns the new callId, or 0 if no extension was needed (caller keeps existing id).
    ///         Caller passes packed config (tickFreq | valuationFreq | gasLimit) + maxFeePerGas.
    function maybeExtend(
        bytes4 selector,
        bool isTick,
        uint256 executionIndex,
        uint96 packedConfig,
        uint256 maxFeePerGas
    ) external returns (uint256 callId) {
        if (executionIndex < EXTEND_NUM_CALLS - 5) return 0;
        if (packedConfig == 0) return 0;
        uint32 freq = isTick ? uint32(packedConfig) : uint32(packedConfig >> 32);
        uint32 gasLimit = uint32(packedConfig >> 64);
        if (freq == 0 || gasLimit == 0) return 0;
        callId = IScheduler(RitualPrecompiles.SCHEDULER).schedule(
            abi.encodeWithSelector(selector, uint256(0)),
            gasLimit,
            uint32(block.number) + freq,
            EXTEND_NUM_CALLS,
            freq,
            EXTEND_TTL,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }

    /// @param tickSelector        e.g. `MultiLegController.tick.selector`
    /// @param valuationSelector   e.g. `MultiLegController.syncValuation.selector`
    function fundAndScheduleBoth(
        bytes4 tickSelector,
        bytes4 valuationSelector,
        uint32 tickFreq,
        uint32 valuationFreq,
        uint32 tickNumCalls,
        uint32 valuationNumCalls,
        uint32 gasLimit,
        uint256 maxFeePerGas,
        uint32 lockDurationBlocks,
        uint256 ritualDeposit
    ) external returns (uint256 tickId, uint256 valId) {
        if (tickFreq == 0 || valuationFreq == 0 || gasLimit == 0 || lockDurationBlocks == 0) revert InvalidConfig();

        if (ritualDeposit > 0) {
            IRitualWallet(RitualPrecompiles.RITUAL_WALLET).deposit{value: ritualDeposit}(uint256(lockDurationBlocks));
        }

        IScheduler sched = IScheduler(RitualPrecompiles.SCHEDULER);

        tickId = sched.schedule(
            abi.encodeWithSelector(tickSelector, uint256(0)),
            gasLimit,
            uint32(block.number) + tickFreq,
            tickNumCalls,
            tickFreq,
            100,
            maxFeePerGas,
            0,
            0,
            address(this)
        );

        valId = sched.schedule(
            abi.encodeWithSelector(valuationSelector, uint256(0)),
            gasLimit,
            uint32(block.number) + valuationFreq,
            valuationNumCalls,
            valuationFreq,
            100,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }
}
