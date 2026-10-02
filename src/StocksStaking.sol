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

interface IStocksHookMinimal {
    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    function expirationInterval() external view returns (uint256);
    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);
    function sync(SyncParams calldata params) external returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);
    function claimTokensByPoolKey(PoolKey calldata key)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);
    function getOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory);

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
    function PROTOCOL_FEE_SHARE_BPS() external view returns (uint256);
}

contract StocksStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    IERC20 public immutable tstToken;
    IERC20 public immutable stockToken;
    uint256 public rewardsDuration;

    address public immutable governor;
    address public immutable hook;
    address public immutable curve;

    PoolKey public poolKey;
    bool public stockIsToken0;
    bool private _poolSet;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant MIN_REWARDS_DURATION = 1 hours;

    uint256 private constant MATERIAL_INFLOW_DIVISOR = 100;

    uint256 public constant MIN_GOVERNABLE_REWARDS_DURATION = 1 days;
    uint256 public constant MAX_GOVERNABLE_REWARDS_DURATION = 365 days;

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

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint160 public pendingLiquidationExpiration;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lastNotifiedBalance;

    bool public rewardsPaused;
    uint256 public pausedAt;
    uint256 public totalRewardsAdded;
    uint256 public totalRewardsClaimed;

    uint256 public frozenRewardsTotal;
    uint256 public sumBalanceTimesPaid;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 reward);
    event RewardsPausedSet(bool paused);
    event RewardsDurationSet(uint256 oldDuration, uint256 newDuration);
    event TreasuryLiquidationStarted(uint256 stockCommitted, bytes32 orderId, uint256 duration);
    event TreasuryLiquidationClaimed(uint256 tstBurned);
    event PoolSet(bytes32 indexed poolId);
    event Redeemed(address indexed redeemer, uint256 tstBurned, uint256 stockOut, uint256 protocolCut, uint256 retained);

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error RewardsDurationTooShort();
    error NotGovernor();
    error NotCurve();
    error PoolAlreadySet();
    error PoolNotSet();
    error NothingToLiquidate();
    error LiquidationTooLong();
    error LiquidationTooShort();
    error LiquidationInProgress();
    error InvalidGovernableRewardsDuration();
    error NothingToRedeem();
    error SlippageExceeded();
    error RedeemExceedsSupply();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

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
        if (_rewardsDuration < MIN_REWARDS_DURATION) revert RewardsDurationTooShort();
        tstToken = IERC20(_tstToken);
        stockToken = IERC20(_stockToken);
        rewardsDuration = _rewardsDuration;
        governor = _governor;
        hook = _hook;
        curve = _curve;
    }

    function setPool(PoolKey calldata key_) external {
        if (msg.sender != curve) revert NotCurve();
        if (_poolSet) revert PoolAlreadySet();
        _poolSet = true;
        poolKey = key_;
        stockIsToken0 = Currency.unwrap(key_.currency0) == address(stockToken);
        emit PoolSet(PoolId.unwrap(key_.toId()));
    }

    function _rewardClockNow() internal view returns (uint256) {
        return rewardsPaused ? pausedAt : block.timestamp;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        uint256 nowForRewards = _rewardClockNow();
        return nowForRewards < periodFinish ? nowForRewards : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalStaked;
    }

    function pendingReward(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _notifyReward();
        _settle(msg.sender);

        sumBalanceTimesPaid += amount * userRewardPerTokenPaid[msg.sender];
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        tstToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientStake();
        _notifyReward();
        _settle(msg.sender);

        sumBalanceTimesPaid -= amount * userRewardPerTokenPaid[msg.sender];
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        tstToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant {
        _notifyReward();
        _settle(msg.sender);

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            frozenRewardsTotal -= reward;
            lastNotifiedBalance -= reward;
            totalRewardsClaimed += reward;
            stockToken.safeTransfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    function notifyRewardAmount() external nonReentrant {
        _notifyReward();
    }

    function setRewardsPaused(bool paused) external onlyGovernor {
        if (paused == rewardsPaused) return;
        if (paused) {
            _notifyReward();
            rewardsPaused = true;
            pausedAt = lastUpdateTime;
        } else {
            uint256 pauseDuration = block.timestamp - pausedAt;
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

    function setRewardsDuration(uint256 newDuration) external onlyGovernor {
        if (
            newDuration < MIN_GOVERNABLE_REWARDS_DURATION || newDuration > MAX_GOVERNABLE_REWARDS_DURATION
                || newDuration % 1 days != 0
        ) {
            revert InvalidGovernableRewardsDuration();
        }
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    function liquidateTreasury(uint256 durationIntervals)
        external
        nonReentrant
        onlyGovernor
        returns (uint256 stockCommitted, bytes32 orderId)
    {
        if (!_poolSet) revert PoolNotSet();
        if (durationIntervals == 0) revert ZeroAmount();
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

        uint256 remaining = _rewardClockNow() < periodFinish ? periodFinish - _rewardClockNow() : 0;
        uint256 vestedButUnclaimed =
            (rewardPerTokenStored * totalStaked - sumBalanceTimesPaid) / PRECISION + frozenRewardsTotal;
        stockCommitted = balance > vestedButUnclaimed ? balance - vestedButUnclaimed : 0;
        if (stockCommitted == 0) revert NothingToLiquidate();

        uint256 interval = IStocksHookMinimal(hook).expirationInterval();
        if (durationIntervals > MAX_LIQUIDATION_DURATION / interval) revert LiquidationTooLong();
        uint256 duration = interval * durationIntervals;
        // Both floors must hold: the wall-clock one (in case expirationInterval is small enough that many
        // intervals still add up to less than a day) and the interval-count one (see MIN_LIQUIDATION_INTERVALS'
        // own comment -- the one that actually matters when expirationInterval is large).
        if (duration < MIN_LIQUIDATION_DURATION || durationIntervals < MIN_LIQUIDATION_INTERVALS) {
            revert LiquidationTooShort();
        }
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
        pendingLiquidationExpiration = orderKey.expiration;

        lastNotifiedBalance = balance - stockCommitted;

        if (remaining > 0) {
            uint256 outstanding = remaining * rewardRate;
            uint256 reduction = stockCommitted < outstanding ? stockCommitted : outstanding;
            rewardRate = (outstanding - reduction) / remaining;
        }

        _notifyReward();

        emit TreasuryLiquidationStarted(stockCommitted, orderId, duration);
    }

    function claimLiquidatedTst() external nonReentrant returns (uint256 tstBurned) {
        tstBurned = _claimLiquidatedTst();
    }

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
        tstBurned = stockIsToken0 ? tokens1 : tokens0;
        if (tstBurned > 0) tstToken.safeTransfer(BURN_ADDRESS, tstBurned);

        emit TreasuryLiquidationClaimed(tstBurned);
    }

    function redeemableStock() public view returns (uint256) {
        uint256 balance = stockToken.balanceOf(address(this));
        uint256 earned = _earnedByStakers();
        return balance > earned ? balance - earned : 0;
    }

    function nonBurnedSupply() public view returns (uint256) {
        return tstToken.totalSupply() - tstToken.balanceOf(BURN_ADDRESS);
    }

    function quoteRedeem(uint256 tstAmount) external view returns (uint256 stockOut, uint256 protocolCut, uint256 retained) {
        if (!_poolSet || tstAmount == 0) return (0, 0, 0);
        uint256 supply = nonBurnedSupply();
        if (tstAmount > supply) return (0, 0, 0);
        (stockOut, protocolCut, retained,) = _redemptionAmounts(redeemableStock(), tstAmount, supply);
    }

    function redeem(uint256 tstAmount, uint256 minStockOut) external nonReentrant returns (uint256 stockOut) {
        if (!_poolSet) revert PoolNotSet();
        if (tstAmount == 0) revert ZeroAmount();
        _notifyReward();

        uint256 supply = nonBurnedSupply();
        if (tstAmount > supply) revert RedeemExceedsSupply();

        uint256 balance = stockToken.balanceOf(address(this));
        uint256 earned = _earnedByStakers();
        uint256 redeemable = balance > earned ? balance - earned : 0;

        uint256 protocolCut;
        uint256 retained;
        address protocol;
        (stockOut, protocolCut, retained, protocol) = _redemptionAmounts(redeemable, tstAmount, supply);
        if (stockOut == 0) revert NothingToRedeem();
        if (stockOut < minStockOut) revert SlippageExceeded();

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

    function _earnedByStakers() internal view returns (uint256) {
        return (rewardPerToken() * totalStaked - sumBalanceTimesPaid) / PRECISION + frozenRewardsTotal;
    }

    function _redemptionAmounts(uint256 redeemable, uint256 tstAmount, uint256 supply)
        internal
        view
        returns (uint256 stockOut, uint256 protocolCut, uint256 retained, address protocol)
    {
        (, , , , , address protocol_, uint256 feeBps) = IStocksHookMinimal(hook).launches(poolKey.toId());
        uint256 protocolBps = (feeBps * IStocksHookMinimal(hook).PROTOCOL_FEE_SHARE_BPS()) / BPS_DENOM;

        uint256 gross = (redeemable * tstAmount) / supply;
        uint256 cost = Math.ceilDiv(gross * feeBps, BPS_DENOM);
        if (cost > gross) cost = gross;
        protocolCut = (gross * protocolBps) / BPS_DENOM;
        if (protocolCut > cost) protocolCut = cost;
        stockOut = gross - cost;
        retained = cost - protocolCut;
        protocol = protocol_;
    }

    function _shrinkRewardsBy(uint256 amountOut, uint256 balance, uint256 earned) internal {
        uint256 clockNow = _rewardClockNow();
        uint256 remaining = clockNow < periodFinish ? periodFinish - clockNow : 0;
        uint256 outstanding = remaining * rewardRate;

        uint256 registered = lastNotifiedBalance > earned ? lastNotifiedBalance - earned : 0;
        uint256 unregistered = balance > lastNotifiedBalance ? balance - lastNotifiedBalance : 0;
        uint256 notStreaming = unregistered + (registered > outstanding ? registered - outstanding : 0);

        uint256 fromStream = amountOut > notStreaming ? amountOut - notStreaming : 0;
        uint256 fromRegistered = amountOut - (amountOut < unregistered ? amountOut : unregistered);

        lastNotifiedBalance -= fromRegistered;
        if (fromStream > 0 && remaining > 0) {
            if (fromStream > outstanding) fromStream = outstanding;
            rewardRate = (outstanding - fromStream) / remaining;
        }
    }

    function _notifyReward() internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (rewardsPaused) {
            return;
        }

        uint256 currentBalance = stockToken.balanceOf(address(this));
        if (currentBalance <= lastNotifiedBalance) return;
        uint256 reward = currentBalance - lastNotifiedBalance;
        lastNotifiedBalance = currentBalance;

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
            periodFinish = block.timestamp + rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
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

                rewardRate += reward / remaining;
            }
        }
        lastUpdateTime = block.timestamp;
        totalRewardsAdded += reward;
        emit RewardAdded(reward);
    }

    function _settle(address account) internal {
        uint256 newPending = pendingReward(account);
        frozenRewardsTotal = frozenRewardsTotal + newPending - rewards[account];
        rewards[account] = newPending;
        sumBalanceTimesPaid =
            sumBalanceTimesPaid + balanceOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
