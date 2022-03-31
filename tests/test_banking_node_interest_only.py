from scripts.helper import get_account, approve_erc20, get_account2
from scripts.deploy import (
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

BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT


def test_banking_node_interest_only():

    account = get_account()
    account2 = get_account2()

    # Deploy BNPL Token
    bnpl = deploy_bnpl_token()

    # Deploy factory
    factory = deploy_bnpl_factory(
        BNPLToken[-1], config["networks"][network.show_active()]["weth"]
    )

    # Whitelist USDT for the factory
    whitelist_usdt(factory)

    # Deploy node
    usdt_address = config["networks"][network.show_active()]["usdt"]
    approve_erc20(BOND_AMOUNT, factory, bnpl, account)
    create_node(factory, account, usdt_address)

    # Check that node was created
    node_address = factory.operatorToNode(account)
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

    # Request a loan of 100 USDT, monthly payments, 1 year duration, 10% interest, interest only
    payment_interval = 2628000  # monthly
    tx = node.requestLoan(
        USDT_AMOUNT,
        payment_interval,
        12,
        83,
        True,
        "0x0000000000000000000000000000000000000000",
        0,
        account,
        "tester loan",
        {"from": account2},
    )
    tx.wait(1)
    assert node.getPendingRequestCount() == 1

    # Approve the loan
    loan_id_interest_only = node.pendingRequests(0)
    tx = node.approveLoan(loan_id_interest_only, 0, {"from": account})
    tx.wait(1)

    assert node.getPendingRequestCount() == 0
    assert node.getCurrentLoansCount() == 1

    approve_erc20(
        USDT_AMOUNT * 1.15,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account2,
    )

    # Payments should be 83c for all except final payment
    expected_repay_amount = 0.83 * 10**6

    for x in range(11):
        assert (
            node.getNextPayment(loan_id_interest_only) >= expected_repay_amount * 0.99
            and node.getNextPayment(loan_id_interest_only)
            <= expected_repay_amount * 1.01
        )
        tx = node.makeLoanPayment(loan_id_interest_only, {"from": account2})
        tx.wait(1)

    # Check stats were updated correctly
    total_interest_gain = expected_repay_amount * 11
    interest_withheld = total_interest_gain * 0.3
    expected_asset_value = total_interest_gain * 0.7 + USDT_AMOUNT * 2
    usdt_address = config["networks"][network.show_active()]["usdt"]
    usdt = interface.IERC20(usdt_address)

    assert (
        node.getTotalAssetValue() >= expected_asset_value * 0.99
        and node.getTotalAssetValue() <= expected_asset_value * 1.01
    )
    assert (
        usdt.balanceOf(node_address) >= interest_withheld * 0.99
        and usdt.balanceOf(node_address) <= interest_withheld * 1.01
    )

    # Check final payment
    expected_final_payment = USDT_AMOUNT + expected_repay_amount
    assert (
        node.getNextPayment(loan_id_interest_only) >= expected_final_payment * 0.99
        and node.getNextPayment(loan_id_interest_only) <= expected_final_payment * 1.01
    )
    tx = node.makeLoanPayment(loan_id_interest_only, {"from": account2})
    tx.wait(1)

    # Check can no longer make loan payments
    with pytest.raises(Exception):
        node.makeLoanPayment(loan_id_interest_only, {"from": account2})
    assert node.getCurrentLoansCount() == 0
