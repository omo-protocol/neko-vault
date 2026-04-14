// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {VaultV2Factory} from "../../src/VaultV2Factory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {DeltaNeutralController} from "../../src/controllers/DeltaNeutralController.sol";
import {PTLoopController} from "../../src/controllers/PTLoopController.sol";
import {CoreWriter} from "../../src/controllers/venue_specific/hyperliquid/CoreWriter.sol";
import {L1Read} from "../../src/controllers/venue_specific/hyperliquid/L1Read.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {VaultTimeLockWrapper} from "../../src/VaultTimeLockWrapper.sol";
import {
    DeltaNeutralAutomationConfig,
    DeltaNeutralKellyConfig,
    Deployment,
    DeltaNeutralDeploymentParams,
    PTLoopAutomationConfig,
    PTLoopDeploymentParams,
    SpotSideMode,
    StrategySpec,
    VenueConfig
} from "../../src/strategies/StrategyTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockValuer} from "../mocks/MockValuer.sol";

contract StrategyVaultFactoryTest is Test {
    bytes32 internal constant HYPERLIQUID_VENUE_ID = keccak256("HYPERLIQUID");
    bytes32 internal constant PENDLE_VENUE_ID = keccak256("PENDLE");
    address internal constant PENDLE_MARKET = address(0xBEEF);

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");

    MockERC20 internal asset;
    MockERC20 internal ptAsset;
    MockValuer internal valuer;
    MockPendleVenue internal pendleVenue;
    CoreWriter internal coreWriter;
    L1Read internal l1Read;
    VaultV2Factory internal vaultFactory;
    UniversalAdapterEscrowFactory internal adapterFactory;
    StrategyVaultFactory internal childFactory;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        ptAsset = new MockERC20("Pendle PT", "PT", 6);
        valuer = new MockValuer();
        pendleVenue = new MockPendleVenue();
        coreWriter = new CoreWriter();
        l1Read = new L1Read();
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();
        childFactory = new StrategyVaultFactory(address(vaultFactory), address(adapterFactory));
    }

    function testCreateDeltaNeutralVault() public {
        Deployment memory deployment = childFactory.createDeltaNeutralVault(_deltaNeutralParams(address(valuer), false));

        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        IUniversalAdapterEscrow sleeve = IUniversalAdapterEscrow(deployment.sleeve);
        StrategySpec memory spec = controller.getStrategySpec();

        assertEq(vault.owner(), owner);
        assertEq(vault.curator(), curator);
        assertEq(controller.vaultManager(), owner);
        assertTrue(vault.isAdapter(deployment.sleeve));
        assertTrue(vault.isAllocator(deployment.controller));
        assertEq(sleeve.owner(), owner);
        assertEq(deployment.wrapper, address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), address(0));
        assertTrue(childFactory.withdrawalQueueOf(deployment.vault) != address(0));
        assertEq(childFactory.depositGateOf(deployment.vault), address(0));
        assertEq(vault.sendAssetsGate(), address(0));
        assertEq(spec.strategyId, deployment.strategyId);
        assertEq(spec.asset, address(asset));
        assertEq(spec.targetReserveBps, 2_000);
        assertEq(uint8(controller.spotSideMode()), uint8(SpotSideMode.Hold));
        assertEq(controller.maxDeltaBps(), 250);
        assertEq(controller.venueId(), HYPERLIQUID_VENUE_ID);
        assertEq(controller.venue(), address(coreWriter));
        assertEq(controller.helper(), address(l1Read));
        assertEq(controller.getKellyConfig().asymmetricRebalanceThresholdBps, 7_500);
    }

    function testCreateDeltaNeutralVaultAllowsZeroValuerForSameChainOnchainPricing() public {
        Deployment memory deployment = childFactory.createDeltaNeutralVault(_deltaNeutralParams(address(0), false));
        assertTrue(deployment.vault != address(0));
    }

    function testCreateDeltaNeutralVaultWithOptionalTimelock() public {
        Deployment memory deployment = childFactory.createDeltaNeutralVault(_deltaNeutralParams(address(valuer), true));
        IVaultV2 vault = IVaultV2(deployment.vault);
        VaultTimeLockWrapper wrapper = VaultTimeLockWrapper(deployment.wrapper);

        assertTrue(deployment.wrapper != address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), deployment.wrapper);
        assertEq(childFactory.depositGateOf(deployment.vault), vault.sendAssetsGate());
        assertEq(address(wrapper.vault()), deployment.vault);
        assertGt(vault.forceDeallocatePenalty(deployment.sleeve), 0);
    }

    function testCreatePTLoopVault() public {
        Deployment memory deployment = childFactory.createPTLoopVault(_ptLoopParams(address(valuer), false));

        PTLoopController controller = PTLoopController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        IUniversalAdapterEscrow sleeve = IUniversalAdapterEscrow(deployment.sleeve);
        StrategySpec memory spec = controller.getStrategySpec();

        assertEq(vault.owner(), owner);
        assertEq(vault.curator(), curator);
        assertEq(controller.vaultManager(), owner);
        assertTrue(vault.isAdapter(deployment.sleeve));
        assertTrue(vault.isAllocator(deployment.controller));
        assertEq(sleeve.owner(), owner);
        assertEq(deployment.wrapper, address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), address(0));
        assertEq(childFactory.withdrawalQueueOf(deployment.vault), address(0));
        assertEq(spec.strategyId, deployment.strategyId);
        assertEq(spec.asset, address(asset));
        assertEq(spec.targetReserveBps, 1_500);
        assertEq(controller.venueId(), PENDLE_VENUE_ID);
        assertEq(controller.venue(), address(pendleVenue));
        assertEq(controller.helper(), address(pendleVenue));
        assertEq(controller.maxUnwindSlippageBps(), 600);
    }

    function testCreatePTLoopVaultAllowsZeroValuerForSameChainOnchainPricing() public {
        Deployment memory deployment = childFactory.createPTLoopVault(_ptLoopParams(address(0), false));
        assertTrue(deployment.vault != address(0));
    }

    function testCreatePTLoopVaultWithOptionalTimelock() public {
        Deployment memory deployment = childFactory.createPTLoopVault(_ptLoopParams(address(valuer), true));
        IVaultV2 vault = IVaultV2(deployment.vault);
        VaultTimeLockWrapper wrapper = VaultTimeLockWrapper(deployment.wrapper);

        assertTrue(deployment.wrapper != address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), deployment.wrapper);
        assertEq(childFactory.depositGateOf(deployment.vault), vault.sendAssetsGate());
        assertEq(address(wrapper.vault()), deployment.vault);
        assertGt(vault.forceDeallocatePenalty(deployment.sleeve), 0);
    }

    function testCreateDeltaNeutralVaultRejectsWrongVenue() public {
        DeltaNeutralDeploymentParams memory params = _deltaNeutralParams(address(valuer), false);
        params.venueConfig = VenueConfig({venueId: PENDLE_VENUE_ID, venue: address(coreWriter), helper: address(l1Read)});

        vm.expectRevert(DeltaNeutralController.InvalidVenue.selector);
        childFactory.createDeltaNeutralVault(params);
    }

    function testCreatePTLoopVaultRejectsWrongVenue() public {
        PTLoopDeploymentParams memory params = _ptLoopParams(address(valuer), false);
        params.venueConfig = VenueConfig({venueId: HYPERLIQUID_VENUE_ID, venue: address(coreWriter), helper: address(l1Read)});

        vm.expectRevert(PTLoopController.InvalidVenue.selector);
        childFactory.createPTLoopVault(params);
    }

    function _deltaNeutralParams(address valuerAddress, bool enableTimelock)
        internal
        view
        returns (DeltaNeutralDeploymentParams memory)
    {
        return DeltaNeutralDeploymentParams({
            owner: owner,
            vaultManager: owner,
            curator: curator,
            enableTimelock: enableTimelock,
            asset: address(asset),
            valuer: valuerAddress,
            name: "Delta Neutral Vault",
            symbol: "ldn",
            strategyIdData: bytes("hyperliquid-dn"),
            spotSideMode: SpotSideMode.Hold,
            targetReserveBps: 2_000,
            maxDeltaBps: 250,
            kellyConfig: _defaultKellyConfig(),
            automationConfig: _defaultDeltaAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("delta"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: HYPERLIQUID_VENUE_ID,
                venue: address(coreWriter),
                helper: address(l1Read)
            })
        });
    }

    function _ptLoopParams(address valuerAddress, bool enableTimelock)
        internal
        view
        returns (PTLoopDeploymentParams memory)
    {
        return PTLoopDeploymentParams({
            owner: owner,
            vaultManager: owner,
            curator: curator,
            enableTimelock: enableTimelock,
            asset: address(asset),
            market: PENDLE_MARKET,
            ptToken: address(ptAsset),
            valuer: valuerAddress,
            name: "PT Loop Vault",
            symbol: "lpt",
            strategyIdData: bytes("pendle-loop"),
            targetReserveBps: 1_500,
            maxUnwindSlippageBps: 600,
            automationConfig: _defaultPTAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("pt-loop"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: PENDLE_VENUE_ID,
                venue: address(pendleVenue),
                helper: address(pendleVenue)
            })
        });
    }

    function _defaultKellyConfig() internal pure returns (DeltaNeutralKellyConfig memory) {
        return DeltaNeutralKellyConfig({
            spotYieldWad: 20_400_000_000_000_000,
            marginYieldWad: 43_300_000_000_000_000,
            baseFundingRateWad: 105_000_000_000_000_000,
            ethVolatilityWad: 600_000_000_000_000_000,
            liquidationLossWad: 950_000_000_000_000_000,
            rebalanceThresholdWad: 50_000_000_000_000_000,
            minBenefitWad: 100_000_000_000_000,
            shortTakerFeeWad: 350_000_000_000_000,
            entrySlippageWad: 1_000_000_000_000_000,
            exitSlippageWad: 1_000_000_000_000_000,
            shortSlippageWad: 500_000_000_000_000,
            bridgeSlippageWad: 1_000_000_000_000_000,
            sizeImpactThresholdAssets: 50_000e6,
            sizeImpactMultiplierWad: 1_500_000_000_000_000_000,
            bridgeFeeAssets: 5e6,
            gasSpotActionAssets: 2e6,
            gasShortActionAssets: 500_000,
            timeHorizonDays: 7,
            fundingDivisor: 2,
            asymmetricRebalanceThresholdBps: 7_500
        });
    }

    function _defaultDeltaAutomationConfig() internal pure returns (DeltaNeutralAutomationConfig memory) {
        return DeltaNeutralAutomationConfig({
            spotAssetIndex: 1,
            perpAssetIndex: 7,
            spotPriceIndex: 1,
            perpDexIndex: 3,
            spotToken: 100,
            spotTokenDecimals: 6,
            encodedTif: 2,
            hyperCoreVault: address(0),
            maxOrderSlippageBps: 500,
            maxOracleDivergenceBps: 1_000,
            maxMarginUsageBps: 8_000
        });
    }

    function _defaultPTAutomationConfig() internal pure returns (PTLoopAutomationConfig memory) {
        return PTLoopAutomationConfig({maxEntrySlippageBps: 600});
    }
}

contract MockPendleVenue {
    function getPtToAssetRate(address) external pure returns (uint256) {
        return 1e18;
    }
}
