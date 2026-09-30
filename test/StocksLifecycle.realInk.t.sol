// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {StocksPoolView} from "../src/dex/v4/StocksPoolView.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";
import {ITWAMM} from "../src/dex/v4/twamm/vendor/ITWAMM.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice One full life of a launch, end to end, against the REAL deployed Uniswap v4 PoolManager on Ink and
/// the REAL AAPLx ERC-4626 wrapper: launch through the factory, buy on the curve, graduate, trade both
/// directions, stake and claim, pass a real governance vote (propose, delay, vote, execute) that liquidates
/// the treasury through the real TWAMM hook, let it fill, claim and burn, run a second liquidation cycle, then
/// check that every token is accounted for and nothing is stranded anywhere. This is the final audit's
/// integration test: every component is the production contract, wired the way the deploy script wires it.
contract StocksLifecycleRealInkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    // AAPLx ERC-4626 wrapper (the stock token new curves pair against), see frontend/lib/stocks.ts
    address constant STOCK = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // MAINNET deploy profile (.env.example)
    uint256 constant GRADUATION_USD_THRESHOLD = 8_000e18;
    uint256 constant MIN_REWARDS_DURATION = 1 days;
    uint256 constant MAX_REWARDS_DURATION = 365 days;
    uint48 constant VOTING_DELAY = 1 days;
    uint32 constant VOTING_PERIOD = 3 days;
    uint256 constant PROPOSAL_THRESHOLD_BPS = 25;
    uint256 constant EXPIRATION_INTERVAL = 1 hours;

    IPoolManager poolManager;
    StocksHook hook;
    StocksGraduator graduator;
    StocksLaunchFactory factory;
    PoolSwapTest swapRouter;

    uint256 signerKey = 0xA11CE;
    address protocol = address(0xFEED);
    address alice = address(0xA11CE1); // big early buyer, later the proposer
    address bob = address(0xB0B1); // medium buyer, votes against
    address carol = address(0xCA201); // small buyer, staker
    address dave = address(0xDA7E); // trader

    uint256 gasSwapBuy;

    // launch under test
    address token;
    StocksCurve curve;
    StocksStaking staking;
    StocksGovernor governor;
    PoolKey key;
    bool tstIsCurrency0;

    function setUp() public {
        vm.createSelectFork("ink");
        poolManager = IPoolManager(POOL_MANAGER);
        require(address(poolManager).code.length > 0, "PoolManager not deployed on this fork");

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
        bytes memory constructorArgs = abi.encode(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(StocksHook).creationCode, constructorArgs);
        hook = new StocksHook{salt: salt}(poolManager, predictedGraduator, EXPIRATION_INTERVAL);
        require(address(hook) == hookAddress, "hook address mismatch");

        graduator = new StocksGraduator(poolManager, hook, predictedFactory);
        require(address(graduator) == predictedGraduator, "graduator address mismatch");

        factory = new StocksLaunchFactory(
            vm.addr(signerKey),
            protocol,
            address(hook),
            governorFactory,
            stakingFactory,
            curveDeployer,
            address(graduator),
            address(registry),
            GRADUATION_USD_THRESHOLD,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD_BPS
        );
        require(address(factory) == predictedFactory, "factory address mismatch");

        swapRouter = new PoolSwapTest(poolManager);
    }

    // ----------------------------------------------------------------------------------------- helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _sign(uint256 price, uint256 ts) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked(address(factory), STOCK, price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(h));
        return abi.encodePacked(r, s, v);
    }

    function _buyOnCurve(address who, uint256 stockIn) internal returns (uint256 tstOut) {
        deal(STOCK, who, stockIn);
        vm.startPrank(who);
        IERC20(STOCK).approve(address(curve), stockIn);
        tstOut = curve.buy(stockIn, 0);
        vm.stopPrank();
    }

    function _swap(address who, bool buyTst, uint256 amountIn) internal {
        address tokenIn = buyTst ? STOCK : token;
        // stock is currency0 exactly when TST is currency1; a swap zeroForOne sells currency0
        bool zeroForOne = buyTst ? !tstIsCurrency0 : tstIsCurrency0;
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IERC20(t).balanceOf(who);
    }

    /// @dev Every TST in existence is in exactly one of these places.
    function _assertTstConserved(string memory when_) internal view {
        uint256 sum = _bal(token, alice) + _bal(token, bob) + _bal(token, carol) + _bal(token, dave)
            + _bal(token, address(curve)) + _bal(token, address(staking)) + _bal(token, address(hook))
            + _bal(token, POOL_MANAGER) + _bal(token, BURN) + _bal(token, address(graduator))
            + _bal(token, address(factory)) + _bal(token, protocol) + _bal(token, address(governor));
        assertEq(sum, 1_000_000_000e18, string.concat("TST conserved ", when_));
    }

    /// @dev What the hook owes (unclaimed TWAMM proceeds) is backed by what it holds.
    function _assertHookSolvent(string memory when_) internal view {
        uint256 tstOwed = hook.tokensOwed(Currency.wrap(token), address(staking));
        uint256 stockOwed = hook.tokensOwed(Currency.wrap(STOCK), address(staking));
        assertGe(_bal(token, address(hook)) + 4, tstOwed, string.concat("hook holds the TST it owes ", when_));
        assertGe(_bal(STOCK, address(hook)) + 4, stockOwed, string.concat("hook holds the stock it owes ", when_));
    }

    /// @dev Nothing is left behind in the plumbing contracts.
    function _assertNoStrandedFunds(string memory when_) internal view {
        assertEq(_bal(STOCK, address(graduator)), 0, string.concat("graduator holds no stock ", when_));
        assertEq(_bal(token, address(graduator)), 0, string.concat("graduator holds no TST ", when_));
        assertEq(_bal(STOCK, address(factory)), 0, string.concat("factory holds no stock ", when_));
        assertEq(_bal(token, address(factory)), 0, string.concat("factory holds no TST ", when_));
        assertEq(_bal(STOCK, address(curve)), 0, string.concat("curve holds no stock after graduation ", when_));
        assertEq(_bal(token, address(curve)), 0, string.concat("curve holds no TST after graduation ", when_));
        assertEq(_bal(STOCK, address(governor)), 0, string.concat("governor holds no stock ", when_));
    }

    /// @dev In-kind redemption against the real hook and the real AAPLx wrapper, with every property checked.
    function _redeemInKindAndVerify() internal {
        uint256 carolEarnedBefore = staking.pendingReward(carol);
        uint256 redeemAmt = _bal(token, dave) / 2;
        (uint256 qOut, uint256 qProtocol, uint256 qKept) = staking.quoteRedeem(redeemAmt);
        assertGt(qOut, 0, "the treasury has stock to redeem against");
        assertGt(qKept, 0, "part of the cost stays in the treasury");
        uint256 protocolBefore = _bal(STOCK, protocol);
        uint256 supplyBefore = staking.nonBurnedSupply();
        uint256 daveStockBefore = _bal(STOCK, dave);

        vm.startPrank(dave);
        IERC20(token).approve(address(staking), redeemAmt);
        uint256 out = staking.redeem(redeemAmt, qOut);
        vm.stopPrank();

        assertEq(out, qOut, "pays exactly the quote");
        assertEq(_bal(STOCK, dave) - daveStockBefore, out, "in kind: the trader holds more wrapper shares");
        assertEq(_bal(STOCK, protocol) - protocolBefore, qProtocol, "the protocol received its share of the cost");
        assertEq(staking.nonBurnedSupply(), supplyBefore - redeemAmt, "the redeemed TST is burned");
        assertEq(staking.pendingReward(carol), carolEarnedBefore, "the staker's earned rewards are untouched");
        _assertTstConserved("after a redemption");
        _assertHookSolvent("after a redemption");
    
    }

    // ------------------------------------------------------------------------------------------ the test

    function test_FullLifecycle() public {
        // ---------------------------------------------------------------- 1. launch through the factory
        uint256 price = 200e18;
        uint256 ts = _now();
        address curveAddr;
        bytes memory sig = _sign(price, ts);
        vm.prank(alice);
        uint256 gasStart = gasleft();
        (token, curveAddr) = factory.createCurve("Lifecycle", "LIFE", STOCK, price, ts, sig, 30 days, "ipfs://lifecycle");
        uint256 gasCreate = gasStart - gasleft();
        curve = StocksCurve(curveAddr);
        assertEq(_bal(token, curveAddr), 1_000_000_000e18, "the curve holds the whole supply at launch");
        assertEq(factory.curveOf(token), curveAddr);
        assertEq(curve.graduationStockTarget(), 40e18, "$8,000 at $200 a share is 40 shares");

        // ---------------------------------------------------------------- 2. buy on the curve
        vm.warp(_now() + 61); // past the snipe window
        _buyOnCurve(alice, 26e18);
        _buyOnCurve(bob, 9e18);
        _buyOnCurve(carol, 4e18);
        assertFalse(curve.graduated());
        vm.expectRevert(StocksCurve.NotReady.selector);
        curve.graduate();
        _buyOnCurve(carol, 2e18); // crosses the 40 share target

        uint256 aliceTst = _bal(token, alice);
        uint256 bobTst = _bal(token, bob);
        uint256 carolTst = _bal(token, carol);
        console.log("alice / bob / carol TST:", aliceTst / 1e18, bobTst / 1e18, carolTst / 1e18);
        assertEq(_bal(STOCK, curveAddr), curve.realStockCollected(), "the curve holds exactly what was paid in");

        // ---------------------------------------------------------------- 3. graduate
        gasStart = gasleft();
        curve.graduate();
        uint256 gasGraduate = gasStart - gasleft();
        assertTrue(curve.graduated());
        staking = StocksStaking(curve.staking());
        governor = StocksGovernor(payable(curve.governor()));
        key = StocksPoolView(curve.pair()).poolKey();
        tstIsCurrency0 = Currency.unwrap(key.currency0) == token;
        PoolId poolId = key.toId();

        assertEq(staking.governor(), address(governor));
        assertEq(staking.curve(), curveAddr);
        assertEq(staking.rewardsDuration(), 30 days);
        assertEq(governor.quorumNumerator(), 10);
        assertEq(governor.proposalThresholdBps(), 25);
        assertEq(_bal(token, address(hook)), 100e18, "the hook got its 100 TST rounding reserve");
        assertEq(_bal(STOCK, address(hook)), 1e12, "and its millionth-of-a-share stock reserve");
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        assertGt(liquidity, 0, "the pool has liquidity");
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolId);
        assertGt(sqrtP, 0, "the pool is initialized");
        _assertTstConserved("after graduation");
        _assertNoStrandedFunds("after graduation");
        _assertHookSolvent("after graduation");

        // a second graduation is impossible
        vm.expectRevert(StocksCurve.AlreadyGraduated.selector);
        curve.graduate();

        // ---------------------------------------------------------------- 4. trade both directions
        deal(STOCK, dave, 200e18);
        uint256 burnBefore = _bal(token, BURN);
        uint256 protocolStockBefore = _bal(STOCK, protocol);
        uint256 treasuryAddedBefore = staking.totalRewardsAdded();
        for (uint256 i; i < 6; ++i) {
            vm.warp(_now() + 17 minutes);
            gasStart = gasleft();
            _swap(dave, true, 8e18); // buy TST with stock: the protocol takes its cut of the stock in, TST fee burned
            if (i == 0) gasSwapBuy = gasStart - gasleft();
            vm.warp(_now() + 9 minutes);
            uint256 sellAmt = _bal(token, dave) / 3;
            _swap(dave, false, sellAmt); // sell TST: stock fee split between protocol and the treasury
        }
        assertGt(_bal(token, BURN), burnBefore, "buying burned TST");
        assertGt(_bal(STOCK, protocol), protocolStockBefore, "the protocol earned stock");
        assertGt(staking.totalRewardsAdded(), treasuryAddedBefore, "the treasury received stock and streamed it as rewards");
        _assertTstConserved("after trading");
        _assertHookSolvent("after trading");

        // ---------------------------------------------------------------- 5. staking and claiming
        vm.startPrank(carol);
        IERC20(token).approve(address(staking), carolTst);
        staking.stake(carolTst);
        vm.stopPrank();
        uint256 sellAtStake = _bal(token, dave) / 2;
        vm.warp(_now() + 2 hours);
        _swap(dave, false, sellAtStake);
        vm.warp(_now() + 10 days);
        _swap(dave, true, 10e18);
        uint256 pending = staking.pendingReward(carol);
        assertGt(pending, 0, "the staker earned stock");
        uint256 carolStockBefore = _bal(STOCK, carol);
        vm.prank(carol);
        staking.claim();
        assertEq(_bal(STOCK, carol) - carolStockBefore, pending, "the claim pays exactly what was pending");
        assertGe(_bal(STOCK, address(staking)), staking.pendingReward(carol) + 1, "treasury still holds the unvested stock");
        _assertTstConserved("after staking");

        // ---------------------------------------------------------------- 5b. in-kind redemption (real hook, real AAPLx wrapper)
        _redeemInKindAndVerify();

        // ---------------------------------------------------------------- 6. governance: liquidate the treasury
        vm.prank(alice);
        TSTToken(token).delegate(alice);
        vm.prank(bob);
        TSTToken(token).delegate(bob);
        vm.warp(_now() + 1);

        uint256 circulating = IERC20(token).totalSupply() - _bal(token, BURN);
        assertGe(_bal(token, alice) * 10_000, circulating * 25, "alice clears the proposal threshold");

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(staking);
        calldatas[0] = abi.encodeCall(StocksStaking.liquidateTreasury, (24));
        string memory description = "Liquidate the treasury over 24 hours and burn the TST it buys";

        uint256 stockInTreasury = _bal(STOCK, address(staking));
        assertGt(stockInTreasury, 0);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.warp(_now() + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
        vm.prank(alice);
        governor.castVote(proposalId, 1); // for
        vm.prank(bob);
        governor.castVote(proposalId, 0); // against

        vm.warp(_now() + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "alice's votes carry it");

        gasStart = gasleft();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        uint256 gasLiquidate = gasStart - gasleft();
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        uint256 expiry = staking.pendingLiquidationExpiration();
        assertGt(expiry, _now(), "a real TWAMM order is live");
        assertLt(_bal(STOCK, address(staking)), stockInTreasury, "the treasury committed its stock to the order");
        _assertHookSolvent("with the order live");

        // a second liquidation cannot start while the first is running
        vm.prank(address(governor));
        vm.expectRevert(StocksStaking.LiquidationInProgress.selector);
        staking.liquidateTreasury(1);

        // redemption is NOT blocked by the live order: it only has the new inflow to draw on
        _swap(dave, false, _bal(token, dave) / 3);
        {
            uint256 amt = _bal(token, dave) / 2;
            vm.startPrank(dave);
            IERC20(token).approve(address(staking), amt);
            try staking.redeem(amt, 0) returns (uint256 got) {
                assertGt(got, 0);
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), StocksStaking.NothingToRedeem.selector, "only a zero payout may refuse");
            }
            vm.stopPrank();
        }

        // ---------------------------------------------------------------- 7. the order fills while people trade
        uint256 burnBeforeOrder = _bal(token, BURN);
        for (uint256 i; i < 5; ++i) {
            vm.warp(_now() + 5 hours);
            _swap(dave, i % 2 == 0, i % 2 == 0 ? 3e18 : _bal(token, dave) / 4);
            _assertHookSolvent("while the order fills");
        }
        vm.warp(expiry + 1 hours);
        _swap(dave, true, 1e18); // a swap after expiry finishes the execution
        (uint256 quoteBeforeClaim,,) = staking.quoteRedeem(1_000_000e18);
        uint256 burnedByStaking = staking.claimLiquidatedTst();
        (uint256 quoteAfterClaim,,) = staking.quoteRedeem(1_000_000e18);
        assertGe(quoteAfterClaim, quoteBeforeClaim, "burning the order's proceeds never lowers the redemption rate");
        assertGt(burnedByStaking, 0, "the order bought TST and the staking contract burned it");
        assertGt(_bal(token, BURN) - burnBeforeOrder, burnedByStaking, "and the hook's own cost on the proceeds burned more");
        _assertTstConserved("after the liquidation");
        _assertHookSolvent("after the liquidation");
        assertEq(hook.tokensOwed(Currency.wrap(token), address(staking)), 0, "everything owed to the treasury was claimed");

        // ---------------------------------------------------------------- 8. a second cycle: claim the old order, start a new one
        for (uint256 i; i < 4; ++i) {
            vm.warp(_now() + 3 hours);
            _swap(dave, false, _bal(token, dave) / 3);
            vm.warp(_now() + 1 hours);
            _swap(dave, true, 4e18);
        }
        if (_bal(STOCK, address(staking)) > 0) {
            uint256 minIntervalsSecondCycle = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
            vm.prank(address(governor));
            try staking.liquidateTreasury(minIntervalsSecondCycle) {
                assertGt(staking.pendingLiquidationExpiration(), _now(), "second order live");
                vm.warp(staking.pendingLiquidationExpiration() + 2 hours);
                _swap(dave, true, 1e18);
                staking.claimLiquidatedTst();
            } catch (bytes memory reason) {
                // the only acceptable refusal is "nothing safe to liquidate"
                assertEq(bytes4(reason), StocksStaking.NothingToLiquidate.selector);
            }
        }

        // ---------------------------------------------------------------- 9. everyone can leave
        vm.startPrank(carol);
        staking.claim();
        staking.unstake(staking.balanceOf(carol));
        vm.stopPrank();
        assertEq(staking.totalStaked(), 0);
        assertEq(_bal(token, carol), carolTst, "the staker gets every staked TST back");

        // ---------------------------------------------------------------- 10. closing books
        _assertTstConserved("at the end");
        _assertHookSolvent("at the end");
        _assertNoStrandedFunds("at the end");
        assertGe(_bal(STOCK, address(staking)) + 1, staking.pendingReward(carol), "the treasury can still pay what it owes");

        // the governor still cannot change its own rules
        vm.prank(address(governor));
        vm.expectRevert(StocksGovernor.VotingSettingsAreImmutable.selector);
        governor.updateQuorumNumerator(0);

        console.log("gas: createCurve / graduate / first buy swap / liquidation vote execution:", gasCreate, gasGraduate);
        console.log("     first swap / liquidate:", gasSwapBuy, gasLiquidate);
        // Every user-facing step must fit comfortably inside a block; these bounds catch a future change that
        // makes one of them balloon.
        assertLt(gasCreate, 6_000_000, "createCurve gas");
        assertLt(gasGraduate, 12_000_000, "graduate gas");
        assertLt(gasSwapBuy, 1_000_000, "swap gas");
        assertLt(gasLiquidate, 2_500_000, "liquidation execution gas");

        console.log("lifecycle complete. final burn (TST):", _bal(token, BURN) / 1e18);
        console.log("protocol earned (stock wei):", _bal(STOCK, protocol));
        console.log("total rewards streamed (stock wei):", staking.totalRewardsAdded());
    }
}
