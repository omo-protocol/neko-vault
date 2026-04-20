// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IScheduler {
    /// @notice Deployed scheduler on Ritual mainnet (0x56e7…) uses this 10-param ABI:
    ///         `schedule(data, gas, startBlock, numCalls, frequency, ttl, maxFee, priority, value, payer)`.
    ///         Official docs at shrinenet-docs describe a 9-param variant with `maxBlockNumber`/`useSelfPay`
    ///         — that's a NEWER version not yet deployed. Verified selector `0x1328c7c4` is present on the
    ///         proxy's implementation contract (`0x708a…`).
    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId);

    function cancel(uint256 callId) external;
}

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
}
