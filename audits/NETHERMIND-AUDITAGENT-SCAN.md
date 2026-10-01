# AuditAgent report - Scan ID `7e433a04-f0fd-45a7-99c0-97026a5d7707`

## Scan details

| Key | Value |
|---|---|
| Repository | exitliquidty/stocks-ink-contracts-public |
| Branch | `main` |
| Commit | `f5d066e5...d3d950a5` |
| Scan ID | `7e433a04-f0fd-45a7-99c0-97026a5d7707` |
| Scan type | Auditor Scan |
| Date | September 30, 2026 |
| Lines of code | 3,208 |
| Contracts in scope | 18 |
| Vulnerabilities found | 22 |
| Audit score | 88 |

## Contracts in scope

- `src/StocksLaunchFactory.sol`
- `src/StocksStaking.sol`
- `src/StocksStakingFactory.sol`
- `src/TSTToken.sol`
- `src/TokenMetadataRegistry.sol`
- `src/curve/StocksCurve.sol`
- `src/curve/StocksCurveFactory.sol`
- `src/dex/v4/StocksGraduator.sol`
- `src/dex/v4/StocksHook.sol`
- `src/dex/v4/StocksPoolView.sol`
- `src/dex/v4/twamm/vendor/ITWAMM.sol`
- `src/dex/v4/twamm/vendor/TWAMM.sol`
- `src/dex/v4/twamm/vendor/TwammBaseHook.sol`
- `src/dex/v4/twamm/vendor/libraries/OrderPool.sol`
- `src/dex/v4/twamm/vendor/libraries/PoolGetters.sol`
- `src/dex/v4/twamm/vendor/libraries/TransferHelper.sol`
- `src/governance/StocksGovernor.sol`
- `src/governance/StocksGovernorFactory.sol`

## Findings summary

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 11 |
| Low | 10 |
| Info | 1 |
| Best practices | 0 |
| Total | 22 |

## Code summary

Stocks.ink is a decentralized finance protocol introducing Tokenized Stock Treasuries (TSTs), designed as an inverse model to digital asset treasuries by transforming speculative trading activity into a growing treasury of tokenized equities. Each TST project pairs a newly launched governance and utility token with an underlying tokenized stock asset. The protocol architecture spans a multi-stage lifecycle consisting of a pre-graduation bonding curve phase, an automated graduation to a Uniswap v4 concentrated liquidity pool equipped with a specialized hook and Time-Weighted Average Market Maker (TWAMM), an on-chain DAO governance structure, and a staking treasury that streams tokenized equity dividends to stakers and enables asset redemptions.

The initial phase begins with the deployment of a TST token and its corresponding bonding curve via the launch factory. The bonding curve implements a virtual constant-product Automated Market Maker (AMM) with anti-snipe protections where traders can buy and sell TST tokens against tokenized stock tokens based on oracle-attested pricing. Once the curve collects enough stock tokens to satisfy the graduation target or sells out 99% of its token allocation, graduation is triggered. During graduation, the curve burns excess unsold tokens, deploys an OpenZeppelin-based community governance system and a dedicated staking contract, and calls the graduator to seed permanent full-range liquidity on Uniswap v4.

Post-graduation, trading occurs on Uniswap v4 through a custom hook that enforces full-range liquidity, eliminating fee extraction via narrow range orders. The hook levies dynamic swap fees, directing a portion to the protocol and the remainder either to token burning (when TST is sold) or to the staking contract as treasury rewards (when stock is traded). The hook also vendors a TWAMM engine, allowing users to dollar-cost average long-term orders without causing sudden market impact. In the staking contract, TST holders can stake their tokens to receive streaming stock token dividends funded by trading fees. TST holders also retain the ability to burn their tokens to redeem a proportional share of unallocated treasury stock, establishing an intrinsic fundamental floor price. Governance can also vote to liquidate portions of the equity treasury through TWAMM orders to buy back and burn TST tokens.

### Main Entry Points and Actors

