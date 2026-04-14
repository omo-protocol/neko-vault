// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultComposerSync} from "../../src/ovault/VaultComposerSync.sol";
import {VaultV2} from "../../src/VaultV2.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {IReceiveAssetsGate, IReceiveSharesGate} from "../../src/interfaces/IGate.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SendParam, OFTLimit, OFTFeeDetail, OFTReceipt, IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt, ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

contract VaultComposerSyncTest is Test {
    uint32 internal constant LOCAL_EID = 30_184;
    uint32 internal constant SRC_EID = 30_102;

    address internal owner = address(this);
    address internal user = makeAddr("user");
    address internal receiver = makeAddr("receiver");
    address internal executor = makeAddr("executor");

    MockERC20 internal asset;
    VaultV2 internal vault;
    MockComposerEndpoint internal endpoint;
    MockComposerOFT internal assetOft;
    MockComposerOFT internal shareOft;
    VaultComposerSync internal composer;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        vault = new VaultV2(owner, address(asset));
        vault.setCurator(owner);

        endpoint = new MockComposerEndpoint(LOCAL_EID);
        assetOft = new MockComposerOFT(address(asset), address(endpoint), false, 4);
        shareOft = new MockComposerOFT(address(vault), address(endpoint), true, 4);
        composer = new VaultComposerSync(address(vault), address(assetOft), address(shareOft));
    }

    function testQuoteSendUsesPreviewDepositEvenThoughMaxDepositIsZero() public {
        SendParam memory sendParam = _remoteSendParam(receiver);

        MessagingFee memory fee = composer.quoteSend(user, address(shareOft), 10e6, sendParam);

        assertEq(fee.nativeFee, vault.previewDeposit(10e6));
    }

    function testQuoteSendUsesPreviewRedeemEvenThoughMaxRedeemIsZero() public {
        SendParam memory sendParam = _remoteSendParam(receiver);

        MessagingFee memory fee = composer.quoteSend(user, address(assetOft), 10e18, sendParam);

        assertEq(fee.nativeFee, vault.previewRedeem(10e18));
    }

    function testLzComposeRefundsToExecutorWhenReceiveSharesGateBlocksReceiver() public {
        address gate = makeAddr("receiveSharesGate");
        _setReceiveSharesGate(gate);
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (receiver)), abi.encode(false));

        asset.mint(address(composer), 10e6);

        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOft), bytes32("compose"), _depositMessage(10e6, _remoteSendParam(receiver)), executor, "");

        SendParam memory refund = assetOft.lastSendParam();
        assertEq(assetOft.lastRefundAddress(), executor);
        assertEq(refund.dstEid, SRC_EID);
        assertEq(refund.amountLD, 10e6);
    }

    function testLzComposeRefundsToExecutorWhenReceiveAssetsGateBlocksReceiver() public {
        address gate = makeAddr("receiveAssetsGate");
        _setReceiveAssetsGate(gate);
        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(false));

        uint256 shares = _fundComposerWithShares(10e6);

        vm.prank(address(endpoint));
        composer.lzCompose(address(shareOft), bytes32("redeem"), _redeemMessage(shares, _remoteSendParam(receiver)), executor, "");

        SendParam memory refund = shareOft.lastSendParam();
        assertEq(shareOft.lastRefundAddress(), executor);
        assertEq(refund.dstEid, SRC_EID);
        assertEq(refund.amountLD, shares);
    }

    function testLzComposeRejectsZeroDestinationAmountAfterQuoteOftRounding() public {
        shareOft.setQuotedAmountReceivedLD(0);
        asset.mint(address(composer), 10e6);

        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOft), bytes32("rounding"), _depositMessage(10e6, _remoteSendParam(receiver)), executor, "");

        SendParam memory refund = assetOft.lastSendParam();
        assertEq(assetOft.lastRefundAddress(), executor);
        assertEq(refund.dstEid, SRC_EID);
        assertEq(refund.amountLD, 10e6);
    }

    function testLzComposeRefundsWhenLocalSendReceivesMsgValue() public {
        asset.mint(address(composer), 10e6);
        SendParam memory localSend = _localSendParam(receiver);
        vm.deal(address(endpoint), 1 ether);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOft), bytes32("local"), _depositMessage(10e6, localSend), executor, "");

        SendParam memory refund = assetOft.lastSendParam();
        MessagingFee memory fee = assetOft.lastFee();
        assertEq(assetOft.lastRefundAddress(), executor);
        assertEq(refund.dstEid, SRC_EID);
        assertEq(fee.nativeFee, 1 ether);
    }

    function testLzComposeRejectsZeroExecutor() public {
        asset.mint(address(composer), 10e6);

        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(VaultComposerSync.InvalidExecutor.selector, address(0)));
        composer.lzCompose(address(assetOft), bytes32("executor"), _depositMessage(10e6, _remoteSendParam(receiver)), address(0), "");
    }

    function _setReceiveSharesGate(address gate) internal {
        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (gate)));
        vault.setReceiveSharesGate(gate);
    }

    function _setReceiveAssetsGate(address gate) internal {
        vault.submit(abi.encodeCall(IVaultV2.setReceiveAssetsGate, (gate)));
        vault.setReceiveAssetsGate(gate);
    }

    function _remoteSendParam(address to) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: 30_101,
            to: bytes32(uint256(uint160(to))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

    function _localSendParam(address to) internal pure returns (SendParam memory) {
        SendParam memory sendParam = _remoteSendParam(to);
        sendParam.dstEid = LOCAL_EID;
        return sendParam;
    }

    function _depositMessage(uint256 amount, SendParam memory sendParam) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(sendParam, uint256(0));
        return OFTComposeMsgCodec.encode(1, SRC_EID, amount, abi.encodePacked(bytes32(uint256(uint160(user))), composeMsg));
    }

    function _redeemMessage(uint256 shares, SendParam memory sendParam) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(sendParam, uint256(0));
        return OFTComposeMsgCodec.encode(1, SRC_EID, shares, abi.encodePacked(bytes32(uint256(uint160(user))), composeMsg));
    }

    function _fundComposerWithShares(uint256 assetsIn) internal returns (uint256 shares) {
        asset.mint(address(this), assetsIn);
        asset.approve(address(vault), assetsIn);
        shares = vault.deposit(assetsIn, address(composer));
    }
}

