// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./BankingNode.sol";
import "./libraries/TransferHelper.sol";

contract BNPLFactory is Ownable {
    mapping(address => address) public operatorToNode;
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
        uint256 bondAmount = 2000000 * 10**18; //2M BNPL to bond a node
        TransferHelper.safeTransferFrom(
            BNPL,
            msg.sender,
            address(this),
            bondAmount
        );
        //one node per operator and base token must be approved
        require(approvedBaseTokens[_baseToken], "invalid base token");
        require(operatorToNode[msg.sender] == address(0));
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
        TransferHelper.safeApprove(BNPL, node, bondAmount);
        BankingNode(node).stake(bondAmount);
        bankingNodesList.push(node);
        operatorToNode[msg.sender] = node;
    }

    //ONLY OWNER FUNCTIONS

    /**
     * Whitelist or Delist a base token for banking nodes(e.g. USDC)
     */
    function whitelistToken(address _baseToken, bool _status)
        external
        onlyOwner
    {
        approvedBaseTokens[_baseToken] = _status;
    }

    /**
     * Get number of current nodes
     */
    function bankingNodeCount() external view returns (uint256) {
        return bankingNodesList.length;
    }
}
