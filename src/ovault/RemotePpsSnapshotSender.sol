// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RemotePpsSnapshotSender {
    error NotOwner();
    error NotVaultManager();
    error InvalidConfig();
    error NoPeer(uint32 dstEid);
    error InvalidRefundAddress();

    event PeerSet(uint32 indexed eid, bytes32 peer);
    event RefundAddressSet(address refundAddress);
    event SnapshotSent(uint32 indexed dstEid, uint256 assets, uint64 snapshotTimestamp, bytes32 guid);

    address public immutable owner;
    address public immutable vaultManager;
    address public immutable sleeve;
    ILayerZeroEndpointV2 public immutable endpoint;
    address public refundAddress;
    uint256 public cachedSnapshotAssets;
    uint64 public cachedSnapshotTimestamp;

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
        refundAddress = owner_;
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    function setRefundAddress(address refundAddress_) external onlyOwner {
        if (refundAddress_ == address(0)) revert InvalidRefundAddress();
        refundAddress = refundAddress_;
        emit RefundAddressSet(refundAddress_);
    }

    function quoteSnapshot(uint32 dstEid, bytes calldata options) external view returns (MessagingFee memory fee) {
        bytes32 receiver = peers[dstEid];
        if (receiver == bytes32(0)) revert NoPeer(dstEid);
        (uint256 assets, uint64 snapshotTimestamp) = _previewSnapshot();

        fee = endpoint.quote(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(assets, snapshotTimestamp),
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

        (uint256 assets, uint64 snapshotTimestamp) = _currentSnapshot();
        receipt = endpoint.send{value: msg.value}(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(assets, snapshotTimestamp),
                options: options,
                payInLzToken: false
            }),
            payable(refundAddress)
        );

        emit SnapshotSent(dstEid, assets, snapshotTimestamp, receipt.guid);
    }

    function _previewSnapshot() internal view returns (uint256 assets, uint64 snapshotTimestamp) {
        (bool success, uint256 liveAssets, uint64 liveTimestamp, bool healthy) = _readSnapshot();
        if (success && healthy && liveTimestamp != 0) {
            return (liveAssets, liveTimestamp);
        }
        if (cachedSnapshotTimestamp != 0) {
            return (cachedSnapshotAssets, cachedSnapshotTimestamp);
        }
        return (0, 0);
    }

    function _currentSnapshot() internal returns (uint256 assets, uint64 snapshotTimestamp) {
        (bool success, uint256 liveAssets, uint64 liveTimestamp, bool healthy) = _readSnapshot();
        if (success && healthy && liveTimestamp != 0) {
            cachedSnapshotAssets = liveAssets;
            cachedSnapshotTimestamp = liveTimestamp;
            return (liveAssets, cachedSnapshotTimestamp);
        }
        if (cachedSnapshotTimestamp != 0) {
            return (cachedSnapshotAssets, cachedSnapshotTimestamp);
        }
        return (0, 0);
    }

    function _readSnapshot()
        internal
        view
        returns (bool success, uint256 assets, uint64 snapshotTimestamp, bool healthy)
    {
        bytes memory data;
        (success, data) = sleeve.staticcall(abi.encodeWithSignature("quoteSnapshotState()"));
        if (success && data.length >= 96) {
            (assets, snapshotTimestamp, healthy) = abi.decode(data, (uint256, uint64, bool));
            return (true, assets, snapshotTimestamp, healthy);
        }

        (success, data) = sleeve.staticcall(abi.encodeWithSignature("quoteSnapshotAssets()"));
        if (success && data.length >= 64) {
            (assets, healthy) = abi.decode(data, (uint256, bool));
            return (true, assets, healthy ? uint64(block.timestamp) : 0, healthy);
        }

        try IAdapter(sleeve).realAssets() returns (uint256 liveAssets) {
            return (true, liveAssets, 0, false);
        } catch {
            return (false, 0, 0, false);
        }
    }
}