- StocksLaunchFactory.createCurve: Allows token creators to deploy a new TST token and bonding curve with price attestations and metadata.
- TokenMetadataRegistry.setMetadataURI: Allows token creators or the factory to record an immutable metadata URI for a deployed token.
- StocksCurve.buy: Allows traders to buy TST tokens using stock tokens along the constant-product bonding curve prior to graduation.
- StocksCurve.sell: Allows traders to sell TST tokens back to the bonding curve in exchange for stock tokens prior to graduation.
- StocksCurve.graduate: Allows any actor or keeper to graduate the bonding curve once thresholds are reached, seeding Uniswap v4 and launching staking and governance.
- StocksCurve.skim: Allows any actor to burn excess TST tokens mistakenly transferred to the curve contract.
- StocksStaking.stake: Allows users to stake TST tokens to accrue streaming tokenized stock reward distributions.
- StocksStaking.unstake: Allows stakers to withdraw their staked TST tokens from the contract.
- StocksStaking.claim: Allows stakers to withdraw their accrued tokenized stock reward dividends.
- StocksStaking.notifyRewardAmount: Allows any caller to update streaming reward calculations when stock token rewards are deposited.
- StocksStaking.redeem: Allows any TST token holder to burn TST tokens in exchange for a pro-rata share of redeemable treasury stock.
- StocksStaking.claimLiquidatedTst: Allows any actor to claim and permanently burn TST tokens acquired from a completed treasury liquidation TWAMM order.
- StocksStaking.setPool: Invoked by the curve contract during graduation to configure the active Uniswap v4 pool key and token orientations.
- StocksStaking.setRewardsPaused: Allows the governor contract to pause or resume reward streaming.
- StocksStaking.setRewardsDuration: Allows the governor contract to update the streaming distribution duration for future rewards.
- StocksStaking.liquidateTreasury: Allows the governor contract to initiate a TWAMM order selling unallocated treasury stock for TST to burn.
- StocksHook.submitOrder: Allows traders to place a continuous dollar-cost averaging TWAMM order across defined time intervals.
- StocksHook.batchSubmitOrders: Allows traders to submit multiple TWAMM orders across pools in a single transaction.
- StocksHook.sync: Allows order creators to synchronize execution progress and update token balances owed for an order.
- StocksHook.syncAndClaimTokens: Allows order creators to synchronize a TWAMM order and immediately withdraw owed tokens.
- StocksHook.batchSyncAndClaimTokens: Allows order creators to synchronize multiple TWAMM orders and withdraw owed tokens across specified currencies.
- StocksHook.claimTokensByPoolKey: Allows order creators to claim their credited tokens for a specific Uniswap v4 pool.
- StocksHook.claimTokensByCurrencies: Allows order creators to claim their credited tokens across an array of currency addresses.
- StocksHook.executeTWAMMOrders: Allows any caller to trigger execution of pending TWAMM orders up to the current block timestamp or target timestamp.
- StocksHook.pumpTwammBacklog: Allows any caller to execute backlogged TWAMM orders across historical intervals in bounded steps to manage gas consumption.
- StocksHook.registerPool: Invoked by the graduator deployer to register launch configuration, token directions, and fee parameters.
- StocksHook.beforeInitialize: Invoked by the Uniswap v4 PoolManager to validate pool creation and initialize TWAMM state.
- StocksHook.beforeAddLiquidity: Invoked by the Uniswap v4 PoolManager to restrict liquidity additions strictly to full-range positions and execute pending TWAMM orders.
- StocksHook.beforeRemoveLiquidity: Invoked by the Uniswap v4 PoolManager to execute pending TWAMM orders prior to liquidity removal.
- StocksHook.beforeSwap: Invoked by the Uniswap v4 PoolManager to execute TWAMM orders and deduct pre-swap protocol stock fees.
- StocksHook.afterSwap: Invoked by the Uniswap v4 PoolManager to collect trading fees, route stock fees to the staking treasury, and burn TST fee cuts.
- StocksGraduator.graduate: Invoked by the curve contract to seed full-range liquidity in Uniswap v4 and configure the hook.
- StocksGraduator.unlockCallback: Invoked by the Uniswap v4 PoolManager during pool initialization to mint initial liquidity and settle token balances.
- StocksGovernor.propose: Allows TST token holders meeting the proposal threshold to create new governance proposals.
- StocksGovernor.castVote: Allows TST token holders to vote on active governance proposals.
- StocksGovernor.castVoteWithReason: Allows TST token holders to vote on active proposals while attaching an explanatory reason.
- StocksGovernor.castVoteWithReasonAndParams: Allows TST token holders to vote on active proposals with custom parameters and a reason.
- StocksGovernor.castVoteBySig: Allows actors to submit a signed cryptographic message to cast a vote on behalf of a voter.
- StocksGovernor.castVoteWithReasonAndParamsBySig: Allows actors to submit a signed message casting a vote with parameters and a reason.
- StocksGovernor.execute: Allows any actor to execute an approved governance proposal once the voting period has elapsed.
- StocksGovernor.cancel: Allows proposers or authorized actors to cancel an active proposal under governance rules.
- StocksCurveFactory.deploy: Allows factory deployers to instantiate a new StocksCurve contract.
- StocksStakingFactory.deploy: Allows deployers or curves to instantiate a new StocksStaking contract.
- StocksGovernorFactory.deploy: Allows deployers or curves to instantiate a new StocksGovernor contract.

## Findings

### 1. `beforeSwap` pulls the protocol stock cut with `poolManager.take` sized off the full specified input, so stock-to-TST swaps revert when the PoolManager does not already hold that much stock.

**Severity:** Medium  
**Contracts:** `src/dex/v4/StocksHook.sol`

#### Context

`StocksHook.beforeSwap` charges the protocol's share of a stock-to-TST exact-input swap before the pool swap runs. For a registered pool it computes `protocolStockCut` from the trader's full `amountSpecified`, pulls that stock out of the PoolManager, forwards it to `info.protocol`, and returns a positive specified `BeforeSwapDelta` so the trader is charged the cut on top of the amount the pool consumes.

```solidity
// File: src/dex/v4/StocksHook.sol
uint256 stockIn = uint256(-params.amountSpecified);
uint256 protocolStockCut = (stockIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
if (protocolStockCut == 0) {
    return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
// @auditagent> take() needs PM stock already on hand
_takeExact(stockCurrency, info.stockToken, protocolStockCut);
IERC20(info.stockToken).safeTransfer(info.protocol, protocolStockCut);
```

#### Root Cause

`poolManager.take` transfers real ERC-20 from the PoolManager. In the standard Uniswap v4 flash-accounting flow the trader has not settled the input yet when `beforeSwap` runs, so the only stock the PoolManager holds is whatever is already sitting in it from liquidity. The cut is `stockIn * floor(feeBps * 2000 / 10000) / 10000` of the full specified input (2% when `feeBps` is 1,000), not of the amount the pool will actually consume. If that cut exceeds the PoolManager's current stock balance, the ERC-20 transfer inside `take` reverts and the whole swap reverts. `afterSwap`'s `PreSwapCutWouldExceedActualFill` guard never runs, because the failure happens before the core swap. A normal router that sets `amountSpecified` to the user's balance and relies on `sqrtPriceLimitX96` to cap the fill, or a corrective buy whose specified size is more than about 50 times the pool's remaining stock, hits this even when the eventual fill would have been small and fully payable.

#### Impact

Stock-to-TST buys revert instead of trading whenever the specified input's protocol cut is larger than the PoolManager's current stock balance. That blocks the usual max-input plus price-limit buy, and it blocks large arbs that would restore a depleted stock side, because those are exactly the swaps whose specified input is large relative to remaining reserves. Traders can still succeed by splitting into swaps no larger than about `50 *` current stock reserves (at the standard 1,000 bps fee), or by using a custom router that pre-transfers the cut into the PoolManager before `swap`. Funds already in the pool are not stolen; the failing swap rolls back. TST-to-stock swaps are unaffected, because that direction does not take stock in `beforeSwap`. The output-side `take` in `afterSwap` is also unaffected in the normal case, because that fee is a fraction of tokens the PoolManager already holds as reserves.

Severity Note:
- The swap reverts only when the protocol cut on the full specified stock input exceeds the PoolManager's current stock balance. Routers that set the specified amount to the expected fill, rather than the full balance with a price limit, do not hit this path.

### 2. Long TST names permanently prevent graduation through `StocksGovernorFactory.deploy`

**Severity:** Medium  
**Contracts:** `src/curve/StocksCurve.sol`, `src/StocksLaunchFactory.sol`, `src/governance/StocksGovernorFactory.sol`

#### Context

