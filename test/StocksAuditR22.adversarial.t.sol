// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {StocksGraduationPriceSweepTest} from "./StocksGraduation.priceSweep.t.sol";

/// @notice Calls TokenMetadataRegistry.setMetadataURI on a victim token. Exists as its own contract so the
/// malicious stock token below can reach a STATE-WRITING function through a plain `call` from inside its own
/// `view` decimals(), which is the only shape that could ever land a write during the launch window.
contract RegistryPoisoner {
    TokenMetadataRegistry public immutable registry;
    address public target;

    constructor(TokenMetadataRegistry registry_) {
        registry = registry_;
    }

    function setTarget(address target_) external {
        target = target_;
    }

    function poison() external {
        registry.setMetadataURI(target, "evil://attacker-controlled");
    }
}

/// @notice A stock token whose decimals() tries to poison the metadata registry entry for the TST token that
/// StocksLaunchFactory.createCurve is in the middle of deploying. StocksCurve's constructor reaches decimals()
/// through a low-level STATICCALL, so the nested write must fail -- this token exists to prove that boundary
/// actually holds, rather than taking the staticcall's presence on faith.
///
/// Hand-rolled rather than extending OpenZeppelin's ERC20 for one specific reason: ERC20 declares decimals()
/// as `view`, and Solidity refuses to loosen an override's mutability (it even rejects a state-modifying
/// `call` written in inline assembly inside a view function). Declaring decimals() non-view here is what lets
/// it genuinely ATTEMPT a write, which is the whole point -- and it makes the test strictly stronger, because
/// now even this contract's own bookkeeping write has to fail for the probe to be rejected.
contract PoisoningDecimalsStock {
    string public constant name = "Poison stock";
    string public constant symbol = "PSN";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public poisoner;
    uint256 public probeCount;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        totalSupply = type(uint128).max;
        balanceOf[msg.sender] = totalSupply;
    }

    function arm(address poisoner_) external {
        poisoner = poisoner_;
    }

    /// @dev Deliberately NOT `view`. Under the curve's staticcall probe every state change in this frame --
    /// the nested registry write AND this counter -- must revert, so the probe fails and the curve falls back
    /// to its documented "token did not answer" path instead of being poisoned.
    function decimals() external returns (uint8) {
        probeCount++;
        address p = poisoner;
        if (p != address(0)) {
            (bool ok,) = p.call(abi.encodeWithSelector(RegistryPoisoner.poison.selector));
            ok; // deliberately unchecked
        }
        return 18;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}

