// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IUniswapV2Router02.sol";

contract BankingNode is ERC20("BNPL USD", "bUSD") {
    address public operator;
    ERC20 public baseToken; //base liquidity token, e.g. USDT or USDC
    uint256 public incrementor;
    uint256 public gracePeriod;
    bool requireKYC;

    //For agent fees
    uint256 public agentFeePercent; //% * 10,000 of interest given to agent , maximum as 5% (500)
    mapping(address => uint256) agentFeePending;
    uint256 public agentFees;
    address public treasury;

    ILendingPoolAddressesProvider public lendingPoolProvider;
    IUniswapV2Router02 public router;
    address public immutable factory;

    //For loans
    mapping(uint256 => Loan) idToLoan;
    uint256[] public pendingRequests;
    uint256[] public currentLoans;
    uint256[] public defaultedLoans;

    //For Staking, Slashing and Balances
    uint256 public accountsReceiveable;
    mapping(address => bool) public whitelistedAddresses;
    mapping(address => uint256) public stakingShares;
    mapping(address => uint256) lastStakeTime;
    mapping(address => uint256) unbondingShares;

    //For Collateral
    mapping(address => uint256) collateralOwed;

    uint256 public unbondingAmount;
    uint256 public totalUnbondingShares;
    uint256 public totalStakingShares;
    uint256 public slashingBalance;
    IERC20 public BNPL;

    uint256 public totalBaseTokenDonations;
    uint256 public totalBNPLDonations;

    struct Loan {
        address borrower;
        address agent;
        bool interestOnly; //interest only or principal + interest
        uint256 loanStartTime; //unix timestamp of start
        uint256 loanAmount;
        uint256 paymentInterval; //unix interval of payment (e.g. monthly = 2,628,000)
        uint256 interestRate; //interest rate * 10000, e.g., 10%: 0.1 * 10000 = 1000
        uint256 numberOfPayments;
        uint256 principalRemaining;
        uint256 paymentsMade;
        address collateral;
        uint256 collateralAmount;
    }

    constructor() {
        factory = msg.sender;
    }

    //STATE CHANGING FUNCTIONS

    /**
     * Called once by the factory at time of deployment
     */
    function initialize(
        ERC20 _baseToken,
        IERC20 _BNPL,
        bool _requireKYC,
        address _operator,
        uint256 _gracePeriod,
        address _lendingPoolProvider,
        address _sushiRouter,
        uint256 _agentFeePercent
    ) external {
        //only to be done by factory
        require(
            msg.sender == factory,
            "Set up can only be done through BNPL Factory"
        );
        //max agentFee is 5%
        require(_agentFeePercent <= 500);
        baseToken = _baseToken;
        BNPL = _BNPL;
        requireKYC = _requireKYC;
        operator = _operator;
        gracePeriod = _gracePeriod;
        agentFeePercent = _agentFeePercent;
        lendingPoolProvider = ILendingPoolAddressesProvider(
            _lendingPoolProvider
        );
        router = IUniswapV2Router02(_sushiRouter);
        //decimal check on baseToken and aToken to make sure math logic on future steps
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        ERC20 aToken = ERC20(
            lendingPool.getReserveData(address(baseToken)).aTokenAddress
        );
        treasury = address(0x27a99802FC48b57670846AbFFf5F2DcDE8a6fC29);
        require(baseToken.decimals() == aToken.decimals());
    }

    /**
     * Request a loan from the banking node
     */
    function requestLoan(
        uint256 loanAmount,
        uint256 paymentInterval,
        uint256 numberOfPayments,
        uint256 interestRate,
        bool interestOnly,
        address agent, //set to operator if no agent
        address collateral,
        uint256 collateralAmount,
        string memory message
    ) external returns (uint256 requestId) {
        //bank node must be active
        require(
            getBNPLBalance(operator) >= 2000000 * 10**18,
            "Banking node is currently not active"
        );
        requestId = incrementor;
        incrementor++;
        pendingRequests.push(requestId);
        idToLoan[requestId] = Loan(
            msg.sender,
            agent,
            interestOnly,
            0,
            loanAmount,
            paymentInterval, //interval of payments (e.g. Monthly)
            interestRate, //annualized interest rate
            numberOfPayments,
            0, //initalize principalRemaining to 0
            0, //intialize paymentsMade to 0
            collateral,
            collateralAmount
        );
        //emit the message

        //post the collateral if any
        if (collateralAmount > 0) {
            //update the collateral owed (interest accrued on collateral is given to lend)
            collateralOwed[collateral] += collateralAmount;
            //collect the collateral
            IERC20 bond = IERC20(collateral);
            bond.transferFrom(msg.sender, address(this), collateralAmount);
            //deposit the collateral in AAVE to accrue interest
            ILendingPool lendingPool = ILendingPool(
                lendingPoolProvider.getLendingPool()
            );
            bond.approve(address(lendingPool), collateralAmount);
            lendingPool.deposit(
                address(bond),
                collateralAmount,
                address(this),
                0
            );
        }
    }

    /**
     * Withdraw the collateral from a loan
     */
    function withdrawCollateral(uint256 loanId) public {
        //must be the borrower or operator to withdraw, and loan must be either paid/not initiated
        require(msg.sender == idToLoan[loanId].borrower);
        require(idToLoan[loanId].principalRemaining == 0);

        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        lendingPool.withdraw(
            idToLoan[loanId].collateral,
            idToLoan[loanId].collateralAmount,
            idToLoan[loanId].borrower
        );
        //update the amounts
        collateralOwed[idToLoan[loanId].collateral] -= idToLoan[loanId]
            .collateralAmount;
        idToLoan[loanId].collateralAmount = 0;
    }

    /**
     * Collect the interest earnt on collateral to distribute to stakers
     */
    function collectCollateralFees(address collateral) external {
        //get the aToken address
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        IERC20 aToken = IERC20(
            lendingPool.getReserveData(collateral).aTokenAddress
        );
        uint256 feesAccrued = aToken.balanceOf(address(this)) -
            collateralOwed[collateral];
        //ensure there is collateral to collect
        require(feesAccrued > 0);
        lendingPool.withdraw(collateral, feesAccrued, address(this));
        //convert the fees to BNPL to give to stakers
        uint256 deadline = block.timestamp;
        //as BNPL-ETH is the most liquid pair, always set path to collateral > ETH > BNPL
        address[] memory path = new address[](3);
        path[0] = collateral;
        path[1] = router.WETH();
        path[2] = address(BNPL);
        //swap for BNPL (0 slippage as small amounts)
        router.swapExactTokensForTokens(
            feesAccrued,
            0,
            path,
            address(this),
            deadline
        );
    }

    /*
     * Make a loan payment
     */
    function makeLoanPayment(uint256 loanId) external {
        //check the loan has outstanding payments
        require(
            idToLoan[loanId].principalRemaining != 0,
            "No payments are required for this loan"
        );
        uint256 paymentAmount = getNextPayment(loanId);
        uint256 interestRatePerPeriod = (idToLoan[loanId].interestRate *
            idToLoan[loanId].paymentInterval) / 31536000;
        uint256 interestPortion = (idToLoan[loanId].principalRemaining *
            interestRatePerPeriod) / 10000;
        //reduce accounts receiveable and loan principal if principal + interest payment
        if (!idToLoan[loanId].interestOnly) {
            uint256 principalPortion = paymentAmount - interestPortion;
            idToLoan[loanId].principalRemaining -= principalPortion;
            accountsReceiveable -= principalPortion;
        } else {
            //check if it was the final payment
            if (
                idToLoan[loanId].paymentsMade + 1 ==
                idToLoan[loanId].numberOfPayments
            ) {
                accountsReceiveable -= idToLoan[loanId].principalRemaining;
                idToLoan[loanId].principalRemaining = 0;
            }
        }
        //make payment
        baseToken.transferFrom(msg.sender, address(this), paymentAmount);
        //get the latest lending pool address
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        //deposit the tokens into AAVE on behalf of the pool contract, withholding 30% and agent fees of the interest as baseToken
        uint256 agentFeeAccrued = (interestPortion * agentFeePercent) / 10000;
        agentFees += agentFeeAccrued;
        agentFeePending[idToLoan[loanId].agent] += agentFeeAccrued;
        uint256 interestWithheld = ((interestPortion * 3) / 10) +
            agentFeeAccrued;
        baseToken.approve(
            address(lendingPool),
            paymentAmount - interestWithheld
        );
        lendingPool.deposit(
            address(baseToken),
            paymentAmount - interestWithheld,
            address(this),
            0
        );
        //increment the loan status
        idToLoan[loanId].paymentsMade++;
        //check if it was the final payment
        if (
            idToLoan[loanId].paymentsMade == idToLoan[loanId].numberOfPayments
        ) {
            //delete from current loans
            for (uint256 i = 0; i < currentLoans.length; i++) {
                if (loanId == currentLoans[i]) {
                    currentLoans[i] = currentLoans[currentLoans.length - 1];
                    currentLoans.pop();
                }
            }
        }
    }

    /**
     * Repay remaining balance to save on interest cost
     * Payment amount is remaining principal + 1 period of interest
     */
    function repayEarly(uint256 loanId) external {
        //check the loan has outstanding payments
        require(
            idToLoan[loanId].principalRemaining != 0,
            "No payments are required for this loan"
        );
        uint256 interestRatePerPeriod = (idToLoan[loanId].interestRate *
            idToLoan[loanId].paymentInterval) / 31536000;
        //make a payment of remaining principal + 1 period of interest
        uint256 interestAmount = (idToLoan[loanId].principalRemaining *
            (interestRatePerPeriod)) / 10000;
        uint256 paymentAmount = (idToLoan[loanId].principalRemaining +
            interestAmount);
        //make payment
        baseToken.transferFrom(msg.sender, address(this), paymentAmount);

        //agent, operator and staking fees
        uint256 agentFeeAccrued = (interestAmount * agentFeePercent) / 10000;
        agentFees += agentFeeAccrued;
        agentFeePending[idToLoan[loanId].agent] += agentFeeAccrued;
        uint256 interestWithheld = ((interestAmount * 3) / 10) +
            agentFeeAccrued;

        //get the latest lending pool address
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        //deposit the tokens into AAVE on behalf of the pool contract
        baseToken.approve(
            address(lendingPool),
            paymentAmount - interestWithheld
        );
        lendingPool.deposit(
            address(baseToken),
            paymentAmount - interestWithheld,
            address(this),
            0
        );
        //update accounts
        accountsReceiveable -= idToLoan[loanId].principalRemaining;
        idToLoan[loanId].principalRemaining = 0;
        //increment the loan status to final and remove from current loans array
        idToLoan[loanId].paymentsMade = idToLoan[loanId].numberOfPayments;
        for (uint256 i = 0; i < currentLoans.length; i++) {
            if (loanId == currentLoans[i]) {
                currentLoans[i] = currentLoans[currentLoans.length - 1];
                currentLoans.pop();
            }
        }
    }

    /**
     * Converts the baseToken (e.g. USDT) 20% BNPL for stakers, and sends 10% to the Banking Node Operator
     * Slippage set to 0 here as they would be small purchases of BNPL
     */
    function collectFees() external {
        //check there are tokens to swap
        require(baseToken.balanceOf(address(this)) - agentFees > 0);
        uint256 deadline = block.timestamp;
        address[] memory path = new address[](3);
        //As BNPL-ETH Pair is most liquid, goes baseToken > WETH > BNPL
        path[0] = address(baseToken);
        path[1] = router.WETH();
        path[2] = address(BNPL);
        //33% to go to operator as baseToken
        uint256 operatorFees = (baseToken.balanceOf(address(this)) -
            agentFees) / 3;
        uint256 stakingRewards = ((baseToken.balanceOf(address(this)) -
            agentFees) * 2) / 3;
        baseToken.transfer(operator, operatorFees);
        //remainder (66%) to go to stakers
        baseToken.approve(address(router), stakingRewards);
        router.swapExactTokensForTokens(
            stakingRewards,
            0,
            path,
            address(this),
            deadline
        );
    }

    /**
     * Deposit liquidity to the banking node
     */
    function deposit(uint256 _amount) public {
        //KYC requirement / whitelist check
        if (requireKYC) {
            require(
                whitelistedAddresses[msg.sender],
                "You must first complete the KYC process"
            );
        }
        //bank node must be active
        require(
            getBNPLBalance(operator) >= 2000000 * 10**18,
            "Banking node is currently not active"
        );
        //check the decimals of the
        uint256 decimalAdjust = 1;
        if (baseToken.decimals() != 18) {
            decimalAdjust = 10**(18 - baseToken.decimals());
        }
        //get the amount of tokens to mint
        uint256 what = 0;
        if (totalSupply() == 0) {
            what = _amount * decimalAdjust;
            _mint(msg.sender, what);
        } else {
            what = (_amount * totalSupply()) / getTotalAssetValue();
            _mint(msg.sender, what);
        }
        //transfer tokens from the user
        baseToken.transferFrom(msg.sender, address(this), _amount);
        //get the latest lending pool address
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        //deposit the tokens into AAVE on behalf of the pool contract
        baseToken.approve(address(lendingPool), _amount);
        lendingPool.deposit(address(baseToken), _amount, address(this), 0);
    }

    /**
     * Withdraw liquidity from the banking node
     * To avoid need to decimal adjust, input _amount is in USDT(or equiv) to withdraw
     * , not BNPL USD to burn
     */
    function withdraw(uint256 _amount) external {
        uint256 what = (_amount * totalSupply()) / getTotalAssetValue();
        _burn(msg.sender, what);
        //get the latest lending pool address;
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        //withdraw the tokens to the user
        lendingPool.withdraw(address(baseToken), _amount, msg.sender);
    }

    /**
     * Stake BNPL into a node
     */
    function stake(uint256 _amount) external {
        //require a non-zero deposit
        require(_amount > 0, "Cannot deposit 0");
        //KYC requirement / whitelist check
        if (requireKYC) {
            require(
                whitelistedAddresses[msg.sender],
                "Your address is has not completed KYC requirements"
            );
        }
        //require bankingNode to be active (operator must have 2M BNPL staked)
        if (msg.sender != factory && msg.sender != operator) {
            require(
                getBNPLBalance(operator) >= 2000000 * 10**18,
                "Banking node is currently not active"
            );
        }
        address staker = msg.sender;
        //factory initial bond counted as operator
        if (msg.sender == factory) {
            staker = operator;
        }
        //set the time of the stake
        lastStakeTime[staker] = block.timestamp;
        //calcualte the number of shares to give
        uint256 what = 0;
        if (totalStakingShares == 0) {
            what = _amount;
        } else {
            what =
                (_amount * totalStakingShares) /
                (BNPL.balanceOf(address(this)) -
                    unbondingAmount -
                    slashingBalance);
        }
        //collect the BNPL
        BNPL.transferFrom(msg.sender, address(this), _amount);
        //issue the shares
        stakingShares[staker] += what;
        totalStakingShares += what;
    }

    /**
     * Unbond BNPL from a node, input is the number shares (sBNPL)
     * Requires a 7 day unbond to prevent frontrun of slashing events or interest repayments
     */
    function initiateUnstake(uint256 _amount) external {
        //operator cannot withdraw unless there are no active loans
        if (msg.sender == operator) {
            require(
                currentLoans.length == 0,
                "Operator can not unbond if there are active loans"
            );
        }
        //require its a non-zero withdraw
        require(_amount > 0, "Cannot unbond 0");
        //require the user has enough
        require(
            stakingShares[msg.sender] >= _amount,
            "You do not have a large enough balance"
        );
        //get the amount of BNPL to issue back
        uint256 what = (_amount *
            (BNPL.balanceOf(address(this)) -
                unbondingAmount -
                slashingBalance)) / totalStakingShares;
        //subtract the number of shares of BNPL from the user
        stakingShares[msg.sender] -= _amount;
        totalStakingShares -= _amount;
        //initiate as 1:1 for unbonding shares with BNPL sent
        uint256 newUnbondingShares = what;
        //update amount if there is a pool of unbonding
        if (unbondingAmount != 0) {
            newUnbondingShares =
                (what * totalUnbondingShares) /
                unbondingAmount;
        }
        //add the balance to their unbonding
        unbondingShares[msg.sender] += newUnbondingShares;
        totalUnbondingShares += newUnbondingShares;
        unbondingAmount += what;
    }

    /**
     * Withdraw BNPL from a bond once unbond period ends
     */
    function unstake() external {
        //require a 45,000 block gap (~7 day) gap since the last deposit
        require(block.timestamp >= lastStakeTime[msg.sender] + 45000);
        uint256 what = unbondingShares[msg.sender];
        //transfer the tokens to user
        BNPL.transfer(msg.sender, what);
        //update the balances
        unbondingShares[msg.sender] = 0;
        unbondingAmount -= what;
    }

    /**
     * Declare a loan defaulted and slash the loan
     * Can be called by anyone
     * Move BNPL to a slashing balance, to be market sold in seperate function to prevent minOut failure
     */
    function slashLoan(uint256 loanId) external {
        //require that the given due date and grace period have expired
        require(block.timestamp > getNextDueDate(loanId) + gracePeriod);
        //check that the loan has remaining payments
        require(idToLoan[loanId].principalRemaining != 0);
        //get slash % with 10,000 multiplier
        uint256 slashPercent = (10000 * idToLoan[loanId].principalRemaining) /
            getTotalAssetValue();
        uint256 unbondingSlash = (unbondingAmount * slashPercent) / 10000;
        uint256 stakingSlash = ((BNPL.balanceOf(address(this)) -
            slashingBalance -
            unbondingAmount) * slashPercent) / 10000;
        //slash both staked and bonded balances
        slashingBalance += unbondingSlash + stakingSlash;
        unbondingAmount -= unbondingSlash;
        stakingSlash -= stakingSlash;
        defaultedLoans.push(loanId);
    }

    /**
     * Sell the slashing balance for BNPL to give to lenders as aUSD
     */
    function sellSlashed(uint256 minOut) external {
        //ensure there is a balance to sell
        require(slashingBalance > 0);
        //As BNPL-ETH Pair is the most liquid, goes BNPL > WETH > baseToken
        address[] memory path = new address[](3);
        path[0] = address(BNPL);
        path[1] = router.WETH();
        path[2] = address(baseToken);
        uint256 deadline = block.timestamp;
        BNPL.approve(address(router), slashingBalance);
        uint256[] memory amounts = router.swapExactTokensForTokens(
            slashingBalance,
            minOut,
            path,
            address(this),
            deadline
        );
        slashingBalance = 0;
        uint256 baseTokenOut = amounts[amounts.length - 1];
        //deposit the baseToken into AAVE
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        baseToken.approve(address(lendingPool), baseTokenOut);
        lendingPool.deposit(address(baseToken), baseTokenOut, address(this), 0);
    }

    /**
     * Collect fees as an agent
     */
    function collectAgentFees() external {
        //require there are fees to collect
        require(agentFeePending[msg.sender] > 0);
        baseToken.transfer(msg.sender, agentFeePending[msg.sender]);
        //update balances
        agentFees -= agentFeePending[msg.sender];
        agentFeePending[msg.sender] = 0;
    }

    /**
     * Donate baseToken for when debt is collected post default
     */

    function donateBaseToken(uint256 _amount) external {
        require(_amount > 0);
        baseToken.transferFrom(msg.sender, address(this), _amount);
        //add donation to AAVE
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        baseToken.approve(address(lendingPool), _amount);
        lendingPool.deposit(address(baseToken), _amount, address(this), 0);
    }

    //OPERATOR ONLY FUNCTIONS

    /**
     * Approve a pending loan request
     * Ensures collateral amount has been posted to prevent front run withdrawal
     */
    function approveLoan(uint256 loanId, uint256 requiredCollateralAmount)
        external
    {
        require(msg.sender == operator);
        //check node is active
        require(
            getBNPLBalance(operator) >= 2000000 * 10**18,
            "Banking node is currently not active"
        );
        //ensure the loan was never started
        require(idToLoan[loanId].loanStartTime == 0);
        //ensure the collateral is still posted
        require(idToLoan[loanId].collateralAmount == requiredCollateralAmount);

        //remove from loanRequests and add loan to current loans
        for (uint256 i = 0; i < pendingRequests.length; i++) {
            if (loanId == pendingRequests[i]) {
                pendingRequests[i] = pendingRequests[
                    pendingRequests.length - 1
                ];
                pendingRequests.pop();
            }
        }
        currentLoans.push(loanId);

        //add the principal remianing and start the loan
        idToLoan[loanId].principalRemaining = idToLoan[loanId].loanAmount;
        idToLoan[loanId].loanStartTime = block.timestamp;

        //send the funds and update accounts (minus 0.25% origination fee)
        accountsReceiveable += idToLoan[loanId].loanAmount;
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        lendingPool.withdraw(
            address(baseToken),
            (idToLoan[loanId].loanAmount * 199) / 200,
            idToLoan[loanId].borrower
        );
        //send the origination fee to factory
        lendingPool.withdraw(
            address(baseToken),
            (idToLoan[loanId].loanAmount * 1) / 200,
            treasury
        );
    }

    /**
     * Used to reject all current pending loan requests
     */
    function clearPendingLoans() external {
        require(address(msg.sender) == operator);
        pendingRequests = new uint256[](0);
    }

    /**
     * Whitelist a given list of addresses
     */
    function whitelistAddresses(address[] memory whitelistAddition) external {
        require(address(msg.sender) == operator);
        for (uint256 i = 0; i < whitelistAddition.length; i++) {
            whitelistedAddresses[whitelistAddition[i]] = true;
        }
    }

    //VIEW ONLY FUNCTIONS

    /**
     * Gets the given users balance in baseToken
     */
    function getBaseTokenBalance(address user) public view returns (uint256) {
        if (totalSupply() == 0) {
            return 0;
        }
        return (balanceOf(user) * getTotalAssetValue()) / totalSupply();
    }

    /**
     * Get the value of the BNPL staked by user
     */
    function getBNPLBalance(address user) public view returns (uint256 what) {
        uint256 balance = stakingShares[user];
        if (balance == 0 || totalStakingShares == 0) {
            what = 0;
        } else {
            what =
                (balance *
                    (BNPL.balanceOf(address(this)) -
                        unbondingAmount -
                        slashingBalance)) /
                totalStakingShares;
        }
    }

    /**
     * Get the amount a user has that is being unbonded
     */
    function getUnbondingBalance(address user) public view returns (uint256) {
        return (unbondingShares[user] * unbondingAmount) / totalUnbondingShares;
    }

    /**
     * Gets the next payment amount due
     * If loan is completed or not approved, returns 0
     */
    function getNextPayment(uint256 loanId) public view returns (uint256) {
        //if loan is completed or not approved, return 0
        if (idToLoan[loanId].principalRemaining == 0) {
            return 0;
        }
        // interest rate per period (31536000 seconds in a year)
        uint256 interestRatePerPeriod = (idToLoan[loanId].interestRate *
            idToLoan[loanId].paymentInterval) / 31536000;
        //check if it is an interest only loan
        if (idToLoan[loanId].interestOnly) {
            //check if its the final payment
            if (
                idToLoan[loanId].paymentsMade + 1 ==
                idToLoan[loanId].numberOfPayments
            ) {
                //if final payment, then principal + final interest amount
                return
                    idToLoan[loanId].loanAmount +
                    ((idToLoan[loanId].loanAmount * interestRatePerPeriod) /
                        10000);
            } else {
                //if not final payment, simple interest amount
                return
                    (idToLoan[loanId].loanAmount * interestRatePerPeriod) /
                    10000;
            }
        } else {
            //principal + interest payments, payment given by the formula:
            //p : principal
            //i : interest rate per period
            //d : duration
            // p * (i * (1+i) ** d) / ((1+i) ** d - 1)
            uint256 numerator = idToLoan[loanId].loanAmount *
                interestRatePerPeriod *
                (10000 + interestRatePerPeriod) **
                    idToLoan[loanId].numberOfPayments;
            uint256 denominator = (10000 + interestRatePerPeriod) **
                idToLoan[loanId].numberOfPayments -
                (10**(4 * idToLoan[loanId].numberOfPayments));
            uint256 adjustment = 10000;
            return numerator / (denominator * adjustment);
        }
    }

    /**
     * Gets the next due date (unix timestamp) of a given loan
     * Returns 0 if loan is not a current loan or loan has alreadyt been paid
     */
    function getNextDueDate(uint256 loanId) public view returns (uint256) {
        //check that the loan has been approved and loan is not completed;
        if (idToLoan[loanId].principalRemaining == 0) {
            return 0;
        }
        return
            idToLoan[loanId].loanStartTime +
            ((idToLoan[loanId].paymentsMade + 1) *
                idToLoan[loanId].paymentInterval);
    }

    /**
     * Get the total assets (accounts receivable + aToken balance)
     * Only principal owed is counted as accounts receivable
     */
    function getTotalAssetValue() public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        IERC20 aToken = IERC20(
            lendingPool.getReserveData(address(baseToken)).aTokenAddress
        );
        uint256 liquidBalance = aToken.balanceOf(address(this));
        return accountsReceiveable + liquidBalance;
    }

    /**
     * Get the liquid assets of the Node
     */
    function getLiquidAssets() public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(
            lendingPoolProvider.getLendingPool()
        );
        IERC20 aToken = IERC20(
            lendingPool.getReserveData(address(baseToken)).aTokenAddress
        );
        return aToken.balanceOf(address(this));
    }

    /**
     * Get number of pending requests
     */
    function getPendingRequestCount() public view returns (uint256) {
        return pendingRequests.length;
    }

    /**
     * Get the loanIds of pending requests
     */
    function getPendingLoanRequests() public view returns (uint256[] memory) {
        return pendingRequests;
    }

    function getCurrentLoansCount() public view returns (uint256) {
        return currentLoans.length;
    }

    function getCurrentLoans() public view returns (uint256[] memory) {
        return currentLoans;
    }

    /**
     * Get the node operators pending rewards
     */
    function getPendingOperatorRewards() external view returns (uint256) {
        return (baseToken.balanceOf(address(this)) - agentFees) / 3;
    }

    /**
     * Get the pending staker rewards
     */
    function getPendingStakerRewards() external view returns (uint256) {
        return ((baseToken.balanceOf(address(this)) - agentFees) * 2) / 3;
    }

    /**
     * Get the amount of fees for a given agent
     */
    function getAgentFee(address agent) public view returns (uint256) {
        return agentFeePending[agent];
    }
}
