# Audit Scope

This file defines what we are asking auditors to review, and what we are not. It exists so that quotes from different firms are directly comparable.

Measurements below are **nSLOC** (source lines excluding blank lines and comments), taken from this repository at the commit you are quoting against. This codebase is heavily commented, so raw line counts run roughly 40% higher than nSLOC.

---

## In scope — 1,531 nSLOC, 12 contracts

All first-party code. Every file below is ours, written for this protocol, and carries `SPDX-License-Identifier: UNLICENSED`.

| Contract | nSLOC | Holds funds | Notes |
|---|---:|:---:|---|
| `src/dex/v4/StocksHook.sol` | 421 | yes | Uniswap v4 hook. Holds per-pool reserves, splits the protocol cost across `beforeSwap`/`afterSwap`, charges TWAMM order flow, and fails open on TWAMM errors under a gas guard. Our overrides of the vendored TWAMM live here. Currently ~585 bytes under the EIP-170 limit. |
| `src/StocksStaking.sol` | 405 | yes | Holds the entire stock treasury. Reward streaming, in-kind redemption, and governance-triggered treasury liquidation via a TWAMM order. |
| `src/curve/StocksCurve.sol` | 222 | yes | Bonding curve. Holds user stock and the full TST supply until graduation. Constant-product quoting, anti-snipe window, graduation trigger. |
| `src/dex/v4/StocksGraduator.sol` | 132 | yes | One-shot per launch. Seeds the v4 pool, delivers hook reserves, and mints the single full-range position that is locked permanently. Failures here are not recoverable. |
| `src/StocksLaunchFactory.sol` | 121 | transient | Validates a signed price attestation, deploys the TST token and curve, registers metadata. |
| `src/governance/StocksGovernor.sol` | 86 | no | OpenZeppelin Governor with a frozen per-proposal burn snapshot in `quorum()` and permanently immutable voting settings. |
| `src/dex/v4/StocksPoolView.sol` | 46 | no | Read-only view of one pool. |
| `src/curve/StocksCurveFactory.sol` | 32 | no | Spawner. |
| `src/TSTToken.sol` | 20 | no | `ERC20Votes` with a timestamp clock. |
| `src/governance/StocksGovernorFactory.sol` | 16 | no | Spawner. |
| `src/TokenMetadataRegistry.sol` | 15 | no | Permissionless write-once metadata registry. |
| `src/StocksStakingFactory.sol` | 15 | no | Spawner. |

**Where the risk concentrates:** `StocksHook`, `StocksStaking`, `StocksCurve` and `StocksGraduator` together are 1,180 nSLOC and account for effectively all funds at risk. If scope has to be cut, cut from the bottom of the table, not the top.

---

## Out of scope — 891 nSLOC, `src/dex/v4/twamm/vendor/`

Third-party code. It must stay in the repository because `StocksHook` extends `TWAMM` and the project will not compile without it, but we are not asking anyone to re-audit it.

| File | nSLOC | Origin | Our changes |
|---|---:|---|---|
| `vendor/TWAMM.sol` | 599 | [akshatmittal/v4-twamm-hook](https://github.com/akshatmittal/v4-twamm-hook) | Import paths; solmate `Owned` → OpenZeppelin `Ownable`; `virtual` added to five functions; `_submitOrder` parameter `calldata` → `memory`. No math, accounting, execution or rounding line changed. |
| `vendor/TwammBaseHook.sol` | 107 | Uniswap v4-periphery `BaseHook` | Local adaptation. Permission validation in the constructor, `onlyPoolManager`, reverting defaults. No business logic. |
| `vendor/ITWAMM.sol` | 98 | akshatmittal/v4-twamm-hook | One import path. |
| `vendor/libraries/PoolGetters.sol` | 39 | akshatmittal/v4-twamm-hook | None — byte-identical to upstream. |
| `vendor/libraries/TransferHelper.sol` | 24 | akshatmittal/v4-twamm-hook | None — byte-identical to upstream. |
| `vendor/libraries/OrderPool.sol` | 24 | akshatmittal/v4-twamm-hook | None — byte-identical to upstream. |

**Prior audits of this code:** ABDK Consulting (January 2025) and Certora (January 2025). The upstream was diffed file by file against HEAD `1a37fda`.

**Important:** the code we layer *on top* of TWAMM is **in scope**. That means `StocksHook`'s overrides of `submitOrder`, `batchSubmitOrders` and `sync`, the order-input cost charged in `_chargeOrderInputFeeAndReduce`, and the `beforeSwap` fail-open. Upstream's audits do not cover any of it, and it is where our own review has found the most issues.

---

## Also excluded

- `lib/` — forge-std, OpenZeppelin, Uniswap v4-core. Dependencies, not vendored, and not included in any count above.
- `test/` — roughly 20,000 lines. Not for review, but useful context: the suite runs 672 tests including invariant campaigns, fuzzing and mutation testing, so ramp-up should be fast.

---

## Optional add-on — 188 nSLOC

Priced separately, at your discretion:

| File | nSLOC | Why it may be worth including |
|---|---:|---|
| `script/DeployFactoryV12.s.sol` | 140 | Every economic parameter (graduation threshold, reward bounds, voting delay and period, proposal threshold) is constructor-supplied, so a deployment misconfiguration is a live risk rather than a theoretical one. |
| `script/VerifyDeploymentV12.s.sol` | 48 | Post-deployment wiring check. A false pass here would mask a bad deployment. |

---

## Totals

| | nSLOC |
|---|---:|
| In scope | **1,531** |
| Optional scripts | 188 |
| Out of scope (vendored) | 891 |
| Whole `src/` tree | 2,422 |

---

## Notes for auditors

- **Architecture:** `BUSINESS-LOGIC.md` in this repository describes the system end to end. Start there.
- **Prior review is published in full** under [`audits/`](./audits/), so you can see what has already been covered instead of rediscovering it:
  - [`INTERNAL-AUDIT.md`](./audits/INTERNAL-AUDIT.md) — 23 rounds of internal review, including mutation testing, a formal proof of the curve solvency invariant, symbolic execution, invariant campaigns up to 1,000,000 calls, and live-fork testing against the real Ink PoolManager and all 723 xStock wrappers.
  - [`AUDIT_INDEPENDENT_VERIFICATION.md`](./audits/AUDIT_INDEPENDENT_VERIFICATION.md) — an independent pass that re-derived the reward accounting from first principles. No new vulnerability in `src/`.
  - [`NETHERMIND-AUDITAGENT-SCAN.md`](./audits/NETHERMIND-AUDITAGENT-SCAN.md) — external automated scan by Nethermind's AuditAgent. 22 findings, all independently verified; 4 were real and are fixed.

  None of this is a third-party human audit, which is what we are asking you for.

- **Known accepted trade-offs**, so they are not surprises: a trusted off-chain signer provides the price attestation used at launch; that attestation is a bearer credential not bound to a sender; graduation seeds the stock side from the curve's live balance, so a donation shifts the pool's opening price; and staked TST plus pool-locked liquidity carry no voting power while still counting toward governance quorum. Each is documented with its reasoning in `audits/INTERNAL-AUDIT.md`.
- **Chain:** Ink (chain ID 57073). Solidity 0.8.26 pinned, `via_ir` enabled, Cancun EVM.