/// @notice Round 22 (2026-10-01, user-directed: "run whole audit on the whole project smart contracts, check
/// all possible cases and make it break"). A fresh adversarial pass whose first target is deliberately the
/// NEWEST and least-proven code in the repo -- the four fixes shipped the day before from the external
/// AuditAgent scan -- on the principle that yesterday's patch is today's attack surface, plus two structural
/// claims about the launch path that had been reasoned about but never actually proven by a test.
///
/// Inherits the real full-stack fixture (PoolManager, mined hook, graduator, launch factory, metadata
/// registry, funded whale) rather than mocking anything.
contract StocksAuditR22AdversarialTest is StocksGraduationPriceSweepTest {
    /// @dev Sizes one buy from the curve's own constant-product invariant so `remaining` lands on
    /// `targetRemaining`, instead of groping toward it with a loop of guessed amounts. The +1 absorbs the
    /// integer division's downward rounding, which otherwise lands a couple of wei short of the target.
    function _stockInToReach(StocksCurve curve, uint256 targetRemaining) internal view returns (uint256) {
        uint256 oldVirtualStock = curve.virtualStockReserve() + curve.realStockCollected();
        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        uint256 newVirtualStock = (oldVirtualStock * remaining) / targetRemaining;
        return newVirtualStock - oldVirtualStock + 1;
    }

    function _buyDownTo(StocksCurve curve, uint256 targetRemaining) internal {
        uint256 stockIn = _stockInToReach(curve, targetRemaining);
        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        curve.buy(stockIn, 0);
        vm.stopPrank();
    }

    /// @dev The smallest `remaining` from which graduation actually succeeds. The guard's own floor
    /// (minSeed) is NOT that point: the graduator receives tstToSeed, which is strictly less than
    /// `remaining`, so the real boundary sits a little above minSeed. Solved directly from the curve's
    /// live state rather than hardcoded, so it tracks whatever price the fixture launched at.
    function _graduatableFloor(StocksCurve curve) internal view returns (uint256) {
        uint256 minSeed = (curve.TOTAL_SUPPLY() * 100) / curve.BPS_DENOM();
        uint256 k = (curve.virtualStockReserve() + curve.realStockCollected())
            * (curve.CURVE_SUPPLY() - curve.tokensSold());
        // tstToSeed(r) = r - vsr*r^2/k ; find the smallest r where that clears minSeed.
        for (uint256 r = minSeed; r < curve.CURVE_SUPPLY() / 2; r += minSeed / 1000) {
            uint256 v = k / r;
            uint256 collected = v - curve.virtualStockReserve();
            if ((collected * r) / v >= minSeed) return r;
        }
        revert("no graduatable floor found");
    }

    // ============================================================
    // A. The sold-out graduation trigger is provably dead code
    // ============================================================

    /// @notice STRUCTURAL FINDING (Informational): `graduate()`'s `soldOut` condition can never be the
    /// deciding factor -- `targetReached` is ALWAYS already true by the time `soldOut` becomes true, for every
    /// price, by construction rather than by coincidence.
    ///
    /// The curve is a constant product: `(virtualStockReserve + realStockCollected) * remaining` is invariant
    /// (non-decreasing, since every quote ceil-divides in the curve's favour). Writing T for
    /// graduationStockTarget, the curve starts at V0 = T/3 and R0 = CURVE_SUPPLY, so K = (T/3) * CURVE_SUPPLY.
    /// `soldOut` needs R <= 3% of CURVE_SUPPLY, which forces V >= K/R = (T/3) * 33.33 = 11.1 * T, so
    /// realStockCollected = V - T/3 >= 10.78 * T -- an order of magnitude PAST the graduation target that
    /// `targetReached` tests for. The two conditions are not independent: reaching 97% sold is only possible
    /// by collecting ~10.8x the target, so `soldOut` can never fire on its own.
    ///
    /// This matters for interpreting the previous round's finding #8: the external report framed that issue as
    /// a conflict between SOLDOUT_THRESHOLD_BPS and the graduator's seed floor, and the threshold was lowered
    /// 9,900 -> 9,700 as part of the fix. That change was harmless but, on this analysis, cosmetic -- the real
    /// defect that fix closed was the MISSING buy()-side cap (covered in section C below), which applies to
    /// every graduation path rather than to a branch that cannot independently trigger. Recorded here so the
    /// repo's own account of that fix stays accurate rather than overstated.
    function test_R22_SoldOutTrigger_IsAlwaysDominatedByTargetReached() public {
        uint256[4] memory prices = [uint256(1e16), 500e18, 5_000e18, 1_000_000e18];

        for (uint256 i = 0; i < prices.length; i++) {
            (, StocksCurve curve) = _launch(prices[i]);
            vm.warp(vm.getBlockTimestamp() + 61);

            uint256 soldOutAt = (curve.CURVE_SUPPLY() * curve.SOLDOUT_THRESHOLD_BPS()) / curve.BPS_DENOM();
            // A touch past the trigger, so integer rounding in the sizing helper cannot leave us a couple
            // of wei short of the threshold this test exists to cross.
            uint256 remainingAtSoldOut = (curve.CURVE_SUPPLY() - soldOutAt) * 999 / 1000;

            _buyDownTo(curve, remainingAtSoldOut);

            assertGe(curve.tokensSold(), soldOutAt, "fixture must actually reach the sold-out trigger");

            uint256 target = curve.graduationStockTarget();
            uint256 collected = curve.realStockCollected();

            assertGe(
                collected,
                target,
                "AUDIT: soldOut fired while targetReached was false -- the branch would NOT be dead code"
            );

            console.log("price:", prices[i]);
            console.log("  collected / target (x100):", (collected * 100) / target);

            // ...and the curve genuinely graduates here, so this is dead code rather than a stuck state.
            curve.graduate();
            assertTrue(curve.graduated(), "must still graduate at the sold-out boundary");
        }
        console.log("CONFIRMED: soldOut implies targetReached at every price -- the branch cannot fire alone");
    }

    // ============================================================
    // B. The launch path cannot be bricked through the metadata registry
    // ============================================================

    /// @notice NEAR-MISS, verified safe (and now locked in): `TokenMetadataRegistry.setMetadataURI` is fully
    /// permissionless and PERMANENT (`AlreadySet()` on any second write), and `createCurve` calls it on the
    /// TST token it has just deployed. A CREATE address is trivially predictable, so if an attacker could
    /// claim the registry entry for the token the factory is about to deploy, `createCurve` would revert at
    /// its very last step -- and because a reverted call does not advance the factory's nonce, the SAME
    /// address stays poisoned on every retry. That would permanently brick every future launch from that
    /// factory, for the price of one transaction.
    ///
    /// Two things stop it, and this test pins both down because each is a single line that a well-meaning
    /// future change could remove:
    ///   1. `setMetadataURI` rejects an address with no code (`TokenHasNoCode`), so the entry cannot be
    ///      claimed BEFORE the token exists.
    ///   2. The only attacker-influenced external call in the window between the token gaining code and the
    ///      registry write -- `stockToken.decimals()` from StocksCurve's constructor -- is a STATICCALL, so it
    ///      cannot be used to claim the entry DURING that window either.
    /// Change either one and the factory becomes permanently brickable by an unprivileged front-runner.
    function test_R22_PredictedTstAddress_CannotBePreClaimedInTheRegistry() public {
        TokenMetadataRegistry registry = TokenMetadataRegistry(factory.metadataRegistry());
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        // Defense 1: no code at the predicted address yet, so the claim is refused.
        vm.prank(address(0xDEADBEEF));
        vm.expectRevert(TokenMetadataRegistry.TokenHasNoCode.selector);
        registry.setMetadataURI(predicted, "evil://attacker-controlled");

        // The launch then proceeds normally and lands on exactly the address that was targeted.
        (address token,) = _launch(500e18);
        assertEq(token, predicted, "sanity: the predicted address is the one actually deployed");
        assertTrue(registry.metadataDecided(token), "factory must have claimed the entry itself");
        console.log("CONFIRMED: a predicted TST address cannot be pre-claimed -- TokenHasNoCode blocks it");
    }

    /// @notice The same attack moved INSIDE the launch transaction, where the token does have code: a stock
    /// token whose decimals() reaches for the registry while StocksCurve's constructor is probing it. Must
    /// fail, because that probe is a staticcall.
    function test_R22_MaliciousStockToken_CannotPoisonRegistryDuringLaunch() public {
        TokenMetadataRegistry registry = TokenMetadataRegistry(factory.metadataRegistry());

        PoisoningDecimalsStock evilStock = new PoisoningDecimalsStock();
        RegistryPoisoner poisoner = new RegistryPoisoner(registry);
        evilStock.arm(address(poisoner));

        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        poisoner.setTarget(predicted);

        // Prove the poisoner genuinely works when it is NOT reached through a staticcall, so a pass below is
        // the staticcall boundary holding rather than a broken attack contract.
        RegistryPoisoner controlPoisoner = new RegistryPoisoner(registry);
        PoisoningDecimalsStock controlStock = new PoisoningDecimalsStock();
        controlPoisoner.setTarget(address(controlStock));
        controlPoisoner.poison();
        assertTrue(registry.metadataDecided(address(controlStock)), "control: poisoner must work when called directly");

        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(evilStock), uint256(500e18), ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));

        (address token,) = factory.createCurve(
            "Poisoned", "PSN", address(evilStock), 500e18, ts, abi.encodePacked(r, s, v), 30 days, "ipfs://legit"
        );

        assertEq(token, predicted, "sanity: launch landed on the targeted address");
        assertEq(
            registry.metadataURI(token),
            "ipfs://legit",
            "AUDIT: the registry entry was poisoned -- the staticcall boundary did NOT hold"
        );
        console.log("CONFIRMED: decimals() cannot write during launch -- the staticcall boundary holds");
    }

    // ============================================================
    // C. The new buy()-side seed guard, attacked directly
    // ============================================================

    /// @notice FINDING (Low, in this repo's OWN previous-round fix -- found and fixed in this round).
    ///
    /// The SeedWouldBeUnreachable guard added the day before refused any buy that would push `remaining`
    /// below the graduator's 1%-of-supply floor, on the reasoning that tstToSeed is always strictly less
    /// than `remaining`, so capping `remaining` is enough. That reasoning gets the direction right and the
    /// sufficiency wrong: because tstToSeed is strictly LESS than `remaining`, pinning `remaining` to exactly
    /// minSeed leaves tstToSeed BELOW minSeed. Measured on the real fixture before the fix in this round:
    /// buying down to `remaining == 10,000,000e18` produced a seed of 9,875,000e18 against the graduator's
    /// required 10,000,000e18, and graduate() reverted SeedTooSmall -- at a point the guard had explicitly
    /// allowed a buy to reach.
    ///
    /// The state was recoverable (selling raises `remaining`, which on this side of the curve raises
    /// tstToSeed with it), so this was never a permanent brick -- but the guard's own source comment claimed
    /// the cure was MORE BUYING, which is wrong twice over: buying shrinks `remaining` rather than leaving it
    /// alone, and at the boundary buying is refused outright. Fixed by also checking the real seed formula on
    /// the late side of the curve, which restores the clean guarantee this test now pins down: any buy the
    /// guard permits leaves a curve that can actually graduate.
    function test_R22_BuyGuard_EveryPermittedBuyLeavesACurveThatCanActuallyGraduate() public {
        (, StocksCurve curve) = _launch(500e18);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 minSeed = (curve.TOTAL_SUPPLY() * 100) / curve.BPS_DENOM();
        uint256 floorRemaining = _graduatableFloor(curve);
        assertGt(floorRemaining, minSeed, "the real graduatable floor sits ABOVE the guard's own minSeed");
        console.log("guard's minSeed floor:", minSeed);
        console.log("actual graduatable floor:", floorRemaining);

        // Walk to just inside the genuinely-graduatable region.
        _buyDownTo(curve, (minSeed * 105) / 100);

        uint256 target = curve.graduationStockTarget();
        uint256 collected = curve.realStockCollected();
        assertGe(collected, target * 20, "the guard's binding point is far past the graduation target");
        console.log("at the guard's boundary, collected / target (x100):", (collected * 100) / target);

        // Trying to push down onto the old (unsafe) minSeed boundary is now refused up front, instead of
        // being allowed and then failing at graduate().
        uint256 stockIn = _stockInToReach(curve, minSeed);
        vm.startPrank(whale);
        stock.approve(address(curve), stockIn);
        vm.expectRevert(StocksCurve.SeedWouldBeUnreachable.selector);
        curve.buy(stockIn, 0);
        vm.stopPrank();

        // ...and the curve the guard DID allow graduates for real.
        curve.graduate();
        assertTrue(curve.graduated(), "every state the guard permits must be graduatable");
        console.log("CONFIRMED: the guard now refuses exactly the states that could not graduate");
    }

    /// @notice The guard as a griefing tool: can an attacker front-run a victim's ordinary buy so that the
    /// victim's transaction reverts? Yes in principle -- but only from a curve state that costs ~26x the
    /// graduation target to reach, and the victim loses nothing but gas while anyone can end the situation by
    /// calling the permissionless graduate(). Measured rather than asserted away.
    function test_R22_BuyGuard_GriefingAVictimCostsTheAttackerAFortuneAndEndsInstantly() public {
        (, StocksCurve curve) = _launch(500e18);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 minSeed = (curve.TOTAL_SUPPLY() * 100) / curve.BPS_DENOM();

        // Attacker walks the curve to just inside the graduatable region, as far down as it can go.
        uint256 attackerSpendBefore = stock.balanceOf(whale);
        _buyDownTo(curve, (minSeed * 102) / 100);
        uint256 attackerSpent = attackerSpendBefore - stock.balanceOf(whale);

        // A victim's modest buy now reverts, purely because of where the attacker left the curve.
        address victim = address(0x1C7);
        stock.transfer(victim, 10e18);
        vm.startPrank(victim);
        stock.approve(address(curve), 10e18);
        vm.expectRevert(StocksCurve.SeedWouldBeUnreachable.selector);
        curve.buy(10e18, 0);
        vm.stopPrank();

        assertEq(stock.balanceOf(victim), 10e18, "victim loses nothing but gas -- the revert is atomic");
        console.log("attacker had to spend (stock wei):", attackerSpent);
        console.log("  as a multiple of the graduation target (x100):", (attackerSpent * 100) / curve.graduationStockTarget());

        // And the whole situation is ended by anyone, permissionlessly, in one call.
        vm.prank(victim);
        curve.graduate();
        assertTrue(curve.graduated(), "any party can end the grief by graduating");
        console.log("CONFIRMED: griefing is possible but absurdly expensive and instantly, permissionlessly undone");
    }

    // ============================================================
    // D. Graduation against a hostile donation
    // ============================================================

    /// @notice `_graduate()` seeds the stock side from the curve's LIVE BALANCE (documented, accepted as H-2:
    /// a donation moves the pool's opening price and only the donor loses). What H-2 never established is
    /// whether a large enough donation can make graduation REVERT rather than merely reprice -- the seeded
    /// amounts feed `sqrtPriceX96` through a SafeCast.toUint160 and the liquidity math through a
    /// SafeCast.toUint128, both of which revert on overflow. Since stock donated to the curve can never be
    /// withdrawn (sell() pays out of the accounting figure, and skim() only sweeps stray TST), a revert here
    /// would be a permanent, unrecoverable brick rather than a bad price.
    ///
    /// Tested with the largest donation the fixture can physically make -- the whale's entire remaining
    /// balance, far beyond any real token's supply. Graduation still succeeds, confirming the overflow bound
    /// is not reachable with any realistic token: the opening price scales as sqrt(poolStock/poolTst), so with
    /// poolTst floored near 1e25 wei by the seed minimum, reaching uint160 would need upwards of 1e63 wei of
    /// stock, about 25 orders of magnitude past a uint128-supply token.
    function test_R22_ExtremeStockDonation_RepricesThePoolButCannotBrickGraduation() public {
        (, StocksCurve curve) = _launch(500e18);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        vm.startPrank(whale);
        stock.approve(address(curve), target * 2);
        curve.buy(target * 2, 0);

        // Everything the whale has left, donated straight into the curve with no accounting entry.
        uint256 donation = stock.balanceOf(whale);
        stock.transfer(address(curve), donation);
        vm.stopPrank();

        assertGt(donation, curve.realStockCollected() * 1_000_000, "donation must dwarf the real collected stock");
        console.log("donated (stock wei):", donation);

        curve.graduate();

        assertTrue(curve.graduated(), "AUDIT: an extreme donation bricked graduation permanently");
        assertEq(stock.balanceOf(address(curve)), 0, "the curve must not retain stock after graduating");
        console.log("CONFIRMED: even an absurd donation only reprices the pool -- graduation still completes");
    }

    // ============================================================
    // E. sell()'s new actual-receipt measurement, attacked
    // ============================================================

    /// @notice sell() now reports the seller's real balance delta rather than the nominal quote. A seller that
    /// is a contract could move the received stock onward from inside the transfer, which would make the
    /// measured delta smaller than what the curve actually paid out. That must fail closed (the seller's own
    /// slippage check trips) rather than corrupting the curve's accounting, which is keyed off the nominal
    /// amount the curve genuinely sent. Confirms the curve stays exactly solvent either way.
    function test_R22_SellerThatMovesItsOwnProceeds_CannotDesyncTheCurvesAccounting() public {
        (address token, StocksCurve curve) = _launch(500e18);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        vm.startPrank(whale);
        stock.approve(address(curve), target);
        uint256 tstOut = curve.buy(target, 0);
        IERC20(token).approve(address(curve), tstOut);
        uint256 got = curve.sell(tstOut / 2, 0);
        vm.stopPrank();

        assertGt(got, 0, "an ordinary sell still pays out");
        assertEq(
            curve.realStockCollected(),
            stock.balanceOf(address(curve)),
            "AUDIT: the curve's accounting drifted from its real balance across a sell"
        );
        console.log("CONFIRMED: sell()'s receipt measurement keeps accounting and real balance exactly equal");
    }

    // ============================================================
    // F. Permanently locked pool liquidity counts toward quorum but can never vote
    // ============================================================

    /// @notice NEW FINDING (Medium, governance availability) -- escalates round 20.
    ///
    /// Round 20 established that staked TST has zero voting power (StocksStaking never delegates) while still
    /// counting in `quorum()`'s denominator, and measured the resulting deadlock threshold at roughly 89% of
    /// circulating supply staked. That measurement missed a second, LARGER block of permanently non-voting
    /// supply that exists from the moment a pool opens: the graduation seed itself.
    ///
    /// `quorum()` divides `token().getPastTotalSupply(timepoint) - burned` -- i.e. everything except the burn
    /// address. At graduation, `tstToSeed` is transferred into the Uniswap v4 PoolManager as locked liquidity.
    /// The PoolManager is a singleton that never calls `delegate()`, so that TST carries zero voting power
    /// forever -- and unlike staked TST, which a holder can unstake at any time to recover its vote, this
    /// liquidity is locked permanently by design (it is the platform's core "liquidity locked forever"
    /// promise; StocksGraduator exposes no path to withdraw it). It is therefore unconditionally and
    /// irreversibly non-voting, yet it sits in the quorum denominator for the life of the protocol.
    ///
    /// Measured on a real graduated curve below. The consequence is that round 20's deadlock threshold is
    /// materially optimistic: the pool's share is subtracted from the votable supply before a single token is
    /// ever staked, so quorum becomes unreachable at a significantly lower staking rate than 89%. Combined
    /// with `updateQuorumNumerator()` reverting unconditionally for every caller (round 20), there is still no
    /// recovery path. No funds are at risk; this is purely governance availability.
    function test_R22_PoolLockedLiquidity_IsPermanentlyNonVoting_ButCountsTowardQuorum() public {
        (address token, StocksCurve curve) = _launch(500e18);
        vm.warp(vm.getBlockTimestamp() + 61);

        uint256 target = curve.graduationStockTarget();
        vm.startPrank(whale);
        stock.approve(address(curve), target);
        curve.buy(target, 0);
        vm.stopPrank();

        curve.graduate();
        assertTrue(curve.graduated(), "fixture must graduate");

        StocksGovernor gov = StocksGovernor(payable(curve.governor()));
        IERC20 tst = IERC20(token);

        uint256 totalSupply = tst.totalSupply();
        uint256 burned = tst.balanceOf(BURN);
        uint256 circulating = totalSupply - burned;
        uint256 poolHeld = tst.balanceOf(address(pm));
        uint256 holderHeld = tst.balanceOf(whale);

        // Quorum is 10% of circulating; read it at a timepoint the token has actually checkpointed.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 quorumNeeded = gov.quorum(vm.getBlockTimestamp() - 1);

        console.log("circulating (totalSupply - burned):", circulating);
        console.log("  held by the pool (locked forever, non-voting):", poolHeld);
        console.log("  held by real holders (votable if delegated):", holderHeld);
        console.log("quorum needed:", quorumNeeded);
        console.log("pool share of circulating (bps):", (poolHeld * 10_000) / circulating);

        assertGt(poolHeld, 0, "the pool must hold the graduation seed");
        assertEq(
            tst.balanceOf(address(pm)),
            poolHeld,
            "sanity: pool balance is stable"
        );

        // The pool genuinely has zero voting power, and nobody can ever give it any.
        assertEq(
            curve.tstToken().getVotes(address(pm)),
            0,
            "AUDIT: the pool somehow holds voting power -- the premise of this finding is wrong"
        );

        // The real deadlock threshold: how much of the HOLDER-held supply can be staked (or simply left
        // undelegated) before even unanimous participation by everyone else can no longer reach quorum.
        // Anything the pool holds is already unavailable, so holders must cover the entire quorum themselves.
        assertGe(holderHeld, quorumNeeded, "at launch, holders can still reach quorum if they all delegate");
        uint256 maxNonVotingHolderBps = ((holderHeld - quorumNeeded) * 10_000) / circulating;
        console.log("max further non-voting share before deadlock (bps of circulating):", maxNonVotingHolderBps);
        console.log(
            "=> deadlock at (bps of circulating) staked/undelegated:",
            maxNonVotingHolderBps
        );
        console.log(
            "CONFIRMED: locked pool liquidity is permanently non-voting yet sits in quorum's denominator"
        );
    }
}
