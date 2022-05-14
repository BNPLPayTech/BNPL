import pytest
from brownie import (
    BankingNode,
    BNPLFactory,
    BNPLFactoryDEMO,
    Contract,
    config,
    network,
    interface,
)
from web3 import Web3
from scripts.deploy_helpers import (
    create_node, 
    deploy_bnpl_token, 
    deploy_bnpl_factory, 
    whitelist_usdt,
    upgrade_factory
)
from scripts.helper import approve_erc20, get_account

BOND_AMOUNT = Web3.toWei(2000000, "ether")


def test_factory_upgradeability():
    """
    Validates the upgradeable implementation of BNPLFactory by deploying the contracts, upgrading 
    to a new implementation and calling a function only found in the second implementation.

    This is the logical flow of the Upgradeable Proxy Pattern from OpenZeppelin:

    owner --> ProxyAdmin --> Proxy --> implementation_v0
                                   |
                                   --> implementation_v1
                                   |
                                   --> implementation_v2
    """
    account = get_account()

    USDT = interface.ERC20(config["networks"][network.show_active()]["usdt"])
    BNPL = deploy_bnpl_token()
    FACTORY = deploy_bnpl_factory(BNPL, account)


    print("Verifying that a node can be created and behaviour is correct against BNPLFactory_V0")
    whitelist_usdt(FACTORY)
    approve_erc20(BOND_AMOUNT, FACTORY, BNPL, account)

    create_node(FACTORY, account, USDT.address)
    node_address = FACTORY.operatorToNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)

    print("Verifying some functions against the newly created node")
    assert node.getBNPLBalance(account) == BOND_AMOUNT

    # Upgrading the Factory to a new implementation
    FACTORY_V2 = upgrade_factory(BNPLFactoryDEMO, account)

    # The following function is unique to the new implementation. We are calling the same proxy as before, 
    # but the proxy is now forwarding / delegating the calls to the new implementation.
    a_great_number = 420
    FACTORY_V2.thisIsANewFunction(a_great_number, {"from": account})
    assert FACTORY_V2.iDontExistInOriginalContract() == a_great_number


