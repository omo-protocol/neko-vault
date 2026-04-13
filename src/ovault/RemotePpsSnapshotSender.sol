// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {ILayerZeroEndpointV2, MessagingParams, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RemotePpsSnapshotSender {
    error NotOwner();
    error NotVaultManager();
    error InvalidConfig();
    error NoPeer(uint32 dstEid);

    event PeerSet(uint32 indexed eid, bytes32 peer);
    event SnapshotSent(uint32 indexed dstEid, uint256 assets, uint64 snapshotTimestamp, bytes32 guid);

    address public immutable owner;
    address public immutable vaultManager;
    address public immutable sleeve;
    ILayerZeroEndpointV2 public immutable endpoint;

    mapping(uint32 eid => bytes32 peer) public peers;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    constructor(address owner_, address vaultManager_, address sleeve_, address endpoint_) {
        if (owner_ == address(0) || vaultManager_ == address(0) || sleeve_ == address(0) || endpoint_ == address(0)) {
            revert InvalidConfig();
        }
        owner = owner_;
        vaultManager = vaultManager_;
        sleeve = sleeve_;
        endpoint = ILayerZeroEndpointV2(endpoint_);
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    function quoteSnapshot(uint32 dstEid, bytes calldata options) external view returns (MessagingFee memory fee) {
        bytes32 receiver = peers[dstEid];
        if (receiver == bytes32(0)) revert NoPeer(dstEid);

        fee = endpoint.quote(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(IAdapter(sleeve).realAssets(), uint64(block.timestamp)),
                options: options,
                payInLzToken: false
            }),
            address(this)
        );
    }

    function pushSnapshot(uint32 dstEid, bytes calldata options)
        external
        payable
        onlyVaultManager
        returns (MessagingReceipt memory receipt)
    {
        bytes32 receiver = peers[dstEid];
        if (receiver == bytes32(0)) revert NoPeer(dstEid);

        uint256 assets = IAdapter(sleeve).realAssets();
        uint64 snapshotTimestamp = uint64(block.timestamp);
        receipt = endpoint.send{value: msg.value}(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(assets, snapshotTimestamp),
                options: options,
                payInLzToken: false
            }),
            payable(msg.sender)
        );

        emit SnapshotSent(dstEid, assets, snapshotTimestamp, receipt.guid);
    }
}
