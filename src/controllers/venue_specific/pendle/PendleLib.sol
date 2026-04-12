// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalAdapterEscrow} from "../../../adapters/interfaces/IUniversalAdapterEscrow.sol";

interface IPendleRouter {
    enum SwapType {
        NONE,
        KYBERSWAP,
        ODOS,
        ETH_WETH,
        OKX,
        ONE_INCH,
        PARASWAP,
        RESERVE_2,
        RESERVE_3,
        RESERVE_4,
        RESERVE_5
    }

    enum OrderType {
        SY_FOR_PT,
        PT_FOR_SY,
        SY_FOR_YT,
        YT_FOR_SY
    }

    struct SwapData {
        SwapType swapType;
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

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        OrderType orderType;
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
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    struct LimitOrderData {
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
        LimitOrderData calldata limit
    ) external returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}

interface IPendleStaticQuoter {
    function getPtToAssetRate(address market) external view returns (uint256);

    function swapExactPtForTokenStatic(address market, uint256 exactPtIn, address tokenOut)
        external
        view
        returns (
            uint256 netTokenOut,
            uint256 netSyToRedeem,
            uint256 netSyFee,
            uint256 priceImpact,
            uint256 exchangeRateAfter
        );
}

struct PTLoopSwapExactTokenForPtRequest {
    address receiver;
    address market;
    uint256 minPtOut;
    IPendleRouter.ApproxParams guessPtOut;
    IPendleRouter.TokenInput input;
    IPendleRouter.LimitOrderData limit;
}

struct PTLoopSwapExactPtForTokenRequest {
    address receiver;
    address market;
    uint256 exactPtIn;
    IPendleRouter.TokenOutput output;
    IPendleRouter.LimitOrderData limit;
}

struct PTLoopOpenRequest {
    address inputToken;
    address receiver;
    address market;
    uint256 minPtOut;
    IPendleRouter.ApproxParams guessPtOut;
    IPendleRouter.TokenInput input;
    IPendleRouter.LimitOrderData limit;
}

struct PTLoopCloseRequest {
    address ptToken;
    address receiver;
    address market;
    uint256 exactPtIn;
    IPendleRouter.TokenOutput output;
    IPendleRouter.LimitOrderData limit;
}

library PendleLib {
    function createTokenInputSimple(address tokenIn, uint256 netTokenIn)
        internal
        pure
        returns (IPendleRouter.TokenInput memory)
    {
        return IPendleRouter.TokenInput({
            tokenIn: tokenIn,
            netTokenIn: netTokenIn,
            tokenMintSy: tokenIn,
            pendleSwap: address(0),
            swapData: createNoAggregatorSwapData()
        });
    }

    function createTokenOutputSimple(address tokenOut, uint256 minTokenOut)
        internal
        pure
        returns (IPendleRouter.TokenOutput memory)
    {
        return IPendleRouter.TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenOut,
            pendleSwap: address(0),
            swapData: createNoAggregatorSwapData()
        });
    }

    function createDefaultApproxParams() internal pure returns (IPendleRouter.ApproxParams memory) {
        return IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14
        });
    }

    function createEmptyLimitOrderData() internal pure returns (IPendleRouter.LimitOrderData memory) {
        IPendleRouter.FillOrderParams[] memory normalFills = new IPendleRouter.FillOrderParams[](0);
        IPendleRouter.FillOrderParams[] memory flashFills = new IPendleRouter.FillOrderParams[](0);

        return IPendleRouter.LimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: normalFills,
            flashFills: flashFills,
            optData: ""
        });
    }

    function buildApproveCall(address token, address spender, uint256 amount)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call memory)
    {
        return IUniversalAdapterEscrow.Call({
            target: token,
            data: abi.encodeWithSignature("approve(address,uint256)", spender, amount),
            value: 0
        });
    }

    function buildSwapExactTokenForPtCall(address router, PTLoopSwapExactTokenForPtRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call memory)
    {
        return IUniversalAdapterEscrow.Call({
            target: router,
            data: abi.encodeCall(
                IPendleRouter.swapExactTokenForPt,
                (request.receiver, request.market, request.minPtOut, request.guessPtOut, request.input, request.limit)
            ),
            value: 0
        });
    }

    function buildSwapExactPtForTokenCall(address router, PTLoopSwapExactPtForTokenRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call memory)
    {
        return IUniversalAdapterEscrow.Call({
            target: router,
            data: abi.encodeCall(
                IPendleRouter.swapExactPtForToken,
                (request.receiver, request.market, request.exactPtIn, request.output, request.limit)
            ),
            value: 0
        });
    }

    function buildOpenLoopCalls(address router, PTLoopOpenRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = buildApproveCall(request.inputToken, router, request.input.netTokenIn);
        calls[1] = buildSwapExactTokenForPtCall(
            router,
            PTLoopSwapExactTokenForPtRequest({
                receiver: request.receiver,
                market: request.market,
                minPtOut: request.minPtOut,
                guessPtOut: request.guessPtOut,
                input: request.input,
                limit: request.limit
            })
        );
    }

    function buildCloseLoopCalls(address router, PTLoopCloseRequest memory request)
        internal
        pure
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = buildApproveCall(request.ptToken, router, request.exactPtIn);
        calls[1] = buildSwapExactPtForTokenCall(
            router,
            PTLoopSwapExactPtForTokenRequest({
                receiver: request.receiver,
                market: request.market,
                exactPtIn: request.exactPtIn,
                output: request.output,
                limit: request.limit
            })
        );
    }

    function createNoAggregatorSwapData() internal pure returns (IPendleRouter.SwapData memory) {
        return IPendleRouter.SwapData({
            swapType: IPendleRouter.SwapType.NONE,
            extRouter: address(0),
            extCalldata: "",
            needScale: false
        });
    }
}
