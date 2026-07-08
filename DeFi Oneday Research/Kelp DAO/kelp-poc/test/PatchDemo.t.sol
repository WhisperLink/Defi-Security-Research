// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MockRsETH, BridgeMessage, VulnerableOFTAdapter, GuardedOFTAdapter} from "../src/OFTAdapters.sol";

contract PatchDemoTest is Test {
    MockRsETH token;

    address attacker      = makeAddr("lazarus");
    address compromisedDVN = makeAddr("layerzero_dvn"); // the single 1-of-1 verifier Lazarus poisoned
    address honestDVN_A    = makeAddr("independent_dvn_A");
    address honestDVN_B    = makeAddr("kelp_dvn");

    uint256 constant FORGED = 116_500 ether;

    function setUp() public {
        token = new MockRsETH();
    }

    /// The real configuration: 1-of-1 DVN, no caps. Forged message drains it.
    function test_Vulnerable_forgedReleaseSucceeds() public {
        VulnerableOFTAdapter v = new VulnerableOFTAdapter(token, compromisedDVN);
        token.mint(address(v), 200_000 ether); // backing locked from legit outbound bridging

        // Forged inbound message signed ONLY by the compromised 1-of-1 DVN.
        address[] memory att = new address[](1);
        att[0] = compromisedDVN;
        BridgeMessage memory m = BridgeMessage({amount: FORGED, to: attacker, attesters: att});

        vm.prank(attacker);
        v.lzReceive(m);

        console2.log("VULNERABLE 1/1 adapter:");
        console2.log("  attacker received = %s rsETH", token.balanceOf(attacker) / 1e18);
        assertEq(token.balanceOf(attacker), FORGED, "forgery should succeed on 1/1");
    }

    /// Patch control (1): M-of-N quorum. Same forged message now lacks a quorum.
    function test_Patch_quorumBlocksForgery() public {
        address[] memory dvns = new address[](3);
        dvns[0] = compromisedDVN; dvns[1] = honestDVN_A; dvns[2] = honestDVN_B;
        GuardedOFTAdapter g = new GuardedOFTAdapter(token, dvns, 2, 5_000 ether); // 2-of-3, 5k/day cap
        token.mint(address(g), 200_000 ether);
        g.recordLock(200_000 ether);

        address[] memory att = new address[](1);
        att[0] = compromisedDVN; // attacker only controls ONE DVN
        BridgeMessage memory m = BridgeMessage({amount: FORGED, to: attacker, attesters: att});

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(GuardedOFTAdapter.InsufficientDVNQuorum.selector, 1, 2));
        g.lzReceive(m);

        console2.log("PATCH (1) 2-of-3 quorum: forged 1-signer message REVERTS (InsufficientDVNQuorum)");
        assertEq(token.balanceOf(attacker), 0);
    }

    /// Patch control (2): even if quorum were somehow met, the rate limit caps the bleed.
    function test_Patch_rateLimitCapsRelease() public {
        address[] memory dvns = new address[](3);
        dvns[0] = compromisedDVN; dvns[1] = honestDVN_A; dvns[2] = honestDVN_B;
        GuardedOFTAdapter g = new GuardedOFTAdapter(token, dvns, 2, 5_000 ether);
        token.mint(address(g), 200_000 ether);
        g.recordLock(200_000 ether);

        // Suppose the attacker managed a 2-signer quorum. The 116,500 release still
        // exceeds the 5,000/day window cap.
        address[] memory att = new address[](2);
        att[0] = compromisedDVN; att[1] = honestDVN_A;
        BridgeMessage memory m = BridgeMessage({amount: FORGED, to: attacker, attesters: att});

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(GuardedOFTAdapter.RateLimited.selector, FORGED, 5_000 ether));
        g.lzReceive(m);

        console2.log("PATCH (2) rate limit: 116,500 release REVERTS (cap 5,000/day)");
    }

    /// Patch control (3): supply invariant blocks releasing more than was locked.
    function test_Patch_invariantBlocksUnbacked() public {
        address[] memory dvns = new address[](3);
        dvns[0] = compromisedDVN; dvns[1] = honestDVN_A; dvns[2] = honestDVN_B;
        // Large window cap so the invariant is what bites; only 1,000 rsETH truly locked.
        GuardedOFTAdapter g = new GuardedOFTAdapter(token, dvns, 2, 1_000_000 ether);
        token.mint(address(g), 200_000 ether);
        g.recordLock(1_000 ether); // only 1,000 legitimately locked/backed

        address[] memory att = new address[](2);
        att[0] = compromisedDVN; att[1] = honestDVN_A;
        BridgeMessage memory m = BridgeMessage({amount: FORGED, to: attacker, attesters: att});

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(GuardedOFTAdapter.SupplyInvariantViolated.selector, FORGED, 1_000 ether));
        g.lzReceive(m);

        console2.log("PATCH (3) supply invariant: releasing 116,500 > 1,000 locked REVERTS");
    }
}
