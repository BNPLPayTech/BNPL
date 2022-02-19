// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IAaveIncentivesController.sol";
import "./libraries/UniswapV2Library.sol";
import "./libraries/TransferHelper.sol";

contract BankingNode is ERC20("BNPL USD", "bUSD") {
    address public operator;

    ERC20 public baseToken; //base liquidity token, e.g. USDT or USDC
    uint256 public incrementor;
    uint256 public gracePeriod;
    bool requireKYC;

    address public treasury;

    address public uniswapFactory;
    IAaveIncentivesController public aaveRewardController;
    ILendingPoolAddressesProvider public lendingPoolProvider;
    address public WETH;
    address public immutable bnplFactory;

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

    struct Loan {
        address borrower;
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

    //EVENTS
    event LoanRequest(uint256 loanId);
    event collateralWithdrawn(
        uint256 loanId,
        address collateral,
        uint256 collateralAmount
    );
    event approvedLoan(uint256 loanId, address borrower);
    event loanPaymentMade(uint256 loanId);
    event loanRepaidEarly(uint256 loanId);
    event baseTokenDeposit(address user, uint256 amount);
    event baseTokenWithdrawn(address user, uint256 amount);
    event feesCollected(uint256 operatorFees, uint256 stakerFees);
    event baseTokensDonated(uint256 amount);
    event aaveRewardsCollected(uint256 amount);
    event slashingSale(uint256 bnplSold, uint256 baseTokenRecovered);

    constructor() {
        bnplFactory = msg.sender;
    }

    //STATE CHANGING FUNCTIONS

    /**
     * Called once by the factory at time of deployment
     */
    function initialize(
        address _baseToken,
        IERC20 _BNPL,
        bool _requireKYC,
        address _operator,
        uint256 _gracePeriod,
        address _lendingPoolProvider,
        address _WETH,
        address _aaveDistributionController,
        address _uniswapFactory
    ) external {
        //only to be done by factory
        require(
            msg.sender == bnplFactory,
            "Set up can only be done through BNPL Factory"
        );
        baseToken = ERC20(_baseToken);
        BNPL = _BNPL;
        requireKYC = _requireKYC;
        operator = _operator;
        gracePeriod = _gracePeriod;
        lendingPoolProvider = ILendingPoolAddressesProvider(
            _lendingPoolProvider
        );
        aaveRewardController = IAaveIncentivesController(
            _aaveDistributionController
        );
        WETH = _WETH;
        //decimal check on baseToken and aToken to make sure math logic on future steps
        ILendingPool lendingPool = _getLendingPool();
        ERC20 aToken = ERC20(
            lendingPool.getReserveData(address(baseToken)).aTokenAddress
        );
        uniswapFactory = _uniswapFactory;
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
        address collateral,
        uint256 collateralAmount,
        string memory message
    ) external returns (uint256 requestId) {
        //bank node must be active
        require(
            getBNPLBalance(operator) >= 1500000 * 10**18,
            "Banking node is currently not active"
        );
        requestId = incrementor;
        incrementor++;
        pendingRequests.push(requestId);
        idToLoan[requestId] = Loan(
            msg.sender,
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
        emit LoanRequest(requestId);
    }

    /**
     * Withdraw the collateral from a loan
     */
    function withdrawCollateral(uint256 loanId) public {
        //must be the borrower or operator to withdraw, and loan must be either paid/not initiated
        require(msg.sender == idToLoan[loanId].borrower);
        require(idToLoan[loanId].principalRemaining == 0);

        ILendingPool lendingPool = _getLendingPool();
        lendingPool.withdraw(
            idToLoan[loanId].collateral,
            idToLoan[loanId].collateralAmount,
            idToLoan[loanId].borrower
        );
        //update the amounts
        collateralOwed[idToLoan[loanId].collateral] -= idToLoan[loanId]
            .collateralAmount;
        idToLoan[loanId].collateralAmount = 0;

        emit collateralWithdrawn(
            loanId,
            idToLoan[loanId].collateral,
            idToLoan[loanId].collateralAmount
        );
    }

    /**
     * Collect AAVE rewards and distribute to lenders
     */
    function collectAaveRewards(address[] calldata assets) external {
        uint256 rewardAmount = aaveRewardController.getRewardsBalance(
            assets,
            address(this)
        );
        require(rewardAmount > 0);
        uint256 rewards = aaveRewardController.claimRewards(
            assets,
            rewardAmount,
            address(this)
        );
        _swapToken(
            aaveRewardController.REWARD_TOKEN(),
            address(BNPL),
            0,
            rewards
        );
        emit aaveRewardsCollected(rewardAmount);
    }

    /**
     * Collect the interest earnt on collateral to distribute to stakers
     */
    function collectCollateralFees(address collateral) external {
        //get the aToken address
        ILendingPool lendingPool = _getLendingPool();
        IERC20 aToken = IERC20(
            lendingPool.getReserveData(collateral).aTokenAddress
        );
        uint256 feesAccrued = aToken.balanceOf(address(this)) -
            collateralOwed[collateral];
        //ensure there is collateral to collect
        require(feesAccrued > 0);
        lendingPool.withdraw(collateral, feesAccrued, address(this));

        _swapToken(collateral, address(BNPL), 0, feesAccrued);
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
            //if interest only, check if it was the final payment
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
        ILendingPool lendingPool = _getLendingPool();
        //deposit the tokens into AAVE on behalf of the pool contract, withholding 30% and the interest as baseToken
        uint256 interestWithheld = ((interestPortion * 3) / 10);
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
            _removeCurrentLoan(loanId);
        }
        emit loanPaymentMade(loanId);
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

        uint256 interestWithheld = ((interestAmount * 3) / 10);

        ILendingPool lendingPool = _getLendingPool();
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
        _removeCurrentLoan(loanId);

        emit loanRepaidEarly(loanId);
    }

    /**
     * Converts the baseToken (e.g. USDT) 20% BNPL for stakers, and sends 10% to the Banking Node Operator
     * Slippage set to 0 here as they would be small purchases of BNPL
     */
    function collectFees() external {
        //check there are tokens to swap
        require(
            baseToken.balanceOf(address(this)) > 0,
            "There are no rewards to collect"
        );
        //33% to go to operator as baseToken
        uint256 operatorFees = (baseToken.balanceOf(address(this))) / 3;
        baseToken.transfer(operator, operatorFees);
        //remainder (67%) is traded for staking rewards
        uint256 stakingRewards = _swapToken(
            address(baseToken),
            address(BNPL),
            0,
            baseToken.balanceOf(address(this))
        );
        emit feesCollected(operatorFees, stakingRewards);
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
            getBNPLBalance(operator) >= 1500000 * 10**18,
            "Banking node is currently not active"
        );
        //check the decimals of the
        uint256 decimalAdjust = 1;
        if (baseToken.decimals() != 18) {
            decimalAdjust = 10**(18 - baseToken.decimals());
        }
        //get the amount of tokens to mint
        uint256 what = _amount * decimalAdjust;
        if (totalSupply() != 0) {
            what = (_amount * totalSupply()) / getTotalAssetValue();
        }
        _mint(msg.sender, what);
        //transfer tokens from the user
        TransferHelper.safeTransferFrom(
            address(baseToken),
            msg.sender,
            address(this),
            _amount
        );
        //get the latest lending pool address
        ILendingPool lendingPool = _getLendingPool();
        //deposit the tokens into AAVE on behalf of the pool contract
        baseToken.approve(address(lendingPool), _amount);
        lendingPool.deposit(address(baseToken), _amount, address(this), 0);

        emit baseTokenDeposit(msg.sender, _amount);
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
        ILendingPool lendingPool = _getLendingPool();
        //withdraw the tokens to the user
        lendingPool.withdraw(address(baseToken), _amount, msg.sender);

        emit baseTokenWithdrawn(msg.sender, _amount);
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
        if (msg.sender != bnplFactory && msg.sender != operator) {
            require(
                getBNPLBalance(operator) >= 1500000 * 10**18,
                "Banking node is currently not active"
            );
        }
        address staker = msg.sender;
        //factory initial bond counted as operator
        if (msg.sender == bnplFactory) {
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
     * minOut used for slashing sale, if no collateral, put 0
     */
    function slashLoan(uint256 loanId, uint256 minOut) external {
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
        //sell collateral if any
        if (idToLoan[loanId].collateralAmount != 0) {
            _swapToken(
                idToLoan[loanId].collateral,
                address(baseToken),
                minOut,
                idToLoan[loanId].collateralAmount
            );
            //update collateral info
            idToLoan[loanId].collateralAmount = 0;
        }
    }

    /**
     * Sell the slashing balance for BNPL to give to lenders as aUSD
     */
    function sellSlashed(uint256 minOut) external {
        //ensure there is a balance to sell
        require(slashingBalance > 0);
        //As BNPL-ETH Pair is the most liquid, goes BNPL > ETH > baseToken
        uint256 baseTokenOut = _swapToken(
            address(BNPL),
            address(baseToken),
            minOut,
            slashingBalance
        );
        slashingBalance = 0;
        //deposit the baseToken into AAVE
        ILendingPool lendingPool = _getLendingPool();
        baseToken.approve(address(lendingPool), baseTokenOut);
        lendingPool.deposit(address(baseToken), baseTokenOut, address(this), 0);

        emit slashingSale(slashingBalance, baseTokenOut);
    }

    /**
     * Donate baseToken for when debt is collected post default
     */

    function donateBaseToken(uint256 _amount) external {
        require(_amount > 0);
        baseToken.transferFrom(msg.sender, address(this), _amount);
        //add donation to AAVE
        ILendingPool lendingPool = _getLendingPool();
        baseToken.approve(address(lendingPool), _amount);
        lendingPool.deposit(address(baseToken), _amount, address(this), 0);

        emit baseTokensDonated(_amount);
    }

    //PRIVATE FUNCTIONS

    /**
     * Get the latest AAVE Lending Pool contract
     */

    function _getLendingPool() private view returns (ILendingPool) {
        return ILendingPool(lendingPoolProvider.getLendingPool());
    }

    /**
     * Remove current Loan
     */
    function _removeCurrentLoan(uint256 loanId) private {
        for (uint256 i = 0; i < currentLoans.length; i++) {
            if (loanId == currentLoans[i]) {
                currentLoans[i] = currentLoans[currentLoans.length - 1];
                currentLoans.pop();
            }
        }
    }

    /**
     * Swaps token for BNPL, as BNPL-ETH is the only liquid pair, always goes through x > ETH > x
     */
    function _swapToken(
        address tokenIn,
        address tokenOut,
        uint256 minOut,
        uint256 amountIn
    ) private returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = WETH;
        path[2] = tokenOut;
        uint256[] memory amounts = UniswapV2Library.getAmountsOut(
            uniswapFactory,
            amountIn,
            path
        );
        //ensure slippage
        require(amounts[amounts.length - 1] >= minOut, "Insufficient outout");
        TransferHelper.safeTransfer(
            tokenIn,
            UniswapV2Library.pairFor(uniswapFactory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        return amounts[amounts.length - 1];
    }

    // **** SWAP ****
    // Copied directly from UniswapV2Router
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(uniswapFactory, output, path[i + 2])
                : _to;
            IUniswapV2Pair(
                UniswapV2Library.pairFor(uniswapFactory, input, output)
            ).swap(amount0Out, amount1Out, to, new bytes(0));
        }
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
            getBNPLBalance(operator) >= 1500000 * 10**18,
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

        //add the principal remaining and start the loan
        idToLoan[loanId].principalRemaining = idToLoan[loanId].loanAmount;
        idToLoan[loanId].loanStartTime = block.timestamp;

        //send the funds and update accounts (minus 0.25% origination fee)
        accountsReceiveable += idToLoan[loanId].loanAmount;
        ILendingPool lendingPool = _getLendingPool();
        lendingPool.withdraw(
            address(baseToken),
            (idToLoan[loanId].loanAmount * 199) / 200,
            idToLoan[loanId].borrower
        );
        //send the origination fee to treasury and agent
        lendingPool.withdraw(
            address(baseToken),
            (idToLoan[loanId].loanAmount * 1) / 400,
            treasury
        );

        emit approvedLoan(loanId, idToLoan[loanId].borrower);
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
    function whitelistAddresses(address whitelistAddition) external {
        require(address(msg.sender) == operator);
        whitelistedAddresses[whitelistAddition] = true;
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
    function getUnbondingBalance(address user) external view returns (uint256) {
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
        ILendingPool lendingPool = _getLendingPool();
        IERC20 aToken = IERC20(
            lendingPool.getReserveData(address(baseToken)).aTokenAddress
        );
        return accountsReceiveable + aToken.balanceOf(address(this));
    }

    /**
     * Get number of pending requests
     */
    function getPendingRequestCount() external view returns (uint256) {
        return pendingRequests.length;
    }

    /**
     * Get the current number of active loans
     */
    function getCurrentLoansCount() external view returns (uint256) {
        return currentLoans.length;
    }
}
