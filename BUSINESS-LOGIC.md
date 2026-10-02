# Stocks.ink: business logic reference

This document is the specification that sits beside the code. `src/` now carries NatSpec on every function, event, error and state variable (added for the external audit; earlier exports had none), and this document is the longer-form companion to it: for every first-party contract, what it is *supposed* to do, in enough detail that you can read a function and check it against the rule here, not just against "does this look reasonable." If you find a place where the code and this document disagree, that disagreement is itself a candidate finding — either the code has a bug, or this document is stale and needs correcting (open an issue either way).

This is a companion to `AUDIT.md`, not a replacement for it. `AUDIT.md` is the audit *trail* — what was found, fixed, and verified, round by round, with dates and test names. This document is the *specification* — what the system is supposed to do, independent of audit history. Read `README.md` first for repo layout and how to build/test; read this document for what the contracts mean; read `AUDIT.md` for what's already been checked.

## 1. What the protocol is

Stocks.ink lets anyone launch a tokenized, tradeable claim on a real-world stock. The token is called a **TST** ("Tokenized Stock Treasury"). The name is deliberate: a Digital Asset Treasury (DAT) is a public company that holds crypto on its balance sheet and trades at a premium or discount to that crypto's value; a TST is the *inverse* — an on-chain token backed by a growing treasury of a real-world stock, accumulated automatically from the token's own trading activity.

The one-sentence version: **every trade in a TST diverts a slice of the underlying stock into an on-chain treasury; stakers earn a stream from that treasury; anyone can permissionlessly redeem TST for a pro-rata share of what the treasury hasn't already promised to stakers; and token holders govern what else the treasury does.**

### 1.1 Life of a token, end to end

1. **Launch.** Someone calls `StocksLaunchFactory.createCurve(...)` with a name, symbol, the address of a real stock token (in practice: an ERC-4626-style tokenized-equity wrapper already live on Ink, e.g. an xStock), and a **signed price attestation** — proof from the protocol's trusted off-chain signer that "this stock token is worth $X as of timestamp T." This deploys a fresh `TSTToken` (1,000,000,000 total supply, all of it minted straight into a fresh `StocksCurve`) and the curve itself.
2. **Curve trading.** Anyone can `buy`/`sell` TST against the curve using the real stock token, via a constant-product bonding curve (see §2.4). 800,000,000 of the 1B supply (80%) is sellable on the curve; the other 200,000,000 (20%) is reserved and never sold here.
3. **Graduation.** Once the curve has collected enough real stock to hit its attested USD threshold (or has sold out), anyone can call `graduate()`. This deploys a governor and a staking/treasury contract for this specific token, seeds a real Uniswap v4 pool (via `StocksGraduator`) at a price matching the curve's own closing price, and burns whatever TST from the 800M curve allocation never sold plus the whole 200M reserved allocation that didn't get used to seed the pool.
4. **Live trading.** From here on, TST trades in a normal Uniswap v4 pool. Every trade that moves stock *into* the pool (a TST→stock sell, or the stock leg of a TST buy) skims a cut for the treasury and the protocol; every trade that moves TST *out* gets partly burned. See §2.6.
5. **Staking and the treasury.** The stock skimmed from trading accumulates in `StocksStaking`, which doubles as both a Synthetix-style reward-streaming contract (for people who stake TST) and the token's on-chain treasury (for people who don't, via redemption).
6. **Redemption.** Anyone, staked or not, can burn TST directly against `StocksStaking.redeem()` for a pro-rata share of whatever stock in the treasury *hasn't already been promised to stakers* — see §5.5 for exactly how that split works. This is a floor: if TST ever trades below what the treasury actually backs it for, buying-and-redeeming is a risk-free arbitrage that pushes the price back up (see §5.6).
7. **Governance.** Each graduated token gets its own `StocksGovernor` (one-token-one-vote, standard OpenZeppelin `Governor`). It can pause/resume the reward stream, change the reward-stream duration, and start a governance-triggered liquidation of the treasury's unearned stock (see §5.4). It has no timelock and no other special powers — see §7.

### 1.2 Actors

- **Launcher**: anyone who calls `createCurve`. No special permission is required beyond having a valid, unused, freshly-signed price attestation.
- **Trusted signer**: an off-chain service, one address per factory generation, that attests to a stock's current USD price. Every launch and every curve's own math trusts this signer completely — see §7.1.
- **Curve traders**: anyone, before graduation.
- **Pool traders**: anyone, after graduation, through the real Uniswap v4 pool.
- **Stakers**: TST holders who lock their tokens in `StocksStaking` to earn a share of the treasury's stock inflow.
- **Redeemers**: anyone who burns TST directly for treasury stock, staked or not.
- **Governor / governance**: TST holders voting through `StocksGovernor`. Staked TST does *not* vote (see §5.1, §7.4) — only unstaked, self-delegated TST does.
- **Protocol**: a single fixed address per factory generation that receives a cut of every trade, every TWAMM order and every redemption.

## 2. `StocksLaunchFactory.sol` + `StocksCurve.sol` + `StocksCurveFactory.sol`

### 2.1 `StocksLaunchFactory` — the one entry point for creating a new token

