// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IRemotePpsSnapshotStore} from "../controllers/StrategyControllerInterfaces.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {ILayerZeroEndpointV2, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RemotePpsSnapshotStore is ILayerZeroReceiver, IRemotePpsSnapshotStore {
    error NotOwner();
    error OnlyEndpoint(address caller);
    error OnlyPeer(uint32 srcEid, bytes32 sender);
    error InvalidConfig();

    event PeerSet(uint32 indexed eid, bytes32 peer);
    event SnapshotReceived(uint32 indexed srcEid, uint256 assets, uint64 snapshotTimestamp, bytes32 guid);

    struct Snapshot {
        uint256 assets;
        uint64 snapshotTimestamp;
        uint64 receivedAt;
    }

    uint256 public constant MAX_SNAPSHOT_AGE = 1 days;

    address public immutable owner;
    ILayerZeroEndpointV2 public immutable endpoint;
    uint32[] internal _remoteEids;

    mapping(uint32 eid => bytes32 peer) public peers;
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
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
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
            Snapshot memory snapshot = snapshots[_remoteEids[i]];
            assets += snapshot.assets;

            if (
                snapshot.receivedAt == 0 || snapshot.snapshotTimestamp == 0
                    || block.timestamp > uint256(snapshot.snapshotTimestamp) + MAX_SNAPSHOT_AGE
            ) {
                healthy = false;
            }
        }
    }

    function allowInitializePath(Origin calldata origin) external view override returns (bool) {
        return peers[origin.srcEid] == origin.sender;
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
        if (peers[origin.srcEid] != origin.sender) revert OnlyPeer(origin.srcEid, origin.sender);

        (uint256 assets, uint64 snapshotTimestamp) = abi.decode(message, (uint256, uint64));
        snapshots[origin.srcEid] =
            Snapshot({assets: assets, snapshotTimestamp: snapshotTimestamp, receivedAt: uint64(block.timestamp)});

        emit SnapshotReceived(origin.srcEid, assets, snapshotTimestamp, guid);
    }
}
