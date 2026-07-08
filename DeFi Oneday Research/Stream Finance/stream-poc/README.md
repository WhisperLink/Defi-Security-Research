# Stream Finance xUSD Collapse: Local Reproduction (PoC)

Foundry reproduction of the core solvency defect behind the Stream Finance xUSD
collapse (2025-11-03/04). See the parent [`Stream Finance.md`](../Stream%20Finance.md)
for the full writeup.

> **Scope note.** Stream's ~$93M loss originated **off-chain** (an external manager,
> tied to the Balancer hack). What is on-chain and reproducible is the mechanism that
> turned that loss into frozen, unliquidatable bad debt: a lending-market oracle that
> priced xUSD at a fixed ~$1.27 while it was really worth ~$0.10.

## Layout

- **`test/StreamOracleFork.t.sol`** (Arbitrum fork): uses the **real Morpho Blue
  market**, **real xUSD token**, and **real oracle** at block 398,000,000 (2025-11-08).
  Shows the oracle reporting ~$1.27 for worthless xUSD, the live market at 100%
  utilization (frozen), worthless xUSD borrowing ~$1.15M real USDC, and `liquidate()`
  reverting because the position reads "healthy".
- `src/StreamPatch.sol` + `test/PatchDemo.t.sol`: a self-contained MiniLend market
  (mirrors Morpho's oracle-driven health logic) comparing a **hardcoded oracle**
  (bad debt succeeds) against a **market-price oracle** (borrow blocked / position
  liquidatable) and a **sanity-bounded oracle** (freezes on deviation).

## Run

```bash
export ARBITRUM_RPC_URL="https://arb-mainnet.g.alchemy.com/v2/<YOUR_KEY>"  # archive access required
forge install foundry-rs/forge-std   # if lib/ is not present
forge test --match-test test_HardcodedOracleLetsWorthlessCollateralBorrowRealUSDC -vv  # real-market fork
forge test --match-contract PatchDemoTest -vv                                          # patch demo
```

## Result (Arbitrum block 398,000,000)

| Observation | Value |
|---|---|
| Oracle price for xUSD (on-chain) | ~$1.27 (fixed; real market ~$0.10) |
| Real market: USDC supplied = borrowed | 715,500 = 715,500 (100% utilization, frozen) |
| Worthless xUSD posted (real ~$100k) | 1,000,000 xUSD |
| Real USDC borrowed out | ~1,147,231 USDC |
| Unbacked bad debt created | ~$1.05M |
| `liquidate()` | reverts (position "healthy" per oracle) |

The hardcoded oracle is the single point of failure: it converts any depeg into
permanent, unliquidatable bad debt.