`StocksLaunchFactory.createCurve` accepts a TST name and `StocksCurve._graduate` appends `" Governor"` before passing it to `StocksGovernorFactory.deploy`. Graduation must deploy the governor before it can create staking and the pool.

```solidity
// File: src/curve/StocksCurve.sol
address gov = StocksGovernorFactory(f.governorFactory()).deploy(
    // @auditagent> derived name exceeds limit
    string.concat(tstToken.name(), " Governor"),
    IVotes(address(tstToken)),
```

#### Root Cause

A TST name of 23–31 bytes passes the token's EIP-712 constructor, but appending the nine-byte suffix produces a governor name longer than 31 bytes. The governor's EIP-712 constructor calls `toShortString()`, which reverts for such names. Because the token name cannot be changed, every subsequent `graduate()` attempt for that curve reverts at the same deployment.

#### Impact

A curve with an affected name can accept stock from buyers and meet its graduation threshold, but can never establish its pool, staking contract, or governance treasury. The graduation transaction rolls back, leaving buyers dependent on `sell()` to unwind their positions; this is not an unconditional lock of stock held by sellers who can return their TST.

### 3. `sell` can deliver less stock than `minStockOut` when the stock token charges a transfer fee

**Severity:** Medium  
**Contracts:** `src/curve/StocksCurve.sol`

#### Context

`StocksCurve.sell` quotes a stock payout for returned TST and uses `minStockOut` to protect the seller from receiving too little stock.

```solidity
// File: src/curve/StocksCurve.sol
stockOut = quoteSell(tstIn);
if (stockOut == 0) revert ZeroAmount();
// @auditagent> Net receipt not checked
if (stockOut < minStockOut) revert SlippageExceeded();

realStockCollected -= stockOut;
tokensSold -= tstIn;

IERC20(address(tstToken)).safeTransferFrom(msg.sender, address(this), tstIn);
stockToken.safeTransfer(msg.sender, stockOut);
```

#### Root Cause

The minimum is checked against the nominal `stockOut` before the stock transfer. `safeTransfer` confirms that the token call succeeded but does not verify the seller's balance increase. If the configured stock token charges a fee on outbound transfers, the call can succeed while the seller receives less than `minStockOut`.

#### Impact

A seller irreversibly gives up TST despite receiving less stock than their specified minimum. For example, a quoted payout of 100 with `minStockOut` set to 100 delivers only 90 if the stock token charges a 10% transfer fee. This requires a stock token that taxes outbound transfers; ordinary untaxed ERC-20 transfers are unaffected.

Severity Note:
- The shortfall equals the stock token's outbound transfer fee and occurs only when that token taxes transfers out of the curve. Untaxed ERC-20 stock delivers the full quoted amount.

### 4. Unbound price attestation lets a front-runner replace a `createCurve` launch and its metadata

**Severity:** Medium  
**Contracts:** `src/StocksLaunchFactory.sol`, `src/curve/StocksCurve.sol`, `src/TokenMetadataRegistry.sol`

#### Context

`StocksLaunchFactory.createCurve` uses a trusted stock-price attestation to deploy a TST and curve, records the curve in `curveOf`, and sets the token's URI in `TokenMetadataRegistry`. The caller supplies the token name, symbol, rewards duration, and metadata URI. Each stock-price-timestamp attestation may be used only once.

```solidity
// File: src/StocksLaunchFactory.sol
// @auditagent> launch parameters remain unbound
bytes32 attestationId = keccak256(abi.encodePacked(stockToken, price, priceTimestamp));
if (usedAttestations[attestationId]) revert AttestationAlreadyUsed();
usedAttestations[attestationId] = true;
```

#### Root Cause

`StocksCurve` verifies a signature over the factory, stock token, price, and timestamp, but not the intended caller or any caller-supplied launch details. `createCurve` likewise keys `usedAttestations` only by stock token, price, and timestamp. An attacker observing a pending launch can submit the copied attestation first with a different name, symbol, metadata URI, or permitted rewards duration. Alternatively, the attacker can change only `metadataURI`; because that value is not an input to the TST or curve deployment, the attacker can occupy the intended launch's token address and write its URI. The first successful call consumes the attestation, and the registry does not allow that token's URI to be changed.

#### Impact

If the attacker's transaction executes first and completes deployment, the legitimate launch reverts with `AttestationAlreadyUsed`. The factory-recognized token can have attacker-chosen branding and an attacker-chosen, permanent metadata URI, potentially misleading users or downstream displays that treat the authentic price attestation as authentication of the launch. The attacker cannot change the signed stock token or price, and the minted supply is transferred to the curve rather than to the attacker. A fresh attestation could permit a separate launch, but cannot correct the URI already recorded for the attacker-launched token.

Severity Note:
- The caller receives no token supply and no curve-admin authority; the signed stock token and price still govern the curve.
- On-chain buyer loss is not forced. It arises only if a user or display treats the first factory-recognized launch as the authentic branded asset.
- A newly signed timestamp can deploy a different token, but it cannot rewrite metadata already stored for the front-run token.

### 5. Staking removes TST voting power without removing staked tokens from governance requirements

**Severity:** Medium  
**Contracts:** `src/StocksStaking.sol`, `src/governance/StocksGovernor.sol`

#### Context

`StocksStaking.stake` transfers TST from a holder into the staking contract. `StocksGovernor` derives quorum from historical total supply less tokens sent to the burn address, and derives its proposal threshold from the similarly calculated current circulating supply.

```solidity
// File: src/StocksStaking.sol
totalStaked += amount;
balanceOf[msg.sender] += amount;
// @auditagent> staked votes lose delegation
tstToken.safeTransferFrom(msg.sender, address(this), amount);
```

#### Root Cause

The staking contract has no facility to delegate its `ERC20Votes` balance or preserve individual stakers' voting power. A transfer into it removes votes from the holder's delegate, but its TST remains in the supply used for quorum and proposal thresholds.

#### Impact

While a sufficiently large share of circulating TST is staked, the remaining voting power can fall below the proposal threshold or the 10% quorum. For example, if more than 90% of circulating TST is staked and the remainder is the only voting power available, even unanimous votes from that remainder cannot meet quorum. This can prevent governance actions, including changes to rewards and treasury liquidation. It is recoverable if enough holders unstake and delegate before the relevant voting snapshot; staking does not permanently trap their TST.

