// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../interfaces/IERC20.sol";
import "../interfaces/IAdapter.sol";

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
    
    constructor(address _vault, address _pendleRouter, address _pendleRouterStatic) {
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        pendleRouterStatic = _pendleRouterStatic;
        ptToken = 0x311dB0FDe558689550c68355783c95eFDfe25329;
        market = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        // Ensure vault asset is kHYPE
        require(asset == 0xfD739d4e423301CE9385c1fb8850539D657C296D, "Vault asset must be kHYPE");
        
        adapterId = keccak256(abi.encode("pendle-v2-adapter-khype", address(this), block.timestamp));
    }
    
    /// @notice Allocate kHYPE to Pendle PT tokens (single-step)
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        uint256 minPtOut = (assets * 95) / 100; // 5% slippage tolerance
        
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= assets, "Insufficient kHYPE balance");
        
        // Single Step: kHYPE → PT via Pendle
        IERC20(asset).approve(pendleRouter, assets);
        
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: assets * 90 / 100,
            guessMax: assets * 110 / 100,
            guessOffchain: assets,
            maxIteration: 30,
            eps: 1e13
        });
        
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: asset, // kHYPE
            netTokenIn: assets,
            tokenMintSy: asset,
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
        
        // Single Step: PT → kHYPE via Pendle
        IERC20(ptToken).approve(pendleRouter, ptToRedeem);
        
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: asset, // kHYPE
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
        
        require(kHypeOut > 0, "No kHYPE received from PT");
        
        // Ensure vault can transfer the kHYPE we received
        IERC20(asset).approve(parentVault, kHypeOut);
        
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
    
    /// @notice Get real assets value in kHYPE (simplified single-phase calculation)
    function realAssets() external view returns (uint256 total) {
        // Get current PT token balance held by adapter
        uint256 currentPtBalance = IERC20(ptToken).balanceOf(address(this));
        
        if (currentPtBalance == 0) return 0;
        
        // Simplified calculation: PT → kHYPE simulation only
        try this.calculateSimplifiedRealAssets(currentPtBalance) returns (uint256 kHypeValue) {
            return kHypeValue;
        } catch {
            // Fallback: use RouterStatic with conservative discount
            try IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market) returns (uint256 rate) {
                uint256 theoreticalKHype = (currentPtBalance * rate) / 1e18;
                return (theoreticalKHype * 85) / 100; // 15% safety discount
            } catch {
                // Final fallback: return PT balance as proxy value
                return (currentPtBalance * 85) / 100;
            }
        }
    }
    
    /// @notice Calculate simplified real assets using single-phase PT→kHYPE simulation
    /// @dev Much simpler than the two-phase WHYPE version
    function calculateSimplifiedRealAssets(uint256 ptBalance) external view returns (uint256) {
        if (ptBalance == 0) return 0;
        
        // Single Phase: Simulate PT → kHYPE swap to get actual expected kHYPE output
        uint256 expectedKHypeOut = simulatePtToKHypeSwap(ptBalance);
        if (expectedKHypeOut == 0) revert("PT to kHYPE simulation failed");
        
        // Apply safety margin for execution risk (2% buffer - lower than complex two-step)
        uint256 safeDeliverable = (expectedKHypeOut * 98) / 100;
        
        return safeDeliverable;
    }
    
    function ids(address) external view returns (bytes32[] memory) {
        return allocationIds;
    }
    
    /// @notice Simulate PT → kHYPE swap to get realistic expected output (simplified)
    /// @dev Uses RouterStatic rate with realistic slippage estimation
    function simulatePtToKHypeSwap(uint256 ptAmount) internal view returns (uint256 expectedKHypeOut) {
        // Get theoretical rate from Pendle RouterStatic
        uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
        uint256 theoreticalKHype = (ptAmount * ptToKHypeRate) / 1e18;
        
        // Estimate realistic slippage based on swap size
        uint256 slippageBps = estimatePendleSlippage(ptAmount);
        expectedKHypeOut = (theoreticalKHype * (10000 - slippageBps)) / 10000;
        
        return expectedKHypeOut;
    }
    
    /// @notice Estimate Pendle swap slippage based on amount (same logic as complex version)
    /// @dev Returns slippage in basis points (100 = 1%)
    function estimatePendleSlippage(uint256 ptAmount) internal pure returns (uint256 slippageBps) {
        // Base slippage for Pendle PT swaps (typically 0.5-2%)
        uint256 baseSlippage = 50; // 0.5%
        
        // Size-based slippage (larger amounts = more slippage)
        // For every 1000 PT tokens, add 0.1% slippage
        uint256 sizeSlippage = (ptAmount / 1000e18) * 10; // 0.1% per 1000 PT
        
        // Cap maximum slippage at 5%
        slippageBps = baseSlippage + sizeSlippage;
        if (slippageBps > 500) slippageBps = 500; // Max 5%
        
        return slippageBps;
    }
    
    /// @notice Calculate how much PT is needed to get approximately the desired kHYPE amount (simplified)
    /// @dev Inverse calculation of realAssets - much simpler without two-step conversion
    function calculatePtNeededForKHype(uint256 desiredKHype) external view returns (uint256 ptNeeded) {
        if (desiredKHype == 0) return 0;
        
        // Single-step reverse calculation: kHYPE → PT
        
        // Get PT→kHYPE rate from RouterStatic
        uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
        uint256 theoreticalPtNeeded = (desiredKHype * 1e18) / ptToKHypeRate;
        
        // Add buffer for PT→kHYPE slippage
        uint256 pendleSlippage = estimatePendleSlippage(theoreticalPtNeeded);
        ptNeeded = (theoreticalPtNeeded * 10000) / (10000 - pendleSlippage);
        
        // Add 3% safety margin for market volatility (lower than complex version)
        ptNeeded = (ptNeeded * 103) / 100;
        
        return ptNeeded;
    }
    
    /// @notice Get current Pendle PT exchange rate for monitoring
    /// @return ptToKHype Current PT → kHYPE rate from Pendle (18 decimals)  
    function getCurrentRate() external view returns (uint256 ptToKHype) {
        ptToKHype = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
    }
    
    // Utility functions for monitoring
    function getPTBalance() external view returns (uint256) {
        return IERC20(ptToken).balanceOf(address(this));
    }
    
    function getKHypeBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}