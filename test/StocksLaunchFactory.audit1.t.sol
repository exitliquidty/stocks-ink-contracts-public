// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";

/// @notice Round-1 audit on StocksLaunchFactory + its three sub-factories (StocksCurveFactory,
/// StocksStakingFactory, StocksGovernorFactory). No new exploitable finding -- see the audit
/// report for the full reasoning. Two things worth permanent regression coverage:
///
/// 1. `StocksLaunchFactory.TOTAL_SUPPLY` and `StocksCurve.TOTAL_SUPPLY` are two INDEPENDENT
/// hardcoded constants (not a shared import), and the factory transfers the launch-side constant's
/// full value to every new curve. This is exactly the kind of duplication that let the already-
/// reported RESERVED_SUPPLY bug (StocksCurve._graduate() dumping the curve's whole balance,
/// including the 200M never-sold reserve, into the graduated pool) go unnoticed -- there is no
/// single source of truth tying "how much TST gets minted and sent to a curve" to "how much TST a
/// curve is actually designed to sell". They currently agree, but nothing enforces that they always
/// will; if a future edit changes one without the other, the failure modes differ sharply in kind
/// (transferring MORE than expected silently dilutes the graduation price the same way
/// RESERVED_SUPPLY already does; transferring LESS could instead hard-lock late buyers when the
/// curve runs out of TST to sell, a denial-of-service rather than a silent value leak). This test
/// is a canary: it fails immediately if the two ever drift apart, forcing that drift to be a
/// conscious decision instead of a silent regression.
///
/// 2. `StocksCurveFactory.deploy()`/`StocksStakingFactory.deploy()`/`StocksGovernorFactory.deploy()`
/// all have zero access control -- anyone can call them directly, bypassing StocksLaunchFactory
/// entirely, and get a real, fully-functional StocksCurve/StocksStaking/StocksGovernor back. This
/// is confirmed NOT exploitable against the real, shared infrastructure: `StocksGraduator.graduate()`
/// (src/dex/v4/StocksGraduator.sol:85) independently gates on
/// `msg.sender == ICurveRegistry(factory).curveOf(tstToken)`, where `factory` is the REAL
/// `StocksLaunchFactory` singleton passed into the real StocksGraduator's own constructor. A rogue
/// curve deployed by calling `StocksCurveFactory.deploy()` directly is never registered in the real
/// StocksLaunchFactory's `curveOf` mapping (only `createCurve()` ever writes to it), so its
/// `_graduate()` call reverts with `NotCurve()` the moment it tries to reach the real, shared
/// StocksGraduator/StocksHook/PoolManager -- already extensively covered by the existing
/// `NotCurve` regression suite in `test/StocksGraduator.security.t.sol` and
/// `test/StocksGraduator.H3CurveHijackFix.t.sol` (this exact class of attack was found and fixed in
/// an earlier generation, well before this session). Not re-tested here to avoid duplicating that
/// coverage; a rogue deployer can only ever stand up their own fully separate, self-contained
/// system (their own fake "factory" providing its own hook/graduator/protocol addresses) -- which
/// poses no risk to real users or real pools.
contract StocksLaunchFactoryAudit1Test is Test {
    uint256 signerKey = 0xA11CE;

    function test_AUDIT_TotalSupplyConstants_MustStayInSyncAcrossFactoryAndCurve() public {
        StocksLaunchFactory factory = new StocksLaunchFactory(
            address(0x1), // trustedSigner
            address(0x2), // protocol
            address(0x3), // hook
            address(0x4), // governorFactory
            address(0x5), // stakingFactory
            address(0x6), // curveDeployer
            address(0x7), // v4Graduator
            address(0x8), // metadataRegistry
            8_000e18, // graduationUsdThreshold
            1 hours, // minRewardsDuration
            365 days, // maxRewardsDuration
            1 hours, // votingDelay
            1 hours, // votingPeriod
            50 // proposalThresholdBps
        );

        address signer = vm.addr(signerKey);
        address stockToken = address(0x9999);
        uint256 price = 100e18;
        uint256 priceTimestamp = block.timestamp;
        bytes32 attestationHash = keccak256(abi.encodePacked(address(0xFACE), stockToken, price, priceTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(attestationHash));

        StocksCurve curve = new StocksCurve(
            address(0xAAAA),
            stockToken,
            signer,
            price,
            priceTimestamp,
            abi.encodePacked(r, s, v),
            7 days,
            address(0xFACE),
            8_000e18,
            1 days,
            365 days
        );

        assertEq(
            factory.TOTAL_SUPPLY(),
            curve.TOTAL_SUPPLY(),
            "DESIGN RISK: StocksLaunchFactory.TOTAL_SUPPLY and StocksCurve.TOTAL_SUPPLY are independently hardcoded, not a shared constant -- this canary must keep passing, or the RESERVED_SUPPLY-style dilution/lock-up failure mode has drifted"
        );
    }
}