Severity Note:
- Quorum numerator and proposal-threshold bps are constructor parameters, not fixed at 10%. The stake ratio that blocks proposals depends on those deployed values.

### 6. Metadata-less six-decimal stock can divert one million shares to the hook at graduation

**Severity:** Medium  
**Contracts:** `src/dex/v4/StocksGraduator.sol`

#### Context

`StocksGraduator.graduate` sets aside a fixed `HOOK_STOCK_RESERVE_WEI` before seeding liquidity. A normally reporting six-decimal stock is rejected by `StocksCurve` at launch, but that constructor accepts stock tokens whose optional `decimals()` call returns no data or reverts.

```solidity
// File: src/dex/v4/StocksGraduator.sol
// @auditagent> Reserve ignores actual decimals
uint256 public constant HOOK_STOCK_RESERVE_WEI = 1e12;
```

#### Root Cause

For an attested stock with six-decimal base units and no usable `decimals()` response, the launch check does not establish 18-decimal units. The graduator nevertheless requires `stockAmount > 1e12` and transfers exactly `1e12` units to `StocksHook`, without scaling the reserve to the asset. Those units equal one million shares for this narrower accepted token.

#### Impact

Conditional on the trusted signer authorizing such a token and its curve reaching graduation, a seed of at most one million shares fails the reserve check. A successful seed sends one million shares to the hook rather than the permanent pool position; the graduator provides no direct return of that buffer to the curve. This does not apply to an ordinary six-decimal token that reports `decimals() == 6`, which the curve rejects.

Severity Note:
- This occurs only if a trusted signer attests a stock that uses six-decimal base units and whose decimals() call returns no data or reverts. A token that reports decimals() equal to 6 is rejected at curve launch, and no such metadata-less stock is part of the default configuration.
- The one million shares are transferred to the hook, not to an external caller. The graduator exposes no function that returns that buffer to the curve or the permanent pool position.

### 7. TWAMM fulfillment has no user-defined execution-price or minimum-proceeds bound

**Severity:** Medium  
**Contracts:** `src/dex/v4/twamm/vendor/TWAMM.sol`, `src/dex/v4/StocksHook.sol`

#### Context

`TWAMM.submitOrder` accepts an input amount and duration but no minimum output or price limit. At each interval boundary, `executeTWAMMOrders` reads the pool's current spot price, calculates virtual order earnings, and constructs a swap intended to fulfill the calculated aggregate amount.

```solidity
// File: src/dex/v4/twamm/vendor/TWAMM.sol
if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96 && maxSwapAmount != 0) {
    // @auditagent> fulfillment ignores owner limits
    IPoolManager.SwapParams memory swapParams =
        IPoolManager.SwapParams(zeroForOne, -maxSwapAmount.toInt256(), sqrtPriceLimitX96);
```

#### Root Cause

The `sqrtPriceLimitX96` supplied to the fulfillment swap is calculated from the current spot price and outstanding orders, rather than an order owner's acceptable execution price. An attacker can move the spot price during the interval in which an order is pending. A swap during that interval invokes `StocksHook.beforeSwap`, but its TWAMM execution only advances through the most recently completed interval; it does not execute the pending interval. If the dislocated price persists through the next boundary, fulfillment calculates the pending interval's earnings at that price. The attacker can then trade in the opposite direction. Moving the price only after an interval has become due would instead trigger TWAMM execution before the attacker's swap, so the attack requires pre-positioning before the boundary.

#### Impact

If the attacker can sustain a sufficiently adverse price through the boundary, TWAMM sellers receive fewer output tokens than they would at the undistorted price. A large pending order can make the attack profitable even after trading costs. Profitability and the victim's loss depend on available liquidity, order size, fees, and whether other traders restore the price before fulfillment; this does not guarantee an attack against every order.

Severity Note:
- Fewer output tokens are credited only if an adverse spot is still in place at the interval boundary, and a round trip is profitable only when the pending order is large enough relative to liquidity and swap fees that other traders have not already restored the price.

### 8. A 99% sell-out cannot satisfy the 1% graduation seed minimum

**Severity:** Medium  
**Contracts:** `src/curve/StocksCurve.sol`, `src/dex/v4/StocksGraduator.sol`

#### Context

`StocksCurve.graduate` permits graduation when 99% of `CURVE_SUPPLY` has been sold. `_graduate` then calculates a price-matched TST seed, which `StocksGraduator.graduate` requires to be at least 1% of total supply.

```solidity
// File: src/curve/StocksCurve.sol
// @auditagent> Sellout exceeds seed capacity
bool soldOut = tokensSold >= (CURVE_SUPPLY * SOLDOUT_THRESHOLD_BPS) / BPS_DENOM;
if (!targetReached && !soldOut) revert NotReady();
```

#### Root Cause

At 99% sell-through, fewer than 8 million TST remain unsold, so `tstToSeed` is necessarily below 8 million TST. The graduator requires 10 million TST. A buyer can cross the threshold in one `buy` transaction, but the resulting `graduate` call always reverts with `SeedTooSmall`. If that buyer holds all the sold TST, nobody else can restore a seedable state by selling.

#### Impact

A buyer willing to commit roughly 33 times the curve's stock graduation target can prevent migration and the associated pool and fee infrastructure from launching until they sell TST back. The purchase is reversible through `sell`, but the blockade persists while the buyer holds the tokens; it is not an irreversible loss of the curve's stock.

Severity Note:
- The freeze is absolute only while sold TST stays concentrated enough that other holders cannot sell the curve back to a seed of at least 1% of total supply.
- Stock already paid into the curve can still be withdrawn by selling TST; only migration and the post-graduation pool, staking, and fee setup are unavailable.

### 9. Transfer-taxed stock can permanently prevent graduation settlement

**Severity:** Medium  
**Contracts:** `src/curve/StocksCurve.sol`, `src/dex/v4/StocksGraduator.sol`

#### Context

`StocksCurve.buy` explicitly accounts for the actual stock received, so a transfer-taxed stock can accumulate on the curve. At graduation, the curve passes its stock balance as `stockAmount`; `StocksGraduator` then pulls that nominal amount and settles the PoolManager's liquidity delta.

```solidity
// File: src/dex/v4/StocksGraduator.sol
// @auditagent> Nominal receipt goes unchecked
IERC20(stockToken).safeTransferFrom(msg.sender, address(this), stockAmount);
```

