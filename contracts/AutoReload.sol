// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.7;

/*

    50% to Vault 
    50% to EmpireDex

    Tweet Vault 
     - every (tweet mechanic)
     - team pays gas to call RewardVaultActivated()
       - fees are charged (exclude the vault from selling fees)
         - cause LP to be created when trade volume + number of tokens waiting on the contract are met
         - autobuyback if settings met
         - sweep to give rewards to in ETH to users
       - syncCirculatingSupply() is called


    // 2% Prism Team
    // 5% ETH rewards
    // 8% Shine team/Buyback
    
*/



import "../access/Ownable.sol";
import "../utils/Address.sol";
import "../utils/math/SafeMath.sol";
import "../token/ERC20.sol";
import "../utils/IERC20.sol";

import "../interfaces/IEmpirePair.sol";
import "../interfaces/IEmpireFactory.sol";
import "../interfaces/IEmpireRouter.sol";

interface IWBNB {
    function deposit() external payable;
}

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setFeeShares(uint256 _marketingShare1, uint256 _marketingShare2) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using Address for address payable;
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IERC20 REWARD = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; 
    
    IEmpireRouter router;

    address public constant marketingWallet = address(0x46d8E2cB84dD4eeaFea1138Da4E4448E6674D7E6);
    address public constant marketingWallet2 = address(0x46d8E2cB84dD4eeaFea1138Da4E4448E6674D7E6);
    
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;

    uint256 public minPeriod = 60 minutes;
    uint256 public minDistribution = 1 * (10 ** 16);

    uint256 public marketingShare1 = 10;
    uint256 public marketingShare2 = 10;

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _router) {
        router = _router != address(0)
            ? IEmpireRouter(_router)
            : IEmpireRouter(0xdADaae6cDFE4FA3c35d54811087b3bC3Cd60F348);
        _token = msg.sender;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }

    function setFeeShares(uint256 _marketingShare1, uint256 _marketingShare2) external override onlyToken {
        marketingShare1 = _marketingShare1;
        marketingShare2 = _marketingShare2;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        } else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 _available = msg.value;

        uint256 marketingAllocation1 = _available.div(100).mul(marketingShare1);
        uint256 marketingAllocation2 = _available.div(100).mul(marketingShare2); 

        payable(marketingWallet).sendValue(marketingAllocation1);
        payable(marketingWallet2).sendValue(marketingAllocation2);

        uint256 _totalAvailable = address(this).balance;

        uint256 balanceBefore = REWARD.balanceOf(address(this));

        IWBNB(WBNB).deposit{value: _totalAvailable}();

        uint256 amount = REWARD.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
        
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }

    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            REWARD.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }

    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract RELOAD is IERC20, Ownable {
    using Address for address;
    using SafeMath for uint256;

    address REWARD = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; 
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;

    address prismTeam = 0x5ABBd94bb0561938130d83FdA22E672110e12528;
    address marketingTeam = 0x5ABBd94bb0561938130d83FdA22E672110e12528;

    string constant _name = "Reload Token";
    string constant _symbol = "RELOAD";
    uint8 constant _decimals = 18;

    uint256 _totalSupply = 1 * 10**15 * (10 ** _decimals); //1 QUADRILLION
    uint256 public _maxTxAmount = ( _totalSupply * 1 ) / 100;
    uint256 public _maxWalletToken = ( _totalSupply * 5 ) / 100;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;
    mapping (address => bool) isDividendExempt;

    uint256 liquidityFee    = 2;
    uint256 reflectionFee   = 5;
    uint256 marketingFee    = 8;

    uint256 public totalFee = 15;
    uint256 feeDenominator  = 100;

    address public autoLiquidityReceiver;
    address public vaultAddress;

    uint256 targetLiquidity = 25;
    uint256 targetLiquidityDenominator = 100;

    address public pair;
    IEmpireRouter router = IEmpireRouter(0xdADaae6cDFE4FA3c35d54811087b3bC3Cd60F348); 
    uint256 public launchedAt;

    uint256 buybackMultiplierNumerator = 120;
    uint256 buybackMultiplierDenominator = 100;
    uint256 buybackMultiplierTriggeredAt;
    uint256 buybackMultiplierLength = 30 minutes;

    bool public autoBuybackEnabled = false;
    uint256 autoBuybackCap;
    uint256 autoBuybackAccumulator;
    uint256 autoBuybackAmount;
    uint256 autoBuybackBlockPeriod;
    uint256 autoBuybackBlockLast;

    uint256 buybackPercentage;
    uint256 prismTeamPercentage;
    uint256 marketingTeamPercentage;

    uint256 sendFundsThreshold;

    DividendDistributor public distributor;
    uint256 distributorGas = 300000;
    
    bool public buyCooldownEnabled = true;
    uint8 public cooldownTimerInterval = 5; 
    mapping (address => uint) private cooldownTimer;
    mapping (address => uint) private cooldownSell;

    bool public swapEnabled = true;
    uint256 public swapThreshold = (getCirculatingSupply() * 50 ) / 10000000;
    uint256 public tradeSwapVolume = (getCirculatingSupply() * 100 ) / 10000000;
    uint256 public _tTradeCycle;
    bool inSwap;

    bool public tradingEnabled = false; //once enabled its final and cannot be changed

    uint256 minimumTokenBalanceForDividends = 20000 * (10 ** _decimals);

    modifier swapping() { inSwap = true; _; inSwap = false; }

    modifier onlyVault() {
        require(
            msg.sender == vaultAddress,
            "Empire::onlyVault: Insufficient Privileges"
        );
        _;
    }

    modifier onlyContract() {
        require(
            msg.sender == address(this),
            "Empire::onlyContract: Insufficient Privileges"
        );
        _;
    }

    modifier onlyPair() {
        require(
            msg.sender == pair,
            "Empire::onlyPair: Insufficient Privileges"
        );
        _;
    }

    constructor (address vault) {
        IEmpireRouter routr = IEmpireRouter(0xdADaae6cDFE4FA3c35d54811087b3bC3Cd60F348); //empiredex

        PairType pairType =
            address(this) < WBNB
                ? PairType.SweepableToken1
                : PairType.SweepableToken0;

        pair = IEmpireFactory(routr.factory()).createPair(WBNB, address(this), pairType, 0);

        _allowances[address(this)][address(routr)] = type(uint256).max;

        distributor = new DividendDistributor(address(routr));

        setVaultAddress(vault);

        isFeeExempt[msg.sender] = true;
        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[address(routr)] = true;
        isTxLimitExempt[pair] = true;
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;
        isDividendExempt[ZERO] = true;

        isDividendExempt[vault] = true;
        isTxLimitExempt[vault] = true;

        autoLiquidityReceiver = msg.sender;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);

        // Sets the default percentage breakdowns for sweeps
        buybackPercentage = 66;
        prismTeamPercentage = 11;
        marketingTeamPercentage =23;

        // Sets the default threshhold for sending funds for scraps after sweep calls
        sendFundsThreshold = 1; // 1 BNB
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external pure returns (uint8) { return _decimals; }
    function symbol() external pure returns (string memory) { return _symbol; }
    function name() external pure returns (string memory) { return _name; }
    function getOwner() external view returns (address) { return owner(); }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "RELOAD:: Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }

    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        require(tradingEnabled || isFeeExempt[sender] || isFeeExempt[recipient], "RELOAD:: Trading is restricted until liquidity has been added");
        require(isTxLimitExempt[sender] || isTxLimitExempt[recipient] || _balances[recipient].add(amount) <= _maxWalletToken, "RELOAD:: recipient wallet limit exceeded");
        require(isTxLimitExempt[sender] || isTxLimitExempt[recipient] || amount <= _maxTxAmount, "RELOAD:: transfer limit exceeded");

        if(inSwap){ return _basicTransfer(sender, recipient, amount); }

        //check tradeCycle is above the volume required
        if(tradingEnabled && _tTradeCycle > tradeSwapVolume) {
            if(shouldSwapBack()){ swapBack(); }
            if(shouldAutoBuyback()){ triggerAutoBuyback(); }
            if(shouldSendFunds()){ triggerSendFunds(); }
        }

        if(!isDividendExempt[sender]){ try distributor.setShare(sender, _balances[sender]) {} catch {} }
        if(!isDividendExempt[recipient]){ try distributor.setShare(recipient, _balances[recipient]) {} catch {} }

        if(tradingEnabled) {
            try distributor.process(distributorGas) {} catch {}
            _tTradeCycle = _tTradeCycle.add(amount);
        }

        _balances[sender] = _balances[sender].sub(amount, "RELOAD:: Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(sender) ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived); 

        // If it is a sell & msg.sender is not at max level, add 1 to cooldownSell
        if (recipient == address(router) && cooldownSell[msg.sender] < 2) {
            cooldownSell[msg.sender]++;
        }

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }

    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "RELOAD:: Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !isFeeExempt[sender];
    }

    function getTotalFee(bool selling) public view returns (uint256) {
        if(launchedAt + 2 >= block.number){ return feeDenominator.sub(1); }
        if(selling && buybackMultiplierTriggeredAt.add(buybackMultiplierLength) > block.timestamp){ return getMultipliedFee(); } //EDIT remove?  
        if(vaultAddress == msg.sender) { return totalFee; }   
        if(selling) {
            if(cooldownSell[msg.sender] == 0) {
                // 1st sell : 10% eth Reflections tax
                // (15% total eth earn, 25%total tax)
                return totalFee.add(10);
            } else if(cooldownSell[msg.sender] == 1) {
                // 2nd sell: 20% eth Reflections tax
                // (25% total eth earn, 35% total tax)
                return totalFee.add(20);
            } else if(cooldownSell[msg.sender] == 2) {
                // 3rd sell: 45% eth Reflections tax
                // (50% total Eth earn, 60% total tax)
                return totalFee.add(45);
            }
        }
        return totalFee;
    }

    function getMultipliedFee() public view returns (uint256) {
        uint256 remainingTime = buybackMultiplierTriggeredAt.add(buybackMultiplierLength).sub(block.timestamp);
        uint256 feeIncrease = totalFee.mul(buybackMultiplierNumerator).div(buybackMultiplierDenominator).sub(totalFee);
        return totalFee.add(feeIncrease.mul(remainingTime).div(buybackMultiplierLength));
    }

    function takeFee(address sender, address receiver, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount.mul(getTotalFee(receiver == pair)).div(feeDenominator);

        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);

        return amount.sub(feeAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair 
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }
    
    function swapBack() public swapping {
        uint256 dynamicLiquidityFee = isOverLiquified(targetLiquidity, targetLiquidityDenominator) ? 0 : liquidityFee;
        uint256 amountToLiquify = swapThreshold.mul(dynamicLiquidityFee).div(totalFee).div(2); // liq amount
        uint256 amountToSwap = swapThreshold.sub(amountToLiquify); //buyback + bnb reward

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 balanceBefore = address(this).balance;

        //EDIT: need to get quote for how much to sweep instead of sweeping amountToSwap
        
        // uint256 quoteReturn = router.getAmountOut(amountIn, reserveIn, reserveOut);

        sweep(amountToSwap);
        
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountREWARD = address(this).balance.sub(balanceBefore);

        uint256 totalREWARDFee = totalFee.sub(dynamicLiquidityFee.div(2));

        uint256 amountREWARDLiquidity = amountREWARD.mul(dynamicLiquidityFee).div(totalREWARDFee).div(2);

        uint256 amountREWARDReflection = amountREWARD.mul(reflectionFee).div(totalREWARDFee);
    
        try distributor.deposit{value: amountREWARDReflection}() {} catch {}
    
        if(amountToLiquify > 0){
            router.addLiquidityETH{value: amountREWARDLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountREWARDLiquidity, amountToLiquify);
        }

        _tTradeCycle = 0; //reset trade cycle as liquify has occurred
    }

    function shouldAutoBuyback() internal view returns (bool) {
        return msg.sender != pair
            && !inSwap
            && autoBuybackEnabled
            && autoBuybackBlockLast + autoBuybackBlockPeriod <= block.number
            && address(this).balance >= autoBuybackAmount;
    }

    function triggerManualBuyback(uint256 amount, bool triggerBuybackMultiplier) external onlyOwner {
        buyTokens(amount, DEAD);
        if(triggerBuybackMultiplier){
            buybackMultiplierTriggeredAt = block.timestamp;
            emit BuybackMultiplierActive(buybackMultiplierLength);
        }
    }

    function clearBuybackMultiplier() external onlyOwner {
        buybackMultiplierTriggeredAt = 0;
    }

    function triggerAutoBuyback() internal {
        buyTokens(autoBuybackAmount, DEAD);
        autoBuybackBlockLast = block.number;
        autoBuybackAccumulator = autoBuybackAccumulator.add(autoBuybackAmount);
        if(autoBuybackAccumulator > autoBuybackCap){ autoBuybackEnabled = false; }
    }

    function buyTokens(uint256 amount, address to) internal swapping {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(this);
    
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            to,
            block.timestamp
        );
    }

    function setAutoBuybackSettings(bool _enabled, uint256 _cap, uint256 _amount, uint256 _period) external onlyOwner {
        autoBuybackEnabled = _enabled;
        autoBuybackCap = _cap;
        autoBuybackAccumulator = 0;
        autoBuybackAmount = _amount.div(100);
        autoBuybackBlockPeriod = _period;
        autoBuybackBlockLast = block.number;
    }

    function setBuybackMultiplierSettings(uint256 numerator, uint256 denominator, uint256 length) external onlyOwner {
        require(numerator / denominator <= 2 && numerator > denominator);
        buybackMultiplierNumerator = numerator;
        buybackMultiplierDenominator = denominator;
        buybackMultiplierLength = length;
    }

    function launched() internal view returns (bool) {
        return launchedAt != 0;
    }

    function launch() internal {
        launchedAt = block.number;
    }

    function setIsAllExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair);
        
        isFeeExempt[holder] = exempt;
        isTxLimitExempt[holder] = exempt;
        isDividendExempt[holder] = exempt;
    }

    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function setIsFeeExempt(address holder, bool exempt) external onlyOwner {
        isFeeExempt[holder] = exempt;
    }

    function setIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        isTxLimitExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _buybackFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _feeDenominator) external onlyOwner {
        liquidityFee = _liquidityFee;
        reflectionFee = _reflectionFee;
        totalFee = _liquidityFee.add(_buybackFee).add(_reflectionFee).add(_marketingFee);
        feeDenominator = _feeDenominator;
        require(totalFee < feeDenominator/4);
    }

    function setFeeReceivers(address _autoLiquidityReceiver) external onlyOwner {
        autoLiquidityReceiver = _autoLiquidityReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external onlyOwner {
        swapEnabled = _enabled;
        swapThreshold = (getCirculatingSupply() * _amount) / 10000000;
    }

    function setTradeSwapVolume(uint256 _amount) external onlyOwner {
        tradeSwapVolume = (getCirculatingSupply() * _amount ) / 10000000;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external onlyOwner {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyOwner {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setFeeShares(uint256 _marketingShare1, uint256 _marketingShare) external onlyOwner {
        require(_marketingShare1 < 50 && _marketingShare < 50, "RELOAD:: Fees must be below 50% each");
        distributor.setFeeShares(_marketingShare1, _marketingShare);
    }

    function setDistributorGasSettings(uint256 gas) external onlyOwner {
        require(gas >= 200000 && gas <= 500000, "RELOAD:: gasForProcessing must be between 200,000 and 500,000");
        require(gas != distributorGas, "RELOAD:: Cannot update gasForProcessing to same value");
        distributorGas = gas;
    }

    function setMinimumTokenBalanceForDividends(uint256 _minimumTokenBalanceForDividends) external onlyOwner {
        minimumTokenBalanceForDividends = _minimumTokenBalanceForDividends;
    }

    function setMaxWalletToken(uint256 maxWalletToken) external onlyOwner {
        _maxWalletToken = ( _totalSupply * maxWalletToken ) / 100;
    }

    function setMaxTxAmount(uint256 maxTxAmount) external onlyOwner {
        _maxTxAmount = ( _totalSupply * maxTxAmount ) / 100;
    }

    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function syncCirculatingSupply() external onlyVault() {
        _totalSupply = getCirculatingSupply();
    }

    function setVaultAddress(address _vaultAddress) public onlyOwner {
        vaultAddress = _vaultAddress;
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy.mul(balanceOf(pair).mul(2)).div(getCirculatingSupply());
    }

    function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }
    
    function triggerRewards() external onlyOwner {
        distributor.process(distributorGas);
    }
    
    function enableTrading() external onlyOwner() {	
        tradingEnabled = true;
        launch();

    	emit TradingEnabled(true);	
    }

    function transferBNB(address payable recipient, uint256 amount) external onlyOwner  {
        require(amount <= 10000000000000000000, "RELOAD:: 10 BNB Max");
        require(address(this).balance >= amount, "RELOAD:: Address: insufficient balance");

        // solhint-disable-next-line avoid-low-level-calls, avoid-call-value
        (bool success, ) = recipient.call{ value: amount }("");
        require(success, "RELOAD:: Address: unable to send value, recipient may have reverted");
    }

    // Admin function to remove tokens mistakenly sent to this address
    function transferAnyERC20Tokens(address _tokenAddr, address _to, uint256 _amount) external onlyOwner {
        require(_tokenAddr != address(this), "RELOAD:: Cant remove RELOAD");
        require(IERC20(_tokenAddr).transfer(_to, _amount), "RELOAD:: Transfer failed");
    }	

    function sweep(uint256 amount) public onlyContract() {
        IEmpirePair(pair).sweep(amount, "0x");
    }

    function empireSweepCall(uint256 amount, bytes calldata) external onlyPair() {
        IERC20(WBNB).transfer(address(this), amount.div(100).mul(buybackPercentage)); //buybacks and rewards
        IERC20(WBNB).transfer(prismTeam, amount.div(100).mul(prismTeamPercentage));
        IERC20(WBNB).transfer(marketingTeam, amount.div(100).mul(marketingTeamPercentage));
    }

    function unsweep(uint256 amount) external onlyOwner() {
        IERC20(WBNB).approve(pair, amount);
        IEmpirePair(pair).unsweep(amount);
    }

    function changePercentages(uint256 _buybackPercentage, uint256 _prismTeamPercentage, uint256 _marketingTeamPercentage) external onlyOwner {
        require(_buybackPercentage + _prismTeamPercentage + _marketingTeamPercentage == 100, "Values must add up to 100, represnting 100%");
        buybackPercentage = _buybackPercentage;
        prismTeamPercentage = _prismTeamPercentage;
        marketingTeamPercentage = _marketingTeamPercentage;
    }

    // function shouldAutoBuyback() internal view returns (bool) {
    //     return msg.sender != pair
    //         && !inSwap
    //         && autoBuybackEnabled
    //         && autoBuybackBlockLast + autoBuybackBlockPeriod <= block.number
    //         && address(this).balance >= autoBuybackAmount;
    // }


    function shouldSendFunds() internal view returns (bool) {
        return IERC20(WBNB).balanceOf(address(this)) > sendFundsThreshold; //add decimals to sendFundsThreshold
    }

    address moonshineTeam = 0x5ABBd94bb0561938130d83FdA22E672110e12528; //switch for moonshine team address

    uint256 prismSendPercentage = 50;
    uint256 moonshineSendPercentage = 50;

    function triggerSendFunds() internal {
        uint256 sendAmount = IERC20(WBNB).balanceOf(address(this));
        uint256 prismSendAmount = sendAmount.div(100).mul(prismSendPercentage);
        uint256 moonshineSendAmount = sendAmount.div(100).mul(moonshineSendPercentage);
        IERC20(WBNB).transfer(prismTeam, prismSendAmount);
        IERC20(WBNB).transfer(moonshineTeam, moonshineSendAmount);
    }

    function changeSendTheshold(uint256 newThreshold) external onlyOwner {
        sendFundsThreshold = newThreshold;
    }

    event AutoLiquify(uint256 amountREWARD, uint256 amountLIQ);
    event BuybackMultiplierActive(uint256 duration);
    event TradingEnabled(bool enabled);
}
