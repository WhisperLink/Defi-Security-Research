// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Faithful Solidity port of the exact Cetus / integer_mate math that caused the
/// 2025-05-22 hack (~$223M). Cetus runs on Sui (Move), which is not EVM-forkable,
/// so instead of a chain fork we port the vulnerable functions verbatim and drive
/// them with the REAL attack-transaction numbers.
///
/// Solidity's `<<` truncates high bits with no revert, exactly like the Move u256
/// left-shift, so the silent overflow reproduces identically.
library CetusMath {
    /// The BUGGY overflow guard from Cetus's `math_u256::checked_shlw`.
    /// It compares against `0xffffffffffffffff << 192` (~2^256) instead of
    /// `1 << 192` (2^192), so any n in [2^192, 2^256 - 2^192) passes the check
    /// and then `n << 64` overflows silently.
    function checkedShlwBuggy(uint256 n) internal pure returns (uint256 result, bool overflow) {
        uint256 mask = uint256(0xffffffffffffffff) << 192; // WRONG bound
        if (n > mask) {
            return (0, true);
        }
        return (n << 64, false); // silent overflow when n >= 2^192
    }

    /// The CORRECT guard: shifting left by 64 overflows a 256-bit word iff the top
    /// 64 bits are set, i.e. n >= 2^192.
    function checkedShlwFixed(uint256 n) internal pure returns (uint256 result, bool overflow) {
        uint256 limit = uint256(1) << 192; // 2^192
        if (n >= limit) {
            return (0, true);
        }
        return (n << 64, false);
    }

    function divRound(uint256 num, uint256 den, bool roundUp) internal pure returns (uint256 q) {
        q = num / den;
        if (roundUp && num % den != 0) {
            q += 1;
        }
    }
}

/// Port of Cetus's `get_delta_a`: the amount of token A required to mint a given
/// liquidity between two sqrt prices. The `checked_shlw` result feeds the numerator.
contract CetusDeltaA {
    error Overflow(); // Move: assert!(!overflowing)

    function getDeltaA(uint128 sqrtP0, uint128 sqrtP1, uint128 liquidity, bool roundUp, bool useFixed)
        public
        pure
        returns (uint256)
    {
        uint256 diff = uint256(sqrtP1) - uint256(sqrtP0);
        uint256 n = uint256(liquidity) * diff; // full_mul(liquidity, sqrt_price_diff)

        (uint256 numerator, bool overflowing) =
            useFixed ? CetusMath.checkedShlwFixed(n) : CetusMath.checkedShlwBuggy(n);

        if (overflowing) revert Overflow(); // the real contract asserts no overflow here

        uint256 denominator = uint256(sqrtP0) * uint256(sqrtP1); // full_mul(sqrt_price_0, sqrt_price_1)
        return CetusMath.divRound(numerator, denominator, roundUp);
    }
}
