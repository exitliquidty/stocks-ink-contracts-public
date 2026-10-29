// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract FillMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @notice Sherlock issue #34: a TWAMM fill swaps through the pool manager with the hook as the caller, and
/// v4-core's `Hooks` library skips `beforeSwap`/`afterSwap` for a swap the hook itself initiates. The hook
/// relies on that: an order's cost is charged at submission and at `sync()`, never by the pool-level
/// callbacks. This test pins the dependency: a fill must not call either callback and must move nothing to the
/// protocol, the treasury or the burn address, while an ordinary swap does call them.
contract SherlockTwammFillSingleChargeTest is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000_000e18;
    uint256 constant FEE_BPS = 1_000;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    FillMockERC20 tst;
    FillMockERC20 stock;
    address protocol = address(0xBEEF);
    address treasury = address(0xFEED);
    address trader = address(0xCAFE);
    address twammOwner = address(0xABCD);
    PoolKey key;

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

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
        tst = new FillMockERC20("Acme", "ACME", SUPPLY);
        stock = new FillMockERC20("Stock", "STOCK", SUPPLY);

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        hook.registerPool(key, address(tst), address(stock), treasury, protocol, FEE_BPS);
        poolManager.initialize(key, SQRT_PRICE_1_1);

        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        tst.transfer(trader, 100_000_000e18);
        stock.transfer(trader, 100_000_000e18);
        vm.startPrank(trader);
        tst.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _tstIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(tst);
    }

    function _fillDoesNotHitTheCallbacks(bool zeroForOne, uint256 amountIn) internal {
        bool sellsStock = zeroForOne == !_tstIsCurrency0();
        if (sellsStock) {
            // Selling stock: the input-side cut is charged on top at submission, so fund input plus cut.
            stock.transfer(twammOwner, amountIn * 2);
            vm.startPrank(twammOwner);
            stock.approve(address(hook), amountIn * 2);
        } else {
            tst.transfer(twammOwner, amountIn);
            vm.startPrank(twammOwner);
            tst.approve(address(hook), amountIn);
        }
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: EXPIRATION_INTERVAL, amountIn: amountIn})
        );
        vm.stopPrank();

        vm.warp(block.timestamp + EXPIRATION_INTERVAL + 1);

        uint256 protocolStock = stock.balanceOf(protocol);
        uint256 treasuryStock = stock.balanceOf(treasury);
        uint256 burnTst = tst.balanceOf(BURN);

        // The fill swaps with the hook as msg.sender: v4-core must not call back into the hook.
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeSwap.selector), 0);
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.afterSwap.selector), 0);
        hook.executeTWAMMOrders(key);

        assertEq(stock.balanceOf(protocol), protocolStock, "fill must not pay the pre-swap protocol cut");
        assertEq(stock.balanceOf(treasury), treasuryStock, "fill must not pay the post-swap treasury share");
        assertEq(tst.balanceOf(BURN), burnTst, "fill must not burn through afterSwap");
    }

    function test_TwammFill_SellingStock_IsNotChargedByTheSwapCallbacks() public {
        _fillDoesNotHitTheCallbacks(!_tstIsCurrency0(), 1_000_000e18);
    }

    function test_TwammFill_SellingTst_IsNotChargedByTheSwapCallbacks() public {
        _fillDoesNotHitTheCallbacks(_tstIsCurrency0(), 1_000_000e18);
    }

    /// @dev The same mechanism sees an ordinary swap's callbacks, so the zero counts above mean something.
    function test_DirectSwap_DoesHitTheSwapCallbacks() public {
        bool zeroForOne = !_tstIsCurrency0();
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.beforeSwap.selector), 1);
        vm.expectCall(address(hook), abi.encodeWithSelector(IHooks.afterSwap.selector), 1);
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1_000e18),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
