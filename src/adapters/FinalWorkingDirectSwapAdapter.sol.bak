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
    
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        ComplexLimitOrderData calldata limit
    ) external returns (uint256 netPtOut, uint256 netSyFee);
}

contract FinalWorkingDirectSwapAdapter is IAdapter {
    
    error NotAuthorized();
    
    address public immutable parentVault;
    address public immutable pendleRouter;
    address public immutable asset; // WHYPE
    address public immutable kHype;
    address public immutable whypeKhypePool;
    bytes32 public immutable adapterId;
    
    mapping(bytes32 => uint256) public allocations;
    bytes32[] public allocationIds;
    
    event FinalWorkingAllocation(
        address indexed market, 
        uint256 whypeIn, 
        uint256 kHypeOut, 
        uint256 ptOut
    );
    
    constructor(address _vault, address _pendleRouter) {
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        kHype = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
        whypeKhypePool = 0x5Cbe810071DE393de35e574Fb2830E16dA794bab;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        adapterId = keccak256(abi.encode("final-working-direct", address(this), block.timestamp));
    }
    
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        
        address market = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
        uint256 minPtOut = (assets * 95) / 100;
        
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= assets, "Insufficient WHYPE balance");
        
        // STEP 1: WHYPE → kHYPE via direct pool swap
        address token0 = IUniswapV3Pool(whypeKhypePool).token0();
        bool zeroForOne = (asset == token0);
        
        uint256 kHypeBefore = IERC20(kHype).balanceOf(address(this));
        
        // Use proven working price limits from successful swap
        (int256 amount0, int256 amount1) = IUniswapV3Pool(whypeKhypePool).swap(
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
        bytes32 allocationId = keccak256(abi.encode("final-working-allocation"));
        allocations[allocationId] = ptOut;
        
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
        
        emit FinalWorkingAllocation(market, assets, kHypeReceived, ptOut);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        change = int256(ptOut);
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
    
    function deallocate(bytes memory, uint256, bytes4, address)
        external returns (bytes32[] memory, int256) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        return (new bytes32[](0), 0);
    }
    
    function realAssets() external view returns (uint256 total) {
        for (uint i = 0; i < allocationIds.length; i++) {
            total += allocations[allocationIds[i]];
        }
    }
    
    function ids(address) external view returns (bytes32[] memory) {
        return allocationIds;
    }
    
    function getPTBalance() external view returns (uint256) {
        address PT = 0x311dB0FDe558689550c68355783c95eFDfe25329;
        return IERC20(PT).balanceOf(address(this));
    }
    
    function getKHypeBalance() external view returns (uint256) {
        return IERC20(kHype).balanceOf(address(this));
    }
}