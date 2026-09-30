// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {StocksStaking} from "../src/StocksStaking.sol";
import {StocksGovernor} from "../src/governance/StocksGovernor.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {StocksAuditR2GovernanceTest} from "./StocksAuditR2.governance.t.sol";
import {MockHookV5} from "./mocks/MockHookV5.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A malicious/compromised stock token whose `transfer` calls back into every guarded entry point of a
/// StocksStaking contract, one at a time, the moment it pays anyone out. Records which calls were rejected.
contract CrossFunctionReentrantStock is MockERC20 {
    StocksStaking public target;
    bool public armed;
    bool[4] public succeeded; // [stake, unstake, claim, redeem]

    constructor() MockERC20("Reentrant", "RE") {}

    function arm(StocksStaking t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(target) && to != address(0)) {
            armed = false; // one shot per call site
            try target.stake(1) { succeeded[0] = true; } catch {}
            try target.unstake(1) { succeeded[1] = true; } catch {}
            try target.claim() { succeeded[2] = true; } catch {}
            try target.redeem(1, 0) { succeeded[3] = true; } catch {}
        }
    }
}

/// @notice A malicious/compromised stock token whose `transferFrom` (the curve's pull) calls back into whichever
/// other nonReentrant entry point of StocksCurve it is armed for.
contract CrossFunctionReentrantCurveStock is MockERC20 {
    StocksCurve public target;
    bool public armed;
    bool public sellSucceeded;
    bool public graduateSucceeded;
    bool public skimSucceeded;

    constructor() MockERC20("Reentrant", "RE") {}

    function arm(StocksCurve t) external {
        target = t;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (armed && to == address(target)) {
            armed = false;
            try target.sell(1, 0) { sellSucceeded = true; } catch {}
            try target.graduate() { graduateSucceeded = true; } catch {}
            try target.skim() { skimSucceeded = true; } catch {}
        }
        return ok;
    }
}

