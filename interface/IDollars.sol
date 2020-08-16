pragma solidity >=0.4.24;


interface IDollars {
    function externalClaimDividends(address account) external returns (uint256);
}
