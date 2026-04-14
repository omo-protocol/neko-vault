// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RemotePpsSnapshotSender} from "../../src/ovault/RemotePpsSnapshotSender.sol";
import {RemotePpsSnapshotStore} from "../../src/ovault/RemotePpsSnapshotStore.sol";
import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract RemotePpsSnapshotSenderStoreTest is Test {
    uint32 internal constant SRC_EID = 30_184;
    uint32 internal constant DST_EID = 30_102;

    address internal owner = address(this);
    address internal vaultManager = makeAddr("vaultManager");

    MockSnapshotSleeve internal sleeve;
    MockSnapshotEndpoint internal endpoint;
    RemotePpsSnapshotSender internal sender;
    RemotePpsSnapshotStore internal store;

    function setUp() public {
        sleeve = new MockSnapshotSleeve();
        endpoint = new MockSnapshotEndpoint(SRC_EID);
        sender = new RemotePpsSnapshotSender(owner, vaultManager, address(sleeve), address(endpoint));

        uint32[] memory remoteEids = new uint32[](1);
        remoteEids[0] = SRC_EID;
        store = new RemotePpsSnapshotStore(owner, address(endpoint), remoteEids);

        sender.setPeer(DST_EID, bytes32(uint256(uint160(address(store)))));
        store.setPeer(SRC_EID, bytes32(uint256(uint160(address(sender)))));
    }

    function testPushSnapshotPropagatesExplicitUnhealthyState() public {
        uint64 healthyTimestamp = uint64(block.timestamp);
        sleeve.setSnapshot(300e6, healthyTimestamp, true, true);

        vm.prank(vaultManager);
        sender.pushSnapshot(DST_EID, "");

        (uint256 assets, bool healthy) = store.quoteRemoteAssets();
        assertEq(assets, 300e6);
        assertTrue(healthy);
        assertTrue(store.snapshotHealthy(SRC_EID));
        assertEq(sender.cachedSnapshotAssets(), 300e6);
        assertEq(sender.cachedSnapshotTimestamp(), healthyTimestamp);

        vm.warp(block.timestamp + 1);
        uint64 unhealthyTimestamp = uint64(block.timestamp);
        sleeve.setSnapshot(325e6, unhealthyTimestamp, false, true);

        vm.prank(vaultManager);
        sender.pushSnapshot(DST_EID, "");

        (assets, healthy) = store.quoteRemoteAssets();
        assertEq(assets, 0);
        assertFalse(healthy);
        assertFalse(store.snapshotHealthy(SRC_EID));

        (uint256 storedAssets, uint64 storedTimestamp,, uint64 nonce) = store.snapshots(SRC_EID);
        assertEq(storedAssets, 325e6);
        assertEq(storedTimestamp, unhealthyTimestamp);
        assertEq(nonce, 2);

        assertEq(sender.cachedSnapshotAssets(), 300e6);
        assertEq(sender.cachedSnapshotTimestamp(), healthyTimestamp);
    }

    function testQuoteSnapshotRevertsWhenSnapshotReadFails() public {
        sleeve.setSnapshot(0, 0, false, false);

        vm.expectRevert(RemotePpsSnapshotSender.SnapshotUnavailable.selector);
        sender.quoteSnapshot(DST_EID, "");
    }

    function testStoreAcceptsLegacyTwoFieldPayload() public {
        uint64 snapshotTimestamp = uint64(block.timestamp);

        vm.prank(address(endpoint));
        store.lzReceive(
            Origin({srcEid: SRC_EID, sender: bytes32(uint256(uint160(address(sender)))), nonce: 1}),
            bytes32("legacy"),
            abi.encode(uint256(123e6), snapshotTimestamp),
            address(0),
            ""
        );

        (uint256 assets, bool healthy) = store.quoteRemoteAssets();
        assertEq(assets, 123e6);
        assertTrue(healthy);
        assertTrue(store.snapshotHealthy(SRC_EID));
    }

    function testStoreRejectsInvalidMessageLength() public {
        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(RemotePpsSnapshotStore.InvalidMessageLength.selector, uint256(32)));
        store.lzReceive(
            Origin({srcEid: SRC_EID, sender: bytes32(uint256(uint160(address(sender)))), nonce: 1}),
            bytes32("bad-length"),
            abi.encode(uint256(1)),
            address(0),
            ""
        );
    }
}

contract MockSnapshotSleeve {
    uint256 internal _assets;
    uint64 internal _timestamp;
    bool internal _healthy;
    bool internal _available;

    function setSnapshot(uint256 assets_, uint64 timestamp_, bool healthy_, bool available_) external {
        _assets = assets_;
        _timestamp = timestamp_;
        _healthy = healthy_;
        _available = available_;
    }

    function quoteSnapshotState() external view returns (uint256 assets, uint64 snapshotTimestamp, bool healthy) {
        require(_available, "snapshot unavailable");
        return (_assets, _timestamp, _healthy);
    }

    function quoteSnapshotAssets() external view returns (uint256 assets, bool healthy) {
        require(_available, "snapshot unavailable");
        return (_assets, _healthy);
    }

    function realAssets() external view returns (uint256 assets) {
        require(_available, "snapshot unavailable");
        return _assets;
    }
}

contract MockSnapshotEndpoint {
    uint32 public immutable eid;
    uint64 public nonce;

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: 1, lzTokenFee: 0});
    }

    function send(MessagingParams calldata params, address)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        nonce++;
        bytes32 guid = keccak256(abi.encode(eid, nonce, params.dstEid, params.receiver, params.message));

        RemotePpsSnapshotStore(address(uint160(uint256(params.receiver)))).lzReceive(
            Origin({srcEid: eid, sender: bytes32(uint256(uint160(msg.sender))), nonce: nonce}),
            guid,
            params.message,
            address(0),
            ""
        );

        return MessagingReceipt({guid: guid, nonce: nonce, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})});
    }
}
