// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {StocksRedemptionAdversarialTest, AdvMockStock} from "./StocksRedemption.adversarial.t.sol";

/// @notice Audit round 2: hook behaviours a mutation run showed no test was pinning, on the real production stack.
contract StocksAuditR2HookEdgesTest is StocksRedemptionAdversarialTest {
    using PoolIdLibrary for PoolKey;

    /// @notice What `sync` returns must be what it actually booked: the proceeds of a TWAMM order net of the flywheel
    /// that was burned out of them, not the gross amount.
    function test_Sync_ReturnsTheNetProceeds_ExactlyWhatWasBooked() public {
        _fundTreasury(200e18);
        uint256 _minLiqIntervals1 = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        vm.prank(curve.governor());
        staking.liquidateTreasury(_minLiqIntervals1);
        vm.warp(_now() + 3 hours);

        ITWAMM.SyncParams memory p = ITWAMM.SyncParams({
            key: key,
            orderKey: ITWAMM.OrderKey({
                owner: address(staking),
                expiration: staking.pendingLiquidationExpiration(),
                zeroForOne: !tstIsCurrency0 // selling stock: stock is currency0 exactly when TST is currency1
            })
        });
        Currency tstCurrency = tstIsCurrency0 ? key.currency0 : key.currency1;
        uint256 burnedBefore = tst.balanceOf(BURN);
        uint256 owedBefore = hook.tokensOwed(tstCurrency, address(staking));

        vm.prank(address(staking));
        (uint256 d0, uint256 d1) = hook.sync(p);
        uint256 tstDelta = tstIsCurrency0 ? d0 : d1;
        uint256 owedAfter = hook.tokensOwed(tstCurrency, address(staking));

        assertGt(tstDelta, 0, "the order has bought something");
        assertEq(owedAfter - owedBefore, tstDelta, "the returned delta is exactly what was booked");
        uint256 burned = tst.balanceOf(BURN) - burnedBefore;
        // 8% of the gross went to the burn address, the rest (92%) is what the order is owed
        assertApproxEqAbs(burned * 92, tstDelta * 8, 100, "the burned part is 8% of the gross proceeds");
    }

    /// @notice The flywheel a launch may be registered with is capped at exactly MAX_FEE_BPS: the cap itself is accepted.
    function test_RegisterPool_AcceptsExactlyTheMaximumFee() public {
        assertEq(hook.MAX_FEE_BPS(), 2_000, "the documented cap");
        AdvMockStock a = new AdvMockStock();
        AdvMockStock b = new AdvMockStock();
        (address lo, address hi) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(graduator));
        hook.registerPool(k, lo, hi, address(0x7EA5), address(0xFEED), 2_000);
        assertEq(hook.feeBps(k.toId()), 2_000);
    }

    /// @notice getReserves is the constant-product view of the pool's liquidity and price. Checked against the formula and
    /// against what the pool manager actually holds.
    function test_GetReserves_MatchesTheFormula_AndThePoolManagersBalances() public {
        _buyTst(trader, 10e18);
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(pm, key.toId());
        uint128 liq = StateLibrary.getLiquidity(pm, key.toId());
        (uint112 r0, uint112 r1,) = hook.getReserves(key.toId());
        assertEq(uint256(r0), FullMath.mulDiv(uint256(liq), 1 << 96, sqrtP), "reserve0 = L / sqrtP");
        assertEq(uint256(r1), FullMath.mulDiv(uint256(liq), sqrtP, 1 << 96), "reserve1 = L * sqrtP");

        uint256 tstReserve = tstIsCurrency0 ? r0 : r1;
        uint256 stockReserve = tstIsCurrency0 ? r1 : r0;
        assertApproxEqRel(tstReserve, tst.balanceOf(address(pm)), 1e15, "the TST reserve matches the pool's TST");
        assertApproxEqRel(stockReserve, stock.balanceOf(address(pm)), 1e15, "the stock reserve matches the pool's stock");
    }
}
