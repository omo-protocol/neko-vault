// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalAdapterEscrow} from "../../../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {CoreWriter} from "./CoreWriter.sol";
import {L1Read} from "./L1Read.sol";

struct HyperliquidOrderRequest {
    uint32 assetIndex;
    bool isBuy;
    uint64 limitPx;
    uint64 size;
    bool reduceOnly;
    uint8 encodedTif;
    uint128 cloid;
}

struct HyperliquidOpenHedgeRequest {
    address hyperCoreVault;
    uint64 vaultUsd;
    uint64 perpUsd;
    HyperliquidOrderRequest order;
}

struct HyperliquidCloseHedgeRequest {
    HyperliquidOrderRequest closeOrder;
    uint64 perpToSpotUsd;
    address hyperCoreVault;
    uint64 vaultWithdrawUsd;
}

struct HyperliquidPositionSnapshot {
    uint64 oraclePx;
    uint64 markPx;
    uint64 l1BlockNumber;
    L1Read.Position position;
    L1Read.SpotBalance spotBalance;
    L1Read.Withdrawable withdrawable;
    L1Read.AccountMarginSummary marginSummary;
}

struct HyperliquidUnwindSizing {
    uint256 requestedAssets;
    uint256 shortfallAssets;
    uint256 spotReductionAssets;
    uint256 hedgeReductionAssets;
    uint64 spotPx;
    uint64 markPx;
    uint64 spotSizeToSell;
    uint64 perpSizeToClose;
    bool requiresLayerZero;
    bool requiresEmergencyExit;
}

library HyperliquidLib {
    uint8 internal constant VERSION = 1;
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_VAULT_TRANSFER = 2;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    uint24 internal constant ACTION_CANCEL_ORDER_BY_OID = 10;
    uint24 internal constant ACTION_BORROW_LEND_OPERATION = 15;

    uint8 internal constant BORROW_LEND_SUPPLY = 0;
    uint8 internal constant BORROW_LEND_WITHDRAW = 1;

    function encodeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 encodedTif,
        uint128 cloid
    ) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid));
    }

    function encodeVaultTransfer(address vault, bool isDeposit, uint64 usd) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_VAULT_TRANSFER, abi.encode(vault, isDeposit, usd));
    }

    function encodeUsdClassTransfer(uint64 ntl, bool toPerp) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    function encodeCancelOrderByOid(uint32 asset, uint64 oid) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_CANCEL_ORDER_BY_OID, abi.encode(asset, oid));
    }

    function encodeBorrowLendSupply(uint64 token, uint64 amount) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_BORROW_LEND_OPERATION, abi.encode(BORROW_LEND_SUPPLY, token, amount));
    }

    function encodeBorrowLendWithdraw(uint64 token, uint64 amount) internal pure returns (bytes memory) {
        return _encodeAction(ACTION_BORROW_LEND_OPERATION, abi.encode(BORROW_LEND_WITHDRAW, token, amount));
    }

    function buildRawActionCall(address coreWriter, bytes memory action)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call memory)
    {
        return IUniversalAdapterEscrow.Call({
            target: coreWriter,
            data: abi.encodeCall(CoreWriter.sendRawAction, (action)),
            value: 0
        });
    }

    function buildOpenHedgeCalls(address coreWriter, HyperliquidOpenHedgeRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        uint256 count = 1;
        if (request.vaultUsd > 0) count++;
        if (request.perpUsd > 0) count++;

        calls = new IUniversalAdapterEscrow.Call[](count);
        uint256 index;

        if (request.vaultUsd > 0) {
            calls[index++] =
                buildRawActionCall(coreWriter, encodeVaultTransfer(request.hyperCoreVault, true, request.vaultUsd));
        }

        if (request.perpUsd > 0) {
            calls[index++] = buildRawActionCall(coreWriter, encodeUsdClassTransfer(request.perpUsd, true));
        }

        calls[index] = buildRawActionCall(coreWriter, _encodeOrder(request.order));
    }

    function buildCloseHedgeCalls(address coreWriter, HyperliquidCloseHedgeRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        uint256 count = 1;
        if (request.perpToSpotUsd > 0) count++;
        if (request.vaultWithdrawUsd > 0) count++;

        calls = new IUniversalAdapterEscrow.Call[](count);
        uint256 index;

        calls[index++] = buildRawActionCall(coreWriter, _encodeOrder(request.closeOrder));

        if (request.perpToSpotUsd > 0) {
            calls[index++] = buildRawActionCall(coreWriter, encodeUsdClassTransfer(request.perpToSpotUsd, false));
        }

        if (request.vaultWithdrawUsd > 0) {
            calls[index] = buildRawActionCall(
                coreWriter, encodeVaultTransfer(request.hyperCoreVault, false, request.vaultWithdrawUsd)
            );
        }
    }

    function buildOrderCall(address coreWriter, HyperliquidOrderRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call memory)
    {
        return buildRawActionCall(coreWriter, _encodeOrder(request));
    }

    function _encodeOrder(HyperliquidOrderRequest memory request) private pure returns (bytes memory) {
        return encodeLimitOrder(
            request.assetIndex,
            request.isBuy,
            request.limitPx,
            request.size,
            request.reduceOnly,
            request.encodedTif,
            request.cloid
        );
    }

    function _encodeAction(uint24 actionId, bytes memory encodedAction) private pure returns (bytes memory data) {
        data = new bytes(4 + encodedAction.length);
        data[0] = bytes1(VERSION);
        data[1] = bytes1(uint8(actionId >> 16));
        data[2] = bytes1(uint8(actionId >> 8));
        data[3] = bytes1(uint8(actionId));

        for (uint256 i; i < encodedAction.length; i++) {
            data[4 + i] = encodedAction[i];
        }
    }
}
