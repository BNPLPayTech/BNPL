// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./BankingNode.sol";

contract BNPLFactory is Ownable {
    mapping(address => address) activeNodes;
    address[] public bankingNodesList;
    IERC20 public immutable BNPL;
    address public immutable lendingPoolAddressesProvider;
    address public sushiRouter;
    mapping(address => bool) approvedBaseTokens;

    //Constuctor
    constructor(
        IERC20 _BNPL,
        address _lendingPoolAddressesProvider,
        address _sushiRouter
    ) {
        BNPL = _BNPL;
        lendingPoolAddressesProvider = _lendingPoolAddressesProvider;
        sushiRouter = _sushiRouter;
    }

    //STATE CHANGING FUNCTIONS

    /**
     * Creates a new banking node
     */
    function createNewNode(
        ERC20 _baseToken,
        bool _requireKYC,
        uint256 _gracePeriod,
        uint256 _agentFee
    ) external returns (address node) {
        //collect the BNPL
        BNPL.transferFrom(msg.sender, address(this), 2000000 * 10**18);
        //require base token to be approve
        require(approvedBaseTokens[address(_baseToken)]);
        //create a new node
        bytes memory bytecode = type(BankingNode).creationCode;
        bytes32 salt = keccak256(
            abi.encodePacked(_baseToken, _requireKYC, _gracePeriod)
        );
        assembly {
            node := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        BankingNode(node).initialize(
            _baseToken,
            BNPL,
            _requireKYC,
            msg.sender,
            _gracePeriod,
            lendingPoolAddressesProvider,
            sushiRouter,
            _agentFee
        );
        BNPL.approve(node, 2000000 * 10**18);
        BankingNode(node).stake(2000000 * 10**18);
        bankingNodesList.push(msg.sender);
        activeNodes[msg.sender] = node;
    }

    //ONLY OWNER FUNCTIONS

    /**
     * Collects the initiation fees for the protocol
     */
    function withdrawFees(address _rewardToken) external onlyOwner {
        IERC20 rewards = IERC20(_rewardToken);
        uint256 amount = rewards.balanceOf(address(this));
        rewards.transfer(msg.sender, amount);
    }

    /**
     * Whitelist a base token for banking nodes(e.g. USDC)
     */
    function whitelistToken(address _baseToken) external onlyOwner {
        approvedBaseTokens[_baseToken] = true;
    }

    //GETTOR FUNCTIONS

    /**
     * Get node address of a operator
     */
    function getNode(address _operator) external view returns (address) {
        return activeNodes[_operator];
    }

    /**
     * Get number of current nodes
     */
    function bankingNodeCount() external view returns (uint256) {
        return bankingNodesList.length;
    }
}
