pragma solidity >=0.4.24;

import "./lib/UInt256Lib.sol";
import "./lib/SafeMathInt.sol";
import "./interface/ISeignorageShares.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";

interface IDollarPolicy {
    function getUsdSharePrice() external view returns (uint256 price);
}

/*
 *  Dollar ERC20
 */

contract Dollars is ERC20Detailed, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    event LogRebase(uint256 indexed epoch, uint256 totalSupply);
    event LogRebasePaused(bool paused);
    event LogSetMinDiscount(uint256 minDiscount);
    event LogBurn(address indexed from, uint256 value);
    event LogClaim(address indexed from, uint256 value);
    event LogMonetaryPolicyUpdated(address monetaryPolicy);

    // Used for authentication
    address public monetaryPolicy;
    address public sharesAddress;

    modifier onlyMonetaryPolicy() {
        require(msg.sender == monetaryPolicy);
        _;
    }

    // Precautionary emergency controls.
    bool public rebasePaused;

    modifier whenRebaseNotPaused() {
        require(!rebasePaused);
        _;
    }

    // coins needing to be burned (9 decimals)
    uint256 private remainingDollarsToBeBurned;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_DOLLAR_SUPPLY = 1 * 10**6 * 10**DECIMALS;

    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _totalSupply;

    uint256 private constant POINT_MULTIPLIER = 10 ** 9;

    uint256 private shareExchangeRate;
    uint256 private dollarExchangeRate;

    uint256 private totalDividendPoints;
    uint256 private unclaimedDividends;

    ISeigniorageShares Shares;

    struct Account {
        uint256 balance;
        uint256 lastDisbursementPoints;
    }

    mapping(address => Account) private _dollarBalances;

    // This is denominated in Dollars, because the cents-dollars conversion might change before
    // it's fully paid.
    mapping (address => mapping (address => uint256)) private _allowedDollars;

    IDollarPolicy DollarPolicy;
    uint256 public burningDiscount; // percentage
    uint256 public minimumBurningThreshold;

    /**
     * @param monetaryPolicy_ The address of the monetary policy contract to use for authentication.
     */
    function setMonetaryPolicy(address monetaryPolicy_)
        external
        onlyOwner
    {
        monetaryPolicy = monetaryPolicy_;
        DollarPolicy = IDollarPolicy(monetaryPolicy_);
        emit LogMonetaryPolicyUpdated(monetaryPolicy_);
    }

    /**
     * @dev Pauses or unpauses the execution of rebase operations.
     * @param paused Pauses rebase operations if this is true.
     */
    function setRebasePaused(bool paused)
        external
        onlyOwner
    {
        rebasePaused = paused;
        emit LogRebasePaused(paused);
    }

    // action of claiming funds
    function externalClaimDividends(address account) external internalUpdateAccount(account) returns (uint256) {
        uint256 owing = dividendsOwing(account);
        return owing;
    }

    // attach this to any action to auto claim
    modifier internalUpdateAccount(address account) {
        uint256 owing = dividendsOwing(account);

        if (owing > 0) {
            unclaimedDividends = unclaimedDividends.sub(owing);
            _dollarBalances[account].balance += owing;
        }

        Shares.setDividendPoints(account, totalDividendPoints);

        emit LogClaim(account, owing);
        _;
    }

    /**
     * @dev Notifies Dollars contract about a new rebase cycle.
     * @param supplyDelta The number of new dollar tokens to add into circulation via expansion.
     * @return The total number of dollars after the supply adjustment.
     */
    function rebase(uint256 epoch, int256 supplyDelta)
        external
        onlyMonetaryPolicy
        whenRebaseNotPaused
        returns (uint256)
    {
        if (supplyDelta == 0) {
            emit LogRebase(epoch, _totalSupply);
            return _totalSupply;
        }

        if (supplyDelta < 0) {
            if (remainingDollarsToBeBurned >= _totalSupply) {
                burningDiscount = burningDiscount.add(1);
            } else {
                uint256 dollarsToBurn = uint256(supplyDelta.abs());
                if (dollarsToBurn > _totalSupply.div(10)) { // maximum contraction is 10% of the total USD Supply
                    dollarsToBurn = _totalSupply.div(10);
                }

                if (dollarsToBurn.add(remainingDollarsToBeBurned) > _totalSupply) {
                    dollarsToBurn = _totalSupply.sub(remainingDollarsToBeBurned);
                }

                if (remainingDollarsToBeBurned > minimumBurningThreshold) {
                    burningDiscount = burningDiscount.add(1);
                } else {
                    burningDiscount = 1; // default
                }

                remainingDollarsToBeBurned = remainingDollarsToBeBurned.add(dollarsToBurn);
            }
        } else {
            disburse(uint256(supplyDelta));
        }

        if (_totalSupply > MAX_SUPPLY) {
            _totalSupply = MAX_SUPPLY;
        }

        emit LogRebase(epoch, _totalSupply);
        return _totalSupply;
    }

    function initialize(address owner_, address seigniorageAddress)
        public
        initializer
    {
        ERC20Detailed.initialize("Dollars", "USD", uint8(DECIMALS));
        Ownable.initialize(owner_);

        rebasePaused = false;
        _totalSupply = INITIAL_DOLLAR_SUPPLY;

        sharesAddress = seigniorageAddress;
        Shares = ISeigniorageShares(seigniorageAddress);

        _dollarBalances[owner_].balance = _totalSupply;
        burningDiscount = 1;
        minimumBurningThreshold = 100 * 10 ** 9; // 100 dollars is the minimum threshold. Anything above warrants increased discount

        emit Transfer(address(0x0), owner_, _totalSupply);
    }

    function dividendsOwing(address account) public view returns (uint256) {
        if (totalDividendPoints > Shares.lastDividendPoints(account)) {
            uint256 newDividendPoints = totalDividendPoints.sub(Shares.lastDividendPoints(account));
            uint256 sharesBalance = Shares.externalRawBalanceOf(account);
            return sharesBalance.mul(newDividendPoints).div(POINT_MULTIPLIER);
        } else {
            return 0;
        }
    }

    // auto claim modifier
    // if user is owned, we pay out immedietly
    // if user is not owned, we prevent them from claiming until the next rebase
    modifier updateAccount(address account) {
        uint256 owing = dividendsOwing(account);

        if (owing > 0) {
            unclaimedDividends = unclaimedDividends.sub(owing);
            _dollarBalances[account].balance += owing;
        }

        Shares.setDividendPoints(account, totalDividendPoints);

        emit LogClaim(account, owing);
        _;
    }

    function setBurningDiscount(uint256 discount)
        public
        onlyOwner
    {
        require(discount >= 0, 'POSITIVE_DISCOUNT');
        require(discount < 100, 'DISCOUNT_TOO_HIGH');
        burningDiscount = discount;
    }

    function setMinimumBurningThreshold(uint256 minimum)
        public
        onlyOwner
    {
        require(minimum >= 0, 'POSITIVE_MINIMUM');
        require(minimum < _totalSupply, 'MINIMUM_TOO_HIGH');
        minimumBurningThreshold = minimum;
    }

    // action of claiming funds
    function claimDividends(address account) public updateAccount(account) returns (uint256) {
        uint256 owing = dividendsOwing(account);
        return owing;
    }

    /**
     * @return The total number of dollars.
     */
    function totalSupply()
        public
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    /**
     * @param who The address to query.
     * @return The balance of the specified address.
     */
    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        return _dollarBalances[who].balance.add(dividendsOwing(who));
    }

    function getRemainingDollarsToBeBurned()
        public
        view
        returns (uint256)
    {
        return remainingDollarsToBeBurned;
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        validRecipient(to)
        updateAccount(msg.sender)
        updateAccount(to)
        returns (bool)
    {
        _dollarBalances[msg.sender].balance = _dollarBalances[msg.sender].balance.sub(value);
        _dollarBalances[to].balance = _dollarBalances[to].balance.add(value);
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
        return _allowedDollars[owner_][spender];
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
        _allowedDollars[from][msg.sender] = _allowedDollars[from][msg.sender].sub(value);

        _dollarBalances[from].balance = _dollarBalances[from].balance.sub(value);
        _dollarBalances[to].balance = _dollarBalances[to].balance.add(value);
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
        _allowedDollars[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
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
        _allowedDollars[msg.sender][spender] =
            _allowedDollars[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedDollars[msg.sender][spender]);
        return true;
    }

    // amount in is 10 ** 9 decimals
    function burn(uint256 amount) public updateAccount(msg.sender) {
        require(amount > 0, 'AMOUNT_MUST_BE_POSITIVE');
        require(burningDiscount >= 0, 'DISCOUNT_NOT_VALID');
        require(remainingDollarsToBeBurned > 0, 'COIN_BURN_MUST_BE_GREATER_THAN_ZERO');
        require(amount <= _dollarBalances[msg.sender].balance, 'INSUFFICIENT_DOLLAR_BALANCE');
        require(amount <= remainingDollarsToBeBurned, 'AMOUNT_MUST_BE_LESS_THAN_OR_EQUAL_TO_REMAINING_COINS');

        _burn(msg.sender, amount);
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        updateAccount(spender)
        updateAccount(msg.sender)
        returns (bool)
    {
        uint256 oldValue = _allowedDollars[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedDollars[msg.sender][spender] = 0;
        } else {
            _allowedDollars[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedDollars[msg.sender][spender]);
        return true;
    }

    function consultBurn(uint256 amount)
        public
        returns (uint256)
    {
        require(amount > 0, 'AMOUNT_MUST_BE_POSITIVE');
        require(burningDiscount >= 0, 'DISCOUNT_NOT_VALID');
        require(remainingDollarsToBeBurned > 0, 'COIN_BURN_MUST_BE_GREATER_THAN_ZERO');
        require(amount <= _dollarBalances[msg.sender].balance.add(dividendsOwing(msg.sender)), 'INSUFFICIENT_DOLLAR_BALANCE');
        require(amount <= remainingDollarsToBeBurned, 'AMOUNT_MUST_BE_LESS_THAN_OR_EQUAL_TO_REMAINING_COINS');

        uint256 usdPerShare = DollarPolicy.getUsdSharePrice(); // 1 share = x dollars
        usdPerShare = usdPerShare.sub(usdPerShare.mul(burningDiscount).div(100)); // 10^9
        uint256 sharesToMint = amount.mul(10 ** 9).div(usdPerShare); // 10^9

        return sharesToMint;
    }

    function getUnclaimedDividends()
        public
        view
        returns (uint256)
    {
        return unclaimedDividends;
    }

    function getTotalDividendPoints()
        public
        view
        returns (uint256)
    {
        return totalDividendPoints;
    }

    function disburse(uint256 amount) internal returns (bool) {
        totalDividendPoints = totalDividendPoints.add(amount.mul(POINT_MULTIPLIER).div(Shares.externalTotalSupply()));
        _totalSupply = _totalSupply.add(amount);
        unclaimedDividends = unclaimedDividends.add(amount);
        return true;
    }

    function _burn(address account, uint256 amount)
        internal 
    {
        _totalSupply = _totalSupply.sub(amount);
        _dollarBalances[account].balance = _dollarBalances[account].balance.sub(amount);

        uint256 usdPerShare = DollarPolicy.getUsdSharePrice(); // 1 share = x dollars
        usdPerShare = usdPerShare.sub(usdPerShare.mul(burningDiscount).div(100)); // 10^9
        uint256 sharesToMint = amount.mul(10 ** 9).div(usdPerShare); // 10^9

        Shares.mintShares(account, sharesToMint);
        remainingDollarsToBeBurned = remainingDollarsToBeBurned.sub(amount);

        emit Transfer(account, address(0), amount);
        emit LogBurn(account, amount);
    }
}
