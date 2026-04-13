// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IRemotePpsSnapshotStore} from "../controllers/StrategyControllerInterfaces.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {
    ILayerZeroEndpointV2,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RemotePpsSnapshotStore is ILayerZeroReceiver, IRemotePpsSnapshotStore {
    error NotOwner();
    error OnlyEndpoint(address caller);
    error OnlyPeer(uint32 srcEid, bytes32 sender);
    error InvalidConfig();
    error InvalidRemoteEid(uint32 srcEid);
    error DuplicateRemoteEid(uint32 srcEid);
    error InvalidMessageLength(uint256 length);
    error InvalidSnapshotOrder(uint32 srcEid, uint64 nonce, uint64 lastNonce);
    error FutureSnapshotTimestamp(uint32 srcEid, uint64 snapshotTimestamp, uint64 maxAllowedTimestamp);
    error NativeTransferFailed();

    event PeerSet(uint32 indexed eid, bytes32 peer);
    event SnapshotReceived(uint32 indexed srcEid, uint256 assets, uint64 snapshotTimestamp, bool healthy, bytes32 guid);

    struct Snapshot {
        uint256 assets;
        uint64 snapshotTimestamp;
        uint64 receivedAt;
        uint64 nonce;
    }

    uint256 public constant MAX_SNAPSHOT_AGE = 1 days;
    uint256 public constant MAX_CLOCK_SKEW = 10 minutes;

    address public immutable owner;
    ILayerZeroEndpointV2 public immutable endpoint;
    uint32[] internal _remoteEids;

    mapping(uint32 eid => bytes32 peer) public peers;
    mapping(uint32 eid => bool configured) public isRemoteEid;
    mapping(uint32 eid => bool healthy) public snapshotHealthy;
    mapping(uint32 eid => Snapshot snapshot) public snapshots;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address endpoint_, uint32[] memory remoteEids_) {
        if (owner_ == address(0) || endpoint_ == address(0) || remoteEids_.length == 0) revert InvalidConfig();
        owner = owner_;
        endpoint = ILayerZeroEndpointV2(endpoint_);
        _remoteEids = remoteEids_;

        for (uint256 i; i < remoteEids_.length; i++) {
            uint32 remoteEid = remoteEids_[i];
            if (remoteEid == 0) revert InvalidRemoteEid(remoteEid);
            if (isRemoteEid[remoteEid]) revert DuplicateRemoteEid(remoteEid);
            isRemoteEid[remoteEid] = true;
        }
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        if (!isRemoteEid[eid]) revert InvalidRemoteEid(eid);
        if (peers[eid] != peer) {
            delete snapshots[eid];
            delete snapshotHealthy[eid];
        }
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    function remoteEidCount() external view returns (uint256) {
        return _remoteEids.length;
    }

    function remoteEidAt(uint256 index) external view returns (uint32) {
        return _remoteEids[index];
    }

    function quoteRemoteAssets() external view override returns (uint256 assets, bool healthy) {
        healthy = true;

        for (uint256 i; i < _remoteEids.length; i++) {
            uint32 remoteEid = _remoteEids[i];
            Snapshot memory snapshot = snapshots[remoteEid];
            if (
                !snapshotHealthy[remoteEid] || snapshot.receivedAt == 0 || snapshot.snapshotTimestamp == 0
                    || block.timestamp > uint256(snapshot.receivedAt) + MAX_SNAPSHOT_AGE
                    || block.timestamp > uint256(snapshot.snapshotTimestamp) + MAX_SNAPSHOT_AGE
            ) {
                healthy = false;
                continue;
            }

            assets += snapshot.assets;
        }
    }

    function allowInitializePath(Origin calldata origin) external view override returns (bool) {
        return isRemoteEid[origin.srcEid] && peers[origin.srcEid] == origin.sender;
    }

    function nextNonce(uint32, bytes32) external pure override returns (uint64 nonce) {
        return 0;
    }

    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint(msg.sender);
        if (!isRemoteEid[origin.srcEid]) revert InvalidRemoteEid(origin.srcEid);
        if (peers[origin.srcEid] != origin.sender) revert OnlyPeer(origin.srcEid, origin.sender);

        uint256 assets;
        uint64 snapshotTimestamp;
        bool healthy;
        if (message.length == 64) {
            (assets, snapshotTimestamp) = abi.decode(message, (uint256, uint64));
            healthy = snapshotTimestamp != 0;
        } else if (message.length == 96) {
            (assets, snapshotTimestamp, healthy) = abi.decode(message, (uint256, uint64, bool));
        } else {
            revert InvalidMessageLength(message.length);
        }
        uint64 maxAllowedTimestamp = uint64(block.timestamp + MAX_CLOCK_SKEW);
        if (snapshotTimestamp > maxAllowedTimestamp) {
            revert FutureSnapshotTimestamp(origin.srcEid, snapshotTimestamp, maxAllowedTimestamp);
        }
        Snapshot memory current = snapshots[origin.srcEid];
        if (current.receivedAt != 0) {
            if (origin.nonce <= current.nonce) {
                revert InvalidSnapshotOrder(origin.srcEid, origin.nonce, current.nonce);
            }
        }

        snapshots[origin.srcEid] = Snapshot({
            assets: assets,
            snapshotTimestamp: snapshotTimestamp,
            receivedAt: uint64(block.timestamp),
            nonce: origin.nonce
        });
        snapshotHealthy[origin.srcEid] = healthy;

        emit SnapshotReceived(origin.srcEid, assets, snapshotTimestamp, healthy, guid);
    }

    function recoverNative(address recipient) external onlyOwner {
        (bool success,) = payable(recipient).call{value: address(this).balance}("");
        if (!success) revert NativeTransferFailed();
    }
}
