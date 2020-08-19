pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";


contract MinePool is Ownable {
    IERC20 public shareToken;
    IERC20 public dollarToken;

    constructor(IERC20 _shareToken, IERC20 _dollarToken) public {
        shareToken = _shareToken;
        dollarToken = _dollarToken;
    }

    function shareBalance() public view returns (uint256) {
        return shareToken.balanceOf(address(this));
    }

    function shareTransfer(address to, uint256 value) external onlyOwner returns (bool) {
        return shareToken.transfer(to, value);
    }

    function dollarBalance() public view returns (uint256) {
        return dollarToken.balanceOf(address(this));
    }

    function dollarTransfer(address to, uint256 value) external onlyOwner returns (bool) {
        return dollarToken.transfer(to, value);
    }
}
