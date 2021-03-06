pragma solidity ^0.4.24;

import "../../standards/erc900/IJurorsRegistry.sol";
import "../../standards/erc900/IJurorsRegistryOwner.sol";


contract JurorsRegistryOwnerMock is IJurorsRegistryOwner {
    uint64 internal termId;
    IJurorsRegistry internal registry;

    event Slashed(uint256 collected);
    event Collected(bool collected);
    event Drafted(address[] addresses, uint64[] weights, uint256 outputLength, uint64 selectedJurors);

    constructor(IJurorsRegistry _registry) public {
        registry = _registry;
    }

    function ensureAndGetTermId() external returns (uint64) {
        return termId;
    }

    function getLastEnsuredTermId() external view returns (uint64) {
        return termId;
    }

    function incrementTerm() public {
        termId += 1;
    }

    function assignTokens(address _juror, uint256 _amount) public {
        registry.assignTokens(_juror, _amount);
    }

    function burnTokens(uint256 _amount) public {
        registry.burnTokens(_amount);
    }

    function slashOrUnlock(address[] _jurors, uint256[] _lockedAmounts, bool[] _rewardedJurors) public {
        uint256 collectedTokens = registry.slashOrUnlock(termId, _jurors, _lockedAmounts, _rewardedJurors);
        emit Slashed(collectedTokens);
    }

    function collect(address _juror, uint256 _amount) public {
        bool collected = registry.collectTokens(_juror, _amount, termId);
        emit Collected(collected);
    }

    function draft(
        bytes32 _termRandomness,
        uint256 _disputeId,
        uint256 _selectedJurors,
        uint256 _batchRequestedJurors,
        uint64 _roundRequestedJurors,
        uint16 _lockPct
    )
        public
    {
        uint256[7] memory draftParams = [
            uint256(_termRandomness),
            _disputeId,
            termId,
            _selectedJurors,
            _batchRequestedJurors,
            _roundRequestedJurors,
            _lockPct
        ];
        (address[] memory jurors, uint64[] memory weights, uint256 outputLength, uint64 selectedJurors) = registry.draft(draftParams);
        emit Drafted(jurors, weights, outputLength, selectedJurors);
    }
}
