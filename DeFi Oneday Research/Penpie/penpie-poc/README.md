# Penpie Reentrancy: Local Reproduction (PoC)

Foundry reproduction of the Penpie cross-contract reentrancy exploit (2024-09-03, ~$27M).
See the parent [`../README.md`](../README.md) for the full writeup.

## Layout

- **`test/PenpieReentrancy.t.sol`** (mainnet fork): runs the real exploit against the
  **real Penpie + Pendle contracts** at block 20,671,877. Creates a malicious-SY market
  via the real Pendle factories, registers it in Penpie, flash-loans from Balancer,
  re-enters `depositMarket()` during `batchHarvestMarketRewards()`, and drains via
  `multiclaim()`. Exploit logic adapted from the DeFiHackLabs PoC (author: rotcivegaf).
- `src/PenpiePatch.sol` + `test/PatchDemo.t.sol`: a self-contained MiniPenpie that mirrors
  the two flaws (unguarded harvest crediting a balance delta + trust-any-market registration),
  comparing the vulnerable version against `nonReentrant` and a market allowlist.

## Run

```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<YOUR_KEY>"  # archive access required
forge install foundry-rs/forge-std   # if lib/ is not present
forge test --match-test test_ReproducePenpieReentrancy -vv  # real-contract fork exploit
forge test --match-contract PatchDemoTest -vv               # patch demo
```

## Result (block 20,671,877)

| | |
|---|---|
| Stolen agETH | 1,367 |
| Stolen rswETH | 901 |
| Extracted this tx | ~2,269 ETH (~$5.4M at ~$2,400/ETH) |
| Total real incident | ~$27M across 3 txs, Ethereum + Arbitrum |

The reproduced transaction is one of the three real attack transactions. The fix is a
`nonReentrant` guard on the harvest path plus vetted market registration; either alone
blocks the drain (see the patch demo).
