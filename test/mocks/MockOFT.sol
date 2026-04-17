// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt, OFTLimit, OFTFeeDetail} from
    "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Minimal mock IOFT for tests. Pulls the ERC20 amount from the sender on `send()` and
///         emits the standard OFTSent event. No actual LZ messaging. quoteSend returns zero fee.
contract MockOFT {
    address public immutable tokenAddr;
    uint64 public nonce;

    event OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD);

    constructor(address token_) {
        tokenAddr = token_;
    }

    function token() external view returns (address) {
        return tokenAddr;
    }

    function oftVersion() external pure returns (bytes4, uint64) {
        return (bytes4(0x02e49c2c), 1);
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function quoteOFT(SendParam calldata sp) external pure returns (OFTLimit memory limit, OFTFeeDetail[] memory details, OFTReceipt memory receipt) {
        limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
        details = new OFTFeeDetail[](0);
        receipt = OFTReceipt({amountSentLD: sp.amountLD, amountReceivedLD: sp.amountLD});
    }

    function quoteSend(SendParam calldata, bool) external pure returns (MessagingFee memory fee) {
        fee = MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function send(SendParam calldata sp, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {
        nonce += 1;
        // Pull tokens from sender (sender must have approved).
        require(IERC20(tokenAddr).transferFrom(msg.sender, address(this), sp.amountLD), "transferFrom failed");
        bytes32 guid = keccak256(abi.encodePacked(address(this), nonce, sp.dstEid, sp.to, sp.amountLD));
        emit OFTSent(guid, sp.dstEid, msg.sender, sp.amountLD, sp.amountLD);
        msgReceipt = MessagingReceipt({guid: guid, nonce: nonce, fee: MessagingFee({nativeFee: 0, lzTokenFee: 0})});
        oftReceipt = OFTReceipt({amountSentLD: sp.amountLD, amountReceivedLD: sp.amountLD});
    }
}
