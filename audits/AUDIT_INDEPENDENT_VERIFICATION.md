# stocks-ink-contracts — Independent Verification Report

**Date:** 2026-09-23 · **Chain:** Ink mainnet (57073) · **Scope:** independent re-derivation + adversarial probing + full fork/deploy rehearsal
**Relationship to `AUDIT.md`:** complementary independent pass, not a replacement. `AUDIT.md` holds the full audit history (rounds 1–9, V7 external-review status, pre-launch checks). This file records what a fresh, independent verification of the reward accounting, governance, hook economics, fork suite and deployment path found.

---

## Verdict

**No new Critical / High / Medium / Low vulnerability was found in the production `src/` contracts.** Independent re-derivation and adversarial tests confirm the reward accounting, governance, hook fee routing and the full token lifecycle are **correct and conservative**. Exactly **one defect was found, and it was in a test harness, not a contract** (IV-5, fixed). The fork test suite and the production deployment path were both validated against **real Ink mainnet state**. One informational hardening item was identified (IV-8): the permissionless `notifyRewardAmount()` lacks `nonReentrant`, which a *malicious* stock token could exploit to re-register a bounded `protocolCut` mid-`redeem()` — unreachable with the production (standard ERC20) stock token, so not a live vulnerability. No production `src/` contract was modified during this pass.

This is **not** a substitute for the external third-party audit, and **nothing was broadcast to the real chain** — every on-chain step ran against a fork or a local anvil with throwaway keys (zero real funds).

---

## Findings

### IV-1 (Info / positive) — Reward accounting is conservative, never under-reserved
`test/IndependentRewardAccounting.t.sol` (new) re-derives rewards from first principles, independent of the production code. It computes each staker's *naive* `pendingReward` (`balance×globalRewardPaid − balanceTimesPaid`) and compares the sum against `StocksStaking`'s actual global obligation (`notified − claimed`). Across 1, 2 and 8 stakers (deterministic + fuzzed notify/top-up/elapsed sequences) the global obligation is **always ≥ the sum of naive pending rewards** — it over-reserves by 0–8 wei total (≤1 wei per staker, the per-user floor). `claimed ≤ pending` holds for every staker in every scenario; `notified == claimed + poolBalance` and `totalStaked == Σ balances` hold throughout. **Conclusion:** the O(1) global accumulator can never leave a staker short; rounding only ever leaves dust in the pool. A mass-concurrency variant (`test/AdversarialStress.t.sol`, 40 stakers, adversarially interleaved, invariant re-checked after every operation) holds the same invariants at 2,000 fuzz runs — see *High-intensity stress testing*.

### IV-2 (Info) — The reward "griefing" concern is a non-issue
The worry that a donor could split a reward into per-staker amounts so small they round to zero and strand the reward does **not** apply: `StocksStaking` does not divide per user at notify time. It advances one global accumulator and computes each `pendingReward` lazily, so a tiny share is never rounded away at distribution. The only rounding is benign per-user floor dust (≤1 wei/user), a few wei of post-liquidation TWAMM residual, and a burn target that over-shoots by ≤1 wei (conservative). Confirms `AUDIT.md` "Top areas for auditor attention" #3 is conservative, not exploitable.

### IV-3 (Info) — Governance flash-vote is structurally impossible
`test/AuditSweepFlashVote.t.sol` + `test/StocksGovernor.security.t.sol`: "borrow TST → self-delegate → propose + vote in one block → clear quorum → `liquidateTreasury` → drain" cannot execute. OpenZeppelin `Governor._voteSucceeded` requires `voteTimepoint ≥ proposalSnapshot + votingDelay` (≥1), so a same-block vote-and-count reverts `GovernorUnexpectedVoteWeight`; a zero-length period reverts `GovernorUnexpectedStartPeriod`; `quorum()` excludes the burn address. With no timelock (accepted H-1) the only governor-reachable action is `liquidateTreasury`, which **burns** the TST it buys — there is no extraction path. Flash-loan governance capture is impossible without holding TST across the voting delay.