#### Root Cause

Unlike `buy`, `StocksGraduator.graduate` does not measure the stock actually received from the curve. It prices and sizes liquidity using the nominal `stockAmount`, then `_settleCurrency` transfers exactly the negative delta and calls `settle()`. An inbound transfer tax can leave the graduator short of the required stock; a tax on its transfer to the PoolManager can make settlement credit less than the outstanding delta. A successful ERC-20 transfer does not establish that the PoolManager's delta was paid.

#### Impact

For an attested, 18-decimal stock charging a material transfer tax, buys can succeed and make the curve ready, but every graduation attempt reverts when the graduator cannot fund or settle the requested liquidity. The pool, staking and governance cannot be finalized while that condition persists. Holders may still attempt pre-graduation sells, but that does not make the same taxed stock suitable for the seed path.

Severity Note:
- A failed graduation reverts atomically, so curve balances stay withdrawable through pre-graduation sells; the lasting effect is that the pool, staking, and governance for that stock never launch while the transfer tax remains.

### 10. `beforeSwap` charges a stock-input fee on amounts a price limit prevents from being swapped

**Severity:** Medium  
**Contracts:** `src/dex/v4/StocksHook.sol`

#### Context

For an exact-input swap from stock to TST, `beforeSwap` computes the protocol cut from the trader's specified stock input and transfers it before the pool executes the swap. `afterSwap` checks the stock amount actually swapped when a price limit truncates the fill.

```solidity
// File: src/dex/v4/StocksHook.sol
uint256 stockIn = uint256(-params.amountSpecified);
// @auditagent> Charges unfilled specified input
uint256 protocolStockCut = (stockIn * _protocolShareBps(info.feeBps)) / BPS_DENOM;
```

#### Root Cause

The cut remains based on the full specified input even if only a small portion reaches the pool. `afterSwap` rejects a truncated fill only when the prepaid cut is at least as large as the stock actually swapped; it accepts every fill slightly above that threshold. A trader can encounter this state with a tight price limit, including after another trade moves the price towards that limit.

#### Impact

The trader can pay a fee far above the intended 2% of the effective stock input. At `feeBps = 1000`, specifying 10,000 stock units incurs a 200-unit cut. If the limit permits only 201 units to be swapped, the trader pays 401 units in total, nearly half of which goes to the protocol. The price limit does not protect the trader from this disproportionate charge; no attacker profit is required.

### 11. Small donated inflows can repeatedly postpone stakers' existing rewards

**Severity:** Medium  
**Contracts:** `src/StocksStaking.sol`

#### Context

`StocksStaking._notifyReward` registers increases in its stock-token balance as rewards. An inflow of at least 1% of the outstanding stream restarts the entire remaining stream over `rewardsDuration`. Anyone can transfer stock to the contract and call `notifyRewardAmount`.

```solidity
// File: src/StocksStaking.sol
// @auditagent> Donations restart existing obligations
if (reward * MATERIAL_INFLOW_DIVISOR >= leftover) {
    rewardRate = (reward + leftover) / rewardsDuration;
    periodFinish = block.timestamp + rewardsDuration;
}
```

#### Root Cause

The restart predicate compares only the new inflow with the outstanding stream. It does not distinguish an unsolicited donation from ordinary reward income or bound how much an existing stream may be postponed. An attacker can provide the qualifying inflow repeatedly while stakers already have unvested rewards.

#### Impact

This is third-party reward-delay griefing rather than theft of vested rewards. Halfway through a stream with approximately `R/2` outstanding, a donation of about `R/200` meets the 1% predicate. Restarting over a full-duration period roughly halves the rate at which that outstanding balance vests during the next half-period. Repeating the action can keep postponing payment at a cost much smaller than the reward balance delayed; the donated stock eventually also belongs to the reward pool.

Severity Note:
- The caller must irrevocably donate stock into the reward pool and receives nothing back, so the delay is griefing rather than a profitable extraction.
- Already-vested rewards remain claimable and staked principal remains withdrawable; only the unvested stream is spread over a new full duration.

### 12. Unaccounted stock donations distort the graduation pool’s opening price

**Severity:** Low  
**Contracts:** `src/curve/StocksCurve.sol`, `src/dex/v4/StocksGraduator.sol`

#### Context

`StocksCurve._graduate` is intended to seed a Uniswap v4 pool at the curve’s closing marginal price. It calculates `tstToSeed` from `realStockCollected`, `virtualStockReserve`, and unsold TST, then passes seed amounts to `StocksGraduator.graduate`. Ordinary buys increase `realStockCollected` by the stock received in that trade; a direct stock-token transfer does not update that accounting.

```solidity
// File: src/curve/StocksCurve.sol
// @auditagent> Unaccounted stock enters seed
uint256 stockToSeed = stockToken.balanceOf(address(this));
```

#### Root Cause

`_graduate` prices `tstToSeed` against accounted stock but sets `stockToSeed` to the curve’s entire stock-token balance. A donation, mistaken transfer, or airdrop therefore increases the stock seed without increasing the TST seed or changing curve quotes. There is no stock equivalent of `skim` to remove the surplus. `StocksGraduator` pulls both supplied amounts and derives the pool’s initial price from them after its fixed hook reserves are deducted. Thus, whenever the balance exceeds `realStockCollected`, unaccounted stock changes the opening ratio rather than being handled separately.

#### Impact

If an ungraduated curve's stock-token balance exceeds realStockCollected, a successful graduate seeds that full balance against a TST amount sized only from accounted stock. The Uniswap v4 pool then opens with more stock per TST than the curve's closing marginal price, by about the ratio of total balance to accounted stock, subject to rounding and the fixed hook reserves. Until trading moves the price, a buyer of TST pays more stock per token than that close, and a seller of TST can receive the surplus. The surplus comes only from a direct transfer, mistaken deposit, or airdrop; supplying it does not let the sender extract stock that buyers deposited through the curve. Pre-graduation sells still pay only accounted reserves. For any realistic stock balance the seed and liquidity math still succeed, so the excess does not block graduation.

Severity Note:
- A sender who supplies the excess cannot extract more than that unsolicited surplus; accounted curve deposits are exchanged for TST at the pool price rather than taken without payment.
- Graduation price and liquidity math revert only at a stock-to-TST seed ratio on the order of 2^64, which a normal stock-token balance cannot reach.

