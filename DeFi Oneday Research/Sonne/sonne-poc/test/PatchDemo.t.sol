// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {MockToken, MiniCToken, MiniLend} from "../src/SonnePatch.sol";

contract PatchDemoTest is Test {
    MockToken velo;   // collateral underlying
    MockToken loanTok; // borrowable asset (USDC-like)

    address attacker = makeAddr("attacker");
    address seeder   = makeAddr("seeder");
    address lender   = makeAddr("lender");

    uint256 constant DONATION = 35_000_000 ether; // ~35M VELO, like the real hack

    function setUp() public {
        velo = new MockToken("VELO");
        loanTok = new MockToken("USDC");
    }

    function _newLend(MiniCToken c) internal returns (MiniLend m) {
        m = new MiniLend(loanTok, c);
        loanTok.mint(address(m), 100_000_000 ether); // lenders' funds sitting in the market
    }

    /// VULNERABLE: empty market. 2 wei of soVELO borrows the whole donation's worth.
    function test_Vulnerable_emptyMarketDonation() public {
        MiniCToken c = new MiniCToken(velo);
        MiniLend m = _newLend(c);

        velo.mint(attacker, DONATION + 1 ether);
        vm.startPrank(attacker);
        velo.approve(address(c), type(uint256).max);

        c.mint(400_000_001);                         // near-empty: mints ~2 wei of soVELO
        uint256 tinyTokens = c.balanceOf(attacker);
        velo.transfer(address(c), DONATION);         // DONATION (direct transfer, no mint)

        uint256 cv = c.collateralValue(attacker);
        console2.log("VULNERABLE (empty market):");
        console2.log("  attacker soVELO balance   = %s wei", tinyTokens);
        console2.log("  exchangeRate after donation = %s", c.exchangeRate());
        console2.log("  attacker collateral value = %s VELO", cv / 1e18);

        uint256 before = loanTok.balanceOf(attacker);
        m.borrow(30_000_000 ether);                  // borrow real funds
        vm.stopPrank();
        console2.log("  borrowed = %s USDC against ~2 wei of collateral", (loanTok.balanceOf(attacker) - before) / 1e18);
        assertGt(cv, 1_000_000 ether); // 2 wei counts as millions of collateral
    }

    /// PATCH: market seeded with a burned initial supply. The same donation barely
    /// moves the attacker's collateral, so the over-borrow reverts.
    function test_Patch_seededMarketBlocksDonation() public {
        MiniCToken c = new MiniCToken(velo);
        MiniLend m = _newLend(c);

        // fix: seed + burn a real initial supply at market creation
        velo.mint(seeder, 1_000 ether);
        vm.startPrank(seeder);
        velo.approve(address(c), type(uint256).max);
        c.seedAndBurn(1_000 ether);
        vm.stopPrank();

        velo.mint(attacker, DONATION + 1 ether);
        vm.startPrank(attacker);
        velo.approve(address(c), type(uint256).max);
        c.mint(400_000_001);
        velo.transfer(address(c), DONATION);

        uint256 cv = c.collateralValue(attacker);
        console2.log("PATCH (seeded + burned initial supply):");
        console2.log("  attacker collateral value = %s VELO (donation diluted into burned supply)", cv / 1e18);

        vm.expectRevert(); // Undercollateralized: 2 wei is worth almost nothing now
        m.borrow(30_000_000 ether);
        vm.stopPrank();
        console2.log("  over-borrow of 30,000,000 USDC REVERTS (Undercollateralized)");
        assertLt(cv, 1 ether); // collateral is now negligible
    }
}
