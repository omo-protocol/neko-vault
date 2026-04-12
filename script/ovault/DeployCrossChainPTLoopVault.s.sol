// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {Deployment, PTLoopAutomationConfig, PTLoopDeploymentParams} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract DeployCrossChainPTLoopVault is StrategyLaunchpadScriptBase {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        StrategyVaultFactory factory = StrategyVaultFactory(vm.envAddress("STRATEGY_FACTORY"));

        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            curator: vm.envOr("CURATOR", owner),
            enableTimelock: vm.envOr("ENABLE_TIMELOCK", false),
            enableOmnichainVault: vm.envOr("ENABLE_OMNICHAIN_VAULT", false),
            asset: vm.envAddress("ASSET"),
            market: vm.envAddress("MARKET"),
            ptToken: vm.envAddress("PT_TOKEN"),
            valuer: vm.envAddress("VALUER"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            strategyIdData: bytes(vm.envString("STRATEGY_ID_DATA")),
            targetReserveBps: vm.envUint("TARGET_RESERVE_BPS"),
            minReserveBps: vm.envUint("MIN_RESERVE_BPS"),
            maxUnwindSlippageBps: vm.envUint("MAX_UNWIND_SLIPPAGE_BPS"),
            automationConfig: _loadAutomationConfig(),
            absoluteCap: vm.envUint("ABSOLUTE_CAP"),
            relativeCap: vm.envUint("RELATIVE_CAP"),
            salt: vm.envOr("SALT", bytes32(0)),
            useOffchainValuer: vm.envOr("USE_OFFCHAIN_VALUER", false),
            venueConfig: _loadVenueConfig(),
            chainManifests: _loadChainManifests()
        });

        vm.startBroadcast(privateKey);
        Deployment memory deployment = factory.createPTLoopVault(params);
        vm.stopBroadcast();

        console2.log("PT-loop cross-chain vault deployed");
        _logDeployment(factory, deployment);
    }

    function _loadAutomationConfig() internal view returns (PTLoopAutomationConfig memory) {
        return PTLoopAutomationConfig({maxEntrySlippageBps: uint16(vm.envUint("AUTOMATION_MAX_ENTRY_SLIPPAGE_BPS"))});
    }
}
