// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {VaultV2Factory} from "../../src/VaultV2Factory.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFT} from "../../src/ovault/ShareOFT.sol";
import {CoreWriter} from "../../src/controllers/venue_specific/hyperliquid/CoreWriter.sol";
import {L1Read} from "../../src/controllers/venue_specific/hyperliquid/L1Read.sol";
import {RunStrategyTestnetRollout} from "../../script/ovault/RunStrategyTestnetRollout.s.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/libs/ExecutorOptions.sol";

contract StrategyLaunchpadScriptsTest is Test {
    bytes32 internal constant HYPERLIQUID_VENUE_ID = keccak256("HYPERLIQUID");
    bytes32 internal constant PENDLE_VENUE_ID = keccak256("PENDLE");
    uint256 internal constant PRIVATE_KEY = 0xA11CE;
    uint16 internal constant SEND = 1;
    uint16 internal constant SEND_AND_CALL = 2;
    uint16 internal constant TYPE_3 = 3;

    address internal owner;
    address internal remoteAssetOFT = makeAddr("remoteAssetOFT");
    address internal remoteShareOFT = makeAddr("remoteShareOFT");
    address internal remotePpsPeer = makeAddr("remotePpsPeer");
    address internal remoteSleeve = makeAddr("remoteSleeve");
    address internal pendleVenue = makeAddr("pendleVenue");
    address internal pendleHelper = makeAddr("pendleHelper");
    address internal pendleMarket = makeAddr("pendleMarket");
    address internal pendlePt = makeAddr("pendlePt");

    VaultV2Factory internal vaultFactory;
    UniversalAdapterEscrowFactory internal adapterFactory;
    StrategyVaultFactory internal strategyFactory;
    MockValuer internal valuer;
    CoreWriter internal coreWriter;
    L1Read internal l1Read;
    MockEndpointV2 internal homeEndpoint;
    MockEndpointV2 internal spokeEndpoint;
    AssetOFT internal homeAssetOFT;
    AssetOFT internal localAssetOFT;
    AssetOFT internal localRemotePpsApp;
    ShareOFT internal localShareOFT;

    function setUp() public {
        owner = vm.addr(PRIVATE_KEY);
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();
        strategyFactory = new StrategyVaultFactory(address(vaultFactory), address(adapterFactory));
        valuer = new MockValuer();
        coreWriter = new CoreWriter();
        l1Read = new L1Read();
        homeEndpoint = new MockEndpointV2(30_184);
        spokeEndpoint = new MockEndpointV2(30_102);
        homeAssetOFT = new AssetOFT("Home USDC", "hUSDC", address(homeEndpoint), owner);
        localAssetOFT = new AssetOFT("Local USDC", "lUSDC", address(spokeEndpoint), owner);
        localRemotePpsApp = new AssetOFT("Remote PPS", "rPPS", address(spokeEndpoint), owner);
        localShareOFT = new ShareOFT("Local Share", "lSHARE", address(spokeEndpoint), owner);
    }

    function testScriptsStayInSyncWithContracts() public {
        _assertRunStrategyTestnetRolloutSupportsAllActions();
    }

    function _assertRunStrategyTestnetRolloutSupportsAllActions() internal {
        RunStrategyTestnetRollout rollout = new RunStrategyTestnetRollout();

        _setCommonEnv();
        _setPTLoopEnv("pt-rollout", "pt-rollout-salt");
        _setHomeAndRemoteManifestEnv(address(homeAssetOFT), remoteAssetOFT, remoteShareOFT);
        vm.setEnv("ENABLE_OMNICHAIN_VAULT", "true");
        vm.setEnv("USES_LAYER_ZERO", "true");
        vm.setEnv("ROLLOUT_ACTION", "0");
        vm.setEnv("STRATEGY_KIND", "1");
        rollout.run();

        bytes32 strategyId = keccak256(bytes("pt-rollout"));
        bytes32 salt = keccak256(abi.encode(uint256(1), owner, strategyId, bytes32("pt-rollout-salt")));
        address vault = vaultFactory.vaultV2(address(strategyFactory), address(homeAssetOFT), salt);
        assertTrue(vault != address(0));

        _setSpokeEnv();
        vm.setEnv("ROLLOUT_ACTION", "1");
        vm.recordLogs();
        rollout.run();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        address expectedAsset = _findEmitterBySymbol(entries, "sUSDC");
        address expectedShare = _findEmitterBySymbol(entries, "sSHARE");
        assertEq(AssetOFT(expectedAsset).owner(), owner);
        assertEq(ShareOFT(expectedShare).owner(), owner);

        _setConfigureEnv(address(localAssetOFT), address(localShareOFT), remoteAssetOFT, remoteShareOFT);
        vm.setEnv("LOCAL_REMOTE_PPS_SYNC", vm.toString(address(localRemotePpsApp)));
        vm.setEnv("REMOTE_REMOTE_PPS_SYNCS", string.concat(vm.toString(remotePpsPeer)));
        vm.setEnv("ROLLOUT_ACTION", "2");
        rollout.run();
        assertEq(localAssetOFT.peers(30_184), bytes32(uint256(uint160(remoteAssetOFT))));
        assertEq(localShareOFT.peers(30_184), bytes32(uint256(uint160(remoteShareOFT))));
        assertEq(localRemotePpsApp.peers(30_184), bytes32(uint256(uint160(remotePpsPeer))));

        _setCommonEnv();
        vm.setEnv("SLEEVE", vm.toString(remoteSleeve));
        vm.setEnv("LZ_ENDPOINT", vm.toString(address(spokeEndpoint)));
        vm.setEnv("ROLLOUT_ACTION", "3");
        rollout.run();
    }

    function _findEmitterBySymbol(Vm.Log[] memory entries, string memory expectedSymbol)
        internal
        returns (address candidate)
    {
        for (uint256 i; i < entries.length; i++) {
            candidate = entries[i].emitter;
            (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSignature("symbol()"));
            if (!success || data.length == 0) continue;

            string memory symbol = abi.decode(data, (string));
            if (keccak256(bytes(symbol)) == keccak256(bytes(expectedSymbol))) return candidate;
        }
        fail();
    }

    function _setCommonEnv() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("CURATOR", vm.toString(owner));
        vm.setEnv("STRATEGY_FACTORY", vm.toString(address(strategyFactory)));
        vm.setEnv("ASSET", vm.toString(address(homeAssetOFT)));
        vm.setEnv("VALUER", vm.toString(address(valuer)));
        vm.setEnv("NAME", "Script Vault");
        vm.setEnv("SYMBOL", "sv");
        vm.setEnv("TARGET_RESERVE_BPS", "1500");
        vm.setEnv("MIN_RESERVE_BPS", "500");
        vm.setEnv("ABSOLUTE_CAP", "1000000");
        vm.setEnv("RELATIVE_CAP", "1000000000000000000");
        vm.setEnv("USE_OFFCHAIN_VALUER", "false");
        vm.setEnv("ENABLE_TIMELOCK", "false");
    }

    function _setDeltaNeutralEnv(string memory strategyIdData, string memory saltValue) internal {
        vm.setEnv("STRATEGY_ID_DATA", strategyIdData);
        vm.setEnv("SALT", vm.toString(bytes32(bytes(saltValue))));
        vm.setEnv("SPOT_SIDE_MODE", "0");
        vm.setEnv("MAX_DELTA_BPS", "250");
        vm.setEnv("VENUE_ID", vm.toString(HYPERLIQUID_VENUE_ID));
        vm.setEnv("VENUE", vm.toString(address(coreWriter)));
        vm.setEnv("VENUE_HELPER", vm.toString(address(l1Read)));
        vm.setEnv("KELLY_SPOT_YIELD_WAD", "20400000000000000");
        vm.setEnv("KELLY_MARGIN_YIELD_WAD", "43300000000000000");
        vm.setEnv("KELLY_BASE_FUNDING_RATE_WAD", "105000000000000000");
        vm.setEnv("KELLY_ETH_VOLATILITY_WAD", "600000000000000000");
        vm.setEnv("KELLY_LIQUIDATION_LOSS_WAD", "950000000000000000");
        vm.setEnv("KELLY_REBALANCE_THRESHOLD_WAD", "50000000000000000");
        vm.setEnv("KELLY_MIN_BENEFIT_WAD", "100000000000000");
        vm.setEnv("KELLY_SHORT_TAKER_FEE_WAD", "350000000000000");
        vm.setEnv("KELLY_ENTRY_SLIPPAGE_WAD", "1000000000000000");
        vm.setEnv("KELLY_EXIT_SLIPPAGE_WAD", "1000000000000000");
        vm.setEnv("KELLY_SHORT_SLIPPAGE_WAD", "500000000000000");
        vm.setEnv("KELLY_BRIDGE_SLIPPAGE_WAD", "1000000000000000");
        vm.setEnv("KELLY_SIZE_IMPACT_THRESHOLD_ASSETS", "50000000000");
        vm.setEnv("KELLY_SIZE_IMPACT_MULTIPLIER_WAD", "1500000000000000000");
        vm.setEnv("KELLY_BRIDGE_FEE_ASSETS", "5000000");
        vm.setEnv("KELLY_GAS_SPOT_ACTION_ASSETS", "2000000");
        vm.setEnv("KELLY_GAS_SHORT_ACTION_ASSETS", "500000");
        vm.setEnv("KELLY_TIME_HORIZON_DAYS", "7");
        vm.setEnv("KELLY_FUNDING_DIVISOR", "2");
        vm.setEnv("KELLY_ASYMMETRIC_REBALANCE_THRESHOLD_BPS", "7500");
        vm.setEnv("AUTOMATION_SPOT_ASSET_INDEX", "1");
        vm.setEnv("AUTOMATION_PERP_ASSET_INDEX", "7");
        vm.setEnv("AUTOMATION_SPOT_PRICE_INDEX", "1");
        vm.setEnv("AUTOMATION_PERP_DEX_INDEX", "3");
        vm.setEnv("AUTOMATION_SPOT_TOKEN", "100");
        vm.setEnv("AUTOMATION_SPOT_TOKEN_DECIMALS", "6");
        vm.setEnv("AUTOMATION_ENCODED_TIF", "2");
        vm.setEnv("AUTOMATION_HYPER_CORE_VAULT", vm.toString(address(0)));
        vm.setEnv("AUTOMATION_MAX_ORDER_SLIPPAGE_BPS", "500");
        vm.setEnv("AUTOMATION_MAX_ORACLE_DIVERGENCE_BPS", "1000");
        vm.setEnv("AUTOMATION_MAX_MARGIN_USAGE_BPS", "8000");
    }

    function _setPTLoopEnv(string memory strategyIdData, string memory saltValue) internal {
        vm.setEnv("STRATEGY_ID_DATA", strategyIdData);
        vm.setEnv("SALT", vm.toString(bytes32(bytes(saltValue))));
        vm.setEnv("MARKET", vm.toString(pendleMarket));
        vm.setEnv("PT_TOKEN", vm.toString(pendlePt));
        vm.setEnv("MAX_UNWIND_SLIPPAGE_BPS", "600");
        vm.setEnv("AUTOMATION_MAX_ENTRY_SLIPPAGE_BPS", "600");
        vm.setEnv("VENUE_ID", vm.toString(PENDLE_VENUE_ID));
        vm.setEnv("VENUE", vm.toString(pendleVenue));
        vm.setEnv("VENUE_HELPER", vm.toString(pendleHelper));
    }

    function _setHomeOnlyManifestEnv(address homeAsset) internal {
        vm.setEnv("MANIFEST_CHAIN_IDS", vm.toString(block.chainid));
        vm.setEnv("MANIFEST_LZ_EIDS", "30184");
        vm.setEnv("MANIFEST_SLEEVES", vm.toString(address(0)));
        vm.setEnv("MANIFEST_ASSET_OFTS", vm.toString(homeAsset));
        vm.setEnv("MANIFEST_SHARE_OFTS", vm.toString(address(0)));
        vm.setEnv("MANIFEST_IS_HOME", "true");
    }

    function _setHomeAndRemoteManifestEnv(address homeAsset, address remoteAsset, address remoteShare) internal {
        vm.setEnv("MANIFEST_CHAIN_IDS", string.concat(vm.toString(block.chainid), ",56"));
        vm.setEnv("MANIFEST_LZ_EIDS", "30184,30102");
        vm.setEnv("MANIFEST_SLEEVES", string.concat(vm.toString(address(0)), ",", vm.toString(remoteSleeve)));
        vm.setEnv("MANIFEST_ASSET_OFTS", string.concat(vm.toString(homeAsset), ",", vm.toString(remoteAsset)));
        vm.setEnv("MANIFEST_SHARE_OFTS", string.concat(vm.toString(address(0)), ",", vm.toString(remoteShare)));
        vm.setEnv("MANIFEST_IS_HOME", "true,false");
    }

    function _setSpokeEnv() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
        vm.setEnv("DELEGATE", vm.toString(owner));
        vm.setEnv("LZ_ENDPOINT", vm.toString(address(spokeEndpoint)));
        vm.setEnv("DEPLOY_ASSET_OFT", "true");
        vm.setEnv("EXISTING_ASSET_OFT", vm.toString(address(0)));
        vm.setEnv("ASSET_NAME", "Spoke USDC");
        vm.setEnv("ASSET_SYMBOL", "sUSDC");
        vm.setEnv("SHARE_NAME", "Spoke Share");
        vm.setEnv("SHARE_SYMBOL", "sSHARE");
    }

    function _setConfigureEnv(address asset, address share, address remoteAsset, address remoteShare) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
        vm.setEnv("LOCAL_ASSET_OFT", vm.toString(asset));
        vm.setEnv("LOCAL_SHARE_OFT", vm.toString(share));
        vm.setEnv("REMOTE_EIDS", "30184");
        vm.setEnv("REMOTE_ASSET_OFTS", vm.toString(remoteAsset));
        vm.setEnv("REMOTE_SHARE_OFTS", vm.toString(remoteShare));
        vm.setEnv("LZ_RECEIVE_GAS", "250000");
        vm.setEnv("LZ_RECEIVE_VALUE", "0");
        vm.setEnv("LZ_COMPOSE_GAS", "500000");
        vm.setEnv("LZ_COMPOSE_VALUE", "0");
    }

    function _expectedSendOptions(uint128 receiveGas, uint128 receiveValue) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encodePacked(TYPE_3),
            abi.encodePacked(
                ExecutorOptions.WORKER_ID,
                uint16(ExecutorOptions.encodeLzReceiveOption(receiveGas, receiveValue).length + 1),
                ExecutorOptions.OPTION_TYPE_LZRECEIVE,
                ExecutorOptions.encodeLzReceiveOption(receiveGas, receiveValue)
            )
        );
    }

    function _expectedSendAndCallOptions(
        uint128 receiveGas,
        uint128 receiveValue,
        uint128 composeGas,
        uint128 composeValue
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _expectedSendOptions(receiveGas, receiveValue),
            abi.encodePacked(
                ExecutorOptions.WORKER_ID,
                uint16(ExecutorOptions.encodeLzComposeOption(0, composeGas, composeValue).length + 1),
                ExecutorOptions.OPTION_TYPE_LZCOMPOSE,
                ExecutorOptions.encodeLzComposeOption(0, composeGas, composeValue)
            )
        );
    }
}

contract MockEndpointV2 {
    uint32 internal immutable _eid;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }

    function setDelegate(address) external {}
}
