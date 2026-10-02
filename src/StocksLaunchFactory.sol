// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Stocks.ink. All rights reserved. No license to use, copy, modify, deploy or distribute this code is granted without the written permission of Stocks.ink.

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                  ║
// ║   S T O C K S . I N K                                            ║
// ║                                                                  ║
// ║   Tokenized Stock Treasuries (TSTs): the inverse of a Digital    ║
// ║   Asset Treasury (DAT).                                          ║
// ║                                                                  ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// A TST turns its own trading volume into a growing on-chain treasury of
// tokenized equities, directed by its community and distributed to stakers.

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TSTToken} from "./TSTToken.sol";
import {StocksCurveFactory} from "./curve/StocksCurveFactory.sol";
import {TokenMetadataRegistry} from "./TokenMetadataRegistry.sol";

/// @title StocksLaunchFactory
/// @notice Entry point for launching a TST. One call deploys the token, deploys its bonding curve, hands the
/// whole supply to that curve and records the token's metadata.
/// @dev The factory is also the per-generation configuration store: the curve reads the hook, graduator,
/// spawner factories and governance settings back from here at graduation, and the graduator only accepts a
/// caller that this factory recorded in `curveOf`. Everything is immutable. There is no owner and no
/// privileged function; the only trusted party is `trustedSigner`, which attests the launch price.
contract StocksLaunchFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fixed supply of every TST, minted once at launch and sent in full to its curve.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Shortest voting delay a generation may be configured with. Mirrors StocksGovernor's own floor so a
    /// misconfigured generation fails at factory deployment rather than at each token's graduation.
    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    /// @notice Shortest voting period a generation may be configured with. Mirrors StocksGovernor's own floor.
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    /// @notice Shortest reward period a generation may allow. Mirrors StocksStaking's own constructor floor.
    uint256 public constant MIN_STAKING_REWARDS_DURATION = 1 hours;

    /// @notice Address whose signature attests the stock price a launch is priced against.
    address public immutable trustedSigner;
    /// @notice Recipient of the protocol's share of every flywheel cost charged by the hook and by redemption.
    address public immutable protocol;
    /// @notice The Uniswap v4 hook every pool of this generation is created on.
    address public immutable hook;
    /// @notice Spawner used at graduation to deploy each token's governor.
    address public immutable governorFactory;
    /// @notice Spawner used at graduation to deploy each token's staking contract (its treasury).
    address public immutable stakingFactory;
    /// @notice Spawner used at launch to deploy each token's bonding curve.
    address public immutable curveDeployer;
    /// @notice Contract that seeds the v4 pool at graduation. Only curves recorded here may call it.
    address public immutable v4Graduator;
    /// @notice Shared write-once registry holding each token's metadata URI.
    address public immutable metadataRegistry;

    /// @notice USD value (18 decimals) of stock a curve must collect before it can graduate.
    uint256 public immutable graduationUsdThreshold;
    /// @notice Shortest staking reward period a launcher may choose.
    uint256 public immutable minRewardsDuration;
    /// @notice Longest staking reward period a launcher may choose.
    uint256 public immutable maxRewardsDuration;
    /// @notice Voting delay, in seconds, given to every governor of this generation.
    uint48 public immutable votingDelay;
    /// @notice Voting period, in seconds, given to every governor of this generation.
    uint32 public immutable votingPeriod;
    /// @notice Share of circulating supply, in basis points, needed to create a proposal.
    uint256 public immutable proposalThresholdBps;

    /// @notice Price attestations already consumed. Keyed by the hash of the attested message (stock token, price,
    /// timestamp) rather than of the signature, so a malleated copy of a signature cannot reuse it.
    mapping(bytes32 => bool) public usedAttestations;
    /// @notice The curve deployed for each TST. This is the registry the graduator authenticates callers against.
    mapping(address token => address curve) public curveOf;

    /// @notice Emitted once per launch.
    /// @param token The new TST.
    /// @param curve Its bonding curve, which holds the whole supply.
    /// @param stockToken The tokenized stock the TST is priced in and backed by.
    /// @param deployer The account that called `createCurve`.
    event CurveLaunched(address indexed token, address indexed curve, address stockToken, address deployer);

    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice The reward duration is outside the allowed range, or the range itself is invalid.
    error InvalidRewardsDuration();
    /// @notice This price attestation has already been used for a launch.
    error AttestationAlreadyUsed();
    /// @notice The configured voting delay is below `MIN_VOTING_DELAY`.
    error InvalidVotingDelay();
    /// @notice The configured voting period is below `MIN_VOTING_PERIOD`.
    error InvalidVotingPeriod();
    /// @notice The configured graduation threshold is zero.
    error InvalidGraduationThreshold();
    /// @notice The configured proposal threshold exceeds 100%.
    error InvalidProposalThreshold();
    /// @notice The token name is too long for the governor that graduation will deploy (see MAX_TST_NAME_BYTES).
    error NameTooLongForGraduation();

    // External audit finding (AuditAgent, 2026-09-30): TSTToken's own constructor already caps `name`
    // at 31 bytes (ShortStrings, via its own EIP712(name_, "1")), so a name up to 31 bytes deploys fine
    // here -- but StocksCurve._graduate() later passes `string.concat(tstToken.name(), " GOVERNOR_SUFFIX")`
    // to StocksGovernorFactory, whose EIP712 constructor has the SAME 31-byte ShortStrings limit. A name
    // of 23-31 bytes therefore launches, collects stock, and reaches its graduation target normally, then
    // PERMANENTLY reverts at graduate() forever (the name is immutable, so there is no way to recover).
    // Proven directly (a real Foundry test: a 24-byte name graduates-reverts identically on every retry).
    // Capped here, at launch, to the largest length that can never hit that later limit -- the same
    // "validate at launch, not discover at graduation" philosophy as this contract's other checks.
    // `bytes(literal).length` isn't a compile-time constant in this solc version, so this stays a plain
    // number rather than a derived one -- kept in sync with StocksCurve._graduate()'s own
    // `string.concat(tstToken.name(), " Governor")` by a dedicated regression test
    // (test/AuditAgentVerify.longName.t.sol) that fails loudly if either side ever changes without the
    // other: " Governor" is 9 bytes, so 31 (ShortStrings' cap) - 9 = 22.
    /// @dev Longest TST name, in bytes, that can still graduate. See the explanation above.
    uint256 internal constant MAX_TST_NAME_BYTES = 22;

    /// @notice Fixes the configuration of one generation. Every value is validated here so that a bad value fails
    /// the deployment instead of surfacing later, at some token's graduation.
    /// @param _trustedSigner Signer of launch price attestations.
    /// @param _protocol Recipient of the protocol's share of the flywheel cost.
    /// @param _hook The v4 hook pools are created on.
    /// @param _governorFactory Governor spawner.
    /// @param _stakingFactory Staking spawner.
    /// @param _curveDeployer Curve spawner.
    /// @param _v4Graduator Pool seeder; must have been deployed against this factory's address.
    /// @param _metadataRegistry Shared metadata registry.
    /// @param _graduationUsdThreshold USD (18 decimals) of stock a curve must collect to graduate.
    /// @param _minRewardsDuration Shortest reward period a launcher may choose.
    /// @param _maxRewardsDuration Longest reward period a launcher may choose.
    /// @param _votingDelay Governor voting delay in seconds.
    /// @param _votingPeriod Governor voting period in seconds.
    /// @param _proposalThresholdBps Proposal threshold in basis points of circulating supply.
    constructor(
        address _trustedSigner,
        address _protocol,
        address _hook,
        address _governorFactory,
        address _stakingFactory,
        address _curveDeployer,
        address _v4Graduator,
        address _metadataRegistry,
        uint256 _graduationUsdThreshold,
        uint256 _minRewardsDuration,
        uint256 _maxRewardsDuration,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThresholdBps
    ) {
        if (
            _trustedSigner == address(0) || _protocol == address(0) || _hook == address(0)
                || _governorFactory == address(0) || _stakingFactory == address(0) || _curveDeployer == address(0)
                || _v4Graduator == address(0) || _metadataRegistry == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_minRewardsDuration > _maxRewardsDuration) revert InvalidRewardsDuration();
        if (_minRewardsDuration < MIN_STAKING_REWARDS_DURATION) revert InvalidRewardsDuration();

        if (_votingDelay < MIN_VOTING_DELAY) revert InvalidVotingDelay();
        if (_votingPeriod < MIN_VOTING_PERIOD) revert InvalidVotingPeriod();
        if (_graduationUsdThreshold == 0) revert InvalidGraduationThreshold();
        if (_proposalThresholdBps > 10_000) revert InvalidProposalThreshold();

        trustedSigner = _trustedSigner;
        protocol = _protocol;
        hook = _hook;
        governorFactory = _governorFactory;
        stakingFactory = _stakingFactory;
        curveDeployer = _curveDeployer;
        v4Graduator = _v4Graduator;
        metadataRegistry = _metadataRegistry;
        graduationUsdThreshold = _graduationUsdThreshold;
        minRewardsDuration = _minRewardsDuration;
        maxRewardsDuration = _maxRewardsDuration;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThresholdBps = _proposalThresholdBps;
    }

    /// @notice Launches a new TST against a signed stock price.
    /// @dev Permissionless. The attestation is consumed before anything is deployed, and the curve's constructor
    /// verifies the signature, so an invalid or stale attestation reverts the whole call and consumes nothing. The
    /// attestation binds the factory, stock token, price and timestamp only: it does not bind the caller, name or
    /// symbol, so whoever submits it first uses it (a known and accepted limitation; nothing of value goes to the
    /// caller, the whole supply goes to the curve).
    /// @param name TST name, at most 22 bytes.
    /// @param symbol TST symbol.
    /// @param stockToken The tokenized stock to price against. Must be an 18-decimal token.
    /// @param price Attested USD price of one whole stock token, 18 decimals.
    /// @param priceTimestamp Time the price was attested. Must be at most five minutes old and not in the future.
    /// @param signature The trusted signer's signature over (factory, stockToken, price, priceTimestamp).
    /// @param rewardsDuration Reward period the token's staking contract will start with.
    /// @param metadataURI Metadata URI recorded for the token. Write-once.
    /// @return token The new TST.
    /// @return curve Its bonding curve.
    function createCurve(
        string calldata name,
        string calldata symbol,
        address stockToken,
        uint256 price,
        uint256 priceTimestamp,
        bytes calldata signature,
        uint256 rewardsDuration,
        string calldata metadataURI
    ) external nonReentrant returns (address token, address curve) {
        if (rewardsDuration < minRewardsDuration || rewardsDuration > maxRewardsDuration) {
            revert InvalidRewardsDuration();
        }
        if (bytes(name).length > MAX_TST_NAME_BYTES) revert NameTooLongForGraduation();

        // One launch per attestation. Marked before any external call; a later revert undoes it.
        bytes32 attestationId = keccak256(abi.encodePacked(stockToken, price, priceTimestamp));
        if (usedAttestations[attestationId]) revert AttestationAlreadyUsed();
        usedAttestations[attestationId] = true;

        // The supply is minted to this factory and forwarded to the curve below, so the factory never keeps a balance.
        TSTToken tst = new TSTToken(name, symbol, TOTAL_SUPPLY, address(this));
        address newCurve = StocksCurveFactory(curveDeployer).deploy(
            address(tst),
            stockToken,
            trustedSigner,
            price,
            priceTimestamp,
            signature,
            rewardsDuration,
            graduationUsdThreshold,
            minRewardsDuration,
            maxRewardsDuration
        );

        IERC20(address(tst)).safeTransfer(newCurve, TOTAL_SUPPLY);

        token = address(tst);
        curve = newCurve;

        curveOf[token] = newCurve;

        // Last step. The registry is write-once and permissionless, but it rejects an address with no code, so nobody
        // could have claimed this entry before the token existed (see the round-22 note in the audit record).
        TokenMetadataRegistry(metadataRegistry).setMetadataURI(token, metadataURI);

        emit CurveLaunched(token, curve, stockToken, msg.sender);
    }
}
