// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IOracle {
    /// Morpho oracle: price of 1 collateral unit in loan-token units, scaled by 1e36
    /// (adjusted for token decimals).
    function price() external view returns (uint256);
}

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);

    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    function supply(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);

    function supplyCollateral(MarketParams memory m, uint256 assets, address onBehalf, bytes memory data) external;

    function borrow(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);

    function liquidate(
        MarketParams memory m,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
}
