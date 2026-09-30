// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";

contract MockStockToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Real user funds move through StocksCurve.buy()/sell() every single trade before a pool
/// ever graduates -- this is the second-most-load-bearing contract in the stack after
/// StocksGraduator (which holds the LP position this curve eventually seeds). No dedicated test
/// file exercised its own buy/sell math, snipe protection, or skim correctness in isolation
/// anywhere in this repo before this file -- everything that touched it did so only incidentally,
/// via full-stack freshfork/graduation tests. This suite is standalone (no factory, no PoolManager,
/// no graduation) specifically so it can fuzz the bonding-curve math itself directly and cheaply.
contract StocksCurveSecurityTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PRICE_DECIMALS = 1e18;

    uint256 signerKey = 0xA11CE;
    address signer;
    address factory = address(0xFACE);
    address attacker = address(0xBAD);

    TSTToken tst;
    MockStockToken stock;

    function setUp() public {
        signer = vm.addr(signerKey);
    }

    function _sign(address stockToken, uint256 price, uint256 priceTimestamp, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash = keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(hash));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Real deploy order (matches StocksLaunchFactory.createCurve exactly): TST token is
    /// minted to the FACTORY first, then the curve is deployed (tstToken is immutable, fixed at
    /// construction), then the factory transfers the full supply to the curve.
    function _deployCurveAndTst(uint256 price, string memory tag)
        internal
        returns (StocksCurve curve, TSTToken tstToken, MockStockToken stockToken)
    {
        stockToken = new MockStockToken(string.concat("Stock", tag), string.concat("STOCK", tag), SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp, signerKey);

        tstToken = new TSTToken(string.concat("Acme", tag), string.concat("ACME", tag), SUPPLY, address(this));
        curve = new StocksCurve(
            address(tstToken),
            address(stockToken),
            signer,
            price,
            priceTimestamp,
            sig,
            7 days,
            factory,
            8_000e18,
            1 days,
            365 days
        );
        tstToken.transfer(address(curve), SUPPLY);
    }

    // ============================================================
    // Attestation validation -- the curve's own launch-integrity guarantee
    // ============================================================

    function test_RevertWhen_AttestationSignedByWrongKey() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 wrongKey = 0xBAD5;
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(s), 100e18, priceTimestamp, wrongKey);

        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_AttestationBoundToDifferentStockToken() public {
        MockStockToken realStock = new MockStockToken("Stock", "STOCK", SUPPLY);
        MockStockToken otherStock = new MockStockToken("Other", "OTHER", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        // Signed for otherStock, but presented alongside realStock -- the hash won't match.
        bytes memory sig = _sign(address(otherStock), 100e18, priceTimestamp, signerKey);

        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        new StocksCurve(address(0xC0FFEE), address(realStock), signer, 100e18, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_AttestationBoundToDifferentFactory() public {
        // Same cross-factory-replay protection MemeStockCurveV2/V3 rely on -- factory is baked
        // into the signed hash, so a signature obtained via one factory can't be replayed against
        // a curve deployed with a different `_factory` address, even with identical price/token/
        // timestamp/signer.
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        address wrongFactory = address(0xDEAD);
        bytes32 hash = keccak256(abi.encodePacked(wrongFactory, address(s), uint256(100e18), priceTimestamp));
        (uint8 v, bytes32 r, bytes32 sVal) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(hash));
        bytes memory sig = abi.encodePacked(r, sVal, v);

        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_PriceIsZero() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(s), 0, priceTimestamp, signerKey);
        vm.expectRevert(StocksCurve.InvalidPrice.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 0, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_PriceTimestampStale() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        vm.warp(block.timestamp + 10 minutes);
        uint256 staleTimestamp = block.timestamp - 6 minutes; // PRICE_MAX_AGE is 5 minutes
        bytes memory sig = _sign(address(s), 100e18, staleTimestamp, signerKey);
        vm.expectRevert(StocksCurve.StalePrice.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, staleTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_PriceTimestampInFuture() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 futureTimestamp = block.timestamp + 1;
        bytes memory sig = _sign(address(s), 100e18, futureTimestamp, signerKey);
        vm.expectRevert(StocksCurve.StalePrice.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, futureTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_RewardsDurationTooShort() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(s), 100e18, priceTimestamp, signerKey);
        vm.expectRevert(StocksCurve.InvalidRewardsDuration.selector);
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, priceTimestamp, sig, 30 minutes, factory, 8_000e18, 1 days, 365 days);
    }

    function test_RevertWhen_RewardsDurationTooLong() public {
        MockStockToken s = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(s), 100e18, priceTimestamp, signerKey);
        vm.expectRevert(StocksCurve.InvalidRewardsDuration.selector);
        // 366 days -- just above this file's fixture bound of 365 days (see 8_000e18/1 days/365
        // days below, matching the current mainnet defaults; was 91 days when the bound was 90 days).
        new StocksCurve(address(0xC0FFEE), address(s), signer, 100e18, priceTimestamp, sig, 366 days, factory, 8_000e18, 1 days, 365 days);
    }

    // ============================================================
    // Snipe protection: the ONLY thing standing between "fair launch" and a bot buying the
    // entire curve in the first block
    // ============================================================

    function test_SnipeProtection_BlocksOversizedBuyWithinWindow() public {
        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(365e18, "N"); // $365, TSLA-scale
        uint256 cap = (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM(); // 5%

        // Binary-search-free approach: quote a stock input sized to land comfortably above the
        // cap, confirm it reverts within the window.
        uint256 stockIn = curve.graduationStockTarget(); // far more than needed to exceed 5% of supply
        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);

        uint256 quoted = curve.quoteBuy(stockIn);
        assertGt(quoted, cap, "test setup: this buy must actually exceed the snipe cap to be meaningful");

        vm.expectRevert(StocksCurve.SnipeCapExceeded.selector);
        curve.buy(stockIn, 0);
    }

    function test_SnipeProtection_ExactCapSizedBuySucceedsWithinWindow() public {
        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(365e18, "O");
        uint256 cap = (curve.CURVE_SUPPLY() * curve.MAX_SNIPE_BUY_BPS()) / curve.BPS_DENOM();

        // Solve for a stockIn that quotes to approximately (but not over) the cap via a coarse
        // binary search over the curve's own quoteBuy -- avoids re-deriving the bonding-curve
        // formula's inverse by hand.
        uint256 lo = 0;
        uint256 hi = curve.graduationStockTarget();
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (curve.quoteBuy(mid) <= cap) lo = mid;
            else hi = mid - 1;
        }
        stockToken.mint(address(this), lo);
        stockToken.approve(address(curve), lo);
        if (lo > 0) {
            uint256 tstOut = curve.buy(lo, 0);
            assertLe(tstOut, cap);
        }
    }

    function test_SnipeProtection_AllowsOversizedBuyAfterWindowCloses() public {
        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(365e18, "P");
        uint256 stockIn = curve.graduationStockTarget();
        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);

        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1);
        uint256 tstOut = curve.buy(stockIn, 0);
        assertGt(tstOut, 0);
    }

    // ============================================================
    // Bonding-curve math soundness: no rounding-exploit round-trip profit
    // ============================================================

    /// @dev The single most important AMM-math invariant: buying then immediately selling back
    /// the exact TST you just received must never return MORE stock than you put in. If
    /// quoteBuy/quoteSell's rounding ever favored the trader instead of the curve, this would be
    /// a free-money exploit repeatable to drain the whole reserve. Math.ceilDiv in both functions
    /// is specifically chosen to round in the curve's favor -- this proves that choice actually
    /// holds under fuzzing, not just by inspection.
    function testFuzz_BuyThenSellRoundTrip_NeverProfitable(uint256 stockIn) public {
        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(365e18, "Q");
        stockIn = bound(stockIn, 1e6, curve.graduationStockTarget() / 10); // stay well clear of sold-out/snipe edges
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1); // isolate the math from snipe capping

        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);
        uint256 tstOut = curve.buy(stockIn, 0);
        vm.assume(tstOut > 0);

        uint256 stockBack = curve.quoteSell(tstOut);
        assertLe(stockBack, stockIn, "round-trip must never manufacture free stock");
    }

    /// @dev Same invariant, the other direction: selling then immediately buying back the exact
    /// stock you received must never return MORE TST than you sold.
    function testFuzz_SellThenBuyRoundTrip_NeverProfitable(uint256 initialStockIn, uint256 sellAmount) public {
        (StocksCurve curve, TSTToken tstToken, MockStockToken stockToken) = _deployCurveAndTst(365e18, "R");
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1);

        initialStockIn = bound(initialStockIn, 1e6, curve.graduationStockTarget() / 10);
        stockToken.mint(address(this), initialStockIn);
        stockToken.approve(address(curve), initialStockIn);
        uint256 tstHeld = curve.buy(initialStockIn, 0);
        vm.assume(tstHeld > 1);

        sellAmount = bound(sellAmount, 1, tstHeld);
        // sell() itself reverts with ZeroAmount if the quote rounds to zero (a real, intentional
        // guard for tiny inputs, not a bug) -- filter those out via the same quote before calling,
        // rather than letting the revert propagate past a would-be post-hoc assume.
        vm.assume(curve.quoteSell(sellAmount) > 0);
        tstToken.approve(address(curve), sellAmount);
        uint256 stockOut = curve.sell(sellAmount, 0);

        uint256 tstBack = curve.quoteBuy(stockOut);
        assertLe(tstBack, sellAmount, "round-trip must never manufacture free TST");
    }

    // ============================================================
    // Extreme construction-time `price` values -- every other test in this file (and every
    // freshfork test in the whole repo) constructs curves against one fixed, realistic price
    // (250-365e18). Nothing before this fuzzes the CONSTRUCTOR's own price parameter itself, which
    // feeds directly into graduationStockTarget/virtualStockReserve and from there into every
    // quoteBuy/quoteSell multiplication downstream -- exactly the kind of arithmetic a classic
    // DeFi overflow/precision bug hides in.
    // ============================================================

    /// @dev Fuzzes `price` across an extremely wide range (1 wei/share up to 1e30) and confirms
    /// construction either succeeds cleanly or reverts with the documented InvalidPrice() guard
    /// (graduationStockTarget rounding to 0 for a large enough price) -- NEVER an undocumented raw
    /// arithmetic panic (overflow, division by zero) from graduationUsdThreshold*PRICE_DECIMALS/
    /// price or the virtualStockReserve division that follows it.
    function testFuzz_Construct_ExtremePriceRange_NeverPanicsOnlyDocumentedRevert(uint256 price) public {
        price = bound(price, 1, 1e30);
        MockStockToken stockToken = new MockStockToken("PriceFuzzStock", "PFS", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), price, priceTimestamp, signerKey);

        uint256 expectedTarget = (8_000e18 * PRICE_DECIMALS) / price; // mirrors this file's fixture graduationUsdThreshold exactly
        if (expectedTarget == 0) {
            vm.expectRevert(StocksCurve.InvalidPrice.selector);
            new StocksCurve(address(0xC0FFEE), address(stockToken), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
        } else {
            StocksCurve curve = new StocksCurve(
                address(0xC0FFEE), address(stockToken), signer, price, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
            );
            assertEq(curve.graduationStockTarget(), expectedTarget, "graduationStockTarget must exactly match the documented formula, no silent rounding surprise");
            assertEq(curve.virtualStockReserve(), expectedTarget / 3, "virtualStockReserve must exactly match VIRTUAL_RESERVE_DIVISOR");
        }
    }

    /// @dev For the subset of extreme prices where construction succeeds, confirm a real buy()
    /// against that curve never panics either -- exercises quoteBuy's own
    /// oldVirtualStock*remaining / newVirtualStock chain of multiplications at the SAME extreme
    /// scale the constructor just accepted, not just the constructor math in isolation above.
    function testFuzz_BuyAgainstExtremePriceCurve_NeverPanics(uint256 price, uint256 stockIn) public {
        price = bound(price, 1, 1e30);
        uint256 expectedTarget = (8_000e18 * PRICE_DECIMALS) / price;
        vm.assume(expectedTarget > 0); // constructor would revert InvalidPrice otherwise, covered by the test above

        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(price, "EXTREME");
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1); // isolate from snipe capping, same as the round-trip fuzz tests above

        // Bound stockIn to a real, meaningful range relative to THIS curve's own scale (which
        // varies enormously across the fuzzed price) rather than a fixed absolute range -- a fixed
        // small range would either always underflow-round-to-zero (astronomically high price) or
        // never come close to exercising interesting curve depth (astronomically low price).
        stockIn = bound(stockIn, 1, expectedTarget * 2 > 0 ? expectedTarget * 2 : type(uint256).max / 4);

        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);
        // A real, EXPECTED revert (ZeroAmount if tstOut rounds to 0 for a relatively tiny stockIn
        // against a huge virtualStockReserve, or CurveSoldOut if this particular extreme scale
        // somehow lets a single buy exhaust CURVE_SUPPLY) is fine and NOT what this test is
        // checking for -- only an unexpected raw panic (arithmetic overflow/underflow, division by
        // zero) would fail it, since forge surfaces panics as their own distinct failure separate
        // from a clean custom-error revert.
        try curve.buy(stockIn, 0) returns (uint256 tstOut) {
            assertLe(curve.tokensSold(), curve.CURVE_SUPPLY(), "tokensSold must never exceed CURVE_SUPPLY even at extreme price scale");
            assertGt(tstOut, 0, "a successful (non-reverting) buy must have produced real, nonzero output");
        } catch (bytes memory reason) {
            // Confirm it's one of the documented custom errors, not a bare Panic(uint256) selector
            // (0x4e487b71) -- that's the one outcome this test exists to rule out.
            bytes4 panicSelector = 0x4e487b71;
            bytes4 gotSelector;
            assembly {
                gotSelector := mload(add(reason, 32))
            }
            assertTrue(gotSelector != panicSelector, "buy() raised a raw arithmetic Panic instead of a documented custom error, at extreme price scale");
        }
    }

    // ============================================================
    // Sold-out / graduation boundary
    // ============================================================

    function test_RevertWhen_GraduateCalledBeforeThresholdReached() public {
        (StocksCurve curve,,) = _deployCurveAndTst(365e18, "S");
        vm.expectRevert(StocksCurve.NotReady.selector);
        curve.graduate();
    }

    function test_RevertWhen_SellingMoreThanEverBought() public {
        // Bespoke setup (not _deployCurveAndTst, which sends TST's ENTIRE supply to the curve,
        // leaving the deployer with nothing left to hand an attacker): keep 1_000e18 TST back so
        // the attacker can hold real TST from an unrelated source (e.g. a plain transfer) while
        // this curve instance's own tokensSold stays at 0 -- selling anything must revert with the
        // dedicated InsufficientTstSupply error rather than a raw underflow panic.
        MockStockToken stockToken = new MockStockToken("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stockToken), 365e18, priceTimestamp, signerKey);
        TSTToken tstToken = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve = new StocksCurve(
            address(tstToken), address(stockToken), signer, 365e18, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days
        );
        tstToken.transfer(address(curve), SUPPLY - 1_000e18);
        tstToken.transfer(attacker, 1_000e18);

        vm.startPrank(attacker);
        tstToken.approve(address(curve), 1_000e18);
        vm.expectRevert(StocksCurve.InsufficientTstSupply.selector);
        curve.sell(1_000e18, 0);
        vm.stopPrank();
    }

    // ============================================================
    // skim(): TST-only cleanup, always burned -- no caller-chosen destination, nothing to race for
    // ============================================================

    function test_Skim_BurnsStrayTst_NeverTouchesCommittedTstSupply() public {
        (StocksCurve curve, TSTToken tstToken, MockStockToken stockToken) = _deployCurveAndTst(365e18, "U");
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1);

        // AuditAgent finding #8's fix: buy() now caps how far a single trade can push `remaining`
        // toward StocksGraduator's own minimum seed floor, since a sufficiently large buy against this
        // fixture's own small virtual reserve would otherwise consume nearly the entire curve. Lowered
        // from the file's earlier shared 5_000e18 convenience value to one that still exercises a real,
        // meaningful buy (this test doesn't depend on the exact resulting tokensSold) without tripping
        // that guard.
        uint256 stockIn = 10e18;
        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);

        // A stray direct donation of TST, simulating a mistaken transfer -- the only thing skim()
        // still touches.
        uint256 strayTst = 42e18;
        deal(address(tstToken), address(this), strayTst);
        tstToken.transfer(address(curve), strayTst);

        uint256 tokensSoldBefore = curve.tokensSold();
        uint256 burnBefore = tstToken.balanceOf(curve.BURN_ADDRESS());
        curve.skim();

        // Exactly the stray TST got burned -- nothing else moved, no destination for anyone to
        // race for.
        assertEq(tstToken.balanceOf(curve.BURN_ADDRESS()) - burnBefore, strayTst);
        assertEq(curve.tokensSold(), tokensSoldBefore, "skim() must never touch tokensSold accounting");
    }

    /// @dev AUDIT FIX regression: skim() used to take a caller-chosen `to` and would sweep BOTH
    /// stray stock and stray TST to it -- a fully permissionless "first caller wins" race letting
    /// any uninvolved third party redirect real value to themselves. Confirms the fix: stock is no
    /// longer touched by skim() at all (it's captured automatically at graduation instead, via
    /// _graduate()'s own full-live-balance sweep), so there's nothing left for a bystander to
    /// claim, regardless of who calls skim() or how the excess got there.
    function test_Skim_StockExcess_NeverTouchedByAnyone_CapturedAtGraduationInstead() public {
        (StocksCurve curve,, MockStockToken stockToken) = _deployCurveAndTst(365e18, "V");
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1);

        // See the sibling skim test above for why this is lowered from the file's earlier shared
        // 5_000e18 convenience value (AuditAgent finding #8's fix).
        uint256 stockIn = 10e18;
        stockToken.mint(address(this), stockIn);
        stockToken.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);

        uint256 excess = 100e18;
        stockToken.mint(address(curve), excess);

        uint256 curveStockBefore = stockToken.balanceOf(address(curve));
        vm.prank(attacker);
        curve.skim();

        // Not a single wei of stock moved -- attacker gained nothing, and the excess is still
        // sitting in the curve, exactly where _graduate() will pick it up later.
        assertEq(stockToken.balanceOf(attacker), 0, "attacker must gain nothing from calling skim()");
        assertEq(stockToken.balanceOf(address(curve)), curveStockBefore, "stock balance must be completely untouched by skim()");
    }

    // ============================================================
    // Reentrancy: a malicious stock token's transfer hook during buy()'s pull
    // ============================================================

    function test_ReentrantStockToken_CannotReenterBuyDuringPull() public {
        ReentrantStock stock = new ReentrantStock("Stock", "STOCK", SUPPLY);
        uint256 priceTimestamp = block.timestamp;
        bytes memory sig = _sign(address(stock), 365e18, priceTimestamp, signerKey);
        TSTToken tstToken = new TSTToken("Acme", "ACME", SUPPLY, address(this));
        StocksCurve curve =
            new StocksCurve(address(tstToken), address(stock), signer, 365e18, priceTimestamp, sig, 7 days, factory, 8_000e18, 1 days, 365 days);
        tstToken.transfer(address(curve), SUPPLY);
        vm.warp(block.timestamp + curve.SNIPE_WINDOW() + 1);

        // See test_Skim_BurnsStrayTst_NeverTouchesCommittedTstSupply above for why this is lowered
        // from the file's earlier shared 5_000e18 convenience value (AuditAgent finding #8's fix).
        uint256 stockIn = 10e18;
        stock.mint(address(this), stockIn);
        stock.approve(address(curve), stockIn);
        stock.arm(curve, stockIn);

        uint256 tstOut = curve.buy(stockIn, 0);
        assertGt(tstOut, 0);
        assertTrue(stock.reentryAttempted());
        assertTrue(stock.reentryReverted());
    }
}

/// @notice ERC20 whose transferFrom attempts to re-enter StocksCurve.buy() the moment it's called
/// -- simulating a malicious/compromised stock token, the same threat class StocksGraduator's own
/// pull-based design defends against (see StocksGraduator.security.t.sol's ReentrantToken).
contract ReentrantStock is ERC20 {
    bool public reentryAttempted;
    bool public reentryReverted;
    StocksCurve private _target;
    uint256 private _amount;
    bool private _armed;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(StocksCurve target_, uint256 amount_) external {
        _target = target_;
        _amount = amount_;
        _armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_armed) {
            _armed = false;
            reentryAttempted = true;
            try _target.buy(_amount, 0) {
                // Should never succeed -- nonReentrant must block it.
            } catch {
                reentryReverted = true;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
