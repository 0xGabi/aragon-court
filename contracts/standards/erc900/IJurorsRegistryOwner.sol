pragma solidity ^0.4.24;


interface IJurorsRegistryOwner {
    function ensureAndGetTermId() external returns (uint64);
    function getLastEnsuredTermId() external view returns (uint64);
}
