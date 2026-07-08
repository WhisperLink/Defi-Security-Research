# Sonne Finance Donation Attack: Local Reproduction (PoC)

Foundry reproduction of the Sonne Finance exploit (2024-05-14, Optimism, ~$20M).
See the parent [`../README.md`](../README.md) for the full writeup.

## Layout

- **`test/SonneDonation.t.sol`** (Optimism fork): runs the real exploit against the
  **real Sonne (Compound V2 fork) contracts** at block 120,062,492. Executes the queued
  governance proposals, flash-loans VELO from Velodrome, mints ~2 wei of soVELO, donates
  35M VELO to explode the exchange rate (2e26 -> 1.77e43), and borrows real USDC against
  ~2 wei of collateral. Exploit logic adapted from the DeFiHackLabs PoC.
- `src/SonnePatch.sol` + `test/PatchDemo.t.sol`: a self-contained MiniCToken that mirrors
  Compound's exchange-rate math, comparing an empty market (donation manipulates the rate)
  against a market seeded with a burned initial supply (donation diluted, over-borrow reverts).

## Run

```bash
export OPTIMISM_RPC_URL="https://opt-mainnet.g.alchemy.com/v2/<YOUR_KEY>"  # archive access required
forge install foundry-rs/forge-std   # if lib/ is not present
forge test --match-test test_ReproduceSonneDonation -vv  # real-contract fork exploit
forge test --match-contract PatchDemoTest -vv            # patch demo
```

## Result (Optimism block 120,062,492)

| | |
|---|---|
| soVELO totalSupply before | 0 (empty market) |
| soVELO minted by attacker | ~2 wei |
| exchangeRate before / after donation | 2e26  ->  1.77e43 |
| USDC borrowed this tx | $724,290 |
| Total real incident | ~$20M across two txs |

The fix is a seed-and-burn initial supply at market creation; the patch demo shows the same
donation then leaves the attacker with ~0 collateral and the over-borrow reverts.
