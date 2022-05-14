from scripts.helper import get_account, approve_erc20, get_weth
from scripts.uniswap_helpers import swap_to_stablecoins
from scripts.deploy_helpers import (
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
    interface
)
from web3 import Web3

BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 200 * 10**6  # 100 USDT
DAI_AMOUNT = 200 * 10**18  # 100 DAI


def test_bnpl_rewards_contract():

    account = get_account()
    account2 = get_account(index=2)

    get_weth(account, 100)
    get_weth(account2, 100)
    swap_to_stablecoins(account)
    swap_to_stablecoins(account2)

    # Deploy BNPL Token
    BNPL = deploy_bnpl_token()

    USDT = interface.IERC20(config["networks"][network.show_active()]["usdt"])
    DAI = interface.IERC20(config["networks"][network.show_active()]["dai"])

    
    # First deploy BNPL Factory and set up 2 nodes
    # Deploy factory
    FACTORY = deploy_bnpl_factory(BNPL, account)
    
    # Deploy the rewards controller
    start_time = time.time()
    rewards_controller = deploy_rewards_controller(FACTORY, BNPL, start_time)

    # Whitelist USDT and DAI for the factory
    # usdt_address = config["networks"][network.show_active()]["usdt"]
    whitelist_usdt(FACTORY)
    whitelist_token(FACTORY, DAI.address)

    print("Deploy node with account 1")
    approve_erc20(BOND_AMOUNT * 2, FACTORY, BNPL, account)
    create_node(FACTORY, account, USDT.address)

    # Check that only one node per account
    with pytest.raises(Exception):
        create_node(FACTORY, account, USDT.address)

    # Send bnpl to account 2 for bonding
    BNPL.transfer(account2, BOND_AMOUNT * 1.1, {"from": account})

    # Deploy node with account 2
    approve_erc20(BOND_AMOUNT * 1.1, FACTORY, BNPL, account2)
    create_node(FACTORY, account2, DAI.address)

    print("Add 100 USDT and 100 DAI into nodes")

    usdt_node_address = FACTORY.operatorToNode(account)
    dai_node_address = FACTORY.operatorToNode(account2)

    usdt_node = Contract.from_abi(BankingNode._name, usdt_node_address, BankingNode.abi)
    dai_node = Contract.from_abi(BankingNode._name, dai_node_address, BankingNode.abi)

    approve_erc20(USDT_AMOUNT * 2.1, usdt_node_address, USDT.address, account2)
    approve_erc20(DAI_AMOUNT * 1.1, dai_node_address, DAI.address, account2)

    print("Depositing double the USDT to ensure it doenst impact reward weights")
    tx = usdt_node.deposit(USDT_AMOUNT, {"from": account2})
    tx.wait(1)
    tx = usdt_node.deposit(USDT_AMOUNT, {"from": account2})
    tx.wait(1)
    tx = dai_node.deposit(DAI_AMOUNT, {"from": account2})
    tx.wait(1)

    print("Check we got the tokens, should get 100 of each token")
    expected_usdt_node_tokens = DAI_AMOUNT * 2
    expected_dai_node_tokens = DAI_AMOUNT

    assert (
        usdt_node.balanceOf(account2) >= expected_usdt_node_tokens * 0.99
        and usdt_node.balanceOf(account2) <= expected_usdt_node_tokens * 1.01
    )
    assert (
        dai_node.balanceOf(account2) >= expected_dai_node_tokens * 0.99
        and dai_node.balanceOf(account2) <= expected_dai_node_tokens * 1.01
    )

    print("Stake a further 2M BNPL into dai_node to check that rewards will be double for this pool")
    approve_erc20(BOND_AMOUNT * 1.1, dai_node_address, BNPL, account)
    dai_node.stake(BOND_AMOUNT, {"from": account})

    

    print("Approve the rewards controller from the treasury")
    approve_erc20(BOND_AMOUNT, rewards_controller, BNPL, account) # fails here

    # Check that we can not add a invalid token
    with pytest.raises(Exception):
        rewards_controller.add(DAI.address, {"from": account2})
    with pytest.raises(Exception):
        rewards_controller.add(BNPL, {"from": account2})

    # Add the two valid lp address
    tx = rewards_controller.add(dai_node_address, {"from": account2})
    tx.wait(1)
    assert rewards_controller.poolLength() == 1
    tx = rewards_controller.add(usdt_node_address, {"from": account})
    tx.wait(1)
    tx = rewards_controller.set(1, {"from": account})
    tx.wait(1)
    assert rewards_controller.poolLength() == 2

    deposit_amount = DAI_AMOUNT * 0.99
    # Deposit the LP tokens to start accrueing rewards
    approve_erc20(deposit_amount * 2, rewards_controller, usdt_node, account2)
    approve_erc20(deposit_amount, rewards_controller, dai_node, account2)

    tx = rewards_controller.deposit(0, deposit_amount, {"from": account2})
    tx.wait(1)
    tx = rewards_controller.deposit(1, deposit_amount * 2, {"from": account2})
    tx.wait(1)

    # Wait 30 seconds and then check rewards are correct
    time.sleep(30)

    # As dai was added first, and has double the staked BNPL, it should accure double the rewards
    assert rewards_controller.pendingBnpl(0, account2) > rewards_controller.pendingBnpl(
        1, account2
    )

    initial_bnpl_bal = BNPL.balanceOf(account2)
    print("Check we can make regular withdrawal and BNPL rewards are collected")
    tx = rewards_controller.withdraw(0, deposit_amount / 2, {"from": account2})
    tx.wait(1)
    assert BNPL.balanceOf(account2) > initial_bnpl_bal
    initial_bnpl_bal = BNPL.balanceOf(account2)
    tx = rewards_controller.withdraw(1, deposit_amount / 2, {"from": account2})
    tx.wait(1)
    assert BNPL.balanceOf(account2) > initial_bnpl_bal

    initial_dai_node_tokens = dai_node.balanceOf(account2)
    initial_usdt_node_tokens = usdt_node.balanceOf(account2)

    print("Check we can make emergency withdrawals")

    tx = rewards_controller.emergencyWithdraw(0, {"from": account2})
    tx.wait(1)
    assert dai_node.balanceOf(account2) > initial_dai_node_tokens

    tx = rewards_controller.emergencyWithdraw(1, {"from": account2})
    tx.wait(1)
    assert usdt_node.balanceOf(account2) > initial_usdt_node_tokens
