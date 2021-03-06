pragma solidity ^0.4.24;

import "../Court.sol";
import "./lib/TimeHelpersMock.sol";


contract CourtMock is Court, TimeHelpersMock {
    constructor(
        uint64 _termDuration,
        ERC20[2] _tokens,
        IJurorsRegistry _jurorsRegistry,
        IAccounting _accounting,
        ICRVoting _voting,
        ISubscriptions _subscriptions,
        uint256[4] _fees, // _jurorFee, _heartbeatFee, _draftFee, _settleFee
        address _governor,
        uint64 _firstTermStartTime,
        uint256 _jurorMinStake,
        uint64[4] _roundStateDurations,
        uint16[2] _pcts,
        uint64 _appealStepFactor,
        uint32 _maxRegularAppealRounds,
        uint256[5] _subscriptionParams // _periodDuration, _feeAmount, _prePaymentPeriods, _latePaymentPenaltyPct, _governorSharePct
    )
        Court(
            _termDuration,
            _tokens,
            _jurorsRegistry,
            _accounting,
            _voting,
            _subscriptions,
            _fees,
            _governor,
            _firstTermStartTime,
            _jurorMinStake,
            _roundStateDurations,
            _pcts,
            _appealStepFactor,
            _maxRegularAppealRounds,
            _subscriptionParams
        )
        public
    {}

    function collect(address _juror, uint256 _amount) external {
        jurorsRegistry.collectTokens(_juror, _amount, termId);
    }

    function getMaxJurorsPerDraftBatch() public pure returns (uint256) {
        return MAX_JURORS_PER_DRAFT_BATCH;
    }

    function getAdjudicationState(uint256 _disputeId, uint256 _roundId, uint64 _termId) public view returns (AdjudicationState) {
        return _adjudicationStateAtTerm(_disputeId, _roundId, _termId);
    }
}