### IV-4 (Info) — Hook fee routing is symmetric, solvent, and charges correctly on mainnet
`test/StocksHook.audit9.t.sol`: buy (`beforeSwap` pre-cut + `afterSwap` post-cut), sell, TWAMM order submission, TWAMM `sync` and a pure stock transfer all charge the same ~10% flywheel (each path within ±0.03%, sums matching); no path dodges the cost. The `beforeSwap` `try/catch` fail-open is unreachable as an attack (a hook address can never also be the pool's stock token). The hook stays 1:1 solvent across every path. **On real Ink mainnet state** the buy-path `beforeSwap` fee is charged correctly: stock gained by the hook = `91,325,032,074,371,561` vs target `91,325,032,074,371,560` (diff 1 wei), and `protocolBalance` rises by exactly the routed fee.

### IV-5 (Test-harness defect — FOUND and FIXED; not a contract bug)
An earlier fork test, `StocksHookAudit9Test::test_FullStockFlywheelRoute_BuyPathChargesBeforeAndAfter`, reported the buy-path fee as "not charged" (`feesNotOnCurve == 0`). Root cause was **in the test, not the protocol**: it mocked the curve as a bare ERC20 and never funded the hook's `protocolBalance`, so `_chargeStockFeeToCurve` had nothing to route (mainnet `protocolBalance` for that pool was genuinely 0). Fix: deploy a real `StocksHookFactory` and deploy/register a real stock through it, so the hook holds genuine `protocolBalance` and the scenario runs on mainnet state with real backing. All 6 rewritten tests pass. **Net:** mainnet fork evidence for the hook is stronger, and the earlier "failure" is explained as a fee-funding harness error — no mainnet defect.

### IV-6 (Infrastructure — FOUND and FIXED) — Fork-suite stalls were an RPC artifact, not contract bugs
The full fork suite intermittently stalled (~17,000 s) and threw spurious `block timestamp is 0` reverts. Diagnosis: the previous `ink` RPC alias (`https://inkonchain-2-rpc.publicnode.com`) drops `block.timestamp` to 0 / stalls under parallel load, and 19 forked files hammering one public endpoint in parallel (Foundry default 4×CPU) starves it. **Not** contract or gas defects — the deterministic zero-fork versions run in milliseconds. Fix: `foundry.toml` `ink` alias → `https://ink.drpc.org`, plus serial execution (`scripts/run-fork-tests.ps1`). Result: the full 19-file fork suite runs **101 passed / 0 failed**.

### IV-7 (Correction) — Real Ink Uniswap v4 PoolManager address
The real Ink PoolManager is **`0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`** (`AUDIT.md` line 41). The tests reference `0x0000000000000000000000000000000000000004` via a deploy-a-mock helper; that address is in the EVM precompile range (`code.length == 0`), so the deploy script's sanity check correctly rejects it. `DeployFactoryV12` requires the real address and deploys cleanly with it.

### IV-8 (Info / hardening) — Permissionless `notifyRewardAmount()` lacks `nonReentrant` (malicious-token-only, bounded)
`test/BusinessLogicAttacks.t.sol` attack 18: unlike `claim`/`unstake`/`redeem`/`liquidateTreasury`, `notifyRewardAmount()` carries **no `nonReentrant` guard**. `redeem()` runs `_shrinkRewardsBy(stockOut + protocolCut)` — which lowers `lastNotifiedBalance` — *before* its two stock transfers (`stockOut` to the redeemer, then `protocolCut` to the protocol). A **malicious stock token** whose `_update` re-enters `notifyRewardAmount()` during the *first* transfer therefore observes `balance > lastNotifiedBalance` by exactly the not-yet-paid `protocolCut` and re-registers it as fresh reward. Measured effect: `totalRewardsAdded` exceeds the stock that entered by **exactly one `protocolCut`** (2% of the redemption gross); the redeemer's own `stockOut` is fixed before the transfers and is **never inflated**; the break is bounded (never a drain). **Reachability:** none in production — the stock token is a trusted protocol token (tokenized equity) and a standard ERC20 has no transfer hook, so `redeem()`'s two transfers complete atomically and conservation holds exactly. **Hardening (optional, defense-in-depth):** add `nonReentrant` to `notifyRewardAmount()` (or make it `onlyGovernor`), or restructure `redeem()` so both transfers are accounted for before any external call. No production contract was changed.


---

## Test evidence (all green)

| Check | Result |
|---|---|
| `SimulationFullLife` — full lifecycle on a real Ink fork (launch → buys → graduation on the real PoolManager → swaps → staking → governor liquidation → claim → in-kind redemption, conservation at every step) | **9 / 9 pass** |
| Fork suite — 19 fork-dependent files, serial, dRPC | **101 / 0** |
| `IndependentRewardAccounting` — deterministic + fuzz | **4 / 0** |
| Non-fork suite | ~510 passing |
| `StocksHook.audit9.t.sol` (real-stack rewrite) | **6 / 6** |

Selected lifecycle numbers from the passing `SimulationFullLife` run (real Ink state): treasury stock earned over 3 weeks of trading `686,616,215,969,986,310`; a staker earned `121,390,830,254,571,428` stock over 7 days; governance liquidation bought back and burned `253,370,282,481,924,236,177,336,245` TST; a full in-kind redemption returned 190 wrapped shares; total TST burned `529,951,396,685,318,491,696,962,670`, with all balances reconciled.

## High-intensity stress testing (this session)

The default suite fuzzes at Foundry's default intensity (256 runs). To probe from many more random directions, the deterministic (non-fork) fuzz and invariant suites were re-run at ≈20× intensity, and a new mass-concurrency adversarial test was authored. **All green — 0 failures.**

| File | Setting | Result |
|---|---|---|
| `IndependentRewardAccounting` | `--fuzz-runs 5000` | 2 / 0 |
| `StocksGovernor.security` | `--fuzz-runs 5000` | 9 / 0 |
| `AuditSweepFlashVote` | `--fuzz-runs 5000` | 11 / 0 |
| `StocksCurve.quoteBounds.fuzz` | `--fuzz-runs 5000` | 3 / 0 |
| `StocksHook.twammDustOrders.fuzz` | `--fuzz-runs 5000` | 1 / 0 |
| `StockStakingGovernableV5.fuzz` | `--fuzz-runs 5000` | 4 / 0 |
| `StocksHook.feeRouting.fuzz` (fork) | `--fuzz-runs 100` | 6 / 0 |
| `StocksSystem.invariant` | `--invariant-depth 30`, 300 runs | 2 / 0 |
| `StockStakingGovernableV5.invariant` | `--invariant-depth 30`, 300 runs | 2 / 0 |
| `StocksAuditR2.curve.invariant` | `--invariant-depth 30`, 300 runs | 1 / 0 |
| **`AdversarialStress` (new)** | `--fuzz-runs 2000` | **1 / 0** |

`test/AdversarialStress.t.sol` (new) closes the **mass-concurrency** gap: it scales the independent reward re-derivation from 4 to **40 stakers** and drives them with a seed-controlled, adversarially-interleaved schedule (stake / notify / partial-unstake / claim / warp) over 60 rounds, re-checking the O(1) obligation invariant (`global ≥ Σ naive pending`, divergence ≤ 1 wei/staker) and solvency (`claimed ≤ notified`) after **every** operation, then a full unwind. It passed at 2,000 fuzz runs (≈85M gas/run).

**Still not covered by an exhaustive campaign** (honest scope): MEV/sandwich tx-sequencing, max-value/overflow boundary sweeps on *every* entry point, oracle-latency races, and non-18-decimal end-to-end stress remain lighter than the reward/governance/curve paths above; the fork-dependent invariant campaigns were run at depth 30 rather than multi-thousand-run counts (RPC-bound). Halmos symbolic proofs remain unusable under the current tooling.

## Business-logic attack testing (red-team, this session)

A targeted red-team pass (`test/BusinessLogicAttacks.t.sol`, new) attempted eighteen concrete economic/design-level exploits against `StocksStaking`. **Seventeen were fully resisted and one (attack 18) is contained to a bounded, malicious-token-only effect — 0 successful attacks in the production threat model.**

| # | Attack | Outcome | Why it fails |
|---|---|---|---|
| 1 | **JIT flash-farm** — flash-mint a dominant stake and `claim()` in the *same block* to siphon reward that accrued to honest stakers | **Resisted** (extracted 0) | `rewardPerTokenStored` does not advance within a block; the attacker's own `_settle` sets `rptPaid = rptStored`, so same-block `pendingReward = 0` |
| 2 | **Notify restart-griefing** — donate 1 wei and `notifyRewardAmount()` to reset `periodFinish` and delay honest distribution | **Resisted** (`periodFinish` unchanged) | the 1% material-inflow ceiling (`reward*100 >= leftover`) tops up dust without restarting the clock |
| 3 | **Dormant-accrual inflation** — leave a pool dormant 1000 days and try to accrue more than was notified | **Resisted** (pending capped at the notified 3000) | accrual is bounded by `min(periodFinish, lastUpdateTime + EXPIRATION_INTERVAL)`; conservation holds |
| 4 | **Unstake bank-run** — drain the reward stock via `unstake()` | **Non-vector** | `unstake()` returns **TST** (line 240), not stock — the reward pool is untouched |
| 5 | **Redemption drain of staker rewards** — mint a full extra supply and `redeem()` max-size to pull the pool dry | **Resisted** (vested 1500 intact; pool retains 2310) | `redeem()` computes `redeemable = balance − earned` **internally** (line 399), excluding stakers' vested rewards; the caller cannot supply or inflate it |
| 6 | **Rounding/dust extraction** — 40 micro stake→claim→unstake cycles to farm rounding dust | **Resisted** (extracted 24,999 wei total) | per-claim rounding is sub-wei; conservation `alice.pending + extracted ≤ notified` holds |
| 7 | **Orphaned-reward capture** — notify while `totalStaked == 0`, first joiner arrives mid-stream | **Resisted** (first joiner got 0) | the pre-join accrual never enters `rewardPerTokenStored` (the `totalStaked == 0` short-circuit), so a later joiner cannot capture it |
| 8 | **Donation-inflated redeemable** — donate stock *without* notify to raise `balance − earned`, then redeem max | **Resisted** (vested 1500 intact) | `earned` is accrual-based (unaffected by raw donations); `redeemable = balance − earned` still excludes vested rewards |
| 9 | **Pause/resume manipulation** — governor pause/resume to short or double-count accrual | **Resisted** (claim ≈ 3000, exact) | pause freezes the clock; resume shifts `periodFinish`/`lastUpdateTime` by the pause duration — no loss, no double-count |
| 10 | **Mid-stream duration front-load** — `setRewardsDuration(1 day)` after a notify to dump the whole reward fast | **Resisted** (pending ≈ 1/30 after 1 day) | `setRewardsDuration` only sets the field; `rewardRate` is recomputed **only** on the next notify, so the active period is unaffected |
| 11 | **Sybil splitting** — split one 1000e18 stake across 20 addresses to multiply reward | **Resisted** (20 sybils total ≈ 3000, exact) | pro-rata accounting conserves the total; splitting cannot mint extra reward |
| 12 | **Huge-notify overflow** — notify 1e30 to force overflow-driven inflation | **Resisted** (pending ≈ 1e30, conserved) | Solidity 0.8 checked math; conservation bounds the claim (a near-`type.max` notify would *revert*, not inflate — and is economically absurd) |
| 13 | **Treasury-liquidation drain** — governor `liquidateTreasury()` commits the balance to a TWAMM sell, trying to drain vested rewards | **Resisted** (vested 1500 fully claimable after) | `stockCommitted = balance − vestedButUnclaimed` (line 320); only *free* stock is committed, vested obligations stay in the pool and `rewardRate` is cut only for the un-accrued remainder |
| 14 | **Malicious-token reentrancy** — hostile stock token re-enters `claim()` from its `_update` transfer hook to double-claim | **Resisted** (re-entry blocked; single fair claim only) | `claim()` is `nonReentrant` *and* zeroes `rewards[account]` before the transfer — the reentrant call reverts (`ReentrancyGuardReentrantCall`), caught by the attacker |
| 15 | **Reentrant permissionless notify** — hostile token re-enters the *unguarded* `notifyRewardAmount()` mid-`claim()` | **Resisted** (provable no-op) | `claim()` drops `lastNotifiedBalance` and the stock balance in lockstep, so `_notifyReward()`'s `currentBalance <= lastNotifiedBalance` guard short-circuits — `rewardRate`/`periodFinish`/`lastNotifiedBalance` all unchanged |
| 16 | **Cross-function reentrancy** — hostile token re-enters `unstake()` (a *different* guarded fn) during `claim()`'s transfer | **Resisted** (re-entry blocked, stake intact) | the single contract-wide `ReentrancyGuard` is not per-function, so `claim`→`unstake` reverts `ReentrancyGuardReentrantCall` |
| 17 | **Fully-vested liquidation** — governor liquidates a treasury whose reward has fully vested | **Resisted** (only ~1e6 wei dust committed) | `stockCommitted = balance − vestedButUnclaimed`; `rewardRate` truncation leaves only sub-million-wei dust free — the vested principal stays claimable |
| 18 | **Reentrant notify mid-`redeem()`** — hostile token re-enters `notifyRewardAmount()` during `redeem()`'s `stockOut` transfer | **Contained** (see IV-8) | `redeem()` cuts `lastNotifiedBalance` by `stockOut+protocolCut` *before* its two transfers, so the re-entry re-registers the not-yet-paid `protocolCut`; the break is **bounded to exactly one `protocolCut`**, the redeemer's output is never inflated, and it is **unreachable with a standard ERC20 stock token** |



Two earlier candidate vectors were investigated and found to be **non-issues by design**: vested rewards remain claimable after the 365-day `EXPIRATION_INTERVAL` (the interval caps *accrual*, not *claims*), and `redeem`'s second parameter is `minStockOut` (slippage), not a caller-controlled `redeemable`. No production contract was changed. **Now covered** (attacks 13–18): `liquidateTreasury` vested-drain, fully-vested liquidation, malicious-token reentrancy on `claim()`, cross-function reentrancy (`claim`→`unstake`), and reentrant `notifyRewardAmount()` during both `claim()` and `redeem()`. **One informational hardening item surfaced** (IV-8): `notifyRewardAmount()` is permissionless and lacks `nonReentrant`, so a *malicious* stock token re-entering it mid-`redeem()` can re-register one `protocolCut` — bounded, and unreachable with the production (standard ERC20) stock token. **Still lighter** (honest scope): the liquidation tests use `MockHookV5`'s fixed exchange rate (real TWAMM pricing/order-matching is fork-proven separately in `StocksLaunchFactory.freshfork.t.sol`).


## Deployment-path rehearsal (anvil fork of Ink mainnet, MAINNET profile)

Run against a local anvil fork (chain 57073) with throwaway keys — nothing broadcast to the real chain:
1. `DeployTokenMetadataRegistry` → deployed.
2. `DeployFactoryV12` (MAINNET profile) → **all six contracts deployed**; the chainid-57073 test-value guard passed (no refusal). Fork-local addresses: factory `0x922D…A1Fe`, hook `0x8211…EAcc`, graduator `0x162A…6890`, plus Governor/Curve/Staking factories.
3. `VerifyDeploymentV12` → **"OK: deployment matches the intended wiring and profile."**

(These addresses are deterministic fork-local artifacts of the rehearsal deployer, not production addresses.)

---

## Accepted risks (re-confirmed, carried from `AUDIT.md`)

Not bugs — design trade-offs to sign off on: single `trustedSigner` centralization (a compromised signer can misprice/mis-time launches; off-chain service, outside this repo) · no governance timelock (H-1; bounded to burn-only actions) · graduation seeds from the live balance (H-2; only a stray donor loses) · Sybil splitting of the per-address anti-snipe cap (inherent) · wrapper-issuer trust · C8 non-18-decimals as an operational-discipline item · TWAMM fail-open bounded by the reserve · the 1% reward-restart ceiling.

## Deferred recommendation (carried)

**EIP-712 attestation domain separation** — the launch price attestation is not a full EIP-712 typed struct (no `chainId`/creator/metadata binding), a griefing/branding risk (a pending attestation can be front-run), **not** theft. Deferred to the next factory generation because it changes the off-chain signer's message format too, and an on-chain/off-chain mismatch would brick every launch.

---

## Artifacts from this pass

- **Created:** `test/IndependentRewardAccounting.t.sol` (independent reward re-derivation), `test/AdversarialStress.t.sol` (40-staker mass-concurrency adversarial stress), `test/BusinessLogicAttacks.t.sol` (5-attack economic red-team), `scripts/run-fork-tests.ps1` (serial fork runner; auto-detects the forked files), `scripts/high-fuzz*.ps1` (high-intensity fuzz/invariant stress runners).
- **Changed:** `foundry.toml` (`ink` RPC → `https://ink.drpc.org`), `test/StocksHook.audit9.t.sol` (real-stack rewrite), `AUDIT.md` (rounds 8–9).
- **Unchanged:** every production `src/` contract.

## Limitations

- This is an **internal independent pass**, not the external third-party audit; the production MAINNET deployment is gated on that audit.
- **Nothing was deployed to the real chain** — all on-chain steps were fork/local with throwaway keys.
- Halmos symbolic proofs do not run under the current tooling (0.3.3 fails in `setUp`); the two curve properties are covered by 200k fuzz runs instead.

## Bottom line

From this independent verification, the production contracts are **audit-clean**: the reward accounting is provably conservative, governance capture is structurally impossible, hook economics are symmetric and solvent on real mainnet state, the full lifecycle works end-to-end, and the production deployment path deploys and verifies correctly. The one defect found was in a test harness and is fixed. Remaining before a real launch: the external audit, then the fresh MAINNET-profile deployment with a funded key.


