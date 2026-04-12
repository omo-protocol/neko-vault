// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {IERC20} from "../interfaces/IERC20.sol";
import {AsyncWithdrawalQueue} from "../queues/AsyncWithdrawalQueue.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

contract AsyncWithdrawalSettlementComposer is ILayerZeroComposer {
    using OFTComposeMsgCodec for bytes;

    error OnlyEndpoint(address caller);
    error OnlyAssetOFT(address composeSender);
    error InvalidRequest();

    event SettlementReceived(uint256 indexed requestId, uint256 amountReceived, bytes32 guid, uint32 srcEid);

    AsyncWithdrawalQueue public immutable queue;
    address public immutable sleeve;
    address public immutable assetOFT;
    address public immutable asset;
    address public immutable endpoint;

    constructor(address queue_, address sleeve_, address assetOFT_) {
        if (queue_ == address(0) || sleeve_ == address(0) || assetOFT_ == address(0)) revert InvalidRequest();

        queue = AsyncWithdrawalQueue(queue_);
        sleeve = sleeve_;
        assetOFT = assetOFT_;
        asset = IOFT(assetOFT_).token();
        endpoint = address(IOAppCore(assetOFT_).endpoint());
    }

    function lzCompose(address composeSender, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        if (msg.sender != endpoint) revert OnlyEndpoint(msg.sender);
        if (composeSender != assetOFT) revert OnlyAssetOFT(composeSender);

        uint256 requestId = abi.decode(message.composeMsg(), (uint256));
        uint256 amountReceived = message.amountLD();
        IERC20(asset).transfer(sleeve, amountReceived);
        queue.creditSettlement(requestId, amountReceived, guid);

        emit SettlementReceived(requestId, amountReceived, guid, message.srcEid());
    }
}
