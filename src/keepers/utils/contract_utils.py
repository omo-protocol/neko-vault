"""
Contract ABIs and contract helper functions for OffchainValuationKeeper
"""

# Minimal ABIs
ERC20_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "balanceOf", "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# PT token ABI (ERC5095/Pendle Principal Token)
PT_TOKEN_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "balanceOf", "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "previewRedeem", "inputs": [{"name": "shares", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "expiry", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Pendle market ABI extension
PENDLE_MARKET_ABI = [
    {"name": "expiry", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Pendle Linear Discount Oracle ABI (Chainlink-style feed)
PENDLE_LINEAR_ORACLE_ABI = [
    {"name": "PT", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "baseDiscountPerYear", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "latestRoundData", "inputs": [], "outputs": [
        {"name": "roundId", "type": "uint80"},
        {"name": "answer", "type": "int256"},
        {"name": "startedAt", "type": "uint256"},
        {"name": "updatedAt", "type": "uint256"},
        {"name": "answeredInRound", "type": "uint80"}
    ], "stateMutability": "view", "type": "function"},
]

# Morpho Chainlink Oracle V2 ABI
MORPHO_CHAINLINK_ORACLE_ABI = [
    {"name": "BASE_FEED_1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "price", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

WRAPPER_ABI = [
    {"name": "convertToShares", "inputs": [{"name": "assets", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "convertToAssets", "inputs": [{"name": "shares", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

PENDLE_ORACLE_ABI = [
    {"name": "getPtToAssetRate", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "getOracleState", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [
        {"name": "increaseCardinalityRequired", "type": "bool"},
        {"name": "cardinalityRequired", "type": "uint16"},
        {"name": "oldestObservationSatisfied", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
]

FELIX_ABI = [
    {"name": "position", "inputs": [
        {"name": "id", "type": "bytes32"},
        {"name": "user", "type": "address"}
    ], "outputs": [
        {"name": "supplyShares", "type": "uint256"},
        {"name": "borrowShares", "type": "uint128"},
        {"name": "collateral", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowAssets", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowShares", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "market", "inputs": [{"name": "id", "type": "bytes32"}], "outputs": [
        {"name": "totalSupplyAssets", "type": "uint128"},
        {"name": "totalSupplyShares", "type": "uint128"},
        {"name": "totalBorrowAssets", "type": "uint128"},
        {"name": "totalBorrowShares", "type": "uint128"},
        {"name": "lastUpdate", "type": "uint128"},
        {"name": "fee", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
]

VALUER_ABI = [
    {"name": "getReport", "inputs": [{"name": "strategyId", "type": "bytes32"}], "outputs": [{
        "components": [
            {"name": "value", "type": "uint256"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "confidence", "type": "uint256"},
            {"name": "nonce", "type": "uint256"},
            {"name": "isPush", "type": "bool"},
            {"name": "lastUpdater", "type": "address"},
        ],
        "type": "tuple"
    }], "stateMutability": "view", "type": "function"},
    {"name": "updateValue", "inputs": [
        {"name": "strategyId", "type": "bytes32"},
        {"name": "value", "type": "uint256"},
        {"name": "confidence", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "expiry", "type": "uint256"},
        {"name": "signatures", "type": "bytes[]"}
    ], "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"name": "requiredWeight", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view",
     "type": "function"},
    {"name": "owner", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "asset", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

# UniversalAdapterEscrow ABI (for cache refresh and donation protection)
ADAPTER_ABI = [
    {"name": "refreshCachedValuation", "inputs": [], "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"name": "getCachedValuation", "inputs": [], "outputs": [
        {"name": "value", "type": "uint256"},
        {"name": "timestamp", "type": "uint256"},
        {"name": "isStale", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
    # Donation attack protection: Use tracked values instead of raw balanceOf()
    {"name": "allocations", "inputs": [{"name": "strategyId", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "externalDeposits", "inputs": [{"name": "strategyId", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "totalAllocations", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "totalExternalDeposits", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "asset", "inputs": [],
     "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

# Uniswap V3 NonFungiblePositionManager ABI (includes ERC721Enumerable)
UNISWAP_V3_POSITION_MANAGER_ABI = [
    {"name": "positions", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [
        {"name": "nonce", "type": "uint96"},
        {"name": "operator", "type": "address"},
        {"name": "token0", "type": "address"},
        {"name": "token1", "type": "address"},
        {"name": "fee", "type": "uint24"},
        {"name": "tickLower", "type": "int24"},
        {"name": "tickUpper", "type": "int24"},
        {"name": "liquidity", "type": "uint128"},
        {"name": "feeGrowthInside0LastX128", "type": "uint256"},
        {"name": "feeGrowthInside1LastX128", "type": "uint256"},
        {"name": "tokensOwed0", "type": "uint128"},
        {"name": "tokensOwed1", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "ownerOf", "inputs": [{"name": "tokenId", "type": "uint256"}],
     "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    # ERC721Enumerable functions for position scanning
    {"name": "balanceOf", "inputs": [{"name": "owner", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "tokenOfOwnerByIndex", "inputs": [
        {"name": "owner", "type": "address"},
        {"name": "index", "type": "uint256"}
    ], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Uniswap V3 Pool ABI
UNISWAP_V3_POOL_ABI = [
    {"name": "slot0", "inputs": [], "outputs": [
        {"name": "sqrtPriceX96", "type": "uint160"},
        {"name": "tick", "type": "int24"},
        {"name": "observationIndex", "type": "uint16"},
        {"name": "observationCardinality", "type": "uint16"},
        {"name": "observationCardinalityNext", "type": "uint16"},
        {"name": "feeProtocol", "type": "uint8"},
        {"name": "unlocked", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "observe", "inputs": [{"name": "secondsAgos", "type": "uint32[]"}], "outputs": [
        {"name": "tickCumulatives", "type": "int56[]"},
        {"name": "secondsPerLiquidityCumulativeX128s", "type": "uint160[]"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "token0", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "token1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "liquidity", "inputs": [], "outputs": [{"type": "uint128"}], "stateMutability": "view", "type": "function"},
]

# Chainlink Price Feed ABI (for external oracles)
CHAINLINK_FEED_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "latestRoundData", "inputs": [], "outputs": [
        {"name": "roundId", "type": "uint80"},
        {"name": "answer", "type": "int256"},
        {"name": "startedAt", "type": "uint256"},
        {"name": "updatedAt", "type": "uint256"},
        {"name": "answeredInRound", "type": "uint80"}
    ], "stateMutability": "view", "type": "function"},
]

# Uniswap V2 Pair ABI (for V2 TWAP price queries)
UNISWAP_V2_PAIR_ABI = [
    {"name": "getReserves", "inputs": [], "outputs": [
        {"name": "reserve0", "type": "uint112"},
        {"name": "reserve1", "type": "uint112"},
        {"name": "blockTimestampLast", "type": "uint32"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "price0CumulativeLast", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "price1CumulativeLast", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "token0", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "token1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

# OToken ABI for options valuation
OTOKEN_ABI = [
    {"name": "underlyingAsset", "inputs": [], "outputs": [{"type": "address"}],
     "stateMutability": "view", "type": "function"},
    {"name": "strikeAsset", "inputs": [], "outputs": [{"type": "address"}],
     "stateMutability": "view", "type": "function"},
    {"name": "strikePrice", "inputs": [], "outputs": [{"type": "uint256"}],
     "stateMutability": "view", "type": "function"},
    {"name": "expiryTimestamp", "inputs": [], "outputs": [{"type": "uint256"}],
     "stateMutability": "view", "type": "function"},
    {"name": "isPut", "inputs": [], "outputs": [{"type": "bool"}],
     "stateMutability": "view", "type": "function"},
]

# AAVE V3 Pool ABI (for HyperLend and other AAVE V3 forks)
AAVE_V3_POOL_ABI = [
    {
        "name": "getUserAccountData",
        "inputs": [{"name": "user", "type": "address"}],
        "outputs": [
            {"name": "totalCollateralBase", "type": "uint256"},
            {"name": "totalDebtBase", "type": "uint256"},
            {"name": "availableBorrowsBase", "type": "uint256"},
            {"name": "currentLiquidationThreshold", "type": "uint256"},
            {"name": "ltv", "type": "uint256"},
            {"name": "healthFactor", "type": "uint256"}
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "name": "getReserveData",
        "inputs": [{"name": "asset", "type": "address"}],
        "outputs": [
            {"name": "configuration", "type": "uint256"},
            {"name": "liquidityIndex", "type": "uint128"},
            {"name": "currentLiquidityRate", "type": "uint128"},
            {"name": "variableBorrowIndex", "type": "uint128"},
            {"name": "currentVariableBorrowRate", "type": "uint128"},
            {"name": "currentStableBorrowRate", "type": "uint128"},
            {"name": "lastUpdateTimestamp", "type": "uint40"},
            {"name": "id", "type": "uint16"},
            {"name": "aTokenAddress", "type": "address"},
            {"name": "stableDebtTokenAddress", "type": "address"},
            {"name": "variableDebtTokenAddress", "type": "address"},
            {"name": "interestRateStrategyAddress", "type": "address"},
            {"name": "accruedToTreasury", "type": "uint128"},
            {"name": "unbacked", "type": "uint128"},
            {"name": "isolationModeTotalDebt", "type": "uint128"}
        ],
        "stateMutability": "view",
        "type": "function"
    }
]
