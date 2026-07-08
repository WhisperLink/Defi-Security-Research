// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MockToken, MiniPenpie, MaliciousMarket} from "../src/PenpiePatch.sol";

contract PatchDemoTest is Test {
    MockToken token;
    address victim = makeAddr("victim");
    uint256 constant VICTIM_LIQ = 1000 ether;
    uint256 constant FLASH = 1000 ether;

    function setUp() public {
        token = new MockToken("ETH");
    }

    function _seedVictim(MiniPenpie p) internal {
        token.mint(victim, VICTIM_LIQ);
        vm.startPrank(victim);
        token.approve(address(p), type(uint256).max);
        p.deposit(VICTIM_LIQ, victim);
        vm.stopPrank();
    }

    /// VULNERABLE: no reentrancy guard + trust-any-market. The malicious market
    /// re-enters deposit() during harvest; the attacker withdraws that deposit AND
    /// claims it as reward, draining the victim pool.
    function test_Vulnerable_reentrancyDrainsPool() public {
        MiniPenpie p = new MiniPenpie(token, false);
        _seedVictim(p);

        MaliciousMarket m = new MaliciousMarket(p, token);
        token.mint(address(m), FLASH);     // flash-loaned into the fake SY/market
        p.registerMarket(address(m));      // permissionless: anyone registers anything
        m.run(FLASH, address(this));

        uint256 poolBefore = token.balanceOf(address(p));
        p.harvest(address(m), address(this)); // reentrancy inflates claimable
        p.withdraw(FLASH);                     // take the reentrant deposit back
        p.claim(address(this));                // AND claim it as "reward"

        uint256 got = token.balanceOf(address(this));
        console2.log("VULNERABLE (no guard, trust-any-market):");
        console2.log("  attacker received     = %s (flash %s -> profit %s)", got / 1e18, FLASH / 1e18, (got - FLASH) / 1e18);
        console2.log("  victim pool %s -> %s (drained)", poolBefore / 1e18, token.balanceOf(address(p)) / 1e18);
        assertEq(got, 2000 ether);                    // withdraw 1000 + claim 1000
        assertEq(token.balanceOf(address(p)), 0);     // victim funds gone
    }

    /// PATCH (A): nonReentrant. The reentrant deposit during harvest reverts,
    /// so the whole harvest reverts and no reward is inflated.
    function test_Patch_nonReentrantBlocksReentry() public {
        MiniPenpie p = new MiniPenpie(token, true);
        _seedVictim(p);

        MaliciousMarket m = new MaliciousMarket(p, token);
        token.mint(address(m), FLASH);
        p.registerMarket(address(m)); // owner (this contract) registers it as trusted
        m.run(FLASH, address(this));

        vm.expectRevert(MiniPenpie.Reentrancy.selector);
        p.harvest(address(m), address(this));
        console2.log("PATCH (A) nonReentrant: reentrant deposit during harvest REVERTS (Reentrancy)");
    }

    /// PATCH (B): market allowlist. A non-owner cannot register an arbitrary market,
    /// so the malicious market never enters the reward path.
    function test_Patch_marketAllowlistBlocksRegistration() public {
        MiniPenpie p = new MiniPenpie(token, true);
        MaliciousMarket m = new MaliciousMarket(p, token);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(MiniPenpie.UntrustedMarket.selector);
        p.registerMarket(address(m));
        console2.log("PATCH (B) market allowlist: unauthorized registerMarket REVERTS (UntrustedMarket)");
    }
}
