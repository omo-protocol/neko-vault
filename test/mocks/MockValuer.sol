// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";

contract MockValuer {
    mapping(address => uint256) public values;
    mapping(bytes32 => uint256) public strategyValues;
    mapping(bytes32 => uint64) public reportTimestamps;

    function isValuationHealthy(address) external pure returns (bool) {
        return true;
    }

    function setValue(address target, uint256 value) external {
        values[target] = value;

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): Also set ESCROW_TOTAL strategy ID
        // This ensures tests using setValue(address) work with new getValue(ESCROW_TOTAL_ID) pattern
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", target));
        strategyValues[totalId] = value;
        reportTimestamps[totalId] = uint64(block.timestamp);
    }

    function setValue(bytes32 strategyId, uint256 value) external {
        strategyValues[strategyId] = value;
        reportTimestamps[strategyId] = uint64(block.timestamp);
    }

    function getValue(address target) external view returns (uint256) {
        return values[target];
    }

    function getValue(bytes32 strategyId) external view returns (uint256) {
        uint256 strategyValue = strategyValues[strategyId];

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): Support ESCROW_TOTAL fallback
        // If this is an ESCROW_TOTAL query and no strategy value set, try address-based fallback
        // This maintains backward compatibility with tests that use setValue(address)
        if (strategyValue == 0) {
            // Check if this looks like an ESCROW_TOTAL strategy ID by trying to extract the address
            // Format: keccak256(abi.encodePacked("ESCROW_TOTAL", address))
            // We can't reverse the hash, so we need tests to set the correct value
            // For now, just return the strategy value (tests should update to use setValue(bytes32))
        }

        return strategyValue;
    }

    function getReport(bytes32 strategyId) external view returns (IUniversalValuerOffchain.ValueReport memory report) {
        report.timestamp = reportTimestamps[strategyId];
    }

}