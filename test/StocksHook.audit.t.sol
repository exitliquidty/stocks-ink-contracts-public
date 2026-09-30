// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract AuditMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @notice Independent adversarial audit of StocksHook's interaction with the vendored TWAMM
/// engine it inherits, focused on whether TWAMM's own internal order-fill swaps are subject to
/// the SAME custom protocol fee (pre-swap stock skim + post-swap TST burn / treasury split) that
/// every ordinary swap through the pool pays.
///
/// ORIGINAL FINDING (CONFIRMED, now FIXED -- see below): they were not. Uniswap v4-core's own
/// Hooks library guards every beforeSwap/afterSwap dispatch with
/// `if (msg.sender == address(self)) return ...` (see lib/v4-core/src/libraries/Hooks.sol lines
/// 216, 252, 292) -- an anti-reentrancy guard that skips calling the hook's own callback whenever
/// the hook ITSELF is the caller of poolManager.swap(). TWAMM.sol's own `_processSwap` (called
/// from `_unlockCallback`, itself only reachable as `StocksHook`/the hook contract) calls
/// `poolManager.swap(...)` with the hook as msg.sender -- so every real on-chain swap that
/// executes a matured TWAMM order completely bypassed StocksHook's beforeSwap/afterSwap, and with
/// it the protocol's entire fee mechanism: no pre-swap protocol stock cut, no post-swap TST burn,
/// no treasury notification. `submitOrder`/`batchSubmitOrders` have no access control, so this was
/// a fully public, permissionless route for arbitrarily large trade volume to skip the protocol's
/// burn/treasury/protocol-fee mechanics entirely: wait one interval, then sync + claim.
///
/// FIX (see StocksHook.sol's own "TWAMM order fee parity" section): submitOrder/batchSubmitOrders
/// now charge this pool's protocol-share cut of stock sold INTO an order, additively, at
/// submission time (mirrors beforeSwap's pre-swap cut); sync() now skims the remaining fee out of
/// a matured order's real proceeds the moment they're known, since -- unlike a direct swap's
/// output -- an order's earnings depend on its whole price path and aren't knowable any earlier
/// than sync (mirrors afterSwap's post-swap burn/treasury split). The tests below now prove the
/// bypass is closed in both trade directions, instead of proving it was open.
contract StocksHookAuditTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000_000e18;
    uint256 constant FEE_BPS = 1_000; // 10%, same as the existing fee-routing fuzz suite
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    AuditMockERC20 tst;
    AuditMockERC20 stock;
    address protocol = address(0xBEEF);
    address treasury = address(0xFEED);
    address trader = address(0xCAFE);
    address twammOwner = address(0xABCD);

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

        AuditMockERC20 tokenA = new AuditMockERC20("Acme", "ACME", SUPPLY);
        AuditMockERC20 tokenB = new AuditMockERC20("Stock", "STOCK", SUPPLY);
        (tst, stock) = (tokenA, tokenB);

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        // Real graduation always uses fee: 0 (see StocksGraduator.sol) -- StocksHook's own custom
        // logic is the ONLY fee mechanism on any real pool, exactly reproduced here.
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        poolId = key.toId();

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

    function _priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    uint256 constant PROTOCOL_SHARE_BPS = 2_000;
    uint256 constant BPS_DENOM = 10_000;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// @dev FIXED (was CONFIRMED HIGH SEVERITY): a TWAMM order selling STOCK for TST now pays the
    /// same protocol-share cut on its input, up front, that a direct swap of the same size pays
    /// pre-swap (asserted for EXACT equality below -- both are a flat bps of the same nominal
    /// trade size, so nothing about AMM execution should make them differ), and burns a real,
    /// nonzero amount of TST out of its own actual proceeds at sync() time, at the same
    /// `feeBps - protocolShareBps` rate a direct swap's post-swap burn uses (checked against the
    /// order's own gross earnings, not against the direct swap's burn amount -- the two trades
    /// execute against the AMM differently, an order sells its full amountIn where a direct swap's
    /// AMM leg only sees amountIn-less-the-pre-swap-cut, so their gross outputs are never expected
    /// to match exactly; only the fee RATE applied to each trade's own output should).
    function test_AUDIT_FIX_TwammOrderFill_PaysProtocolCutAndBurnsTst_SellingStock() public {
        uint256 tradeSize = 1_000_000e18;
        bool sellStockZeroForOne = !_tstIsCurrency0(); // sell STOCK for TST, both ways below

        // ---- Control: an ordinary direct swap of the exact same size/direction ----
        uint256 protocolStockBeforeDirect = stock.balanceOf(protocol);
        uint256 burnTstBeforeDirect = tst.balanceOf(BURN);

        vm.prank(trader);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: sellStockZeroForOne,
                amountSpecified: -int256(tradeSize),
                sqrtPriceLimitX96: _priceLimit(sellStockZeroForOne)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 directProtocolGain = stock.balanceOf(protocol) - protocolStockBeforeDirect;
        uint256 directBurnGain = tst.balanceOf(BURN) - burnTstBeforeDirect;
        console.log("Direct swap: protocol stock fee collected:", directProtocolGain);
        console.log("Direct swap: TST burned:", directBurnGain);
        assertGt(directProtocolGain, 0, "sanity: an ordinary direct swap of this size must pay a real protocol fee");
        assertGt(directBurnGain, 0, "sanity: an ordinary direct swap of this size must burn a real amount of TST");

        uint256 expectedProtocolCut = (tradeSize * ((FEE_BPS * PROTOCOL_SHARE_BPS) / BPS_DENOM)) / BPS_DENOM;
        assertEq(directProtocolGain, expectedProtocolCut, "sanity: direct swap's own pre-swap cut matches the flat-bps formula");

        // ---- Treatment: the identical trade, routed through a TWAMM order instead ----
        uint256 orderDuration = EXPIRATION_INTERVAL; // the minimum possible wait
        stock.transfer(twammOwner, tradeSize);
        vm.startPrank(twammOwner);
        // Exactly amountIn, no headroom -- mirrors StocksStaking's own real
        // `forceApprove(hook, stockCommitted)` exactly, and doubles as the regression check for
        // the additive-fee design this fix moved away from: that version needed extra allowance
        // beyond amountIn and broke this exact real caller (see StocksHook.sol's own comment on
        // "TWAMM order fee parity" and TWAMM.sol's own comment on _submitOrder's signature).
        stock.approve(address(hook), tradeSize);

        // The input-side fee is charged INSIDE submitOrder itself, so this snapshot has to come
        // before that call, not after -- confirmed live in an earlier draft of this test that
        // snapshotting afterward silently missed the submission-time charge entirely.
        uint256 protocolStockBeforeTwamm = stock.balanceOf(protocol);

        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({
                key: key,
                zeroForOne: sellStockZeroForOne,
                duration: orderDuration,
                amountIn: tradeSize
            })
        );
        vm.stopPrank();

        uint256 protocolGainAtSubmission = stock.balanceOf(protocol) - protocolStockBeforeTwamm;
        console.log("TWAMM order: protocol stock fee collected at submission:", protocolGainAtSubmission);
        assertEq(
            protocolGainAtSubmission,
            expectedProtocolCut,
            "FIX CHECK: TWAMM order's input-side protocol cut must exactly match a direct swap's own pre-swap cut"
        );

        vm.warp(block.timestamp + orderDuration + 1);
        hook.executeTWAMMOrders(key);

        // The burn-side fee only fires inside sync() itself (an order's real proceeds aren't known
        // any earlier), so THIS snapshot has to come before THAT call.
        uint256 burnTstBeforeTwamm = tst.balanceOf(BURN);

        vm.prank(twammOwner);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));

        uint256 twammBurnGain = tst.balanceOf(BURN) - burnTstBeforeTwamm;
        console.log("TWAMM order: TST burned at sync:", twammBurnGain);

        vm.prank(twammOwner);
        (uint256 tokens0, uint256 tokens1) = hook.claimTokensByPoolKey(key);
        uint256 ownerTstReceived = _tstIsCurrency0() ? tokens0 : tokens1;
        console.log("TWAMM order owner's real TST payout (net of the burn):", ownerTstReceived);

        assertGt(ownerTstReceived, 0, "sanity: the TWAMM order must have genuinely filled and paid out real TST");
        assertGt(twammBurnGain, 0, "FIX CHECK: TWAMM order fill must burn a real, nonzero amount of TST");

        uint256 grossTwammEarnings = ownerTstReceived + twammBurnGain;
        uint256 effectiveFeeBps = FEE_BPS - (FEE_BPS * PROTOCOL_SHARE_BPS) / BPS_DENOM;
        uint256 expectedBurn = (grossTwammEarnings * effectiveFeeBps) / BPS_DENOM;
        assertApproxEqAbs(
            twammBurnGain,
            expectedBurn,
            1,
            "FIX CHECK: TWAMM order's burn must match effectiveFeeBps of its OWN gross earnings, within 1 wei of rounding"
        );
    }

    /// @dev FIXED (was CONFIRMED HIGH SEVERITY, same root cause): a TWAMM order selling TST for
    /// STOCK now pays the full feeBps on its real proceeds at sync() time, split between protocol
    /// and treasury exactly as afterSwap's own TST->stock branch always has -- this direction has
    /// no separate pre-swap input-side charge (neither does the direct-swap path it mirrors), so
    /// everything is checked at sync().
    function test_AUDIT_FIX_TwammOrderFill_SplitsFeeBetweenProtocolAndTreasury_SellingTst() public {
        uint256 tradeSize = 1_000_000e18;
        bool sellTstZeroForOne = _tstIsCurrency0();

        uint256 orderDuration = EXPIRATION_INTERVAL;
        tst.transfer(twammOwner, tradeSize);
        vm.startPrank(twammOwner);
        tst.approve(address(hook), tradeSize); // exactly amountIn -- this direction charges no input-side fee at all

        uint256 protocolStockBefore = stock.balanceOf(protocol);

        (, ITWAMM.OrderKey memory orderKey) = hook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: sellTstZeroForOne, duration: orderDuration, amountIn: tradeSize})
        );
        vm.stopPrank();

        // This direction charges nothing at submission -- only stock-selling orders do (see
        // StocksHook.sol's own _chargeOrderInputFee), matching the direct-swap path exactly.
        assertEq(stock.balanceOf(protocol), protocolStockBefore, "sanity: TST-selling orders pay no input-side fee");

        vm.warp(block.timestamp + orderDuration + 1);
        hook.executeTWAMMOrders(key);

        uint256 treasuryStockBefore = stock.balanceOf(treasury);
        // protocolStockBefore is still valid as a baseline: nothing else touched `protocol`'s
        // stock balance between here and the submission-time check above.

        vm.prank(twammOwner);
        hook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey}));

        uint256 protocolGain = stock.balanceOf(protocol) - protocolStockBefore;
        uint256 treasuryGain = stock.balanceOf(treasury) - treasuryStockBefore;
        console.log("TWAMM order (selling TST): protocol stock fee collected at sync:", protocolGain);
        console.log("TWAMM order (selling TST): treasury stock received at sync:", treasuryGain);

        vm.prank(twammOwner);
        (uint256 tokens0, uint256 tokens1) = hook.claimTokensByPoolKey(key);
        uint256 ownerStockReceived = _tstIsCurrency0() ? tokens1 : tokens0;
        console.log("TWAMM order owner's real stock payout (net of the fee):", ownerStockReceived);

        assertGt(ownerStockReceived, 0, "sanity: the TWAMM order must have genuinely filled and paid out real stock");
        assertGt(protocolGain, 0, "FIX CHECK: TWAMM order fill must pay the protocol a real, nonzero cut");
        assertGt(treasuryGain, 0, "FIX CHECK: TWAMM order fill must pay the treasury a real, nonzero cut");

        uint256 totalFee = protocolGain + treasuryGain;
        uint256 grossEarnings = ownerStockReceived + totalFee;
        uint256 expectedTotalFee = (grossEarnings * FEE_BPS) / BPS_DENOM;
        uint256 expectedProtocolCut = (totalFee * PROTOCOL_SHARE_BPS) / BPS_DENOM;
        assertApproxEqAbs(
            totalFee, expectedTotalFee, 1, "FIX CHECK: total fee must match feeBps of the order's own gross earnings"
        );
        assertApproxEqAbs(
            protocolGain, expectedProtocolCut, 1, "FIX CHECK: protocol's share of that fee must match PROTOCOL_FEE_SHARE_BPS"
        );
    }
}
