pragma solidity >=0.4.24;

import "./interface/IDollars.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";

import "./lib/SafeMathInt.sol";

/*
 *  SeigniorageShares ERC20
 */


contract SeigniorageShares is ERC20Detailed, Ownable {
    address private _minter;

    modifier onlyMinter() {
        require(msg.sender == _minter, "DOES_NOT_HAVE_MINTER_ROLE");
        _;
    }

    using SafeMath for uint256;
    using SafeMathInt for int256;

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_SHARE_SUPPLY = 21 * 10**6 * 10**DECIMALS;

    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _totalSupply;

    struct Account {
        uint256 balance;
        uint256 lastDividendPoints;
    }

    bool private _initializedDollar;
    // eslint-ignore
    IDollars Dollars;

    mapping(address=>Account) private _shareBalances;
    mapping (address => mapping (address => uint256)) private _allowedShares;

    function setDividendPoints(address who, uint256 amount) external onlyMinter returns (bool) {
        _shareBalances[who].lastDividendPoints = amount;
        return true;
    }

    function changeMinter(address minter) external onlyOwner {
        _minter = minter;
    }

    function mintShares(address who, uint256 amount) external onlyMinter returns (bool) {
        _shareBalances[who].balance = _shareBalances[who].balance.add(amount);
        _totalSupply = _totalSupply.add(amount);
        return true;
    }

    function externalTotalSupply()
        external
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function externalRawBalanceOf(address who)
        external
        view
        returns (uint256)
    {
        return _shareBalances[who].balance;
    }

    function lastDividendPoints(address who)
        external
        view
        returns (uint256)
    {
        return _shareBalances[who].lastDividendPoints;
    }

    function initialize(address owner_)
        public
        initializer
    {
        ERC20Detailed.initialize("Seigniorage Shares", "SHARE", uint8(DECIMALS));
        Ownable.initialize(owner_);

        _initializedDollar = false;

        _totalSupply = INITIAL_SHARE_SUPPLY;
        _shareBalances[owner_].balance = _totalSupply;

        emit Transfer(address(0x0), owner_, _totalSupply);
    }

    // instantiate dollar
    function initializeDollar(address dollarAddress) public onlyOwner {
        require(_initializedDollar == false, "ALREADY_INITIALIZED");
        Dollars = IDollars(dollarAddress);
        _initializedDollar = true;
    }

     /**
     * @return The total number of Dollars.
     */
    function totalSupply()
        public
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        return _shareBalances[who].balance;
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        updateAccount(msg.sender)
        updateAccount(to)
        validRecipient(to)
        returns (bool)
    {
        _shareBalances[msg.sender].balance = _shareBalances[msg.sender].balance.sub(value);
        _shareBalances[to].balance = _shareBalances[to].balance.add(value);
        emit Transfer(msg.sender, to, value);
        return true;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        public
        view
        returns (uint256)
    {
        return _allowedShares[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value)
        public
        validRecipient(to)
        updateAccount(from)
        updateAccount(msg.sender)
        updateAccount(to)
        returns (bool)
    {
        _allowedShares[from][msg.sender] = _allowedShares[from][msg.sender].sub(value);

        _shareBalances[from].balance = _shareBalances[from].balance.sub(value);
        _shareBalances[to].balance = _shareBalances[to].balance.add(value);
        emit Transfer(from, to, value);

        return true;
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender. This method is included for ERC20 compatibility.
     * increaseAllowance and decreaseAllowance should be used instead.
     * Changing an allowance with this method brings the risk that someone may transfer both
     * the old and the new allowance - if they are both greater than zero - if a transfer
     * transaction is mined before the later approve() call is mined.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value)
        public
        validRecipient(spender)
        updateAccount(msg.sender)
        updateAccount(spender)
        returns (bool)
    {
        _allowedShares[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        updateAccount(msg.sender)
        updateAccount(spender)
        returns (bool)
    {
        _allowedShares[msg.sender][spender] =
            _allowedShares[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedShares[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        updateAccount(msg.sender)
        updateAccount(spender)
        returns (bool)
    {
        uint256 oldValue = _allowedShares[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedShares[msg.sender][spender] = 0;
        } else {
            _allowedShares[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedShares[msg.sender][spender]);
        return true;
    }

    // attach this to any action to auto claim
    modifier updateAccount(address account) {
        require(_initializedDollar == true, "DOLLAR_NEEDS_INITIALIZATION");

        Dollars.claimDividends(account);
        _;
    }
}
