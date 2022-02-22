from scripts.helper import get_account, approve_erc20, get_account2
from scripts.deploy import (
    create_node,
    whitelist_usdt,
    whitelist_token,
    deploy_bnpl_factory,
    deploy_bnpl_token,
    add_lp,
    deploy_rewards_controller,
)
import pytest
import time
from brownie import (
    BNPLFactory,
    BNPLToken,
    BankingNode,
    Contract,
    config,
    network,
    interface,
)
from web3 import Web3

BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT

"""
"""


def test_rewards_contract():

    account = get_account()
    account2 = get_account2()

    # Deploy BNPL Token
    bnpl = deploy_bnpl_token()

    # First deploy BNPL Factory and set up 2 nodes
    # Deploy factory
    factory = deploy_bnpl_factory(
        BNPLToken[-1], config["networks"][network.show_active()]["weth"]
    )

    # Whitelist USDT and BUSD for the factory
    busd_address = config["networks"][network.show_active()]["busd"]
    whitelist_usdt(factory)
    whitelist_token(factory, busd_address)
