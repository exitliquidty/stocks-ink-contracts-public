// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksCurve} from "../src/curve/StocksCurve.sol";
import {TSTToken} from "../src/TSTToken.sol";
import {TokenMetadataRegistry} from "../src/TokenMetadataRegistry.sol";

/// @notice Direct tests of StocksLaunchFactory.createCurve, the one entry point every launch goes through.
/// The final audit's mutation check found nothing failed when the attestation replay guard was deleted,
/// so this file covers the whole launch path: what a launch mints and where it goes, every way the signed
/// price attestation can be rejected, the reward-duration bounds, the replay guard, metadata handling, and
/// the constructor's own validation.
contract StocksLaunchFactoryLaunchTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    uint256 constant THRESHOLD = 8_000e18;
    uint256 constant MIN_DURATION = 1 days;
    uint256 constant MAX_DURATION = 365 days;

    StocksLaunchFactory factory;
    StocksCurveFactory curveFactory;
    TokenMetadataRegistry registry;
    address signer;
    address stock = address(0x57C0C);
    address alice = address(0xA11CE1);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_800_000_000);
        signer = vm.addr(SIGNER_KEY);
        curveFactory = new StocksCurveFactory();
        registry = new TokenMetadataRegistry();
        factory = _newFactory(signer, MIN_DURATION, MAX_DURATION, 1 hours, 1 hours);
    }

    /// @dev External so that `vm.expectRevert` can be used repeatedly in one test: a revert inside a `new` in the test's own
    /// frame would end the test at that line, and every check after it would silently never run.
    function newFactoryExt(address trustedSigner, uint256 minDur, uint256 maxDur, uint48 delay, uint32 period)
        external
        returns (StocksLaunchFactory)
    {
        return _newFactory(trustedSigner, minDur, maxDur, delay, period);
    }

    function newFactoryRaw(address[8] memory b, uint256 threshold, uint256 minDur, uint256 maxDur, uint256 proposalBps)
        external
        returns (StocksLaunchFactory)
    {
        return new StocksLaunchFactory(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], threshold, minDur, maxDur, 1 hours, 1 hours, proposalBps);
    }

    function _newFactory(address trustedSigner, uint256 minDur, uint256 maxDur, uint48 delay, uint32 period)
        internal
        returns (StocksLaunchFactory)
    {
        return new StocksLaunchFactory(
            trustedSigner,
            address(0x2), // protocol
            address(0x3), // hook
            address(0x4), // governorFactory
            address(0x5), // stakingFactory
            address(curveFactory),
            address(0x7), // v4Graduator
            address(registry),
            THRESHOLD,
            minDur,
            maxDur,
            delay,
            period,
            25
        );
    }

    function _sign(uint256 key, address forFactory, address stockToken, uint256 price, uint256 ts)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 h = keccak256(abi.encodePacked(forFactory, stockToken, price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(h));
        return abi.encodePacked(r, s, v);
    }

    function _attest(uint256 price) internal returns (uint256 ts, bytes memory sig) {
        ts = vm.getBlockTimestamp();
        sig = _sign(SIGNER_KEY, address(factory), stock, price, ts);
    }

    function _create(address who, string memory name, uint256 price, uint256 ts, bytes memory sig, uint256 dur, string memory uri)
        internal
        returns (address token, address curve)
    {
        vm.prank(who);
        return factory.createCurve(name, "SYM", stock, price, ts, sig, dur, uri);
    }

    // ---------------------------------------------------------------- what a launch creates

    function test_Launch_MintsFullSupplyToTheCurve_AndRegistersIt() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        (address token, address curve) = _create(alice, "Acme", 100e18, ts, sig, 30 days, "ipfs://x");

        assertEq(IERC20(token).totalSupply(), 1_000_000_000e18, "1B minted");
        assertEq(IERC20(token).balanceOf(curve), 1_000_000_000e18, "all of it sits in the curve");
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "the factory keeps nothing");
        assertEq(IERC20(token).balanceOf(alice), 0, "the creator gets nothing");
        assertEq(factory.curveOf(token), curve, "the curve is registered for its token");
    }

    function test_Launch_CurveIsBoundToThisFactory_AndTheTrustedSigner() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        (address token, address curveAddr) = _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
        StocksCurve curve = StocksCurve(curveAddr);

        assertEq(curve.factory(), address(factory));
        assertEq(curve.trustedSigner(), signer);
        assertEq(address(curve.tstToken()), token);
        assertEq(address(curve.stockToken()), stock);
        assertEq(curve.rewardsDuration(), 30 days);
        assertEq(curve.graduationStockTarget(), (THRESHOLD * 1e18) / 100e18, "target = threshold / price");
        assertFalse(curve.graduated());
    }

    function test_Launch_TokenHasNoAdminAndNoMoreMinting() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        (address token,) = _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
        // Nothing on the token can mint or change supply: the only ways in are the constructor mint.
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", alice, 1e18));
        assertFalse(ok, "no mint function");
        assertEq(TSTToken(token).totalSupply(), 1_000_000_000e18);
    }

    function test_TwoLaunches_AreIndependent() public {
        (uint256 ts, bytes memory sigA) = _attest(100e18);
        (address t1, address c1) = _create(alice, "One", 100e18, ts, sigA, 30 days, "a");
        bytes memory sigB = _sign(SIGNER_KEY, address(factory), stock, 101e18, ts);
        (address t2, address c2) = _create(bob, "Two", 101e18, ts, sigB, 60 days, "b");

        assertTrue(t1 != t2 && c1 != c2);
        assertEq(factory.curveOf(t1), c1);
        assertEq(factory.curveOf(t2), c2);
        assertEq(StocksCurve(c1).rewardsDuration(), 30 days);
        assertEq(StocksCurve(c2).rewardsDuration(), 60 days);
        assertEq(IERC20(t1).balanceOf(c2), 0, "no cross-contamination");
    }

    // ---------------------------------------------------------------- metadata

    function test_Metadata_SetOnceAtLaunch_AndEmptyIsAlsoFinal() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        (address t1,) = _create(alice, "Acme", 100e18, ts, sig, 30 days, "ipfs://real");
        assertEq(registry.metadataURI(t1), "ipfs://real");
        assertTrue(registry.metadataDecided(t1));

        bytes memory sig2 = _sign(SIGNER_KEY, address(factory), stock, 102e18, ts);
        (address t2,) = _create(alice, "Blank", 102e18, ts, sig2, 30 days, "");
        assertTrue(registry.metadataDecided(t2), "an empty choice is still a final choice");
        vm.expectRevert(TokenMetadataRegistry.AlreadySet.selector);
        registry.setMetadataURI(t2, "ipfs://squat");
    }

    // ---------------------------------------------------------------- attestation: replay

    function test_Replay_SameAttestationTwice_Reverts() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
        vm.prank(alice);
        vm.expectRevert(StocksLaunchFactory.AttestationAlreadyUsed.selector);
        factory.createCurve("Acme2", "SYM", stock, 100e18, ts, sig, 30 days, "");
    }

    /// @notice Audit round 2 (Info): the replay guard is keyed by the attested message, not by one particular signature of
    /// it. A signer that does not sign deterministically could otherwise produce a second, different but equally valid
    /// signature over the same attestation and launch twice from it. Signed here with a different nonce.
    function test_Replay_ADifferentValidSignatureOverTheSameAttestation_Reverts() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(alice, "Acme", 100e18, ts, sig, 30 days, "");

        bytes32 h = keccak256(abi.encodePacked(address(factory), stock, uint256(100e18), ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.signWithNonceUnsafe(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h), 12345);
        bytes memory otherSig = abi.encodePacked(r, s, v);
        assertTrue(keccak256(otherSig) != keccak256(sig), "a genuinely different signature");

        vm.prank(alice);
        vm.expectRevert(StocksLaunchFactory.AttestationAlreadyUsed.selector);
        factory.createCurve("Acme2", "SYM", stock, 100e18, ts, otherSig, 30 days, "");
    }

    function test_Replay_FromAnotherAddress_Reverts() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
        vm.prank(bob);
        vm.expectRevert(StocksLaunchFactory.AttestationAlreadyUsed.selector);
        factory.createCurve("Other", "OTH", stock, 100e18, ts, sig, 90 days, "z");
    }

    function test_Replay_IsPerAttestation_ADifferentPriceIsANewAttestation() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
        bytes memory sig2 = _sign(SIGNER_KEY, address(factory), stock, 100e18 + 1, ts);
        _create(alice, "Acme", 100e18 + 1, ts, sig2, 30 days, "");
    }

    /// @dev Documents an accepted property (see AUDIT.md, business-logic flags): the signed message covers the
    /// factory, the stock, the price and the time, but NOT the creator or the name, so anyone who sees a
    /// pending createCurve in the mempool can consume that attestation first with a different name.
    /// The victim's transaction then reverts and they simply request a fresh attestation. Nothing is stolen.
    function test_Accepted_AttestationIsNotBoundToTheCreator_FrontRunnerConsumesIt() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(bob, "Squatted", 100e18, ts, sig, 30 days, "");
        vm.prank(alice);
        vm.expectRevert(StocksLaunchFactory.AttestationAlreadyUsed.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    // ---------------------------------------------------------------- attestation: signature checks

    function test_Signature_WrongSigner_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(0xBAD, address(factory), stock, 100e18, ts);
        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    function test_Signature_ForADifferentStock_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), address(0xDEAD5), 100e18, ts);
        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    function test_Signature_ForADifferentPrice_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, 100e18, ts);
        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        factory.createCurve("Acme", "ACME", stock, 1e18, ts, sig, 30 days, "");
    }

    function test_Signature_ForADifferentFactoryGeneration_Reverts() public {
        StocksLaunchFactory other = _newFactory(signer, MIN_DURATION, MAX_DURATION, 1 hours, 1 hours);
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sigForOther = _sign(SIGNER_KEY, address(other), stock, 100e18, ts);
        vm.expectRevert(StocksCurve.InvalidSignature.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sigForOther, 30 days, "");
        // and it works on the factory it was signed for
        vm.prank(alice);
        other.createCurve("Acme", "ACME", stock, 100e18, ts, sigForOther, 30 days, "");
    }

    function test_Signature_MalformedLength_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        vm.expectRevert();
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, hex"1234", 30 days, "");
    }

    function test_Signature_HighSMalleatedCopy_IsRejected() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), stock, uint256(100e18), ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(n - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        // the original launches once...
        vm.prank(alice);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, abi.encodePacked(r, s, v), 30 days, "");
        // ...and the malleated twin (a different byte string for the same message) cannot launch again
        vm.prank(alice);
        vm.expectRevert();
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, abi.encodePacked(r, sHigh, vFlipped), 30 days, "");
    }

    // ---------------------------------------------------------------- attestation: freshness and price

    function test_Price_StaleByOverFiveMinutes_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, 100e18, ts);
        vm.warp(ts + 5 minutes + 1);
        vm.expectRevert(StocksCurve.StalePrice.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    function test_Price_ExactlyFiveMinutesOld_IsStillAccepted() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, 100e18, ts);
        vm.warp(ts + 5 minutes);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    function test_Price_FromTheFuture_Reverts() public {
        uint256 ts = vm.getBlockTimestamp() + 1;
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, 100e18, ts);
        vm.expectRevert(StocksCurve.StalePrice.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 30 days, "");
    }

    function test_Price_Zero_Reverts() public {
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, 0, ts);
        vm.expectRevert(StocksCurve.InvalidPrice.selector);
        factory.createCurve("Acme", "ACME", stock, 0, ts, sig, 30 days, "");
    }

    function test_Price_SoHighTheTargetRoundsToZero_Reverts() public {
        // threshold * 1e18 / price == 0 once price > threshold * 1e18
        uint256 price = THRESHOLD * 1e18 + 1;
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, price, ts);
        vm.expectRevert(StocksCurve.InvalidPrice.selector);
        factory.createCurve("Acme", "ACME", stock, price, ts, sig, 30 days, "");
    }

    // ---------------------------------------------------------------- reward duration bounds

    function test_Duration_BelowMin_Reverts() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        vm.expectRevert(StocksLaunchFactory.InvalidRewardsDuration.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, MIN_DURATION - 1, "");
    }

    function test_Duration_AboveMax_Reverts() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        vm.expectRevert(StocksLaunchFactory.InvalidRewardsDuration.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, MAX_DURATION + 1, "");
    }

    function test_Duration_ExactBounds_AreAccepted() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        _create(alice, "Min", 100e18, ts, sig, MIN_DURATION, "");
        bytes memory sig2 = _sign(SIGNER_KEY, address(factory), stock, 103e18, ts);
        _create(alice, "Max", 103e18, ts, sig2, MAX_DURATION, "");
    }

    function test_FailedLaunch_LeavesNoTrace_AttestationNotBurned() public {
        (uint256 ts, bytes memory sig) = _attest(100e18);
        vm.expectRevert(StocksLaunchFactory.InvalidRewardsDuration.selector);
        factory.createCurve("Acme", "ACME", stock, 100e18, ts, sig, 1, "");
        // the revert rolled back the replay marker, so the same attestation still works with valid input
        _create(alice, "Acme", 100e18, ts, sig, 30 days, "");
    }

    // ---------------------------------------------------------------- constructor validation

    function test_Constructor_RejectsZeroAddresses() public {
        address[8] memory a = [signer, address(2), address(3), address(4), address(5), address(curveFactory), address(7), address(registry)];
        for (uint256 i; i < 8; ++i) {
            address[8] memory b = a;
            b[i] = address(0);
            vm.expectRevert(StocksLaunchFactory.ZeroAddress.selector);
            this.newFactoryRaw(b, THRESHOLD, MIN_DURATION, MAX_DURATION, 25);
        }
    }

    /// @notice Audit round 2 (C2): settings that would only fail later, at graduation, are refused at construction.
    function test_Constructor_RejectsAGraduationThresholdOfZero_AndAProposalThresholdAbove100Percent() public {
        address[8] memory a = [signer, address(2), address(3), address(4), address(5), address(curveFactory), address(7), address(registry)];
        vm.expectRevert(StocksLaunchFactory.InvalidGraduationThreshold.selector);
        this.newFactoryRaw(a, 0, MIN_DURATION, MAX_DURATION, 25);
        vm.expectRevert(StocksLaunchFactory.InvalidProposalThreshold.selector);
        this.newFactoryRaw(a, THRESHOLD, MIN_DURATION, MAX_DURATION, 10_001);
        // the boundary itself is accepted
        StocksLaunchFactory atBoundary = this.newFactoryRaw(a, THRESHOLD, MIN_DURATION, MAX_DURATION, 10_000);
        assertEq(atBoundary.proposalThresholdBps(), 10_000, "100% is a valid proposal threshold");
        // a fixed reward duration (min == max) is valid too
        StocksLaunchFactory fixedDuration = this.newFactoryRaw(a, THRESHOLD, 7 days, 7 days, 25);
        assertEq(fixedDuration.minRewardsDuration(), fixedDuration.maxRewardsDuration());
        // and exactly one hour is the smallest accepted reward duration
        StocksLaunchFactory oneHour = this.newFactoryRaw(a, THRESHOLD, 1 hours, 1 hours, 25);
        assertEq(oneHour.minRewardsDuration(), 1 hours);
    }

    function test_Constructor_RejectsBadDurationsAndTimings() public {
        vm.expectRevert(StocksLaunchFactory.InvalidRewardsDuration.selector);
        this.newFactoryExt(signer, 10 days, 5 days, 1 hours, 1 hours); // min > max
        vm.expectRevert(StocksLaunchFactory.InvalidRewardsDuration.selector);
        this.newFactoryExt(signer, 1 hours - 1, 5 days, 1 hours, 1 hours); // min below the 1h floor
        vm.expectRevert(StocksLaunchFactory.InvalidVotingDelay.selector);
        this.newFactoryExt(signer, MIN_DURATION, MAX_DURATION, 1 hours - 1, 1 hours);
        vm.expectRevert(StocksLaunchFactory.InvalidVotingPeriod.selector);
        this.newFactoryExt(signer, MIN_DURATION, MAX_DURATION, 1 hours, 1 hours - 1);
        // the exact floors are accepted
        this.newFactoryExt(signer, 1 hours, 1 hours, 1 hours, 1 hours);
    }

    function test_Constructor_StoresEveryParameter() public {
        assertEq(factory.trustedSigner(), signer);
        assertEq(factory.graduationUsdThreshold(), THRESHOLD);
        assertEq(factory.minRewardsDuration(), MIN_DURATION);
        assertEq(factory.maxRewardsDuration(), MAX_DURATION);
        assertEq(factory.votingDelay(), 1 hours);
        assertEq(factory.votingPeriod(), 1 hours);
        assertEq(factory.proposalThresholdBps(), 25);
        assertEq(factory.metadataRegistry(), address(registry));
        assertEq(factory.curveDeployer(), address(curveFactory));
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_AnyValidLaunch_ConservesSupply(uint256 price, uint256 dur, uint256 age) public {
        price = bound(price, 1e15, THRESHOLD);
        dur = bound(dur, MIN_DURATION, MAX_DURATION);
        age = bound(age, 0, 5 minutes);
        uint256 ts = vm.getBlockTimestamp();
        bytes memory sig = _sign(SIGNER_KEY, address(factory), stock, price, ts);
        vm.warp(ts + age);
        vm.prank(alice);
        (address token, address curve) = factory.createCurve("F", "F", stock, price, ts, sig, dur, "");
        assertEq(IERC20(token).totalSupply(), 1_000_000_000e18);
        assertEq(IERC20(token).balanceOf(curve), 1_000_000_000e18);
        assertEq(factory.curveOf(token), curve);
    }
}
