pragma solidity ^0.4.24; // TODO: pin solc

// Inspired by: Kleros.sol https://github.com/kleros/kleros @ 7281e69
import "./standards/sumtree/ISumTree.sol";
import "./standards/arbitration/IArbitrable.sol";
import "./standards/erc900/ERC900.sol";
import "./standards/voting/ICRVoting.sol";
import "./standards/voting/ICRVotingOwner.sol";
import "./standards/subscription/ISubscriptions.sol";
import "./standards/subscription/ISubscriptionsOwner.sol";

import { ApproveAndCallFallBack } from "@aragon/apps-shared-minime/contracts/MiniMeToken.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";


// solium-disable function-order
contract Court is ERC900, ApproveAndCallFallBack, ICRVotingOwner, ISubscriptionsOwner {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;

    uint256 internal constant MAX_JURORS_PER_BATCH = 10; // to cap gas used on draft
    uint256 internal constant MAX_REGULAR_APPEAL_ROUNDS = 4; // before the final appeal
    uint256 internal constant FINAL_ROUND_WEIGHT_PRECISION = 1000; // to improve roundings
    uint64 internal constant APPEAL_STEP_FACTOR = 3;
    // TODO: move all other constants up here

    struct Account {
        mapping (address => uint256) balances; // token addr -> balance
        // when deactivating, balance becomes available on next term:
        uint64 deactivationTermId;
        uint256 atStakeTokens;   // maximum amount of juror tokens that the juror could be slashed given their drafts
        uint256 sumTreeId;       // key in the sum tree used for sortition
    }

    struct CourtConfig {
        // Fee structure
        ERC20 feeToken;
        uint256 jurorFee;           // per juror, total round juror fee = jurorFee * jurors drawn
        uint256 heartbeatFee;       // per dispute, total heartbeat fee = heartbeatFee * disputes/appeals in term
        uint256 draftFee;           // per juror, total round draft fee = draftFee * jurors drawn
        uint256 settleFee;          // per juror, total round draft fee = settleFee * jurors drawn
        // Dispute config
        uint64 commitTerms;
        uint64 revealTerms;
        uint64 appealTerms;
        uint64 appealConfirmTerms;
        uint16 penaltyPct;
        uint16 finalRoundReduction; // ‱ of reduction applied for final appeal round (1/10,000)
    }

    struct Term {
        uint64 startTime;       // timestamp when the term started
        uint64 dependingDrafts; // disputes or appeals pegged to this term for randomness
        uint64 courtConfigId;   // fee structure for this term (index in courtConfigs array)
        uint64 randomnessBN;    // block number for entropy
        bytes32 randomness;     // entropy from randomnessBN block hash
    }

    enum AdjudicationState {
        Invalid,
        Commit,
        Reveal,
        Appeal,
        AppealConfirm,
        Ended
    }

    struct JurorState {
        uint64 weight;
        bool rewarded;
    }

    struct AdjudicationRound {
        address[] jurors;
        mapping (address => JurorState) jurorSlotStates;
        Appealer[] appealers;
        uint32 nextJurorIndex;
        uint32 filledSeats;
        uint64 draftTermId;
        uint64 delayTerms;
        uint64 jurorNumber;
        uint64 coherentJurors;
        address triggeredBy;
        bool settledPenalties;
        bool settledAppeals;
        // for regular rounds this contains penalties from non-winning jurors, collected after reveal period
        // for the final round it contains all potential penalties from jurors that voted, as they are collected when jurors commit vote
        uint256 collectedTokens;
    }

    struct Appealer {
        address appealer;
        uint8 forRuling;
        ERC20 depositToken;
        uint256 depositAmount;
    }

    enum DisputeState {
        PreDraft,
        Adjudicating,
        Executed
    }

    struct Dispute {
        IArbitrable subject;
        uint8 possibleRulings;      // number of possible rulings the court can decide on
        uint8 winningRuling;
        DisputeState state;
        AdjudicationRound[] rounds;
    }

    // State constants which are set in the constructor and can't change
    ERC20 internal jurorToken;
    uint64 public termDuration; // recomended value ~1 hour as 256 blocks (available block hash) around an hour to mine
    ICRVoting internal voting;
    ISumTree internal sumTree;
    ISubscriptions internal subscriptions;

    // Global config, configurable by governor
    address internal governor; // TODO: consider using aOS' ACL
    uint256 public jurorMinStake; // TODO: consider adding it to the conf
    CourtConfig[] public courtConfigs;

    // Court state
    uint64 public termId;
    uint64 public configChangeTermId;
    mapping (address => Account) internal accounts;
    mapping (uint256 => address) public jurorsByTreeId;
    mapping (uint64 => Term) public terms;
    Dispute[] public disputes;

    string internal constant ERROR_INVALID_ADDR = "COURT_INVALID_ADDR";
    string internal constant ERROR_DEPOSIT_FAILED = "COURT_DEPOSIT_FAILED";
    string internal constant ERROR_ZERO_TRANSFER = "COURT_ZERO_TRANSFER";
    string internal constant ERROR_TOO_MANY_TRANSITIONS = "COURT_TOO_MANY_TRANSITIONS";
    string internal constant ERROR_UNFINISHED_TERM = "COURT_UNFINISHED_TERM";
    string internal constant ERROR_PAST_TERM_FEE_CHANGE = "COURT_PAST_TERM_FEE_CHANGE";
    string internal constant ERROR_INVALID_ACCOUNT_STATE = "COURT_INVALID_ACCOUNT_STATE";
    string internal constant ERROR_TOKENS_BELOW_MIN_STAKE = "COURT_TOKENS_BELOW_MIN_STAKE";
    string internal constant ERROR_JUROR_TOKENS_AT_STAKE = "COURT_JUROR_TOKENS_AT_STAKE";
    string internal constant ERROR_BALANCE_TOO_LOW = "COURT_BALANCE_TOO_LOW";
    string internal constant ERROR_OVERFLOW = "COURT_OVERFLOW";
    string internal constant ERROR_TOKEN_TRANSFER_FAILED = "COURT_TOKEN_TRANSFER_FAILED";
    string internal constant ERROR_ROUND_ALREADY_DRAFTED = "COURT_ROUND_ALREADY_DRAFTED";
    string internal constant ERROR_NOT_DRAFT_TERM = "COURT_NOT_DRAFT_TERM";
    string internal constant ERROR_WRONG_TERM = "COURT_WRONG_TERM";
    string internal constant ERROR_TERM_RANDOMNESS_UNAVAIL = "COURT_TERM_RANDOMNESS_UNAVAIL";
    string internal constant ERROR_SORTITION_LENGTHS_MISMATCH = "COURT_SORTITION_LENGTHS_MISMATCH";
    string internal constant ERROR_INVALID_DISPUTE_STATE = "COURT_INVALID_DISPUTE_STATE";
    string internal constant ERROR_INVALID_ADJUDICATION_ROUND = "COURT_INVALID_ADJUDICATION_ROUND";
    string internal constant ERROR_INVALID_ADJUDICATION_STATE = "COURT_INVALID_ADJUDICATION_STATE";
    string internal constant ERROR_INVALID_JUROR = "COURT_INVALID_JUROR";
    // TODO: string internal constant ERROR_INVALID_DISPUTE_CREATOR = "COURT_INVALID_DISPUTE_CREATOR";
    string internal constant ERROR_SUBSCRIPTION_NOT_PAID = "COURT_SUBSCRIPTION_NOT_PAID";
    string internal constant ERROR_INVALID_RULING_OPTIONS = "COURT_INVALID_RULING_OPTIONS";
    string internal constant ERROR_CONFIG_PERIOD_ZERO_TERMS = "COURT_CONFIG_PERIOD_ZERO_TERMS";
    string internal constant ERROR_PREV_ROUND_NOT_SETTLED = "COURT_PREV_ROUND_NOT_SETTLED";
    string internal constant ERROR_ROUND_ALREADY_SETTLED = "COURT_ROUND_ALREADY_SETTLED";
    string internal constant ERROR_ROUND_NOT_SETTLED = "COURT_ROUND_NOT_SETTLED";
    string internal constant ERROR_JUROR_ALREADY_REWARDED = "COURT_JUROR_ALREADY_REWARDED";
    string internal constant ERROR_JUROR_NOT_COHERENT = "COURT_JUROR_NOT_COHERENT";

    uint64 internal constant ZERO_TERM_ID = 0; // invalid term that doesn't accept disputes
    uint8 public constant APPEAL_COLLATERAL_FACTOR = 3; // multiple of juror fees required to appeal a preliminary ruling
    uint8 public constant APPEAL_CONFIRMATION_COLLATERAL_FACTOR = 2; // multiple of juror fees required to confirm appeal
    uint64 internal constant MODIFIER_ALLOWED_TERM_TRANSITIONS = 1;
    //bytes4 private constant ARBITRABLE_INTERFACE_ID = 0xabababab; // TODO: interface id
    uint256 internal constant PCT_BASE = 10000; // ‱
    uint8 internal constant MIN_RULING_OPTIONS = 2;
    uint8 internal constant MAX_RULING_OPTIONS = MIN_RULING_OPTIONS;
    address internal constant BURN_ACCOUNT = 0xdead;
    uint256 internal constant MAX_UINT16 = uint16(-1);
    uint256 internal constant MAX_UINT32 = uint32(-1);
    uint64 internal constant MAX_UINT64 = uint64(-1);

    event NewTerm(uint64 termId, address indexed heartbeatSender);
    event NewCourtConfig(uint64 fromTermId, uint64 courtConfigId);
    event TokenBalanceChange(address indexed token, address indexed owner, uint256 amount, bool positive);
    event JurorActivated(address indexed juror, uint64 fromTermId);
    event JurorDeactivated(address indexed juror, uint64 lastTermId);
    event JurorDrafted(uint256 indexed disputeId, address juror);
    event DisputeStateChanged(uint256 indexed disputeId, DisputeState indexed state);
    event NewDispute(uint256 indexed disputeId, address indexed subject, uint64 indexed draftTermId, uint64 jurorNumber);
    event TokenWithdrawal(address indexed token, address indexed account, uint256 amount);
    event RulingAppealed(uint256 indexed disputeId, uint256 indexed roundId, uint8 forRuling);
    event RulingAppealConfirmed(uint256 indexed disputeId, uint256 indexed roundId, uint64 indexed draftTermId, uint256 jurorNumber);
    event RulingExecuted(uint256 indexed disputeId, uint8 indexed ruling);
    event RoundSlashingSettled(uint256 indexed disputeId, uint256 indexed roundId, uint256 collectedTokens);
    event RewardSettled(uint256 indexed disputeId, uint256 indexed roundId, address juror);

    modifier only(address _addr) {
        require(msg.sender == _addr, ERROR_INVALID_ADDR);
        _;
    }

    modifier ensureTerm {
        uint64 requiredTransitions = neededTermTransitions();
        require(requiredTransitions <= MODIFIER_ALLOWED_TERM_TRANSITIONS, ERROR_TOO_MANY_TRANSITIONS);

        if (requiredTransitions > 0) {
            heartbeat(requiredTransitions);
        }

        _;
    }

    /**
     * @param _termDuration Duration in seconds per term (recommended 1 hour)
     * @param _jurorToken The address of the juror work token contract.
     * @param _feeToken The address of the token contract that is used to pay for fees.
     * @param _voting The address of the Commit Reveal Voting contract.
     * @param _sumTree The address of the contract storing de Sum Tree for sortitions.
     * @param _fees Array containing:
     *        _jurorFee The amount of _feeToken that is paid per juror per dispute
     *        _heartbeatFee The amount of _feeToken per dispute to cover maintenance costs.
     *        _draftFee The amount of _feeToken per juror to cover the drafting cost.
     *        _settleFee The amount of _feeToken per juror to cover round settlement cost.
     * @param _governor Address of the governor contract.
     * @param _firstTermStartTime Timestamp in seconds when the court will open (to give time for juror onboarding)
     * @param _jurorMinStake Minimum amount of juror tokens that can be activated
     * @param _roundStateDurations Number of terms that the different states a dispute round last
     * @param _penaltyPct ‱ of jurorMinStake that can be slashed (1/10,000)
     * @param _subscriptionParams Array containing params for Subscriptions:
     *        _periodDuration Length of Subscription periods
     *        _feeAmount Amount of periodic fees
     *        _prePaymentPeriods Max number of payments that can be done in advance
     *        _latePaymentPenaltyPct Penalty for not paying on time
     *        _governorSharePct Share of paid fees that goes to governor
     */
    constructor(
        uint64 _termDuration,
        ERC20 _jurorToken,
        ERC20 _feeToken,
        ICRVoting _voting,
        ISumTree _sumTree,
        ISubscriptions _subscriptions,
        uint256[4] _fees, // _jurorFee, _heartbeatFee, _draftFee, _settleFee
        address _governor,
        uint64 _firstTermStartTime,
        uint256 _jurorMinStake,
        uint64[4] _roundStateDurations,
        uint16 _penaltyPct,
        uint16 _finalRoundReduction,
        uint256[5] _subscriptionParams // _periodDuration, _feeAmount, _prePaymentPeriods, _latePaymentPenaltyPct, _governorSharePct
    ) public {
        termDuration = _termDuration;
        jurorToken = _jurorToken;
        voting = _voting;
        sumTree = _sumTree;
        subscriptions = _subscriptions;
        jurorMinStake = _jurorMinStake;
        governor = _governor;

        voting.setOwner(ICRVotingOwner(this));
        sumTree.init(address(this));
        _initSubscriptions(_feeToken, _subscriptionParams);

        courtConfigs.length = 1; // leave index 0 empty
        _setCourtConfig(
            ZERO_TERM_ID,
            _feeToken,
            _fees,
            _roundStateDurations,
            _penaltyPct,
            _finalRoundReduction
        );
        terms[ZERO_TERM_ID].startTime = _firstTermStartTime - _termDuration;
    }

    /**
     * @notice Send a heartbeat to the Court to transition up to `_termTransitions`
     */
    function heartbeat(uint64 _termTransitions) public {
        require(canTransitionTerm(), ERROR_UNFINISHED_TERM);

        Term storage prevTerm = terms[termId];
        termId += 1;
        Term storage nextTerm = terms[termId];
        address heartbeatSender = msg.sender;

        // Set fee structure for term
        if (nextTerm.courtConfigId == 0) {
            nextTerm.courtConfigId = prevTerm.courtConfigId;
        } else {
            configChangeTermId = ZERO_TERM_ID; // fee structure changed in this term
        }

        // TODO: skip period if you can

        // Set the start time of the term (ensures equally long terms, regardless of heartbeats)
        nextTerm.startTime = prevTerm.startTime + termDuration;
        nextTerm.randomnessBN = _blockNumber() + 1; // randomness source set to next block (content unknown when heartbeat happens)

        CourtConfig storage courtConfig = courtConfigs[nextTerm.courtConfigId];
        uint256 totalFee = nextTerm.dependingDrafts * courtConfig.heartbeatFee;

        if (totalFee > 0) {
            _assignTokens(courtConfig.feeToken, heartbeatSender, totalFee);
        }

        emit NewTerm(termId, heartbeatSender);

        if (_termTransitions > 1 && canTransitionTerm()) {
            heartbeat(_termTransitions - 1);
        }
    }

    /**
     * @notice Stake `@tokenAmount(self.jurorToken(), _amount)` to the Court
     */
    function stake(uint256 _amount, bytes) external {
        _stake(msg.sender, msg.sender, _amount);
    }

    /**
     * @notice Stake `@tokenAmount(self.jurorToken(), _amount)` for `_to` to the Court
     */
    function stakeFor(address _to, uint256 _amount, bytes) external {
        _stake(msg.sender, _to, _amount);
    }

    /**
     * @notice Unstake `@tokenAmount(self.jurorToken(), _amount)` for `_to` from the Court
     */
    function unstake(uint256 _amount, bytes) external {
        return withdraw(jurorToken, _amount); // withdraw() ensures the correct term
    }

    /**
     * @notice Withdraw `@tokenAmount(_token, _amount)` from the Court
     */
    function withdraw(ERC20 _token, uint256 _amount) public ensureTerm {
        require(_amount > 0, ERROR_ZERO_TRANSFER);

        address addr = msg.sender;
        Account storage account = accounts[addr];
        uint256 balance = account.balances[_token];
        require(balance >= _amount, ERROR_BALANCE_TOO_LOW);

        if (_token == jurorToken) {
            // Make sure deactivation has finished before withdrawing
            require(account.deactivationTermId <= termId, ERROR_INVALID_ACCOUNT_STATE);
            require(_amount <= unlockedBalanceOf(addr), ERROR_JUROR_TOKENS_AT_STAKE);

            emit Unstaked(addr, _amount, totalStakedFor(addr), "");
        }

        _removeTokens(_token, addr, _amount);
        require(_token.safeTransfer(addr, _amount), ERROR_TOKEN_TRANSFER_FAILED);

        emit TokenWithdrawal(_token, addr, _amount);
    }

    /**
     * @notice Become an active juror on next term
     */
    function activate() external ensureTerm {
        address jurorAddress = msg.sender;
        Account storage account = accounts[jurorAddress];
        uint256 balance = account.balances[jurorToken];

        require(account.deactivationTermId <= termId, ERROR_INVALID_ACCOUNT_STATE);
        require(balance >= jurorMinStake, ERROR_TOKENS_BELOW_MIN_STAKE);

        uint256 sumTreeId = account.sumTreeId;
        if (sumTreeId == 0) {
            sumTreeId = sumTree.insert(termId, 0); // Always > 0 (as constructor inserts the first item)
            account.sumTreeId = sumTreeId;
            jurorsByTreeId[sumTreeId] = jurorAddress;
        }

        uint64 fromTermId = termId + 1;
        sumTree.update(sumTreeId, fromTermId, balance, true);

        account.deactivationTermId = MAX_UINT64;
        account.balances[jurorToken] = 0; // tokens are in the tree (present or future)

        emit JurorActivated(jurorAddress, fromTermId);
    }

    // TODO: Activate more tokens as a juror

    /**
     * @notice Stop being an active juror on next term
     */
    function deactivate() external ensureTerm {
        address jurorAddress = msg.sender;
        Account storage account = accounts[jurorAddress];

        require(account.deactivationTermId == MAX_UINT64, ERROR_INVALID_ACCOUNT_STATE);

        // Always account.sumTreeId > 0, as juror has activated before
        uint256 treeBalance = sumTree.getItem(account.sumTreeId);
        account.balances[jurorToken] += treeBalance;

        uint64 lastTermId = termId + 1;
        account.deactivationTermId = lastTermId;

        sumTree.set(account.sumTreeId, lastTermId, 0);

        emit JurorDeactivated(jurorAddress, lastTermId);
    }

    /**
     * @notice Create a dispute over `_subject` with `_possibleRulings` possible rulings, drafting `_jurorNumber` jurors in term `_draftTermId`
     */
    function createDispute(IArbitrable _subject, uint8 _possibleRulings, uint64 _jurorNumber, uint64 _draftTermId)
        external
        ensureTerm
        returns (uint256)
    {
        // TODO: Limit the min amount of terms before drafting (to allow for evidence submission)
        // TODO: Limit the max amount of terms into the future that a dispute can be drafted
        // TODO: Limit the max number of initial jurors
        // TODO: ERC165 check that _subject conforms to the Arbitrable interface

        // TODO: require(address(_subject) == msg.sender, ERROR_INVALID_DISPUTE_CREATOR);
        require(subscriptions.isUpToDate(address(_subject)), ERROR_SUBSCRIPTION_NOT_PAID);
        require(_possibleRulings >= MIN_RULING_OPTIONS && _possibleRulings <= MAX_RULING_OPTIONS, ERROR_INVALID_RULING_OPTIONS);

        uint256 disputeId = disputes.length;
        disputes.length = disputeId + 1;

        Dispute storage dispute = disputes[disputeId];
        dispute.subject = _subject;
        dispute.possibleRulings = _possibleRulings;

        (ERC20 feeToken, uint256 feeAmount) = feeForRegularRound(_draftTermId, _jurorNumber);
        // pay round fees
        _payGeneric(feeToken, feeAmount);
        _createRound(disputeId, DisputeState.PreDraft, _draftTermId, _jurorNumber, 0);

        emit NewDispute(disputeId, _subject, _draftTermId, _jurorNumber);

        return disputeId;
    }

    /**
     * @notice Draft jurors for the next round of dispute #`_disputeId`
     * @dev Allows for batches, so only up to MAX_JURORS_PER_BATCH will be drafted in each call
     */
    function draftAdjudicationRound(uint256 _disputeId)
        public
        ensureTerm
    {
        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage round = dispute.rounds[dispute.rounds.length - 1];
        // TODO: stack too deep: uint64 draftTermId = round.draftTermId;
        // We keep the inintial term for config, but we update it for randomness seed,
        // as otherwise it would be easier for some juror to add tokens to the tree (or remove them)
        // in order to change the result of the next draft batch
        Term storage draftTerm = terms[termId];
        CourtConfig storage config = courtConfigs[terms[round.draftTermId].courtConfigId]; // safe to use directly as it is current or past term

        require(dispute.state == DisputeState.PreDraft, ERROR_ROUND_ALREADY_DRAFTED);
        require(round.draftTermId <= termId, ERROR_NOT_DRAFT_TERM);
        // Ensure that term has randomness:
        _ensureTermRandomness(draftTerm);

        // TODO: stack too deep
        //uint64 jurorNumber = round.jurorNumber;
        //uint256 nextJurorIndex = round.nextJurorIndex;
        if (round.jurors.length == 0) {
            round.jurors.length = round.jurorNumber;
        }

        uint256 jurorsRequested = round.jurorNumber - round.filledSeats;
        if (jurorsRequested > MAX_JURORS_PER_BATCH) {
            jurorsRequested = MAX_JURORS_PER_BATCH;
        }

        // to add "randomness" to sortition call in order to avoid getting stuck by
        // getting the same overleveraged juror over and over
        uint256 sortitionIteration = 0;

        while (jurorsRequested > 0) {
            (
                uint256[] memory jurorKeys,
                uint256[] memory stakes
            ) = _treeSearch(
                draftTerm.randomness,
                _disputeId,
                round.filledSeats,
                jurorsRequested,
                round.jurorNumber,
                sortitionIteration
            );
            require(jurorKeys.length == stakes.length, ERROR_SORTITION_LENGTHS_MISMATCH);
            require(jurorKeys.length == jurorsRequested, ERROR_SORTITION_LENGTHS_MISMATCH);

            for (uint256 i = 0; i < jurorKeys.length; i++) {
                address juror = jurorsByTreeId[jurorKeys[i]];

                // Account storage jurorAccount = accounts[juror]; // Hitting stack too deep
                uint256 newAtStake = accounts[juror].atStakeTokens + _pct4(jurorMinStake, config.penaltyPct); // maxPenalty
                // Only select a juror if their stake is greater than or equal than the amount of tokens that they can lose, otherwise skip it
                if (stakes[i] >= newAtStake) {
                    accounts[juror].atStakeTokens = newAtStake;
                    // check repeated juror, we assume jurors come ordered from tree search
                    if (round.nextJurorIndex > 0 && round.jurors[round.nextJurorIndex - 1] == juror) {
                        round.jurors.length--;
                    } else {
                        round.jurors[round.nextJurorIndex] = juror;
                        round.nextJurorIndex++;
                    }
                    round.jurorSlotStates[juror].weight++;
                    round.filledSeats++;

                    emit JurorDrafted(_disputeId, juror);

                    jurorsRequested--;
                }
            }
            sortitionIteration++;
        }

        _assignTokens(config.feeToken, msg.sender, config.draftFee * round.jurorNumber);

        // drafting is over
        if (round.filledSeats == round.jurorNumber) {
            if (round.draftTermId < termId) {
                round.delayTerms = termId - round.draftTermId;
            }
            dispute.state = DisputeState.Adjudicating;
            emit DisputeStateChanged(_disputeId, dispute.state);
        }
    }

    function _endTermForAdjudicationRound(AdjudicationRound storage round) internal view returns (uint64) {
        uint64 draftTermId = round.draftTermId;
        uint64 configId = terms[draftTermId].courtConfigId;
        CourtConfig storage config = courtConfigs[uint256(configId)];

        // TODO: delayed??
        return draftTermId + config.commitTerms + config.revealTerms + config.appealTerms + config.appealConfirmTerms;
    }

    /**
     * @notice Appeal round #`_roundId` ruling in dispute #`_disputeId`
     */
    function appealRuling(uint256 _disputeId, uint256 _roundId, uint8 _forRuling) external ensureTerm {
        // TODO: require(_forRuling > uint8(Ruling.RefusedRuling));

        _checkAdjudicationState(_disputeId, _roundId, AdjudicationState.Appeal);

        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage currentRound = dispute.rounds[_roundId];

        uint64 appealJurorNumber;
        uint64 appealDraftTermId = _endTermForAdjudicationRound(currentRound);

        uint8 currentRuling = getWinningRuling(_disputeId);
        require(currentRuling != _forRuling);
        require(currentRound.appealers.length == 0); // This ruling hasn't been appealed yet

        (,, ERC20 feeToken, uint256 feeAmount) = _getAppealDetails(currentRound, _roundId);

        // pay round collateral
        uint256 appealDeposit = feeAmount * APPEAL_COLLATERAL_FACTOR;
        _payGeneric(feeToken, appealDeposit);
        currentRound.appealers.push(Appealer(msg.sender, _forRuling, feeToken, appealDeposit));

        emit RulingAppealed(_disputeId, _roundId, _forRuling);
    }

    /**
     * @notice Confirm appeal for #`_roundId` ruling in dispute #`_disputeId`
     */
    function appealConfirm(uint256 _disputeId, uint256 _roundId, uint8 _forRuling) external ensureTerm {
        // TODO: require(_forRuling > uint8(Ruling.RefusedRuling));

        _checkAdjudicationState(_disputeId, _roundId, AdjudicationState.AppealConfirm);

        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage currentRound = dispute.rounds[_roundId];

        require(currentRound.appealers.length == 1); // The ruling was appealed and not confirmed
        require(currentRound.appealers[0].forRuling != _forRuling); // Appealing for a different ruling

        (uint64 appealDraftTermId, uint64 appealJurorNumber, ERC20 feeToken, uint256 feeAmount) = _getAppealDetails(currentRound, _roundId);

        // create round
        uint256 roundId;
        if (_roundId == MAX_REGULAR_APPEAL_ROUNDS - 1) { // final round, roundId starts at 0
            // filledSeats is not used for final round, so we set it to zero
            roundId = _createRound(_disputeId, DisputeState.Adjudicating, appealDraftTermId, appealJurorNumber, 0);
        } else { // no need for more checks, as final appeal won't ever be in Appealable state, so it would never reach here (first check would fail)
            roundId = _createRound(_disputeId, DisputeState.PreDraft, appealDraftTermId, appealJurorNumber, 0);
        }

        // pay round fees
        _payGeneric(feeToken, feeAmount);
        // pay round collateral
        uint256 appealDeposit = feeAmount * APPEAL_CONFIRMATION_COLLATERAL_FACTOR;
        _payGeneric(feeToken, appealDeposit);

        currentRound.appealers.push(Appealer(msg.sender, _forRuling, feeToken, appealDeposit));

        emit RulingAppealConfirmed(_disputeId, roundId, appealDraftTermId, appealJurorNumber);
    }

    function _getAppealDetails(
        AdjudicationRound storage _currentRound,
        uint256 _roundId
    )
        internal
        returns (uint64 appealDraftTermId, uint64 appealJurorNumber, ERC20 feeToken, uint256 feeAmount)
    {
        appealDraftTermId = _endTermForAdjudicationRound(_currentRound);
        if (_roundId == MAX_REGULAR_APPEAL_ROUNDS - 1) { // final round, roundId starts at 0
            // number of jurors will be the number of times the minimum stake is hold in the tree, multiplied by a precision factor for division roundings
            appealJurorNumber = _getFinalAdjudicationRoundJurorNumber();
            (feeToken, feeAmount) = feeForFinalRound(appealDraftTermId, appealJurorNumber);
        } else { // no need for more checks, as final appeal won't ever be in Appealable state, so it would never reach here (first check would fail)
            appealJurorNumber = _getRegularAdjudicationRoundJurorNumber(_currentRound.jurorNumber);
            (feeToken, feeAmount) = feeForRegularRound(appealDraftTermId, appealJurorNumber);
        }
    }

    /**
     * @notice Settle appeal deposits for #`_roundId` ruling in dispute #`_disputeId`
     */
    function settleAppealDeposit(uint256 _disputeId, uint256 _roundId) external ensureTerm {
        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage round = dispute.rounds[_roundId];
        uint256 appealsLength = round.appealers.length;

        require(round.settledPenalties);
        require(!round.settledAppeals);
        require(appealsLength > 0);

        if (appealsLength == 1) {
            // return entire deposit to appealer
            Appealer storage appealer = round.appealers[0];
            _assignTokens(appealer.depositToken, appealer.appealer, appealer.depositAmount);
        } else {
            Appealer storage appealer1 = round.appealers[0];
            Appealer storage appealer2 = round.appealers[1];

            uint8 winningRuling = getWinningRuling(_disputeId);
            uint256 totalDepositMultiplier = APPEAL_COLLATERAL_FACTOR + APPEAL_CONFIRMATION_COLLATERAL_FACTOR;
            uint256 totalDeposit = appealer1.depositAmount + appealer2.depositAmount;
            // deposits are a multiple of juror fees, given that the round was initiated
            uint256 jurorFees = totalDeposit / totalDepositMultiplier;

            if (appealer1.forRuling == winningRuling) {
                _assignTokens(appealer1.depositToken, appealer1.appealer, totalDeposit - jurorFees);
            } else if (appealer2.forRuling == winningRuling) {
                _assignTokens(appealer1.depositToken, appealer2.appealer, totalDeposit - jurorFees);
            } else {
                _assignTokens(appealer1.depositToken, appealer1.appealer, appealer1.depositAmount - jurorFees / 2);
                _assignTokens(appealer1.depositToken, appealer2.appealer, appealer2.depositAmount - jurorFees / 2);
            }
        }
    }

    /**
     * @notice Execute the final ruling of dispute #`_disputeId`
     */
    function executeRuling(uint256 _disputeId, uint256 _roundId) external ensureTerm {
        // checks that dispute is in adjudication state
        _checkAdjudicationState(_disputeId, _roundId, AdjudicationState.Ended);

        Dispute storage dispute = disputes[_disputeId];
        dispute.state = DisputeState.Executed;

        uint8 winningRuling = voting.getWinningRuling(_getVoteId(_disputeId, _roundId));
        dispute.winningRuling = winningRuling;

        dispute.subject.rule(_disputeId, uint256(winningRuling));

        emit RulingExecuted(_disputeId, winningRuling);
    }

    /**
     * @notice Execute the final ruling of dispute #`_disputeId`
     * @dev Just executes penalties, jurors must manually claim their rewards
     */
    function settleRoundSlashing(uint256 _disputeId, uint256 _roundId) external ensureTerm {
        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage round = dispute.rounds[_roundId];
        CourtConfig storage config = courtConfigs[terms[round.draftTermId].courtConfigId]; // safe to use directly as it is the current term

        // Enforce that rounds are settled in order to avoid one round without incentive to settle
        // even if there is a settleFee, it may not be big enough and all jurors in the round are going to be slashed
        require(_roundId == 0 || dispute.rounds[_roundId - 1].settledPenalties, ERROR_PREV_ROUND_NOT_SETTLED);
        require(!round.settledPenalties, ERROR_ROUND_ALREADY_SETTLED);

        uint256 voteId = _getVoteId(_disputeId, _roundId);
        uint8 winningRuling;
        if (dispute.state != DisputeState.Executed) {
            _checkAdjudicationState(_disputeId, dispute.rounds.length - 1, AdjudicationState.Ended);
            winningRuling = voting.getWinningRuling(voteId);
            dispute.winningRuling = winningRuling;
        } else {
            // winningRuling was already set on `executeRuling`
            winningRuling = dispute.winningRuling;
        }

        uint256 coherentJurors = voting.getRulingVotes(voteId, winningRuling);
        round.coherentJurors = uint64(coherentJurors);

        uint256 collectedTokens;
        if (_roundId < MAX_REGULAR_APPEAL_ROUNDS) {
            collectedTokens = _settleRegularRoundSlashing(round, voteId, config.penaltyPct, winningRuling);
            round.collectedTokens = collectedTokens;
            _assignTokens(config.feeToken, msg.sender, config.settleFee * round.jurorNumber);
        } else { // final round
            // this was accounted for on juror's vote commit
            collectedTokens = round.collectedTokens;
            // there's no settleFee in this round
        }

        round.settledPenalties = true;

        // No juror was coherent in the round
        if (coherentJurors == 0) {
            // refund fees and burn ANJ
            uint256 jurorFee = config.jurorFee * round.jurorNumber;
            if (_roundId == MAX_REGULAR_APPEAL_ROUNDS) {
                // number of jurors will in the final round is multiplied by a precision factor for division roundings, so we need to undo it here
                // besides, we account for the final round discount in fees
                jurorFee = _pct4(jurorFee / FINAL_ROUND_WEIGHT_PRECISION, config.finalRoundReduction);
            }
            _assignTokens(config.feeToken, round.triggeredBy, jurorFee);
            _assignTokens(jurorToken, BURN_ACCOUNT, collectedTokens);
        }

        emit RoundSlashingSettled(_disputeId, _roundId, collectedTokens);
    }

    function _settleRegularRoundSlashing(
        AdjudicationRound storage _round,
        uint256 _voteId,
        uint16 _penaltyPct,
        uint8 _winningRuling
    )
        internal
        returns (uint256 collectedTokens)
    {
        uint256 penalty = _pct4(jurorMinStake, _penaltyPct);

        uint256 votesLength = _round.jurors.length;
        uint64 slashingUpdateTermId = termId + 1;

        // should we batch this too?? OOG?
        for (uint256 i = 0; i < votesLength; i++) {
            address juror = _round.jurors[i];
            uint256 weightedPenalty = penalty * _round.jurorSlotStates[juror].weight;
            Account storage account = accounts[juror];
            account.atStakeTokens -= weightedPenalty;

            uint8 jurorRuling = voting.getCastVote(_voteId, juror);
            // If the juror didn't vote for the final winning ruling
            if (jurorRuling != _winningRuling) {
                collectedTokens += weightedPenalty;

                if (account.deactivationTermId <= slashingUpdateTermId) {
                    // Slash from balance if the account already deactivated
                    _removeTokens(jurorToken, juror, weightedPenalty);
                } else {
                    // account.sumTreeId always > 0: as the juror has activated (and gots its sumTreeId)
                    sumTree.update(account.sumTreeId, slashingUpdateTermId, weightedPenalty, false);
                }
            }
        }
    }

    /**
     * @notice Claim reward for round #`_roundId` of dispute #`_disputeId` for juror `_juror`
     */
    function settleReward(uint256 _disputeId, uint256 _roundId, address _juror) external ensureTerm {
        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage round = dispute.rounds[_roundId];
        JurorState storage jurorState = round.jurorSlotStates[_juror];

        require(round.settledPenalties, ERROR_ROUND_NOT_SETTLED);
        require(jurorState.weight > 0, ERROR_INVALID_JUROR);
        require(!jurorState.rewarded, ERROR_JUROR_ALREADY_REWARDED);

        jurorState.rewarded = true;

        uint256 voteId = _getVoteId(_disputeId, _roundId);
        uint256 coherentJurors = round.coherentJurors;
        uint8 jurorRuling = voting.getCastVote(voteId, _juror);

        require(jurorRuling == dispute.winningRuling, ERROR_JUROR_NOT_COHERENT);

        uint256 collectedTokens = round.collectedTokens;

        if (collectedTokens > 0) {
            _assignTokens(jurorToken, _juror, jurorState.weight * collectedTokens / coherentJurors);
        }

        CourtConfig storage config = courtConfigs[terms[round.draftTermId].courtConfigId]; // safe to use directly as it is a past term
        uint256 jurorFee = config.jurorFee * jurorState.weight * round.jurorNumber / coherentJurors;
        if (_roundId == MAX_REGULAR_APPEAL_ROUNDS) {
            // number of jurors will in the final round is multiplied by a precision factor for division roundings, so we need to undo it here
            // besides, we account for the final round discount in fees
            jurorFee = _pct4(jurorFee / FINAL_ROUND_WEIGHT_PRECISION, config.finalRoundReduction);
        }
        _assignTokens(config.feeToken, _juror, jurorFee);

        emit RewardSettled(_disputeId, _roundId, _juror);
    }

    function canTransitionTerm() public view returns (bool) {
        return neededTermTransitions() >= 1;
    }

    function neededTermTransitions() public view returns (uint64) {
        return (_time() - terms[termId].startTime) / termDuration;
    }

    /**
     * @dev This function only works for regular rounds. For final round `filledSeats` is always zero,
     *      so the result will always be false. There is no drafting in final round.
     */
    function areAllJurorsDrafted(uint256 _disputeId, uint256 _roundId) public view returns (bool) {
        AdjudicationRound storage round = disputes[_disputeId].rounds[_roundId];
        return round.filledSeats == round.jurorNumber;
    }

    /**
     * @dev Assumes term is up to date. This function only works for regular rounds.
     */
    function feeForRegularRound(
        uint64 _draftTermId,
        uint64 _jurorNumber
    )
        public
        view
        returns (ERC20 feeToken, uint256 feeAmount)
    {
        CourtConfig storage fees = _courtConfigForTerm(_draftTermId);

        feeToken = fees.feeToken;
        feeAmount = fees.heartbeatFee + _jurorNumber * (fees.jurorFee + fees.draftFee + fees.settleFee);
    }

    function feeForFinalRound(
        uint64 _draftTermId,
        uint64 _jurorNumber
    )
        public
        view
        returns (ERC20 feeToken, uint256 feeAmount)
    {
        CourtConfig storage config = _courtConfigForTerm(_draftTermId);
        feeToken = config.feeToken;
        // number of jurors is the number of times the minimum stake is hold in the tree, multiplied by a precision factor for division roundings
        // besides, apply final round discount
        feeAmount = config.heartbeatFee +
            _pct4(_jurorNumber * config.jurorFee / FINAL_ROUND_WEIGHT_PRECISION, config.finalRoundReduction);
    }

    /**
     * @dev Callback of approveAndCall, allows staking directly with a transaction to the token contract.
     * @param _from The address making the transfer.
     * @param _amount Amount of tokens to transfer to Kleros (in basic units).
     * @param _token Token address
     */
    function receiveApproval(address _from, uint256 _amount, address _token, bytes)
        public
        only(_token)
    {
        if (_token == address(jurorToken)) {
            _stake(_from, _from, _amount);
            // TODO: Activate depending on data
        }
    }

    function totalStaked() external view returns (uint256) {
        return jurorToken.balanceOf(this);
    }

    function token() external view returns (address) {
        return address(jurorToken);
    }

    function supportsHistory() external pure returns (bool) {
        return false;
    }

    function totalStakedFor(address _addr) public view returns (uint256) {
        Account storage account = accounts[_addr];
        uint256 sumTreeId = account.sumTreeId;
        uint256 activeTokens = sumTreeId > 0 ? sumTree.getItem(sumTreeId) : 0;

        return account.balances[jurorToken] + activeTokens;
    }

    /**
     * @dev Assumes that it is always called ensuring the term
     */
    function unlockedBalanceOf(address _addr) public view returns (uint256) {
        Account storage account = accounts[_addr];
        return account.balances[jurorToken].sub(account.atStakeTokens);
    }

    function getDispute(uint256 _disputeId) external view returns (address subject, uint8 possibleRulings, uint8 winningRuling, DisputeState state) {
        Dispute storage dispute = disputes[_disputeId];
        return (dispute.subject, dispute.possibleRulings, dispute.winningRuling, dispute.state);
    }

    function getAdjudicationRound(uint256 _disputeId, uint256 _roundId)
        external
        view
        returns (uint64 draftTerm, uint64 jurorNumber, address triggeredBy, bool settledPenalties, uint256 collectedTokens)
    {
        AdjudicationRound storage round = disputes[_disputeId].rounds[_roundId];

        return (round.draftTermId, round.jurorNumber, round.triggeredBy, round.settledPenalties, round.collectedTokens);
    }

    function getAccount(address _accountAddress)
        external
        view
        returns (uint256 atStakeTokens, uint256 sumTreeId)
    {
        Account storage account = accounts[_accountAddress];
        return (account.atStakeTokens, account.sumTreeId);
    }

    // Voting interface fns

    /**
     * @notice Check that adjudication state is correct
     * @return `_voter`'s weight
     */
    function canCommit(uint256 _voteId, address _voter) external ensureTerm only(voting) returns (uint256 weight) {
        (uint256 disputeId, uint256 roundId) = _decodeVoteId(_voteId);

        // for the final round
        if (roundId == MAX_REGULAR_APPEAL_ROUNDS) {
            return _canCommitFinalRound(disputeId, roundId, _voter);
        }

        weight = _canPerformVotingAction(disputeId, roundId, _voter, AdjudicationState.Commit);
    }

    function _canCommitFinalRound(uint256 _disputeId, uint256 _roundId, address _voter) internal returns (uint256 weight) {
        _checkAdjudicationState(_disputeId, _roundId, AdjudicationState.Commit);

        // weight is the number of times the minimum stake the juror has, multiplied by a precision factor for division roundings
        weight = FINAL_ROUND_WEIGHT_PRECISION *
            sumTree.getItemPast(accounts[_voter].sumTreeId, disputes[_disputeId].rounds[_roundId].draftTermId) /
            jurorMinStake;

        // as it's the final round, lock tokens
        if (weight > 0) {
            AdjudicationRound storage round = disputes[_disputeId].rounds[_roundId];
            CourtConfig storage config = courtConfigs[terms[round.draftTermId].courtConfigId]; // safe to use directly as it is a past term
            Account storage account = accounts[_voter];

            // weight is the number of times the minimum stake the juror has, multiplied by a precision factor for division roundings, so we remove that factor here
            uint256 weightedPenalty = _pct4(jurorMinStake, config.penaltyPct) * weight / FINAL_ROUND_WEIGHT_PRECISION;

            // Try to lock tokens
            // If there's not enough we just return 0 (so prevent juror from voting).
            // TODO: Should we use the remaining amount instead?
            uint64 slashingUpdateTermId = termId + 1;
            // Slash from balance if the account already deactivated
            if (account.deactivationTermId <= slashingUpdateTermId) {
                if (weightedPenalty > unlockedBalanceOf(_voter)) {
                    return 0;
                }
                _removeTokens(jurorToken, _voter, weightedPenalty);
            } else {
                // account.sumTreeId always > 0: as the juror has activated (and got its sumTreeId)
                uint256 treeUnlockedBalance = sumTree.getItem(account.sumTreeId).sub(account.atStakeTokens);
                if (weightedPenalty > treeUnlockedBalance) {
                    return 0;
                }
                sumTree.update(account.sumTreeId, slashingUpdateTermId, weightedPenalty, false);
            }

            // update round state
            round.collectedTokens += weightedPenalty;
            // This shouldn't overflow. See `_getJurorWeight` and `_newFinalAdjudicationRound`. This will always be less than `jurorNumber`, which currenty is uint64 too
            round.jurorSlotStates[_voter].weight = uint64(weight);
        }
    }

    /**
     * @notice Check that adjudication state is correct
     * @return `_voter`'s weight
     */
    function canReveal(uint256 _voteId, address _voter) external ensureTerm only(voting) returns (uint256) {
        (uint256 disputeId, uint256 roundId) = _decodeVoteId(_voteId);
        return _canPerformVotingAction(disputeId, roundId, _voter, AdjudicationState.Reveal);
    }

    function _canPerformVotingAction(
        uint256 _disputeId,
        uint256 _roundId,
        address _voter,
        AdjudicationState _state
    )
        internal
        view
        returns (uint256)
    {
        _checkAdjudicationState(_disputeId, _roundId, _state);

        return _getJurorWeight(_disputeId, _roundId, _voter);
    }

    function getWinningRuling(uint256 _disputeId) public view returns (uint8 ruling) {
        // TODO !!!!
        Dispute storage dispute = disputes[_disputeId];
        AdjudicationRound storage round = dispute.rounds[dispute.rounds.length - 1];

        // If an appeal was started and not confirmed, the ruling is immediately flipped
        if (round.appealers.length == 1) {
            ruling = round.appealers[0].forRuling;
        } else {
            ruling = dispute.winningRuling;
        }
    }

    function getJurorWeight(uint256 _disputeId, uint256 _roundId, address _juror) external view returns (uint256) {
        return _getJurorWeight(_disputeId, _roundId, _juror);
    }

    function _getVoteId(uint256 _disputeId, uint256 _roundId) internal pure returns (uint256) {
        return (_disputeId << 128) + _roundId;
    }

    function _decodeVoteId(uint256 _voteId) internal pure returns (uint256 disputeId, uint256 roundId) {
        disputeId = _voteId >> 128;
        roundId = _voteId & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }

    function _getJurorWeight(uint256 _disputeId, uint256 _roundId, address _juror) internal view returns (uint256) {
        return disputes[_disputeId].rounds[_roundId].jurorSlotStates[_juror].weight;
    }

    /* Subscriptions interface */
    function getCurrentTermId() external view returns (uint64) {
        return termId + neededTermTransitions();
    }

    function getTermRandomness(uint64 _termId) external view returns (bytes32) {
        require(_termId <= termId, ERROR_WRONG_TERM);
        Term storage term = terms[_termId];

        return _getTermRandomness(term);
    }

    function _getTermRandomness(Term storage _term) internal view returns (bytes32 randomness) {
        require(_blockNumber() > _term.randomnessBN, ERROR_TERM_RANDOMNESS_UNAVAIL);

        randomness = blockhash(_term.randomnessBN);
    }

    function getAccountSumTreeId(address _juror) external view returns (uint256) {
        return accounts[_juror].sumTreeId;
    }

    function getGovernor() external view returns (address) {
        return governor;
    }

    function _payGeneric(ERC20 paymentToken, uint256 amount) internal {
        if (amount > 0) {
            require(paymentToken.safeTransferFrom(msg.sender, this, amount), ERROR_DEPOSIT_FAILED);
        }
    }

    function _getRegularAdjudicationRoundJurorNumber(uint64 _currentRoundJurorNumber) internal pure returns (uint64 appealJurorNumber) {
        appealJurorNumber = APPEAL_STEP_FACTOR * _currentRoundJurorNumber;
        // make sure it's odd
        if (appealJurorNumber % 2 == 0) {
            appealJurorNumber++;
        }
    }

    // TODO: gives different results depending on when it's called!! (as it depends on current `termId`)
    function _getFinalAdjudicationRoundJurorNumber() internal view returns (uint64 appealJurorNumber) {
        // the max amount of tokens the tree can hold for this to fit in an uint64 is:
        // 2^64 * jurorMinStake / FINAL_ROUND_WEIGHT_PRECISION
        // (decimals get cancelled in the division). So it seems enough.
        appealJurorNumber = uint64(FINAL_ROUND_WEIGHT_PRECISION * sumTree.totalSumPresent(termId) / jurorMinStake);
    }

    function _createRound(
        uint256 _disputeId,
        DisputeState _disputeState,
        uint64 _draftTermId,
        uint64 _jurorNumber,
        uint32 _filledSeats
    )
        internal
        returns (uint256 roundId)
    {
        Dispute storage dispute = disputes[_disputeId];
        dispute.state = _disputeState;

        roundId = dispute.rounds.length;
        dispute.rounds.length = roundId + 1;

        AdjudicationRound storage round = dispute.rounds[roundId];
        uint256 voteId = _getVoteId(_disputeId, roundId);
        voting.createVote(voteId, dispute.possibleRulings);
        round.draftTermId = _draftTermId;
        round.jurorNumber = _jurorNumber;
        round.filledSeats = _filledSeats;
        round.triggeredBy = msg.sender;

        terms[_draftTermId].dependingDrafts += 1;
    }

    function _checkAdjudicationState(uint256 _disputeId, uint256 _roundId, AdjudicationState _state) internal view {
        Dispute storage dispute = disputes[_disputeId];
        DisputeState disputeState = dispute.state;

        require(disputeState == DisputeState.Adjudicating, ERROR_INVALID_DISPUTE_STATE);
        require(_roundId == dispute.rounds.length - 1, ERROR_INVALID_ADJUDICATION_ROUND);
        require(_adjudicationStateAtTerm(_disputeId, _roundId, termId) == _state, ERROR_INVALID_ADJUDICATION_STATE);
    }

    function _adjudicationStateAtTerm(uint256 _disputeId, uint256 _roundId, uint64 _termId) internal view returns (AdjudicationState) {
        AdjudicationRound storage round = disputes[_disputeId].rounds[_roundId];

        // we use the config for the original draft term and only use the delay for the timing of the rounds
        uint64 draftTermId = round.draftTermId;
        uint64 configId = terms[draftTermId].courtConfigId;
        uint64 draftFinishedTermId = draftTermId + round.delayTerms;
        CourtConfig storage config = courtConfigs[uint256(configId)];

        uint64 revealStart = draftFinishedTermId + config.commitTerms;
        uint64 appealStart = revealStart + config.revealTerms;
        uint64 appealConfStart = appealStart + config.appealTerms;
        uint64 appealConfEnded = appealStart + config.appealConfirmTerms;

        if (_termId < draftFinishedTermId) {
            return AdjudicationState.Invalid;
        } else if (_termId < revealStart) {
            return AdjudicationState.Commit;
        } else if (_termId < appealStart) {
            return AdjudicationState.Reveal;
        } else if (_termId < appealConfStart && _roundId < MAX_REGULAR_APPEAL_ROUNDS) {
            return AdjudicationState.Appeal;
        } else if (_termId < appealConfEnded && _roundId < MAX_REGULAR_APPEAL_ROUNDS) {
            return AdjudicationState.AppealConfirm;
        } else {
            return AdjudicationState.Ended;
        }
    }

    function _ensureTermRandomness(Term storage _term) internal {
        if (_term.randomness == bytes32(0)) {
            _term.randomness = _getTermRandomness(_term);
        }
    }

    function _treeSearch(
        bytes32 _termRandomness,
        uint256 _disputeId,
        uint256 _filledSeats,
        uint256 _jurorsRequested,
        uint256 _jurorNumber,
        uint256 _sortitionIteration
    )
        internal
        view
        returns (uint256[] keys, uint256[] stakes)
    {
        (keys, stakes) = sumTree.multiSortition(
            _termRandomness,
            _disputeId,
            termId,
            false,
            _filledSeats,
            _jurorsRequested,
            _jurorNumber,
            _sortitionIteration
        );
    }

    function _courtConfigForTerm(uint64 _termId) internal view returns (CourtConfig storage) {
        uint64 feeTermId;

        if (_termId <= termId) {
            feeTermId = _termId; // for past terms, use the fee structure of the specific term
        } else if (configChangeTermId <= _termId) {
            feeTermId = configChangeTermId; // if fees are changing before the draft, use the incoming fee schedule
        } else {
            feeTermId = termId; // if no changes are scheduled, use the current term fee schedule (which CANNOT change for this term)
        }

        uint256 courtConfigId = uint256(terms[feeTermId].courtConfigId);
        return courtConfigs[courtConfigId];
    }

    function _stake(address _from, address _to, uint256 _amount) internal {
        require(_amount > 0, ERROR_ZERO_TRANSFER);

        _assignTokens(jurorToken, _to, _amount);
        require(jurorToken.safeTransferFrom(_from, this, _amount), ERROR_DEPOSIT_FAILED);

        emit Staked(_to, _amount, totalStakedFor(_to), "");
    }

    function _assignTokens(ERC20 _token, address _to, uint256 _amount) internal {
        Account storage account = accounts[_to];
        account.balances[_token] = account.balances[_token].add(_amount);

        emit TokenBalanceChange(_token, _to, _amount, true);
    }

    function _removeTokens(ERC20 _token, address _from, uint256 _amount) internal {
        Account storage account = accounts[_from];
        account.balances[_token] = account.balances[_token].sub(_amount);

        emit TokenBalanceChange(_token, _from, _amount, false);
    }

    // TODO: Expose external function to change config
    function _setCourtConfig(
        uint64 _fromTermId,
        ERC20 _feeToken,
        uint256[4] _fees, // _jurorFee, _heartbeatFee, _draftFee, _settleFee
        uint64[4] _roundStateDurations,
        uint16 _penaltyPct,
        uint16 _finalRoundReduction
    )
        internal
    {
        // TODO: Require config changes happening at least X terms in the future
        // Where X is the amount of terms in the future a dispute can be scheduled to be drafted at

        // TODO: add reasonable limits for durations

        require(configChangeTermId > termId || termId == ZERO_TERM_ID, ERROR_PAST_TERM_FEE_CHANGE);

        for (uint i = 0; i < _roundStateDurations.length; i++) {
            require(_roundStateDurations[i] > 0, ERROR_CONFIG_PERIOD_ZERO_TERMS);
        }

        if (configChangeTermId != ZERO_TERM_ID) {
            terms[configChangeTermId].courtConfigId = 0; // reset previously set fee structure change
        }

        CourtConfig memory courtConfig = CourtConfig({
            feeToken: _feeToken,
            jurorFee: _fees[0],
            heartbeatFee: _fees[1],
            draftFee: _fees[2],
            settleFee: _fees[3],
            commitTerms: _roundStateDurations[0],
            revealTerms: _roundStateDurations[1],
            appealTerms: _roundStateDurations[2],
            appealConfirmTerms: _roundStateDurations[3],
            penaltyPct: _penaltyPct,
            finalRoundReduction: _finalRoundReduction
        });

        uint64 courtConfigId = uint64(courtConfigs.push(courtConfig) - 1);
        terms[configChangeTermId].courtConfigId = courtConfigId;
        configChangeTermId = _fromTermId;

        emit NewCourtConfig(_fromTermId, courtConfigId);
    }

    function _initSubscriptions(ERC20 _feeToken, uint256[5] _subscriptionParams) internal {
        require(_subscriptionParams[0] < MAX_UINT64, ERROR_OVERFLOW); // _periodDuration
        require(_subscriptionParams[3] < MAX_UINT16, ERROR_OVERFLOW); // _latePaymentPenaltyPct
        require(_subscriptionParams[4] < MAX_UINT16, ERROR_OVERFLOW); // _governorSharePct
        subscriptions.init(
            ISubscriptionsOwner(this),
            sumTree,
            uint64(_subscriptionParams[0]), // _periodDuration
            _feeToken,
            _subscriptionParams[1],         // _feeAmount
            _subscriptionParams[2],         // _prePaymentPeriods
            uint16(_subscriptionParams[3]), // _latePaymentPenaltyPct
            uint16(_subscriptionParams[4])  // _governorSharePct
        );
    }

    function _time() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _blockNumber() internal view returns (uint64) {
        return uint64(block.number);
    }

    function _pct4(uint256 _number, uint16 _pct) internal pure returns (uint256) {
        return _number * uint256(_pct) / PCT_BASE;
    }
}
