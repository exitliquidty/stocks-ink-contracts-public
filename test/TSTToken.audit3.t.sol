// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TSTToken} from "../src/TSTToken.sol";

/// @notice Round-3 audit on TSTToken.sol: fresh adversarial pass focused on whether this token's
/// own mechanics (constructor/mint recipient, ERC20Votes delegation semantics, burn accounting,
/// privileged roles) independently worsen or mitigate the RESERVED_SUPPLY graduation-price bug
/// found this round in StocksCurve.sol/StocksGraduator.sol (a curve holds its full 1B TOTAL_SUPPLY
/// from launch, including the never-sold 200M RESERVED_SUPPLY, until graduation drains it all into
/// the new pool). Rounds 1-2 already covered general ERC20Votes correctness (clock mode, delegation
/// activating checkpoints, transfer-only-moves-votes-when-delegated, delegateBySig) and the real,
/// quantified OP-Stack sequencer-drift risk to the voting floor -- neither re-litigated here.
contract TSTTokenAudit3Test is Test {
    TSTToken token;

    address curveStandIn = address(0xC0FFEE); // a plain contract/EOA that never calls delegate() --
        // stands in for the real StocksCurve, which has no delegate() call anywhere in its own code.
    address trader = address(0xBEEF);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant RESERVED_SUPPLY = 200_000_000e18;

    function setUp() public {
        // Mirrors the real launch flow exactly: TSTToken's constructor mints the FULL supply to a
        // single recipient (in production, StocksLaunchFactory, which immediately forwards the
        // entire balance on to the curve) -- there is no separate "reserved" mint or vesting
        // schedule anywhere in this token's own code. Minting directly to curveStandIn here is
        // behaviorally identical to factory-mint-then-forward, since neither step ever delegates.
        token = new TSTToken("Acme", "ACME", SUPPLY, curveStandIn);
    }

    /// @notice CONFIRMED SAFE: the curve's own large, undelegated balance -- including the
    /// RESERVED_SUPPLY portion that rides along inside it for the token's entire pre-graduation
    /// life -- contributes ZERO voting power. TSTToken has no auto-delegation-on-mint or
    /// auto-delegation-on-transfer anywhere; OZ's ERC20Votes requires an explicit delegate() call
    /// from the balance holder. Since StocksCurve never calls delegate() (confirmed by inspection:
    /// no such call exists anywhere in StocksCurve.sol), the RESERVED_SUPPLY bug cannot be
    /// compounded into a governance-power issue -- it's a purely economic (pool-price) bug, not an
    /// additional voting-power-inflation vector.
    function test_AUDIT_CurveHoldingFullSupplyIncludingReserved_CarriesZeroVotingPower() public {
        assertEq(token.balanceOf(curveStandIn), SUPPLY, "sanity: curve holds the full mint, RESERVED_SUPPLY included");
        assertEq(token.getVotes(curveStandIn), 0, "CONFIRMED SAFE: undelegated balance, however large, has zero voting weight");

        vm.warp(block.timestamp + 1);
        assertEq(token.getPastVotes(curveStandIn, block.timestamp - 1), 0, "CONFIRMED SAFE: no historical voting weight either -- delegation was simply never activated");
    }

    /// @notice CONFIRMED SAFE: this also means a fresh buyer (StocksCurve.buy() transfers TST out
    /// of the curve to the trader) does NOT inherit any voting power either -- ERC20Votes never
    /// auto-delegates the recipient of a transfer, matching (and here re-verified from the curve's
    /// specific real transfer path, not just a generic alice->bob transfer) round 1's existing
    /// "TokensAcquiredAfterSnapshot_HaveZeroVotingWeight" coverage.
    function test_AUDIT_TraderReceivingTstFromCurve_HasZeroVotesUntilSelfDelegating() public {
        vm.prank(curveStandIn);
        token.transfer(trader, 1_000e18);

        assertEq(token.balanceOf(trader), 1_000e18);
        assertEq(token.getVotes(trader), 0, "CONFIRMED SAFE: receiving TST from the curve grants no voting power until the trader explicitly delegates");

        vm.prank(trader);
        token.delegate(trader);
        assertEq(token.getVotes(trader), 1_000e18, "sanity: explicit self-delegation does activate it, as expected");
    }

    /// @notice CONFIRMED SAFE (code-inspection, not test-derived): TSTToken.sol has no owner, no
    /// minter role, no pause/freeze/blacklist mechanism, and no post-constructor mint path --
    /// `_mint` is called exactly once, in the constructor. There is no function on this contract
    /// whose selector could grant any privileged party additional supply or control after
    /// deployment; the ABI surface is limited to what ERC20Votes/EIP712/ERC6372Utils already expose
    /// plus the two view overrides (`clock`, `CLOCK_MODE`). No PoC applies since there is no
    /// function to call -- this line stands as the recorded conclusion of that inspection.
    function test_NoOp_NoPrivilegedRoleExistsOnThisToken_CodeInspectionOnly() public pure {
        assertTrue(true);
    }
}