One instance per "generation" (a generation is a full redeploy of the whole contract stack — see `AUDIT.md`'s deploy history). Immutable at construction: the trusted signer, the protocol address, the hook, the three spawner factories (`governorFactory`, `stakingFactory`, `curveDeployer`), the graduator, the metadata registry, and seven "protocol constants" that every token launched from this generation shares: `graduationUsdThreshold`, `minRewardsDuration`/`maxRewardsDuration` (the allowed range for a curve's staking reward period), `votingDelay`/`votingPeriod` (fixed for every governor this generation spawns), and `proposalThresholdBps`.

**Constructor rules** (all revert if violated, so a misconfigured generation simply never deploys):
- No address parameter may be zero.
- `minRewardsDuration <= maxRewardsDuration`, and `minRewardsDuration >= 1 hour`.
- `votingDelay >= 1 hour`, `votingPeriod >= 1 hour`.
- `graduationUsdThreshold != 0` (a zero threshold would make every launch's `graduationStockTarget` math divide-by-zero-adjacent and never resolve).
- `proposalThresholdBps <= 10,000` (100%) — above that, no proposal could ever meet its own threshold, and (worse) `StocksGovernor`'s own constructor would reject it *after* the curve had already collected real stock from users.

**`createCurve(name, symbol, stockToken, price, priceTimestamp, signature, rewardsDuration, metadataURI)`** — the only state-changing function:
1. `rewardsDuration` must be within `[minRewardsDuration, maxRewardsDuration]`.
2. The attestation — `keccak256(stockToken, price, priceTimestamp)` — must not have been used before (`usedAttestations`). This is a hash of the *message*, not of the signature: two different valid signatures over the same message consume the same replay slot (fixed after an earlier round found the id included the signature bytes — see `AUDIT.md` C7). It is **not bound to the caller**: whoever's transaction lands first consumes it, regardless of who the signer originally attested it for. A front-runner can "steal" a pending attestation and launch with their own name/symbol/metadata; the original submitter's transaction simply reverts (`AttestationAlreadyUsed`) and they request a fresh attestation. This is griefing/branding risk only — nothing is stolen, and it's a documented, accepted design point (see §7.2).
3. Mints a fresh `TSTToken` with the full 1,000,000,000e18 supply, and deploys a `StocksCurve` via `StocksCurveFactory`, which verifies the *same* attestation against the *same* trusted signer independently inside its own constructor (§2.4) — the factory's replay check and the curve's own signature check are two independent layers, not one shared one.
4. Transfers the *entire* TST supply to the new curve (the curve is the sole custodian of unsold TST until it graduates).
5. Records `curveOf[token] = curve` — this is the mapping `StocksGraduator` checks to make sure only a token's *real* curve can call `graduate()` on it (see §4, `NotCurve`).
6. Sets the token's metadata URI once, permanently, via `TokenMetadataRegistry` (§3).

The reward-duration and quorum-numerator "protocol constants" are baked into *every* curve deployed from this factory generation — they cannot vary per-launch, only per-generation.

### 2.2 `StocksCurveFactory` — one-function spawner

`deploy(...)` just does `new StocksCurve(..., msg.sender, ...)`, passing its own caller as the curve's `factory` immutable. It has no access control: anyone can call it directly to deploy a standalone `StocksCurve` that isn't linked to any real `TSTToken` minted through the real factory. This is not a vulnerability — deploying `StocksCurve` directly via `new` would let anyone do exactly the same thing anyway; the factory adds no privilege worth gating.

### 2.3 `TSTToken` — the token itself

Plain OpenZeppelin `ERC20Votes`, minted once at construction (the full requested supply, to the requesting curve) with no further minting function anywhere in the codebase — supply is fixed forever at launch. Overrides `clock()`/`CLOCK_MODE()` to use `Time.timestamp()` (an ERC-6372 real-time clock) instead of the OZ default (block number). This choice is load-bearing: see §5.1 and §7.6 for why a timestamp clock, combined with a `MIN_VOTING_DELAY` floor, makes flash-loan governance takeover structurally impossible.

Votes require explicit self-delegation (`delegate(self)`) — an `ERC20Votes` token never grants voting power automatically just by holding it.

### 2.4 `StocksCurve` — the pre-graduation bonding curve

One instance per launched token. Holds the entire unsold TST supply until graduation.

**Constants:**
- `TOTAL_SUPPLY = 1,000,000,000e18`; `CURVE_SUPPLY = 800,000,000e18` (sellable here); `RESERVED_SUPPLY = 200,000,000e18` (never sold on the curve — seeded into the graduation pool if needed, otherwise burned).
- `VIRTUAL_RESERVE_DIVISOR = 3` — the curve's virtual stock reserve at launch is `graduationStockTarget / 3` (see below).
- `SNIPE_WINDOW = 60 seconds`, `MAX_SNIPE_BUY_BPS = 500` (5%) — an anti-snipe cap on the first minute.
- `SOLDOUT_THRESHOLD_BPS = 9,900` (99%) — the curve can graduate on sell-through alone even if the USD target was never technically reached.
- `FEE_BPS = 1,000` (10%) — the flywheel rate registered with the hook at graduation (see §2.6).
- `PRICE_MAX_AGE = 5 minutes` — how stale a price attestation may be.
- `QUORUM_NUMERATOR = 10` (10%) — every graduated governor's quorum, hardcoded here, not configurable per-launch.

**Constructor rules:**
- No zero addresses.
- `_rewardsDuration` within `[_minRewardsDuration, _maxRewardsDuration]` (the generation's bounds, passed through).
- The stock token, if it advertises a `decimals()` that returns something other than 18, is rejected (`UnsupportedStockDecimals`). This can only catch a token that *successfully* reports a mismatched value — a token with no `decimals()` at all, or one whose call reverts, is left alone (every quote and reserve constant in this contract assumes 18-decimal stock wei; a mismatched real deployment would silently mis-price everything, but this check can't prove a token's *behavior* matches ERC-20, only catch an honest wrong answer — see `AUDIT.md`'s C8/L-2).
- `price != 0`; `priceTimestamp` not in the future and not more than `PRICE_MAX_AGE` old.
- The attestation `keccak256(factory, stockToken, price, priceTimestamp)` must recover, via ECDSA, to exactly `_trustedSigner`. Note this is bound to `factory` (a specific generation) and `_stockToken`, but **not** to `chainId` or to the launch creator — see §7.2 for the residual risk this leaves and why it's accepted, not fixed.
- `graduationStockTarget = graduationUsdThreshold * 1e18 / price` must be nonzero (an absurdly high price would round it to zero — rejected).
- `virtualStockReserve = graduationStockTarget / 3`.

**Pricing — `quoteBuy`/`quoteSell`.** This is a constant-product AMM over a *virtual* reserve, not the classic `x*y=k` two-real-token pool: the "stock" side of the product is `virtualStockReserve + realStockCollected` (real collected stock plus a fixed virtual top-up so the curve has a sensible starting price with zero real stock in it); the "TST" side is `CURVE_SUPPLY - tokensSold` (how much of the 800M is still unsold). Both quote functions round in the curve's own favor (`Math.ceilDiv` on the side being subtracted), so the product `(virtualStockReserve + realStockCollected) * (CURVE_SUPPLY - tokensSold)` can only stay flat or grow across any sequence of buys and sells — proven both algebraically and by fuzzing (`AUDIT.md`). A consequence: buying then immediately selling back the exact TST you received can never return more stock than you put in.

**`buy(stockIn, minTstOut)`:**
- Reverts if already graduated, or `stockIn == 0`.
- Pulls stock via `safeTransferFrom`, then uses the *actual* balance delta (not the requested amount) as `actualStockIn` — this is what makes the curve correctly handle a fee-on-transfer stock token (it just gets less than requested, not more than it can pay out).
- Quotes, checks the result doesn't oversell `CURVE_SUPPLY`, checks it against `minTstOut` (slippage).
- **Snipe cap**: for the first `SNIPE_WINDOW` (60s) after launch, one address's *cumulative* TST across multiple buys in that window is capped at 5% of `CURVE_SUPPLY` (`snipeWindowBought` accumulates — this was specifically hardened against splitting one large buy into many small calls; see `AUDIT.md`). A single Sybil attacker splitting across *many addresses* is not, and cannot be, prevented by a per-address cap — documented, accepted (§7.3).
- Updates `realStockCollected`/`tokensSold`, pays out TST.

**`sell(tstIn, minStockOut)`:** the mirror image — burns down `tokensSold`/`realStockCollected`, pays out stock. Reverts if `tstIn > tokensSold` (can never sell back more than has genuinely been sold).

**`graduate()`:** callable by anyone, once `realStockCollected >= graduationStockTarget` **or** `tokensSold >= 99%` of `CURVE_SUPPLY`. Delegates to `_graduate()`:
1. Deploys a governor (via `StocksGovernorFactory`) named `"<TST name> Governor"`, wired to this token's own votes, with the *generation's* voting delay/period/threshold and this curve's hardcoded 10% quorum.
2. Deploys a staking/treasury contract (via `StocksStakingFactory`) wired to this TST/stock pair, this curve's `rewardsDuration`, the new governor, and the shared hook.
3. Computes a **price-matched seed**: `priceMatchedSeed = realStockCollected * (CURVE_SUPPLY - tokensSold) / (virtualStockReserve + realStockCollected)` — the amount of TST that, paired with all the stock the curve collected, opens the new Uniswap pool at *exactly the curve's own closing price* (no dislocation between curve-close and pool-open). If that's below `StocksGraduator.MIN_TST_SEED_SUPPLY_BPS` (1% of total supply), the minimum wins instead — a floor against a curve graduating with a comically thin pool.
4. Burns whatever TST is left over after the seed (this is the RESERVED_SUPPLY's fate if the price-matched seed doesn't need all of it, plus any unsold curve TST above what's needed).
5. Approves and calls `StocksGraduator.graduate(...)` with the full stock balance and the computed TST seed.
6. Wires the new staking contract's `poolKey` from the graduator's return value, and records `pair`/`staking`/`governor`.

**`skim()`:** callable by anyone, pre-graduation only. Burns any TST sitting in the curve *above* what accounting says should be there (`TOTAL_SUPPLY - tokensSold`) — i.e., dust from a fee-on-transfer or rebasing TST-side anomaly (TST itself is a plain fixed-supply token, so this is mostly a defensive no-op in practice, but costs nothing to have).

## 3. `TokenMetadataRegistry.sol`

A tiny, shared, generation-independent contract (deployed once, reused by every factory generation). `setMetadataURI(token, uri)` is callable by *anyone*, but only once per token address (`metadataDecided`), and only if `token` already has code (`TokenHasNoCode` — this specifically defeats a front-runner trying to squat a *predicted* token address before the real launch transaction lands: the registry can't be written to until the token genuinely exists). An empty string is a valid, final choice — "no metadata" is itself a permanent decision, not a placeholder.

## 4. `StocksGraduator.sol`

Not a factory in the usual sense — one shared instance handles *every* token's graduation for a generation. Its whole job is: take a TST/stock pair and turn it into a live, correctly-priced, permanently-locked-liquidity Uniswap v4 pool.

**Constants:** `TICK_SPACING = 60`; `MIN_TST_SEED_SUPPLY_BPS = 100` (1% of total TST supply, the graduation seed floor mentioned above); `HOOK_TST_RESERVE_WEI = 1e20`, `HOOK_STOCK_RESERVE_WEI = 1e12` — a small buffer handed to the hook at every graduation specifically to cover the vendored TWAMM's own rounding shortfall at order-execution boundaries (see `AUDIT.md` F-1; this is what makes swaps fail *open* rather than freezing the whole pool when that shortfall happens).

**`graduate(tstToken, stockToken, treasury, protocol, feeBps, tstAmount, stockAmount)`:**
- Callable *only* by `curveOf(tstToken)` on the launch factory this graduator is bound to (`NotCurve` otherwise) — this is the fix for an earlier, separately-audited "graduation hijack" bug (H-3 in the audit history): nothing but the real, factory-registered curve for that exact token can graduate it.
- Requires both amounts nonzero and both *strictly greater* than their respective hook reserve constants (`SeedTooSmall` otherwise — a seed at or below the reserve amount would leave the pool with zero real liquidity after the reserve is skimmed off).
- Requires `tstAmount` to be at least 1% of the TST token's total supply (the same floor `StocksCurve._graduate()` already enforces before calling here — belt and suspenders).
- Pulls both tokens, orders currencies canonically (`tstIsCurrency0 = tstToken < stockToken`, standard Uniswap ordering), builds the `PoolKey` with `fee: 0` (static; the *actual* trading cost is entirely the hook's own flywheel, not a native Uniswap fee) and this hook as the pool's hook address.
- Registers the pool with the hook (`hook.registerPool`, §5's fee-routing setup), skims the two hook reserves off to the hook directly, computes a `sqrtPriceX96` from the *remaining* pool amounts (so the reserve skim doesn't skew the opening price), and initializes the pool at that price.
- Mints a single, **full-range** liquidity position (`TickMath.minUsableTick` to `maxUsableTick` for `TICK_SPACING = 60`) via `poolManager.unlock` → `unlockCallback` → `modifyLiquidity`. This position is never removed by any first-party contract — it's the pool's permanent floor depth. (Nothing on-chain *prevents* a third party from also adding their own liquidity to the same pool; see `AUDIT.md`'s L-1 for what protects a liquidity action against a failing TWAMM catch-up either way.)
- Deploys a `StocksPoolView` (a tiny, permanent, read-only convenience wrapper around this specific pool — §6) and burns/routes any dust left over (excess TST to the burn address, excess stock to the treasury).

## 5. `StocksHook.sol` (+ vendored `TWAMM.sol`)

This is the busiest contract in the system: a Uniswap v4 hook that is *also* a full TWAMM (time-weighted average market maker) engine. The TWAMM machinery (`src/dex/v4/twamm/vendor/`) is a licensed third-party dependency ("Derived from akshatmittal/v4-twamm-hook, used with the author's permission. Do not redistribute.") with only import-path, two `virtual` keywords, and one `calldata`→`memory` change from upstream (`AUDIT.md` §5 has the full diff verification) — treat its accounting math as someone else's audited code, and treat `StocksHook`'s own overrides as the part that's genuinely first-party and needs the closest reading.

### 5.1 What the hook is for

Every launched, graduated token shares the *same* hook contract (one hook per factory generation, referenced by every pool's `PoolKey.hooks`). It does three independent jobs:
1. **The flywheel**: taxes trades and TWAMM order proceeds, splitting the tax between burning TST and funding each token's own treasury/protocol.
2. **TWAMM order execution**: the generic, permissionless engine for time-sliced orders (used by governance liquidations, §5.4, and directly usable by anyone else too — see §7.5).
3. **A price accumulator** (`price0CumulativeLast`/`price1CumulativeLast`): a plain, swap-triggered spot-price accumulator, explicitly *not* a robust TWAP oracle (documented, §7.7) — nothing in this codebase relies on it for anything security-sensitive.

### 5.2 Registration and initialization

`registerPool(key, tstToken, stockToken, treasury, protocol, feeBps)` — callable only by `poolDeployer` (the graduator, set immutably at construction). Validates the pair isn't already registered, no zero addresses, the two tokens aren't identical, `feeBps <= MAX_FEE_BPS` (2,000 = 20% absolute ceiling — the curve/graduator always register at 1,000 = 10%, but the hook itself would accept up to 20% from a different caller shape), the key's `hooks` field really is this contract, and that the key's two currencies really are exactly `{tstToken, stockToken}` in some order. Records a `LaunchInfo` struct (which side is TST, both token addresses, treasury, protocol, feeBps) keyed by `PoolId`.

`beforeInitialize` is only callable by the PoolManager, only for a pool whose `sender` is `poolDeployer` and whose pool was already `registerPool`'d, and rejects native-currency pools (no ETH-paired pools here) — then initializes the TWAMM state for this pool.

### 5.3 The flywheel (fee mechanics)

`PROTOCOL_FEE_SHARE_BPS = 2,000` (20% of *whatever cut is being taken*, not 20% of the trade) is the fixed split between "protocol" and "treasury" wherever a cut is divided between them.

Four cost paths, all charging the *same* effective 10% (at the curve/graduator's standard `feeBps = 1,000`), split so the protocol always gets 2% of the trade and the treasury/burn gets 8%:

| Direction | Where the cut is taken | Split |
|---|---|---|
| Buy TST with stock, direct swap | `beforeSwap`: 2% of the stock *input*, taken pre-swap via `_takeExact` | 100% protocol |
| (same swap, continued) | `afterSwap`: 8% of the TST *output* | 100% burned |
| Sell TST for stock, direct swap | `afterSwap`: 10% of the stock *output* | 2% protocol / 8% treasury (`_routeStockFee`) |
| Submit a stock-selling TWAMM order | `_chargeOrderInputFeeAndReduce`, at submission: 2% of `amountIn` | 100% protocol, and the order itself is only ever sized at the *reduced* amount |
| That order's proceeds, at `sync` | 8% of what it bought (TST) | 100% burned |
| Submit a TST-selling TWAMM order / that order's proceeds | 10% of the stock proceeds at `sync` | 2% protocol / 8% treasury |

The reasoning for the *asymmetry* (protocol-only on the stock-input leg, split on the stock-output leg) is that the stock-input leg is charged *before* the swap even happens (as a hook-returned delta, not a real balance check), so it's simpler to route it as a single transfer; the output-leg cut is charged from real settled balances afterward and naturally splits.

When the treasury's stock cut lands (`_routeStockFee`), the hook also fires a **best-effort** `notifyRewardAmount()` ping at the treasury contract via a raw `.call(...)` with the return value deliberately ignored — if the treasury contract reverts or doesn't exist for some reason, the swap must still succeed; the next real interaction with the treasury will pick up the balance anyway (`StocksStaking._notifyReward` recomputes from its own current balance every time, not from the ping).

### 5.4 TWAMM order execution and the interval-boundary defect

`submitOrder`/`batchSubmitOrders` are **permissionless** — any address can submit a TWAMM order against any registered (or unregistered) pool through this hook, not just `StocksStaking`. `StocksStaking.liquidateTreasury` (§5's staking chapter, §5.4 below) is simply the *one first-party caller* of this in the whole system.

**The interval-boundary timing defect (fixed at the `StocksStaking` layer, not here — see `AUDIT.md` round 5).** The vendored TWAMM rounds a new order's virtual start down to the *beginning* of the current `expirationInterval`, not to the real submission moment. An order submitted moments before an interval boundary can therefore have almost its entire committed amount sold within the first real second after that boundary, instead of gradually — up to roughly one interval's *share* of the order, regardless of its total length. This is real, vendor-level behavior, not something `StocksHook` introduced or can cheaply fix at this layer (the fix that exists — `StocksStaking.MIN_LIQUIDATION_DURATION` — only protects the one caller this codebase controls; a user calling `submitOrder` directly still gets the raw behavior; see §7.5 for why that's accepted as-is).

### 5.5 `getReserves` / the price accumulator

Purely a *derived* view computed from the pool's current `sqrtPriceX96` and `liquidity` (via `StateLibrary`) — not separately tracked balances. `_updateAccumulator` runs on every `afterSwap`, integrating the *previous* block's reserves over the elapsed time into the two cumulative-price mappings, Uniswap-v2-style. As stated in §5.1: this is informational only, not consulted by any pricing/redemption logic in this codebase.

## 6. `StocksPoolView.sol`

A tiny, immutable, per-pool convenience contract deployed once by the graduator at graduation. Holds no funds and has no state-changing functions — it exists purely so a frontend/indexer can read `token0()`, `token1()`, `poolKey()`, `treasury()`, `feeBps()`, `getReserves()` and the two price accumulators for one specific pool without needing to know its `PoolId` or query the hook's mappings directly.

## 7. `StocksStaking.sol` (+ `StocksStakingFactory.sol`)

This is simultaneously: (a) a Synthetix-style reward-streaming staking contract, and (b) the token's entire on-chain treasury and redemption mechanism. One instance per graduated token, deployed by `StocksStakingFactory` at graduation, immutably wired to that token's TST, stock, governor, hook, and curve.

### 5.1 Constructor and constants

- No zero addresses; `_rewardsDuration >= MIN_REWARDS_DURATION` (1 hour) — the *initial* duration, set once at construction from the curve's own `rewardsDuration`.
- `MIN_GOVERNABLE_REWARDS_DURATION = 1 day`, `MAX_GOVERNABLE_REWARDS_DURATION = 365 days` — the range governance can later move `rewardsDuration` into via `setRewardsDuration` (must also be an exact multiple of 1 day).
- `MAX_LIQUIDATION_DURATION = 30 days`, `MIN_LIQUIDATION_DURATION = 1 day` — the allowed range for a governance-triggered treasury liquidation's TWAMM order (§5.4; the minimum exists specifically to bound the interval-boundary defect described in §5.4 to a small, predictable fraction of the order instead of nearly all of it).

`setPool(key)` — callable *only* by `curve` (the launching curve, set immutably), and *only once* (`PoolAlreadySet` on a second call). This is how the staking contract learns which real Uniswap pool is "its" pool and which side of it is stock vs. TST.

### 5.2 The reward stream (Synthetix pattern, adapted)

Standard accumulator-based streaming: `rewardPerTokenStored` tracks cumulative reward-per-staked-TST; every `stake`/`unstake`/`claim`/`liquidateTreasury`/`redeem` call first runs `_notifyReward()` (roll the accumulator forward to now) and `_settle(account)` (freeze that account's own pending reward before their balance changes). A few deliberate departures from the textbook version, all load-bearing:

- **`notifyRewardAmount()` is permissionless and idempotent.** It doesn't take an amount parameter — it just compares the contract's *current* stock balance against `lastNotifiedBalance` and treats any positive difference as new reward. This means the hook's best-effort ping (§5.3) is purely an optimization; anyone calling this function costs nothing but a small amount of accumulator-rounding dust (bounded, tested — `AUDIT.md`'s reward-griefing analysis: at most `calls * totalStaked / 1e18` wei lost across any number of calls).
- **The 1%-restart rule** (`MATERIAL_INFLOW_DIVISOR = 100`): if a new inflow is at least 1% of what's still left to stream (`reward * 100 >= leftover`), the *whole* remaining balance plus the new inflow gets re-spread over a fresh period, restarting it. The fresh period runs for the LONGER of `rewardsDuration` and the time that was still left (round 24): a restart may stretch what is already streaming but never compress it, which matters once governance has lowered `rewardsDuration` below the time left on the running period. A smaller inflow just nudges the existing `rewardRate` up without resetting the clock. This is the fix for an earlier "late reward sniping" bug (F-2 in `AUDIT.md`) where a large staker joining right after a big inflow could claim almost all of it; the trade-off, stated plainly there, is that steady frequent small inflows now vest more slowly (spread across a rolling window) than a naive model would suggest.
- **`_shrinkRewardsBy`** is the function that makes `redeem()` and `liquidateTreasury()` safe to take stock *out* of the contract without corrupting the reward math: it carefully attributes the outflow first to stock that was never "registered" as a reward inflow at all, then to registered-but-not-yet-streamed stock, before ever touching `rewardRate` itself — so an outflow can never silently reduce what's *already been earned* by a staker.
- **Pause is a clock-freeze, not a balance freeze.** `setRewardsPaused(true)` snapshots `pausedAt = lastUpdateTime` and every subsequent read (`_rewardClockNow()`) substitutes `pausedAt` for `block.timestamp` — the accumulator simply stops advancing. `setRewardsPaused(false)` shifts `periodFinish`/`lastUpdateTime` forward by exactly the paused duration, so a paused stream resumes exactly where it left off, losing no time and minting no extra rewards. Staking, unstaking, claiming and redeeming all keep working normally while paused — pausing only stops *new* accrual, it never traps existing funds (tested explicitly, `AUDIT.md`).

### 5.3 `stake` / `unstake` / `claim`

Standard: pull/push TST, settle rewards first, update `totalStaked`/`balanceOf`. `unstake` requires the caller to actually hold at least `amount`. `claim` zeroes the caller's `rewards[msg.sender]`, decrements the accounting mirrors (`frozenRewardsTotal`, `lastNotifiedBalance`), and pays out stock. **Staked TST carries no voting power** — `TSTToken` never delegates on a user's behalf, and staking doesn't move TST anywhere that changes that; a staker who wants to vote must keep (or separately hold) unstaked, self-delegated TST. This is a deliberate design choice (documented in `AUDIT.md` as design note M-4/C4), not an oversight: governance liveness depends on the *unstaked* share of supply.

### 5.4 `liquidateTreasury(durationIntervals)` — governance-triggered treasury sale

`onlyGovernor`. What it does: takes everything in the treasury's stock balance that stakers *haven't already earned* (`balance - vestedButUnclaimed`), and sells it gradually for TST via a TWAMM order submitted to the hook, over `durationIntervals * hook.expirationInterval()` seconds. The bought TST is burned as the order fills (`claimLiquidatedTst`, callable by anyone, any time, even mid-order for a partial fill).

Rules, precisely:
- `!_poolSet` → revert. `durationIntervals == 0` → revert.
- A second call is refused (`LiquidationInProgress`) while a previous order's `pendingLiquidationExpiration` hasn't passed yet — there can only ever be one liquidation order outstanding at a time.
- If a *previous, already-expired* order was never claimed, this call auto-claims (and burns) it first, so a forgotten claim can never strand real, already-sold proceeds.
- The committed amount is capped by the "vested but unclaimed" floor — a liquidation can never touch stock stakers have already earned, only what's still scheduled to stream or genuinely unallocated.
- `NothingToLiquidate` if that floor consumes the entire balance.
- `durationIntervals` must convert (via the pool's own `expirationInterval`) to a duration between `MIN_LIQUIDATION_DURATION` (1 day) and `MAX_LIQUIDATION_DURATION` (30 days) — see §5.1 and §5.4's TWAMM note for why both bounds exist. The maximum exists because a TWAMM order can never be cancelled once started, so an absurdly long duration would otherwise lock the whole committed amount away for years with no recourse (`AUDIT.md` C1). The minimum exists because too *short* an order is vulnerable to the interval-boundary front-loading defect (§5's hook chapter).
- If a genuine reward stream was still running when the liquidation starts, `rewardRate` is reduced proportionally (the committed stock is coming *out* of what was still scheduled to stream, so the remaining rate has to shrink to match what's actually left).

Governance cannot choose *who* the liquidated stock goes to — there is no recipient parameter anywhere in this function; the stock only ever moves into the hook's own TWAMM order, and eventually into TST that gets burned. The only three `onlyGovernor` functions on this whole contract are `setRewardsPaused`, `setRewardsDuration`, and this one — none of them move funds to an address the proposal itself picks.

### 5.5 `redeem(tstAmount, minStockOut)` — the treasury floor, open to everyone

Burns `tstAmount` TST (sent straight to the dead-address burn) for a pro-rata share of `redeemableStock()` = `stockToken.balanceOf(this) - _earnedByStakers()` — i.e., exactly the same "unearned" pool `liquidateTreasury` draws from, scaled by `tstAmount / nonBurnedSupply()`.

The payout isn't 1:1 with the pro-rata share — `_redemptionAmounts` applies the *same* `feeBps`/`PROTOCOL_FEE_SHARE_BPS` cost structure as a normal trade (read live from the hook's own `launches` mapping for this pool, so it always matches whatever the pool is actually configured with): of the gross pro-rata amount, a cost (`feeBps`, ceiling-rounded up, capped so it never exceeds the gross) is deducted, split between the protocol (`protocolBps` of the gross) and *retained in the treasury* (the rest of the cost) — so a redemption never fully drains its own pro-rata share out of the treasury; part of it stays behind for everyone else. `NothingToRedeem` if the computed payout rounds to zero; `RedeemExceedsSupply` if `tstAmount` is somehow larger than the whole non-burned supply (can't happen honestly, but guarded).

`_shrinkRewardsBy` runs here too, exactly as in liquidation — a redemption can never eat into stakers' already-earned rewards.

**Order of the transfers (round 26).** The stock is paid out first (to the redeemer, then the protocol's share) and the TST is burned last. The published rate is treasury over circulating supply and its views are not reentrancy-guarded, so the order decides which way the rate is wrong for the instant between transfers: paying out first makes it read at or below the true rate, never above. The burn is in the same transaction and reverts the payout if it fails.

**Why this is a genuine price floor.** `redeemableStock() / nonBurnedSupply()` is a *rate* — stock per TST — computed purely from the treasury's own balance and the token's own supply, with **no dependency on the Uniswap pool's price at all** (no oracle, no TWAP, nothing spot-price-based). If the pool ever trades TST below that rate, buying TST on the pool and immediately redeeming it is a strictly profitable arbitrage (net of the pool's own 10% swap cost and the redemption's own cost) that consumes cheap TST and pushes the pool price back up — and critically, doing so **costs nobody else anything**: it doesn't move other holders' claim on the treasury, doesn't touch stakers' earned rewards, and the rate for remaining holders never falls as a result (proven directly in `AUDIT.md`'s adversarial suite). A flash-loan attempt to borrow TST from the pool itself and redeem it in the same transaction fails on its own economics whenever the rate is genuinely below the pool price (the stock you'd get back can't buy back what you borrowed) — not because of any explicit anti-flash-loan guard, just because the arbitrage direction only works one way.

## 8. `StocksStakingFactory.sol`

One-function spawner, identical shape to `StocksCurveFactory`: `deploy(tstToken, stockToken, rewardsDuration, governor, hook)` does `new StocksStaking(..., msg.sender)`, passing itself... actually passing its *caller* (the curve) as the `_curve` immutable, which is what later lets only that specific curve call `setPool` on the result. No access control on `deploy` itself, same reasoning as §2.2: deploying `StocksStaking` directly via `new` is already unrestricted, so gating the factory adds nothing.

## 9. `StocksGovernor.sol` (+ `StocksGovernorFactory.sol`)

One governor per graduated token. A thin, deliberately-locked-down wrapper around OpenZeppelin's standard `Governor` + `GovernorSettings` + `GovernorCountingSimple` + `GovernorVotes` + `GovernorVotesQuorumFraction` stack — one token, one vote, simple for/against/abstain counting, no timelock (a passed proposal executes immediately on `execute()`, callable by *anyone*, not just the proposer).

**What's locked at construction and can never change:** `votingDelay`, `votingPeriod`, and the quorum numerator (`updateQuorumNumerator` is overridden to unconditionally revert `VotingSettingsAreImmutable`, same as the two setters) — closing a self-escalation path where a single ordinary-looking proposal could otherwise lower its own quorum toward zero and then have a small holder pass anything (documented history: F-3 in `AUDIT.md`, "the same self-escalation V9 closed for the voting window"). Floors, enforced only at construction (nothing stops a later proposal from trying to call the dead setters, they just always revert): `votingDelay >= 1 hour`, `votingPeriod >= 1 hour`, `quorumNumerator >= 1`.

**`proposalThreshold()`** is computed *live* from `proposalThresholdBps` (immutable, set at construction, 0-10,000) against the token's *current* circulating supply (`totalSupply - burned`) — not a fixed number frozen at deploy time, so it naturally shrinks as more TST gets burned over the token's life. `setProposalThreshold` (inherited from `GovernorSettings`) is deliberately left *reachable* but *inert*: it can be called and will store a value, but `proposalThreshold()` never reads it — reviewed and accepted as harmless in `AUDIT.md`.

**`quorum(timepoint)`** is the one place with real custom logic: it needs "circulating supply at that past timepoint," which requires knowing how much was burned *as of that timepoint* — but `IERC20.balanceOf` only ever returns the *current* burn balance. The fix: `_castVote()` is overridden to record the burn-address balance the *first* time any vote is cast against a given snapshot timepoint (`_burnSnapshotRecorded`), and `quorum()` reads that recorded value if one exists, falling back to the live burn balance until then. Voting is only possible once a proposal is active, so the value is always recorded at or after the snapshot (round 24; it used to be recorded at proposal creation, a whole voting delay too early, which set quorum slightly too high). Burning tokens *after* the first vote can therefore never move that vote's quorum requirement, and the first vote on a given timepoint fixes the figure for every proposal that shares it, which is intentional (the alternative — always re-reading the live burn balance — is exactly the bug this closes).

`StocksGovernorFactory` is the fourth one-function spawner, no access control, same reasoning as §2.2/§8.

## 10. Cross-cutting invariants worth checking directly against the code

These are properties that span more than one contract — the kind of thing a bug could violate without any single function "looking wrong" in isolation.

- **TST conservation.** At every point in a token's life, `totalSupply()` equals the sum of: TST still in the curve (pre-graduation) or burned (dead address) or held/staked by users or sitting in the hook's small graduation reserve or in flight inside an active TWAMM order. Nothing should ever be unaccounted for.
- **Stock solvency.** `StocksStaking`'s own stock balance must always be `>= _earnedByStakers()` — the contract can never promise more to stakers than it actually holds. Every function that can reduce the balance (`claim`, `liquidateTreasury`, `redeem`) is structured specifically to preserve this (§5.5's `_shrinkRewardsBy`).
- **The constant product on `StocksCurve` never decreases** across any sequence of buys/sells (§2.4).
- **No path exists for the protocol/treasury/governance to redirect funds to an address a caller freely chooses.** Every function that moves stock or TST out of a contract either pays `msg.sender` directly (stake/unstake/claim/redeem), pays a fixed, immutable, non-parameterized address (protocol/treasury/burn), or moves it into the hook's own TWAMM order accounting (liquidation) — never an arbitrary parameter.
- **Redemption's rate is independent of the Uniswap pool's price** (§5.5) — no function anywhere reads `getReserves()`, `getSlot0`, or the price accumulators to compute a redemption or liquidation amount.
- **A staker's already-earned, not-yet-claimed reward is untouchable by anything except that staker's own `claim()`** — not by `redeem`, not by `liquidateTreasury`, not by pausing.

## 11. Documented design choices — not bugs, don't re-report

- **§7.1 Signer centralization.** One `trustedSigner` per generation, no rotation without a full redeploy. A compromised key can attest a false price for a new launch (mispricing that one token) but cannot touch already-graduated tokens' treasuries, redemption math, or governance.
- **§7.2 Attestation not bound to a creator or a chain.** See §2.1 point 2. Griefing/branding risk only.
- **§7.3 Sybil-splittable snipe cap.** The 5% cap is per-*address*; coordinated addresses can still collectively acquire more in the snipe window. No per-address cap can prevent this.
- **§7.4 Staked TST doesn't vote.** See §5.3.
- **§7.5 Permissionless, unprotected user TWAMM orders.** See §5.4's timing note. The frontend never exposes a path to call `submitOrder` directly (confirmed by search, `AUDIT.md` round 7); the only realistic caller of the raw function is a technically sophisticated user harming only themselves.
- **§7.6 No timelock on governance.** A passed proposal executes the instant anyone calls `execute()`. Combined with §2.3's real-time clock and the 1-hour `MIN_VOTING_DELAY` floor, this is also what makes flash-loan vote acquisition structurally impossible — the snapshot a vote counts against is always already in the past relative to when a same-block flash loan's balance change would occur.
- **§7.7 Price accumulators are a plain spot accumulator, not a TWAP oracle.** Nothing in this codebase treats it as one.
- **§7.8 Real stock tokens are external, upgradeable, pausable wrappers.** If the underlying wrapper's issuer pauses or upgrades it, every function touching that stock token (buys, sells, staking claims, redemptions) can revert until it's unpaused. A trust assumption on the wrapper issuer, not something this codebase can control.

---

*If you're auditing this repo: start with §10 above as your checklist, then read each contract's chapter against the actual source side by side. If a rule stated here doesn't match what the code does, that mismatch is the finding — report it either as a code bug (if the code is wrong) or flag this document for correction (if the code is right and this description is stale).*
