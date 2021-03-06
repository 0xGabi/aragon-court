pragma solidity ^0.4.24;

import "../../JurorsRegistry.sol";
import "../lib/TimeHelpersMock.sol";


contract JurorsRegistryMock is JurorsRegistry, TimeHelpersMock {
    bool internal treeSearchHijacked;
    bool internal nextDraftMocked;
    address[] public mockedSelectedJurors;
    uint256[] public mockedWeights;

    function mockHijackTreeSearch() external {
        treeSearchHijacked = true;
    }

    function mockNextDraft(address[] _selectedJurors, uint256[] _weights) external {
        nextDraftMocked = true;

        delete mockedSelectedJurors;
        for (uint256 i = 0; i < _selectedJurors.length; i++) {
            mockedSelectedJurors.push(_selectedJurors[i]);
        }

        delete mockedWeights;
        for (uint256 j = 0; j < _weights.length; j++) {
            mockedWeights.push(_weights[j]);
        }
    }

    function _treeSearch(uint256[7] _params) internal view returns (uint256[], uint256[]) {
        if (treeSearchHijacked) {
            return _runHijackedSearch(_params);
        }
        if (nextDraftMocked) {
            return _runMockedSearch(_params);
        }
        return super._treeSearch(_params);
    }

    function _runHijackedSearch(uint256[7] _params) internal view returns (uint256[] keys, uint256[] nodeValues) {
        uint256 _jurorsRequested = _params[4];

        keys = new uint256[](_jurorsRequested);
        nodeValues = new uint256[](_jurorsRequested);
        for (uint256 i = 0; i < _jurorsRequested; i++) {
            uint256 key = i % (tree.nextKey - 1) + 1; // loop, and avoid 0
            keys[i] = key;
            nodeValues[i] = tree.getItem(key);
        }
    }

    function _runMockedSearch(uint256[7] _params) internal returns (uint256[] ids, uint256[] activeBalances) {
        uint256 totalLength = 0;
        for (uint256 k = 0; k < mockedWeights.length; k++) {
            totalLength += mockedWeights[k];
        }

        ids = new uint256[](totalLength);
        activeBalances = new uint256[](totalLength);

        uint256 index = 0;
        for (uint256 i = 0; i < mockedSelectedJurors.length; i++) {
            address juror = mockedSelectedJurors[i];
            uint256 id = jurorsByAddress[juror].id;
            uint256 activeBalance = tree.getItem(id);

            for (uint256 j = 0; j < mockedWeights[i]; j++) {
                ids[index] = id;
                activeBalances[index] = activeBalance;
                index++;
            }
        }

        nextDraftMocked = false;
    }
}
