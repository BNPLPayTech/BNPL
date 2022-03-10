// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
//import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";// the imported libraries are affected by the upgradable contract so it needs to change to 

contract BNPLToken is ERC20Upgradeable, AccessControl {

   /*
    constructor() ERC20("BNPL", "BNPL") {
        _mint(msg.sender, 100000000 * (10**18));
    }
    */

    function initialize() public initializer {
        // __ERC20_init --> the replacement of the ERC20 constructor
        __ERC20_init("BNPL", "BNPL");
        _mint(msg.sender, 100000000 * (10**18));
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}


}
