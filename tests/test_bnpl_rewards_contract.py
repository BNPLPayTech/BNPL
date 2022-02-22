from scripts.helper import get_account, approve_erc20, get_account2
from scripts.deploy import (
    create_node,
    whitelist_usdt,
    whitelist_token,
    deploy_bnpl_factory,
    deploy_bnpl_token,
    deploy_rewards_controller,
)
import pytest
import time
from brownie import (
    BNPLToken,
    BankingNode,
    Contract,
    config,
    network,
)
from web3 import Web3

BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT
BUSD_AMOUNT = 100 * 10**18  # 100 BUSD

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
    usdt_address = config["networks"][network.show_active()]["usdt"]
    busd_address = config["networks"][network.show_active()]["busd"]
    whitelist_usdt(factory)
    whitelist_token(factory, busd_address)

    # Deploy node with account 1
    approve_erc20(BOND_AMOUNT * 2, factory, bnpl, account)
    create_node(factory, account, usdt_address)

    # Check that only one node per account
    with pytest.raises(Exception):
        create_node(factory, account, usdt_address)

    # Send bnpl to account 2 for bonding
    bnpl.transfer(account2, BOND_AMOUNT * 1.1, {"from": account})

    # Deploy node with account 2
    approve_erc20(BOND_AMOUNT * 1.1, factory, bnpl, account2)
    create_node(factory, account2, busd_address)

    # Add 100 USDT and 100 BUSD into nodes

    usdt_node_address = factory.operatorToNode(account)
    busd_node_address = factory.operatorToNode(account2)

    usdt_node = Contract.from_abi(BankingNode._name, usdt_node_address, BankingNode.abi)
    busd_node = Contract.from_abi(BankingNode._name, busd_node_address, BankingNode.abi)

    approve_erc20(USDT_AMOUNT * 2.1, usdt_node_address, usdt_address, account2)
    approve_erc20(BUSD_AMOUNT * 1.1, busd_node_address, busd_address, account2)

    # Depositing double the USDT to ensure it doenst impact reward weights
    tx = usdt_node.deposit(USDT_AMOUNT, {"from": account2})
    tx.wait(1)
    tx = usdt_node.deposit(USDT_AMOUNT, {"from": account2})
    tx.wait(1)
    tx = busd_node.deposit(BUSD_AMOUNT, {"from": account2})
    tx.wait(1)

    # Check we got the tokens, should get 100 of each token
    expected_usdt_node_tokens = BUSD_AMOUNT * 2
    expected_busd_node_tokens = BUSD_AMOUNT

    assert (
        usdt_node.balanceOf(account2) >= expected_usdt_node_tokens * 0.99
        and usdt_node.balanceOf(account2) <= expected_usdt_node_tokens * 1.01
    )
    assert (
        busd_node.balanceOf(account2) >= expected_busd_node_tokens * 0.99
        and busd_node.balanceOf(account2) <= expected_busd_node_tokens * 1.01
    )

    # Stake a further 2M BNPL into busd_node to check that rewards will be double for this pool
    approve_erc20(BOND_AMOUNT * 1.1, busd_node_address, bnpl, account)
    busd_node.stake(BOND_AMOUNT, {"from": account})

    # Deploy the rewards controller
    start_time = time.time()
    rewards_controller = deploy_rewards_controller(factory, bnpl, start_time)

    # Approve the rewards controller from the treasury
    approve_erc20(BOND_AMOUNT, rewards_controller, bnpl, account)

    # Check that we can not add a invalid token
    with pytest.raises(Exception):
        rewards_controller.add(busd_address, True, {"from": account2})
    with pytest.raises(Exception):
        rewards_controller.add(bnpl, True, {"from": account2})

    # Add the two valid lp address
    tx = rewards_controller.add(busd_node_address, True, {"from": account2})
    tx.wait(1)
    assert rewards_controller.poolLength() == 1
    tx = rewards_controller.add(usdt_node_address, False, {"from": account})
    tx.wait(1)
    tx = rewards_controller.set(1, {"from": account})
    tx.wait(1)
    assert rewards_controller.poolLength() == 2

    deposit_amount = BUSD_AMOUNT * 0.99
    # Deposit the LP tokens to start accrueing rewards
    approve_erc20(deposit_amount * 2, rewards_controller, usdt_node, account2)
    approve_erc20(deposit_amount, rewards_controller, busd_node, account2)

    tx = rewards_controller.deposit(0, deposit_amount, {"from": account2})
    tx.wait(1)
    tx = rewards_controller.deposit(1, deposit_amount * 2, {"from": account2})
    tx.wait(1)

    # Wait 30 seconds and then check rewards are correct
    time.sleep(30)

    # As busd was added first, and has double the staked BNPL, it should accure double the rewards
    assert rewards_controller.pendingBnpl(0, account2) > rewards_controller.pendingBnpl(
        1, account2
    )

    initial_bnpl_bal = bnpl.balanceOf(account2)
    # Check we can make regular withdrawal and BNPL rewards are collected
    tx = rewards_controller.withdraw(0, deposit_amount / 2, {"from": account2})
    tx.wait(1)
    assert bnpl.balanceOf(account2) > initial_bnpl_bal
    initial_bnpl_bal = bnpl.balanceOf(account2)
    tx = rewards_controller.withdraw(1, deposit_amount / 2, {"from": account2})
    tx.wait(1)
    assert bnpl.balanceOf(account2) > initial_bnpl_bal

    initial_busd_node_tokens = busd_node.balanceOf(account2)
    initial_usdt_node_tokens = usdt_node.balanceOf(account2)

    # Check we can make emergency withdrawals

    tx = rewards_controller.emergencyWithdraw(0, {"from": account2})
    tx.wait(1)
    assert busd_node.balanceOf(account2) > initial_busd_node_tokens

    tx = rewards_controller.emergencyWithdraw(1, {"from": account2})
    tx.wait(1)
    assert usdt_node.balanceOf(account2) > initial_usdt_node_tokens
