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

/// @dev The part of TSTToken the governor needs beyond IVotes.
interface IBurnHistory {
    /// @notice The burn address's balance at the end of `timepoint`.
    /// @param timepoint A timestamp on the token's clock.
    /// @return The burned amount at that time.
    function getPastBurned(uint256 timepoint) external view returns (uint256);
}

/// @title StocksGovernor
/// @notice The governor deployed for each TST at graduation. TST holders vote, and the governor is the only
/// address that may call the three governed functions on that token's staking contract: pause or resume
/// rewards, change the reward period, and liquidate the treasury into a buy-and-burn.
/// @dev OpenZeppelin Governor with simple For/Against/Abstain counting and no timelock. Three things differ
/// from the stock contract. (1) Voting delay, voting period and quorum are fixed at deployment and can never
/// be changed, not even by a proposal. (2) Quorum and the proposal threshold are measured against CIRCULATING
/// supply, total supply minus what sits at the burn address, because TST is burned by transfer and total
/// supply never falls. (3) The burned amount used for a proposal's quorum is the one at its snapshot, read
/// from the token's burn history, so the bar is fixed before voting begins. Staked TST and TST held in the
/// pool carry no votes while they sit there; a staker who wants to vote must unstake and delegate before the
/// proposal's snapshot.
contract StocksGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction
{
    /// @notice Shortest voting delay accepted at deployment.
    uint48 public constant MIN_VOTING_DELAY = 1 hours;
    /// @notice Shortest voting period accepted at deployment.
    uint32 public constant MIN_VOTING_PERIOD = 1 hours;
    /// @notice Smallest quorum percentage accepted at deployment.
    uint256 public constant MIN_QUORUM_NUMERATOR = 1;
    /// @dev Basis-point denominator.
    uint256 private constant BPS_DENOM = 10_000;

    /// @notice Share of circulating supply, in basis points, an account must hold in votes to create a proposal.
    uint256 public immutable proposalThresholdBps;
    /// @notice The address TST is burned to. Its balance is excluded from circulating supply.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The voting delay is below the minimum.
    /// @param votingDelay The value supplied.
    /// @param minVotingDelay The minimum allowed.
    error VotingDelayTooShort(uint48 votingDelay, uint48 minVotingDelay);
    /// @notice The voting period is below the minimum.
    /// @param votingPeriod The value supplied.
    /// @param minVotingPeriod The minimum allowed.
    error VotingPeriodTooShort(uint32 votingPeriod, uint32 minVotingPeriod);
    /// @notice The quorum percentage is below the minimum.
    /// @param quorumNumerator The value supplied.
    /// @param minQuorumNumerator The minimum allowed.
    error QuorumNumeratorTooLow(uint256 quorumNumerator, uint256 minQuorumNumerator);
    /// @notice Voting delay, voting period and quorum cannot be changed after deployment.
    error VotingSettingsAreImmutable();
    /// @notice The proposal threshold exceeds 100%.
    /// @param proposalThresholdBps The value supplied.
    error ProposalThresholdBpsTooHigh(uint256 proposalThresholdBps);

    /// @notice Fixes the governor's settings for good.
    /// @param name_ Governor name; also its EIP-712 domain name, so at most 31 bytes.
    /// @param token_ The vote token (the TST).
    /// @param votingDelay_ Seconds between proposal creation and the vote snapshot.
    /// @param votingPeriod_ Seconds the vote stays open.
    /// @param proposalThresholdBps_ Proposal threshold in basis points of circulating supply.
    /// @param quorumNumerator_ Quorum as a percentage of circulating supply.
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

    /// @notice Always reverts: the voting delay is immutable.
    function setVotingDelay(uint48) public pure override {
        revert VotingSettingsAreImmutable();
    }

    /// @notice Always reverts: the voting period is immutable.
    function setVotingPeriod(uint32) public pure override {
        revert VotingSettingsAreImmutable();
    }

    /// @notice Always reverts: the quorum percentage is immutable.
    function updateQuorumNumerator(uint256) public pure override {
        revert VotingSettingsAreImmutable();
    }

    /// @notice Always reverts: the proposal threshold is immutable (Sherlock #22: the inherited setter changed
    /// nothing but emitted a misleading event).
    function setProposalThreshold(uint256) public pure override {
        revert VotingSettingsAreImmutable();
    }

    /// @notice Votes needed to create a proposal: `proposalThresholdBps` of the current circulating supply.
    /// @dev `proposalThresholdBps` is immutable and the inherited setter reverts.
    /// @return The threshold, in votes.
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        IERC20 votesToken = IERC20(address(token()));
        uint256 circulatingSupply = votesToken.totalSupply() - votesToken.balanceOf(BURN_ADDRESS);
        return (circulatingSupply * proposalThresholdBps) / BPS_DENOM;
    }

    /// @notice Votes (For plus Abstain) a proposal with this snapshot needs in order to pass.
    /// @dev The quorum percentage of circulating supply at the snapshot: total supply minus burned TST, both
    /// read from the token's own history at that timepoint. One fixed figure per proposal, which no vote, burn
    /// or redemption after the snapshot can move (Sherlock review: it used to be pinned by the first vote).
    /// @param timepoint The proposal's snapshot timestamp.
    /// @return The quorum, in votes.
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        uint256 circulatingSupply =
            token().getPastTotalSupply(timepoint) - IBurnHistory(address(token())).getPastBurned(timepoint);
        return (circulatingSupply * quorumNumerator(timepoint)) / quorumDenominator();
    }
}