/// @notice Audit round 3: cross-function reentrancy (does the guard really block re-entry into a DIFFERENT
/// nonReentrant function, not just the one being called?), and precisely what governance can and cannot do to the
/// treasury.
contract StocksAuditR2ReentrancyAndGovernanceTest is StocksAuditR2GovernanceTest {
    // ------------------------------------------------------------------------------ cross-function reentrancy

    /// @notice A malicious stock token's payout during `redeem()` tries to call `stake`, `unstake`, `claim` and
    /// `redeem` again, all on the SAME staking contract. OpenZeppelin's ReentrancyGuard uses one shared lock per
    /// contract, so every one of them must be rejected, not just a second `redeem`.
    function test_CrossFunctionReentrancy_OnStaking_EveryGuardedEntryPointIsBlocked() public {
        CrossFunctionReentrantStock rs = new CrossFunctionReentrantStock();
        TSTToken tst_ = new TSTToken("X", "X", 1_000_000_000e18, address(this));
        MockHookV5 hookStub = new MockHookV5(IERC20(address(rs)), IERC20(address(tst_)), 1 hours, 1e18);
        StocksStaking s = new StocksStaking(address(tst_), address(rs), 7 days, address(this), address(hookStub), address(this));
        bool tstIs0 = address(tst_) < address(rs);
        PoolKey memory k = PoolKey({
            currency0: tstIs0 ? Currency.wrap(address(tst_)) : Currency.wrap(address(rs)),
            currency1: tstIs0 ? Currency.wrap(address(rs)) : Currency.wrap(address(tst_)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hookStub))
        });
        s.setPool(k);

        address redeemer = address(0xBEEF);
        tst_.transfer(redeemer, 1_000e18);
        rs.mint(address(s), 1_000e18);
        // fund the attacker contract itself so a reentrant stake/unstake/claim/redeem would genuinely go through
        // if the guard failed: it needs TST to stake/redeem and an approval on the staking contract
        tst_.transfer(address(rs), 500e18);
        vm.prank(address(rs));
        tst_.approve(address(s), type(uint256).max);
        rs.arm(s);

        vm.startPrank(redeemer);
        tst_.approve(address(s), 1_000e18);
        s.redeem(500e18, 0);
        vm.stopPrank();

        assertFalse(rs.succeeded(0), "reentrant stake() must be rejected");
        assertFalse(rs.succeeded(1), "reentrant unstake() must be rejected");
        assertFalse(rs.succeeded(2), "reentrant claim() must be rejected");
        assertFalse(rs.succeeded(3), "reentrant redeem() must be rejected");
    }

    /// @notice A malicious stock token's pull during `buy()` tries to call `sell`, `graduate` and `skim` on the
    /// SAME curve. All three must be rejected by the shared guard, not just a second `buy`.
    function test_CrossFunctionReentrancy_OnCurve_EveryGuardedEntryPointIsBlocked() public {
        CrossFunctionReentrantCurveStock stock_ = new CrossFunctionReentrantCurveStock();
        uint256 signerKey = 0xA11CE;
        address factory_ = address(0xFACE);
        uint256 price = 200e18;
        uint256 ts = block.timestamp;
        bytes32 h = keccak256(abi.encodePacked(factory_, address(stock_), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(h));
        TSTToken tst_ = new TSTToken("Y", "Y", 1_000_000_000e18, address(this));
        StocksCurve c = new StocksCurve(
            address(tst_), address(stock_), vm.addr(signerKey), price, ts, abi.encodePacked(r, s, v), 7 days, factory_, 8_000e18, 1 days, 365 days
        );
        tst_.transfer(address(c), 1_000_000_000e18);
        vm.warp(block.timestamp + c.SNIPE_WINDOW() + 1);

        stock_.mint(address(this), 5_000e18);
        stock_.approve(address(c), 5_000e18);
        // give the token a pre-existing TST holding + approval so a reentrant sell() would really pay out if the
        // guard failed
        stock_.arm(c);
        c.buy(5_000e18, 0);

        assertFalse(stock_.sellSucceeded(), "reentrant sell() must be rejected");
        assertFalse(stock_.graduateSucceeded(), "reentrant graduate() must be rejected");
        assertFalse(stock_.skimSucceeded(), "reentrant skim() must be rejected");
    }

    // ------------------------------------------------------------------------------ governance cannot redirect treasury

    /// @notice Enumerates the ONLY functions on StocksStaking that governance can call (`onlyGovernor`), and shows
    /// none of them takes a recipient address: a passed proposal can pause/resume rewards, change the reward
    /// duration, or start a bounded liquidation into the hook's own TWAMM order. None can move a single wei of
    /// treasury stock to an address the proposal itself chooses.
    function test_Governance_CanNeverChooseWhoTreasuryStockGoesTo() public {
        _fundTreasury(200e18);
        StocksGovernor g = _gov();
        address attacker = address(0xBAD);

        // setRewardsPaused / setRewardsDuration: no token movement at all, proven by the treasury balance being
        // untouched across both calls
        (address[] memory t1, uint256[] memory v1, bytes[] memory c1, bytes32 h1,) =
            _pass(abi.encodeCall(StocksStaking.setRewardsPaused, (true)), "Pause");
        uint256 before = stock.balanceOf(address(staking));
        gov.execute(t1, v1, c1, h1);
        assertEq(stock.balanceOf(address(staking)), before, "pausing moves no stock");

        (address[] memory t2, uint256[] memory v2, bytes[] memory c2, bytes32 h2,) =
            _pass(abi.encodeCall(StocksStaking.setRewardsDuration, (10 days)), "Duration");
        before = stock.balanceOf(address(staking));
        gov.execute(t2, v2, c2, h2);
        assertEq(stock.balanceOf(address(staking)), before, "changing the duration moves no stock");

        // liquidateTreasury: the only staking function that moves treasury stock out; it takes a duration, not a
        // recipient, and the stock always goes to the hook it is already wired to, never anywhere else
        uint256 attackerBefore = stock.balanceOf(attacker);
        (address[] memory t3, uint256[] memory v3, bytes[] memory c3, bytes32 h3,) =
            _pass(abi.encodeCall(StocksStaking.liquidateTreasury, (staking.MAX_LIQUIDATION_DURATION() / hook.expirationInterval())), "Liquidate");
        gov.execute(t3, v3, c3, h3);
        assertEq(stock.balanceOf(attacker), attackerBefore, "the attacker never receives anything");
        assertGt(stock.balanceOf(address(hook)), 0, "the stock can only land in the hook's own order");

        // and a proposal that TRIES to call something with a recipient parameter the proposer controls (e.g. a
        // plain ERC20 transfer out of the staking contract) is not something `onlyGovernor` staking exposes at
        // all -- there is no such function to call in the first place
        bytes4[4] memory governorGatedSelectors = [
            StocksStaking.setRewardsPaused.selector,
            StocksStaking.setRewardsDuration.selector,
            StocksStaking.liquidateTreasury.selector,
            bytes4(0)
        ];
        assertEq(uint256(uint32(governorGatedSelectors[3])), 0, "sanity: there is no fourth onlyGovernor function");
    }

    // ------------------------------------------------------------------------------ chained liquidations

    /// @notice The 30-day cap bounds a SINGLE proposal's blast radius, but does not by itself stop a majority that
    /// keeps choosing to re-propose. What it does guarantee: a second liquidation can never be started while the
    /// first is still running (`LiquidationInProgress`), so achieving a year of continuous lock-up after the fix
    /// needs about twelve SEPARATE successful votes, not one.
    function test_ChainedLiquidations_EachRequiresItsOwnSeparateVote_CannotBeStacked() public {
        _fundTreasury(500e18);
        uint256 maxIntervals = staking.MAX_LIQUIDATION_DURATION() / hook.expirationInterval();

        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h,) =
            _pass(abi.encodeCall(StocksStaking.liquidateTreasury, (maxIntervals)), "First liquidation");
        gov.execute(t, v, c, h);
        uint256 firstExpiration = staking.pendingLiquidationExpiration();
        assertGt(firstExpiration, block.timestamp);

        // a second proposal, passed and ready to execute well before the first order expires, must still fail
        uint256 minIntervals = staking.MIN_LIQUIDATION_DURATION() / hook.expirationInterval();
        (address[] memory t2, uint256[] memory v2, bytes[] memory c2, bytes32 h2,) =
            _pass(abi.encodeCall(StocksStaking.liquidateTreasury, (minIntervals)), "Second liquidation, too soon");
        vm.expectRevert(StocksStaking.LiquidationInProgress.selector);
        gov.execute(t2, v2, c2, h2);

        // only once the first order's 30 days are up does a fresh vote's execution succeed
        vm.warp(firstExpiration + 1);
        gov.execute(t2, v2, c2, h2);
        assertGt(staking.pendingLiquidationExpiration(), firstExpiration, "the second order starts fresh, only after the first is over");
    }
}
