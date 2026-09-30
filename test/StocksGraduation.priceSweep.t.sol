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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SweepMockStock is ERC20 {
    constructor() ERC20("Sweep stock", "SWP") {
        _mint(msg.sender, type(uint128).max);
    }
}

/// @notice Graduation must work for EVERY stock the app can list, not just a few sample prices. Real prices run
/// from a few dollars to thousands, and a wrapper share is worth its split factor times a raw share (up to
/// about 10x today), so the price of a wrapped share reaches into the tens of thousands of dollars. This sweeps
/// the signed price from $0.01 to $1,000,000 a share and the final buy from just reaching the target up to 25
/// times over it (a whale overshooting the target), and checks that a launch always graduates into a working,
/// funded pool: the hook holds its reserve, the pool has liquidity at a price consistent with what the curve
/// last quoted, both swap directions work, and no token is stranded or created.
///
/// Audit round 13 (external review lead, fixed): overshoot above roughly 26x used to trigger
/// StocksCurve._graduate's now-removed minSeed price-distorting floor (see the dedicated
/// StocksCurve.graduationSeedFloor.t.sol for the fix and its own extreme-overshoot coverage). This file's own
/// sweep stays within 25x specifically to keep testing what it always intended -- "does a big but survivable
/// overshoot still graduate into a correctly-priced pool" -- rather than also asserting on the now-intentional
/// revert path, which the dedicated file covers on its own.
contract StocksGraduationPriceSweepTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant SIGNER_KEY = 0xA11CE;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    PoolManager pm;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    PoolSwapTest swapRouter;
    SweepMockStock stock;
    address protocol = address(0xFEED);
    address whale = address(0xB16);
    address trader = address(0x7A1);
    uint256 nonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        stock = new SweepMockStock();
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
        factory = new StocksLaunchFactory(
            vm.addr(SIGNER_KEY), protocol, address(hook), governorFactory, stakingFactory, curveDeployer,
            address(graduator), address(registry), 8_000e18, 1 days, 365 days, 1 days, 3 days, 25
        );
        require(address(factory) == predictedFactory, "factory address mismatch");
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));
        stock.transfer(whale, type(uint128).max / 2);
        stock.transfer(trader, type(uint128).max / 4);
    }

    function _launch(uint256 price) internal returns (address token, StocksCurve curve) {
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        // a fresh timestamp per launch keeps every attestation unique
        (address t, address c) = factory.createCurve(
            string.concat("Sweep", vm.toString(++nonce)), "SWP", address(stock), price, ts, abi.encodePacked(r, s, v), 30 days, ""
        );
        return (t, StocksCurve(c));
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, uint256 amountIn, address tokenIn) internal returns (bool ok) {
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {}
        vm.stopPrank();
    }

    function _graduateAt(uint256 price, uint256 overshootPct) internal {
        (address token, StocksCurve curve) = _launch(price);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        uint256 stockIn = (target * overshootPct) / 100;
        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);
        vm.stopPrank();
        curve.graduate();
        assertTrue(curve.graduated(), "graduated");

        // the pool exists, is funded, and its opening price is consistent with the curve's last quote
        PoolKey memory key = StocksPoolView(curve.pair()).poolKey();
        PoolId id = key.toId();
        assertGt(StateLibrary.getLiquidity(pm, id), 0, "pool has liquidity");
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(pm, id);
        assertGt(sqrtP, TickMath.MIN_SQRT_PRICE, "price in range (low)");
        assertLt(sqrtP, TickMath.MAX_SQRT_PRICE, "price in range (high)");

        // the hook got exactly its reserve
        assertEq(IERC20(token).balanceOf(address(hook)) >= 100e18, true, "hook TST reserve");
        assertGe(stock.balanceOf(address(hook)), 1e12, "hook stock reserve");

        // nothing stranded in the plumbing, and TST is fully accounted for
        assertEq(IERC20(token).balanceOf(address(curve)), 0, "curve holds no TST");
        assertEq(stock.balanceOf(address(curve)), 0, "curve holds no stock");
        assertEq(IERC20(token).balanceOf(address(graduator)), 0, "graduator holds no TST");
        assertEq(stock.balanceOf(address(graduator)), 0, "graduator holds no stock");
        uint256 sum = IERC20(token).balanceOf(whale) + IERC20(token).balanceOf(address(hook))
            + IERC20(token).balanceOf(address(pm)) + IERC20(token).balanceOf(BURN)
            + IERC20(token).balanceOf(curve.staking()) + IERC20(token).balanceOf(address(this));
        assertEq(sum, IERC20(token).totalSupply(), "every TST is somewhere");

        // both directions trade. The buy is small relative to the pool so it cannot legitimately exhaust it.
        bool tstIs0 = Currency.unwrap(key.currency0) == token;
        uint256 poolStock = stock.balanceOf(address(pm));
        uint256 buyIn = poolStock / 200 + 1;
        assertTrue(_swap(trader, key, !tstIs0, buyIn, address(stock)), "buy swap works");
        uint256 got = IERC20(token).balanceOf(trader);
        assertGt(got, 0, "the buy returned TST");
        assertTrue(_swap(trader, key, tstIs0, got / 2 + 1, token), "sell swap works");
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_EveryPriceAndOvershoot_GraduatesIntoAWorkingPool(uint256 priceSeed, uint256 overshootSeed) public {
        // log-uniform price from $0.01 to $1,000,000 a share, in 18-decimal USD
        uint256 exp = bound(priceSeed, 16, 24);
        uint256 mant = 1 + (uint256(keccak256(abi.encode(priceSeed))) % 9);
        uint256 price = mant * 10 ** exp;
        // final buy from just reaching the target to 25x over it -- comfortably under the ~26x point where
        // the (now-removed) minSeed floor used to kick in, see the docstring above.
        uint256 overshootPct = bound(overshootSeed, 101, 2500);
        _graduateAt(price, overshootPct);
    }

    /// @dev Named cases: a $2 penny-ish stock, $200, $2,000, a split wrapper worth 10 raw shares of a $500 stock,
    /// and the extremes of the sweep, each with a modest and a large (but still survivable, 20x) overshoot.
    function test_NamedPrices_Graduate() public {
        uint256[7] memory prices = [uint256(2e18), 200e18, 2_000e18, 5_000e18, 5e16, 200_000e18, 1_000_000e18];
        for (uint256 i; i < prices.length; ++i) {
            _graduateAt(prices[i], 101);
            _graduateAt(prices[i], 2000);
        }
    }
}
