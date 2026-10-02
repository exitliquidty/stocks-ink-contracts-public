// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Stocks.ink. All rights reserved. No license to use, copy, modify, deploy or distribute this code is granted without the written permission of Stocks.ink.

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   S T O C K S . I N K                                            ║
// ║                                                                  ║
// ║   Tokenized Stock Treasuries (TSTs): the inverse of a Digital    ║
// ║   Asset Treasury (DAT).                                          ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// A TST turns its own trading volume into a growing on-chain treasury of
// tokenized equities, directed by its community and distributed to stakers.

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice The part of the hook the staking contract uses: placing and settling its liquidation order, and
/// reading the pool's cost settings for redemption.
interface IStocksHookMinimal {
    // A TWAMM order to place: sell `amountIn` of one currency evenly over `duration` seconds.
    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    // Identifies an order: its owner, when it ends, and which way it sells.
    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    // Which order, on which pool, to settle.
    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    // An order's live state inside the hook. `sellRate` is zero once the order no longer exists.
    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    /// @notice Length of a TWAMM interval, in seconds.
    function expirationInterval() external view returns (uint256);
    /// @notice Places a TWAMM order, pulling the tokens it sells from the caller.
    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);
    /// @notice Credits the order's owner with what the order has bought so far, net of the flywheel cost.
    function sync(SyncParams calldata params) external returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);
    /// @notice Pays the caller everything the hook owes it in the pool's two currencies.
    function claimTokensByPoolKey(PoolKey calldata key)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);
    /// @notice Reads an order's live state.
    function getOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory);

    /// @notice A pool's registration record: its tokens, treasury, protocol address and cost.
    function launches(PoolId poolId)
        external
        view
        returns (
            bool registered,
            bool tstIsCurrency0,
            address tstToken,
            address stockToken,
            address treasury,
            address protocol,
            uint256 feeBps
        );
    /// @notice The protocol's share of the flywheel cost, in basis points of the cost.
    function PROTOCOL_FEE_SHARE_BPS() external view returns (uint256);
}

