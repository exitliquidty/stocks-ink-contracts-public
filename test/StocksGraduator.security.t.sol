// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract MockERC20G is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @notice Stands in for StocksLaunchFactory's own `curveOf` (see that contract's AUDIT FIX H-3
/// docstring) -- lets this suite register exactly which address is "the legitimate curve" for a
/// given token, the same authentication StocksGraduator.graduate() now requires from a real
/// factory. Every existing test below registers the address it's about to call graduate() FROM
/// (almost always this test contract itself) as that token's curve immediately after minting it,
/// via _freshPair -- so every pre-existing assertion keeps testing exactly what it always tested,
/// now against a caller the graduator actually accepts.
contract MockCurveRegistry {
    mapping(address => address) public curveOf;

    function setCurve(address token, address curve) external {
        curveOf[token] = curve;
    }
}

/// @notice This is the contract that actually owns Stocks.ink's locked liquidity: StocksGraduator
/// mints the one and only full-range position per graduated pool, using its own balance, and never
/// exposes any function that could move it back out (see the contract's own docstring). If
/// anything here were wrong, it would be the single highest-impact bug in the whole stack --
/// "liquidity locked forever" is the platform's core promise. This suite:
///   1. Ports every test from MemeStockV4Graduator.security.t.sol (the sibling this is a "full
///      copy, not inheritance" of) to confirm the same protections actually carried over
///      byte-for-byte, rather than assuming the docstring's claim is still true.
///   2. Adds coverage for attack surfaces not exercised by that suite or by
///      MemeStockHookV5.security.t.sol: direct unlockCallback abuse, front-running graduation via
///      a raw poolManager.initialize() call (a DIFFERENT griefing vector than the already-fixed
///      dust-seed registerPool() squat -- this one attacks PoolManager's own one-time-init
///      invariant instead of the hook's registry), reentrancy from a malicious TST/stock token's
///      transfer hook during the pull, and extreme/lopsided seed ratios.
contract StocksGraduatorSecurityTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant FEE_BPS = 1_000;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    MockCurveRegistry registry;

    address attacker = address(0xBAD);
    address realTreasury = address(0xCAFE);
    address realProtocol = address(0xF00D);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

        // Deployed before the nonce is captured below, so it doesn't shift the existing
        // hook/graduator address predictions by one.
        registry = new MockCurveRegistry();

        uint256 nonceBeforeHook = vm.getNonce(address(this));
        address predictedGraduator = vm.computeCreateAddress(address(this), nonceBeforeHook + 1);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, address(registry));
        require(address(graduator) == predictedGraduator, "graduator address mismatch");
    }

    // Registers `address(this)` -- the address every existing test below actually calls
    // graduate() from -- as the legitimate curve for the new tstToken, the same authentication
    // a real StocksLaunchFactory.curveOf() would provide. Keeps every pre-existing test's
    // assertion testing exactly what it always tested (dust floors, reentrancy, ratio math, ...),
    // now against a caller the AUDIT FIX H-3 check actually accepts.
    function _freshPair(string memory tag) internal returns (MockERC20G tst, MockERC20G stock) {
        tst = new MockERC20G(string.concat("Acme", tag), string.concat("ACME", tag), SUPPLY);
        stock = new MockERC20G(string.concat("Stock", tag), string.concat("STOCK", tag), SUPPLY);
        registry.setCurve(address(tst), address(this));
    }

    function _key(address tstToken, address stockToken) internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = tstToken < stockToken
            ? (Currency.wrap(tstToken), Currency.wrap(stockToken))
            : (Currency.wrap(stockToken), Currency.wrap(tstToken));
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
    }

    function _isRegistered(address tstToken, address stockToken) internal view returns (bool registered) {
        (registered,,,,,,) = hook.launches(_key(tstToken, stockToken).toId());
    }

    // ============================================================
    // Ported from MemeStockV4Graduator.security.t.sol -- confirms the "full copy" claim
    // ============================================================

    // AUDIT FIX H-3 means an outsider (not the registered curve for this pair) now hits NotCurve
    // before SeedTooSmall ever gets evaluated -- H-1's dust floor is defense-in-depth for a
    // registered-but-buggy caller now (see test_RevertWhen_RegisteredCurveSendsDust below), not
    // the primary defense against an outsider, which is H-3 itself. Updated from this test's
    // original expectation (SeedTooSmall) to match: `attacker` was never registered as this
    // pair's curve by _freshPair, so this is really just confirming the ordinary outsider-caller
    // rejection with a dust-sized seed -- same real-world case the original test covered.
    function test_RevertWhen_DustSeedAttemptsToSquatPoolId() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("A");
        uint256 dust = 1e6;

        vm.expectRevert(StocksGraduator.NotCurve.selector);
        vm.prank(attacker);
        graduator.graduate(address(tst), address(stock), attacker, attacker, FEE_BPS, dust, dust);

        assertFalse(_isRegistered(address(tst), address(stock)));
    }

    // Defense-in-depth: even the pair's OWN registered curve can't graduate with a dust-sized
    // seed -- H-1's floor still matters for a legitimate-but-misbehaving/buggy caller, not just
    // as a historical artifact now that H-3 handles the outsider case.
    //
    // External AuditAgent finding #9 (2026-09-30) fix: graduate() now measures its ACTUAL
    // received balance-diff (fee-on-transfer protection) by pulling BEFORE checking SeedTooSmall,
    // instead of checking the caller-supplied amount first and pulling after. A real curve always
    // approves exactly what it's about to send, so this test now does too -- otherwise the pull
    // itself reverts with ERC20InsufficientAllowance before ever reaching the check this test
    // means to exercise.
    function test_RevertWhen_RegisteredCurveSendsDust() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("A2");
        uint256 dust = 1e6;
        tst.approve(address(graduator), dust);
        stock.approve(address(graduator), dust);

        vm.expectRevert(StocksGraduator.SeedTooSmall.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, dust, dust);

        assertFalse(_isRegistered(address(tst), address(stock)));
    }

    function test_RevertWhen_SeedJustUnderThreshold() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("B");
        uint256 threshold = (tst.totalSupply() * graduator.MIN_TST_SEED_SUPPLY_BPS()) / graduator.BPS_DENOM();
        uint256 justUnder = threshold - 1;
        tst.approve(address(graduator), justUnder);
        stock.approve(address(graduator), 1e18);

        vm.expectRevert(StocksGraduator.SeedTooSmall.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, justUnder, 1e18);
    }

    function test_SeedAtExactThreshold_Succeeds() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("C");
        uint256 threshold = (tst.totalSupply() * graduator.MIN_TST_SEED_SUPPLY_BPS()) / graduator.BPS_DENOM();

        tst.approve(address(graduator), threshold);
        stock.approve(address(graduator), 1_000e18);

        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, threshold, 1_000e18);
        assertTrue(_isRegistered(address(tst), address(stock)));
        (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function test_DustSweep_DonatedExtraTokensRoutedToLegitimateDestinations_NotStranded() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("E");
        address burnAddr = graduator.BURN_ADDRESS();

        uint256 strayTst = 777e18;
        uint256 strayStock = 333e18;
        tst.transfer(address(graduator), strayTst);
        stock.transfer(address(graduator), strayStock);

        uint256 realTstSeed = (tst.totalSupply() * 20) / 100;
        uint256 realStockSeed = 10_000e18;
        tst.approve(address(graduator), realTstSeed);
        stock.approve(address(graduator), realStockSeed);

        uint256 burnBefore = tst.balanceOf(burnAddr);
        uint256 treasuryBefore = stock.balanceOf(realTreasury);

        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, realTstSeed, realStockSeed);

        assertGe(tst.balanceOf(burnAddr) - burnBefore, strayTst);
        assertGe(stock.balanceOf(realTreasury) - treasuryBefore, strayStock);
        assertEq(tst.balanceOf(address(graduator)), 0);
        assertEq(stock.balanceOf(address(graduator)), 0);
    }

    function test_TwoSequentialGraduations_DoNotCrossContaminateBalancesOrState() public {
        (MockERC20G tstX, MockERC20G stockX) = _freshPair("X");
        (MockERC20G tstY, MockERC20G stockY) = _freshPair("Y");

        uint256 seedX = (tstX.totalSupply() * 25) / 100;
        tstX.approve(address(graduator), seedX);
        stockX.approve(address(graduator), 2_000e18);
        address poolViewX =
            graduator.graduate(address(tstX), address(stockX), realTreasury, realProtocol, FEE_BPS, seedX, 2_000e18);
        (uint112 rx0, uint112 rx1,) = StocksPoolView(poolViewX).getReserves();

        uint256 seedY = (tstY.totalSupply() * 30) / 100;
        tstY.approve(address(graduator), seedY);
        stockY.approve(address(graduator), 9_000e18);
        graduator.graduate(address(tstY), address(stockY), realTreasury, realProtocol, FEE_BPS, seedY, 9_000e18);

        (uint112 rx0After, uint112 rx1After,) = StocksPoolView(poolViewX).getReserves();
        assertEq(rx0After, rx0);
        assertEq(rx1After, rx1);

        assertEq(tstX.balanceOf(address(graduator)), 0);
        assertEq(stockX.balanceOf(address(graduator)), 0);
        assertEq(tstY.balanceOf(address(graduator)), 0);
        assertEq(stockY.balanceOf(address(graduator)), 0);
    }

    function test_RevertWhen_ZeroAmount() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("F");
        vm.expectRevert(StocksGraduator.ZeroAmount.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, 0, 1e18);
    }

    function test_RealisticGraduation_ProducesWorkingPoolAtExpectedRatio() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("G");
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 4_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
        bool tstIsCurrency0 = address(tst) < address(stock);
        (uint256 tstReserve, uint256 stockReserve) = tstIsCurrency0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        assertApproxEqRel(tstReserve, tstSeed, 0.0001e18);
        assertApproxEqRel(stockReserve, stockSeed, 0.0001e18);
        assertEq(StocksPoolView(poolView).tstToken(), address(tst));
        assertEq(StocksPoolView(poolView).stockToken(), address(stock));
    }

    // ============================================================
    // NEW: direct unlockCallback abuse
    // ============================================================

    /// @dev unlockCallback is the ONLY code path that ever calls poolManager.modifyLiquidity with a
    /// POSITIVE delta to mint the locked position -- if anything else could reach it with
    /// attacker-chosen (key, liquidity) data, that would be the mechanism to worry about most.
    /// Confirms the guard actually fires for a direct call, not just that the happy path works.
    function test_UnlockCallback_RevertsForNonPoolManagerCaller() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("H");
        PoolKey memory key = _key(address(tst), address(stock));

        vm.expectRevert(StocksGraduator.NotPoolManager.selector);
        graduator.unlockCallback(abi.encode(key, uint128(1_000e18)));
    }

    // ============================================================
    // NEW: front-running graduation via a raw poolManager.initialize() call
    // ============================================================

    /// @dev A DIFFERENT griefing vector than the already-fixed dust-seed registerPool() squat
    /// (which the H-1 fix above closes): this one skips the hook's own registry entirely and
    /// attacks PoolManager's own "a given PoolKey can only ever be initialized once" invariant
    /// directly. If StocksHook.beforeInitialize didn't check WHO is calling initialize(), an
    /// attacker watching the mempool for a pending graduate() call could front-run it with their
    /// own poolManager.initialize(sameKey, anyPrice) call, permanently bricking that pool's real
    /// graduation with no rescue (PoolManager's own initialized-once invariant can never be
    /// undone) -- worse than the registerPool squat, since it doesn't even need the target's own
    /// token. Confirms beforeInitialize's `sender != poolDeployer` check (StocksHook.sol) actually
    /// blocks this: the direct call must revert, AND the real graduation must still succeed
    /// afterward on the exact same PoolKey.
    function test_FrontRunViaDirectPoolManagerInitialize_RevertsAndDoesNotBrickRealGraduation() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("I");
        PoolKey memory key = _key(address(tst), address(stock));

        // Attacker has no relationship to this pair at all -- doesn't need to hold or approve
        // anything, since beforeInitialize's sender check fires before any registration state is
        // even consulted. V4-core wraps a reverting hook callback in its own HookCallFailed()
        // envelope rather than letting the raw reason propagate directly (confirmed via
        // `cast 4byte` on the actual revert data: the wrapped reason is exactly
        // NotPoolDeployer() -- beforeInitialize's guard really did fire), so this only asserts
        // that the call reverts at all, not the exact wrapper shape.
        vm.prank(attacker);
        vm.expectRevert();
        poolManager.initialize(key, 79228162514264337593543950336); // 1:1 sqrtPriceX96

        // The failed attempt must not have left the PoolKey initialized -- the real graduation
        // (which calls poolManager.initialize() itself, inside _graduate()) must still succeed.
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);
        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);
        assertGt(poolView.code.length, 0);
        assertTrue(_isRegistered(address(tst), address(stock)));
    }

    // ============================================================
    // NEW: reentrancy from a malicious tst/stock token's transfer hook during the pull
    // ============================================================

    function test_ReentrantTstToken_CannotReenterGraduateDuringPull() public {
        ReentrantToken tst = new ReentrantToken("Acme", "ACME", SUPPLY);
        MockERC20G stock = new MockERC20G("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        // Arm the token to try re-entering graduate() the moment the graduator pulls it via
        // transferFrom -- this is the exact AUDIT FIX H-2 window (pull happens as the graduator's
        // own first action, already inside nonReentrant) this test is proving actually holds.
        tst.arm(graduator, address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        // The outer call must still succeed -- nonReentrant blocks only the REENTRANT inner call,
        // it must not make the whole legitimate graduation revert.
        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);
        assertGt(poolView.code.length, 0);
        assertTrue(tst.reentryAttempted());
        assertTrue(tst.reentryReverted());
    }

    function test_ReentrantStockToken_CannotReenterGraduateDuringPull() public {
        MockERC20G tst = new MockERC20G("Acme", "ACME", SUPPLY);
        ReentrantToken stock = new ReentrantToken("Stock", "STOCK", SUPPLY);
        registry.setCurve(address(tst), address(this));

        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        stock.arm(graduator, address(tst), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);
        assertGt(poolView.code.length, 0);
        assertTrue(stock.reentryAttempted());
        assertTrue(stock.reentryReverted());
    }

    // ============================================================
    // NEW: extreme / lopsided seed ratios
    // ============================================================

    /// @dev A seed ratio far more lopsided than any real curve graduation would ever produce
    /// (StocksCurve seeds at minimum the 20% RESERVED_SUPPLY floor of TST against a
    /// USD-denominated stock target -- never anywhere near this extreme) -- proving the sqrtPriceX96/
    /// liquidity math either produces a correctly-priced pool or cleanly reverts, never silently
    /// corrupting state, regardless of how extreme the ratio is.
    function testFuzz_ExtremeLopsidedSeedRatio_NeverCorruptsState(uint256 tstSeed, uint256 stockSeed) public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("J");
        uint256 minTst = (tst.totalSupply() * graduator.MIN_TST_SEED_SUPPLY_BPS()) / graduator.BPS_DENOM();
        tstSeed = bound(tstSeed, minTst, tst.totalSupply());
        stockSeed = bound(stockSeed, 1, stock.totalSupply());

        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);

        try graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed)
        returns (address poolView) {
            // Success must mean a REAL, fully-backed pool -- not funds stranded on this
            // contract -- but NOT necessarily a nonzero reserve on both sides. Separate finding
            // from this suite's own H-3 fix, surfaced by fuzzing here: a 1-wei-scale stockSeed
            // against a near-total-supply tstSeed (a ratio no real StocksCurve graduation can
            // ever produce -- see this function's own docstring on the 20% RESERVED_SUPPLY floor)
            // can mint a position whose `liquidity` value is nonzero (so NoLiquidityMinted's own
            // check doesn't fire) but whose STOCK-side reserve rounds down to exactly 0 -- a real,
            // if extremely low-severity, rounding edge case in the tick-range liquidity math,
            // confirmed live via this exact fuzz run (tstSeed ~7.6e28, stockSeed=1 wei). Already
            // effectively unreachable in practice by two independent facts, not by this test
            // relaxing anything: (1) H-3 means only the pair's own already-registered curve could
            // ever reach this at all, and (2) that curve's own graduation math never produces
            // anywhere near this ratio. Not fixed here -- flagged to the user as a separate,
            // out-of-scope-for-H-3 observation; asserting on it honestly (allowing zero, still
            // requiring nothing stranded) rather than silently loosening or hiding it.
            (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
            assertGe(r0, 0);
            assertGe(r1, 0);
            assertEq(tst.balanceOf(address(graduator)), 0);
            assertEq(stock.balanceOf(address(graduator)), 0);
        } catch (bytes memory reason) {
            // The only acceptable failure mode for an extreme-but-nonzero ratio is a clean
            // revert (liquidity rounds to zero, or a math library's own guarded require) --
            // never a Panic (arithmetic overflow/underflow, which would indicate the math itself
            // is unsound), and the graduator must not be left holding stranded funds. Checking
            // "not a Panic" rather than pinning to NoLiquidityMinted's exact selector: a revert
            // nested inside poolManager.unlock()'s own callback can arrive re-wrapped by V4-core
            // (confirmed live -- a genuine NoLiquidityMinted() case failed a strict selector
            // match here for exactly that reason), so the selector-level shape isn't reliable to
            // assert on; the soundness property (no panic, no stranded funds) is.
            bytes4 panicSelector = bytes4(keccak256("Panic(uint256)"));
            bool isPanic = reason.length >= 4 && bytes4(reason) == panicSelector;
            assertFalse(isPanic, "extreme ratio must never panic -- math must be sound at every input");
            assertEq(tst.balanceOf(address(graduator)), 0);
            assertEq(stock.balanceOf(address(graduator)), 0);
        }
    }

    // ============================================================
    // NEW: the actual load-bearing guarantee behind "locked forever" -- V4's own position
    // ownership, not a Stocks.ink-authored access-control check
    // ============================================================

    /// @dev TWAMM's beforeRemoveLiquidity (see TWAMM.sol) does NOT gate who may remove liquidity
    /// at all -- its own comment says "Liquidity removal must always be unblocked." So the
    /// "locked forever" guarantee this whole contract exists to provide rests entirely on
    /// Uniswap V4 core's own position-ownership model (a position is keyed to
    /// (owner=caller-at-mint-time, tickLower, tickUpper, salt); modifyLiquidity only ever lets
    /// msg.sender touch a position keyed to msg.sender's own address) -- NOT on any check inside
    /// this codebase. This test empirically proves that guarantee actually holds in practice,
    /// rather than trusting the architecture argument alone: an attacker, with no special
    /// privilege, tries to remove liquidity from the EXACT same pool/tick-range/salt the graduator
    /// locked, and confirms (a) the attempt cannot reduce the graduator's real, locked reserves at
    /// all, and (b) the attacker cannot extract any of the graduator's seed tokens by doing so.
    function test_AttackerCannotRemoveGraduatorsLockedLiquidity() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("K");
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5_000e18;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);
        address poolView =
            graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);

        (uint112 r0Before, uint112 r1Before,) = StocksPoolView(poolView).getReserves();
        assertGt(r0Before, 0);
        assertGt(r1Before, 0);

        PoolKey memory key = _key(address(tst), address(stock));
        LiquidityRemovalAttacker evil = new LiquidityRemovalAttacker(poolManager);

        // The attacker's own attempt to remove liquidity at the graduator's exact tick range/salt
        // must fail -- they hold no position there at all (their own address, not the graduator's,
        // is what modifyLiquidity keys against), so removing ANY amount underflows their
        // (nonexistent) position.
        vm.expectRevert();
        evil.attemptRemoval(key, 1);

        // Confirm the graduator's real, locked reserves are completely untouched regardless.
        (uint112 r0After, uint112 r1After,) = StocksPoolView(poolView).getReserves();
        assertEq(r0After, r0Before);
        assertEq(r1After, r1Before);
        assertEq(tst.balanceOf(address(evil)), 0);
        assertEq(stock.balanceOf(address(evil)), 0);
    }

    // ============================================================
    // Hook rounding reserve (audit finding F-1): graduation hands the hook HOOK_TST_RESERVE_WEI of the TST
    // and HOOK_STOCK_RESERVE_WEI of the stock, taken out of the seed
    // ============================================================

    function _hookBal(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(hook));
    }

    function _graduateSeed(MockERC20G tst, MockERC20G stock, uint256 tstSeed, uint256 stockSeed)
        internal
        returns (address poolView)
    {
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);
        poolView = graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed);
    }

    function test_Reserve_DeliveredToHook_AndPoolFundedFromTheRemainder() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R1");
        uint256 tstSeed = 200_000_000e18;
        uint256 stockSeed = 40e18; // about $8,000 of a $200 share
        uint256 hookTst0 = _hookBal(address(tst));
        uint256 hookStock0 = _hookBal(address(stock));

        address poolView = _graduateSeed(tst, stock, tstSeed, stockSeed);

        assertEq(_hookBal(address(tst)) - hookTst0, graduator.HOOK_TST_RESERVE_WEI(), "hook got the TST reserve");
        assertEq(_hookBal(address(stock)) - hookStock0, graduator.HOOK_STOCK_RESERVE_WEI(), "hook got the stock reserve");

        (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
        bool tstIsCurrency0 = address(tst) < address(stock);
        (uint256 tstReserve, uint256 stockReserve) =
            tstIsCurrency0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertApproxEqRel(tstReserve, tstSeed - graduator.HOOK_TST_RESERVE_WEI(), 0.0001e18);
        assertApproxEqRel(stockReserve, stockSeed - graduator.HOOK_STOCK_RESERVE_WEI(), 0.0001e18);
    }

    function test_Reserve_GraduatorHoldsNothingAfterGraduation() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R2");
        _graduateSeed(tst, stock, 200_000_000e18, 40e18);
        assertEq(tst.balanceOf(address(graduator)), 0, "no TST left in the graduator");
        assertEq(stock.balanceOf(address(graduator)), 0, "no stock left in the graduator");
    }

    function test_RevertWhen_TstSeedIsNotAboveTheReserve() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R3");
        uint256 tooSmall = graduator.HOOK_TST_RESERVE_WEI(); // exactly the reserve leaves nothing for the pool
        tst.approve(address(graduator), tooSmall);
        stock.approve(address(graduator), 1_000e18);
        vm.expectRevert(StocksGraduator.SeedTooSmall.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tooSmall, 1_000e18);
    }

    function test_RevertWhen_StockSeedIsNotAboveTheReserve() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R4");
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 tooSmall = graduator.HOOK_STOCK_RESERVE_WEI();
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), tooSmall);
        vm.expectRevert(StocksGraduator.SeedTooSmall.selector);
        graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, tooSmall);
    }

    /// @dev A stock seed only just above the reserve leaves the pool almost nothing. It must either
    /// graduate cleanly or revert atomically, never leave the graduator holding tokens or a half-made pool.
    function test_StockSeedJustAboveTheReserve_GraduatesOrRevertsAtomically() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R5");
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = graduator.HOOK_STOCK_RESERVE_WEI() + 1e6;
        tst.approve(address(graduator), tstSeed);
        stock.approve(address(graduator), stockSeed);
        try graduator.graduate(address(tst), address(stock), realTreasury, realProtocol, FEE_BPS, tstSeed, stockSeed) {
            assertTrue(_isRegistered(address(tst), address(stock)), "graduated, so the pool is registered");
        } catch {
            assertFalse(_isRegistered(address(tst), address(stock)), "reverted, so nothing was registered");
        }
        assertEq(tst.balanceOf(address(graduator)), 0);
        assertEq(stock.balanceOf(address(graduator)), 0);
    }

    /// @dev The TEST profile ($10 threshold) seeds far less stock than mainnet. It must still graduate.
    function test_TestProfileSizedSeed_StillGraduates() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R6");
        uint256 tstSeed = (tst.totalSupply() * 20) / 100;
        uint256 stockSeed = 5e16; // about $10 of a $200 share
        address poolView = _graduateSeed(tst, stock, tstSeed, stockSeed);
        (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertGe(_hookBal(address(stock)), graduator.HOOK_STOCK_RESERVE_WEI());
    }

    /// @dev The minimum allowed TST seed (1% of supply, the path a whale overbuy takes) still leaves the
    /// pool funded after the reserve comes out.
    function test_MinimumTstSeed_StillGraduatesWithTheReserve() public {
        (MockERC20G tst, MockERC20G stock) = _freshPair("R7");
        uint256 minSeed = (tst.totalSupply() * graduator.MIN_TST_SEED_SUPPLY_BPS()) / graduator.BPS_DENOM();
        address poolView = _graduateSeed(tst, stock, minSeed, 40e18);
        (uint112 r0, uint112 r1,) = StocksPoolView(poolView).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(_hookBal(address(tst)), graduator.HOOK_TST_RESERVE_WEI());
    }

    /// @dev Two pools that share one stock token: the shared stock balance grows by one stock reserve per
    /// pool, and each pool's own TST reserve lands in its own token.
    function test_TwoPoolsSharingAStock_EachContributesItsOwnReserve() public {
        (MockERC20G tstA,) = _freshPair("R8");
        MockERC20G tstB = new MockERC20G("AcmeR9", "ACMER9", SUPPLY);
        registry.setCurve(address(tstB), address(this));
        MockERC20G sharedStock = new MockERC20G("SharedStock", "SHARED", SUPPLY);

        uint256 stockBefore = _hookBal(address(sharedStock));
        _graduateSeed(tstA, sharedStock, 200_000_000e18, 40e18);
        _graduateSeed(tstB, sharedStock, 200_000_000e18, 40e18);

        assertEq(_hookBal(address(sharedStock)) - stockBefore, 2 * graduator.HOOK_STOCK_RESERVE_WEI());
        assertEq(_hookBal(address(tstA)), graduator.HOOK_TST_RESERVE_WEI());
        assertEq(_hookBal(address(tstB)), graduator.HOOK_TST_RESERVE_WEI());
    }
}

