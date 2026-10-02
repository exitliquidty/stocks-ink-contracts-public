# Stocks.ink: Smart Contracts (External Audit)

This is a contracts-only export of [Stocks.ink](https://stocks.ink)'s current contract generation, prepared for external audit. It is not the main app repo: the frontend and docs site live elsewhere.

Stocks.ink lets anyone launch a tokenized version of a real-world stock ("TST", Tokenized Stock Treasury), bond it against a signed real-time price attestation, and trade it through a bonding curve that graduates into a live Uniswap V4 pool with on-chain staking and governance over the resulting treasury.

## What to audit

| | |
|---|---|
| Commit | the commit tagged **`audit-freeze-2026-10-02`** on `main` (code frozen at this tag) |
| Contracts | the 12 first-party contracts listed in [`SCOPE.md`](./SCOPE.md), 1,533 nSLOC |
| Chain | Ink (chain ID 57073) |
| Compiler | Solidity 0.8.26 (pinned), `via_ir`, Cancun EVM |

The vendored TWAMM under `src/dex/v4/twamm/vendor/` (891 nSLOC) is third-party code already audited by ABDK Consulting and Certora in January 2025. We consider it out of scope and it stays in the repository because the project will not compile without it; the protocol's own overrides on top of it, in `StocksHook`, are in scope. `SCOPE.md` has the per-file breakdown.

## The system in plain words

1. **Launch.** Anyone can create a token (a TST) tied to a tokenized stock such as a tokenized Tesla share. A trusted signer attests the stock's price at that moment; nothing else about the launch is permissioned.
2. **Bonding curve.** The new token is sold on a curve: people pay in the tokenized stock and get TST, and can sell back at any time. The price rises as more is bought. Nothing is charged on the curve.
3. **Graduation.** Once the curve has collected a set dollar value of stock, anyone can press "graduate". All the collected stock and a matching amount of TST go into a Uniswap v4 pool, and that liquidity is locked forever. Every TST that was not sold or seeded is burned.
4. **The flywheel.** Every trade in the pool is charged 10%. When someone sells TST, the 10% is taken in stock: 8% goes to the token's treasury and 2% to the protocol. When someone buys TST, 2% of the stock paid goes to the protocol and 8% of the TST bought is burned.
5. **Staking.** The treasury streams the stock it receives to people who stake TST.
6. **Redemption.** Any holder can burn TST and take its share of the treasury stock that stakers have not yet earned. This gives the token a floor.
7. **Governance.** TST holders vote. They can do exactly three things: pause or resume staking rewards, change how long rewards take to stream, and sell the unearned treasury stock to buy back and burn TST.

[`BUSINESS-LOGIC.md`](./BUSINESS-LOGIC.md) is the full specification, contract by contract: what every function is supposed to do and why, the invariants that should hold, and the design choices that are intentional. Read it first.

## Repo layout

- `src/`: the 12 first-party contracts plus `src/dex/v4/twamm/vendor/`, a vendored third-party TWAMM. The vendored code is upstream's with only import, `virtual`, and one `calldata`-to-`memory` change.
- `test/`: Foundry test suite: security suites, fuzz tests, invariant campaigns, live-fork tests, and one Halmos symbolic-execution test.
- `script/`: the deploy script for the current factory generation, a read-only post-deploy verifier, the shared metadata registry deploy, and a local mock-token helper.
- `audits/`: all prior review, published in full.
- `BUSINESS-LOGIC.md`, `SCOPE.md`: specification and scope.

## Building and testing

Requires [Foundry](https://getfoundry.sh) (tested with forge 1.8.0) and network access. From a fresh clone:

```
git clone https://github.com/exitliquidty/stocks-ink-contracts-public.git
cd stocks-ink-contracts-public
git submodule update --init --recursive
forge build
forge test
```

No `.env` file and no API key are needed to build or test. `.env.example` is only for the deploy script.

Expected result at the audit tag: **114 suites, 672 tests, 0 failed**. `forge build` reports no compiler warnings in `src/`.

Notes:

- **The first build is slow.** `via_ir` is enabled, so a cold build takes roughly 30 to 60 minutes and several GB of memory. Later runs are incremental.
- `StocksHook.sol` is compiled with `optimizer_runs = 1` (see `compilation_restrictions` in `foundry.toml`) because it sits close to the EIP-170 24,576-byte limit (24,227 bytes at the audit tag).
- About 20 test files run against a live fork of Ink through the `ink` RPC alias in `foundry.toml` (`https://rpc-gel.inkonchain.com`, public, no key), so the suite needs network access. `grep -l createSelectFork test/*.sol` lists them.
- `test/StocksWrappers.realInk.t.sol` samples 48 of the 723 real wrappers by default; set `FULL_WRAPPER_SWEEP=true` for the full sweep (about 25 minutes).
- After the build, a full test run takes about 10 to 20 minutes; the heaviest tests are the stateful campaigns in `test/StocksHook.solvency.t.sol` and `test/StocksSystem.invariant.t.sol` and the gas sweeps in `test/StocksHook.failOpenGas.t.sol`.
- `test/StocksCurve.halmos.t.sol` is written for [Halmos](https://github.com/a16z/halmos), not plain `forge test`.

## Test coverage

Not measured at the audit tag. `forge coverage` builds the whole tree without the optimizer, and with `via_ir` that has exhausted memory on the development machine each time it was tried. It is being run separately and the figure will be sent to the auditors alongside this commit.

What the repository does have is mutation testing, which measures whether the tests can fail and not just whether lines run: 116 single-line mutants across the first-party contracts (106 killed, the 10 survivors each shown equivalent or documented) and 36 more over the vendored TWAMM. See rounds 2, 3 and 6 in [`audits/INTERNAL-AUDIT.md`](./audits/INTERNAL-AUDIT.md).

## Code documentation

Every function, event, error and state variable in the 12 first-party contracts carries NatSpec (96 of 96 functions), and the harder function bodies carry line-level comments. Comment lines to code lines across the first-party contracts: **87%**. The vendored TWAMM is left as upstream wrote it.

## Prior security work

Published in full under [`audits/`](./audits/):

- [`INTERNAL-AUDIT.md`](./audits/INTERNAL-AUDIT.md): 27 rounds of internal review. Mutation testing, a formal proof of the curve's solvency invariant, symbolic execution, invariant campaigns up to 1,000,000 calls, live-fork testing against the real Ink PoolManager and all 723 xStock wrappers, and every finding with its fix and its regression test.
- [`AUDIT_INDEPENDENT_VERIFICATION.md`](./audits/AUDIT_INDEPENDENT_VERIFICATION.md): an independent pass that re-derived the reward accounting from first principles.
- [`NETHERMIND-AUDITAGENT-SCAN.md`](./audits/NETHERMIND-AUDITAGENT-SCAN.md): an external automated scan (22 findings, all verified, 4 real and fixed).

All of it is internal or automated review. None of it is a third-party human audit. The vendored TWAMM's own upstream audits (ABDK, Certora, January 2025) cover the vendored code only.

## Known issues and accepted trade-offs

These are known, deliberate or accepted, and documented with their reasoning in `audits/INTERNAL-AUDIT.md`. They are listed so they are not reported as new.

1. **Trusted price signer.** A single off-chain signer attests the stock price used at launch. It can only affect the launch price of new tokens.
2. **The price attestation is a bearer credential.** It is bound to the factory, stock token, price and timestamp, not to the caller, the name, or the chain id. Whoever submits it first uses it. Nothing of value goes to the caller. (Round 13.)
3. **A stock donation to the curve raises the pool's opening price.** Graduation seeds the stock side from the curve's balance. The donor pays for it and cannot recover it at a profit.
4. **Non-voting supply counts toward quorum.** Staked TST and TST sitting in the pool carry no votes but are part of circulating supply, and the 10% quorum is immutable. Staking has no lock: a staker who wants to vote unstakes and delegates before the proposal's snapshot and can restake straight after it. Heavy staking therefore makes quorum a coordination problem, not a permanent deadlock. (Rounds 20, 22, 27.)
5. **Governance can redirect the unearned reward stream.** Pausing rewards and liquidating the treasury both act on stock stakers have not yet earned. Earned rewards cannot be touched. Stakers do not vote while staked.
6. **Most of the treasury's inflow goes to stakers.** All stock arriving at the treasury is streamed to whoever is staked, so stakers earn far more than their share of supply; redemption draws only on what has not yet vested. (Round 19.)
7. **Treasury liquidation has no price limit.** It is a TWAMM order, executed in whole-interval slices at whatever the pool price is. Its protection is duration (at least 24 intervals and one day). A liquidation whose hourly slice is around 20% of the pool's stock depth or more can be exploited by an opposing order plus a price push before each catch-up. (Rounds 5, 13, 25.)
8. **TWAMM orders are permissionless, uncapped in duration and cannot be cancelled.** A long-lived order makes catch-up cost grow with idle time; `pumpTwammBacklog` clears a backlog in bounded steps. (Rounds 7, 14, 18.)
9. **Sandwiching and MEV** on curve trades and pool swaps are bounded by the caller's own slippage limit, as on any AMM. (Round 15.)
10. **No deadline** on `buy`, `sell` or `redeem`; the slippage bound is the only protection. (Round 23.)
11. **The anti-snipe cap is per address** and can be split across addresses.
12. **Tokens that take a cut on transfer, rebase, or have transfer callbacks are not supported** as the stock token. Graduation fails closed for a cut-on-transfer token. The attested tokens (xStock wrappers) are plain 18-decimal tokens. (Rounds 21, 24, 26.)
13. **The stock issuer can pause its token.** The xStock wrappers are upgradeable and pausable by their issuer; a pause halts every transfer of that stock, here as everywhere. (Round 2.)
14. **Price accumulators and `getReserves` are spot values**, not a manipulation-resistant oracle. Nothing on-chain consumes them.
15. **`claim()` has a brief instant where `redeemableStock()` reads high by the reward in flight**, observable only by a stock token with a pre-transfer callback. (Round 26.)
16. **Uniswap can switch on a v4 protocol fee** (up to 0.1% per direction) for any pool. Behaviour with it on is tested. (Round 25.)

## Deployment status

The generation currently live on Ink is an earlier test-profile deployment and does not contain the changes made since round 2 of the internal review. The mainnet deployment will be made from the audited commit plus any fixes that come out of this audit.

## License

Proprietary, all rights reserved. See [`LICENSE`](./LICENSE). This repository is shared for review only.
