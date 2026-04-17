// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOFT, SendParam, MessagingFee, MessagingReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title BaseOftSender
/// @notice On-chain router that wraps LayerZero `IOFT.send()` for strategy top-ups.
///         Per-`destinationRef` routes let the operator configure Base→Polygon (PM) and
///         Base→HyperEVM (HL) flows in one place. For HL, the destination is the LZ vendored
///         `HyperLiquidComposer` on HyperEVM — it auto-spot-sends to HyperCore on arrival via
///         the compose message (`abi.encode(minMsgValue, hlCoreReceiver)`, 64 bytes).
///         For PM, the destination is the operator's PM-registered wallet on Polygon.
///         LZ native fees are paid from this contract's balance (operator tops up via `receive()`).
contract BaseOftSender {
    error NotOwner();
    error NotAuthorized();
    error RouteInactive();
    error InsufficientFeeBalance();
    error InvalidAddress();

    event RouteConfigured(
        bytes32 indexed destinationRef,
        address oft,
        uint32 dstEid,
        bytes32 recipient,
        address hlCoreReceiver,
        bool active
    );
    event AuthorizedCallerSet(address indexed caller, bool allowed);
    event OftSendTriggered(bytes32 indexed destinationRef, uint256 amount, bytes32 guid);
    event OwnerSet(address indexed newOwner);

    /// @notice Per-destination bridge route.
    /// @param oft              The LZ OFT adapter on Base (USDC OFT).
    /// @param dstEid           LZ endpoint ID of the destination chain.
    /// @param recipient        bytes32-packed destination address (composer on HyperEVM, EOA on Polygon).
    /// @param extraOptions     LZ execution options (gas for lzReceive / lzCompose on destination).
    /// @param hlCoreReceiver   Only non-zero when route targets HL composer — the HyperCore spot
    ///                         account to credit. Baked into composeMsg at send time.
    /// @param slippageBps      Max acceptable slippage in bps. `minAmountLD = amount * (10000 - slippageBps) / 10000`.
    ///                         0 = strict (minAmountLD = amountLD). Use for OFTs with fees / shared decimals.
    /// @param active           Route toggle.
    struct Route {
        address oft;
        uint32 dstEid;
        bytes32 recipient;
        bytes extraOptions;
        address hlCoreReceiver;
        uint16 slippageBps;
        bool active;
    }

    address public immutable asset;
    address public owner;
    mapping(address => bool) public authorizedCallers;
    mapping(bytes32 => Route) public routes;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address asset_, address owner_) {
        if (asset_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        asset = asset_;
        owner = owner_;
    }

    /// @notice Accept native for LZ fee top-ups.
    receive() external payable {}

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerSet(caller, allowed);
    }

    function configureRoute(bytes32 destinationRef, Route calldata r) external onlyOwner {
        if (r.oft == address(0) || r.recipient == bytes32(0)) revert InvalidAddress();
        routes[destinationRef] = r;
        emit RouteConfigured(destinationRef, r.oft, r.dstEid, r.recipient, r.hlCoreReceiver, r.active);
    }

    /// @notice Sweep stuck native (fee refills in excess, etc.). ERC20 stuck balance also recoverable.
    function sweepNative(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native sweep failed");
    }

    function sweepToken(address token, address to, uint256 amount) external onlyOwner {
        SafeERC20Lib.safeTransfer(token, to, amount);
    }

    // ─── Bridge ──────────────────────────────────────────────────────────────

    /// @notice Bridge `amount` USDC to the `destinationRef`-configured route via LZ OFT.
    ///         Caller (typically `BaseStrategyModule`) must have already transferred `amount` to
    ///         this contract. The LZ fee is paid from this contract's native balance — operator
    ///         keeps it funded.
    /// @return guid LayerZero message GUID (useful for indexers).
    function bridge(bytes32 destinationRef, uint256 amount) external returns (bytes32 guid) {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();

        Route memory r = routes[destinationRef];
        if (!r.active) revert RouteInactive();

        // Approve OFT to pull USDC from this contract.
        IERC20(asset).approve(r.oft, amount);

        bytes memory composeMsg;
        if (r.hlCoreReceiver != address(0)) {
            // HL composer expects 64-byte abi.encode(uint256 minMsgValue, address hlCoreReceiver)
            composeMsg = abi.encode(uint256(0), r.hlCoreReceiver);
        }

        uint256 minAmountLD = r.slippageBps == 0 ? amount : (amount * (10_000 - uint256(r.slippageBps))) / 10_000;
        SendParam memory sp = SendParam({
            dstEid: r.dstEid,
            to: r.recipient,
            amountLD: amount,
            minAmountLD: minAmountLD,
            extraOptions: r.extraOptions,
            composeMsg: composeMsg,
            oftCmd: bytes("")
        });

        MessagingFee memory fee = IOFT(r.oft).quoteSend(sp, false);
        if (address(this).balance < fee.nativeFee) revert InsufficientFeeBalance();

        (MessagingReceipt memory mr,) = IOFT(r.oft).send{value: fee.nativeFee}(sp, fee, owner);
        guid = mr.guid;
        emit OftSendTriggered(destinationRef, amount, guid);
    }

    /// @notice View-only fee quote for a given route + amount. Operators check this before triggering.
    function quoteFee(bytes32 destinationRef, uint256 amount) external view returns (uint256 nativeFee) {
        Route memory r = routes[destinationRef];
        if (!r.active) return 0;
        bytes memory composeMsg;
        if (r.hlCoreReceiver != address(0)) {
            composeMsg = abi.encode(uint256(0), r.hlCoreReceiver);
        }
        uint256 minAmountLD = r.slippageBps == 0 ? amount : (amount * (10_000 - uint256(r.slippageBps))) / 10_000;
        SendParam memory sp = SendParam({
            dstEid: r.dstEid,
            to: r.recipient,
            amountLD: amount,
            minAmountLD: minAmountLD,
            extraOptions: r.extraOptions,
            composeMsg: composeMsg,
            oftCmd: bytes("")
        });
        MessagingFee memory fee = IOFT(r.oft).quoteSend(sp, false);
        return fee.nativeFee;
    }
}
