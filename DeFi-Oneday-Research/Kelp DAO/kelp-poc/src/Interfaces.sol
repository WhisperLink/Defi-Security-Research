// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

// Aave V3 Pool (subset)
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function setUserEMode(uint8 categoryId) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// Chainlink-style price feed used by Aave oracle
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256); // 8 decimals, USD
}

interface IAaveDataProvider {
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);
}

interface IAToken {
    function totalSupply() external view returns (uint256);
}

// Compound V3 (Comet): base asset is WETH; rsETH is a collateral asset.
interface IComet {
    function supply(address asset, uint256 amount) external;      // supply collateral
    function withdraw(address asset, uint256 amount) external;    // withdraw base => opens a borrow
    function borrowBalanceOf(address account) external view returns (uint256);
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
    function baseToken() external view returns (address);
    function totalsCollateral(address asset) external view returns (uint128 totalSupplyAsset, uint128 _reserved);

    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }
    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory);
}
