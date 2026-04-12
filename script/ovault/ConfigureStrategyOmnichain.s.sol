// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    EnforcedOptionParam,
    IOAppOptionsType3
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/libs/ExecutorOptions.sol";

contract ConfigureStrategyOmnichain is Script {
    uint16 internal constant SEND = 1;
    uint16 internal constant SEND_AND_CALL = 2;
    uint16 internal constant TYPE_3 = 3;

    error InvalidConfig();

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address localAssetOFT = vm.envAddress("LOCAL_ASSET_OFT");
        address localShareOFT = vm.envOr("LOCAL_SHARE_OFT", address(0));
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");
        address[] memory remoteAssetOFTs = vm.envAddress("REMOTE_ASSET_OFTS", ",");
        address[] memory remoteShareOFTs = vm.envAddress("REMOTE_SHARE_OFTS", ",");

        uint256 length = remoteEids.length;
        if (length == 0 || remoteAssetOFTs.length != length || remoteShareOFTs.length != length) revert InvalidConfig();

        bytes memory sendOptions = _newOptions();
        sendOptions = _addExecutorOption(
            sendOptions,
            ExecutorOptions.OPTION_TYPE_LZRECEIVE,
            ExecutorOptions.encodeLzReceiveOption(
                uint128(vm.envUint("LZ_RECEIVE_GAS")), uint128(vm.envOr("LZ_RECEIVE_VALUE", uint256(0)))
            )
        );
        bytes memory sendAndCallOptions = sendOptions;
        uint256 composeGas = vm.envOr("LZ_COMPOSE_GAS", uint256(0));
        uint256 composeValue = vm.envOr("LZ_COMPOSE_VALUE", uint256(0));
        if (composeGas != 0 || composeValue != 0) {
            sendAndCallOptions = _addExecutorOption(
                sendAndCallOptions,
                ExecutorOptions.OPTION_TYPE_LZCOMPOSE,
                ExecutorOptions.encodeLzComposeOption(0, uint128(composeGas), uint128(composeValue))
            );
        }

        vm.startBroadcast(privateKey);

        _setPeers(localAssetOFT, remoteEids, remoteAssetOFTs);
        _setOptions(localAssetOFT, remoteEids, sendOptions, sendAndCallOptions);

        if (localShareOFT != address(0)) {
            _setPeers(localShareOFT, remoteEids, remoteShareOFTs);
            _setOptions(localShareOFT, remoteEids, sendOptions, sendAndCallOptions);
        }

        vm.stopBroadcast();

        console2.log("Configured omnichain peers for asset OFT:", localAssetOFT);
        console2.log("Configured omnichain peers for share OFT:", localShareOFT);
    }

    function _setPeers(address localOApp, uint32[] memory remoteEids, address[] memory remotes) internal {
        for (uint256 i; i < remoteEids.length; i++) {
            if (remotes[i] == address(0)) revert InvalidConfig();
            IOAppCore(localOApp).setPeer(remoteEids[i], bytes32(uint256(uint160(remotes[i]))));
        }
    }

    function _setOptions(
        address localOApp,
        uint32[] memory remoteEids,
        bytes memory sendOptions,
        bytes memory sendAndCallOptions
    ) internal {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](remoteEids.length * 2);
        for (uint256 i; i < remoteEids.length; i++) {
            uint256 baseIndex = i * 2;
            options[baseIndex] = EnforcedOptionParam(remoteEids[i], SEND, sendOptions);
            options[baseIndex + 1] = EnforcedOptionParam(remoteEids[i], SEND_AND_CALL, sendAndCallOptions);
        }
        IOAppOptionsType3(localOApp).setEnforcedOptions(options);
    }

    function _loadUint32Array(string memory key) internal view returns (uint32[] memory values) {
        uint256[] memory rawValues = vm.envUint(key, ",");
        values = new uint32[](rawValues.length);
        for (uint256 i; i < rawValues.length; i++) {
            values[i] = uint32(rawValues[i]);
        }
    }

    function _newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(TYPE_3);
    }

    function _addExecutorOption(bytes memory options, uint8 optionType, bytes memory option)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(options, ExecutorOptions.WORKER_ID, uint16(option.length + 1), optionType, option);
    }
}