### 13. A partial liquidation claim can strand the remaining TST after `sync` deletes the expired order

**Severity:** Low  
**Contracts:** `src/StocksStaking.sol`

#### Context

`claimLiquidatedTst` synchronizes the treasury's TWAMM order, claims its TST proceeds from the hook, and sends the amount received to `BURN_ADDRESS`. The hook permits a claim smaller than its recorded credit when its token balance is insufficient.

```solidity
// File: src/StocksStaking.sol
// @auditagent> missing order blocks claims
IStocksHookMinimal(hook).sync(
    IStocksHookMinimal.SyncParams({key: poolKey, orderKey: orderKey})
);
(uint256 tokens0, uint256 tokens1) = IStocksHookMinimal(hook).claimTokensByPoolKey(poolKey);
```

#### Root Cause

`_claimLiquidatedTst` always calls `sync` before claiming tokens. Synchronizing an expired order deletes its order record, but a balance-limited token claim leaves the unpaid credit in the hook. Once the order is deleted, another `claimLiquidatedTst` call reverts at `sync` before reaching that credit. `liquidateTreasury` also skips its old-order claim when `getOrder` reports a zero sell rate.

#### Impact

If the hook has enough TST to complete synchronization but not enough to pay the full credited amount, the unpaid remainder cannot be claimed or burned through the staking contract even if the hook is later replenished. It can become accessible through a subsequent successful liquidation, but that requires a new governance action and surplus stock; without one, it remains stranded. The loss is limited to the unpaid credit, and material impact requires a material hook shortfall.

Severity Note:
- The unpaid credit is stranded only if the hook can finish sync while holding less TST than the amount credited. The claim does not create that shortage, and the owed TST can still be pulled by a later liquidation claim once the hook can pay.

### 14. Price attestations can be replayed across chains with matching factory addresses

**Severity:** Low  
**Contracts:** `src/curve/StocksCurve.sol`, `src/StocksLaunchFactory.sol`

#### Context

`StocksCurve` verifies a personal-signed digest containing its launcher address, stock address, price, and timestamp. The launcher keeps a local `usedAttestations` mapping.

```solidity
// File: src/curve/StocksCurve.sol
// @auditagent> Chain identity not signed
bytes32 attestationHash = keccak256(abi.encodePacked(factory, _stockToken, price, priceTimestamp));
```

#### Root Cause

Neither the signed digest nor the local replay mapping binds a chain ID. The EIP-191 personal-sign prefix authenticates the constructed digest but adds no chain identity. If two chains use the same launch-factory address and trusted signer, a fresh quote for a stock address on one chain also verifies for that address on the other; use on the first chain does not mark the second mapping.

#### Impact

A price attestation that omits the chain id can be reused on another chain only when that chain's launch factory is at the same address, uses the same trusted signer, and the same stock-token address is valid there. If that token's USD value differs, the new curve's virtual reserve and graduation target are set from the other chain's quote. Only buyers of that new curve, and the pool created if it graduates, are exposed to the difference; they can still sell on the curve before graduation. Existing curves are unaffected. Reuse does not misprice the curve when the token has the same USD value on both chains, and the quote must still be inside the five-minute freshness window.

Severity Note:
- Loss requires two chains to share a launch-factory address, trusted signer, and stock-token address, plus a material USD-value difference inside the five-minute freshness window.
- Replaying a quote for the same asset at the same USD price does not change curve economics.

### 15. Unbounded TWAMM catch-up lets staggered dust orders block later operations

**Severity:** Low  
**Contracts:** `src/dex/v4/twamm/vendor/TWAMM.sol`, `src/dex/v4/StocksHook.sol`, `src/StocksStaking.sol`

#### Context

`TWAMM` advances outstanding orders when a new order is submitted or an owner calls `sync`. `StocksHook` also attempts that advancement before swaps and liquidity changes through `_safeTwammExecute`. `StocksStaking` uses hook order submission for `liquidateTreasury` and hook `sync` for `claimLiquidatedTst`. Permissionless `pumpTwammBacklog` and the timestamped execution overload can advance virtual time in smaller steps.

```solidity
// File: src/dex/v4/twamm/vendor/TWAMM.sol
// @auditagent> Unbounded expiration interval scan
while (nextExpirationTimestamp <= currentTimestampAtInterval) {
    if (_hasOutstandingOrdersAtInterval(self, nextExpirationTimestamp)) {
        pool = _advanceTimestampForSinglePoolSell(
```

#### Root Cause

`_executeTWAMMOrders` has no per-call bound on the elapsed expiration intervals it scans, and it performs additional work at intervals with expiring orders. An attacker can submit many small, nonzero-sell-rate orders with distinct future expirations, then let those intervals pass without successful execution. The next `_submitOrder` or `sync` must catch up in one call. Swaps and liquidity changes instead reach catch-up through `_safeTwammExecute`: although it can catch some execution failures and let the action proceed, it reverts when the failed external call has consumed most of its forwarded gas. Staking liquidation inherits the submission path—and can also sync a prior expired liquidation—while claiming a liquidation inherits the sync path.

#### Impact

A sufficiently large backlog can make later order submissions and owner syncs exceed practical transaction gas limits, delaying direct order users, the governor’s treasury liquidation, and the sync needed to claim and burn proceeds from a staking liquidation. Swaps and permitted liquidity changes also revert when catch-up exhausts the hook callback’s gas and triggers `TwammExecutionOutOfGas`; they may proceed without updated TWAMM execution if a failure is caught with sufficient gas remaining. The attack requires the staggered intervals to elapse without intervening successful catch-up. It does not itself imply stolen funds or a permanent block: anyone can advance the backlog in smaller calls, but affected users or keepers bear that gas and operational work before blocked calls succeed.

Severity Note:
- A catch-up that exceeds a block gas limit needs on the order of several hundred elapsed expiration intervals that each contain an outstanding order and that pass with no successful execution. At a one-hour expiration interval that is weeks without any swap, liquidity change, order submission, sync, or backlog pump; any one of those calls advances virtual time and shrinks the remaining work.

### 16. A newly submitted order can execute an elapsed interval's entire sell amount immediately

**Severity:** Low  
**Contracts:** `src/dex/v4/twamm/vendor/TWAMM.sol`, `src/dex/v4/StocksHook.sol`

#### Context

