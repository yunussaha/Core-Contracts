pragma solidity >=0.4.24;


interface IDollars {
    function claimDividends(address account) external returns (uint256);
}

