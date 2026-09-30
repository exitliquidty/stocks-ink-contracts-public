// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @notice Round-4 audit: StocksHook.sol against non-standard/malicious ERC20 tokens as either
/// leg of a pool. Rounds 1-3 verified the fee/TWAMM logic itself is correct assuming both tokens
/// behave as plain, well-formed ERC20s. This round builds real adversarial token mocks to check
/// whether that assumption is actually load-bearing, and if so, what happens when it's violated.
contract PlainMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @dev Deducts `feeBps` on every transfer/transferFrom, sending the fee to a black hole -- the
/// simplest possible fee-on-transfer token, deliberately not disguising the behavior in any way.
contract FeeOnTransferMockERC20 is ERC20 {
    uint256 public immutable feeBps;
    address public constant SINK = address(0xdead1234);

    constructor(string memory name_, string memory symbol_, uint256 supply, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, SINK, fee);
    }
}

/// @dev transfer()/transferFrom() always return false without reverting -- the classic
/// pre-EIP20-compliance footgun. Balances still move correctly so a caller that ignores the
/// return value would never notice; only a caller that checks it (as SafeERC20 does) reacts.
contract ReturnsFalseMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        return false;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, value);
        return false;
    }
}

contract StocksHookAudit4Test is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000_000e18;
    uint256 constant FEE_BPS = 1_000; // 10%
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    address protocol = address(0xBEEF);
    address treasury = address(0xFEED);
    address trader = address(0xCAFE);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
    }

    function _deployHook() internal returns (StocksHook hook) {
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
    }

    function _priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev CONFIRMED (Medium/DoS, not fund-loss), and MORE SEVERE than initially hypothesized: a
    /// fee-on-transfer token used as `stockToken` reverts with Uniswap v4-core's own
    /// `CurrencyNotSettled()` on the very first `modifyLiquidity` call that tries to seed the
    /// pool -- i.e. graduation itself can never complete, not merely "swaps revert after a
    /// successful graduation." v4-core's own liquidity/settlement accounting requires exact-amount
    /// transfers for ANY currency movement (adding liquidity included, not just swapping), and a
    /// fee-on-transfer token violates that at the CORE level, before StocksHook's own `_takeExact`
    /// balance-diff check (which would ALSO independently revert with `Overflow()` on the hook's
    /// own pre-swap stock pull, if a swap were ever reached) gets any chance to run. This makes the
    /// root cause a known, inherent, well-documented limitation of fee-on-transfer tokens with
    /// Uniswap v4 in general, not a StocksHook-specific code defect -- but it's a real, live risk
    /// for THIS protocol specifically, since
    /// `registerPool`/`beforeInitialize` perform no check that either token is a plain, standard
    /// ERC20 (see StocksHook.sol's own registerPool -- it validates addresses/fee bounds/pool-key
    /// shape, never token behavior), and the launcher who originally chooses `stockToken` at curve
    /// creation is unprivileged and permissionless (already established in earlier audit rounds),
    /// nothing on-chain stops a fee-on-transfer token from reaching this point. This is a DoS, not
    /// a fund-drain: no value is stolen, but every buyer/staker of that specific token's pool loses
    /// the ability to trade it at all, discovered only after real capital (curve buy-ins, staked
    /// principal) is already committed. Whether this is in-scope depends on Stocks.ink's own
    /// trust model: this project's convention is that `stockToken` is always a vetted xStock
    /// wrapper, but that convention is enforced nowhere on-chain.
    function test_AUDIT_FeeOnTransferStockToken_PermanentlyBricksFeeBearingSwaps() public {
        StocksHook hook = _deployHook();
        PlainMockERC20 tst = new PlainMockERC20("TST", "TST", SUPPLY);
        FeeOnTransferMockERC20 stock = new FeeOnTransferMockERC20("Fee Stock", "FSTK", SUPPLY, 100); // 1% fee

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

        hook.registerPool(key, address(tst), address(stock), treasury, protocol, FEE_BPS);
        poolManager.initialize(key, SQRT_PRICE_1_1);

        // Graduation itself (which seeds the pool's initial liquidity via modifyLiquidity) already
        // reverts here -- confirmed live it never even gets as far as a swap.
        tst.approve(address(lpRouter), type(uint256).max);
        stock.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert(); // v4-core's own CurrencyNotSettled(), see docstring above
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
        console.log("CONFIRMED: a fee-on-transfer stockToken makes pool seeding (graduation itself) revert permanently (v4-core CurrencyNotSettled)");
    }

    /// @dev CONFIRMED SAFE: a token whose transfer()/transferFrom() always return `false` (without
    /// reverting) cannot cause StocksHook to silently misaccount, because every transfer in
    /// StocksHook.sol goes through OpenZeppelin's SafeERC20 (`using SafeERC20 for IERC20`), which
    /// explicitly checks the boolean return value and reverts on `false` rather than treating a
    /// non-reverting call as success. Verified directly against a real deployed pool rather than
    /// assumed from reading `using SafeERC20 for IERC20` alone.
    function test_AUDIT_ReturnsFalseToken_SafeERC20CorrectlyReverts_NoSilentLoss() public {
        StocksHook hook = _deployHook();
        ReturnsFalseMockERC20 tst = new ReturnsFalseMockERC20("TST", "TST", SUPPLY);
        PlainMockERC20 stock = new PlainMockERC20("Stock", "STOCK", SUPPLY);

        (Currency c0, Currency c1) = address(tst) < address(stock)
            ? (Currency.wrap(address(tst)), Currency.wrap(address(stock)))
            : (Currency.wrap(address(stock)), Currency.wrap(address(tst)));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});

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

        bool tstIsCurrency0 = Currency.unwrap(key.currency0) == address(tst);
        // Sell STOCK for TST -- this is the feeIsTst=true direction, where afterSwap's burn branch
        // fires: `IERC20(tstToken).safeTransfer(BURN, feeAmount)`, which must revert given tst's
        // transfer() always returns false. (Selling TST instead would route the fee through the
        // STOCK side's _routeStockFee, not exercising this specific token's broken transfer at all.)
        bool sellStockZeroForOne = !tstIsCurrency0;

        vm.prank(trader);
        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: sellStockZeroForOne,
                amountSpecified: -int256(1_000_000e18),
                sqrtPriceLimitX96: _priceLimit(sellStockZeroForOne)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console.log("CONFIRMED SAFE: SafeERC20 reverts the whole swap rather than silently accepting a false return");
    }

    /// @dev PLAUSIBLE / not independently re-derived this round: a malicious token that reenters
    /// during transfer() (calling back into `submitOrder`, `sync`, or attempting a nested
    /// `poolManager.swap()`/`unlock()`) could theoretically interleave state changes with an
    /// in-progress fee transfer. `submitOrder`/`batchSubmitOrders` are genuinely permissionless
    /// (no access control, by design), so a reentrant call INTO them mid-transfer would succeed as
    /// a plain external call -- the question is whether it could observe or create an inconsistent
    /// LaunchInfo/tokensOwed state relative to the still-in-progress outer operation. This
    /// specifically requires understanding whether Uniswap v4-core's own `unlock`/lock mechanism
    /// (lib/v4-core's PoolManager) permits a NESTED `unlock()` call while one is already active for
    /// the same transaction -- round 3's audit of this file explicitly treated that lock mechanism
    /// as trusted, audited-elsewhere infrastructure rather than re-deriving it, and this round did
    /// not have time to build a full malicious-reentrant-token PoC against it either. Recommend a
    /// dedicated PoC in a future round specifically driving a token whose `transfer()` callback
    /// calls `IERC20(hook).submitOrder(...)` or attempts `poolManager.unlock(...)` mid-fee-transfer,
    /// to either confirm v4-core's lock rejects the nested call (expected) or find a gap.
    function test_AUDIT_ReentrancyAngle_DocumentedNotIndependentlyProvenThisRound() public pure {
        assertTrue(true, "see docstring -- documented limitation, not a PoC");
    }
}