Direct callers of `StocksHook.submitOrder` can choose an order duration, including one expiration interval. `TWAMM._submitOrder` first catches up existing orders, then derives the new expiration from the start of the current interval and immediately adds its rate to the active pool.

```solidity
// File: src/dex/v4/twamm/vendor/TWAMM.sol
// @auditagent> Submission backdates virtual sales
uint256 currentTimestampAtInterval = _getIntervalTime(block.timestamp);
orderKey = OrderKey({
    owner: msg.sender,
    expiration: (currentTimestampAtInterval + params.duration).toUint160(),
    zeroForOne: params.zeroForOne
});
```

#### Root Cause

The new order's active rate is treated as though it existed at `lastVirtualOrderTimestamp`, even when submission occurs just before the next boundary. On that boundary, execution advances a full interval at the new rate; it does not prorate from the actual submission time. This is a separate timing defect from expensive catch-up: execution can succeed while selling earlier than the owner requested.

#### Impact

A direct TWAMM order is anchored to the start of the current expiration interval, so the next execution sells a full interval of its rate even if submission was only moments earlier. The order then ends up to one interval sooner in wall-clock time than duration measured from submission. A one-interval order therefore completes at that boundary instead of about one interval later; longer orders keep the same per-interval size and only lose up to one interval of spacing. The submitter still sells only the tokens deposited and receives that swap's output. Any difference versus a later execution is ordinary market slippage and depends on liquidity and prices over that interval. Longer protocol liquidation orders are less exposed; this applies to direct submitOrder callers.

Severity Note:
- A one-interval order is always settled as a single swap of its full deposit at the next interval boundary, so submitting late changes the execution time, not the amount sold in that chunk.
- Any difference versus selling at a later boundary is market slippage and can be a gain if the nearer price is better.

### 17. Recording burned supply at proposal creation can make the later voting quorum unreachable

**Severity:** Low  
**Contracts:** `src/governance/StocksGovernor.sol`, `src/TSTToken.sol`, `src/StocksStaking.sol`

#### Context

`StocksGovernor` subtracts a recorded dead-address balance from past total supply to calculate a proposal's quorum. `TSTToken` uses a timestamp clock, and proposals have at least a one-hour voting delay, so the proposal's voting snapshot is in the future when `_propose` records that balance. `StocksStaking.redeem` is one route that transfers TST to the dead address.

```solidity
// File: src/governance/StocksGovernor.sol
uint256 timepoint = proposalSnapshot(proposalId);
if (!_burnSnapshotRecorded[timepoint]) {
    _burnSnapshotRecorded[timepoint] = true;
    // @auditagent> Burn snapshot precedes voting
    _burnedAtSnapshot[timepoint] = IERC20(address(token())).balanceOf(BURN_ADDRESS);
}
```

#### Root Cause

`_propose` records the burn balance at proposal creation, but `quorum(proposalSnapshot(proposalId))` combines that earlier balance with vote checkpoints from the later snapshot. TST sent to `BURN_ADDRESS` between those times no longer contributes voting power, yet remains counted as circulating supply for that proposal's quorum. The first proposal for a timepoint fixes this discrepancy for every proposal sharing that timepoint.

#### Impact

A proposal's quorum uses the burn-address balance from creation rather than from its later voting snapshot. Tokens sent to the burn address during the voting delay no longer vote, but they still raise that proposal's quorum by the quorum fraction of the amount transferred. Ordinary transfers only increase the votes required by that fraction. Quorum can exceed all remaining voting power only if the transfer is larger than circulating supply multiplied by one minus the quorum fraction. The affected proposal can be replaced by one created after the transfer, which records the updated burn balance.

Severity Note:
- Quorum is unreachable only if the amount sent to the burn address during the voting delay exceeds circulating supply multiplied by one minus the quorum fraction.
- A proposal created after that transfer records the updated burn balance, so the same discrepancy does not carry forward unless another large transfer occurs before the new snapshot.

### 18. Stock tokens with unverified decimals can be launched using 18-decimal pricing math

**Severity:** Low  
**Contracts:** `src/curve/StocksCurve.sol`

#### Context

