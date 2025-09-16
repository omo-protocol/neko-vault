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

interface IMetaAggregationRouterV2 {
    struct SwapDescription {
        address srcToken;
        address dstToken;
        address[] srcReceivers;
        uint256[] srcAmounts;
        address[] feeReceivers;
        uint256[] feeAmounts;
        address destReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
        bytes permit;
    }
    
    function swapSimpleMode(
        address caller,
        SwapDescription calldata desc,
        bytes calldata executorData,
        bytes calldata clientData
    ) external returns (uint256 returnAmount, uint256 gasUsed);
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

contract FinalWorkingMetaRouterAdapter is IAdapter {
    
    error NotAuthorized();
    error MetaRouterSwapFailed();
    
    address public immutable parentVault;
    address public immutable pendleRouter;
    address public immutable metaRouter;
    address public immutable asset; // WHYPE
    address public immutable kHype;
    bytes32 public immutable adapterId;
    
    mapping(bytes32 => uint256) public allocations;
    bytes32[] public allocationIds;
    
    event FinalWorkingAllocation(address indexed market, uint256 whypeIn, uint256 kHypeOut, uint256 ptOut);
    
    constructor(address _vault, address _pendleRouter) {
        parentVault = _vault;
        pendleRouter = _pendleRouter;
        metaRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        kHype = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
        
        (bool success, bytes memory data) = _vault.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        asset = abi.decode(data, (address));
        
        adapterId = keccak256(abi.encode("final-working-meta", address(this), block.timestamp));
    }
    
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids_, int256 change) 
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        
        address market = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
        uint256 minPtOut = (assets * 95) / 100;
        
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= assets, "Insufficient WHYPE balance");
        
        // Step 1: Call MetaAggregationRouterV2 DIRECTLY to swap WHYPE → kHYPE
        IERC20(asset).approve(metaRouter, assets);
        
        // Build WORKING SwapDescription with MINIMAL parameters
        address[] memory srcReceivers = new address[](1);
        srcReceivers[0] = address(this);
        
        uint256[] memory srcAmounts = new uint256[](1);
        srcAmounts[0] = assets;
        
        IMetaAggregationRouterV2.SwapDescription memory desc = IMetaAggregationRouterV2.SwapDescription({
            srcToken: asset,                      // WHYPE
            dstToken: kHype,                      // kHYPE
            srcReceivers: srcReceivers,
            srcAmounts: srcAmounts,
            feeReceivers: new address[](0),       // No fees
            feeAmounts: new uint256[](0),         // No fees  
            destReceiver: address(this),          // kHYPE comes to this adapter
            amount: assets,
            minReturnAmount: (assets * 90) / 100, // 10% slippage for safety
            flags: 2,                             // Include deadline flag (bit 1)
            permit: ""                            // No permit
        });
        
        // Set deadline to current block timestamp + 10 minutes  
        uint256 deadline = block.timestamp + 600;
        bytes memory executorData = abi.encode(deadline);
        bytes memory clientData = "";
        
        uint256 kHypeReceived;
        try IMetaAggregationRouterV2(metaRouter).swapSimpleMode(
            address(this),
            desc,
            executorData,
            clientData
        ) returns (uint256 returnAmount, uint256) {
            kHypeReceived = returnAmount;
        } catch {
            // If deadline in executorData fails, try encoding differently
            executorData = abi.encode(uint256(0), address(0), deadline, "");
            (kHypeReceived,) = IMetaAggregationRouterV2(metaRouter).swapSimpleMode(
                address(this),
                desc,
                executorData,
                clientData
            );
        }
        
        if (kHypeReceived == 0) revert MetaRouterSwapFailed();
        
        // Step 2: Use kHYPE with Pendle (no external router needed!)
        IERC20(kHype).approve(pendleRouter, kHypeReceived);
        
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: kHypeReceived * 90 / 100,
            guessMax: kHypeReceived * 110 / 100,
            guessOffchain: kHypeReceived,
            maxIteration: 30,
            eps: 1e13
        });
        
        // Clean Pendle call - we already have kHYPE!
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: kHype,
            netTokenIn: kHypeReceived,
            tokenMintSy: kHype,
            pendleSwap: address(0),               // No swap needed
            swapData: IPendleRouter.SwapData({
                swapType: 0,                      // No external routing
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