// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/* ------------------------- Minimal interfaces ------------------------- */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Adapter spec used by VaultV2 (Morpho Vaults v2 docs).
interface IAdapter {
    /// @notice Allocate underlying "asset" from the vault into a target protocol.
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Deallocate underlying "asset" back to the vault from the target protocol.
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Mark-to-market value of all positions (in the vault's underlying asset units, 1e18 scale).
    function realAssets() external view returns (uint256 assets);
}

/// @dev Minimal view into VaultV2 for allocation accounting and asset address.
interface IVaultV2View {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function allocation(bytes32 id) external view returns (uint256);
}

/// @dev Pendle Market (V3) exposes readTokens() to fetch SY/PT/YT addresses, and is itself the LP token (ERC20).
interface IPMarketV3 /* is IERC20-like (balanceOf/decimals via ERC20 in impl) */ {
    function readTokens() external view returns (address _SY, address _PT, address _YT);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev Router V3 (diamond) surface we use. See Etherscan: IPAllActionV3 / IPActionSwapPTV3.
interface IPAllActionV3 {
    /* -------- swap PT <-> token/SY -------- */

    struct SwapData {
        bytes data;
        address router;  // third-party aggregator (e.g., 1inch); unused if zero
        uint256 minAmountOut;
    }

    struct TokenInput {
        address tokenIn;      // the ERC20 token to spend (e.g., ASSET)
        uint256 netTokenIn;   // amount of tokenIn to spend
        address tokenMintSy;  // SY contract to wrap tokenIn into SY (router handles this)
        address pendleSwap;   // router’s internal swap aggregator
        SwapData swapData;    // optional aggregator payload
    }

    struct TokenOutput {
        address tokenOut;     // the ERC20 token you want to receive (e.g., ASSET)
        uint256 minTokenOut;  // slippage floor for tokenOut
        address tokenRedeemSy;// SY to unwrap back to tokenOut
        address pendleSwap;   // router’s internal swap aggregator
        SwapData swapData;    // optional aggregator payload
    }

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps; // 1e18-based tolerance
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        // Fill arrays omitted for brevity; pass empty arrays if unused
        bytes normalFills; // abi-encoded router type; leave empty for no LOs
        bytes flashFills;  // abi-encoded router type; leave empty for no LOs
        bytes optData;
    }

    /// Swap exact ERC20 (via SY) for PT on a market.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    /// Swap exact PT for ERC20 (via SY) from a market.
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}

/// @dev PT/LP Oracle (TWAP) per Pendle docs: PT->SY / PT->asset / LP->asset (all 1e18 scale).
interface IPendleOracle {
    function getPtToSyRate(address market, uint32 twapSeconds) external view returns (uint256 rate18);
    function getPtToAssetRate(address market, uint32 twapSeconds) external view returns (uint256 rate18);
    function getLpToAssetRate(address market, uint32 twapSeconds) external view returns (uint256 rate18);
}

/// @dev Optional: If SY != ASSET, supply SY->ASSET rate (1e18). If SY == ASSET, return 1e18.
interface ISyToAssetOracle {
    function getSyToAssetRate(address sy) external view returns (uint256 rate18);
}

/* ------------------------- Small math util ------------------------- */

library Math {
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }
}

/* ------------------------- Pendle Adapter ------------------------- */

