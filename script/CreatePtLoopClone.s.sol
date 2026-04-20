// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {PtLoopController, PtLoopConfig} from "../src/controllers/cross_venue/PtLoopController.sol";
import {CrossVenueCommandLib} from "../src/base/CrossVenueCommandLib.sol";

/// @notice Creates a live PT-USDai-18JUN2026 / Morpho Blue loop clone. Demo-sized.
///
///         Env vars:
///           PRIVATE_KEY      — deployer / owner
///           FACTORY          — ArchetypeFactory on Ritual
///           BASE_VAULT       — VaultV2 on Base
///           ADAPTER_URL      — adapter HTTPS endpoint
///           FUND_WEI         — optional; if >0, calls fundAndSchedule with msg.value = FUND_WEI
contract CreatePtLoopClone is Script {
    // Arb PT-USDai-18JUN2026 (confirmed via Pendle + Morpho GraphQL).
    address constant PENDLE_MARKET = 0x8A8A557b90eC79496a18a1f9C9DA8Bbd7DB86Fd3;
    bytes32 constant MORPHO_MARKET_ID = 0x958b40fcd0df023c156ec4a7eb8ffd47985b19d8bb02a36fb0af1bfc837fd605;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("FACTORY");
        address baseVault = vm.envAddress("BASE_VAULT");
        string memory adapterUrl = vm.envString("ADAPTER_URL");
        address owner = vm.addr(pk);

        bytes32 strategyId = vm.envBytes32("STRATEGY_ID");
        bytes32 marketRef = bytes32(uint256(uint160(PENDLE_MARKET)));

        PtLoopConfig memory cfg = PtLoopConfig({
            marketRef: marketRef,
            maxSlippageBps: 100,                              // 1%
            maxLoops: 1,                                       // single atomic flash sandwich
            loopNotionalUsd: 10_000_000,                       // $10 per iteration
            bufferTargetUsd: 15_000_000,                       // $15
            bufferMinUsd:    5_000_000,                        // top up when <$5
            destinationRef: keccak256("dest:arb:ptloop"),
            bufferStalenessSeconds: 120_000,                   // 2min (Ritual ms scale)
            envelopeTtlSeconds: 3600,                          // 1h (Base seconds scale)
            targetLeverageBps: 40_000,                         // 4x
            hfMinBps: 12_000,                                  // 1.20 HF floor
            targetChainId: 42161,
            morphoMarketId: MORPHO_MARKET_ID
        });

        PtLoopController.InitParams memory p = PtLoopController.InitParams({
            owner: owner,
            vaultManager: owner,
            baseVault: baseVault,
            baseAsset: BASE_USDC,
            strategyId: strategyId,
            adapterUrl: adapterUrl,
            executor: address(0),                              // set via bootstrapClone (ECIES)
            cfg: cfg,
            // Base gateway knows PM/HL/PAUSE/REFILL — PT loop reuses HL's CCTP-burn primitive;
            // the destinationRef routes the burn to Arb (PtLoopExecutor clone).
            topUpCommandType: CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER,
            funder: owner,                                     // demo: same EOA funds + manages
            reserveDestinationRef: keccak256("dest:refill"),
            minBaseReserveUsd: 0                               // disable auto-unwind for demo
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId, "pt-usdai-clean"));

        vm.startBroadcast(pk);
        address clone = ArchetypeFactory(factory).createPtLoop(p, salt);
        vm.stopBroadcast();

        console.log("=== PT Loop clone created ===");
        console.log("Clone:           ", clone);
        console.log("Owner:           ", owner);
        console.log("Pendle market:   ", PENDLE_MARKET);
        console.log("Morpho market id:");
        console.logBytes32(MORPHO_MARKET_ID);
        console.log("Target leverage: 4x  |  HF floor: 1.20  |  L_max at 91.5% LLTV ~ 11.76x");
        console.log("Buffers:         $5 min / $15 target per cycle; $10 notional");
        console.log("Next: bootstrapClone for secrets, then fundAndSchedule + deposit USDC on Base");
    }
}