`StocksCurve` treats stock-token amounts as 18-decimal units when deriving the graduation stock target and virtual reserve from the signed USD price. Its constructor attempts to reject a stock token that reports a different `decimals()` value. The ERC-20 `decimals()` method is optional, so a transferable token need not provide it. ([eips.ethereum.org](https://eips.ethereum.org/EIPS/eip-20?utm_source=openai))

```solidity
// File: src/curve/StocksCurve.sol
(bool decimalsOk, bytes memory decimalsData) = _stockToken.staticcall(abi.encodeWithSignature("decimals()"));
// @auditagent> permits unverified decimals
if (decimalsOk && decimalsData.length >= 32 && abi.decode(decimalsData, (uint256)) != 18) {
    revert UnsupportedStockDecimals();
}
```

#### Root Cause

The constructor rejects a non-18 value only when the `decimals()` static call succeeds and returns at least 32 bytes. A missing or reverting method passes the check, leaving the stock unit size unverified while `graduationStockTarget` is calculated with `PRICE_DECIMALS = 1e18`.

#### Impact

If the trusted signer attests a normally denominated price for a stock token that actually uses six decimal places but does not return `decimals()`, the curve treats raw token units as though they had 18 decimal places. Its stock target and virtual reserve are then 10^12 times larger in token units than intended for that price, materially mispricing trades and potentially making graduation impractical. This requires an attestation for such a token; a token that is actually 18-decimal does not trigger the mismatch.

Severity Note:
- Mispricing occurs only when the trusted signer attests a non-18-decimal stock token that does not return a decodable decimals() value. Buyers are not forced to trade: slippage checks can reject the quote, and sells return stock along the same curve.

### 19. TWAMM intervals above 30 hours make treasury liquidation impossible

**Severity:** Low  
**Contracts:** `src/StocksStaking.sol`

#### Context

`StocksStaking.liquidateTreasury` lets the governor sell surplus treasury stock through the generation's hook. It requires at least `MIN_LIQUIDATION_INTERVALS` (24) intervals while limiting an order to `MAX_LIQUIDATION_DURATION` (30 days).

```solidity
// File: src/StocksStaking.sol
uint256 interval = IStocksHookMinimal(hook).expirationInterval();
// @auditagent> Conflicting liquidation duration bounds
if (durationIntervals > MAX_LIQUIDATION_DURATION / interval) revert LiquidationTooLong();
uint256 duration = interval * durationIntervals;
// Both floors must hold: the wall-clock one (in case expirationInterval is small enough that many
// intervals still add up to less than a day) and the interval-count one (see MIN_LIQUIDATION_INTERVALS'
// own comment -- the one that actually matters when expirationInterval is large).
if (duration < MIN_LIQUIDATION_DURATION || durationIntervals < MIN_LIQUIDATION_INTERVALS) {
    revert LiquidationTooShort();
}
```

#### Root Cause

When `expirationInterval` exceeds 108,000 seconds, 24 intervals exceed 30 days. For example, a two-day interval allows at most 15 intervals under the maximum-duration check, while every count below 24 fails the minimum-interval check. The hook accepts this nonzero interval. A zero interval is not another trigger: the `TWAMM` constructor rejects it.

#### Impact

In a generation configured with an interval above 30 hours, no governor proposal can successfully call `liquidateTreasury` for its graduated TSTs. Surplus stock cannot be sold and the resulting TST burned through this governance action. The described one-hour configuration is unaffected.

Severity Note:
- Surplus stock is not trapped: holders can still redeem TST for stock, and balance increases can still be streamed as staking rewards. Only the governor TWAMM sale that buys and burns TST is unreachable.

### 20. Truncated stock rewards are marked notified but never streamed to stakers

**Severity:** Low  
**Contracts:** `src/StocksStaking.sol`

#### Context

`StocksStaking._notifyReward` detects newly received stock, records it in `lastNotifiedBalance`, and sets `rewardRate` to stream it to stakers. Stock can arrive through hook-routed fees or a direct transfer before a caller invokes `notifyRewardAmount`. Stock not earned by stakers is available for redemption or treasury liquidation.

```solidity
// File: src/StocksStaking.sol
uint256 reward = currentBalance - lastNotifiedBalance;
// @auditagent> Reward remainder prematurely accounted
lastNotifiedBalance = currentBalance;

if (block.timestamp >= periodFinish) {
    rewardRate = reward / rewardsDuration;
```

#### Root Cause

`_notifyReward` advances `lastNotifiedBalance` by the entire inflow even when integer division cannot incorporate all of it into `rewardRate`. After a period ends, an inflow smaller than `rewardsDuration` produces a zero rate. During an active period, an inflow below the material-restart threshold produces no rate increase when `reward < remaining`. A material restart can also discard the remainder of `(reward + leftover) / rewardsDuration`. Because the omitted stock has already been marked notified, subsequent notifications do not carry it into the stream; repeated separately notified small inflows can repeat the loss.

#### Impact

Stakers cannot claim the omitted stock, including after the stream expires. It is not included in `_earnedByStakers`, so it can instead contribute to `redeemableStock` paid through `redeem`, or to `stockCommitted` in a governor-initiated `liquidateTreasury`, subject to those entrypoints' checks. Each division loses less than its denominator in stock base units: less than `remaining` in the active small-inflow branch and less than `rewardsDuration` in the other branches. For example, 100 base units over a one-hour `rewardsDuration` produce a zero rate. A material cumulative effect requires repeated inflows.

Severity Note:
- Each notification omits fewer base units than rewardsDuration, which is dust for an 18-decimal stock even at a 365-day duration. A larger per-notification loss requires a low-decimal stock and an inflow smaller than the active remainder or rewardsDuration, repeated across separate notifications.

### 21. Any caller can irreversibly claim the metadata entry of an existing token

**Severity:** Low  
**Contracts:** `src/TokenMetadataRegistry.sol`

#### Context

`TokenMetadataRegistry.setMetadataURI` is a public first-write registry. It accepts any address with deployed code and permanently records one URI for that address.

```solidity
// File: src/TokenMetadataRegistry.sol
function setMetadataURI(address token, string calldata uri) external {
    // @auditagent> Any caller claims metadata
    if (token.code.length == 0) revert TokenHasNoCode();
    if (metadataDecided[token]) revert AlreadySet();
    metadataDecided[token] = true;
    metadataURI[token] = uri;
```

#### Root Cause

Code existence and an unset entry are the only conditions on the write. For an already-deployed token whose entry is unset, an unrelated caller can submit a URI before the token's intended registrant. `metadataDecided` then prevents that registrant from correcting it. This is distinct from an inter-transaction attempt to preempt `createCurve`: a factory-launched TST is deployed and registered in one transaction.

#### Impact

Owners or intended registrants of independently deployed tokens, including directly deployed `TSTToken` instances, can permanently lose the ability to publish their intended URI in this registry. Consumers that treat its entry as authoritative may display attacker-chosen metadata. The demonstrated path affects already-deployed, unregistered tokens; it does not by itself preempt an atomic factory launch.

Severity Note:
- Attacker-chosen metadata is shown to users only if an external consumer treats this registry entry as authoritative. The registry stores a URI and does not change token ownership, balances, or protocol funds.

### 22. `graduate()` accepts a stale stock-denominated target after the stock’s USD price falls

**Severity:** Info  
**Contracts:** `src/curve/StocksCurve.sol`

#### Context

`StocksCurve` converts `graduationUsdThreshold` into an immutable `graduationStockTarget` using a signed stock/USD price at deployment. Later, `graduate()` permits graduation when the collected stock reaches that target.

```solidity
// File: src/curve/StocksCurve.sol
// @auditagent> Stale fixed graduation target
bool targetReached = realStockCollected >= graduationStockTarget;
bool soldOut = tokensSold >= (CURVE_SUPPLY * SOLDOUT_THRESHOLD_BPS) / BPS_DENOM;
if (!targetReached && !soldOut) revert NotReady();
```

#### Root Cause

The price timestamp is checked only in the constructor. Neither `buy()` nor `graduate()` obtains a fresh price before using `graduationStockTarget`. If the stock depreciates after launch, reaching the fixed number of stock tokens no longer implies reaching the configured USD threshold. This can trigger the target-based graduation path without relying on the separate sold-out condition.

#### Impact

The graduation stock target is fixed from the signed launch-time USD price and is not revalued if that price later falls. Reaching it can therefore seed the graduated pool with stock whose current USD value is below graduationUsdThreshold. Traders must still supply those stock tokens, no value is redirected to the caller, and the separate sold-out path can graduate without meeting the stock target.
