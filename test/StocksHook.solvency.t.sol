// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SolvencyMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

contract SolvencyMockTreasury {
    function notifyRewardAmount() external {}
}

/// @notice Random-walk handler: swaps in both directions, TWAMM orders in both directions with
/// random sizes and durations, time warps, syncs, claims and permissionless executeTWAMMOrders,
/// all from several independent actors. The invariants live in the test contract below.
contract SolvencyHandler is Test {
    using PoolIdLibrary for PoolKey;

    StocksHook public hook;
    PoolSwapTest public swapRouter;
    SolvencyMockERC20 public tst;
    SolvencyMockERC20 public stock;
    PoolKey public key;

    address[4] public actors = [address(0xA001), address(0xA002), address(0xA003), address(0xA004)];
    uint256 constant INTERVAL = 1 hours;

    struct LiveOrder {
        address owner;
        ITWAMM.OrderKey orderKey;
    }

    LiveOrder[] public orders;

    // Ghost counters the test contract asserts on.
    uint256 public cappedClaims; // claims that paid out less than the recorded balance owed
    uint256 public totalSwaps;
    uint256 public totalOrders;
    uint256 public totalSyncs;
    uint256 public totalClaims;
    // Largest gap ever seen between what the hook owes and what it holds (per token, summed), the
    // largest single short-paid claim, and the biggest order ever placed, to tell fixed rounding
    // dust apart from a gap that grows with volume.
    uint256 public maxOwedOverBalance;
    uint256 public maxClaimShortfall;
    uint256 public maxOrderAmount;

    // Pool depth per currency. When nonzero, swap and order sizes are set relative to it (orders up to 3x
    // the pool's whole depth, like a real treasury liquidation against a thin graduated pool). Zero keeps
    // the original absolute bounds.
    uint256 public depth0;
    uint256 public depth1;

    constructor(
        StocksHook hook_,
        PoolSwapTest swapRouter_,
        SolvencyMockERC20 tst_,
        SolvencyMockERC20 stock_,
        PoolKey memory key_,
        uint256 depth0_,
        uint256 depth1_
    ) {
        depth0 = depth0_;
        depth1 = depth1_;
        hook = hook_;
        swapRouter = swapRouter_;
        tst = tst_;
        stock = stock_;
        key = key_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amount) external {
        address who = _actor(actorSeed);
        if (depth0 == 0) {
            amount = bound(amount, 1e15, 3e24);
        } else {
            uint256 d = zeroForOne ? depth0 : depth1;
            amount = bound(amount, d / 1e6, d * 2);
        }
        vm.prank(who);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: _limit(zeroForOne)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        totalSwaps++;
        _track();
    }

    function submitOrder(uint256 actorSeed, bool zeroForOne, uint256 intervals, uint256 amount) external {
        address who = _actor(actorSeed);
        intervals = bound(intervals, 1, 6);
        if (depth0 == 0) {
            amount = bound(amount, 1e18, 5e23);
        } else {
            uint256 d = zeroForOne ? depth0 : depth1;
            amount = bound(amount, d / 1e3, d * 3);
        }
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        // Single-shot pranks, NOT startPrank/stopPrank: a revert inside submitOrder (e.g. a duplicate order)
        // would skip stopPrank, and Foundry does not roll cheatcode state back on a revert, so the dangling
        // prank would silently make every later single-prank action in the workload fail.
        vm.prank(who);
        SolvencyMockERC20(sellToken).approve(address(hook), amount);
        vm.prank(who);
        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: intervals * INTERVAL, amountIn: amount})
        );

        orders.push(LiveOrder({owner: who, orderKey: orderKey}));
        totalOrders++;
        if (amount > maxOrderAmount) maxOrderAmount = amount;
        _track();
    }

    function warpTime(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1, 3 * INTERVAL);
        vm.warp(block.timestamp + secondsForward);
    }

    function executeOrders() external {
        hook.executeTWAMMOrders(key);
        _track();
    }

    function syncOrder(uint256 orderSeed) external {
        if (orders.length == 0) return;
        LiveOrder memory o = orders[orderSeed % orders.length];
        // An expired order is deleted by its first sync; skip already-settled ones.
        if (hook.getOrder(key, o.orderKey).sellRate == 0) return;
        vm.prank(o.owner);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: o.orderKey}));
        totalSyncs++;
        _track();
    }

    function claim(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 owed0 = hook.tokensOwed(key.currency0, who);
        uint256 owed1 = hook.tokensOwed(key.currency1, who);
        vm.prank(who);
        (uint256 got0, uint256 got1) = hook.claimTokensByPoolKey(key);
        // TWAMM's claim silently caps a payout at the hook's live balance. A capped claim means the
        // hook owed more than it held, i.e. it was insolvent for this token.
        if (got0 != owed0 || got1 != owed1) {
            cappedClaims++;
            uint256 sf = (owed0 - got0) + (owed1 - got1);
            if (sf > maxClaimShortfall) maxClaimShortfall = sf;
        }
        totalClaims++;
        _track();
    }

    /// @dev Settles the whole pool: executes TWAMM, syncs every order that still exists, then every actor
    /// claims. Used to check what the hook is left holding once nothing is owed to anyone.
    function settleAll() external {
        try hook.executeTWAMMOrders(key) {} catch {}
        for (uint256 i; i < orders.length; i++) {
            LiveOrder memory o = orders[i];
            if (hook.getOrder(key, o.orderKey).sellRate != 0) {
                vm.prank(o.owner);
                try hook.sync(ITWAMM.SyncParams({key: key, orderKey: o.orderKey})) {} catch {}
            }
        }
        for (uint256 a; a < actors.length; a++) {
            vm.prank(actors[a]);
            try hook.claimTokensByPoolKey(key) {} catch {}
        }
    }

    function _track() internal {
        for (uint256 t; t < 2; t++) {
            Currency c = t == 0 ? key.currency0 : key.currency1;
            uint256 owed = this.sumOwed(c);
            uint256 bal = IERC20Like(Currency.unwrap(c)).balanceOf(address(hook));
            if (owed > bal && owed - bal > maxOwedOverBalance) maxOwedOverBalance = owed - bal;
        }
    }

    function sumOwed(Currency c) external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += hook.tokensOwed(c, actors[i]);
        }
    }
}