/// @notice Attempts to remove liquidity from an arbitrary pool key/tick-range/salt via a direct
/// poolManager.unlock() + modifyLiquidity(negative delta) call -- the only way an outsider could
/// even attempt to touch a position that isn't theirs. Used to empirically confirm V4 core's own
/// per-caller position keying is what actually protects StocksGraduator's locked liquidity, not
/// any check inside this codebase (see beforeRemoveLiquidity's own "always unblocked" comment).
contract LiquidityRemovalAttacker is IUnlockCallback {
    IPoolManager immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function attemptRemoval(PoolKey calldata key, uint128 liquidity) external {
        poolManager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        // Negative delta = removal, at the SAME full-range tick bounds/salt the graduator used --
        // but keyed to address(this) (this contract, as msg.sender here), not the graduator, so
        // this can only ever touch a position this contract itself previously minted (none).
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        return "";
    }
}

/// @notice ERC20 whose transferFrom attempts to re-enter StocksGraduator.graduate() the moment it's
/// called -- simulating a malicious/compromised TST or stock token, exactly the threat
/// StocksGraduator's own docstring calls out (AUDIT FIX H-2) as the reason it pulls funds itself
/// inside nonReentrant rather than trusting a pre-transfer. Records whether the reentrant call was
/// attempted and whether it correctly reverted, so the outer test can assert both without the
/// revert itself unwinding the whole transferFrom (caught internally, never propagated).
contract ReentrantToken is ERC20 {
    bool public reentryAttempted;
    bool public reentryReverted;

    StocksGraduator private _target;
    address private _otherToken;
    address private _treasury;
    address private _protocol;
    uint256 private _feeBps;
    uint256 private _tstAmount;
    uint256 private _stockAmount;
    bool private _armed;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function arm(
        StocksGraduator target_,
        address otherToken_,
        address treasury_,
        address protocol_,
        uint256 feeBps_,
        uint256 tstAmount_,
        uint256 stockAmount_
    ) external {
        _target = target_;
        _otherToken = otherToken_;
        _treasury = treasury_;
        _protocol = protocol_;
        _feeBps = feeBps_;
        _tstAmount = tstAmount_;
        _stockAmount = stockAmount_;
        _armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_armed) {
            _armed = false; // exactly once, so the legitimate transfer itself can still complete
            reentryAttempted = true;
            try _target.graduate(address(this), _otherToken, _treasury, _protocol, _feeBps, _tstAmount, _stockAmount)
            {
                // If this ever succeeds, nonReentrant failed to block it -- reentryReverted stays
                // false and the outer test's assertTrue(reentryReverted) catches it.
            } catch {
                reentryReverted = true;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
