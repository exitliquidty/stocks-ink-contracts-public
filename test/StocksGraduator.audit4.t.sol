// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// Round-4 audit finding on StocksGraduator/StocksCurve's graduation seeding, RESOLVED: the graduated
// pool's STARTING PRICE used to silently diverge from the bonding curve's own last marginal price,
// because StocksCurve._graduate() seeded the pool with its FULL live TST balance
// (TOTAL_SUPPLY - tokensSold) rather than a price-matched amount. The difference between the full
// balance and the genuinely-unsold curve portion is exactly RESERVED_SUPPLY (200,000,000e18 -- 20%
// of total supply, declared in StocksCurve.sol but never otherwise referenced anywhere else in the
// codebase), which used to get dumped into the pool's initial liquidity alongside the unsold curve
// remainder. This root cause lived in StocksCurve.sol's own `_graduate()`
// (StocksGraduator.graduate()/`_liquidityForAmounts` remain fully correct GIVEN whatever ratio
// they're handed -- confirmed safe in prior rounds), so this file exercises it end to end through the
// real launch stack, the way an economic actor actually reaches it (there is no way to trigger
// StocksGraduator.graduate() directly except via the real registered curve, confirmed by the existing
// H-3 hijack-fix suite).
//
// FIX: _graduate() now computes tstToSeed = realStockCollected * remaining / oldVirtualStock --
// mirroring quoteSell's own marginal-price formula exactly, so the new pool's price
// (stockToSeed / tstToSeed = oldVirtualStock / remaining) reproduces the curve's own instantaneous
// marginal price instead of merely approximating it. Seeding with just the unsold remainder (without
// this ratio) was tried and found NOT precise enough -- virtualStockReserve is a permanent, nonzero
// offset in the curve's own pricing, so a naive remaining-only seed still opened measurably below the
// curve's real price. RESERVED_SUPPLY is burned except for whatever's needed to top the seed up to
// StocksGraduator's own MIN_TST_SEED_SUPPLY_BPS floor, for the rare case a single oversized buy would
// otherwise leave too little to seed a real pool at all (see StocksCurve.audit5.t.sol for that case).

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract StocksGraduatorAudit4Test is Test {
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;
    uint256 constant GRADUATION_USD_THRESHOLD = 8_000e18;
    uint256 constant MIN_REWARDS_DURATION = 1 hours;
    uint256 constant MAX_REWARDS_DURATION = 365 days;
    uint48 constant VOTING_DELAY = 1 hours;
    uint32 constant VOTING_PERIOD = 1 hours;
    uint256 constant PROPOSAL_THRESHOLD_BPS = 100;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    TokenMetadataRegistry metadataRegistry;

    uint256 trustedSignerKey = 0xA11CE;
    address trustedSigner;
    address protocol = address(0xF00D);
    address buyer = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");
        trustedSigner = vm.addr(trustedSignerKey);

        metadataRegistry = new TokenMetadataRegistry();
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
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, predictedFactory);
        require(address(graduator) == predictedGraduator, "graduator address mismatch");

        factory = new StocksLaunchFactory(
            trustedSigner,
            protocol,
            address(hook),
            governorFactory,
            stakingFactory,
            curveDeployer,
            address(graduator),
            address(metadataRegistry),
            GRADUATION_USD_THRESHOLD,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_BPS
        );
        require(address(factory) == predictedFactory, "factory address mismatch");
    }

    function _signAttestation(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(address(factory), stockToken, price, priceTimestamp));
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(trustedSignerKey, ethSignedDigest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice FIXED: the graduated pool now opens at (within rounding dust of) the curve's own last
    /// marginal price -- _graduate() seeds it with a price-matched amount instead of the curve's FULL
    /// TST balance, and the untouched RESERVED_SUPPLY is burned rather than silently diluting every
    /// already-purchased TST token's real backing the instant the pool opens.
    function test_AUDIT_GraduationSeeding_NowMatchesCurvesOwnPrice_ReservedSupplyBurned() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB; // real wMSTRx on this fork
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curveAddr) = factory.createCurve(
            "Test", "TST", stockToken, price, priceTimestamp, signature, 30 days, ""
        );
        StocksCurve curve = StocksCurve(curveAddr);

        vm.warp(block.timestamp + 61); // past the snipe window

        // Buy enough stock to cross the USD graduation target (80e18 stock @ price=100e18 for the
        // 8,000e18 USD threshold configured above).
        uint256 buyAmount = 90e18;
        deal(stockToken, buyer, buyAmount);
        vm.startPrank(buyer);
        IERC20(stockToken).approve(curveAddr, buyAmount);
        curve.buy(buyAmount, 0);
        vm.stopPrank();
        assertGe(curve.realStockCollected(), curve.graduationStockTarget(), "sanity: graduation target reached");

        // --- Measure the curve's own "fair" continuation price the instant before graduation ---
        uint256 tokensSoldBefore = curve.tokensSold();
        uint256 curveTstBalanceBefore = IERC20(token).balanceOf(curveAddr);
        uint256 remainingCurveSupply = curve.CURVE_SUPPLY() - tokensSoldBefore;
        // quoteSell(1e18): real stock a seller gets for 1 TST at the curve's live rate, right now.
        uint256 fairStockPerTst = curve.quoteSell(1e18);

        console.log("tokensSold before graduation:", tokensSoldBefore);
        console.log("curve's own TST balance (full, no longer all seeded):", curveTstBalanceBefore);
        console.log("genuinely-unsold curve remainder (CURVE_SUPPLY - tokensSold):", remainingCurveSupply);
        console.log("RESERVED_SUPPLY, now burned instead of seeded:", curve.RESERVED_SUPPLY());
        console.log("curve's fair price: stock received for selling 1 TST right now:", fairStockPerTst);

        // Sanity: the full balance still exceeds the genuinely-unsold remainder by exactly
        // RESERVED_SUPPLY -- confirming the reserve really is sitting there, available to be
        // mishandled, so the fix below is meaningfully exercised rather than vacuously true.
        assertEq(
            curveTstBalanceBefore, remainingCurveSupply + curve.RESERVED_SUPPLY(), "sanity: full balance == unsold remainder + untouched reserved supply"
        );

        uint256 burnBalanceBefore = IERC20(token).balanceOf(curve.BURN_ADDRESS());
        address hookAddr = factory.hook();
        uint256 hookTstBefore = IERC20(token).balanceOf(hookAddr);
        uint256 hookStockBefore = IERC20(stockToken).balanceOf(hookAddr);

        curve.graduate();
        assertTrue(curve.graduated());

        // The governor the real launch flow just created has its quorum locked: not even the governor itself
        // (the only caller onlyGovernance accepts) can change it, and it is still the hardcoded 10%.
        StocksGovernor realGov = StocksGovernor(payable(curve.governor()));
        assertEq(realGov.quorumNumerator(), 10, "quorum is the hardcoded 10%");
        vm.prank(address(realGov));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        realGov.updateQuorumNumerator(0);
        assertEq(realGov.quorumNumerator(), 10, "and it is still 10% afterward");

        // The graduator hands the hook a tiny rounding reserve of BOTH tokens (see StocksGraduator's
        // HOOK_RESERVE_WEI comment), taken out of the seed.
        uint256 hookTstReserve = StocksGraduator(factory.v4Graduator()).HOOK_TST_RESERVE_WEI();
        uint256 hookStockReserve = StocksGraduator(factory.v4Graduator()).HOOK_STOCK_RESERVE_WEI();
        assertEq(hookTstReserve, 1e20, "the TST reserve is 100 whole TST");
        assertEq(hookStockReserve, 1e12, "the stock reserve is a millionth of a share");
        assertEq(IERC20(token).balanceOf(hookAddr) - hookTstBefore, hookTstReserve, "hook received the TST reserve");
        assertEq(IERC20(stockToken).balanceOf(hookAddr) - hookStockBefore, hookStockReserve, "hook received the stock reserve");

        // --- Measure the pool's actual opening price ---
        StocksPoolView poolView = StocksPoolView(curve.pair());
        (uint112 r0, uint112 r1,) = poolView.getReserves();
        bool tokenIsToken0 = poolView.token0() == token;
        (uint256 tstReserve, uint256 stockReserve) = tokenIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Pool's own opening price for 1 TST, in stock terms (same units as fairStockPerTst above).
        uint256 poolStockPerTst = (stockReserve * 1e18) / tstReserve;

        console.log("pool's seeded tstReserve:", tstReserve);
        console.log("pool's seeded stockReserve:", stockReserve);
        console.log("pool's OPENING price: stock per 1 TST:", poolStockPerTst);

        // FIXED: the pool now opens within rounding dust of the curve's own last marginal price --
        // no more free arbitrage for whoever trades first. Allow up to 0.01% relative difference for
        // integer-division dust, nowhere close to the ~2x-3x crash this test used to demonstrate.
        uint256 diff = fairStockPerTst > poolStockPerTst ? fairStockPerTst - poolStockPerTst : poolStockPerTst - fairStockPerTst;
        assertLt(diff * 10_000, fairStockPerTst, "FIXED: pool's opening price must be within 0.01% of the curve's own last quoted price");

        // FIXED: RESERVED_SUPPLY (and, since price-matching intentionally seeds LESS than the raw
        // unsold remainder -- oldVirtualStock exceeds realStockCollected by the permanent virtual
        // offset -- a bit more besides) is burned, not seeded into the pool nor left anywhere
        // claimable. Check the real invariant (everything not seeded is burned, accounting closes
        // exactly) rather than assuming the burned amount is exactly RESERVED_SUPPLY.
        uint256 burnBalanceAfter = IERC20(token).balanceOf(curve.BURN_ADDRESS());
        // Uniswap's own sqrt-price liquidity math can round the ACTUAL minted reserve a few wei away
        // from the nominal tstToSeed requested -- allow tiny dust, not exact equality.
        assertApproxEqAbs(burnBalanceAfter - burnBalanceBefore, curveTstBalanceBefore - tstReserve - hookTstReserve, 1e6, "FIXED: every TST not seeded into the pool is accounted for by the burn");
        assertGe(burnBalanceAfter - burnBalanceBefore, curve.RESERVED_SUPPLY(), "FIXED: at least the full untouched reserved supply is burned, never seeded");
        assertEq(IERC20(token).balanceOf(curveAddr), 0, "curve holds no leftover TST after graduation");

        console.log("CONFIRMED FIXED: pool opens at the curve's own price, RESERVED_SUPPLY burned instead of diluting it");
    }
}
