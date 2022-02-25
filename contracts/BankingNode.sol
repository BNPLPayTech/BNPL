// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IAaveIncentivesController.sol";
import "./libraries/UniswapV2Library.sol";
import "./libraries/TransferHelper.sol";

//CUSTOM ERRORS

//occurs when trying to do privledged functions
error InvalidUser(address requiredUser);
//occurs when users try to add funds if node operator hasn't maintaioned enough pledged BNPL
error NodeInactive();
//occurs when trying to interact without being KYC's (if node requires it)
error KYCNotApproved();
//occurs when trying to pay loans that are completed or not started
error NoPrincipalRemaining();
//occurs when trying to swap/deposit/withdraw a zero
error ZeroInput();
//occurs if interest rate, loanAmount, or paymentInterval or is applied as 0
error InvalidLoanInput();
//occurs if trying to apply for a loan with >5 year loan length
error MaximumLoanDurationExceeded();
//occurs if user tries to withdraw collateral while loan is still ongoing
error LoanStillOngoing();
//edge case occurence if all BNPL is slashed, but there are still BNPL shares
error DonationRequired();
//occurs if operator tries to unstake while there are active loans
error ActiveLoansOngoing();
//occurs when trying to withdraw too much funds
error InsufficientBalance();
//occurs during swaps, if amount received is lower than minOut (slippage tolerance exceeded)
error InsufficentOutput();
//occurs if trying to approve a loan that has already started
error LoanAlreadyStarted();
//occurs if trying to approve a loan without enough collateral posted
error InsufficientCollateral();
//occurs when trying to slash a loan that is not yet considered defaulted
error LoanNotExpired();
//occurs is trying to slash an already slashed loan
error LoanAlreadySlashed();
//occurs if trying to withdraw staked BNPL where 7 day unbonding hasnt passed
error LoanStillUnbonding();

