// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BNPLFactory.sol";

/**
 * Modified version of Sushiswap MasterChef.sol contract
 * - Migrator functionality removed
 * - Uses timestamp instead of block number
 * - Adding LP token is public instead of onlyOwner, but requires the LP token to be saved to bnplFactory
 */

contract BNPLRewardsController {
    BNPLFactory public immutable bnplFactory;
    uint256 public startTime; //unix time of start

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accSushiPerShare;
    }

    PoolInfo[] public poolInfo;

    constructor(BNPLFactory _bnplFactory, uint256 _startTime) {
        bnplFactory = _bnplFactory;
        startTime = _startTime;
    }

    //State Changing Functions

    /**
     * Add a pool to be allocated rewards
     * Public function, but requires _lpToken to be saved to bnpl factory
     */
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public {
        require(isValidNode(address(_lpToken)), "Invalid LP Token");
        if (_withUpdate) {
            massUpdatePools();
        }
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
    }

    //Gettor Functions

    /**
     * Return reward multiplier over the given _from to _to timestamps
     * Every month ()
     */
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {}

    /**
     * Get the number of pools
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * View function to get the pending bnpl to harvest
     */

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
