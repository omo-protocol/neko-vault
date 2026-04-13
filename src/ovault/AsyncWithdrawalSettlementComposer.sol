// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {IERC20} from "../interfaces/IERC20.sol";
import {AsyncWithdrawalQueue} from "../queues/AsyncWithdrawalQueue.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

contract AsyncWithdrawalSettlementComposer is ILayerZeroComposer {
    using OFTComposeMsgCodec for bytes;

    error OnlyEndpoint(address caller);
    error OnlyAssetOFT(address composeSender);
    error InvalidRequest();
    error OnlyQueueOwner(address caller);
    error PendingSettlementNotFound();
    error PendingSettlementAlreadyExists();

    event SettlementReceived(uint256 indexed requestId, uint256 amountReceived, bytes32 guid, uint32 srcEid);
    event SettlementPending(uint256 indexed requestId, uint256 amountReceived, bytes32 guid, bytes reason);
    event PendingSettlementRecovered(bytes32 indexed guid, address indexed recipient, uint256 amountRecovered);

    AsyncWithdrawalQueue public immutable queue;
    address public immutable sleeve;
    address public immutable assetOFT;
    address public immutable asset;
    address public immutable endpoint;
    mapping(bytes32 guid => PendingSettlement) public pendingSettlements;

    struct PendingSettlement {
        uint256 requestId;
        uint256 amountReceived;
    }

    constructor(address queue_, address sleeve_, address assetOFT_) {
        if (queue_ == address(0) || sleeve_ == address(0) || assetOFT_ == address(0)) revert InvalidRequest();

        queue = AsyncWithdrawalQueue(queue_);
        sleeve = sleeve_;
        assetOFT = assetOFT_;
        asset = IOFT(assetOFT_).token();
        endpoint = address(IOAppCore(assetOFT_).endpoint());
        if (asset == address(0) || endpoint == address(0)) revert InvalidRequest();
        if (address(queue.vault().asset()) != asset || queue.sleeve() != sleeve) revert InvalidRequest();
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
        try this.handleSettlement(requestId, amountReceived, guid) {
            emit SettlementReceived(requestId, amountReceived, guid, message.srcEid());
        } catch (bytes memory reason) {
            if (pendingSettlements[guid].amountReceived != 0) revert PendingSettlementAlreadyExists();
            pendingSettlements[guid] = PendingSettlement({requestId: requestId, amountReceived: amountReceived});
            emit SettlementPending(requestId, amountReceived, guid, reason);
        }
    }

    function handleSettlement(uint256 requestId, uint256 amountReceived, bytes32 guid) external {
        if (msg.sender != address(this)) revert InvalidRequest();
        SafeERC20Lib.safeTransfer(asset, sleeve, amountReceived);
        queue.creditSettlement(requestId, amountReceived, guid);
    }

    function retrySettlement(bytes32 guid) external {
        PendingSettlement memory pending = pendingSettlements[guid];
        if (pending.amountReceived == 0) revert PendingSettlementNotFound();

        delete pendingSettlements[guid];
        this.handleSettlement(pending.requestId, pending.amountReceived, guid);
        emit SettlementReceived(pending.requestId, pending.amountReceived, guid, 0);
    }

    function recoverPendingSettlement(bytes32 guid, address recipient) external {
        if (msg.sender != queue.owner()) revert OnlyQueueOwner(msg.sender);
        if (recipient == address(0)) revert InvalidRequest();

        PendingSettlement memory pending = pendingSettlements[guid];
        if (pending.amountReceived == 0) revert PendingSettlementNotFound();

        delete pendingSettlements[guid];
        SafeERC20Lib.safeTransfer(asset, recipient, pending.amountReceived);
        emit PendingSettlementRecovered(guid, recipient, pending.amountReceived);
    }
}