contract BankingNode is ERC20("BNPL USD", "bUSD") {
    //Node specific variables
    address public operator;
    address public baseToken; //base liquidity token, e.g. USDT or USDC
    uint256 public gracePeriod;
    bool public requireKYC;

    //variables used for swaps, private to reduce contract size
    address private uniswapFactory;
    address private WETH;
    uint256 private incrementor;

    //constants set by factory
    address public BNPL;
    ILendingPoolAddressesProvider public lendingPoolProvider;
    address public immutable bnplFactory;
    //used by treasury can be private
    IAaveIncentivesController private aaveRewardController;
    address private treasury;

    //For loans
    mapping(uint256 => Loan) public idToLoan;
    uint256[] public pendingRequests;
    uint256[] public currentLoans;
    mapping(uint256 => uint256) defaultedLoans;
    uint256 public defaultedLoanCount;

    //For Staking, Slashing and Balances
    uint256 public accountsReceiveable;
    mapping(address => bool) public whitelistedAddresses;
    mapping(address => uint256) public unbondTime;
    mapping(uint256 => address) public loanToAgent;
    uint256 public slashingBalance;
    //can be private as there is a getter function for staking balance
    mapping(address => uint256) private stakingShares;
    uint256 private totalStakingShares;

    uint256 public unbondingAmount;
    //can be private as there is getter function for unbonding balance
    uint256 private totalUnbondingShares;
    mapping(address => uint256) private unbondingShares;

    //For Collateral in loans
    mapping(address => uint256) public collateralOwed;

    struct Loan {
        address borrower;
        bool interestOnly; //interest only or principal + interest
        uint256 loanStartTime; //unix timestamp of start
        uint256 loanAmount;
        uint256 paymentInterval; //unix interval of payment (e.g. monthly = 2,628,000)
        uint256 interestRate; //interest rate per peiod * 10000, e.g., 10% on a 12 month loan = : 0.1 * 10000 / 12 = 83
        uint256 numberOfPayments;
        uint256 principalRemaining;
        uint256 paymentsMade;
        address collateral;
        uint256 collateralAmount;
        bool isSlashed;
    }

    //EVENTS
    event LoanRequest(uint256 loanId);
    event collateralWithdrawn(
        uint256 loanId,
        address collateral,
        uint256 collateralAmount
    );
    event approvedLoan(uint256 loanId);
    event loanPaymentMade(uint256 loanId);
    event loanRepaidEarly(uint256 loanId);
    event baseTokenDeposit(address user, uint256 amount);
    event baseTokenWithdrawn(address user, uint256 amount);
    event feesCollected(uint256 operatorFees, uint256 stakerFees);
    event baseTokensDonated(uint256 amount);
    event aaveRewardsCollected(uint256 amount);
    event loanSlashed(uint256 loanId);
    event slashingSale(uint256 bnplSold, uint256 baseTokenRecovered);
    event bnplStaked(address user, uint256 bnplWithdrawn);
    event unbondingInitiated(address user, uint256 unbondAmount);
    event bnplWithdrawn(address user, uint256 bnplWithdrawn);

    constructor() {
        bnplFactory = msg.sender;
    }

    // MODIFIERS

    /**
     * Ensure a node is active for deposit, stake, and loan approval functions
     * Require KYC is also batched in
     */
    modifier ensureNodeActive() {
        address _operator = operator;
        if (msg.sender != bnplFactory && msg.sender != _operator) {
            if (getBNPLBalance(_operator) < 0x13DA329B6336471800000) {
                revert NodeInactive();
            }
            if (requireKYC && whitelistedAddresses[msg.sender] == false) {
                revert KYCNotApproved();
            }
        }
        _;
    }

    /**
     * Ensure that the loan has principal to be paid
     */
    modifier ensurePrincipalRemaining(uint256 loanId) {
        if (idToLoan[loanId].principalRemaining == 0) {
            revert NoPrincipalRemaining();
        }
        _;
    }

    /**
     * For operator only functions
     */
    modifier operatorOnly() {
        address _operator = operator;
        if (msg.sender != _operator) {
            revert InvalidUser(_operator);
        }
        _;
    }

    /**
     * Requires input value to be non-zero
     */
    modifier nonZeroInput(uint256 input) {
        if (input == 0) {
            revert ZeroInput();
        }
        _;
    }

    //STATE CHANGING FUNCTIONS

    /**
     * Called once by the factory at time of deployment
     */
    function initialize(
        address _baseToken,
        address _BNPL,
        bool _requireKYC,
        address _operator,
        uint256 _gracePeriod,
        address _lendingPoolProvider,
        address _WETH,
        address _aaveDistributionController,
        address _uniswapFactory
    ) external {
        //only to be done by factory, no need for error msgs in here as not used by users
        require(msg.sender == bnplFactory);
        baseToken = _baseToken;
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
        uniswapFactory = _uniswapFactory;
        treasury = address(0x27a99802FC48b57670846AbFFf5F2DcDE8a6fC29);
        //decimal check on baseToken and aToken to make sure math logic on future steps
        require(
            ERC20(baseToken).decimals() ==
                ERC20(_getLendingPool().getReserveData(baseToken).aTokenAddress)
                    .decimals()
        );
    }

    /**
     * Request a loan from the banking node
     * Saves the loan with the operator able to approve or reject
     * Can post collateral if chosen, collateral accepted is anything that is accepted by aave
     */
    function requestLoan(
        uint256 loanAmount,
        uint256 paymentInterval,
        uint256 numberOfPayments,
        uint256 interestRate,
        bool interestOnly,
        address collateral,
        uint256 collateralAmount,
        address agent,
        string memory message
    ) external ensureNodeActive returns (uint256 requestId) {
        if (loanAmount < 1000 || paymentInterval == 0 || interestRate == 0) {
            revert InvalidLoanInput();
        }
        //157,680,000 seconds in 5 years
        if (paymentInterval * numberOfPayments > 157680000) {
            revert MaximumLoanDurationExceeded();
        }
        requestId = incrementor;
        incrementor++;
        pendingRequests.push(requestId);
        idToLoan[requestId] = Loan(
            msg.sender, //set borrower
            interestOnly,
            0, //start time initiated to 0
            loanAmount,
            paymentInterval, //interval of payments (e.g. Monthly)
            interestRate, //annualized interest rate per period * 10000 (e.g. 12 month loan 10% = 83)
            numberOfPayments,
            0, //initalize principalRemaining to 0
            0, //intialize paymentsMade to 0
            collateral,
            collateralAmount,
            false
        );

        //post the collateral if any
        if (collateralAmount > 0) {
            //update the collateral owed (interest accrued on collateral is given to lend)
            collateralOwed[collateral] += collateralAmount;
            TransferHelper.safeTransferFrom(
                collateral,
                msg.sender,
                address(this),
                collateralAmount
            );
            //deposit the collateral in AAVE to accrue interest
            _depositToLendingPool(collateral, collateralAmount);
        }
        //save the agent of the loan
        loanToAgent[requestId] = agent;

        emit LoanRequest(requestId);
    }

    /**
     * Withdraw the collateral from a loan
     * Loan must have no principal remaining (not approved, or payments finsihed)
     */
    function withdrawCollateral(uint256 loanId) external {
        Loan storage loan = idToLoan[loanId];
        address collateral = loan.collateral;
        uint256 amount = loan.collateralAmount;

        //must be the borrower or operator to withdraw, and loan must be either paid/not initiated
        if (msg.sender != loan.borrower) {
            revert InvalidUser(loan.borrower);
        }
        if (loan.principalRemaining > 0) {
            revert LoanStillOngoing();
        }
        //no need to check if loan is slashed as collateral amont set to 0 on slashing

        _withdrawFromLendingPool(collateral, amount, loan.borrower);

        //update the amounts
        collateralOwed[collateral] -= amount;
        loan.collateralAmount = 0;

        emit collateralWithdrawn(loanId, collateral, amount);
    }

    /**
     * Collect AAVE rewards to be sent to the treasury
     */
    function collectAaveRewards(address[] calldata assets) external {
        uint256 rewardAmount = aaveRewardController.getUserUnclaimedRewards(
            address(this)
        );
        address _treasuy = treasury;
        if (rewardAmount == 0) {
            revert ZeroInput();
        }
        //claim rewards to the treasury
        uint256 rewards = aaveRewardController.claimRewards(
            assets,
            rewardAmount,
            _treasuy
        );

        emit aaveRewardsCollected(rewardAmount);
    }

    /**
     * Collect the interest earnt on collateral posted to distribute to stakers
     */
    function collectCollateralFees(address collateral) external {
        //get the aToken address
        ILendingPool lendingPool = _getLendingPool();
        address _bnpl = BNPL;
        uint256 feesAccrued = IERC20(
            lendingPool.getReserveData(collateral).aTokenAddress
        ).balanceOf(address(this)) - collateralOwed[collateral];
        //ensure there is collateral to collect inside of _swap
        lendingPool.withdraw(collateral, feesAccrued, address(this));
        //no slippage for small swaps
        _swapToken(collateral, _bnpl, 0, feesAccrued);
    }

    /*
     * Make a loan payment
     */
    function makeLoanPayment(uint256 loanId)
        external
        ensurePrincipalRemaining(loanId)
    {
        Loan storage loan = idToLoan[loanId];
        uint256 paymentAmount = getNextPayment(loanId);
        uint256 interestPortion = (loan.principalRemaining *
            loan.interestRate) / 10000;
        address _baseToken = baseToken;
        loan.paymentsMade++;
        //reduce accounts receiveable and loan principal if principal + interest payment
        bool finalPayment = loan.paymentsMade == loan.numberOfPayments;

        if (!loan.interestOnly) {
            uint256 principalPortion = paymentAmount - interestPortion;
            loan.principalRemaining -= principalPortion;
            accountsReceiveable -= principalPortion;
        } else {
            //interest only, principal change only on final payment
            if (finalPayment) {
                accountsReceiveable -= loan.principalRemaining;
                loan.principalRemaining = 0;
            }
        }
        //make payment
        TransferHelper.safeTransferFrom(
            _baseToken,
            msg.sender,
            address(this),
            paymentAmount
        );
        //deposit the tokens into AAVE on behalf of the pool contract, withholding 30% and the interest as baseToken
        _depositToLendingPool(
            _baseToken,
            paymentAmount - ((interestPortion * 3) / 10)
        );
        //remove if final payment
        if (finalPayment) {
            _removeCurrentLoan(loanId);
        }
        //increment the loan status

        emit loanPaymentMade(loanId);
    }

    /**
     * Repay remaining balance to save on interest cost
     * Payment amount is remaining principal + 1 period of interest
     */
    function repayEarly(uint256 loanId)
        external
        ensurePrincipalRemaining(loanId)
    {
        Loan storage loan = idToLoan[loanId];
        uint256 principalLeft = loan.principalRemaining;
        //make a payment of remaining principal + 1 period of interest
        uint256 interestAmount = (principalLeft * loan.interestRate) / 10000;
        uint256 paymentAmount = principalLeft + interestAmount;
        address _baseToken = baseToken;
        //make payment
        TransferHelper.safeTransferFrom(
            _baseToken,
            msg.sender,
            address(this),
            paymentAmount
        );
        //deposit withholding 30% of the interest as fees
        _depositToLendingPool(
            _baseToken,
            paymentAmount - ((interestAmount * 3) / 10)
        );

        //update accounts
        accountsReceiveable -= principalLeft;
        loan.principalRemaining = 0;
        //increment the loan status to final and remove from current loans array
        loan.paymentsMade = loan.numberOfPayments;
        _removeCurrentLoan(loanId);

        emit loanRepaidEarly(loanId);
    }

    /**
     * Converts the baseToken (e.g. USDT) 20% BNPL for stakers, and sends 10% to the Banking Node Operator
     * Slippage set to 0 here as they would be small purchases of BNPL
     */
    function collectFees() external {
        //requirement check for nonzero inside of _swap
        //33% to go to operator as baseToken
        address _baseToken = baseToken;
        address _bnpl = BNPL;
        address _operator = operator;
        uint256 operatorFees = IERC20(_baseToken).balanceOf(address(this)) / 3;
        TransferHelper.safeTransfer(_baseToken, _operator, operatorFees);
        //remainder (67%) is traded for staking rewards
        //no need for slippage on small trade
        uint256 stakingRewards = _swapToken(
            _baseToken,
            _bnpl,
            0,
            IERC20(_baseToken).balanceOf(address(this))
        );
        emit feesCollected(operatorFees, stakingRewards);
    }

    /**
     * Deposit liquidity to the banking node in the baseToken (e.g. usdt) specified
     * Mints tokens, with check on decimals of base tokens
     */
    function deposit(uint256 _amount)
        external
        ensureNodeActive
        nonZeroInput(_amount)
    {
        //check the decimals of the baseTokens
        address _baseToken = baseToken;
        uint256 decimalAdjust = 1;
        uint256 tokenDecimals = ERC20(_baseToken).decimals();
        if (tokenDecimals != 18) {
            decimalAdjust = 10**(18 - tokenDecimals);
        }
        //get the amount of tokens to mint
        uint256 what = _amount * decimalAdjust;
        if (totalSupply() != 0) {
            //no need to decimal adjust here as total asset value adjusts
            //unable to deposit if getTotalAssetValue() == 0 and totalSupply() != 0, but this
            //should never occur as defaults will get slashed for some base token recovery
            what = (_amount * totalSupply()) / getTotalAssetValue();
        }
        //transfer tokens from the user and mint
        TransferHelper.safeTransferFrom(
            _baseToken,
            msg.sender,
            address(this),
            _amount
        );
        _mint(msg.sender, what);

        _depositToLendingPool(_baseToken, _amount);

        emit baseTokenDeposit(msg.sender, _amount);
    }

    /**
     * Withdraw liquidity from the banking node
     * To avoid need to decimal adjust, input _amount is in USDT(or equiv) to withdraw
     * , not BNPL USD to burn
     */
    function withdraw(uint256 _amount) external nonZeroInput(_amount) {
        if (getBaseTokenBalance(msg.sender) < _amount) {
            revert InsufficientBalance();
        }
        //safe div, if _amount > 0, asset value always >0;
        uint256 what = (_amount * totalSupply()) / getTotalAssetValue();
        address _baseToken = baseToken;
        _burn(msg.sender, what);
        _withdrawFromLendingPool(_baseToken, _amount, msg.sender);

        emit baseTokenWithdrawn(msg.sender, _amount);
    }

    /**
     * Stake BNPL into a node
     */
    function stake(uint256 _amount)
        external
        ensureNodeActive
        nonZeroInput(_amount)
    {
        address staker = msg.sender;
        //factory initial bond counted as operator
        if (msg.sender == bnplFactory) {
            staker = operator;
        }
        //calcualte the number of shares to give
        uint256 what = _amount;
        uint256 _totalStakingShares = totalStakingShares;
        if (_totalStakingShares > 0) {
            //edge case - if totalStakingShares != 0, but all bnpl has been slashed:
            //node will require a donation to work again
            uint256 totalStakedBNPL = getStakedBNPL();
            if (totalStakedBNPL == 0) {
                revert DonationRequired();
            }
            what = (_amount * _totalStakingShares) / totalStakedBNPL;
        }
        //collect the BNPL
        address _bnpl = BNPL;
        TransferHelper.safeTransferFrom(
            _bnpl,
            msg.sender,
            address(this),
            _amount
        );
        //issue the shares
        stakingShares[staker] += what;
        totalStakingShares += what;

        emit bnplStaked(msg.sender, _amount);
    }

    /**
     * Unbond BNPL from a node, input is the number shares (sBNPL)
     * Requires a 7 day unbond to prevent frontrun of slashing events or interest repayments
     * Operator can not unstake unless there are no loans active
     */
    function initiateUnstake(uint256 _amount) external nonZeroInput(_amount) {
        //operator cannot withdraw unless there are no active loans
        address _operator = operator;
        if (msg.sender == _operator && currentLoans.length > 0) {
            revert ActiveLoansOngoing();
        }
        //require the user has enough
        if (stakingShares[msg.sender] < _amount) {
            revert InsufficientBalance();
        }
        //set the time of the unbond
        unbondTime[msg.sender] = block.timestamp;
        //get the amount of BNPL to issue back
        //safe div: if user staking shares >0, totalStakingShares always > 0
        uint256 what = (_amount * getStakedBNPL()) / totalStakingShares;
        //subtract the number of shares of BNPL from the user
        stakingShares[msg.sender] -= _amount;
        totalStakingShares -= _amount;
        //initiate as 1:1 for unbonding shares with BNPL sent
        uint256 newUnbondingShares = what;
        uint256 _unbondingAmount = unbondingAmount;
        //update amount if there is a pool of unbonding
        if (_unbondingAmount != 0) {
            newUnbondingShares =
                (what * totalUnbondingShares) /
                _unbondingAmount;
        }
        //add the balance to their unbonding
        unbondingShares[msg.sender] += newUnbondingShares;
        totalUnbondingShares += newUnbondingShares;
        unbondingAmount += what;

        emit unbondingInitiated(msg.sender, _amount);
    }

    /**
     * Withdraw BNPL from a bond once unbond period ends
     */
    function unstake() external {
        uint256 userAmount = unbondingShares[msg.sender];
        if (userAmount == 0) {
            revert ZeroInput();
        }
        //require a 604,800 second gap (7 day) gap since unbond initiated
        if (block.timestamp < unbondTime[msg.sender] + 604800) {
            revert LoanStillUnbonding();
        }
        //safe div: if user amount > 0, then totalUnbondingShares always > 0
        uint256 what = (userAmount * unbondingAmount) / totalUnbondingShares;
        //transfer the tokens to user
        TransferHelper.safeTransfer(BNPL, msg.sender, what);
        //update the balances
        unbondingShares[msg.sender] = 0;
        unbondingAmount -= what;

        emit bnplWithdrawn(msg.sender, what);
    }

    /**
     * Declare a loan defaulted and slash the loan
     * Can be called by anyone
     * Move BNPL to a slashing balance, to be market sold in seperate function to prevent minOut failure
     * minOut used for slashing sale, if no collateral, put 0
     */
    function slashLoan(uint256 loanId, uint256 minOut)
        external
        ensurePrincipalRemaining(loanId)
    {
        //require that the given due date and grace period have expired
        if (block.timestamp <= getNextDueDate(loanId) + gracePeriod) {
            revert LoanNotExpired();
        }

        Loan storage loan = idToLoan[loanId];
        //check loan is not slashed already
        if (loan.isSlashed) {
            revert LoanAlreadySlashed();
        }
        //get slash % with 10,000 multiplier
        uint256 principalLost = loan.principalRemaining;
        //safe div: totalassetvalue > 0 if principal > 0
        uint256 slashPercent = (1e12 * principalLost) / getTotalAssetValue();
        uint256 unbondingSlash = (unbondingAmount * slashPercent) / 1e12;
        uint256 stakingSlash = (getStakedBNPL() * slashPercent) / 1e12;
        //slash both staked and bonded balances
        accountsReceiveable -= principalLost;
        slashingBalance += unbondingSlash + stakingSlash;
        unbondingAmount -= unbondingSlash;
        loan.isSlashed = true;
        //remove from current loans and add to defualt loans
        _removeCurrentLoan(loanId);
        defaultedLoans[defaultedLoanCount] = loanId;
        defaultedLoanCount++;
        //withdraw and sell collateral if any
        uint256 collateralPosted = loan.collateralAmount;
        if (collateralPosted > 0) {
            address collateral = loan.collateral;
            address _baseToken = baseToken;
            _withdrawFromLendingPool(
                collateral,
                collateralPosted,
                address(this)
            );
            uint256 baseTokenOut = _swapToken(
                collateral,
                _baseToken,
                minOut,
                collateralPosted
            );
            _depositToLendingPool(_baseToken, baseTokenOut);
            //update collateral info
            collateralOwed[collateral] -= collateralPosted;
            loan.collateralAmount = 0;
        }
        emit loanSlashed(loanId);
    }

    /**
     * Sell the slashing balance of BNPL to give to lenders as aUSD
     * Slashing sale moved to seperate function to simplify logic with minOut
     */
    function sellSlashed(uint256 minOut) external {
        //ensure there is a balance to sell (moved to inside _swap)
        //As BNPL-ETH Pair is the most liquid, goes BNPL > ETH > baseToken
        address _baseToken = baseToken;
        address _bnpl = BNPL;
        uint256 _slashingBalance = slashingBalance;
        uint256 baseTokenOut = _swapToken(
            _bnpl,
            _baseToken,
            minOut,
            _slashingBalance
        );
        slashingBalance = 0;
        //deposit the baseToken into AAVE
        _depositToLendingPool(_baseToken, baseTokenOut);

        emit slashingSale(_slashingBalance, baseTokenOut);
    }

    /**
     * Donate baseToken for when debt is collected post default
     * BNPL can be donated by simply sending it to the contract
     */
    function donateBaseToken(uint256 _amount) external nonZeroInput(_amount) {
        address _baseToken = baseToken;

        TransferHelper.safeTransferFrom(
            _baseToken,
            msg.sender,
            address(this),
            _amount
        );
        //add donation to AAVE
        _depositToLendingPool(_baseToken, _amount);

        emit baseTokensDonated(_amount);
    }

    //OPERATOR ONLY FUNCTIONS

    /**
     * Approve a pending loan request
     * Ensures collateral amount has been posted to prevent front run withdrawal
     */
    function approveLoan(uint256 loanId, uint256 requiredCollateralAmount)
        external
        operatorOnly
    {
        Loan storage loan = idToLoan[loanId];
        address _operator = operator;
        if (getBNPLBalance(_operator) < 0x13DA329B6336471800000) {
            revert NodeInactive();
        }
        //ensure the loan was never started
        if (loan.loanStartTime > 0) {
            revert LoanAlreadyStarted();
        }
        if (loan.collateralAmount < requiredCollateralAmount) {
            revert InsufficientCollateral();
        }

        //remove from loanRequests and add loan to current loans
        uint256 length = pendingRequests.length;
        for (uint256 i = 0; i < length; i++) {
            if (loanId == pendingRequests[i]) {
                pendingRequests[i] = pendingRequests[length - 1];
                pendingRequests.pop();
                break;
            }
        }
        currentLoans.push(loanId);

        //add the principal remaining and start the loan
        uint256 loanSize = loan.loanAmount;
        loan.principalRemaining = loanSize;
        loan.loanStartTime = block.timestamp;
        accountsReceiveable += loanSize;
        //send the funds and update accounts (minus 0.75% origination fee)
        ILendingPool lendingPool = _getLendingPool();
        address _baseToken = baseToken;
        lendingPool.withdraw(_baseToken, (loanSize * 397) / 400, loan.borrower);
        //send the 0.5% origination fee to treasury and agent
        lendingPool.withdraw(_baseToken, loanSize / 200, treasury);
        lendingPool.withdraw(_baseToken, loanSize / 400, loanToAgent[loanId]);

        emit approvedLoan(loanId);
    }

    /**
     * Used to reject all current pending loan requests
     */
    function clearPendingLoans() external operatorOnly {
        pendingRequests = new uint256[](0);
    }

    /**
     * Whitelist or delist a given list of addresses
     * Only relevant on KYC nodes
     */
    function whitelistAddresses(
        address[] memory whitelistAddition,
        bool _status
    ) external operatorOnly {
        uint256 length = whitelistAddition.length;
        for (uint256 i; i < length; i++) {
            whitelistedAddresses[whitelistAddition[i]] = _status;
        }
    }

    /**
     * Updates the KYC Status of a node
     */
    function setKYC(bool _newStatus) external operatorOnly {
        requireKYC = _newStatus;
    }

    //PRIVATE FUNCTIONS

    /**
     * Deposit token onto AAVE lending pool
     */
    function _depositToLendingPool(address tokenIn, uint256 amountIn) private {
        TransferHelper.safeApprove(
            tokenIn,
            address(_getLendingPool()),
            amountIn
        );
        _getLendingPool().deposit(tokenIn, amountIn, address(this), 0);
    }

    /**
     * Withdraw token from AAVE lending pool
     */
    function _withdrawFromLendingPool(
        address tokenOut,
        uint256 amountOut,
        address to
    ) private nonZeroInput(amountOut) {
        _getLendingPool().withdraw(tokenOut, amountOut, to);
    }

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
                return;
            }
        }
    }

    /**
     * Swaps token for BNPL, as BNPL-ETH is the only liquid pair, always goes through tokenIn > ETH > tokenOut
     */
    function _swapToken(
        address tokenIn,
        address tokenOut,
        uint256 minOut,
        uint256 amountIn
    ) private returns (uint256 tokenOutput) {
        if (amountIn == 0) {
            revert ZeroInput();
        }
        address _uniswapFactory = uniswapFactory;
        address _weth = WETH;
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = _weth;
        path[2] = tokenOut;
        uint256[] memory amounts = UniswapV2Library.getAmountsOut(
            _uniswapFactory,
            amountIn,
            path
        );
        //ensure slippage
        tokenOutput = amounts[2];
        if (minOut > tokenOutput) {
            revert InsufficentOutput();
        }
        TransferHelper.safeTransfer(
            tokenIn,
            UniswapV2Library.pairFor(_uniswapFactory, tokenIn, _weth),
            amountIn
        );
        // **** SWAP ****
        // Copied directly from UniswapV2Router with minor changes as set path length = 3
        // requires the initial amount to have already been sent to the first pair
        for (uint256 i; i < 2; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < 1
                ? UniswapV2Library.pairFor(_uniswapFactory, output, path[2])
                : address(this);
            IUniswapV2Pair(
                UniswapV2Library.pairFor(_uniswapFactory, input, output)
            ).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    //VIEW ONLY FUNCTIONS

    /**
     * Get the total BNPL in the Staking account
     * = the total BNPL - unbonding balance - slashing balance
     */
    function getStakedBNPL() public view returns (uint256) {
        return
            IERC20(BNPL).balanceOf(address(this)) -
            unbondingAmount -
            slashingBalance;
    }

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
        uint256 _totalStakingShares = totalStakingShares;
        if (balance == 0 || _totalStakingShares == 0) {
            what = 0;
        } else {
            what = (balance * getStakedBNPL()) / _totalStakingShares;
        }
    }

    /**
     * Get the amount a user has that is being unbonded
     */
    function getUnbondingBalance(address user) external view returns (uint256) {
        uint256 _totalUnbondingShares;
        if (_totalUnbondingShares == 0) {
            return 0;
        }
        return
            (unbondingShares[user] * unbondingAmount) / _totalUnbondingShares;
    }

    /**
     * Gets the next payment amount due
     * If loan is completed or not approved, returns 0
     */
    function getNextPayment(uint256 loanId) public view returns (uint256) {
        //if loan is completed or not approved, return 0
        Loan storage loan = idToLoan[loanId];
        if (loan.principalRemaining == 0) {
            return 0;
        }
        uint256 _interestRate = loan.interestRate;
        uint256 _loanAmount = loan.loanAmount;
        uint256 _numberOfPayments = loan.numberOfPayments;
        //check if it is an interest only loan
        if (loan.interestOnly) {
            //check if its the final payment
            if (loan.paymentsMade + 1 == _numberOfPayments) {
                //if final payment, then principal + final interest amount
                return _loanAmount + ((_loanAmount * _interestRate) / 10000);
            } else {
                //if not final payment, simple interest amount
                return (_loanAmount * _interestRate) / 10000;
            }
        } else {
            //principal + interest payments, payment given by the formula:
            //p : principal
            //i : interest rate per period
            //d : duration
            // p * (i * (1+i) ** d) / ((1+i) ** d - 1)
            uint256 numerator = _loanAmount *
                _interestRate *
                (10000 + _interestRate)**_numberOfPayments;
            uint256 denominator = (10000 + _interestRate)**_numberOfPayments -
                (10**(4 * _numberOfPayments));
            return numerator / (denominator * 10000);
        }
    }

    /**
     * Gets the next due date (unix timestamp) of a given loan
     * Returns 0 if loan is not a current loan or loan has already been paid
     */
    function getNextDueDate(uint256 loanId) public view returns (uint256) {
        //check that the loan has been approved and loan is not completed;
        Loan storage loan = idToLoan[loanId];
        if (loan.principalRemaining == 0) {
            return 0;
        }
        return
            loan.loanStartTime +
            ((loan.paymentsMade + 1) * loan.paymentInterval);
    }

    /**
     * Get the total assets (accounts receivable + aToken balance)
     * Only principal owed is counted as accounts receivable
     */
    function getTotalAssetValue() public view returns (uint256) {
        return
            IERC20(_getLendingPool().getReserveData(baseToken).aTokenAddress)
                .balanceOf(address(this)) + accountsReceiveable;
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
