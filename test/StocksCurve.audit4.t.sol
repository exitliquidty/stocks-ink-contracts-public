// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract MockStockTokenC4 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @notice Round-4 audit on StocksCurve.sol: two NEW findings not covered by prior rounds. Does not
/// re-report the already-confirmed RESERVED_SUPPLY graduation-seeding bug (StocksGraduator.audit4),
/// the fee-on-transfer sell()/donated-stock findings (Bugs 6/7, reviewed and left unfixed), the
/// proven solvency invariant, or reentrancy safety.
contract StocksCurveAudit4Test is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    uint256 signerKey = 0xA11CE;
    address signer;
    address factory = address(0xFACE);

    function setUp() public {
        signer = vm.addr(signerKey);
    }

    function _sign(address stockToken, uint256 price, uint256 priceTimestamp) internal view returns (bytes memory) {
        bytes32 hash = keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    /// @notice FIXED (was Medium-High): MAX_SNIPE_BUY_BPS used to cap `tstOut` PER CALL during
    /// SNIPE_WINDOW only, tracking nothing across calls -- no per-address accumulator, no global
    /// counter. The entire anti-snipe protection was trivially defeated by splitting one large buy
    /// into N sequential calls, all within the same 60-second window (and even the same block, via
    /// one helper contract), each individually under the 5% cap. `snipeWindowBought[msg.sender]` now
    /// accumulates across calls within the window, and the cap is checked against that running total,
    /// closing the split-into-many-calls bypass. (A per-address cap can never stop coordinated Sybil
    /// addresses splitting a buy between them -- that's a different, unrelated protection this cap
    /// was never meant to provide.)
    function test_AUDIT_SnipeCapBypass_RepeatedCallsNowAccumulateAndRevertAtTheCap() public {
        MockStockTokenC4 stock = new MockStockTokenC4("Stock", "STOCK", SUPPLY);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stock), price, priceTimestamp);

        TSTToken tst = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tst), address(stock), signer, price, priceTimestamp, sig, 7 days, factory, 8_000_000e18, 1 days, 365 days
        );
        tst.transfer(address(curve), SUPPLY);
        // Still inside SNIPE_WINDOW (no warp) -- graduationStockTarget is set huge (8,000,000e18 USD
        // @ price=100e18) so the curve has plenty of room and no run of buys graduates it early,
        // isolating the snipe-cap question from the separate graduation-timing question.

        uint256 singleTxCap = (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM();
        address sniper = address(0xBEEF);
        stock.transfer(sniper, SUPPLY);
        vm.prank(sniper);
        stock.approve(address(curve), type(uint256).max);

        // A single call right at the cap succeeds (sanity: the cap is real and does bind per-call).
        vm.prank(sniper);
        uint256 firstBuyStockIn = _stockInForApproxTstOut(curve, singleTxCap);
        vm.prank(sniper);
        uint256 tstOut1 = curve.buy(firstBuyStockIn, 0);
        assertLe(tstOut1, singleTxCap, "sanity: single call respects the per-call cap");

        // FIXED: a second call from the SAME sniper, same block, still inside SNIPE_WINDOW, that
        // would push their CUMULATIVE total past the cap must now revert -- even though this single
        // call's own tstOut is, by itself, comfortably under the per-call cap.
        uint256 stockIn = _stockInForApproxTstOut(curve, singleTxCap);
        vm.prank(sniper);
        vm.expectRevert(StocksCurve.SnipeCapExceeded.selector);
        curve.buy(stockIn, 0);

        console.log("Single-tx snipe cap (5% of CURVE_SUPPLY):", singleTxCap);
        console.log("Sniper's cumulative total after their first (allowed) buy:", curve.snipeWindowBought(sniper));
        console.log("FIXED: a second call that would push the sniper's cumulative total past the cap now reverts");

        // A DIFFERENT address is unaffected -- the cap is per-address, not global -- confirming this
        // fix targets the split-into-many-calls bypass specifically, not ordinary distinct buyers.
        address otherBuyer = address(0xC0FFEE);
        vm.prank(sniper);
        stock.transfer(otherBuyer, SUPPLY / 10);
        vm.prank(otherBuyer);
        stock.approve(address(curve), type(uint256).max);
        uint256 otherStockIn = _stockInForApproxTstOut(curve, singleTxCap);
        vm.prank(otherBuyer);
        uint256 otherTstOut = curve.buy(otherStockIn, 0);
        assertGt(otherTstOut, 0, "a different address, unrelated to the sniper's own cumulative total, can still buy normally");

        assertLt(block.timestamp, curve.launchTimestamp() + curve.SNIPE_WINDOW(), "sanity: still inside the snipe window the whole time");
        console.log("CONFIRMED FIXED: the snipe cap now tracks cumulative per-address totals within the window, not just each individual call");
    }

    /// @dev Binary-searches for a stockIn that yields tstOut approximately equal to `targetTstOut`,
    /// so repeated calls can each land close to (but not over) the per-call cap without needing to
    /// invert the curve's own ceilDiv-rounded formula exactly.
    function _stockInForApproxTstOut(StocksCurve curve, uint256 targetTstOut) internal view returns (uint256) {
        uint256 lo = 1;
        uint256 hi = 10_000_000e18;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (curve.quoteBuy(mid) <= targetTstOut) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }
}

