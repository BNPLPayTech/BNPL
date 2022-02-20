// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BankingNode.sol";
import "./libraries/TransferHelper.sol";

contract BNPLFactory is Ownable {
    mapping(address => address) operatorToNode;
    address[] public bankingNodesList;
    address public immutable BNPL;
    address public immutable lendingPoolAddressesProvider;
    address public immutable WETH;
    address public immutable uniswapFactory;
    mapping(address => bool) approvedBaseTokens;
    address public aaveDistributionController;

    //Constuctor
    constructor(
        address _BNPL,
        address _lendingPoolAddressesProvider,
        address _WETH,
        address _aaveDistributionController,
        address _uniswapFactory
    ) {
        BNPL = _BNPL;
        lendingPoolAddressesProvider = _lendingPoolAddressesProvider;
        WETH = _WETH;
        aaveDistributionController = _aaveDistributionController;
        uniswapFactory = _uniswapFactory;
    }

    //STATE CHANGING FUNCTIONS

    /**
     * Creates a new banking node
     */
    function createNewNode(
        address _baseToken,
        bool _requireKYC,
        uint256 _gracePeriod
    ) external returns (address node) {
        //collect the 2M BNPL
        TransferHelper.safeTransferFrom(
            BNPL,
            msg.sender,
            address(this),
            2000000 * 10**18
        );
        //require base token to be approve
        require(approvedBaseTokens[_baseToken]);
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
            WETH,
            aaveDistributionController,
            uniswapFactory
        );
        TransferHelper.safeApprove(BNPL, node, 2000000 * 10**18);
        BankingNode(node).stake(2000000 * 10**18);
        bankingNodesList.push(msg.sender);
        operatorToNode[msg.sender] = node;
    }

    //ONLY OWNER FUNCTIONS

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
        return operatorToNode[_operator];
    }

    /**
     * Get number of current nodes
     */
    function bankingNodeCount() external view returns (uint256) {
        return bankingNodesList.length;
    }
}
