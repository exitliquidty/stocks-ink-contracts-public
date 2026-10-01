# Stocks.ink: Smart Contracts (External Audit)

This is a contracts-only export of [Stocks.ink](https://stocks.ink)'s current contract generation, prepared for external audit. It is not the main app repo — the frontend, docs site, and internal audit/finding history live elsewhere and are not part of this export.

Stocks.ink lets anyone launch a tokenized version of a real-world stock ("TST", Tokenized Stock Treasury), bond it against a signed real-time price attestation, and trade it through a bonding curve that graduates into a live Uniswap V4 pool with on-chain staking and governance over the resulting treasury.

## Audit scope

**[`SCOPE.md`](./SCOPE.md) defines exactly what we are asking to be audited**, so that proposals from different firms are directly comparable. In short: the **12 first-party contracts, 1,531 nSLOC**. The vendored TWAMM under `src/dex/v4/twamm/vendor/` (891 nSLOC, 37% of the tree) is third-party code already audited by ABDK Consulting and Certora in January 2025, and is **out of scope** — it stays in the repository only because the project will not compile without it. The protocol's own overrides on top of it, in `StocksHook`, are in scope.

Please quote against `SCOPE.md`.

## Prior security work

Published in full under [`audits/`](./audits/) — 23 rounds of internal review, an independent verification pass, and an external automated scan by Nethermind's AuditAgent (22 findings, all verified, 4 real and fixed). It is internal and automated review, **not** a third-party human audit, which is still pending. It is public so reviewers can see what is already covered and so the design trade-offs we have deliberately accepted are stated up front rather than reported as findings.

## Start here

Read [`BUSINESS-LOGIC.md`](./BUSINESS-LOGIC.md) first: a full business-logic specification, contract by contract, written against the code with no inline comments. It describes what every function is supposed to do and why, the invariants that should hold across contracts, and a list of design choices that are intentional, not bugs — so you can diff the actual code against a stated rule instead of guessing intent from scratch.

## License

Proprietary, all rights reserved. See [`LICENSE`](./LICENSE). This repository is shared for review only.

## Repo layout

- `src/`: 12 core contracts plus `src/dex/v4/twamm/vendor/`, a vendored third-party TWAMM implementation. It is upstream's code with only import, `virtual`, and one `calldata`-to-`memory` change; the protocol's own logic on top of it lives in `StocksHook`, which the original upstream audits do not cover.
- `test/`: Foundry test suite — security suites, fuzz tests, invariant tests, live-fork tests, and one Halmos symbolic-execution test.
- `script/`: the deploy script for the current factory generation, a read-only post-deploy verifier, the shared metadata registry, and a local mock-token deploy helper.

## Building and testing

```
git submodule update --init --recursive
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). Notes:

- `StocksHook.sol` is compiled with `optimizer_runs = 1` (see `additional_compiler_profiles` in `foundry.toml`) because it sits right at the EIP-170 24,576-byte size limit.
- A few tests run against a live fork of Ink through the `ink` RPC alias in `foundry.toml` (`https://rpc-gel.inkonchain.com`), so they need network access: `test/RealXStockWrapper.dividendrate.t.sol`, the graduation test in `test/StocksGraduator.audit4.t.sol`, and the real-PoolManager runs at the end of `test/StocksHook.twammRounding.regression.t.sol`.
- `test/StocksWrappers.realInk.t.sol` samples 48 of the 723 real wrappers by default; set `FULL_WRAPPER_SWEEP=true` for the full sweep (about 25 minutes).
- A full run takes several minutes; the heaviest tests are the stateful stress in `test/StocksHook.solvency.t.sol` and `test/StocksSystem.invariant.t.sol` and the gas sweeps in `test/StocksHook.failOpenGas.t.sol`.
- `test/StocksCurve.halmos.t.sol` is written for [Halmos](https://github.com/a16z/halmos), not plain `forge test`.
