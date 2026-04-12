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
    ChainManifest,
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
    address internal constant PENDLE_PT = address(0xCAFE);

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");

    MockERC20 internal asset;
    MockValuer internal valuer;
    MockAssetOFTView internal assetOFT;
    CoreWriter internal coreWriter;
    L1Read internal l1Read;
    VaultV2Factory internal vaultFactory;
    UniversalAdapterEscrowFactory internal adapterFactory;
    StrategyVaultFactory internal childFactory;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        valuer = new MockValuer();
        assetOFT = new MockAssetOFTView(address(asset), address(this));
        coreWriter = new CoreWriter();
        l1Read = new L1Read();
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();
        childFactory = new StrategyVaultFactory(address(vaultFactory), address(adapterFactory));
    }

    function testCreateDeltaNeutralVault() public {
        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            curator: curator,
            enableTimelock: false,
            asset: address(asset),
            valuer: address(valuer),
            name: "Delta Neutral Vault",
            symbol: "ldn",
            strategyIdData: bytes("hyperliquid-dn"),
            spotSideMode: SpotSideMode.Hold,
            targetReserveBps: 2_000,
            minReserveBps: 500,
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
                helper: address(l1Read),
                usesLayerZero: false
            }),
            chainManifests: _homeManifest()
        });

        Deployment memory deployment = childFactory.createDeltaNeutralVault(params);

        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        IUniversalAdapterEscrow sleeve = IUniversalAdapterEscrow(deployment.sleeve);
        StrategySpec memory spec = controller.getStrategySpec();
        ChainManifest memory manifest = controller.getChainManifest(0);

        assertEq(vault.owner(), owner);
        assertEq(vault.curator(), curator);
        assertTrue(vault.isAdapter(deployment.sleeve));
        assertTrue(vault.isAllocator(deployment.controller));
        assertEq(sleeve.owner(), owner);
        assertEq(deployment.wrapper, address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), address(0));
        assertTrue(childFactory.withdrawalQueueOf(deployment.vault) != address(0));
        assertEq(childFactory.withdrawalSettlementComposerOf(deployment.vault), address(0));
        assertEq(childFactory.depositGateOf(deployment.vault), address(0));
        assertEq(vault.sendAssetsGate(), address(0));
        assertEq(spec.strategyId, deployment.strategyId);
        assertEq(spec.asset, address(asset));
        assertEq(spec.targetReserveBps, 2_000);
        assertEq(uint8(controller.spotSideMode()), uint8(SpotSideMode.Hold));
        assertEq(controller.maxDeltaBps(), 250);
        assertEq(manifest.sleeve, deployment.sleeve);
        assertTrue(manifest.isHomeChain);
        assertEq(controller.venueId(), HYPERLIQUID_VENUE_ID);
        assertEq(controller.venue(), address(coreWriter));
        assertEq(controller.helper(), address(l1Read));
        assertEq(controller.remoteChainCount(), 0);
        assertEq(controller.getKellyConfig().asymmetricRebalanceThresholdBps, 7_500);
    }

    function testCreateDeltaNeutralVaultWithOptionalTimelock() public {
        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            curator: curator,
            enableTimelock: true,
            asset: address(asset),
            valuer: address(valuer),
            name: "Delta Neutral Vault",
            symbol: "ldn",
            strategyIdData: bytes("hyperliquid-dn"),
            spotSideMode: SpotSideMode.Hold,
            targetReserveBps: 2_000,
            minReserveBps: 500,
            maxDeltaBps: 250,
            kellyConfig: _defaultKellyConfig(),
            automationConfig: _defaultDeltaAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("delta-lock"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: HYPERLIQUID_VENUE_ID,
                venue: address(coreWriter),
                helper: address(l1Read),
                usesLayerZero: false
            }),
            chainManifests: _homeManifest()
        });

        Deployment memory deployment = childFactory.createDeltaNeutralVault(params);
        IVaultV2 vault = IVaultV2(deployment.vault);
        VaultTimeLockWrapper wrapper = VaultTimeLockWrapper(deployment.wrapper);

        assertTrue(deployment.wrapper != address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), deployment.wrapper);
        assertEq(childFactory.depositGateOf(deployment.vault), vault.sendAssetsGate());
        assertEq(address(wrapper.vault()), deployment.vault);
    }

    function testCreatePTLoopVault() public {
        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            curator: curator,
            enableTimelock: false,
            asset: address(asset),
            market: PENDLE_MARKET,
            ptToken: PENDLE_PT,
            valuer: address(valuer),
            name: "PT Loop Vault",
            symbol: "lpt",
            strategyIdData: bytes("pendle-loop"),
            targetReserveBps: 1_500,
            minReserveBps: 500,
            maxUnwindSlippageBps: 600,
            automationConfig: PTLoopAutomationConfig({maxEntrySlippageBps: 600}),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("pt-loop"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: PENDLE_VENUE_ID,
                venue: address(0x2001),
                helper: address(0x2002),
                usesLayerZero: true
            }),
            chainManifests: _homeAndRemoteManifest()
        });

        Deployment memory deployment = childFactory.createPTLoopVault(params);
        PTLoopController controller = PTLoopController(deployment.controller);
        ChainManifest memory homeManifest = controller.getChainManifest(0);
        ChainManifest memory remoteManifest = controller.getChainManifest(1);

        assertEq(controller.venueId(), PENDLE_VENUE_ID);
        assertEq(controller.maxUnwindSlippageBps(), 600);
        assertEq(controller.remoteChainCount(), 1);
        assertEq(deployment.wrapper, address(0));
        assertEq(childFactory.timeLockWrapperOf(deployment.vault), address(0));
        assertEq(controller.market(), PENDLE_MARKET);
        assertEq(controller.ptToken(), PENDLE_PT);
        assertEq(IVaultV2(deployment.vault).liquidityAdapter(), deployment.sleeve);
        assertTrue(homeManifest.isHomeChain);
        assertEq(homeManifest.sleeve, deployment.sleeve);
        assertFalse(remoteManifest.isHomeChain);
        assertEq(remoteManifest.chainId, 56);
    }

    function testCreatePTLoopVaultRejectsMissingRemoteManifestWhenLayerZeroEnabled() public {
        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            curator: curator,
            enableTimelock: false,
            asset: address(asset),
            market: PENDLE_MARKET,
            ptToken: PENDLE_PT,
            valuer: address(valuer),
            name: "PT Loop Vault",
            symbol: "lpt",
            strategyIdData: bytes("pendle-loop"),
            targetReserveBps: 1_500,
            minReserveBps: 500,
            maxUnwindSlippageBps: 600,
            automationConfig: PTLoopAutomationConfig({maxEntrySlippageBps: 600}),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("pt-loop"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: PENDLE_VENUE_ID,
                venue: address(0x2001),
                helper: address(0x2002),
                usesLayerZero: true
            }),
            chainManifests: _homeManifest()
        });

        vm.expectRevert(bytes4(keccak256("InvalidChainManifest()")));
        childFactory.createPTLoopVault(params);
    }

    function testCreateDeltaNeutralVaultRejectsWrongVenue() public {
        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            curator: curator,
            enableTimelock: false,
            asset: address(asset),
            valuer: address(valuer),
            name: "",
            symbol: "",
            strategyIdData: bytes("hyperliquid-dn"),
            spotSideMode: SpotSideMode.Hold,
            targetReserveBps: 2_000,
            minReserveBps: 500,
            maxDeltaBps: 250,
            kellyConfig: _defaultKellyConfig(),
            automationConfig: _defaultDeltaAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("bad"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: PENDLE_VENUE_ID,
                venue: address(coreWriter),
                helper: address(l1Read),
                usesLayerZero: false
            }),
            chainManifests: _homeManifest()
        });

        vm.expectRevert(DeltaNeutralController.InvalidVenue.selector);
        childFactory.createDeltaNeutralVault(params);
    }

    function _homeManifest() internal view returns (ChainManifest[] memory manifests) {
        manifests = new ChainManifest[](1);
        manifests[0] = ChainManifest({
            chainId: block.chainid,
            lzEid: 30_184,
            sleeve: address(0),
            assetOFT: address(assetOFT),
            shareOFT: address(0),
            isHomeChain: true
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

    function _homeAndRemoteManifest() internal view returns (ChainManifest[] memory manifests) {
        manifests = new ChainManifest[](2);
        manifests[0] = ChainManifest({
            chainId: block.chainid,
            lzEid: 30_184,
            sleeve: address(0),
            assetOFT: address(assetOFT),
            shareOFT: address(0),
            isHomeChain: true
        });
        manifests[1] = ChainManifest({
            chainId: 56,
            lzEid: 30_102,
            sleeve: address(0xBEEF),
            assetOFT: address(0xCAFE),
            shareOFT: address(0),
            isHomeChain: false
        });
    }

    function _venueConfig(bytes32 venueId, address venue, bool usesLayerZero)
        internal
        pure
        returns (VenueConfig memory)
    {
        return VenueConfig({venueId: venueId, venue: venue, helper: address(0), usesLayerZero: usesLayerZero});
    }
}

contract MockAssetOFTView {
    address internal immutable _token;
    address internal immutable _endpoint;

    constructor(address token_, address endpoint_) {
        _token = token_;
        _endpoint = endpoint_;
    }

    function token() external view returns (address) {
        return _token;
    }

    function endpoint() external view returns (address) {
        return _endpoint;
    }
}
