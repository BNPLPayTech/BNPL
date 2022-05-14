from scripts.helper import get_account, approve_erc20, get_weth
from scripts.uniswap_helpers import swap_to_stablecoins
from scripts.deploy_helpers import (
    create_node,
    whitelist_usdt,
    deploy_bnpl_factory,
    deploy_bnpl_token,
    add_lp,
)
import pytest
import time
from brownie import (
    BNPLToken,
    BankingNode,
    Contract,
    config,
    network,
    interface,
)
from web3 import Web3

BOND_AMOUNT = Web3.toWei(2_000_000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT

def test_banking_node_early_repay():

    account = get_account()
    account2 = get_account(index=2)

    get_weth(account, 100)
    get_weth(account2, 100)
    swap_to_stablecoins(account)
    swap_to_stablecoins(account2)

    # Deploy BNPL Token
    BNPL = deploy_bnpl_token()

    # Deploy factory
    FACTORY = deploy_bnpl_factory(BNPL, account)

    # Whitelist USDT for the factory
    whitelist_usdt(FACTORY)

    # Deploy node
    usdt_address = config["networks"][network.show_active()]["usdt"]
    approve_erc20(BOND_AMOUNT, FACTORY, BNPL, account)
    create_node(FACTORY, account, usdt_address)

    # Check that node was created
    node_address = FACTORY.operatorToNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)

    # Check that 2M BNPL was bonded
    assert node.getBNPLBalance(account) == BOND_AMOUNT

    # Check initial paramets of Node
    assert node.getTotalAssetValue() == 0

    # Deposit USDT with 1 account
    approve_erc20(
        USDT_AMOUNT * 2,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account,
    )
    tx = node.deposit(USDT_AMOUNT, {"from": account})
    tx.wait(1)
    tx = node.deposit(USDT_AMOUNT, {"from": account})
    tx.wait(1)

    # Request a loan of 100 USDT, monthly payments, 1 year duration, 10% interest, principal + interest
    payment_interval = 2628000  # monthly
    tx = node.requestLoan(
        USDT_AMOUNT,
        payment_interval,
        12,
        83,
        False,
        "0x0000000000000000000000000000000000000000",
        0,
        account,
        "tester loan",
        {"from": account2},
    )
    tx.wait(1)
    assert node.getPendingRequestCount() == 1

    # Save initial numbers
    # usdt_address = config["networks"][network.show_active()]["usdt"]
    treasury = config["networks"][network.show_active()]["treasury"]
    USDT = interface.IERC20(config["networks"][network.show_active()]["usdt"])
    borrower_initial_usd = USDT.balanceOf(account2)
    agent_initial_usd = USDT.balanceOf(account)
    treasury_initial_usd = USDT.balanceOf(treasury)

    # Approve the loan

    loan_id_early_repay = node.pendingRequests(0)

    tx = node.approveLoan(loan_id_early_repay, 0, {"from": account})
    tx.wait(1)

    assert node.getPendingRequestCount() == 0
    assert node.getPendingRequestCount() == 0

    # Check balances have been distributed
    expected_borrower_usdt_received = USDT_AMOUNT * 0.9925
    expected_agent_fees = USDT_AMOUNT * 0.0025
    expected_treasury_fees = USDT_AMOUNT * 0.005

    assert (
        USDT.balanceOf(treasury) >= treasury_initial_usd + expected_treasury_fees * 0.99
        and USDT.balanceOf(treasury)
        <= treasury_initial_usd + expected_treasury_fees * 1.01
    )
    assert (
        USDT.balanceOf(account2)
        >= borrower_initial_usd + expected_borrower_usdt_received * 0.99
        and USDT.balanceOf(account2)
        <= borrower_initial_usd + expected_borrower_usdt_received * 1.01
    )
    assert (
        USDT.balanceOf(account) >= agent_initial_usd + expected_agent_fees * 0.99
        and USDT.balanceOf(account) <= agent_initial_usd + expected_agent_fees * 1.01
    )

    approve_erc20(
        USDT_AMOUNT * 1.1,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account2,
    )

    # Make 1 payment, then pay off rest early
    tx = node.makeLoanPayment(loan_id_early_repay, {"from": account2})
    tx.wait(1)
    tx = node.repayEarly(loan_id_early_repay, {"from": account2})
    tx.wait(1)

    # Ensure can not repay more
    with pytest.raises(Exception):
        tx = node.makeLoanPayment(loan_id_early_repay, {"from": account2})
    with pytest.raises(Exception):
        tx = node.repayEarly(loan_id_early_repay, {"from": account2})

    # Check balances are correct
    expected_total_interest = 1.59 * 10**6  # 1.59 USDT
    expected_interest_withheld = expected_total_interest * 0.3
    expected_node_value = USDT_AMOUNT * 2 + expected_total_interest * 0.7

    assert node.getCurrentLoansCount() == 0
    assert (
        node.getTotalAssetValue() >= expected_node_value * 0.99
        and node.getTotalAssetValue() <= expected_node_value * 1.01
    )
    assert (
        USDT.balanceOf(node_address) >= expected_interest_withheld * 0.99
        and USDT.balanceOf(node_address) <= expected_interest_withheld * 1.01
    )
