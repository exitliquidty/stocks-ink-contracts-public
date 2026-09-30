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

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from
    "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StocksGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction
{
    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    uint256 public constant MIN_QUORUM_NUMERATOR = 1;
    uint256 private constant BPS_DENOM = 10_000;

    uint256 public immutable proposalThresholdBps;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    mapping(uint256 timepoint => uint256 burned) private _burnedAtSnapshot;
    mapping(uint256 timepoint => bool recorded) private _burnSnapshotRecorded;

    error VotingDelayTooShort(uint48 votingDelay, uint48 minVotingDelay);
    error VotingPeriodTooShort(uint32 votingPeriod, uint32 minVotingPeriod);
    error QuorumNumeratorTooLow(uint256 quorumNumerator, uint256 minQuorumNumerator);
    error VotingSettingsAreImmutable();
    error ProposalThresholdBpsTooHigh(uint256 proposalThresholdBps);

    constructor(
        string memory name_,
        IVotes token_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThresholdBps_,
        uint256 quorumNumerator_
    )
        Governor(name_)
        GovernorSettings(votingDelay_, votingPeriod_, 0)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
    {
        if (votingDelay_ < MIN_VOTING_DELAY) revert VotingDelayTooShort(votingDelay_, MIN_VOTING_DELAY);
        if (votingPeriod_ < MIN_VOTING_PERIOD) revert VotingPeriodTooShort(votingPeriod_, MIN_VOTING_PERIOD);
        if (quorumNumerator_ < MIN_QUORUM_NUMERATOR) {
            revert QuorumNumeratorTooLow(quorumNumerator_, MIN_QUORUM_NUMERATOR);
        }
        if (proposalThresholdBps_ > BPS_DENOM) revert ProposalThresholdBpsTooHigh(proposalThresholdBps_);
        proposalThresholdBps = proposalThresholdBps_;
    }

    function setVotingDelay(uint48) public pure override {
        revert VotingSettingsAreImmutable();
    }

    function setVotingPeriod(uint32) public pure override {
        revert VotingSettingsAreImmutable();
    }

    function updateQuorumNumerator(uint256) public pure override {
        revert VotingSettingsAreImmutable();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        IERC20 votesToken = IERC20(address(token()));
        uint256 circulatingSupply = votesToken.totalSupply() - votesToken.balanceOf(BURN_ADDRESS);
        return (circulatingSupply * proposalThresholdBps) / BPS_DENOM;
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {

        uint256 burned = _burnSnapshotRecorded[timepoint]
            ? _burnedAtSnapshot[timepoint]
            : IERC20(address(token())).balanceOf(BURN_ADDRESS);
        uint256 circulatingSupply = token().getPastTotalSupply(timepoint) - burned;
        return (circulatingSupply * quorumNumerator(timepoint)) / quorumDenominator();
    }

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256 proposalId) {
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        uint256 timepoint = proposalSnapshot(proposalId);
        if (!_burnSnapshotRecorded[timepoint]) {
            _burnSnapshotRecorded[timepoint] = true;
            _burnedAtSnapshot[timepoint] = IERC20(address(token())).balanceOf(BURN_ADDRESS);
        }
    }
}
