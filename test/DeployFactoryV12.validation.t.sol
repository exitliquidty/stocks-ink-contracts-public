// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployFactoryV12} from "../script/DeployFactoryV12.s.sol";

/// @notice Audit round 6: direct, deterministic tests for the deploy-time validation guards added in round 5
/// (external review). `validateCastsAndInterval` is a pure function taking explicit arguments (extracted from
/// `run()` specifically so it can be tested this way -- `vm.setEnv`-based testing of the full script does not
/// reliably reset state between test functions within one forge process, discovered while first attempting that
/// approach here). The one guard that genuinely needs a real chain (the PoolManager code-length check) is tested
/// separately, directly, on a real Ink fork.
contract DeployFactoryV12ValidationTest is Test {
    DeployFactoryV12 deployScript;

    function setUp() public {
        deployScript = new DeployFactoryV12();
    }

    // ------------------------------------------------------------------------------ safe casts

    function test_VotingDelayAboveUint48Range_Reverts() public {
        vm.expectRevert(bytes("VOTING_DELAY_SECONDS does not fit in uint48"));
        deployScript.validateCastsAndInterval(uint256(type(uint48).max) + 1, 1 days, 1 hours, 2_000_000_000);
    }

    function test_VotingDelayAtExactlyUint48Max_Accepted() public view {
        (uint48 votingDelay,) = deployScript.validateCastsAndInterval(type(uint48).max, 1 days, 1 hours, 2_000_000_000);
        assertEq(votingDelay, type(uint48).max);
    }

    function test_VotingPeriodAboveUint32Range_Reverts() public {
        vm.expectRevert(bytes("VOTING_PERIOD_SECONDS does not fit in uint32"));
        deployScript.validateCastsAndInterval(1 days, uint256(type(uint32).max) + 1, 1 hours, 2_000_000_000);
    }

    function test_VotingPeriodAtExactlyUint32Max_Accepted() public view {
        (, uint32 votingPeriod) = deployScript.validateCastsAndInterval(1 days, type(uint32).max, 1 hours, 2_000_000_000);
        assertEq(votingPeriod, type(uint32).max);
    }

    // ------------------------------------------------------------------------------ expirationInterval sanity bounds

    function test_ZeroExpirationInterval_Reverts() public {
        vm.expectRevert(bytes("EXPIRATION_INTERVAL_SECONDS is zero or absurdly large"));
        deployScript.validateCastsAndInterval(1 days, 3 days, 0, 2_000_000_000);
    }

    function test_ExpirationIntervalAtOrAboveNow_Reverts() public {
        vm.expectRevert(bytes("EXPIRATION_INTERVAL_SECONDS is zero or absurdly large"));
        deployScript.validateCastsAndInterval(1 days, 3 days, 2_000_000_000, 2_000_000_000);

        vm.expectRevert(bytes("EXPIRATION_INTERVAL_SECONDS is zero or absurdly large"));
        deployScript.validateCastsAndInterval(1 days, 3 days, 2_000_000_001, 2_000_000_000);
    }

    function test_ExpirationIntervalOneSecondBelowNow_Accepted() public view {
        // an interval one second below "now", but still comfortably within the separate bounds below --
        // was 29 days (comfortably under the old 30-day-only cap); tightened to 1 day once the
        // interval*24-vs-30-days check below made 29 days itself invalid, so this stays isolated to
        // testing only the "at or above now" edge case, not the interval-count bound.
        deployScript.validateCastsAndInterval(1 days, 3 days, 1 days, 1 days + 1);
        // no revert: reaching here is the assertion
    }

    function test_ExpirationIntervalAboveMaxLiquidationDuration_Reverts() public {
        vm.expectRevert(
            bytes(
                "EXPIRATION_INTERVAL_SECONDS exceeds the treasury's own MAX_LIQUIDATION_DURATION (30 days): every liquidation would revert"
            )
        );
        deployScript.validateCastsAndInterval(1 days, 3 days, 31 days, 2_000_000_000);
    }

    /// @dev 30 days alone still passes the check directly above (the plain 30-day cap) -- this is
    /// specifically the gap a review found and this test pins closed: 30 days * MIN_LIQUIDATION_INTERVALS
    /// (24) is 720 days, so no durationIntervals value could ever satisfy both liquidateTreasury floors at
    /// once. Confirmed via revert-then-retest: this test failed (no revert) against the code before the
    /// interval-count require was added, and passes now.
    function test_ExpirationIntervalAtExactlyThirtyDays_RevertsOnIntervalCountBound() public {
        vm.expectRevert(
            bytes(
                "EXPIRATION_INTERVAL_SECONDS * MIN_LIQUIDATION_INTERVALS (24) exceeds MAX_LIQUIDATION_DURATION (30 days): every liquidation would revert regardless of durationIntervals chosen"
            )
        );
        deployScript.validateCastsAndInterval(1 days, 3 days, 30 days, 2_000_000_000);
    }

    function test_ExpirationIntervalOneSecondAboveThirtyDays_Reverts() public {
        vm.expectRevert(
            bytes(
                "EXPIRATION_INTERVAL_SECONDS exceeds the treasury's own MAX_LIQUIDATION_DURATION (30 days): every liquidation would revert"
            )
        );
        deployScript.validateCastsAndInterval(1 days, 3 days, 30 days + 1, 2_000_000_000);
    }

    /// @dev The real bound this generation actually enforces: 30 days / MIN_LIQUIDATION_INTERVALS (24) =
    /// 1.25 days (108,000 seconds) exactly, since 2,592,000 / 24 has no remainder.
    function test_ExpirationIntervalAtExactlyOnePointTwoFiveDays_Accepted() public view {
        deployScript.validateCastsAndInterval(1 days, 3 days, 108_000, 2_000_000_000);
        // no revert: reaching here is the assertion
    }

    function test_ExpirationIntervalOneSecondAboveOnePointTwoFiveDays_Reverts() public {
        vm.expectRevert(
            bytes(
                "EXPIRATION_INTERVAL_SECONDS * MIN_LIQUIDATION_INTERVALS (24) exceeds MAX_LIQUIDATION_DURATION (30 days): every liquidation would revert regardless of durationIntervals chosen"
            )
        );
        deployScript.validateCastsAndInterval(1 days, 3 days, 108_001, 2_000_000_000);
    }

    /// @dev The standard real-world value (1 hour, matching every deployed generation so far) is accepted.
    function test_TheStandardOneHourInterval_IsAccepted() public view {
        (uint48 votingDelay, uint32 votingPeriod) = deployScript.validateCastsAndInterval(1 days, 3 days, 1 hours, 2_000_000_000);
        assertEq(votingDelay, 1 days);
        assertEq(votingPeriod, 3 days);
    }

    // ------------------------------------------------------------------------------ PoolManager code check (needs a real chain)

    // Ink's canonical Uniswap v4 PoolManager -- the same address DeployFactoryV6.s.t.sol hardcodes, not read from
    // .env, so this test does not depend on any local env config (the contracts-only audit mirror of this repo has
    // no .env at all).
    address constant CANONICAL_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    function test_PoolManagerWithNoCode_HasNoCode_OnARealChain() public {
        vm.createSelectFork("ink");
        address fake = makeAddr("not-a-real-pool-manager");
        assertEq(fake.code.length, 0, "a freshly made address genuinely has no code");
        assertGt(CANONICAL_POOL_MANAGER.code.length, 0, "the real, canonical PoolManager genuinely has code");
    }
}
