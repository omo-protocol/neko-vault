// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {IScheduler, IRitualWallet} from "../../interfaces/ritual/IScheduler.sol";

/// @notice External library that a controller delegatecalls to set up tick + valuation schedules.
///         Kept external to keep the controller runtime under EIP-170. Uses the deployed
///         scheduler's 10-param ABI: (data, gas, startBlock, numCalls, frequency, ttl,
///         maxFeePerGas, priority, value, payer). Hard constraint: numCalls × frequency ≤ 10_000
///         (~58min) per schedule.
///
///         Cost model: each scheduled tick pays two independent bills from the controller's
///         RitualWallet — the tx gas (`gas × maxFeePerGas`) AND the async HTTP precompile fee
///         (`perCallHttpBudget`, drawn by the 0x0805 precompile at call time). Prior revisions
///         of this library only budgeted for gas and the HTTP bill silently drained funds,
///         causing renewals to fail and schedules to die mid-run (observed 2026-04 live demo).
///
///         `perCallHttpBudget` is a conservative upper bound — it governs balance checks only;
///         it does not cap actual spend. Typical value: 2e15 (0.002 RITUAL) per call.
library SchedulerSetupLib {
    error InvalidConfig();
    error InsufficientDeposit();

    uint32 internal constant SCHEDULER_TTL = 100;

    /// @notice Initial schedule setup. Deposits `ritualDeposit` into the RitualWallet and
    ///         registers both schedules.
    ///
    ///         Required deposit = 2 × (gas×maxFee + perCallHttpBudget) × (tickNumCalls + valuationNumCalls).
    ///         The 2× buffers one full renewal cycle: current batch + one renewed batch. Without it,
    ///         `maybeRenew` always fails its balance check and schedules silently die.
    ///
    ///         Pass `perCallHttpBudget = 0` only if the scheduled callback never emits a 0x0805
    ///         async HTTP call (uncommon — both MultiLeg and PtLoop do). When 0 the deposit check
    ///         collapses to gas-only, matching legacy behavior.
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
        uint256 ritualDeposit,
        uint256 perCallHttpBudget
    ) external returns (uint256 tickId, uint256 valId) {
        if (tickFreq == 0 || valuationFreq == 0 || gasLimit == 0 || lockDurationBlocks == 0) revert InvalidConfig();
        if (tickNumCalls == 0 || valuationNumCalls == 0) revert InvalidConfig();

        uint256 perCall = uint256(gasLimit) * maxFeePerGas + perCallHttpBudget;
        uint256 required = perCall * (uint256(tickNumCalls) + uint256(valuationNumCalls)) * 2;
        if (ritualDeposit < required) revert InsufficientDeposit();

        IRitualWallet(RitualPrecompiles.RITUAL_WALLET).deposit{value: ritualDeposit}(uint256(lockDurationBlocks));

        IScheduler sched = IScheduler(RitualPrecompiles.SCHEDULER);

        tickId = sched.schedule(
            abi.encodeWithSelector(tickSelector, uint256(0)),
            gasLimit,
            uint32(block.number) + tickFreq,
            tickNumCalls,
            tickFreq,
            SCHEDULER_TTL,
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
            SCHEDULER_TTL,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }

    /// @notice Renew a single recurring callback (no RitualWallet deposit). Used by controllers
    ///         to self-extend their schedules when the current batch nears exhaustion.
    function renewCallback(
        bytes4 selector,
        uint32 freq,
        uint32 numCalls,
        uint32 gasLimit,
        uint256 maxFeePerGas,
        uint32 startBlockOffset
    ) external returns (uint256 id) {
        if (freq == 0 || numCalls == 0 || gasLimit == 0) revert InvalidConfig();
        id = IScheduler(RitualPrecompiles.SCHEDULER).schedule(
            abi.encodeWithSelector(selector, uint256(0)),
            gasLimit,
            uint32(block.number) + (startBlockOffset == 0 ? freq : startBlockOffset),
            numCalls,
            freq,
            SCHEDULER_TTL,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }

    /// @notice Combined "am I in the renewal window + can I afford it + renew" helper. Returns
    ///         the new schedule id if renewal fired, else 0. Caller stores the id.
    ///
    ///         Skips silently if not in the last `renewThreshold` executions of the current
    ///         batch, or if RitualWallet balance can't cover a full new batch's
    ///         (gas + HTTP budget) costs — prevents partial renewal that would drain remaining
    ///         funds without producing a usable schedule.
    function maybeRenew(
        bytes4 selector,
        uint256 executionIndex,
        uint32 numCalls,
        uint32 freq,
        uint32 gasLimit,
        uint256 maxFeePerGas,
        uint32 renewThreshold,
        uint256 perCallHttpBudget
    ) external returns (uint256 id) {
        if (numCalls == 0) return 0;
        if (executionIndex + renewThreshold < numCalls) return 0;
        uint256 cost = (uint256(gasLimit) * maxFeePerGas + perCallHttpBudget) * numCalls;
        if (IRitualWallet(RitualPrecompiles.RITUAL_WALLET).balanceOf(address(this)) < cost) return 0;
        id = IScheduler(RitualPrecompiles.SCHEDULER).schedule(
            abi.encodeWithSelector(selector, uint256(0)),
            gasLimit, uint32(block.number) + freq, numCalls, freq,
            SCHEDULER_TTL, maxFeePerGas, 0, 0, address(this)
        );
    }
}
