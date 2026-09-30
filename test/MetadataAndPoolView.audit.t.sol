// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";

contract DummyTokenStub {}

/// @notice Round-9 audit finding on TokenMetadataRegistry, FIXED. Distinct from the already-fixed
/// CREATE-address-prediction front-run (see TokenMetadataRegistry.frontrun.t.sol, which only
/// covers a token that doesn't exist yet). setMetadataURI has NO access control at all beyond
/// "token must have code" and "not already decided" -- its only real-world safety comes from
/// StocksLaunchFactory.createCurve() calling it atomically at launch. The bug: createCurve() used
/// to treat a non-empty metadataURI as OPTIONAL and simply SKIP the call when the launcher passed
/// "" -- and the registry itself inferred "already decided" from "the stored URI is non-empty," so
/// a skipped call left that token's slot looking genuinely untouched forever, on a live, trading
/// token, with zero time-based or ownership-based protection. Anyone could claim that slot with an
/// arbitrary URI at any later point, and AlreadySet then permanently blocked the real team from
/// ever correcting it.
///
/// THE FIX: TokenMetadataRegistry now tracks the decision itself (`metadataDecided`), independent
/// of what value was chosen, and StocksLaunchFactory.createCurve() now calls setMetadataURI
/// unconditionally, even for "" -- so every token launched through the current factory has its one
/// shot taken atomically at creation, empty or not, before anyone else could ever get a call in.
/// test_AUDIT_EmptyMetadataChoice_NowLocksTheSlotForever below proves the registry's own half of
/// this (the same one-shot call the factory now always makes). The registry can never fully
/// eliminate test_RegistryItself_StillPermissionlessForATrulyUntouchedSlot below -- an address the
/// CURRENT factory never processed at all (an old pre-registry generation's token, or literally
/// any other contract nobody's called this for) is, by design, still open to whoever calls first --
/// but the fix means the current factory itself never produces that "untouched forever" state for
/// any token it launches, empty metadata choice or not.
contract MetadataAndPoolViewAuditTest is Test {
    TokenMetadataRegistry registry;

    function setUp() public {
        registry = new TokenMetadataRegistry();
    }

    /// @dev Proves the fix: an empty-string choice (what StocksLaunchFactory.createCurve() now
    /// always submits, even when the launcher picked no metadata) locks the slot exactly like a
    /// real URI would -- nobody, not a squatter, not the real team, can ever call this again.
    function test_AUDIT_EmptyMetadataChoice_NowLocksTheSlotForever() public {
        address liveToken = address(new DummyTokenStub());

        // Simulates StocksLaunchFactory.createCurve()'s own unconditional call, for a launcher who
        // chose no on-chain metadata.
        registry.setMetadataURI(liveToken, "");
        assertTrue(registry.metadataDecided(liveToken), "the empty choice must count as decided");

        vm.warp(block.timestamp + 365 days);

        address squatter = makeAddr("squatter");
        vm.prank(squatter);
        vm.expectRevert(TokenMetadataRegistry.AlreadySet.selector);
        registry.setMetadataURI(liveToken, "ipfs://totally-not-a-phishing-link");
        assertEq(registry.metadataURI(liveToken), "", "must stay empty, not squatted");

        // Not even the real team gets a second chance -- "permanently, once" applies to them too,
        // exactly as intended: the launcher already made this call at launch time.
        vm.prank(makeAddr("realTeam"));
        vm.expectRevert(TokenMetadataRegistry.AlreadySet.selector);
        registry.setMetadataURI(liveToken, "ipfs://the-real-legitimate-metadata");

        console.log("FIXED: an empty metadata choice at launch now locks the slot forever, closing the squat window");
    }

    /// @dev Documents the registry's remaining, deliberate limit: an address the current factory
    /// never called this for AT ALL (not "called with empty," genuinely never called) is still
    /// first-come. This is inherent to a permissionless registry with no onlyFactory gate -- the
    /// fix's guarantee is that the CURRENT factory never leaves a token it launches in this state,
    /// not that the registry can retroactively protect tokens nothing ever registered for.
    function test_RegistryItself_StillPermissionlessForATrulyUntouchedSlot() public {
        address neverProcessedToken = address(new DummyTokenStub());
        assertFalse(registry.metadataDecided(neverProcessedToken));

        address squatter = makeAddr("squatter");
        vm.prank(squatter);
        registry.setMetadataURI(neverProcessedToken, "ipfs://first-caller-wins");
        assertEq(registry.metadataURI(neverProcessedToken), "ipfs://first-caller-wins");

        console.log("EXPECTED: a token the factory never called this for at all is still first-come -- not this registry's job to retroactively cover");
    }
}
