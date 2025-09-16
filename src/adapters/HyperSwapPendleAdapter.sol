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

interface IHyperSwapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
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

contract HyperSwapPendleAdapter is IAdapter {
    
    error NotAuthorized();
    
    address public immutable parentVault;
    address public immutable pendleRouter;
    address public immutable hyperSwapRouter;
    address public immutable asset; // WHYPE
    address public immutable kHype;
    bytes32 public immutable adapterId;
    
    mapping(bytes32 => uint256) public allocations;
    bytes32[] public allocationIds;
    
    event HyperSwapPendleAllocation(address indexed market, uint256 whypeIn, uint256 kHypeOut, uint256 ptOut);
    
    constructor(address _vault, address _pendleRouter, address _hyperSwapRouter) {
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        hyperSwapRouter = _hyperSwapRouter;
        kHype = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        adapterId = keccak256(abi.encode("hyperswap-pendle", address(this), block.timestamp));
    }
    
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        
        address market = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
        uint256 minPtOut = (assets * 95) / 100; // 5% slippage
        
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= assets, "Insufficient WHYPE balance");
        
        // Step 1: Swap WHYPE → kHYPE using HyperSwap V3
        IERC20(asset).approve(hyperSwapRouter, assets);
        
        IHyperSwapV3Router.ExactInputSingleParams memory swapParams = IHyperSwapV3Router.ExactInputSingleParams({
            tokenIn: asset,          // WHYPE
            tokenOut: kHype,         // kHYPE
            fee: 3000,               // 0.3% fee tier (common for major pairs)
            recipient: address(this),
            deadline: block.timestamp + 300, // 5 minutes
            amountIn: assets,
            amountOutMinimum: (assets * 95) / 100, // 5% slippage
            sqrtPriceLimitX96: 0     // No price limit
        });
        
        uint256 kHypeReceived = IHyperSwapV3Router(hyperSwapRouter).exactInputSingle(swapParams);
        
        // Step 2: Use kHYPE with Pendle to get PT tokens
        IERC20(kHype).approve(pendleRouter, kHypeReceived);
        
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: kHypeReceived * 90 / 100,
            guessMax: kHypeReceived * 110 / 100,
            guessOffchain: kHypeReceived,
            maxIteration: 30,
            eps: 1e13
        });
        
        // No external router needed - we already have kHYPE!
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: kHype,
            netTokenIn: kHypeReceived,
            tokenMintSy: kHype,
            pendleSwap: address(0),  // No swap needed
            swapData: IPendleRouter.SwapData({
                swapType: 0,         // No external swap
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
        
        // Track allocation
        bytes32 allocationId = keccak256(abi.encode("hyperswap-pendle-allocation"));
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
        
        emit HyperSwapPendleAllocation(market, assets, kHypeReceived, ptOut);
        
        ids_ = new bytes32[](1);
        ids_[0] = allocationId;
        change = int256(ptOut);
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