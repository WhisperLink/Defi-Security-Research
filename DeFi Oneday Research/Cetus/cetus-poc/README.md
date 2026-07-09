# Cetus Overflow: Local Reproduction (PoC)

Reproduction of the Cetus Protocol hack (2025-05-22, ~$223M). See the parent
[`../README.md`](../README.md) for the full writeup.

> **Why a port, not a fork.** Cetus runs on **Sui (Move)**, which is not EVM-forkable.
> So instead of a chain fork, this PoC ports the exact vulnerable functions
> (`checked_shlw`, `get_delta_a`) to Solidity and drives them with the **real
> attack-transaction numbers**. Solidity's `<<` truncates high bits without reverting,
> exactly like the Move u256 shift, so the silent overflow reproduces identically.

## Layout

- **`test/CetusOverflow.t.sol`**: drives the ported `get_delta_a` with the real attack
  values (liquidity `≈2^113`, tick range `[300000, 300200]`, the two sqrt prices) and shows
  the buggy `checked_shlw` missing the overflow so the required token amount collapses to **1**.
- `src/CetusMath.sol`: the ported `checked_shlw` (buggy vs correct bound), `div_round`, and `get_delta_a`.
- `test/PatchDemo.t.sol`: vulnerable (wrong mask -> token amount 1) vs patched (correct
  `1 << 192` bound -> overflow flagged -> revert), plus a sanity check that a normal position still works.

## Run

```bash
forge install foundry-rs/forge-std   # if lib/ is not present
forge test --match-test test_ReproduceOverflow -vv   # the overflow reproduction
forge test --match-contract PatchDemoTest -vv        # patch demo
```

## Result

| | |
|---|---|
| `n = liquidity * ΔsqrtP` | `6.2771…e57`  (≥ 2^192, so `n<<64` overflows) |
| buggy mask `0xffff…<<192` | ~2^256, so `n > mask` is **false** (overflow missed) |
| token A required (buggy) | **1**  (for a ~2^113 position) |
| token A required (patched) | **revert (Overflow)** |

The one-line fix (`1 << 192` instead of `0xffffffffffffffff << 192`) turns "mint a
2^113 position for 1 token" into a reverted transaction.
