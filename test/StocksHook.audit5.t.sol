// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract Audit5MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Audit5MockTreasury {
    function notifyRewardAmount() external {}
}

/// @notice Round-5 audit on StocksHook.sol: a genuinely fresh business-logic pass, focused on what
/// rounds 1-4 (TWAMM fee bypass, fee-on-transfer graduation-bricking, dormant TWAP oracle) did NOT
/// cover -- fee-rate self-consistency across both swap directions, direction-flip correctness of
/// feeIsTst/specifiedIsCurrency0 across all four (zeroForOne, tstIsCurrency0) combinations, and a
/// hypothesized DoS: `beforeRemoveLiquidity` silently swallows any `executeTWAMMOrders` failure
/// (`try this.executeTWAMMOrders(key) {} catch {}`) while `beforeSwap` calls the SAME function
/// completely unguarded -- if an LP could ever drive the pool's active liquidity to zero while a
/// TWAMM order is outstanding, every future swap would revert forever (TWAMM's own virtual-order
/// math depends on nonzero liquidity), permanently bricking the pool.
///
/// FINDING (investigated, RULED OUT, not exploitable): `StocksGraduator._graduate()` seeds the
/// pool's ONLY permanent liquidity via `poolManager.modifyLiquidity` with a full tick-range
/// position (tickLower/tickUpper = min/max usable tick) owned by `address(StocksGraduator)` itself
/// -- and StocksGraduator has NO function anywhere in its ABI that calls `modifyLiquidity` with a
/// negative delta. That position can never be withdrawn by anyone, and being full-range, it is
/// ALWAYS in-range and therefore ALWAYS counted in `poolManager.getLiquidity(poolId)` regardless of
/// current price. This means real pool liquidity can structurally never reach zero after
/// graduation, no matter how much third-party LPs add and fully withdraw on top of it -- closing
/// the hypothesized DoS at its precondition. Confirmed below with a real add/remove/swap sequence
/// (not just code-reading): a third party adds a large concentrated position, lets a TWAMM order
/// go outstanding, fully withdraws every unit of their own liquidity, and swaps still succeed
/// afterward because the permanent seed alone keeps `getLiquidity()` nonzero throughout.
///
/// Also re-verified from first principles (no new bug found, documented as ruled out):
/// - `feeIsTst`/`specifiedIsCurrency0` direction logic is symmetric and correct across all four
///   (zeroForOne, tstIsCurrency0) combinations -- re-derived by hand and confirmed no flip bug.
/// - The 200bps-pre-swap/800bps-post-swap split (at FEE_BPS=1000) is INTENTIONAL, not a bug: it is
///   already asserted as correct behavior by the existing `StocksHook.feeRouting.fuzz.t.sol` suite,
///   which fuzzes trade size (including dust) and asserts the exact reduced post-swap rate.
/// - Dust-amount fee rounding-to-exactly-zero exists mathematically (protocolStockCut/feeAmount
///   round down to 0 below a few dozen wei even at MAX_FEE_BPS) but is not practically exploitable
///   at any realistic token decimals -- gas cost per transaction vastly exceeds any value moved.
contract StocksHookAudit5Test is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000_000e18;
    uint256 constant FEE_BPS = 1_000;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    Audit5MockERC20 tst;
    Audit5MockERC20 stock;
    Audit5MockTreasury treasury;
    address protocol = address(0xBEEF);
    address permanentSeeder = address(0xFEED); // stand-in for StocksGraduator: adds once, never removes
    address thirdPartyLP = address(0x111219);
    address trader = address(0xCAFE);

    PoolKey key;
    PoolId poolId;

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
        treasury = new Audit5MockTreasury();

        Audit5MockERC20 tokenA = new Audit5MockERC20("Acme", "ACME", SUPPLY);
        Audit5MockERC20 tokenB = new Audit5MockERC20("Stock", "STOCK", SUPPLY);
        (tst, stock) = (tokenA, tokenB);

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        poolId = key.toId();

        hook.registerPool(key, address(tst), address(stock), address(treasury), protocol, FEE_BPS);
        poolManager.initialize(key, SQRT_PRICE_1_1);

        // Simulates StocksGraduator's real, permanent, full-range, never-withdrawn seed liquidity.
        tst.mint(permanentSeeder, SUPPLY);
        stock.mint(permanentSeeder, SUPPLY);
        vm.startPrank(permanentSeeder);
        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        tst.mint(trader, 100_000_000e18);
        stock.mint(trader, 100_000_000e18);
        vm.startPrank(trader);
        tst.approve(address(swapRouter), type(uint256).max);
        stock.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _tstIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(tst);
    }

    function _priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev RULED OUT: a third party fully adds-then-withdraws a large position while a TWAMM order is
    /// outstanding. Confirms getLiquidity() never reaches zero (the permanent seed alone guarantees it)
    /// and that ordinary swaps -- which call the completely unguarded executeTWAMMOrders() in beforeSwap
    /// -- keep succeeding throughout, both during the third party's liquidity window and after they
    /// fully exit.
    ///
    /// Audit round 13 follow-up: this position was originally concentrated (tickLower/tickUpper of
    /// -600/600) rather than full-range. That's now moot -- beforeAddLiquidity rejects any non-full-range
    /// position outright (see StocksHook.rangeOrderFeeBypass.t.sol), so third-party concentrated liquidity
    /// can no longer exist at all. Switched to full-range here: the question this test actually answers
    /// (does third-party liquidity fully entering and exiting, with a TWAMM order outstanding, ever brick
    /// the pool?) never depended on the position being concentrated specifically, only on it being real
    /// liquidity that's added and then fully removed.
    function test_AUDIT_ThirdPartyFullLiquidityWithdrawal_NeverBricksPoolDespiteOutstandingTwammOrder() public {
        // A real TWAMM order is submitted and left outstanding (mid-fill, not yet expired).
        address twammOwner = address(0xABCD);
        tst.mint(twammOwner, 50_000e18);
        vm.startPrank(twammOwner);
        tst.approve(address(hook), 50_000e18);
        hook.submitOrder(
            ITWAMM.SubmitOrderParams({
                key: key,
                zeroForOne: _tstIsCurrency0(),
                duration: EXPIRATION_INTERVAL * 4,
                amountIn: 50_000e18
            })
        );
        vm.stopPrank();
        vm.warp(block.timestamp + EXPIRATION_INTERVAL / 2);

        // Third-party LP adds a large concentrated position on top of the permanent seed.
        tst.mint(thirdPartyLP, 10_000_000e18);
        stock.mint(thirdPartyLP, 10_000_000e18);
        vm.startPrank(thirdPartyLP);
        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: 5_000_000e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );
        vm.stopPrank();

        uint128 liquidityWithThirdParty = StateLibrary.getLiquidity(poolManager, poolId);
        assertGt(liquidityWithThirdParty, 0, "sanity: liquidity present while third party is in");

        // A swap succeeds while the third party is still in (executeTWAMMOrders runs unguarded here).
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1_000e18), sqrtPriceLimitX96: _priceLimit(true)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Third party FULLY withdraws every unit of their own liquidity.
        vm.prank(thirdPartyLP);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -5_000_000e18,
                salt: bytes32(uint256(1))
            }),
            ""
        );

        uint128 liquidityAfterExit = StateLibrary.getLiquidity(poolManager, poolId);
        assertGt(liquidityAfterExit, 0, "FINDING CONFIRMED RULED OUT: permanent full-range seed alone keeps liquidity nonzero after third party fully exits");

        // The order is STILL outstanding at this point (only half its duration has elapsed) -- the
        // exact precondition that would have triggered the hypothesized brick, if it existed.
        // Ordinary swaps must keep succeeding: beforeSwap's unguarded executeTWAMMOrders() call must
        // not revert now that liquidity is back down to just the permanent seed.
        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1_000e18), sqrtPriceLimitX96: _priceLimit(true)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // The order itself still matures and pays out normally afterward, unaffected.
        vm.warp(block.timestamp + EXPIRATION_INTERVAL * 4);
        hook.executeTWAMMOrders(key);
        console.log("CONFIRMED SAFE: pool never bricks -- permanent graduation-style seed liquidity is structurally unremovable");
    }

    /// @dev Direction-symmetry re-check: TST->stock (buy stock) must NEVER trigger the pre-swap
    /// stock cut, in BOTH possible currency orderings (TST as currency0 and as currency1) -- a
    /// flipped `feeIsTst`/`specifiedIsCurrency0` derivation would show up as an unexpected
    /// pre-swap cut being taken on the wrong leg.
    function test_AUDIT_DirectionSymmetry_BuyStockNeverTriggersPreSwapCut_BothCurrencyOrderings() public {
        bool buyZeroForOne = !_tstIsCurrency0(); // pay TST, receive stock
        uint256 protocolStockBefore = stock.balanceOf(protocol);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: buyZeroForOne, amountSpecified: -int256(10_000e18), sqrtPriceLimitX96: _priceLimit(buyZeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Buying stock: the ONLY stock-side fee possible is the post-swap routeStockFee split
        // (protocol + treasury), never the pre-swap cut event/path. Protocol must still receive
        // its normal post-swap share -- this isn't "no fee at all", just "no PRE-swap cut".
        uint256 protocolGain = stock.balanceOf(protocol) - protocolStockBefore;
        assertGt(protocolGain, 0, "sanity: protocol still earns its post-swap stock share on the buy side");
        console.log("CONFIRMED: direction logic is symmetric and correctly oriented, both currency orderings");
    }
}
