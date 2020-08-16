pragma solidity >=0.4.24;

import "./lib/SafeMathInt.sol";
import "./lib/UInt256Lib.sol";
import "./dollars.sol";

/*
 *  Dollar Policy
 */


interface IDecentralizedOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}


contract DollarsPolicy is Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        uint256 cpi,
        int256 requestedSupplyAdjustment,
        uint256 timestampSec
    );

    Dollars public dollars;

    // Provides the current CPI, as an 18 decimal fixed point number.
    IDecentralizedOracle public sharesPerUsdOracle;
    IDecentralizedOracle public ethPerUsdOracle;
    IDecentralizedOracle public ethPerUsdcOracle;

    uint256 public deviationThreshold;

    uint256 public rebaseLag;

    uint256 private cpi;

    uint256 public minRebaseTimeIntervalSec;

    uint256 public lastRebaseTimestampSec;

    uint256 public rebaseWindowOffsetSec;

    uint256 public rebaseWindowLengthSec;

    uint256 public epoch;

    address WETH_ADDRESS;
    address SHARE_ADDRESS;

    uint256 private constant DECIMALS = 18;

    uint256 private constant MAX_RATE = 10**6 * 10**DECIMALS;
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255) / MAX_RATE;

    address public orchestrator;
    bool private initializedOracle;

    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator);
        _;
    }

    function getUsdSharePrice() external view returns (uint256) {
        sharesPerUsdOracle.update();

        uint256 sharePrice = sharesPerUsdOracle.consult(SHARE_ADDRESS, 1 * 10 ** 9);        // 10^9 decimals
        return sharePrice;
    }

    function rebase() external onlyOrchestrator {
        require(inRebaseWindow());
        require(initializedOracle == true, 'ORACLE_NOT_INITIALIZED');

        require(lastRebaseTimestampSec.add(minRebaseTimeIntervalSec) < now);

        lastRebaseTimestampSec = now.sub(
            now.mod(minRebaseTimeIntervalSec)).add(rebaseWindowOffsetSec);

        epoch = epoch.add(1);

        sharesPerUsdOracle.update();
        ethPerUsdOracle.update();
        ethPerUsdcOracle.update();

        uint256 ethUsdcPrice = ethPerUsdcOracle.consult(WETH_ADDRESS, 1 * 10 ** 18);        // 10^18 decimals ropsten, 10^6 mainnet
        uint256 ethUsdPrice = ethPerUsdOracle.consult(WETH_ADDRESS, 1 * 10 ** 18);          // 10^9 decimals
        uint256 dollarCoinExchangeRate = ethUsdcPrice.mul(10 ** 9)                          // 10^18 decimals
            .div(ethUsdPrice);
        uint256 sharePrice = sharesPerUsdOracle.consult(SHARE_ADDRESS, 1 * 10 ** 9);        // 10^9 decimals
        uint256 shareExchangeRate = sharePrice.mul(dollarCoinExchangeRate).div(10 ** 9);    // 10^18 decimals

        uint256 targetRate = cpi;

        if (dollarCoinExchangeRate > MAX_RATE) {
            dollarCoinExchangeRate = MAX_RATE;
        }

        // dollarCoinExchangeRate & targetRate arre 10^18 decimals
        int256 supplyDelta = computeSupplyDelta(dollarCoinExchangeRate, targetRate);        // supplyDelta = 10^9 decimals

        // Apply the Dampening factor.
        supplyDelta = supplyDelta.div(rebaseLag.toInt256Safe());

        // check on the expansionary side
        if (supplyDelta > 0 && dollars.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(dollars.totalSupply())).toInt256Safe();
        }

        // check on the contraction side
        if (supplyDelta < 0 && dollars.totalSupply().add(uint256(supplyDelta.abs())) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(dollars.totalSupply())).toInt256Safe();
        }

        uint256 supplyAfterRebase;

        if (supplyDelta < 0) { // contraction, we send the amount of shares to mint
            uint256 sharesToMint = uint256(supplyDelta.abs());
            supplyAfterRebase = dollars.rebase(epoch, (sharesToMint).toInt256Safe().mul(-1));
        } else { // expansion, we send the amount of dollars to mint
            supplyAfterRebase = dollars.rebase(epoch, supplyDelta);
        }

        assert(supplyAfterRebase <= MAX_SUPPLY);
        emit LogRebase(epoch, dollarCoinExchangeRate, cpi, supplyDelta, now);
    }

    function setOrchestrator(address orchestrator_)
        external
        onlyOwner
    {
        orchestrator = orchestrator_;
    }

    function setDeviationThreshold(uint256 deviationThreshold_)
        external
        onlyOwner
    {
        deviationThreshold = deviationThreshold_;
    }

    function setCpi(uint256 cpi_)
        external
        onlyOwner
    {
        require(cpi_ > 0);
        cpi = cpi_;
    }

    function setRebaseLag(uint256 rebaseLag_)
        external
        onlyOwner
    {
        require(rebaseLag_ > 0);
        rebaseLag = rebaseLag_;
    }

    function setWethAddress(address wethAddress)
        external
        onlyOwner
    {
        WETH_ADDRESS = wethAddress;
    }

    function setShareAddress(address shareAddress)
        external
        onlyOwner
    {
        SHARE_ADDRESS = shareAddress;
    }

    function setRebaseTimingParameters(
        uint256 minRebaseTimeIntervalSec_,
        uint256 rebaseWindowOffsetSec_,
        uint256 rebaseWindowLengthSec_)
        external
        onlyOwner
    {
        require(minRebaseTimeIntervalSec_ > 0);
        require(rebaseWindowOffsetSec_ < minRebaseTimeIntervalSec_);

        minRebaseTimeIntervalSec = minRebaseTimeIntervalSec_;
        rebaseWindowOffsetSec = rebaseWindowOffsetSec_;
        rebaseWindowLengthSec = rebaseWindowLengthSec_;
    }

    function initialize(address owner_, Dollars dollars_)
        public
        initializer
    {
        Ownable.initialize(owner_);

        deviationThreshold = 5 * 10 ** (DECIMALS-2);

        rebaseLag = 50;
        minRebaseTimeIntervalSec = 1 days;
        rebaseWindowOffsetSec = 63000;  // with stock market, 63000 for 1:30pm EST (debug)
        rebaseWindowLengthSec = 15 minutes;
        lastRebaseTimestampSec = 0;
        cpi = 1 * 10 ** 18;
        epoch = 0;

        dollars = dollars_;
    }

    function initializeOracles(
        address sharesPerUsdOracleAddress,
        address ethPerUsdOracleAddress,
        address ethPerUsdcOracleAddress
    ) public onlyOwner {
        require(initializedOracle == false, 'ALREADY_INITIALIZED_ORACLE');
        sharesPerUsdOracle = IDecentralizedOracle(sharesPerUsdOracleAddress);
        ethPerUsdOracle = IDecentralizedOracle(ethPerUsdOracleAddress);
        ethPerUsdcOracle = IDecentralizedOracle(ethPerUsdcOracleAddress);

        initializedOracle = true;
    }

    function changeOracles(
        address sharesPerUsdOracleAddress,
        address ethPerUsdOracleAddress,
        address ethPerUsdcOracleAddress
    ) public onlyOwner {
        sharesPerUsdOracle = IDecentralizedOracle(sharesPerUsdOracleAddress);
        ethPerUsdOracle = IDecentralizedOracle(ethPerUsdOracleAddress);
        ethPerUsdcOracle = IDecentralizedOracle(ethPerUsdcOracleAddress);
    }

    function inRebaseWindow() public view returns (bool) {
        return (
            now.mod(minRebaseTimeIntervalSec) >= rebaseWindowOffsetSec &&
            now.mod(minRebaseTimeIntervalSec) < (rebaseWindowOffsetSec.add(rebaseWindowLengthSec))
        );
    }

    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        private
        view
        returns (int256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        int256 targetRateSigned = targetRate.toInt256Safe();
        return dollars.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }

    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        private
        view
        returns (bool)
    {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }
}