contract PendleV2Adapter is IAdapter {
    using Math for uint256;

    /* IMMUTABLES */

    address public immutable factory;
    address public immutable parentVault;
    address public immutable asset;
    address public immutable router;     // Pendle Router V3 diamond
    address public immutable pOracle;    // PT/LP oracle
    address public immutable syOracle;   // SY->ASSET oracle (can be address(0) if not needed)
    bytes32 public immutable adapterId;

    /* STORAGE */

    address public skimRecipient;

    // Active markets that hold value for this adapter (LP and/or PT balances).
    address[] public marketList;
    mapping(address => bool) public inList;

    /* CONSTANTS */

    uint32 public constant TWAP = 3600; // 1 hour TWAP

    /* ERRORS */

    error NotAuthorized();
    error ApproveFailed();
    error LoanAssetMismatch(); // kept for parity with Morpho example; not used here.

    /* EVENTS */

    event SetSkimRecipient(address indexed newSkimRecipient);
    event Skim(address indexed token, uint256 assets);

    /* CONSTRUCTOR */

    constructor(address _parentVault, address _router, address _pOracle, address _syOracle) {
        factory = msg.sender;
        parentVault = _parentVault;
        router = _router;
        pOracle = _pOracle;
        syOracle = _syOracle;

        address _asset = IVaultV2View(_parentVault).asset();
        asset = _asset;

        adapterId = keccak256(abi.encode("this", address(this)));

        // Pre-approve router & parent vault to save gas on first use (like Morpho adapter pattern).
        _safeApprove(_asset, _router, type(uint256).max);
        _safeApprove(_asset, _parentVault, type(uint256).max);
    }

    /* ------------------------- Admin-like utils (optional) ------------------------- */

    function setSkimRecipient(address newSkimRecipient) external {
        if (msg.sender != IVaultV2View(parentVault).owner()) revert NotAuthorized();
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Skim arbitrary ERC20 (rewards, dust) from adapter to skimRecipient.
    function skim(address token) external {
        if (msg.sender != skimRecipient) revert NotAuthorized();
        uint256 bal = IERC20(token).balanceOf(address(this));
        _safeTransfer(token, skimRecipient, bal);
        emit Skim(token, bal);
    }

    /* ------------------------- IAdapter: allocate/deallocate/realAssets ------------------------- */

    /// @notice Data schema for Router ops we support (extend as you need).
    enum Op {
        SwapExactTokenForPt,   // use ASSET->SY->PT (router)
        SwapExactPtForToken    // PT->SY->ASSET (router)
        // add/remove liq variants can be added later if this strategy needs LP
    }

    struct PendleCall {
        address market;                 // Pendle Market V3 address
        Op op;
        // ---- for SwapExactTokenForPt ----
        IPAllActionV3.TokenInput input;      // tokenIn should be == ASSET for single-asset flow
        uint256 minPtOut;                    // slippage min PT out
        IPAllActionV3.ApproxParams guessPt;  // approx params (see Router docs)
        IPAllActionV3.LimitOrderData limit;  // pass empty if unused

        // ---- for SwapExactPtForToken ----
        uint256 exactPtIn;
        IPAllActionV3.TokenOutput output;    // tokenOut should be == ASSET
    }

    /// @inheritdoc IAdapter
    function allocate(bytes memory data, uint256 /*assets*/, bytes4 /*selector*/, address /*sender*/)
        external
        returns (bytes32[] memory ids_, int256 delta)
    {
        if (msg.sender != parentVault) revert NotAuthorized();

        PendleCall memory p = abi.decode(data, (PendleCall));
        address m = p.market;

        // Track old allocation before action.
        uint256 oldAllocation = _allocation(m);

        if (p.op == Op.SwapExactTokenForPt) {
            // Ensure approvals for tokenIn if not ASSET (rare). For ASSET we pre-approved in ctor.
            if (p.input.tokenIn != asset) {
                _safeApprove(p.input.tokenIn, router, type(uint256).max);
            }

            // Execute ASSET -> (SY) -> PT swap on this market.
            (uint256 netPtOut,,) = IPAllActionV3(router).swapExactTokenForPt(
                address(this),
                m,
                p.minPtOut,
                p.guessPt,
                p.input,
                p.limit
            );

            // Optionally, approve PT to router for future operations (sell/LP), one-time.
            ( , address PT, ) = IPMarketV3(m).readTokens();
            _maybeApprove(PT, router);
            // PT remains in adapter as the strategy's position.
            require(netPtOut > 0, "no-pt-out");
        } else {
            revert("allocate-op-not-supported");
        }

        // Compute new allocation (mark-to-market) and update the market list.
        uint256 newAllocation = _marketValueInAsset(m);
        _updateList(m, oldAllocation, newAllocation);

        ids_ = ids(m);
        delta = int256(newAllocation) - int256(oldAllocation);
        return (ids_, delta);
    }

    /// @inheritdoc IAdapter
    function deallocate(bytes memory data, uint256 /*assets*/, bytes4 /*selector*/, address /*sender*/)
        external
        returns (bytes32[] memory ids_, int256 delta)
    {
        if (msg.sender != parentVault) revert NotAuthorized();

        PendleCall memory p = abi.decode(data, (PendleCall));
        address m = p.market;

        uint256 oldAllocation = _allocation(m);

        if (p.op == Op.SwapExactPtForToken) {
            // Sell exact PT for ASSET via Router.
            ( , address PT, ) = IPMarketV3(m).readTokens();

            _maybeApprove(PT, router); // approve PT to router if needed

            // exactPtIn specified in `p.exactPtIn`; tokenOut should be ASSET.
            IPAllActionV3(router).swapExactPtForToken(
                address(this),
                m,
                p.exactPtIn,
                p.output,
                p.limit
            );

            // Parent vault has infinite allowance for ASSET set in ctor; it will pull ASSET after this call.
        } else {
            revert("deallocate-op-not-supported");
        }

        uint256 newAllocation = _marketValueInAsset(m);
        _updateList(m, oldAllocation, newAllocation);

        ids_ = ids(m);
        delta = int256(newAllocation) - int256(oldAllocation);
        return (ids_, delta);
    }

    /// @inheritdoc IAdapter
    function realAssets() external view returns (uint256 assetsIn18) {
        uint256 sum;
        for (uint256 i = 0; i < marketList.length; i++) {
            sum += _marketValueInAsset(marketList[i]);
        }
        return sum;
    }

    /* ------------------------- Helper views & ids ------------------------- */

    /// @notice Current allocation recorded in VaultV2 for this (adapter, market) id.
    function _allocation(address market) internal view returns (uint256) {
        return IVaultV2View(parentVault).allocation(
            keccak256(abi.encode("this/market", address(this), market))
        );
    }

    /// @notice Risk ids (used for caps): adapter, market, and PT.
    function ids(address market) public view returns (bytes32[] memory ids_) {
        ( , address PT, ) = IPMarketV3(market).readTokens();
        ids_ = new bytes32[](3);
        ids_[0] = adapterId;
        ids_[1] = keccak256(abi.encode("market", market));
        ids_[2] = keccak256(abi.encode("pt", PT));
    }

    /// @notice Mark-to-market value (1e18) = PT_value + LP_value on this market.
    function _marketValueInAsset(address market) internal view returns (uint256) {
        ( , address PT, ) = IPMarketV3(market).readTokens();

        uint256 total;
        // Value PT → asset
        uint256 ptBal = IERC20(PT).balanceOf(address(this));
        if (ptBal > 0) {
            // Prefer PT→asset oracle if available, else PT→SY * SY→asset.
            uint256 ptToAsset = IPendleOracle(pOracle).getPtToAssetRate(market, TWAP);
            if (ptToAsset == 0) {
                // Fallback: PT→SY * SY→ASSET
                uint256 ptToSy = IPendleOracle(pOracle).getPtToSyRate(market, TWAP);
                // If SY oracle is not set, assume SY == ASSET (rate = 1e18).
                uint256 syToAsset = (syOracle == address(0))
                    ? 1e18
                    : ISyToAssetOracle(syOracle).getSyToAssetRate(_syOfMarket(market));
                ptToAsset = ptToSy.mulDiv(syToAsset, 1e18);
            }
            total += ptBal.mulDiv(ptToAsset, 1e18);
        }

        // Value LP (market ERC20) → asset
        uint256 lpBal = IPMarketV3(market).balanceOf(address(this));
        if (lpBal > 0) {
            uint256 lpToAsset = IPendleOracle(pOracle).getLpToAssetRate(market, TWAP);
            total += lpBal.mulDiv(lpToAsset, 1e18);
        }

        return total;
    }

    /// @dev Read SY address from the market via readTokens().
    function _syOfMarket(address market) internal view returns (address sy) {
        (address _SY,,) = IPMarketV3(market).readTokens();
        return _SY;
    }

    /// @dev Maintain marketList membership based on before/after allocation.
    function _updateList(address market, uint256 oldAlloc, uint256 newAlloc) internal {
        if (oldAlloc == 0 && newAlloc > 0 && !inList[market]) {
            inList[market] = true;
            marketList.push(market);
        } else if (oldAlloc > 0 && newAlloc == 0 && inList[market]) {
            // remove by swap-with-last
            inList[market] = false;
            uint256 L = marketList.length;
            for (uint256 i = 0; i < L; i++) {
                if (marketList[i] == market) {
                    marketList[i] = marketList[L - 1];
                    marketList.pop();
                    break;
                }
            }
        }
    }

    /* ------------------------- Internal safe helpers ------------------------- */

    function _safeApprove(address token, address spender, uint256 amt) internal {
        (bool ok) = IERC20(token).approve(spender, amt);
        if (!ok) revert ApproveFailed();
    }

    function _maybeApprove(address token, address spender) internal {
        // cheap idempotent pattern; many PT tokens return true on re-approve max
        IERC20(token).approve(spender, type(uint256).max);
    }

    function _safeTransfer(address token, address to, uint256 amt) internal {
        (bool ok) = IERC20(token).transfer(to, amt);
        require(ok, "transfer-failed");
    }
}