/// @notice Stateful invariants for the ONE contract that custodies user funds for every pool at once:
/// StocksHook (inherits TWAMM, whose order inputs and unclaimed proceeds sit commingled in the hook's
/// own token balances). Existing suites prove each fee is accounted for exactly once; nothing
/// proved that the commingled custody itself stays solvent under arbitrary interleavings of swaps,
/// TWAMM orders in both directions, time, syncs and claims. Runs against a PoolManager built from
/// the pinned v4-core source.
abstract contract StocksHookSolvencyBase is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant SUPPLY = 1_000_000_000_000e18;
    function _feeBps() internal view virtual returns (uint256) {
        return 1_000;
    }

    /// @dev true = run against the real deployed PoolManager on an Ink fork instead of a local build.
    function _useRealPoolManager() internal view virtual returns (bool) {
        return false;
    }

    /// @dev 0 = whatever the deploy addresses give; 1 = TST is currency0; 2 = TST is currency1. Real
    /// pools land in both orderings depending on the new token's address.
    function _orderingMode() internal view virtual returns (uint8) {
        return 0;
    }

    /// @dev true = a pool shaped like a real graduation: 200M TST against 40 stock shares, so about 5
    /// million TST per share, instead of a 1:1 pool.
    function _realisticPool() internal view virtual returns (bool) {
        return false;
    }

    /// @dev Stock shares seeded next to the 200M TST in a realistic pool (40 = about $8,000 of a $200 share).
    function _realisticStockSeed() internal view virtual returns (uint256) {
        return 40e18;
    }

    /// @dev The rounding reserve the hook holds. Defaults mirror what StocksGraduator hands the hook at
    /// graduation (HOOK_TST_RESERVE_WEI = 1e20, HOOK_STOCK_RESERVE_WEI = 1e12, asserted equal in
    /// StocksGraduator.audit4.t.sol), so this harness matches a real graduated pool. Override both to 0 to
    /// test the hook with no reserve at all.
    function _tstReserve() internal view virtual returns (uint256) {
        return 1e20;
    }

    function _stockReserve() internal view virtual returns (uint256) {
        return 1e12;
    }
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    SolvencyMockERC20 tst;
    SolvencyMockERC20 stock;
    SolvencyHandler handler;
    PoolKey key;

    address protocol = address(0xBEEF);
    SolvencyMockTreasury treasury;

    function setUp() public {
        if (_useRealPoolManager()) {
            // The real, deployed Uniswap v4 PoolManager on Ink, via a fork.
            vm.createSelectFork("ink");
            poolManager = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
            require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
            vm.warp(vm.getBlockTimestamp() + 1 days);
        } else {
            // A fresh local EVM starts at block.timestamp = 1, which TWAMM rounds to interval time 0 and
            // then reads as "uninitialized". Real chains never do that, so start at a realistic time.
            vm.warp(1_800_000_000);
            // A locally deployed PoolManager built from the pinned v4-core source: deterministic and
            // offline, which is what lets this stateful test run hundreds of random sequences.
            poolManager = IPoolManager(address(new PoolManager(address(this))));
        }

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(this), EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, address(this), EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        treasury = new SolvencyMockTreasury();

        SolvencyMockERC20 tokenA = new SolvencyMockERC20("Acme", "ACME", SUPPLY);
        SolvencyMockERC20 tokenB = new SolvencyMockERC20("Stock", "STOCK", SUPPLY);
        if (_orderingMode() == 0) {
            (tst, stock) = (tokenA, tokenB);
        } else {
            (SolvencyMockERC20 lo, SolvencyMockERC20 hi) =
                address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
            (tst, stock) = _orderingMode() == 1 ? (lo, hi) : (hi, lo);
        }

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        hook.registerPool(key, address(tst), address(stock), address(treasury), protocol, _feeBps());
        uint160 startSqrtPrice = SQRT_PRICE_1_1;
        uint128 startLiquidity = 10_000_000e18;
        uint256 depth0;
        uint256 depth1;
        if (_realisticPool()) {
            uint256 tstSeed = 200_000_000e18;
            uint256 stockSeed = _realisticStockSeed();
            bool tstIsCurrency0 = address(tst) < address(stock);
            (uint256 a0, uint256 a1) = tstIsCurrency0 ? (tstSeed, stockSeed) : (stockSeed, tstSeed);
            startSqrtPrice = uint160(Math.sqrt(Math.mulDiv(a1, 1 << 192, a0)));
            startLiquidity = uint128(Math.sqrt(a0 * a1));
            (depth0, depth1) = (a0, a1);
        }
        poolManager.initialize(key, startSqrtPrice);

        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        // Matches the real graduation shape: one permanent full-range position.
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: int256(uint256(startLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        if (_tstReserve() > 0) tst.transfer(address(hook), _tstReserve());
        if (_stockReserve() > 0) stock.transfer(address(hook), _stockReserve());

        handler = new SolvencyHandler(hook, swapRouter, tst, stock, key, depth0, depth1);
        for (uint256 i; i < 4; i++) {
            address a = handler.actors(i);
            tst.transfer(a, 100_000_000_000e18);
            stock.transfer(a, 100_000_000_000e18);
            vm.startPrank(a);
            tst.approve(address(swapRouter), type(uint256).max);
            stock.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        targetContract(address(handler));
    }
}

/// forge-config: default.invariant.runs = 300
/// forge-config: default.invariant.depth = 120
contract StocksHookSolvencyTest is StocksHookSolvencyBase {
    /// @dev Rounding dust allowance: TWAMM floors every per-order payout and documents an "offByOne" in
    /// its own claim path, so the hook can end up a few wei short across many small orders. What must
    /// NEVER happen is a gap that grows with order SIZE. Bounded here by a small fixed number of wei
    /// per order/sync, independent of amounts (orders here go up to 5e23 wei, so a size-proportional
    /// gap would blow through this bound immediately).
    uint256 constant DUST_WEI_PER_OP = 4;

    function _dustAllowance() internal view returns (uint256) {
        return DUST_WEI_PER_OP * (handler.totalOrders() + handler.totalSyncs() + 1);
    }

    /// @dev What the hook owes (unclaimed TWAMM proceeds) is backed by what it holds, up to rounding dust.
    function invariant_HookOwedIsBackedUpToRoundingDust() public view {
        assertLe(handler.maxOwedOverBalance(), _dustAllowance(), "hook is short by more than rounding dust");
    }

    /// @dev No claim is ever short-paid by more than rounding dust.
    function invariant_NoClaimIsShortPaidBeyondDust() public view {
        assertLe(handler.maxClaimShortfall(), _dustAllowance(), "a claim was short-paid by more than rounding dust");
    }

    /// @dev The pool can never be bricked: after any sequence, a small swap in each direction still
    /// succeeds (so no state reached by the walk makes executeTWAMMOrders/beforeSwap revert forever).
    function invariant_PoolIsNeverBricked() public {
        for (uint256 d; d < 2; d++) {
            bool zeroForOne = d == 0;
            address inToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
            address who = handler.actors(0);
            vm.startPrank(who);
            SolvencyMockERC20(inToken).approve(address(swapRouter), type(uint256).max);
            try swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(1e15),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            ) {} catch (bytes memory reason) {
                vm.stopPrank();
                console.log("swap direction zeroForOne:", zeroForOne);
                console.logBytes(reason);
                fail("pool is bricked: a small swap reverted");
                return;
            }
            vm.stopPrank();
        }
    }

    /// @dev Runs after each invariant run: prints how much of the walk was real work, so a green
    /// result can never hide a handler whose calls all reverted or did nothing.
    function afterInvariant() public view {
        console.log("swaps:", handler.totalSwaps());
        console.log("orders:", handler.totalOrders());
        console.log("syncs:", handler.totalSyncs());
        console.log("claims:", handler.totalClaims());
        console.log("max owed-over-balance (wei):", handler.maxOwedOverBalance());
        console.log("max short-paid claim (wei):", handler.maxClaimShortfall());
        console.log("biggest order (wei):", handler.maxOrderAmount());
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @notice The same invariants on a hook with NO reserve. Custody stays backed to rounding dust, and the pool
/// can still never be bricked, because beforeSwap now fails open when virtual execution reverts.
contract StocksHookSolvencyNoReserveTest is StocksHookSolvencyTest {
    function _tstReserve() internal pure override returns (uint256) {
        return 0;
    }

    function _stockReserve() internal pure override returns (uint256) {
        return 0;
    }
}
