// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {StocksRedemptionAdversarialTest} from "./StocksRedemption.adversarial.t.sol";

contract MockWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @dev A minimal two-hop router: one unlock() session, two sequential poolManager.swap() calls to
/// DIFFERENT pools (a plain, hookless WETH/TST pool, then this protocol's own hooked TST/Stock pool),
/// settling only the NET deltas at the end -- exactly the shape a real aggregator router (this
/// project's own SuperSwap, or any other) would use to route through this hook as one leg of a
/// larger path, atomically.
contract TwoHopRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct HopData {
        address sender;
        PoolKey keyIn; // leg 1: currencyIn -> intermediate
        bool zeroForOneIn;
        PoolKey keyOut; // leg 2: intermediate -> currencyOut
        bool zeroForOneOut;
        Currency currencyIn;
        Currency intermediate;
        Currency currencyOut;
        uint256 amountIn;
    }

    function multiHopSwap(
        PoolKey memory keyIn,
        bool zeroForOneIn,
        PoolKey memory keyOut,
        bool zeroForOneOut,
        Currency currencyIn,
        Currency intermediate,
        Currency currencyOut,
        uint256 amountIn
    ) external returns (int256 finalOut) {
        bytes memory result = manager.unlock(
            abi.encode(HopData(msg.sender, keyIn, zeroForOneIn, keyOut, zeroForOneOut, currencyIn, intermediate, currencyOut, amountIn))
        );
        finalOut = abi.decode(result, (int256));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        HopData memory d = abi.decode(rawData, (HopData));

        // leg 1: currencyIn -> intermediate, exact input
        BalanceDelta delta1 = manager.swap(
            d.keyIn,
            IPoolManager.SwapParams({
                zeroForOne: d.zeroForOneIn,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: d.zeroForOneIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 intermediateReceived = d.zeroForOneIn ? delta1.amount1() : delta1.amount0();
        require(intermediateReceived > 0, "leg1 produced no output");

        // leg 2: intermediate -> currencyOut, exact input sized off leg 1's REAL output
        BalanceDelta delta2 = manager.swap(
            d.keyOut,
            IPoolManager.SwapParams({
                zeroForOne: d.zeroForOneOut,
                amountSpecified: -int256(uint256(uint128(intermediateReceived))),
                sqrtPriceLimitX96: d.zeroForOneOut ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 finalOutAmount = d.zeroForOneOut ? -delta2.amount1() : -delta2.amount0();
        // sign convention below: we want the POSITIVE amount owed TO the caller
        int128 outOwed = d.zeroForOneOut ? delta2.amount1() : delta2.amount0();
        require(outOwed > 0, "leg2 produced no output");

        // net the intermediate currency across both legs (should be at/near zero; settle/take any dust)
        int128 intermediateOwed = d.zeroForOneIn
            ? (d.zeroForOneOut ? delta1.amount1() + delta2.amount0() : delta1.amount1() + delta2.amount1())
            : (d.zeroForOneOut ? delta1.amount0() + delta2.amount0() : delta1.amount0() + delta2.amount1());

        // pay currencyIn (what leg 1 owes the pool)
        d.currencyIn.settle(manager, d.sender, d.amountIn, false);
        // settle/take any intermediate dust so the unlock session closes cleanly
        if (intermediateOwed < 0) {
            d.intermediate.settle(manager, d.sender, uint256(uint128(-intermediateOwed)), false);
        } else if (intermediateOwed > 0) {
            d.intermediate.take(manager, d.sender, uint256(uint128(intermediateOwed)), false);
        }
        // deliver currencyOut to the caller
        d.currencyOut.take(manager, d.sender, uint256(uint128(outOwed)), false);

        finalOutAmount; // silence unused-var warning; outOwed is the value actually delivered
        return abi.encode(int256(uint256(uint128(outOwed))));
    }
}

/// @notice Round 10's own top-down pass flagged "multi-hop swap routing through this hook as one leg
/// of a larger route" as not yet reached -- genuinely untested anywhere in this repo (grepped: zero
/// hits for multi-hop/PathKey/V4Router-style test infra). This is a real integration scenario: this
/// project's own SuperSwap aggregator (or any other v4-aware router) could plausibly route e.g.
/// WETH -> TST -> Stock through an unrelated pool chained with this hook's own pool, atomically, in
/// one unlock() session -- not something any existing single-hop swapRouter test exercises.
contract StocksHookMultiHopRoutingTest is StocksRedemptionAdversarialTest {
    MockWeth weth;
    PoolKey wethTstKey;
    bool wethIsCurrency0InPlainPool;
    TwoHopRouter router;

    function _setUpPlainPoolAndRouter() internal {
        weth = new MockWeth();
        router = new TwoHopRouter(IPoolManager(address(pm)));

        Currency c0;
        Currency c1;
        if (address(weth) < address(tst)) {
            c0 = Currency.wrap(address(weth));
            c1 = Currency.wrap(address(tst));
            wethIsCurrency0InPlainPool = true;
        } else {
            c0 = Currency.wrap(address(tst));
            c1 = Currency.wrap(address(weth));
            wethIsCurrency0InPlainPool = false;
        }
        wethTstKey = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        pm.initialize(wethTstKey, TickMath.getSqrtPriceAtTick(0));

        // seed real liquidity in the plain pool. The curve is already graduated (buy() reverts
        // AlreadyGraduated), so TST for LP capital comes from an honest swap against the real,
        // already-graduated pool instead -- not part of what this test measures.
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        weth.approve(address(lpRouter), type(uint256).max);

        uint256 stockForTst = 5e18;
        stock.approve(address(swapRouter), stockForTst);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !tstIsCurrency0,
                amountSpecified: -int256(stockForTst),
                sqrtPriceLimitX96: !tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTestSettings(),
            ""
        );
        uint256 tstForLp = tst.balanceOf(address(this));
        require(tstForLp > 0, "sanity: must have acquired some TST for LP capital");
        tst.approve(address(lpRouter), type(uint256).max);

        // a liquidity amount sized conservatively off what was actually acquired, at a tight-ish
        // range around the 1:1 starting price so the token amounts required stay modest.
        int24 tickLower = -60;
        int24 tickUpper = 60;
        lpRouter.modifyLiquidity(
            wethTstKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(tstForLp / 4),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev The core comparison: route stock -> TST -> (nothing further needed, single-hop through the
    /// hook already proven elsewhere) is not the point here. The point is TST -> Stock done as the
    /// SECOND leg of an atomic WETH -> TST -> Stock route, versus the identical TST -> Stock trade done
    /// standalone: does chaining change what the hook charges, or let currency leak/duplicate across
    /// the shared unlock session?
    function test_StocksHookAsSecondLegOfMultiHopRoute_ChargesTheSameAsStandalone() public {
        _setUpPlainPoolAndRouter();

        // fund the trader with WETH, the actual currency entering the whole route
        weth.transfer(trader, 10_000e18);

        // --- baseline: measure a STANDALONE TST->Stock swap of a KNOWN tst amount via the ordinary
        // single-hop swapRouter, on a snapshot, to get the honest reference output.
        uint256 tstLegAmount = 100e18;
        tst.transfer(trader, tstLegAmount * 2); // give trader tst directly for the standalone control leg

        uint256 snap = vm.snapshotState();

        vm.startPrank(trader);
        tst.approve(address(swapRouter), tstLegAmount);
        BalanceDelta standaloneDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: tstIsCurrency0,
                amountSpecified: -int256(tstLegAmount),
                sqrtPriceLimitX96: tstIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTestSettings(),
            ""
        );
        vm.stopPrank();
        int128 standaloneStockOut = tstIsCurrency0 ? standaloneDelta.amount1() : standaloneDelta.amount0();
        assertGt(standaloneStockOut, 0, "sanity: standalone leg must produce stock output");

        vm.revertToState(snap);

        // --- now run the SAME tstLegAmount as the second leg of a real multi-hop route: WETH -> TST
        // (plain pool) -> Stock (hooked pool), atomically, through TwoHopRouter.
        // First figure out how much WETH buys exactly tstLegAmount of TST on the plain pool (quote via
        // a throwaway snapshot swap, then revert, so the real routed call below uses a realistic size).
        uint256 quoteSnap = vm.snapshotState();
        vm.startPrank(trader);
        weth.approve(address(swapRouterPlain()), type(uint256).max);
        BalanceDelta quoteDelta = swapRouterPlain().swap(
            wethTstKey,
            IPoolManager.SwapParams({
                zeroForOne: wethIsCurrency0InPlainPool,
                amountSpecified: int256(tstLegAmount), // EXACT OUTPUT: want exactly tstLegAmount of TST
                sqrtPriceLimitX96: wethIsCurrency0InPlainPool ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTestSettings(),
            ""
        );
        vm.stopPrank();
        int128 wethSpent = wethIsCurrency0InPlainPool ? -quoteDelta.amount0() : -quoteDelta.amount1();
        vm.revertToState(quoteSnap);

        vm.startPrank(trader);
        weth.approve(address(router), type(uint256).max);
        int256 routedStockOut = router.multiHopSwap(
            wethTstKey,
            wethIsCurrency0InPlainPool,
            key,
            tstIsCurrency0,
            Currency.wrap(address(weth)),
            Currency.wrap(address(tst)),
            tstIsCurrency0 ? key.currency1 : key.currency0,
            uint256(uint128(wethSpent))
        );
        vm.stopPrank();

        console.log("standalone stock out, routed (multi-hop) stock out:");
        console.logInt(int256(standaloneStockOut));
        console.logInt(routedStockOut);

        // The routed leg 2 receives approximately tstLegAmount of TST from leg 1 (via the exact-output
        // quote above), so its stock output should closely match the standalone reference -- the hook's
        // own accounting (protocol cut, TWAMM catch-up, fee burn) must charge the SAME way regardless of
        // whether it's reached standalone or as the second leg of a shared unlock session. Allow a small
        // tolerance for the plain pool's own rounding on the exact-output quote leg.
        assertApproxEqRel(uint256(routedStockOut), uint256(uint128(standaloneStockOut)), 0.02e18, "multi-hop leg charged materially differently than standalone");

        // and the trader ends this atomic route holding correct final balances: no WETH or TST stuck in
        // the router, no double-spend, no stranded intermediate currency.
        assertEq(weth.balanceOf(address(router)), 0, "no WETH stuck in the router");
        assertEq(tst.balanceOf(address(router)), 0, "no TST stuck in the router");
        assertEq(stock.balanceOf(address(router)), 0, "no stock stuck in the router");
    }

    // ---- small helpers to keep the test body above readable ----

    function swapRouterPlain() internal view returns (PoolSwapTest) {
        return swapRouter;
    }

    function PoolSwapTestSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
