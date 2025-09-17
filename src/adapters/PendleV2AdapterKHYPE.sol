// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../interfaces/IERC20.sol";
import "../interfaces/IAdapter.sol";
import "../libraries/SafeERC20Lib.sol";
import "forge-std/console.sol";

interface IPendleRouterStatic {
    function getPtToAssetRate(address market) external view returns (uint256);
}

interface IPendleRouter {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }
    
    struct SwapData {
        uint8 swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }
    
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct OrderInfo {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        uint8 orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    struct FillOrderParams {
        OrderInfo order;
        bytes signature;
        uint256 makingAmount;
    }

    struct ComplexLimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }
    
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        ComplexLimitOrderData calldata limit
    ) external returns (uint256 netPtOut, uint256 netSyFee);

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        ComplexLimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee);
}

contract PendleV2AdapterKHYPE is IAdapter {
    
    error NotAuthorized();
    
    address public immutable parentVault;
    address public immutable pendleRouter;
    address public immutable pendleRouterStatic;
    address public immutable asset; // kHYPE (vault asset)
    address public immutable ptToken;
    address public immutable market;
    bytes32 public immutable adapterId;
    
    mapping(bytes32 => uint256) public allocations;
    bytes32[] public allocationIds;
    
    event PendleAllocation(
        address indexed market, 
        uint256 kHypeIn, 
        uint256 ptOut
    );
    
    event PendleDeallocation(
        address indexed market, 
        uint256 ptIn, 
        uint256 kHypeOut
    );
    
    constructor(
        address _vault, 
        address _pendleRouter, 
        address _pendleRouterStatic,
        address _ptToken,
        address _market
    ) {
        require(_vault != address(0), "Vault cannot be zero address");
        require(_pendleRouter != address(0), "Pendle router cannot be zero address");
        require(_pendleRouterStatic != address(0), "Pendle router static cannot be zero address");
        require(_ptToken != address(0), "PT token cannot be zero address");
        require(_market != address(0), "Market cannot be zero address");
        
        // Validate contracts have code
        require(_vault.code.length > 0, "Vault must be a contract");
        require(_pendleRouter.code.length > 0, "Pendle router must be a contract");
        require(_ptToken.code.length > 0, "PT token must be a contract");
        require(_market.code.length > 0, "Market must be a contract");
        
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        pendleRouterStatic = _pendleRouterStatic;
        ptToken = _ptToken;
        market = _market;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        // Validate asset has code (is a contract) 
        require(asset.code.length > 0, "Asset must be a contract");
        // TODO: In production, vault asset should be kHYPE (0xfD739d4e423301CE9385c1fb8850539D657C296D)
        console.log("Adapter created for vault:", _vault);
        console.log("Vault asset detected:", asset);
        
        adapterId = keccak256(abi.encode("pendle-v2-adapter-khype", address(this), block.timestamp));
    }
    
    /// @notice Allocate kHYPE to Pendle PT tokens (single-step)
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        uint256 minPtOut = (assets * 95) / 100; // 5% slippage tolerance
        
        // Check what asset we received from vault
        uint256 vaultAssetBalance = IERC20(asset).balanceOf(address(this));
        require(vaultAssetBalance >= assets, "Insufficient vault asset balance");
        
        // If vault asset is kHYPE, use directly; if wHYPE, convert first
        uint256 kHypeAmount;
        if (asset == 0xfD739d4e423301CE9385c1fb8850539D657C296D) {
            // Vault uses kHYPE directly
            kHypeAmount = assets;
            SafeERC20Lib.safeApprove(asset, pendleRouter, kHypeAmount);
        } else {
            // Vault uses wHYPE, convert to kHYPE (assume 1:1 for now)
            // In production, this would need actual conversion via DEX
            kHypeAmount = assets; // Simplified for testing
            SafeERC20Lib.safeApprove(0xfD739d4e423301CE9385c1fb8850539D657C296D, pendleRouter, kHypeAmount);
        }
        
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: assets * 90 / 100,
            guessMax: assets * 110 / 100,
            guessOffchain: assets,
            maxIteration: 30,
            eps: 1e13
        });
        
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: 0xfD739d4e423301CE9385c1fb8850539D657C296D, // kHYPE for Pendle
            netTokenIn: kHypeAmount,
            tokenMintSy: 0xfD739d4e423301CE9385c1fb8850539D657C296D,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        
        IPendleRouter.ComplexLimitOrderData memory limit = IPendleRouter.ComplexLimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: new IPendleRouter.FillOrderParams[](0),
            flashFills: new IPendleRouter.FillOrderParams[](0),
            optData: ""
        });
        
        (uint256 ptOut,) = IPendleRouter(pendleRouter).swapExactTokenForPt(
            address(this),
            market,
            minPtOut,
            approx,
            input,
            limit
        );
        
        require(ptOut > 0, "No PT received");
        
        // Track allocation
        bytes32 allocationId = keccak256(abi.encode("pendle-v2-khype-allocation"));
        allocations[allocationId] += ptOut;
        
        bool exists = false;
        for (uint i = 0; i < allocationIds.length; i++) {
            if (allocationIds[i] == allocationId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            allocationIds.push(allocationId);
        }
        
        emit PendleAllocation(market, assets, ptOut);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        change = int256(ptOut);
    }
    
    /// @notice Deallocate PT tokens back to kHYPE (single-step)
    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        bytes32 allocationId = keccak256(abi.encode("pendle-v2-khype-allocation"));
        
        // The `assets` parameter represents desired kHYPE output amount
        uint256 currentPtBalance = IERC20(ptToken).balanceOf(address(this));
        require(currentPtBalance > 0, "No PT tokens to redeem");
        
        // Calculate how much PT we need to redeem to get approximately `assets` kHYPE
        uint256 ptToRedeem;
        try this.calculatePtNeededForKHype(assets) returns (uint256 ptNeeded) {
            ptToRedeem = ptNeeded;
            // Ensure we don't exceed available PT balance
            if (ptToRedeem > currentPtBalance) {
                ptToRedeem = currentPtBalance;
            }
        } catch {
            // Fallback: use simple proportion based on theoretical rate
            uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
            ptToRedeem = (assets * 1e18) / ptToKHypeRate;
            if (ptToRedeem > currentPtBalance) {
                ptToRedeem = currentPtBalance;
            }
        }
        
        require(ptToRedeem > 0, "No PT to redeem");
        require(ptToRedeem <= currentPtBalance, "Insufficient PT balance");
        
        // Cap at 95% of current PT balance for safety
        if (ptToRedeem > (currentPtBalance * 95) / 100) {
            ptToRedeem = (currentPtBalance * 95) / 100;
        }
        
        // Single Step: PT → Asset via Pendle
        SafeERC20Lib.safeApprove(ptToken, pendleRouter, ptToRedeem);
        
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: asset, // kHYPE for Pendle output
            minTokenOut: (ptToRedeem * 85) / 100, // 15% slippage tolerance for safer deallocate
            tokenRedeemSy: asset,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        
        IPendleRouter.ComplexLimitOrderData memory limit = IPendleRouter.ComplexLimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: new IPendleRouter.FillOrderParams[](0),
            flashFills: new IPendleRouter.FillOrderParams[](0),
            optData: ""
        });
        
        // Try PT→kHYPE swap with error handling
        uint256 kHypeOut;
        try IPendleRouter(pendleRouter).swapExactPtForToken(
            address(this),
            market,
            ptToRedeem,
            output,
            limit
        ) returns (uint256 netTokenOut, uint256) {
            kHypeOut = netTokenOut;
        } catch {
            // If swap fails, try with even more slippage
            output.minTokenOut = (ptToRedeem * 75) / 100; // 25% slippage
            
            try IPendleRouter(pendleRouter).swapExactPtForToken(
                address(this),
                market,
                ptToRedeem,
                output,
                limit
            ) returns (uint256 netTokenOut, uint256) {
                kHypeOut = netTokenOut;
            } catch {
                revert("PT to kHYPE swap failed even with high slippage");
            }
        }
        
        require(kHypeOut > 0, "No asset received from PT");
        
        // Ensure vault can transfer the asset we received
        SafeERC20Lib.safeApprove(asset, parentVault, kHypeOut);
        
        // Update allocation tracking - reduce by PT tokens consumed
        allocations[allocationId] -= ptToRedeem;
        
        // Remove from list if allocation is zero
        if (allocations[allocationId] == 0) {
            for (uint i = 0; i < allocationIds.length; i++) {
                if (allocationIds[i] == allocationId) {
                    allocationIds[i] = allocationIds[allocationIds.length - 1];
                    allocationIds.pop();
                    break;
                }
            }
        }
        
        emit PendleDeallocation(market, ptToRedeem, kHypeOut);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        // Return the actual kHYPE received (negative for deallocate)
        change = -int256(kHypeOut);
    }
    
    /// @notice Get real assets value in vault asset (improved error handling)
    function realAssets() external view returns (uint256 total) {
        // Get current PT token balance held by adapter
        uint256 currentPtBalance = IERC20(ptToken).balanceOf(address(this));
        
        if (currentPtBalance == 0) return 0;
        
        // Primary method: Try simplified calculation with dynamic slippage
        try this.calculateDynamicRealAssets(currentPtBalance) returns (uint256 assetValue) {
            return assetValue;
        } catch {
            // Secondary fallback: Try RouterStatic if available
            try IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market) returns (uint256 rate) {
                if (rate > 0) {
                    uint256 theoreticalAsset = (currentPtBalance * rate) / 1e18;
                    return (theoreticalAsset * 80) / 100; // 20% safety discount due to RouterStatic uncertainty
                }
            } catch {
                // RouterStatic failed - ignore and continue to final fallback
            }
            
            // Final conservative fallback: Assume 1:1 ratio with heavy discount
            return (currentPtBalance * 70) / 100; // 30% safety discount for unknown PT value
        }
    }
    
    /// @notice Calculate real assets using dynamic slippage calculation
    /// @dev Enhanced version with dynamic slippage estimation
    function calculateDynamicRealAssets(uint256 ptBalance) external view returns (uint256) {
        if (ptBalance == 0) return 0;
        
        // Single Phase: Simulate PT → Asset swap with dynamic slippage
        uint256 expectedAssetOut = simulatePtToAssetSwapDynamic(ptBalance);
        if (expectedAssetOut == 0) revert("PT to asset simulation failed");
        
        // Apply safety margin for execution risk (3% buffer for single-step swap)
        uint256 safeDeliverable = (expectedAssetOut * 97) / 100;
        
        return safeDeliverable;
    }
    
    function ids(address) external view returns (bytes32[] memory) {
        return allocationIds;
    }
    
    /// @notice Simulate PT → Asset swap with dynamic slippage calculation
    /// @dev Enhanced version with improved error handling and dynamic slippage
    function simulatePtToAssetSwapDynamic(uint256 ptAmount) internal view returns (uint256 expectedAssetOut) {
        // Try to get theoretical rate from RouterStatic first
        uint256 theoreticalAsset;
        bool routerStaticWorked = false;
        
        try IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market) returns (uint256 rate) {
            if (rate > 0) {
                theoreticalAsset = (ptAmount * rate) / 1e18;
                routerStaticWorked = true;
            }
        } catch {
            // RouterStatic failed, use fallback estimation
        }
        
        if (!routerStaticWorked) {
            // Fallback: Assume near 1:1 ratio but with uncertainty
            theoreticalAsset = ptAmount;
        }
        
        // Apply dynamic slippage based on amount and market conditions
        uint256 slippageBps = estimateDynamicSlippage(ptAmount, routerStaticWorked);
        expectedAssetOut = (theoreticalAsset * (10000 - slippageBps)) / 10000;
        
        return expectedAssetOut;
    }
    
    /// @notice Estimate dynamic slippage based on amount and oracle availability
    /// @dev Returns slippage in basis points (100 = 1%) with enhanced logic
    function estimateDynamicSlippage(uint256 ptAmount, bool oracleWorked) internal pure returns (uint256 slippageBps) {
        // Base slippage depends on oracle availability
        uint256 baseSlippage = oracleWorked ? 50 : 200; // 0.5% if oracle works, 2% if not
        
        // Size-based slippage (larger amounts = more slippage)
        // For every 1000 PT tokens, add proportional slippage
        uint256 sizeSlippage = (ptAmount / 1000e18) * 15; // 0.15% per 1000 PT
        
        // Oracle uncertainty penalty
        uint256 oraclePenalty = oracleWorked ? 0 : 100; // +1% if no oracle
        
        // Combine all factors
        slippageBps = baseSlippage + sizeSlippage + oraclePenalty;
        
        // Cap maximum slippage at 8% (higher than before due to uncertainty)
        if (slippageBps > 800) slippageBps = 800; // Max 8%
        
        return slippageBps;
    }
    
    /// @notice Legacy slippage estimation for backward compatibility  
    /// @dev Returns slippage in basis points (100 = 1%)
    function estimatePendleSlippage(uint256 ptAmount) internal pure returns (uint256 slippageBps) {
        return estimateDynamicSlippage(ptAmount, true); // Assume oracle works for legacy calls
    }
    
    /// @notice Calculate how much PT is needed to get approximately the desired asset amount
    /// @dev Enhanced calculation with dynamic slippage and error handling
    function calculatePtNeededForKHype(uint256 desiredAsset) external view returns (uint256 ptNeeded) {
        if (desiredAsset == 0) return 0;
        
        // Try to get PT→Asset rate from RouterStatic
        uint256 theoreticalPtNeeded;
        bool oracleWorked = false;
        
        try IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market) returns (uint256 rate) {
            if (rate > 0) {
                theoreticalPtNeeded = (desiredAsset * 1e18) / rate;
                oracleWorked = true;
            } else {
                theoreticalPtNeeded = desiredAsset; // Fallback 1:1
            }
        } catch {
            // RouterStatic failed, assume 1:1 ratio
            theoreticalPtNeeded = desiredAsset;
        }
        
        // Add buffer for PT→Asset slippage using dynamic calculation
        uint256 slippage = estimateDynamicSlippage(theoreticalPtNeeded, oracleWorked);
        ptNeeded = (theoreticalPtNeeded * 10000) / (10000 - slippage);
        
        // Add safety margin based on oracle availability
        uint256 safetyMargin = oracleWorked ? 103 : 110; // 3% if oracle works, 10% if not
        ptNeeded = (ptNeeded * safetyMargin) / 100;
        
        return ptNeeded;
    }
    
    /// @notice Get current Pendle PT exchange rate for monitoring
    /// @return ptToAsset Current PT → Asset rate from Pendle (18 decimals), 0 if unavailable
    function getCurrentRate() external view returns (uint256 ptToAsset) {
        try IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market) returns (uint256 rate) {
            return rate;
        } catch {
            return 0; // Return 0 if RouterStatic is unavailable
        }
    }
    
    // Utility functions for monitoring
    function getPTBalance() external view returns (uint256) {
        return IERC20(ptToken).balanceOf(address(this));
    }
    
    function getAssetBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}