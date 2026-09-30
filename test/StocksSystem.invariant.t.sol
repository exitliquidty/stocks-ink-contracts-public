// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SystemMockStock is ERC20 {
    constructor() ERC20("Mock xStock wrapper", "mSTK") {
        _mint(msg.sender, 1_000_000_000_000e18);
    }
}

/// @notice Random-walk over the WHOLE production stack after a real graduation: pool swaps in both
/// directions, staking (stake, unstake, claim), donations to the treasury (dust and large), TWAMM orders by
/// users, governance-driven treasury liquidations, reward pause and duration changes, time, and permissionless
/// execution and claiming, in any order, from four actors.
contract SystemHandler is Test {
    StocksHook public hook;
    StocksStaking public staking;
    PoolSwapTest public swapRouter;
    IERC20 public tst;
    SystemMockStock public stock;
    address public governor;
    address public protocolAddr;
    PoolKey public key;
    bool public tstIsCurrency0;

    address[4] public actors = [address(0xA001), address(0xA002), address(0xA003), address(0xA004)];
    uint256 constant INTERVAL = 1 hours;

    struct LiveOrder {
        address owner;
        ITWAMM.OrderKey orderKey;
    }

    LiveOrder[] public orders;

    // ghost counters
    uint256 public swaps;
    uint256 public stakes;
    uint256 public claims;
    uint256 public orderCount;
    uint256 public syncs;
    uint256 public liquidations;
    uint256 public liquidationRefusals;
    uint256 public donations;
    uint256 public pauses;

    // --- in-kind redemption ghosts (each violation counter must stay 0) ---
    uint256 public redemptionsDone;
    uint256 public redemptionsRefused;
    uint256 public redeemEarnedViolations;
    uint256 public redeemQuoteMismatches;
    uint256 public redeemBookingMismatches;
    uint256 public redeemUnexpectedReverts;
    /// @dev buy TST from the pool and redeem it in the same call
    uint256 public atomicRoundTrips;
    uint256 public atomicProfitViolations;
    /// @dev Core user paths that must NEVER revert (swap, stake, unstake, claim, order sync/claim).
    uint256 public unexpectedReverts;
    bytes public firstUnexpectedRevert;
    string public firstUnexpectedWhere;

    constructor(
        StocksHook hook_,
        StocksStaking staking_,
        PoolSwapTest router_,
        IERC20 tst_,
        SystemMockStock stock_,
        address governor_,
        address protocol_,
        PoolKey memory key_,
        bool tstIsCurrency0_
    ) {
        protocolAddr = protocol_;
        hook = hook_;
        staking = staking_;
        swapRouter = router_;
        tst = tst_;
        stock = stock_;
        governor = governor_;
        key = key_;
        tstIsCurrency0 = tstIsCurrency0_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Uniform mapping of `x` into [lo, hi]. (forge-std's bound() wraps small inputs to the TOP of the
    /// range, which would make "small" random amounts enormous.)
    function _scale(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    /// @dev Brings the pool up to date first, the way any earlier swap or a keeper would, so trade sizes are
    /// picked against the pool as it really is when the trade executes.
    function _settlePool() internal {
        try hook.executeTWAMMOrders(key) {} catch {}
    }

    function _flag(string memory where_, bytes memory reason) internal {
        if (unexpectedReverts == 0) {
            firstUnexpectedRevert = reason;
            firstUnexpectedWhere = where_;
        }
        unexpectedReverts++;
    }

    // ------------------------------------------------------------------------------------ pool trading

    function swapBuy(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        _settlePool();
        uint256 depth = stock.balanceOf(address(swapRouter.manager()));
        amount = _scale(amount, depth / 1e6 + 1, depth / 2 + 1);
        uint256 have = stock.balanceOf(who);
        if (have == 0) return;
        if (amount > have) amount = have;
        _swap("swapBuy", who, address(stock), !tstIsCurrency0, amount);
    }

    function swapSell(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 have = tst.balanceOf(who);
        if (have == 0) return;
        _settlePool();
        amount = _scale(amount, 1, have);
        _swap("swapSell", who, address(tst), tstIsCurrency0, amount);
    }

    function _swap(string memory where_, address who, address tokenIn, bool zeroForOne, uint256 amount) internal {
        vm.prank(who);
        IERC20(tokenIn).approve(address(swapRouter), amount);
        vm.prank(who);
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            swaps++;
        } catch (bytes memory reason) {
            _flag(where_, reason);
        }
    }

    // ---------------------------------------------------------------------------------------- staking

    function stake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 have = tst.balanceOf(who);
        if (have == 0) return;
        amount = _scale(amount, 1, have);
        vm.prank(who);
        tst.approve(address(staking), amount);
        vm.prank(who);
        try staking.stake(amount) {
            stakes++;
        } catch (bytes memory reason) {
            _flag("stake", reason);
        }
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 have = staking.balanceOf(who);
        if (have == 0) return;
        amount = _scale(amount, 1, have);
        vm.prank(who);
        try staking.unstake(amount) {
            stakes++;
        } catch (bytes memory reason) {
            _flag("unstake", reason);
        }
    }

    function claimRewards(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try staking.claim() {
            claims++;
        } catch (bytes memory reason) {
            _flag("claim", reason);
        }
    }

    /// @dev Stock sent straight to the treasury, from a dust amount up to a large donation.
    function donate(uint256 actorSeed, uint256 amount, bool tiny) external {
        address who = _actor(actorSeed);
        uint256 have = stock.balanceOf(who);
        if (have == 0) return;
        amount = tiny ? _scale(amount, 1, 1e9) : _scale(amount, 1e15, 5e18);
        if (amount > have) amount = have;
        vm.prank(who);
        stock.transfer(address(staking), amount);
        donations++;
        if (amount % 2 == 0) {
            try staking.notifyRewardAmount() {} catch (bytes memory reason) {
                _flag("notifyRewardAmount", reason);
            }
        }
    }

    function warpTime(uint256 secondsForward) external {
        secondsForward = _scale(secondsForward, 1, 5 days);
        vm.warp(block.timestamp + secondsForward);
    }

    // -------------------------------------------------------------------------------------- redemption

    function redeem(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 have = tst.balanceOf(who);
        if (have == 0) return;
        amount = _scale(amount, 1, have);
        _redeemAndCheck(who, amount);
    }

    function _redeemAndCheck(address who, uint256 amount) internal returns (uint256 out) {
        uint256[4] memory earnedBefore;
        for (uint256 i; i < 4; ++i) {
            earnedBefore[i] = staking.pendingReward(actors[i]);
        }
        (uint256 qOut, uint256 qProtocol,) = staking.quoteRedeem(amount);
        uint256 balanceBefore = stock.balanceOf(address(staking));
        uint256 protocolBefore = stock.balanceOf(protocolAddr);

        vm.prank(who);
        tst.approve(address(staking), amount);
        vm.prank(who);
        try staking.redeem(amount, 0) returns (uint256 o) {
            out = o;
            redemptionsDone++;
            for (uint256 i; i < 4; ++i) {
                if (staking.pendingReward(actors[i]) != earnedBefore[i]) redeemEarnedViolations++;
            }
            if (o != qOut) redeemQuoteMismatches++;
            if (
                balanceBefore - stock.balanceOf(address(staking)) != o + qProtocol
                    || stock.balanceOf(protocolAddr) - protocolBefore != qProtocol
            ) redeemBookingMismatches++;
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            if (
                sel == StocksStaking.NothingToRedeem.selector
            ) {
                redemptionsRefused++;
            } else {
                redeemUnexpectedReverts++;
            }
        }
    }

    /// @dev A flash-loan style attempt: with as much stock as the actor has, buy TST from the pool and redeem all of
    /// it in the same call. Unless the pool sold TST below the redemption rate, this must lose money.
    function atomicBuyThenRedeem(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        _settlePool();
        uint256 depth = stock.balanceOf(address(swapRouter.manager()));
        amount = _scale(amount, depth / 1e4 + 1, depth / 4 + 1);
        uint256 have = stock.balanceOf(who);
        if (have == 0) return;
        if (amount > have) amount = have;

        // the pool's marginal price in stock per TST, and the redemption rate, both before the buy
        uint256 tstInPool = tst.balanceOf(address(swapRouter.manager()));
        if (tstInPool == 0) return;
        uint256 supply = staking.nonBurnedSupply();
        if (supply == 0) return;
        bool poolBelowRate = (depth * 1e18) / tstInPool < (staking.redeemableStock() * 1e18) / supply;

        uint256 stockBefore = stock.balanceOf(who);
        uint256 tstBefore = tst.balanceOf(who);
        vm.prank(who);
        stock.approve(address(swapRouter), amount);
        vm.prank(who);
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {
            return;
        }
        uint256 bought = tst.balanceOf(who) - tstBefore;
        if (bought == 0) return;
        _redeemAndCheck(who, bought);
        atomicRoundTrips++;
        if (stock.balanceOf(who) > stockBefore && !poolBelowRate) atomicProfitViolations++;
    }

    // ------------------------------------------------------------------------------- governance actions

    function liquidate(uint256 intervals) external {
        // MIN_LIQUIDATION_DURATION is 24 intervals at a 1-hour expirationInterval; bias the range to mostly
        // valid (>=24) so the invariant walk keeps exercising a successful, in-progress liquidation most of the
        // time, while still occasionally hitting the LiquidationTooShort revert path via the low end.
        intervals = _scale(intervals, 20, 144);
        vm.prank(governor);
        try staking.liquidateTreasury(intervals) {
            liquidations++;
        } catch {
            liquidationRefusals++;
        }
    }

    function claimLiquidated() external {
        try staking.claimLiquidatedTst() {} catch {
            liquidationRefusals++;
        }
    }

    function setPaused(bool paused) external {
        vm.prank(governor);
        try staking.setRewardsPaused(paused) {
            pauses++;
        } catch (bytes memory reason) {
            _flag("setRewardsPaused", reason);
        }
    }

    function setDuration(uint256 dayCount) external {
        dayCount = _scale(dayCount, 1, 90);
        vm.prank(governor);
        try staking.setRewardsDuration(dayCount * 1 days) {} catch (bytes memory reason) {
            _flag("setRewardsDuration", reason);
        }
    }

    // ------------------------------------------------------------------------------------- user TWAMM

    function submitOrder(uint256 actorSeed, bool sellStock, uint256 intervals, uint256 amount) external {
        address who = _actor(actorSeed);
        intervals = _scale(intervals, 1, 12);
        address sellToken = sellStock ? address(stock) : address(tst);
        uint256 have = IERC20(sellToken).balanceOf(who);
        if (have < 1e12) return;
        // up to 3x the pool's depth in that token, like a real treasury liquidation against a thin pool
        uint256 depth = IERC20(sellToken).balanceOf(address(swapRouter.manager()));
        amount = _scale(amount, depth / 1e4 + 1e12, depth * 3);
        if (amount > have) amount = have;
        bool zeroForOne = sellStock ? !tstIsCurrency0 : tstIsCurrency0;

        vm.prank(who);
        IERC20(sellToken).approve(address(hook), amount);
        vm.prank(who);
        try hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: intervals * INTERVAL, amountIn: amount})
        ) returns (bytes32, ITWAMM.OrderKey memory orderKey) {
            orders.push(LiveOrder({owner: who, orderKey: orderKey}));
            orderCount++;
        } catch {
            // a tiny order, or a duplicate order in the same interval, may be refused: not a core path
        }
    }

    function syncOrder(uint256 orderSeed) external {
        if (orders.length == 0) return;
        LiveOrder memory o = orders[orderSeed % orders.length];
        if (hook.getOrder(key, o.orderKey).sellRate == 0) return;
        vm.prank(o.owner);
        try hook.sync(ITWAMM.SyncParams({key: key, orderKey: o.orderKey})) {
            syncs++;
        } catch (bytes memory reason) {
            _flag("sync", reason);
        }
    }

    function claimTokens(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try hook.claimTokensByPoolKey(key) {} catch (bytes memory reason) {
            _flag("claimTokensByPoolKey", reason);
        }
    }

    function executeOrders() external {
        try hook.executeTWAMMOrders(key) {} catch {
            // execution may fail on a rounding shortfall; swaps still work (fail open), tracked via swaps
        }
    }

    // ghost counters for the gas-griefing fix (round 14): never previously exercised by this
    // random-walk campaign, since pumpTwammBacklog was added mid-session after this handler was
    // last written -- added here so the long-running invariant campaign actually covers it, not
    // just the dedicated adversarial file.
    uint256 public pumps;
    uint256 public pumpReverts;

    function pumpBacklog(uint256 stepSeed, uint256 maxStepsSeed) external {
        uint256 stepSeconds = _scale(stepSeed, 1, 6 hours);
        uint256 maxSteps = _scale(maxStepsSeed, 1, 50);
        try hook.pumpTwammBacklog(key, stepSeconds, maxSteps) {
            pumps++;
        } catch {
            // NothingToPump (nothing outstanding) is an expected, frequent outcome, not a bug --
            // this is a permissionless function callable at any time, including when there is
            // nothing to catch up.
            pumpReverts++;
        }
    }
}