contract MockComposerEndpoint {
    uint32 internal immutable _eid;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }
}

contract MockComposerOFT is IOFT {
    address internal immutable _token;
    ILayerZeroEndpointV2 internal immutable _endpoint;
    bool internal immutable _approvalRequired;
    uint8 internal immutable _sharedDecimals;

    SendParam internal _lastSendParam;
    MessagingFee internal _lastFee;
    address internal _lastRefundAddress;
    uint256 internal _quotedAmountReceivedLD = type(uint256).max;

    constructor(address token_, address endpoint_, bool approvalRequired_, uint8 sharedDecimals_) {
        _token = token_;
        _endpoint = ILayerZeroEndpointV2(endpoint_);
        _approvalRequired = approvalRequired_;
        _sharedDecimals = sharedDecimals_;
    }

    function setQuotedAmountReceivedLD(uint256 amountReceivedLD) external {
        _quotedAmountReceivedLD = amountReceivedLD;
    }

    function lastSendParam() external view returns (SendParam memory) {
        return _lastSendParam;
    }

    function lastFee() external view returns (MessagingFee memory) {
        return _lastFee;
    }

    function lastRefundAddress() external view returns (address) {
        return _lastRefundAddress;
    }

    function oftVersion() external pure returns (bytes4 interfaceId, uint64 version) {
        return (0x02e49c2c, 1);
    }

    function token() external view returns (address) {
        return _token;
    }

    function approvalRequired() external view returns (bool) {
        return _approvalRequired;
    }

    function endpoint() external view returns (ILayerZeroEndpointV2 iEndpoint) {
        return _endpoint;
    }

    function sharedDecimals() external view returns (uint8) {
        return _sharedDecimals;
    }

    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory receipt)
    {
        oftFeeDetails = new OFTFeeDetail[](0);
        uint256 amountReceivedLD =
            _quotedAmountReceivedLD == type(uint256).max ? sendParam.amountLD : _quotedAmountReceivedLD;
        receipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: amountReceivedLD});
        return (OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max}), oftFeeDetails, receipt);
    }

    function quoteSend(SendParam calldata sendParam, bool) external pure returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: sendParam.amountLD, lzTokenFee: 0});
    }

    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        _lastSendParam = sendParam;
        _lastFee = fee;
        _lastRefundAddress = refundAddress;

        receipt = MessagingReceipt({guid: keccak256(abi.encode(sendParam.dstEid, sendParam.to, refundAddress)), nonce: 1, fee: fee});
        oftReceipt = OFTReceipt({amountSentLD: sendParam.amountLD, amountReceivedLD: sendParam.amountLD});
    }
}
