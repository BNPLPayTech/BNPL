// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BNPLFactory.sol";
import "./interfaces/IBankingNode.sol";

/**
 * Modified version of Sushiswap MasterChef.sol contract
 * - Migrator functionality removed
 * - Uses timestamp instead of block number
 * - Adding LP token is public instead of onlyOwner, but requires the LP token to be saved to bnplFactory
 * - Alloc points are based on amount of BNPL staked to the node
 * - Minting functions for BNPL not possible, they are transfered from treasury instead
 / - Removed safeMath as using solidity ^0.8.0
 */

contract BNPLRewardsController is Ownable {
    BNPLFactory public immutable bnplFactory;

    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    address public immutable bnpl;
    address public immutable treasury;
    uint256 public bnplPerSecond; //initiated to
    uint256 public immutable startTime; //unix time of start
    uint256 public endTime; //3 years of emmisions
    uint256 public totalAllocPoint = 0; //total allocation points, no need for max alloc points as max is the supply of BNPL
    PoolInfo[] public poolInfo;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IBankingNode lpToken; //changed from IERC20
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accBnplPerShare;
    }

    //EVENTS
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        BNPLFactory _bnplFactory,
        address _bnpl,
        address _treasury,
        uint256 _startTime
    ) {
        bnplFactory = _bnplFactory;
        startTime = _startTime;
        endTime = _startTime + 94608000; //94,608,000 seconds in 3 years
        bnpl = _bnpl;
        treasury = _treasury;
        bnplPerSecond = (425000000 * 10**18) / 94608000; //425,000,000 BNPL to be distributed over 3 years
    }

    //State Changing Functions

    /**
     * Add a pool to be allocated rewards
     * Modified from MasterChef to be public, but requires the pool to be saved in BNPL Factory
     * _allocPoints to be based on the number of bnpl staked in the given node
     */
    function add(IBankingNode _lpToken, bool _withUpdate) public {
        require(isValidNode(address(_lpToken)), "Invalid LP Token");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 _allocPoint = _lpToken.getStakedBNPL();
        checkForDuplicate(_lpToken);

        uint256 lastRewardTime = block.timestamp > startTime
            ? block.timestamp
            : startTime;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accBnplPerShare: 0
            })
        );
    }

    /**
     * Update the given pool's bnpl allocation point, changed from Masterchef to be:
     * - Public, but sets _allocPoints to the number of bnpl staked to a node
     */
    function set(uint256 _pid) external {
        //get the new _allocPoints
        uint256 _allocPoint = poolInfo[_pid].lpToken.getStakedBNPL();

        massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    /**
     * Update reward variables for all pools
     */
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * Update reward variables for a pool given pool to be up-to-date
     */
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime == block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(
            pool.lastRewardTime,
            block.timestamp
        );
        uint256 bnplReward = (multiplier * bnplPerSecond * pool.allocPoint) /
            totalAllocPoint;

        //instead of minting, simply transfers the tokens from the owner
        //ensure owner has approved the tokens to the contract
        TransferHelper.safeTransferFrom(
            bnpl,
            treasury,
            address(this),
            bnplReward
        );

        pool.accBnplPerShare += (bnplReward * 1e12) / lpSupply;
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * Deposit LP tokens from the user
     */
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
    }

    /**
     * Withdraw LP tokens from the user
     */
    function withdraw() public {}

    function harvestAll() public {}

    function emergencyWithdraw() public {}

    function safeOXDTransfer() internal {}

    //OWNER ONLY FUNCTIONS

    /**
     * Update the BNPL per second emmisions
     */
    function updateRewards(uint256 _bnplPerSecond) public onlyOwner {
        bnplPerSecond = _bnplPerSecond;
    }

    //Gettor Functions

    /**
     * Return reward multiplier over the given _from to _to timestamps
     */
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        //get the start time to be minimum
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime || _from >= endTime) {
            return 0;
        } else if (_to <= endTime) {
            return _to - _from;
        } else {
            return endTime - _from;
        }
    }

    /**
     * Get the number of pools
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * Check if the pool already exists
     */
    function checkForDuplicate(IBankingNode _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 i = 0; i < length; i++) {
            require(poolInfo[i].lpToken != _lpToken, "Pool already exists");
        }
    }

    /**
     * View function to get the pending bnpl to harvest
     * Modifed by removing safe math
     */
    function pendingBnpl(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBnplPerShare = pool.accBnplPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 bnplReward = (multiplier *
                bnplPerSecond *
                pool.allocPoint) / totalAllocPoint;
            accBnplPerShare += (bnplReward * 1e12) / lpSupply;
        }
        return (user.amount * accBnplPerShare) / (1e12) - user.rewardDebt;
    }

    /**
     * Checks if a given address is a valid banking node registered
     */
    function isValidNode(address _bankingNode) private view returns (bool) {
        uint256 length = bnplFactory.bankingNodeCount();
        for (uint256 i; i < length; i++) {
            if (bnplFactory.bankingNodesList(i) == _bankingNode) {
                return true;
            }
        }
        return false;
    }
}
