// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {IScheduler, IRitualWallet} from "../../interfaces/ritual/IScheduler.sol";

/// @notice External library that a controller delegatecalls to set up tick + valuation schedules.
///         Kept external to keep the controller runtime under EIP-170. Uses the deployed
///         scheduler's 10-param ABI: (data, gas, startBlock, numCalls, frequency, ttl,
///         maxFeePerGas, priority, value, payer). Hard constraint: numCalls × frequency ≤ 10_000
///         (~58min) per schedule. Caller must re-invoke before the batch expires or provide
///         an off-chain keeper to call `fundAndSchedule` again.
library SchedulerSetupLib {
    error InvalidConfig();

    uint32 internal constant SCHEDULER_TTL = 100;

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
        if (tickNumCalls == 0 || valuationNumCalls == 0) revert InvalidConfig();

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
}
