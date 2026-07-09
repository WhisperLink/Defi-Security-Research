// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CetusMath, CetusDeltaA} from "../src/CetusMath.sol";

/// Vulnerable (wrong overflow bound) vs patched (correct bound) checked_shlw.
contract PatchDemoTest is Test {
    CetusDeltaA pool;

    uint128 constant SQRT_P0   = 60_257_519_765_924_248_467_716_150;
    uint128 constant SQRT_P1   = 60_863_087_478_126_617_965_993_239;
    uint128 constant LIQUIDITY = 10_365_647_984_364_446_732_462_244_378_333_008; // ~2^113

    function setUp() public {
        pool = new CetusDeltaA();
    }

    /// VULNERABLE: buggy mask misses the overflow, token A required collapses to 1.
    function test_Vulnerable_overflowMissed() public view {
        uint256 deltaA = pool.getDeltaA(SQRT_P0, SQRT_P1, LIQUIDITY, true, false);
        console2.log("VULNERABLE (mask = 0xffffffffffffffff << 192):");
        console2.log("  token A required for ~2^113 liquidity = %s  (overflow missed)", deltaA);
        assertEq(deltaA, 1);
    }

    /// PATCH: correct bound (n >= 2^192) flags the overflow, so get_delta_a reverts
    /// and the attacker can never mint liquidity for a wrong token amount.
    function test_Patch_correctBoundReverts() public {
        vm.expectRevert(CetusDeltaA.Overflow.selector);
        pool.getDeltaA(SQRT_P0, SQRT_P1, LIQUIDITY, true, true);
        console2.log("PATCH (limit = 1 << 192): overflow flagged -> get_delta_a REVERTS (Overflow)");
    }

    /// Sanity: a legitimate, in-range liquidity still works under the patched bound.
    function test_Patch_normalLiquidityStillWorks() public view {
        uint128 smallLiquidity = 1_000_000_000_000_000; // ordinary position (~1e15, well below 2^113)
        uint256 deltaA = pool.getDeltaA(SQRT_P0, SQRT_P1, smallLiquidity, true, true);
        console2.log("PATCH: a normal position still computes fine, token A = %s", deltaA);
        assertGt(deltaA, 0);
    }
}
