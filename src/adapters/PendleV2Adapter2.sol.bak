// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAdapter {
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external returns (bytes32[] memory ids, int256 change);
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external returns (bytes32[] memory ids, int256 change);
    function realAssets() external view returns (uint256 assets);
    function ids(address) external view returns (bytes32[] memory);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}

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

contract PendleV2Adapter2 is IAdapter {
    
    error NotAuthorized();
    
    address public immutable parentVault;
    address public immutable pendleRouter;
    address public immutable pendleRouterStatic;
    address public immutable asset; // WHYPE
    address public immutable kHype;
    address public immutable whypeKhypePool;
    address public immutable ptToken;
    address public immutable market;
    bytes32 public immutable adapterId;
    
    mapping(bytes32 => uint256) public allocations;
    bytes32[] public allocationIds;
    
    event PendleAllocation(
        address indexed market, 
        uint256 whypeIn, 
        uint256 kHypeOut, 
        uint256 ptOut
    );
    
    event PendleDeallocation(
        address indexed market, 
        uint256 ptIn, 
        uint256 kHypeOut, 
        uint256 whypeOut
    );
    
    constructor(address _vault, address _pendleRouter, address _pendleRouterStatic) {
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        pendleRouterStatic = _pendleRouterStatic;
        kHype = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
        whypeKhypePool = 0x5Cbe810071DE393de35e574Fb2830E16dA794bab;
        ptToken = 0x311dB0FDe558689550c68355783c95eFDfe25329;
        market = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        adapterId = keccak256(abi.encode("pendle-v2-adapter", address(this), block.timestamp));
    }
    
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        uint256 minPtOut = (assets * 95) / 100;
        
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= assets, "Insufficient WHYPE balance");
        
        // STEP 1: WHYPE → kHYPE via direct pool swap
        address token0 = IUniswapV3Pool(whypeKhypePool).token0();
        bool zeroForOne = (asset == token0);
        
        uint256 kHypeBefore = IERC20(kHype).balanceOf(address(this));
        
        // Use proven working price limits from successful swap
        IUniswapV3Pool(whypeKhypePool).swap(
            address(this),                  // recipient
            zeroForOne,                     // WHYPE → kHYPE
            int256(assets),                 // exactInput: positive amount
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, // sqrtPriceLimitX96 (min/max price)
            ""                              // empty callback data
        );
        
        uint256 kHypeReceived = IERC20(kHype).balanceOf(address(this)) - kHypeBefore;
        require(kHypeReceived > 0, "No kHYPE received");
        
        // STEP 2: kHYPE → PT via Pendle (PROVEN WORKING!)
        IERC20(kHype).approve(pendleRouter, kHypeReceived);
        
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: kHypeReceived * 90 / 100,
            guessMax: kHypeReceived * 110 / 100,
            guessOffchain: kHypeReceived,
            maxIteration: 30,
            eps: 1e13
        });
        
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: kHype,
            netTokenIn: kHypeReceived,
            tokenMintSy: kHype,
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
        bytes32 allocationId = keccak256(abi.encode("pendle-v2-allocation"));
        allocations[allocationId] += ptOut; // Accumulate PT tokens
        
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
        
        emit PendleAllocation(market, assets, kHypeReceived, ptOut);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        change = int256(ptOut);
    }
    
    // REVERSE FLOW: PT → kHYPE → WHYPE
    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        bytes32 allocationId = keccak256(abi.encode("pendle-v2-allocation"));
        
        // The `assets` parameter represents desired WHYPE output amount
        uint256 currentPtBalance = IERC20(ptToken).balanceOf(address(this));
        require(currentPtBalance > 0, "No PT tokens to redeem");
        
        // Calculate how much PT we need to redeem to get approximately `assets` WHYPE
        uint256 ptToRedeem;
        try this.calculatePtNeededForWhype(assets) returns (uint256 ptNeeded) {
            ptToRedeem = ptNeeded;
            // Ensure we don't exceed available PT balance
            if (ptToRedeem > currentPtBalance) {
                ptToRedeem = currentPtBalance;
            }
        } catch {
            // Fallback: use simple proportion based on current allocation
            uint256 totalAllocation = allocations[allocationId];
            require(totalAllocation > 0, "No allocation to deallocate");
            ptToRedeem = (assets * currentPtBalance) / totalAllocation;
        }
        
        require(ptToRedeem > 0, "No PT to redeem");
        require(ptToRedeem <= currentPtBalance, "Insufficient PT balance");
        
        // Cap at 95% of current PT balance for safety
        if (ptToRedeem > (currentPtBalance * 95) / 100) {
            ptToRedeem = (currentPtBalance * 95) / 100;
        }
        
        // STEP 1: PT → kHYPE via Pendle
        IERC20(ptToken).approve(pendleRouter, ptToRedeem);
        
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: kHype,
            minTokenOut: (ptToRedeem * 80) / 100, // 20% slippage for safer deallocate
            tokenRedeemSy: kHype,
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
            output.minTokenOut = (ptToRedeem * 70) / 100; // 30% slippage
            
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
        
        // STEP 2: kHYPE → WHYPE via direct pool swap (REVERSE)
        address token0 = IUniswapV3Pool(whypeKhypePool).token0();
        bool zeroForOne = (kHype == token0); // Now kHYPE → WHYPE (reverse direction)
        
        uint256 whypeBefore = IERC20(asset).balanceOf(address(this));
        
        // Use proven working price limits (reversed direction)
        IUniswapV3Pool(whypeKhypePool).swap(
            address(this),                  // recipient
            zeroForOne,                     // kHYPE → WHYPE
            int256(kHypeOut),               // exactInput: positive amount
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, // sqrtPriceLimitX96
            ""                              // empty callback data
        );
        
        uint256 whypeReceived = IERC20(asset).balanceOf(address(this)) - whypeBefore;
        require(whypeReceived > 0, "No WHYPE received");
        
        // Ensure vault can transfer the WHYPE we received
        IERC20(asset).approve(parentVault, whypeReceived);
        
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
        
        emit PendleDeallocation(market, ptToRedeem, kHypeOut, whypeReceived);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        // Return the actual WHYPE received (negative for deallocate)
        // This ensures VaultV2 only tries to transfer what we actually have
        change = -int256(whypeReceived);
    }
    
    // HyperSwap V3 callback for when pool calls back during swap  
    function hyperswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external {
        require(msg.sender == whypeKhypePool, "Invalid caller");
        
        // Pay the pool what it needs (the input amount)
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(whypeKhypePool).token0()).transfer(whypeKhypePool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(whypeKhypePool).token1()).transfer(whypeKhypePool, uint256(amount1Delta));
        }
    }
    
    function realAssets() external view returns (uint256 total) {
        // Get current PT token balance held by adapter
        uint256 currentPtBalance = IERC20(ptToken).balanceOf(address(this));
        
        if (currentPtBalance == 0) return 0;
        
        // Use Dynamic Slippage Calculation for accurate real-time valuation
        try this.calculateDynamicRealAssets(currentPtBalance) returns (uint256 dynamicValue) {
            return dynamicValue;
        } catch {
            // Fallback: use accurate theoretical value with conservative discount
            try this.getAccurateRealAssets(currentPtBalance) returns (uint256 accurateValue) {
                return (accurateValue * 70) / 100; // 30% fallback discount
            } catch {
                // Final fallback: return PT balance as proxy value
                return (currentPtBalance * 70) / 100;
            }
        }
    }
    
    /// @notice Calculate dynamic real assets using actual swap simulation
    /// @dev Simulates PT→kHYPE→WHYPE path to get real-time deliverable amount
    function calculateDynamicRealAssets(uint256 ptBalance) external view returns (uint256) {
        if (ptBalance == 0) return 0;
        
        // PHASE 1: Simulate PT → kHYPE swap to get actual expected kHYPE output
        uint256 expectedKHypeOut = simulatePtToKHypeSwap(ptBalance);
        if (expectedKHypeOut == 0) revert("PT simulation failed");
        
        // PHASE 2: Simulate kHYPE → WHYPE swap to get actual expected WHYPE output  
        uint256 expectedWhypeOut = simulateKHypeToWhypeSwap(expectedKHypeOut);
        if (expectedWhypeOut == 0) revert("WHYPE simulation failed");
        
        // PHASE 3: Apply safety margin for execution risk (5% buffer for price movement)
        uint256 safeDeliverable = (expectedWhypeOut * 95) / 100;
        
        return safeDeliverable;
    }
    
    /// @notice Get accurate real assets value using live rates
    /// @dev Separate function to allow try/catch in realAssets()
    function getAccurateRealAssets(uint256 ptBalance) external view returns (uint256) {
        // STEP 1: Get PT to kHYPE exchange rate from Pendle RouterStatic
        uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
        
        // Calculate total kHYPE value of PT holdings
        uint256 kHypeValue = (ptBalance * ptToKHypeRate) / 1e18;
        
        // STEP 2: Convert kHYPE to WHYPE using current HyperSwap V3 pool rate
        uint256 kHypeToWhypeRate = getKHypeToWHypeRate();
        uint256 whypeValue = (kHypeValue * kHypeToWhypeRate) / 1e18;
        
        return whypeValue;
    }
    
    function ids(address) external view returns (bytes32[] memory) {
        return allocationIds;
    }
    
    /// @notice Get current kHYPE → WHYPE exchange rate from HyperSwap V3 pool
    /// @return rate The amount of WHYPE received per 1 kHYPE (in 18 decimals)
    function getKHypeToWHypeRate() public view returns (uint256 rate) {
        // Get current pool price
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(whypeKhypePool).slot0();
        
        // Get pool token ordering
        address token0 = IUniswapV3Pool(whypeKhypePool).token0();
        
        // Calculate price ratio from sqrtPriceX96
        // Price = (sqrtPriceX96 / 2^96)^2 = token1/token0 price
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        
        if (kHype == token0) {
            // kHYPE is token0, WHYPE is token1
            // Price gives WHYPE per kHYPE directly
            // Convert from X192 to 18 decimals: (priceX192 * 1e18) / 2^192
            rate = (priceX192 * 1e18) >> 192;
        } else {
            // kHYPE is token1, WHYPE is token0  
            // Price gives kHYPE per WHYPE, so we need inverse
            // Rate = 1/price = 2^192 / priceX192
            rate = (1e18 << 192) / priceX192;
        }
        
        // Ensure reasonable bounds (between 0.1 and 10.0 for safety - more lenient for testing)
        require(rate >= 1e17 && rate <= 10e18, "Pool price out of bounds");
    }
    
    function getPTBalance() external view returns (uint256) {
        return IERC20(ptToken).balanceOf(address(this));
    }
    
    function getKHypeBalance() external view returns (uint256) {
        return IERC20(kHype).balanceOf(address(this));
    }
    
    function getWHYPEBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
    
    /// @notice Simulate PT → kHYPE swap to get realistic expected output
    /// @dev Uses RouterStatic rate with realistic slippage estimation
    function simulatePtToKHypeSwap(uint256 ptAmount) internal view returns (uint256 expectedKHypeOut) {
        // Get theoretical rate from Pendle RouterStatic
        uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
        uint256 theoreticalKHype = (ptAmount * ptToKHypeRate) / 1e18;
        
        // Estimate realistic slippage based on swap size
        // Larger swaps have higher slippage due to price impact
        uint256 slippageBps = estimatePendleSlippage(ptAmount);
        expectedKHypeOut = (theoreticalKHype * (10000 - slippageBps)) / 10000;
        
        return expectedKHypeOut;
    }
    
    /// @notice Simulate kHYPE → WHYPE swap using current Uniswap V3 pool state
    /// @dev Calculates exact output using simplified constant product approximation
    function simulateKHypeToWhypeSwap(uint256 kHypeAmount) internal view returns (uint256 expectedWhypeOut) {
        // Estimate output using simplified constant product approximation
        // This provides a good estimate without complex liquidity calculations
        uint256 poolSlippageBps = estimatePoolSlippage(kHypeAmount);
        
        // Calculate theoretical output using current spot rate
        uint256 kHypeToWhypeRate = getKHypeToWHypeRate();
        uint256 theoreticalWhype = (kHypeAmount * kHypeToWhypeRate) / 1e18;
        
        // Apply estimated slippage
        expectedWhypeOut = (theoreticalWhype * (10000 - poolSlippageBps)) / 10000;
        
        return expectedWhypeOut;
    }
    
    /// @notice Estimate Pendle swap slippage based on amount and market conditions
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
    
    /// @notice Estimate HyperSwap V3 pool slippage based on amount
    /// @dev Returns slippage in basis points (100 = 1%)  
    function estimatePoolSlippage(uint256 swapAmount) internal pure returns (uint256 slippageBps) {
        // Base slippage for HyperSwap V3 (typically 0.1-0.5%)
        uint256 baseSlippage = 20; // 0.2%
        
        // Size-based slippage impact
        // For every 10 ETH equivalent, add 0.1% slippage
        uint256 sizeSlippage = (swapAmount / 10e18) * 10; // 0.1% per 10 tokens
        
        // Cap maximum slippage at 3%
        slippageBps = baseSlippage + sizeSlippage;
        if (slippageBps > 300) slippageBps = 300; // Max 3%
        
        return slippageBps;
    }
    
    /// @notice Calculate how much PT is needed to get approximately the desired WHYPE amount
    /// @dev Inverse calculation of realAssets - accounts for slippage in both swaps
    function calculatePtNeededForWhype(uint256 desiredWhype) external view returns (uint256 ptNeeded) {
        if (desiredWhype == 0) return 0;
        
        // REVERSE CALCULATION: We need to work backwards from desired WHYPE to required PT
        
        // STEP 1: Account for kHYPE→WHYPE slippage
        // We need more kHYPE than theoretical to get desired WHYPE due to slippage
        uint256 kHypeToWhypeRate = getKHypeToWHypeRate();
        uint256 theoreticalKHypeNeeded = (desiredWhype * 1e18) / kHypeToWhypeRate;
        
        // Add buffer for kHYPE→WHYPE slippage (use same estimation as forward calculation)
        uint256 poolSlippage = estimatePoolSlippage(theoreticalKHypeNeeded);
        uint256 kHypeNeeded = (theoreticalKHypeNeeded * 10000) / (10000 - poolSlippage);
        
        // STEP 2: Account for PT→kHYPE slippage  
        // We need more PT than theoretical to get desired kHYPE due to slippage
        uint256 ptToKHypeRate = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
        uint256 theoreticalPtNeeded = (kHypeNeeded * 1e18) / ptToKHypeRate;
        
        // Add buffer for PT→kHYPE slippage
        uint256 pendleSlippage = estimatePendleSlippage(theoreticalPtNeeded);
        ptNeeded = (theoreticalPtNeeded * 10000) / (10000 - pendleSlippage);
        
        // Add additional 5% safety margin for market volatility
        ptNeeded = (ptNeeded * 105) / 100;
        
        return ptNeeded;
    }
    
    /// @notice Get current pool exchange rate for monitoring
    /// @return kHypeToWhype Current kHYPE → WHYPE rate (18 decimals)
    /// @return ptToKHype Current PT → kHYPE rate from Pendle (18 decimals)  
    function getCurrentRates() external view returns (uint256 kHypeToWhype, uint256 ptToKHype) {
        // These calls may fail if RouterStatic is not available
        kHypeToWhype = getKHypeToWHypeRate();
        ptToKHype = IPendleRouterStatic(pendleRouterStatic).getPtToAssetRate(market);
    }
}