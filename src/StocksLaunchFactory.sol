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

contract StocksLaunchFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    uint256 public constant MIN_STAKING_REWARDS_DURATION = 1 hours;

    address public immutable trustedSigner;
    address public immutable protocol;
    address public immutable hook;
    address public immutable governorFactory;
    address public immutable stakingFactory;
    address public immutable curveDeployer;
    address public immutable v4Graduator;
    address public immutable metadataRegistry;

    uint256 public immutable graduationUsdThreshold;
    uint256 public immutable minRewardsDuration;
    uint256 public immutable maxRewardsDuration;
    uint48 public immutable votingDelay;
    uint32 public immutable votingPeriod;
    uint256 public immutable proposalThresholdBps;

    mapping(bytes32 => bool) public usedAttestations;
    mapping(address token => address curve) public curveOf;

    event CurveLaunched(address indexed token, address indexed curve, address stockToken, address deployer);

    error ZeroAddress();
    error InvalidRewardsDuration();
    error AttestationAlreadyUsed();
    error InvalidVotingDelay();
    error InvalidVotingPeriod();
    error InvalidGraduationThreshold();
    error InvalidProposalThreshold();

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

        bytes32 attestationId = keccak256(abi.encodePacked(stockToken, price, priceTimestamp));
        if (usedAttestations[attestationId]) revert AttestationAlreadyUsed();
        usedAttestations[attestationId] = true;

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

        TokenMetadataRegistry(metadataRegistry).setMetadataURI(token, metadataURI);

        emit CurveLaunched(token, curve, stockToken, msg.sender);
    }
}