/// @title StocksStaking
/// @notice A TST's treasury and its staking contract in one. It holds the tokenized stock that trading sends
/// here, streams that stock to TST stakers, lets any holder redeem TST for a share of what has not yet been
/// earned by stakers, and lets governance sell the unearned part to buy back and burn TST.
/// @dev One contract per token, deployed at graduation. How the pieces fit:
///
///  - Inflow. The hook transfers the treasury's share of every flywheel cost here as stock and calls
///    `notifyRewardAmount`. Any stock that arrives, from the hook or as a plain transfer, is treated the same
///    way: it is added to a reward stream.
///  - Rewards. A Synthetix-style stream: `rewardRate` stock per second until `periodFinish`, shared by stakers
///    in proportion to stake. An inflow of at least 1/100 of what is still left to stream restarts the period
///    (never shortening it), so a late large inflow cannot be captured by a stake that arrives just after it;
///    smaller inflows are added to the time remaining. While nobody is staked, time passes and that part of
///    the stream stays in the treasury unassigned. Staking has no lock.
///  - What belongs to whom. Stock already earned by stakers ("vested") is theirs and nothing else can touch
///    it. Everything else in the balance, which is the not-yet-vested stream plus anything unassigned, is the
///    redeemable treasury.
///  - Redemption. `redeem` burns the caller's TST and pays out the same fraction of the redeemable treasury
///    as that TST is of circulating supply, less the flywheel cost. The reward stream is shrunk by what left.
///  - Liquidation. Governance can commit the whole redeemable treasury to a TWAMM order that sells it for TST
///    over 1 to 30 days; the TST bought is burned.
///  - Governance. Three functions are restricted to the token's governor: pause or resume rewards, change the
///    reward period, liquidate. None of them can send funds to an address of the governor's choosing.
///
/// The invariant behind all of it: `lastNotifiedBalance >= vested rewards + stock still to be streamed`, so
/// stakers can always be paid what they have earned and the stream is always funded.
contract StocksStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @notice The token that is staked, and burned on redemption.
    IERC20 public immutable tstToken;
    /// @notice The tokenized stock the treasury holds and rewards are paid in.
    IERC20 public immutable stockToken;
    /// @notice Length of a reward period, in seconds. Applies to periods that start or restart from now on.
    uint256 public rewardsDuration;

    /// @notice The only address allowed to call the governed functions.
    address public immutable governor;
    /// @notice The v4 hook, through which liquidation orders are placed.
    address public immutable hook;
    /// @notice The token's curve: the only address allowed to set the pool, once, at graduation.
    address public immutable curve;

    /// @notice The token's v4 pool. Set once at graduation.
    PoolKey public poolKey;
    /// @notice Whether the stock token is the pool's currency0.
    bool public stockIsToken0;
    /// @dev True once `setPool` has run.
    bool private _poolSet;

    /// @dev Scale of the reward-per-token accumulator.
    uint256 private constant PRECISION = 1e18;
    /// @dev Basis-point denominator.
    uint256 private constant BPS_DENOM = 10_000;
    /// @dev Shortest reward period accepted by the constructor.
    uint256 private constant MIN_REWARDS_DURATION = 1 hours;

    /// @dev An inflow restarts the reward period if it is at least 1/100 of what is still left to stream. Below
    /// that it is added to the time remaining, so dust donations cannot keep pushing the period out.
    uint256 private constant MATERIAL_INFLOW_DIVISOR = 100;

    /// @notice Shortest reward period governance may set.
    uint256 public constant MIN_GOVERNABLE_REWARDS_DURATION = 1 days;
    /// @notice Longest reward period governance may set.
    uint256 public constant MAX_GOVERNABLE_REWARDS_DURATION = 365 days;

    /// @notice Longest a liquidation order may run. Without a cap one proposal could lock the treasury in an
    /// order for years, and an order cannot be cancelled.
    uint256 public constant MAX_LIQUIDATION_DURATION = 30 days;

    /// @notice Shortest order a liquidation proposal may create. The vendored TWAMM rounds a new order's virtual
    /// start down to the beginning of the CURRENT expirationInterval, not to the moment it was actually submitted:
    /// an order submitted moments before an interval boundary can have up to one whole interval's worth of its sell
    /// rate applied over that single already-elapsed (but not yet closed) interval, executing almost immediately
    /// instead of gradually. That worst case is at most one interval's share of the order regardless of duration, so
    /// bounding the order to span many intervals keeps it a small fraction of the total instead of nearly all of it.
    uint256 public constant MIN_LIQUIDATION_DURATION = 1 days;

    /// @notice Independent floor on the number of intervals a liquidation order must span, alongside
    /// MIN_LIQUIDATION_DURATION above. The wall-clock floor alone only bounds the front-load defect to
    /// "about 1/24" *because* the deploy config this was written against uses a 1-hour expirationInterval, so
    /// a 1-day minimum happens to mean 24 slices. Nothing forces that relationship: DeployFactoryV12 only caps
    /// expirationInterval at 30 days (so MAX_LIQUIDATION_DURATION stays reachable) with no floor tying it to
    /// this contract's own minimum. A generation deployed with, say, a 1-day expirationInterval would let
    /// durationIntervals = 1 satisfy the 1-day wall-clock floor while spanning exactly one interval -- zero
    /// gradual-selling protection, silently reopening the exact defect MIN_LIQUIDATION_DURATION exists to
    /// bound. Checking the interval count directly closes that regardless of expirationInterval's size. A
    /// no-op for the deployed 1-hour-interval generation (24 intervals * 1 hour is exactly the existing 1-day
    /// floor), so every existing liquidation scenario in this codebase is unaffected.
    uint256 public constant MIN_LIQUIDATION_INTERVALS = 24;

    /// @notice Where burned TST is sent.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice When the current or most recent liquidation order ends. Zero if there has never been one.
    uint160 public pendingLiquidationExpiration;

    /// @notice When the current reward period ends.
    uint256 public periodFinish;
    /// @notice Stock streamed to stakers per second during the current period.
    uint256 public rewardRate;
    /// @notice Last time the reward-per-token accumulator was brought up to date.
    uint256 public lastUpdateTime;
    /// @notice Cumulative reward per staked token as of `lastUpdateTime`, scaled by 1e18.
    uint256 public rewardPerTokenStored;
    /// @notice The part of the stock balance the reward accounting has recognised. Stock above this has arrived
    /// but has not yet been added to the stream.
    uint256 public lastNotifiedBalance;

    /// @notice Whether governance has paused the reward stream.
    bool public rewardsPaused;
    /// @notice The reward clock's value when the stream was paused. Zero when not paused.
    uint256 public pausedAt;
    /// @notice All stock ever added to the reward stream.
    uint256 public totalRewardsAdded;
    /// @notice All stock ever claimed by stakers.
    uint256 public totalRewardsClaimed;

    /// @notice Sum of every staker's settled, unclaimed reward (`rewards[account]`).
    uint256 public frozenRewardsTotal;
    /// @notice Sum over stakers of stake times reward-per-token already settled. Together with
    /// `frozenRewardsTotal` it gives total vested rewards without iterating over stakers.
    uint256 public sumBalanceTimesPaid;

    /// @notice Total TST staked.
    uint256 public totalStaked;
    /// @notice TST staked by each account.
    mapping(address => uint256) public balanceOf;
    /// @notice The reward-per-token value each account was last settled at.
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @notice Each account's settled, unclaimed reward.
    mapping(address => uint256) public rewards;

    /// @notice Emitted when TST is staked.
    /// @param user The staker.
    /// @param amount TST staked.
    event Staked(address indexed user, uint256 amount);
    /// @notice Emitted when TST is unstaked.
    /// @param user The staker.
    /// @param amount TST returned.
    event Unstaked(address indexed user, uint256 amount);
    /// @notice Emitted when a staker claims rewards.
    /// @param user The staker.
    /// @param amount Stock paid.
    event Claimed(address indexed user, uint256 amount);
    /// @notice Emitted when newly arrived stock is added to the reward stream.
    /// @param reward Stock added.
    event RewardAdded(uint256 reward);
    /// @notice Emitted when governance pauses or resumes rewards.
    /// @param paused The new state.
    event RewardsPausedSet(bool paused);
    /// @notice Emitted when governance changes the reward period.
    /// @param oldDuration The previous period, in seconds.
    /// @param newDuration The new period, in seconds.
    event RewardsDurationSet(uint256 oldDuration, uint256 newDuration);
    /// @notice Emitted when a liquidation order is placed.
    /// @param stockCommitted Stock committed to the order, before the protocol's share is taken from it.
    /// @param orderId The TWAMM order's id.
    /// @param duration The order's length, in seconds.
    event TreasuryLiquidationStarted(uint256 stockCommitted, bytes32 orderId, uint256 duration);
    /// @notice Emitted when liquidation proceeds are collected and burned.
    /// @param tstBurned TST burned.
    event TreasuryLiquidationClaimed(uint256 tstBurned);
    /// @notice Emitted when the pool is set at graduation.
    /// @param poolId The pool's id.
    event PoolSet(bytes32 indexed poolId);
    /// @notice Emitted on every redemption.
    /// @param redeemer The redeemer.
    /// @param tstBurned TST burned.
    /// @param stockOut Stock paid to the redeemer.
    /// @param protocolCut Stock paid to the protocol.
    /// @param retained Stock kept in the treasury as the rest of the flywheel cost.
    event Redeemed(address indexed redeemer, uint256 tstBurned, uint256 stockOut, uint256 protocolCut, uint256 retained);

    /// @notice An amount is zero.
    error ZeroAmount();
    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice The caller is unstaking more than it has staked.
    error InsufficientStake();
    /// @notice The constructor's reward period is under one hour.
    error RewardsDurationTooShort();
    /// @notice The caller is not the governor.
    error NotGovernor();
    /// @notice The caller is not the curve.
    error NotCurve();
    /// @notice The pool has already been set.
    error PoolAlreadySet();
    /// @notice The pool has not been set yet.
    error PoolNotSet();
    /// @notice There is no stock beyond what stakers have already earned.
    error NothingToLiquidate();
    /// @notice The liquidation would run longer than `MAX_LIQUIDATION_DURATION`.
    error LiquidationTooLong();
    /// @notice The liquidation would run for less than a day or span fewer than 24 intervals.
    error LiquidationTooShort();
    /// @notice The previous liquidation order has not ended yet.
    error LiquidationInProgress();
    /// @notice The reward period is outside 1 to 365 days or is not a whole number of days.
    error InvalidGovernableRewardsDuration();
    /// @notice The redemption would pay out nothing.
    error NothingToRedeem();
    /// @notice The redemption would pay less than the caller's minimum.
    error SlippageExceeded();
    /// @notice More TST is being redeemed than circulates.
    error RedeemExceedsSupply();

    /// @dev Restricts a function to the token's governor.
    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// @notice Deploys the treasury for one token.
    /// @param _tstToken The TST.
    /// @param _stockToken The tokenized stock.
    /// @param _rewardsDuration Initial reward period, at least one hour.
    /// @param _governor The token's governor.
    /// @param _hook The v4 hook.
    /// @param _curve The token's curve, which will set the pool.
    constructor(
        address _tstToken,
        address _stockToken,
        uint256 _rewardsDuration,
        address _governor,
        address _hook,
        address _curve
    ) {
        if (
            _tstToken == address(0) || _stockToken == address(0) || _governor == address(0)
                || _hook == address(0) || _curve == address(0)
        ) {
            revert ZeroAddress();
        }
        // The launch factory enforces its own, tighter range; this is the contract's last-resort floor.
        if (_rewardsDuration < MIN_REWARDS_DURATION) revert RewardsDurationTooShort();
        tstToken = IERC20(_tstToken);
        stockToken = IERC20(_stockToken);
        rewardsDuration = _rewardsDuration;
        governor = _governor;
        hook = _hook;
        curve = _curve;
    }

    /// @notice Records the token's v4 pool. Called once, by the curve, at graduation.
    /// @param key_ The pool key.
    function setPool(PoolKey calldata key_) external {
        if (msg.sender != curve) revert NotCurve();
        if (_poolSet) revert PoolAlreadySet();
        _poolSet = true;
        poolKey = key_;
        // Remember which side of the pool the stock is on: the liquidation order sells stock, so its direction
        // depends on this.
        stockIsToken0 = Currency.unwrap(key_.currency0) == address(stockToken);
        emit PoolSet(PoolId.unwrap(key_.toId()));
    }

    /// @dev The reward stream's clock: the current time, or the time rewards were paused while they are paused.
    /// @return The clock value.
    function _rewardClockNow() internal view returns (uint256) {
        return rewardsPaused ? pausedAt : block.timestamp;
    }

    /// @notice The latest time rewards have accrued up to: the reward clock, capped at the period's end.
    /// @return The timestamp.
    function lastTimeRewardApplicable() public view returns (uint256) {
        uint256 nowForRewards = _rewardClockNow();
        return nowForRewards < periodFinish ? nowForRewards : periodFinish;
    }

    /// @notice Cumulative reward per staked token up to now, scaled by 1e18.
    /// @dev Does not advance while nothing is staked, so stock streamed during that time is assigned to no one
    /// and stays in the redeemable treasury.
    /// @return The accumulator value.
    function rewardPerToken() public view returns (uint256) {
        // With nothing staked there is no one to credit, and dividing by zero is avoided.
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalStaked;
    }

    /// @notice Stock an account could claim right now.
    /// @param account The staker.
    /// @return The claimable amount.
    function pendingReward(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    /// @notice Stakes TST to earn a share of the reward stream. There is no lock.
    /// @dev Staked TST is held by this contract and carries no votes while it is here.
    /// @param amount TST to stake. Must be approved to this contract.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _notifyReward();
        _settle(msg.sender);

        // The account was just settled, so its paid marker is current. Adding stake raises the running sum by
        // stake * marker, which keeps `_earnedByStakers` exact.
        sumBalanceTimesPaid += amount * userRewardPerTokenPaid[msg.sender];
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        tstToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Returns staked TST. Rewards earned so far stay claimable.
    /// @param amount TST to unstake.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientStake();
        _notifyReward();
        _settle(msg.sender);

        // The mirror of `stake`: remove this stake's contribution from the running sum.
        sumBalanceTimesPaid -= amount * userRewardPerTokenPaid[msg.sender];
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        tstToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Pays the caller its earned stock.
    function claim() external nonReentrant {
        _notifyReward();
        _settle(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            frozenRewardsTotal -= reward;
            // The reward is leaving the contract, so the recognised balance drops with it. Otherwise the next arrival
            // would be under-counted by this amount.
            lastNotifiedBalance -= reward;
            totalRewardsClaimed += reward;
            stockToken.safeTransfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    /// @notice Adds any stock that has arrived since the last update to the reward stream.
    /// @dev Callable by anyone; the hook calls it after each transfer. It cannot be used to move funds.
    function notifyRewardAmount() external nonReentrant {
        _notifyReward();
    }

    /// @notice Pauses or resumes the reward stream. Governor only.
    /// @dev While paused nothing accrues and arriving stock is not added to the stream (it remains redeemable).
    /// On resume the period's end is pushed out by the length of the pause, so the paused time is not lost.
    /// @param paused True to pause, false to resume.
    function setRewardsPaused(bool paused) external onlyGovernor {
        if (paused == rewardsPaused) return;
        if (paused) {
            _notifyReward();
            rewardsPaused = true;
            // Freeze the reward clock at the point accrual was last brought up to date.
            pausedAt = lastUpdateTime;
        } else {
            // How long the stream was frozen.
            uint256 pauseDuration = block.timestamp - pausedAt;
            // A period was still running when rewards were paused: push its end, and the accrual marker, forward by the
            // length of the pause so that exactly the unstreamed remainder is still streamed.
            if (periodFinish > pausedAt) {
                periodFinish += pauseDuration;
                lastUpdateTime += pauseDuration;
            }
            rewardsPaused = false;
            pausedAt = 0;
            _notifyReward();
        }
        emit RewardsPausedSet(paused);
    }

    /// @notice Changes the reward period for future periods. Governor only.
    /// @dev Does not touch the period already running: a later restart runs over the longer of the new period
    /// and the time still left, so lowering the period can never speed up what is already streaming.
    /// @param newDuration The new period: a whole number of days, from 1 to 365.
    function setRewardsDuration(uint256 newDuration) external onlyGovernor {
        if (
            newDuration < MIN_GOVERNABLE_REWARDS_DURATION || newDuration > MAX_GOVERNABLE_REWARDS_DURATION
                || newDuration % 1 days != 0
        ) {
            revert InvalidGovernableRewardsDuration();
        }
        // Takes effect at the next period start or restart; the running period is left alone.
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @notice Sells the whole redeemable treasury for TST over time and burns the TST. Governor only.
    /// @dev Commits everything stakers have not yet earned to one TWAMM order on the token's own pool; the
    /// not-yet-vested reward stream is part of that and is wound down accordingly. Earned rewards are untouched.
    /// Only one order can run at a time, and an order cannot be cancelled. The order has no price limit: its
    /// protection is its duration. The longer it runs, the smaller each interval's slice is relative to the pool,
    /// and the less there is for anyone to gain by moving the price around it (see rounds 5 and 25 of the audit
    /// record).
    /// @param durationIntervals Length of the order in TWAMM intervals: at least 24 and one day, at most 30 days.
    /// @return stockCommitted Stock committed to the order.
    /// @return orderId The TWAMM order's id.
    function liquidateTreasury(uint256 durationIntervals)
        external
        nonReentrant
        onlyGovernor
        returns (uint256 stockCommitted, bytes32 orderId)
    {
        if (!_poolSet) revert PoolNotSet();
        if (durationIntervals == 0) revert ZeroAmount();
        // One order at a time. If the previous one has ended but its proceeds were never collected, collect and burn
        // them first so nothing is left behind in the hook.
        if (block.timestamp < pendingLiquidationExpiration) revert LiquidationInProgress();
        if (pendingLiquidationExpiration != 0) {
            IStocksHookMinimal.OrderKey memory oldOrderKey = IStocksHookMinimal.OrderKey({
                owner: address(this),
                expiration: pendingLiquidationExpiration,
                zeroForOne: stockIsToken0
            });
            if (IStocksHookMinimal(hook).getOrder(poolKey, oldOrderKey).sellRate != 0) {
                _claimLiquidatedTst();
            }
        }
        _notifyReward();

        uint256 balance = stockToken.balanceOf(address(this));
        if (balance == 0) revert NothingToLiquidate();

        // Time left on the running reward period, on the reward clock.
        uint256 remaining = _rewardClockNow() < periodFinish ? periodFinish - _rewardClockNow() : 0;
        // Stock stakers have already earned. Everything above it is committed.
        uint256 vestedButUnclaimed =
            (rewardPerTokenStored * totalStaked - sumBalanceTimesPaid) / PRECISION + frozenRewardsTotal;
        stockCommitted = balance > vestedButUnclaimed ? balance - vestedButUnclaimed : 0;
        if (stockCommitted == 0) revert NothingToLiquidate();

        // The order's length must be a whole number of TWAMM intervals, capped at 30 days.
        uint256 interval = IStocksHookMinimal(hook).expirationInterval();
        if (durationIntervals > MAX_LIQUIDATION_DURATION / interval) revert LiquidationTooLong();
        uint256 duration = interval * durationIntervals;
        // Both floors must hold: the wall-clock one (in case expirationInterval is small enough that many
        // intervals still add up to less than a day) and the interval-count one (see MIN_LIQUIDATION_INTERVALS'
        // own comment -- the one that actually matters when expirationInterval is large).
        if (duration < MIN_LIQUIDATION_DURATION || durationIntervals < MIN_LIQUIDATION_INTERVALS) {
            revert LiquidationTooShort();
        }
        // The hook pulls the protocol's share and the order's deposit from here; together at most `stockCommitted`.
        stockToken.forceApprove(hook, stockCommitted);
        IStocksHookMinimal.OrderKey memory orderKey;
        (orderId, orderKey) = IStocksHookMinimal(hook).submitOrder(
            IStocksHookMinimal.SubmitOrderParams({
                key: poolKey,
                zeroForOne: stockIsToken0,
                duration: duration,
                amountIn: stockCommitted
            })
        );
        // Remember the order so its proceeds can be collected and so a second order cannot overlap it.
        pendingLiquidationExpiration = orderKey.expiration;

        // The committed stock has left, and so has the stream it was funding.
        lastNotifiedBalance = balance - stockCommitted;

        if (remaining > 0) {
            uint256 outstanding = remaining * rewardRate;
            // The committed stock included whatever was still due to be streamed, so the stream is cut by that much.
            // In practice this zeroes the rate, since everything not yet vested was committed.
            uint256 reduction = stockCommitted < outstanding ? stockCommitted : outstanding;
            rewardRate = (outstanding - reduction) / remaining;
        }

        _notifyReward();

        emit TreasuryLiquidationStarted(stockCommitted, orderId, duration);
    }

    /// @notice Collects whatever the liquidation order has bought so far and burns it. Callable by anyone, at
    /// any time while the order exists.
    /// @return tstBurned TST burned by this call.
    function claimLiquidatedTst() external nonReentrant returns (uint256 tstBurned) {
        tstBurned = _claimLiquidatedTst();
    }

    /// @dev Settles the order in the hook, withdraws what is owed and burns the TST.
    /// @return tstBurned TST burned.
    function _claimLiquidatedTst() internal returns (uint256 tstBurned) {
        IStocksHookMinimal.OrderKey memory orderKey = IStocksHookMinimal.OrderKey({
            owner: address(this),
            expiration: pendingLiquidationExpiration,
            zeroForOne: stockIsToken0
        });
        IStocksHookMinimal(hook).sync(
            IStocksHookMinimal.SyncParams({key: poolKey, orderKey: orderKey})
        );
        (uint256 tokens0, uint256 tokens1) = IStocksHookMinimal(hook).claimTokensByPoolKey(poolKey);
        // The order sells stock, so what it bought is the pool's other currency: the TST.
        tstBurned = stockIsToken0 ? tokens1 : tokens0;
        if (tstBurned > 0) tstToken.safeTransfer(BURN_ADDRESS, tstBurned);

        emit TreasuryLiquidationClaimed(tstBurned);
    }

    /// @notice Stock a redemption can draw on: the balance minus everything stakers have already earned.
    /// @return The redeemable amount.
    function redeemableStock() public view returns (uint256) {
        uint256 balance = stockToken.balanceOf(address(this));
        uint256 earned = _earnedByStakers();
        return balance > earned ? balance - earned : 0;
    }

    /// @notice Circulating TST: total supply minus the burn address's balance.
    /// @dev Includes staked TST and TST sitting in the pool.
    /// @return The circulating supply.
    function nonBurnedSupply() public view returns (uint256) {
        return tstToken.totalSupply() - tstToken.balanceOf(BURN_ADDRESS);
    }

    /// @notice What redeeming `tstAmount` would pay right now.
    /// @param tstAmount TST to redeem.
    /// @return stockOut Stock the redeemer would receive.
    /// @return protocolCut Stock the protocol would receive.
    /// @return retained Stock that would stay in the treasury as the rest of the flywheel cost.
    function quoteRedeem(uint256 tstAmount) external view returns (uint256 stockOut, uint256 protocolCut, uint256 retained) {
        // A quote never reverts; it returns zeros where `redeem` would revert.
        if (!_poolSet || tstAmount == 0) return (0, 0, 0);
        uint256 supply = nonBurnedSupply();
        if (tstAmount > supply) return (0, 0, 0);
        (stockOut, protocolCut, retained,) = _redemptionAmounts(redeemableStock(), tstAmount, supply);
    }

    /// @notice Burns the caller's TST for its share of the redeemable treasury, paid in stock.
    /// @dev The share is `tstAmount / nonBurnedSupply()` of `redeemableStock()`, less the flywheel cost. The rate
    /// for holders who stay never falls as a result, because the cost's treasury share stays behind.
    /// @param tstAmount TST to burn. Must be approved to this contract.
    /// @param minStockOut Smallest acceptable payout.
    /// @return stockOut Stock paid to the caller.
    function redeem(uint256 tstAmount, uint256 minStockOut) external nonReentrant returns (uint256 stockOut) {
        if (!_poolSet) revert PoolNotSet();
        if (tstAmount == 0) revert ZeroAmount();
        _notifyReward();

        uint256 supply = nonBurnedSupply();
        if (tstAmount > supply) revert RedeemExceedsSupply();

        uint256 balance = stockToken.balanceOf(address(this));
        uint256 earned = _earnedByStakers();
        // Same figure `redeemableStock()` publishes, computed from the values already in hand.
        uint256 redeemable = balance > earned ? balance - earned : 0;

        uint256 protocolCut;
        uint256 retained;
        address protocol;
        (stockOut, protocolCut, retained, protocol) = _redemptionAmounts(redeemable, tstAmount, supply);
        if (stockOut == 0) revert NothingToRedeem();
        // Protects the caller if the redeemable treasury shrank between quoting and execution: rewards vesting to
        // stakers, a liquidation, or an earlier redemption.
        if (stockOut < minStockOut) revert SlippageExceeded();

        // Account for the stock about to leave before any transfer is made.
        _shrinkRewardsBy(stockOut + protocolCut, balance, earned);

        // The stock leaves BEFORE the TST is burned, on purpose. `quoteRedeem` / `redeemableStock` publish
        // treasury / non-burned supply through views that `nonReentrant` does not cover, and these three
        // transfers move the two sides of that ratio one at a time. Burning first shrank the denominator while
        // the stock was still here, so mid-call the views read a rate higher than any rate ever settled
        // (round 23: 10.13% too high on a 10%-of-supply redemption) -- the `get_virtual_price` shape. Paying
        // out first means every intermediate state reads at or BELOW the settled rate instead, which is the
        // harmless direction for anything that trusts the quote. Nothing is paid for free by the reordering:
        // the burn is in the same transaction and reverts all three transfers if it fails.
        stockToken.safeTransfer(msg.sender, stockOut);
        if (protocolCut > 0) stockToken.safeTransfer(protocol, protocolCut);
        tstToken.safeTransferFrom(msg.sender, BURN_ADDRESS, tstAmount);

        emit Redeemed(msg.sender, tstAmount, stockOut, protocolCut, retained);
    }

    /// @dev Total vested, unclaimed rewards across all stakers, computed without iterating. Rounds up relative
    /// to the sum of individual claims, so it never understates what stakers are owed.
    /// @return The vested total.
    function _earnedByStakers() internal view returns (uint256) {
        return (rewardPerToken() * totalStaked - sumBalanceTimesPaid) / PRECISION + frozenRewardsTotal;
    }

    /// @dev Splits a redemption's pro-rata share into what is paid out, what the protocol takes and what stays.
    /// The cost rounds up and the payout down.
    /// @param redeemable The redeemable treasury.
    /// @param tstAmount TST being redeemed.
    /// @param supply Circulating TST.
    /// @return stockOut Stock for the redeemer.
    /// @return protocolCut Stock for the protocol.
    /// @return retained Stock that stays in the treasury.
    /// @return protocol The protocol's address.
    function _redemptionAmounts(uint256 redeemable, uint256 tstAmount, uint256 supply)
        internal
        view
        returns (uint256 stockOut, uint256 protocolCut, uint256 retained, address protocol)
    {
        (, , , , , address protocol_, uint256 feeBps) = IStocksHookMinimal(hook).launches(poolKey.toId());
        // The protocol's share of the cost, as a rate on the gross amount (2% when the cost is 10%).
        uint256 protocolBps = (feeBps * IStocksHookMinimal(hook).PROTOCOL_FEE_SHARE_BPS()) / BPS_DENOM;

        // The redeemer's pro-rata share of the redeemable treasury, before the cost. Rounds down.
        uint256 gross = (redeemable * tstAmount) / supply;
        // The flywheel cost on that share. Rounds up, so the payout rounds down.
        uint256 cost = Math.ceilDiv(gross * feeBps, BPS_DENOM);
        if (cost > gross) cost = gross;
        // Of the cost, this part is paid out to the protocol...
        protocolCut = (gross * protocolBps) / BPS_DENOM;
        if (protocolCut > cost) protocolCut = cost;
        stockOut = gross - cost;
        // ...and this part never leaves: it stays in the treasury for the holders who remain.
        retained = cost - protocolCut;
        protocol = protocol_;
    }

    /// @dev Removes `amountOut` from the accounting when stock leaves through redemption. It is taken first from
    /// stock that is not funding the stream (unrecognised arrivals, then recognised stock beyond the stream) and
    /// only then from the stream itself, whose rate is lowered to match. Vested rewards are never touched.
    /// @param amountOut Stock leaving.
    /// @param balance The stock balance before it leaves.
    /// @param earned Vested rewards.
    function _shrinkRewardsBy(uint256 amountOut, uint256 balance, uint256 earned) internal {
        // What is still due to be streamed, on the reward clock.
        uint256 clockNow = _rewardClockNow();
        uint256 remaining = clockNow < periodFinish ? periodFinish - clockNow : 0;
        uint256 outstanding = remaining * rewardRate;

        // Recognised stock that stakers have not earned: the stream's funding plus any recognised surplus.
        uint256 registered = lastNotifiedBalance > earned ? lastNotifiedBalance - earned : 0;
        // Stock that has arrived but has not been recognised yet. It funds nothing, so it is used first.
        uint256 unregistered = balance > lastNotifiedBalance ? balance - lastNotifiedBalance : 0;
        // Everything redeemable that the stream does not depend on.
        uint256 notStreaming = unregistered + (registered > outstanding ? registered - outstanding : 0);

        // Only what cannot be covered from the above has to come out of the stream.
        uint256 fromStream = amountOut > notStreaming ? amountOut - notStreaming : 0;
        // Whatever is not covered by unrecognised stock comes out of the recognised balance.
        uint256 fromRegistered = amountOut - (amountOut < unregistered ? amountOut : unregistered);

        lastNotifiedBalance -= fromRegistered;
        // Lower the rate so that the stream pays out exactly what is still there to fund it.
        if (fromStream > 0 && remaining > 0) {
            if (fromStream > outstanding) fromStream = outstanding;
            rewardRate = (outstanding - fromStream) / remaining;
        }
    }

    /// @dev Brings the accumulator up to date, then adds any newly arrived stock to the stream. After the period
    /// has ended the inflow starts a new one. During a period a material inflow restarts it over the longer of
    /// `rewardsDuration` and the time left, and an immaterial one is spread over the time left. Does nothing
    /// with new stock while rewards are paused.
    function _notifyReward() internal {
        // Bring the accumulator up to date before anything that affects the rate.
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        // While paused, arriving stock is left unrecognised. It is picked up on resume.
        if (rewardsPaused) {
            return;
        }

        // Anything above the recognised balance is a new arrival. The amount is measured, never passed in, so a
        // caller cannot claim to have delivered more than actually arrived.
        uint256 currentBalance = stockToken.balanceOf(address(this));
        if (currentBalance <= lastNotifiedBalance) return;
        uint256 reward = currentBalance - lastNotifiedBalance;
        lastNotifiedBalance = currentBalance;

        // No period is running: the arrival starts a fresh one over the full duration.
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
            periodFinish = block.timestamp + rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            // What the running period still has to pay out.
            uint256 leftover = remaining * rewardRate;
            if (reward * MATERIAL_INFLOW_DIVISOR >= leftover) {
                // A restart must never SHORTEN the vesting of the existing leftover. Spreading it over a
                // longer window is exactly what makes the restart rule a defence against late staking: a
                // latecomer cannot capture what is already in the pot without staying for it. If governance
                // lowers `rewardsDuration` below the time left on the current period, restarting over the
                // raw new duration would compress that leftover instead, and since the restart trigger is
                // permissionless anyone could stake, force it, and collect the compressed stream. Taking
                // the longer of the two keeps the new duration in force for future periods while leaving
                // the current leftover on at least its original schedule.
                uint256 restartDuration = rewardsDuration > remaining ? rewardsDuration : remaining;
                rewardRate = (reward + leftover) / restartDuration;
                periodFinish = block.timestamp + restartDuration;
            } else {

                // An immaterial arrival does not move the period's end; it is spread over the time left. Anything lost to
                // the division stays in the treasury.
                rewardRate += reward / remaining;
            }
        }
        lastUpdateTime = block.timestamp;
        // Lifetime total, for monitoring and for the conservation invariants in the tests.
        totalRewardsAdded += reward;
        emit RewardAdded(reward);
    }

    /// @dev Moves an account's accrued reward into `rewards[account]` and updates the two running sums. Must be
    /// called before the account's stake changes.
    /// @param account The staker.
    function _settle(address account) internal {
        // Everything the account has earned up to now, at the current accumulator value.
        uint256 newPending = pendingReward(account);
        // Keep the two running sums in step with this account's settlement.
        frozenRewardsTotal = frozenRewardsTotal + newPending - rewards[account];
        rewards[account] = newPending;
        sumBalanceTimesPaid =
            sumBalanceTimesPaid + balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
