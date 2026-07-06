# Kelp DAO rsETH Bridge Exploit: Local Reproduction (PoC)

Foundry reproduction of the **on-chain, economically-real** portion of the Kelp DAO
rsETH bridge exploit (2026-04-18). See the parent [`Kelp DAO.md`](../Kelp%20DAO.md)
for the full writeup.

> **Scope note.** The real root cause was **off-chain**: Lazarus compromised
> LayerZero's 1-of-1 DVN servers and force-fed a *forged* cross-chain message that
> looked perfectly valid on-chain. There is no buggy contract to "replay". This PoC
> therefore **models** the forged release with a cheatcode, then executes the *real*
> downstream drain (supply rsETH → borrow WETH) against live mainnet contracts on a fork.

## Layout

- **`test/KelpEndpointForge.t.sol`** (Level B, deepest): plants the verified
  `inboundPayloadHash` in the **real `EndpointV2`** storage (what the poisoned DVN's `verify()`
  writes), then calls the **real `EndpointV2.lzReceive()`**. The endpoint runs its own nonce
  accounting (3239 → 3240) and hash check, then dispatches to the real adapter, which releases
  116,500 rsETH from escrow. The only cheatcode is the single DVN-attestation storage write.
- **`test/KelpRealForgedReceive.t.sol`** (Level A, end-to-end): loads the **real Kelp OFT
  Adapter** (`0x85d4…98Ef3`), impersonates the endpoint, calls the adapter's **real `lzReceive()`**,
  the escrow releases 116,500 rsETH (116,721 → 221), then drains Aave V3 + Compound V3.
- `test/KelpDrainFork.t.sol`: simpler variant that models the release with a `deal()` cheatcode
  instead of the real adapter; same downstream drain. Kept for comparison.
- `src/OFTAdapters.sol` + `test/PatchDemo.t.sol`: a vulnerable 1-of-1 adapter (forged
  release succeeds) vs. a guarded adapter where a 2-of-3 DVN quorum, a rolling rate
  limit, and a `released <= locked` invariant each independently reject the forgery.

## Run

```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<YOUR_KEY>"  # archive access required
forge install foundry-rs/forge-std   # if lib/ is not present
forge test --match-test test_ReproduceDrain -vv   # fork drain
forge test --match-contract PatchDemoTest -vv     # patch demo
```

## Result (block 24,900,000)

| Venue | rsETH supplied | Constraint hit | WETH borrowed |
|---|---|---|---|
| Aave V3 (e-mode 3) | 47,699 | supply-cap headroom (530k cap) | 46,971 |
| Compound V3 (WETH) | 18,000 | base WETH liquidity | 11,294 |
| **Total** | | | **58,266 WETH ≈ $141M** |

The ~$141M reproduced here is a *subset* of the ~$290M real loss: this PoC uses only
Ethereum-mainnet Aave + Compound. The real attacker also used Arbitrum and Euler, which
is exactly why the loss was larger; mainnet supply caps and liquidity alone cap a
single-chain drain well below the full figure.