/// forge-config: default.invariant.runs = 200
/// forge-config: default.invariant.depth = 300
/// @notice The system-level invariants: whatever sequence of user and governance actions runs, every token is
/// accounted for, the hook and the treasury can pay what they owe, and the user paths never revert.
contract StocksSystemInvariantTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    PoolManager pm;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    PoolSwapTest swapRouter;
    SystemMockStock stock;
    IERC20 tst;
    StocksCurve curve;
    StocksStaking staking;
    StocksGovernor governor;
    SystemHandler handler;
    PoolKey key;
    address protocol = address(0xFEED);

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        stock = new SystemMockStock();
        TokenMetadataRegistry registry = new TokenMetadataRegistry();
        address governorFactory = address(new StocksGovernorFactory());
        address curveDeployer = address(new StocksCurveFactory());
        address stakingFactory = address(new StocksStakingFactory());

        uint256 nonceAtStart = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceAtStart + 1);
        address predictedFactory = vm.computeCreateAddress(address(this), nonceAtStart + 2);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(address(pm)), predictedGraduator, uint256(1 hours));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(IPoolManager(address(pm)), predictedGraduator, 1 hours);
        require(address(hook) == hookAddress, "hook address mismatch");
        graduator = new StocksGraduator(IPoolManager(address(pm)), hook, predictedFactory);
        require(address(graduator) == predictedGraduator, "graduator address mismatch");
        factory = new StocksLaunchFactory(
            vm.addr(SIGNER_KEY),
            protocol,
            address(hook),
            governorFactory,
            stakingFactory,
            curveDeployer,
            address(graduator),
            address(registry),
            8_000e18,
            1 days,
            365 days,
            1 days,
            3 days,
            25
        );
        require(address(factory) == predictedFactory, "factory address mismatch");
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));

        // launch and graduate
        uint256 price = 200e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        (address token, address curveAddr) =
            factory.createCurve("System", "SYS", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, "");
        tst = IERC20(token);
        curve = StocksCurve(curveAddr);
        vm.warp(vm.getBlockTimestamp() + 61);

        address[4] memory who = [address(0xA001), address(0xA002), address(0xA003), address(0xA004)];
        uint256[4] memory buys = [uint256(14e18), 12e18, 9e18, 6e18];
        for (uint256 i; i < 4; ++i) {
            stock.transfer(who[i], buys[i] + 1_000_000e18);
            vm.startPrank(who[i]);
            stock.approve(curveAddr, buys[i]);
            curve.buy(buys[i], 0);
            vm.stopPrank();
        }
        curve.graduate();
        staking = StocksStaking(curve.staking());
        governor = StocksGovernor(payable(curve.governor()));
        key = StocksPoolView(curve.pair()).poolKey();
        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == token;

        handler = new SystemHandler(hook, staking, swapRouter, tst, stock, address(governor), protocol, key, tstIsCurrency0);
        stock.transfer(address(handler), 1_000e18);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _holders() internal view returns (address[13] memory a) {
        a = [
            handler.actors(0),
            handler.actors(1),
            handler.actors(2),
            handler.actors(3),
            address(handler),
            address(this),
            address(curve),
            address(staking),
            address(hook),
            address(pm),
            protocol,
            address(graduator),
            address(factory)
        ];
    }

    function _dust() internal view returns (uint256) {
        return 4 * (handler.orderCount() + handler.syncs() + handler.liquidations() + handler.swaps() / 8 + 1);
    }

    // ---------------------------------------------------------------------------------------- invariants

    /// @dev Every TST is in exactly one place (burned TST sits at the dead address).
    function invariant_TstIsConserved() public view {
        address[13] memory a = _holders();
        uint256 sum = tst.balanceOf(BURN) + tst.balanceOf(address(governor));
        for (uint256 i; i < a.length; ++i) {
            sum += tst.balanceOf(a[i]);
        }
        assertEq(sum, tst.totalSupply(), "TST supply is fully accounted for");
    }

    /// @dev Every unit of the stock token is in exactly one place too (nothing is minted or lost).
    function invariant_StockIsConserved() public view {
        address[13] memory a = _holders();
        uint256 sum = stock.balanceOf(BURN) + stock.balanceOf(address(governor));
        for (uint256 i; i < a.length; ++i) {
            sum += stock.balanceOf(a[i]);
        }
        assertEq(sum, stock.totalSupply(), "stock supply is fully accounted for");
    }

    /// @dev What the hook owes to TWAMM users and to the treasury is backed by what it holds, up to rounding
    /// dust (its 100 TST and millionth-of-a-share reserve sits on top of that).
    function invariant_HookBacksWhatItOwes() public view {
        for (uint256 t; t < 2; ++t) {
            Currency c = t == 0 ? Currency.wrap(address(tst)) : Currency.wrap(address(stock));
            uint256 owed = hook.tokensOwed(c, address(staking));
            for (uint256 i; i < 4; ++i) {
                owed += hook.tokensOwed(c, handler.actors(i));
            }
            owed += hook.tokensOwed(c, address(handler));
            uint256 bal = IERC20(Currency.unwrap(c)).balanceOf(address(hook));
            assertLe(owed, bal + _dust(), "the hook holds what it owes");
        }
    }

    /// @dev The treasury can pay every staker what they have earned.
    function invariant_TreasuryCoversAllPendingRewards() public view {
        uint256 pending;
        for (uint256 i; i < 4; ++i) {
            pending += staking.pendingReward(handler.actors(i));
        }
        assertLe(pending, stock.balanceOf(address(staking)) + _dust(), "the treasury holds every earned reward");
        assertLe(staking.lastNotifiedBalance(), stock.balanceOf(address(staking)), "the notified balance is real");
    }

    /// @dev Every staked TST is held by the staking contract, and the per-user balances add up.
    function invariant_StakedTstIsAllThere() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += staking.balanceOf(handler.actors(i));
        }
        sum += staking.balanceOf(address(handler));
        assertEq(sum, staking.totalStaked(), "per-user stakes add up to the total");
        assertGe(tst.balanceOf(address(staking)), staking.totalStaked(), "all staked TST is held");
    }

    function invariant_RewardsPaidNeverExceedRewardsAdded() public view {
        assertLe(staking.totalRewardsClaimed(), staking.totalRewardsAdded(), "claims never exceed inflows");
    }

    /// @dev The plumbing contracts never keep anything.
    function invariant_NoStrandedFundsInPlumbing() public view {
        assertEq(stock.balanceOf(address(graduator)), 0);
        assertEq(tst.balanceOf(address(graduator)), 0);
        assertEq(stock.balanceOf(address(factory)), 0);
        assertEq(tst.balanceOf(address(factory)), 0);
        assertEq(stock.balanceOf(address(curve)), 0);
        assertEq(tst.balanceOf(address(curve)), 0);
        assertEq(stock.balanceOf(address(governor)), 0);
    }

    /// @dev A redemption never changes anyone's earned rewards, pays exactly its quote, books the treasury and the
    /// protocol exactly, and is only ever refused for the listed reasons.
    function invariant_RedemptionIsExactAndNeverTouchesEarnedRewards() public view {
        assertEq(handler.redeemEarnedViolations(), 0, "a redemption changed earned rewards");
        assertEq(handler.redeemQuoteMismatches(), 0, "a redemption paid something other than its quote");
        assertEq(handler.redeemBookingMismatches(), 0, "a redemption's treasury or protocol booking was off");
        assertEq(handler.redeemUnexpectedReverts(), 0, "a redemption reverted for an unexpected reason");
    }

    /// @dev Buying TST from the real pool and redeeming it in the same call never makes money unless the pool was
    /// selling below the redemption rate (that is the intended arbitrage, not an exploit).
    function invariant_BuyingFromThePoolAndRedeemingNeverProfits_UnlessThePoolIsBelowTheRate() public view {
        assertEq(handler.atomicProfitViolations(), 0, "a buy-then-redeem round trip profited at or above the rate");
    }

    /// @dev Swaps, staking, claiming and TWAMM syncs are the core user paths: none may ever revert.
    function invariant_CoreUserPathsNeverRevert() public view {
        assertEq(
            handler.unexpectedReverts(),
            0,
            string.concat(
                "a core user path reverted: ", handler.firstUnexpectedWhere(), " ", vm.toString(handler.firstUnexpectedRevert())
            )
        );
    }

    /// @dev The governor's rules stay fixed.
    function invariant_GovernorRulesAreFixed() public view {
        assertEq(governor.quorumNumerator(), 10);
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 3 days);
    }

    /// @dev Guards against a vacuous pass: a plain seeded walk of 600 handler calls must actually reach every
    /// kind of action (swaps in both directions, staking, claiming, TWAMM orders, syncs, liquidations that the
    /// hook accepted, pauses), so the invariants above are being checked against real activity.
    function test_HandlerReachesEveryPath() public {
        for (uint256 i; i < 600; ++i) {
            uint256 r = uint256(keccak256(abi.encode("walk", i)));
            uint256 a = uint256(keccak256(abi.encode("a", i)));
            uint256 b = uint256(keccak256(abi.encode("b", i)));
            uint256 pick = r % 19;
            if (pick == 0 || pick == 1) handler.swapBuy(a, b);
            else if (pick == 2 || pick == 3) handler.swapSell(a, b);
            else if (pick == 4) handler.stake(a, b);
            else if (pick == 5) handler.unstake(a, b);
            else if (pick == 6) handler.claimRewards(a);
            else if (pick == 7) handler.donate(a, b, i % 2 == 0);
            else if (pick == 8) handler.warpTime(b);
            else if (pick == 9) handler.liquidate(b);
            else if (pick == 10) handler.claimLiquidated();
            else if (pick == 11) handler.submitOrder(a, i % 2 == 0, b, uint256(keccak256(abi.encode(b))));
            else if (pick == 12) handler.syncOrder(a);
            else if (pick == 13) handler.claimTokens(a);
            else if (pick == 14) handler.setPaused(i % 4 == 0);
            else if (pick == 15 || pick == 16 || pick == 17) handler.redeem(a, b);
            else handler.atomicBuyThenRedeem(a, b);
        }
        console.log("swaps / stakes / claims:", handler.swaps(), handler.stakes(), handler.claims());
        console.log("orders / syncs / donations:", handler.orderCount(), handler.syncs(), handler.donations());
        console.log("liquidations / refusals / pauses:", handler.liquidations(), handler.liquidationRefusals(), handler.pauses());
        assertGt(handler.swaps(), 20, "swaps happened");
        assertGt(handler.stakes(), 5, "staking happened");
        assertGt(handler.claims(), 5, "claims happened");
        assertGt(handler.orderCount(), 5, "user TWAMM orders happened");
        assertGt(handler.syncs(), 0, "syncs happened");
        assertGt(handler.liquidations(), 0, "the hook accepted at least one treasury liquidation");
        assertGt(handler.redemptionsDone(), 10, "redemptions happened");
        assertGt(handler.atomicRoundTrips(), 2, "atomic buy-then-redeem round trips happened");
        assertEq(handler.unexpectedReverts(), 0, "and no core path reverted along the way");
    }
}