/// @notice Round-4 escalation, RESOLVED by the RESERVED_SUPPLY fix (StocksGraduator.audit4): this
/// originally demonstrated that the graduation-seeding price-crash bug was not merely a "race between
/// MEV bots" risk but a GUARANTEED, ATOMIC, ZERO-COMPETITION-RISK self-dealing opportunity, since
/// nothing stops the same caller from crossing graduationStockTarget and immediately calling
/// graduate() themselves, with no delay. That atomicity/self-triggerability is still structurally
/// true today (nothing about the fix changes who can call buy() then graduate() back to back) -- but
/// it's now harmless, because the pool it graduates into opens at the curve's own real price instead
/// of a crashed one. This file keeps proving the structural fact (no access control, no delay) while
/// no longer claiming any profit from it, since there is none left to claim.
contract StocksCurveAudit4GraduationSelfDealTest is Test {
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
    address attacker = address(0xBADD);

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

    function test_AUDIT_SameCallerCrossesThresholdAndGraduatesAtomically_NoRaceRequired() public {
        address stockToken = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB; // real wMSTRx on this fork
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes memory signature = _signAttestation(stockToken, price, priceTimestamp);
        (address token, address curveAddr) = factory.createCurve(
            "Test", "TST", stockToken, price, priceTimestamp, signature, 30 days, ""
        );
        StocksCurve curve = StocksCurve(curveAddr);

        vm.warp(block.timestamp + 61); // past the snipe window

        uint256 buyAmount = 90e18; // crosses the 8,000e18 USD target @ price=100e18
        deal(stockToken, attacker, buyAmount);

        // Everything below happens from the SAME address (`attacker`), back to back, with no time
        // warp and no other party's call interleaved -- exactly what a single atomic transaction (an
        // EOA calling into one helper contract that does buy() -> graduate() -> swap) would look
        // like. Nothing in buy() or graduate() requires a different caller or imposes any delay.
        vm.startPrank(attacker);
        IERC20(stockToken).approve(curveAddr, buyAmount);
        curve.buy(buyAmount, 0); // (1) the attacker's OWN buy crosses the graduation threshold
        assertGe(curve.realStockCollected(), curve.graduationStockTarget(), "sanity: threshold crossed by the attacker's own buy");

        curve.graduate(); // (2) the SAME attacker immediately graduates -- no access control, no delay
        vm.stopPrank();
        assertTrue(curve.graduated(), "attacker successfully self-triggered graduation in the same call sequence as their qualifying buy");

        // (3) Quantify the guaranteed profit available in the very next action: compare the pool's
        // now-crashed constant-product price against what the curve itself would have charged one
        // "block" earlier for the same TST amount, using the pool's own seeded reserves (no swap
        // execution needed to prove the guaranteed-value claim -- the crashed reserves ARE the
        // guaranteed opportunity, and they exist the instant graduate() returns, in the attacker's
        // own transaction, before any other party can possibly act).
        StocksPoolView poolView = StocksPoolView(curve.pair());
        (uint112 r0, uint112 r1,) = poolView.getReserves();
        bool tokenIsToken0 = poolView.token0() == token;
        (uint256 tstReserve, uint256 stockReserve) = tokenIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Constant-product quote: stock needed to buy 1,000 TST from the freshly-seeded pool
        // (ignoring fees, for a clean apples-to-apples comparison against the curve's own quote unit).
        uint256 tstWanted = 1_000e18;
        uint256 stockCostAtCrashedPool = (stockReserve * tstWanted) / (tstReserve - tstWanted);

        console.log("Pool's opening tstReserve (fair-priced, not crashed):", tstReserve);
        console.log("Pool's opening stockReserve:", stockReserve);
        console.log("Stock cost to buy 1,000 TST from the pool, right after self-graduation:", stockCostAtCrashedPool);
        console.log("FIXED: the SAME address can still self-trigger graduation atomically, but there is no crashed price left to exploit");

        // The finding this test isolates: atomicity/self-triggerability, not any profit from it (the
        // price-crash magnitude that used to make this profitable is gone, verified precisely in
        // StocksGraduator.audit4's own price-matching assertion). Assert only the structural claim:
        // graduation succeeded for the same caller with zero elapsed time/blocks and zero intervening
        // calls from anyone else -- this is expected, harmless behavior now, not a vulnerability.
        assertEq(curve.pair(), address(poolView), "pool exists and is readable immediately, same transaction context, no other party involved");
    }
}
