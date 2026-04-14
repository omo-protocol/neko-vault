// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../interfaces/IERC20.sol";
import {IWithdrawalReserveSource} from "../StrategyControllerInterfaces.sol";

library ControllerLiquidityLib {
    function reserveTarget(uint256 totalAssets, uint256 targetReserveBps) internal pure returns (uint256) {
        return totalAssets * targetReserveBps / 10_000;
    }

    function protectedWithdrawalLiquidity(address sleeve) internal view returns (uint256 assets) {
        address queue = settlementQueue(sleeve);
        if (queue == address(0)) return 0;

        (bool success, bytes memory data) =
            queue.staticcall(abi.encodeWithSelector(IWithdrawalReserveSource.totalProtectedAssets.selector));
        if (!success || data.length < 32) return type(uint256).max;
        return abi.decode(data, (uint256));
    }

    function requiredLocalLiquidity(address sleeve, uint256 totalAssets, uint256 targetReserveBps)
        internal
        view
        returns (uint256)
    {
        uint256 targetReserve = reserveTarget(totalAssets, targetReserveBps);
        uint256 protectedAssets = protectedWithdrawalLiquidity(sleeve);
        return targetReserve > protectedAssets ? targetReserve : protectedAssets;
    }

    function availableToAllocate(
        address asset,
        address vault,
        address sleeve,
        uint256 idleAssets,
        uint256 totalAssets,
        uint256 targetReserveBps
    ) internal view returns (uint256) {
        uint256 requiredLiquidity = requiredLocalLiquidity(sleeve, totalAssets, targetReserveBps);
        uint256 totalLiquidAssets = IERC20(asset).balanceOf(vault) + idleAssets;
        if (totalLiquidAssets <= requiredLiquidity) return 0;

        uint256 allocatableAssets = totalLiquidAssets - requiredLiquidity;
        return allocatableAssets < idleAssets ? allocatableAssets : idleAssets;
    }

    function settlementQueue(address sleeve) internal view returns (address queue) {
        (bool success, bytes memory data) = sleeve.staticcall(abi.encodeWithSignature("settlementQueue()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
