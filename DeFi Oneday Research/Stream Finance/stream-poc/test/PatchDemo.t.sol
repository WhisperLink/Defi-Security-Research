// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {
    MockToken,
    IOracle,
    HardcodedOracle,
    MarketPriceOracle,
    SanityBoundedOracle,
    MiniLend
} from "../src/StreamPatch.sol";

/// Self-contained demo of the Stream xUSD defect and its fixes, on a MiniLend
/// market that mirrors Morpho's oracle-driven health logic.
///
/// Prices are 1e36-scaled loan-per-collateral. $1.27 = 1.27e36; $0.10 = 0.10e36.
contract PatchDemoTest is Test {
    uint256 constant NOMINAL = 127 * 1e34; // $1.27 (the stuck oracle value)
    uint256 constant REAL    = 10 * 1e34;  // $0.10 (true market price after collapse)
    uint256 constant LLTV    = 915 * 1e15; // 91.5%

    MockToken loan;   // USDC-like
    MockToken coll;   // xUSD-like
    address borrower = makeAddr("stream");
    address lender   = makeAddr("lender");

    function setUp() public {
        loan = new MockToken("USDC");
        coll = new MockToken("xUSD");
    }

    function _market(IOracle o) internal returns (MiniLend m) {
        m = new MiniLend(loan, coll, o, LLTV);
        loan.mint(lender, 2_000_000 ether);
        coll.mint(borrower, 1_000_000 ether); // real value ~$100k, nominal ~$1.27M
        vm.prank(lender);
        loan.approve(address(m), type(uint256).max);
        vm.prank(lender);
        m.supply(1_500_000 ether);
        vm.prank(borrower);
        coll.approve(address(m), type(uint256).max);
        vm.prank(borrower);
        m.depositCollateral(1_000_000 ether);
    }

    /// VULNERABLE: hardcoded $1.27 oracle. Worthless xUSD borrows real USDC and
    /// the position can never be liquidated.
    function test_Vulnerable_hardcodedOracle() public {
        MiniLend m = _market(new HardcodedOracle(NOMINAL));
        uint256 maxBorrow = uint256(1_000_000 ether) * NOMINAL / 1e36 * LLTV / 1e18;

        vm.prank(borrower);
        m.borrow(maxBorrow * 99 / 100);

        uint256 got = loan.balanceOf(borrower);
        console2.log("VULNERABLE (hardcoded $1.27 oracle):");
        console2.log("  xUSD posted real value = ~$100,000");
        console2.log("  real USDC borrowed out = $%s", got / 1e18);
        // even now, the market thinks the borrower is healthy
        console2.log("  isHealthy per oracle   = %s (cannot be liquidated)", m.isHealthy(borrower));
        assertGt(got, 1_000_000 ether); // borrowed > $1M against ~$100k of real value
        assertTrue(m.isHealthy(borrower));
    }

    /// PATCH (1): a market-price oracle blocks the borrow outright once xUSD is worth $0.10.
    function test_Patch_marketPriceOracleBlocksBorrow() public {
        MarketPriceOracle o = new MarketPriceOracle();
        o.set(REAL); // honest price
        MiniLend m = _market(o);

        // Trying to borrow the old nominal amount now reverts as under-collateralized.
        uint256 nominalBorrow = uint256(1_000_000 ether) * NOMINAL / 1e36 * LLTV / 1e18;
        vm.prank(borrower);
        vm.expectRevert(MiniLend.Unhealthy.selector);
        m.borrow(nominalBorrow * 99 / 100);
        console2.log("PATCH (1) market-price oracle: over-borrow against $0.10 xUSD REVERTS (Unhealthy)");
    }

    /// PATCH (1b): an already-open position becomes liquidatable the moment the
    /// oracle reflects the depeg (the opposite of the frozen real market).
    function test_Patch_marketPriceMakesPositionLiquidatable() public {
        MarketPriceOracle o = new MarketPriceOracle();
        o.set(NOMINAL); // pre-collapse: borrow is allowed
        MiniLend m = _market(o);
        uint256 maxBorrow = uint256(1_000_000 ether) * NOMINAL / 1e36 * LLTV / 1e18;
        vm.prank(borrower);
        m.borrow(maxBorrow * 99 / 100);
        assertTrue(m.isHealthy(borrower));

        o.set(REAL); // collapse: oracle now tells the truth
        assertFalse(m.isHealthy(borrower));
        m.liquidate(borrower); // succeeds
        console2.log("PATCH (1b) real oracle: after depeg, position is liquidatable and gets liquidated");
    }

    /// PATCH (3): a sanity-bounded oracle freezes the market (reverts) when the
    /// nominal price diverges from the backing feed beyond the deviation cap,
    /// instead of silently minting bad debt.
    function test_Patch_sanityBoundedOracleFreezes() public {
        MarketPriceOracle backing = new MarketPriceOracle();
        backing.set(REAL); // backing/redemption feed says $0.10
        SanityBoundedOracle o = new SanityBoundedOracle(NOMINAL, backing, 200); // 2% cap
        MiniLend m = _market(o);

        uint256 nominalBorrow = uint256(1_000_000 ether) * NOMINAL / 1e36 * LLTV / 1e18;
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(SanityBoundedOracle.OracleDeviation.selector, NOMINAL, REAL));
        m.borrow(nominalBorrow * 99 / 100);
        console2.log("PATCH (3) sanity-bounded oracle: 1.27 vs 0.10 backing exceeds 2%% cap -> REVERTS (frozen)");
    }
}
