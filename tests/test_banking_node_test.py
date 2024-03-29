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

BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT

def test_banking_node_test():

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
    USDT = interface.ERC20(config["networks"][network.show_active()]["usdt"])
    # Whitelist USDT for the factory
    whitelist_usdt(FACTORY)

    print("Deploy node")
    usdt_address = config["networks"][network.show_active()]["usdt"]
    approve_erc20(BOND_AMOUNT, FACTORY, BNPL, account)
    create_node(FACTORY, account, usdt_address)

    print("Check that node was created")
    node_address = FACTORY.operatorToNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)

    print("Check that 2M BNPL was bonded")
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

    # Check Balances
    assert (
        node.getTotalAssetValue() >= USDT_AMOUNT * 1.99999999
        and node.getTotalAssetValue() < USDT_AMOUNT * 2.01
    )
    assert (
        node.getBaseTokenBalance(account) >= USDT_AMOUNT * 1.99999999
        and node.getBaseTokenBalance(account) < USDT_AMOUNT * 2.01
    )

    print("Deposit USDT with second account")
    approve_erc20(
        USDT_AMOUNT,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account2,
    )
    tx = node.deposit(USDT_AMOUNT, {"from": account2})
    tx.wait(1)

    # Check Balances
    assert (
        node.getTotalAssetValue() >= USDT_AMOUNT * 2.99999999
        and node.getTotalAssetValue() < USDT_AMOUNT * 3.01
    )
    assert (
        node.getBaseTokenBalance(account2) >= USDT_AMOUNT * 0.99999999
        and node.getBaseTokenBalance(account2) < USDT_AMOUNT * 1.01
    )

    print("Check operator can withdraw unbond funds as there are no current loans")
    tx = node.initiateUnstake(BOND_AMOUNT / 2, {"from": account})
    tx.wait(1)
    assert node.unbondingAmount() == BOND_AMOUNT / 2
    assert node.getBNPLBalance(account) == BOND_AMOUNT / 2

    print("Check that liquidity can no longer be deposited as node is now inactive")
    approve_erc20(
        USDT_AMOUNT,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account2,
    )
    with pytest.raises(Exception):
        tx = node.deposit(USDT_AMOUNT, {"from": account2})

    # Check liquidity can still be withdrawn
    user_amount = node.getBaseTokenBalance(account2)
    assert user_amount > USDT_AMOUNT * 0.99 and user_amount < USDT_AMOUNT * 1.01

    tx = node.withdraw(user_amount, {"from": account2})
    tx.wait(1)
    assert (
        node.getTotalAssetValue() >= USDT_AMOUNT * 1.99999999
        and node.getTotalAssetValue() < USDT_AMOUNT * 2.01
    )

    print("Check balance was updated")
    assert node.getBaseTokenBalance(account2) <= USDT_AMOUNT * 0.01

    # Check can not withdraw more than deposited amount
    with pytest.raises(Exception):
        tx = node.withdraw(USDT_AMOUNT, {"from": account2})

    print("Re-stake to get node back to active")
    approve_erc20(BOND_AMOUNT / 2, node_address, BNPL, account)
    node.stake(BOND_AMOUNT / 2, {"from": account})
    assert node.getBNPLBalance(account) == BOND_AMOUNT
    assert node.unbondingAmount() == BOND_AMOUNT / 2

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

    # Check return values of loan getter functions
    loan_id = node.pendingRequests(0)
    assert node.getNextDueDate(loan_id) == 0
    assert node.getNextPayment(loan_id) == 0

    print("Approve the loan to check return parameters")
    with pytest.raises(Exception):  # First check operator only
        tx = node.approveLoan(loan_id, 0, {"from": account2})
    tx = node.approveLoan(loan_id, 0, {"from": account})
    tx.wait(1)

    assert node.getPendingRequestCount() == 0
    assert node.getCurrentLoansCount() == 1

    # Confirm that now operator can no longer unbond
    with pytest.raises(Exception):
        tx = node.initiateUnstake(BOND_AMOUNT / 2, {"from": account})

    print("Check total balance unchanged, but accounts receivable increase")
    assert (
        node.getTotalAssetValue() >= USDT_AMOUNT * 1.99
        and node.getTotalAssetValue() < USDT_AMOUNT * 2.01
    )
    assert node.accountsReceiveable() == USDT_AMOUNT

    # Check the new value of loan getter functions
    assert (
        node.getNextDueDate(loan_id) > time.time()
        and node.getNextDueDate(loan_id) < time.time() + payment_interval
    )
    expected_payment = 8.79 * 10**6  # 8.79 USDT
    assert (
        node.getNextPayment(loan_id) > expected_payment * 0.99
        and node.getNextPayment(loan_id) < expected_payment * 1.01
    )

    print("Make a payment") # THIS FAILS
    # approve_erc20(
    #     USDT_AMOUNT,
    #     node_address,
    #     USDT,
    #     account2,
    # )
    tx = USDT.approve(node.address, USDT_AMOUNT, {"from": account})
    tx.wait(1)
    node.makeLoanPayment(loan_id, {"from": account2})

    # Ensure it can not be slashed
    with pytest.raises(Exception):
        tx = node.slashLoan(loan_id, 0, {"from": account})

    print("Check on new loan details")
    expected_interest_paid = USDT_AMOUNT * 0.1 / 12 * 0.7
    expected_principal_portion = expected_payment - expected_interest_paid

    assert (
        node.getTotalAssetValue() >= USDT_AMOUNT * 1.99 + expected_interest_paid
        and node.getTotalAssetValue() < USDT_AMOUNT * 2.01 + expected_interest_paid
    )
    assert (
        node.accountsReceiveable() >= USDT_AMOUNT - expected_principal_portion * 0.99
        and node.accountsReceiveable()
        >= USDT_AMOUNT - expected_principal_portion * 1.01
    )
    assert (
        node.getNextDueDate(loan_id) > time.time() + payment_interval
        and node.getNextDueDate(loan_id) < time.time() + payment_interval * 2
    )

    print("Check there is baseToken for the operator, stakers")
    base_token_withheld = USDT_AMOUNT * 0.1 / 12 * 0.3
    usdt_address = config["networks"][network.show_active()]["usdt"]
    usdt = interface.IERC20(usdt_address)

    assert (
        usdt.balanceOf(node_address) >= base_token_withheld * 0.99
        and usdt.balanceOf(node_address) <= base_token_withheld * 1.01
    )

    # Ensure loan can not be slashed
    with pytest.raises(Exception):
        node.slashLoan(loan_id, 0, {"from": account})

    print("Make the remaining 11 payments")
    # for x in range(10):
    for x in range(11):
        node.makeLoanPayment(loan_id, {"from": account2})
    assert node.getCurrentLoansCount() == 0
    # assert node.getCurrentLoansCount() == 1

    # Check can not make another payment
    with pytest.raises(Exception):
        node.makeLoanPayment(loan_id, {"from": account2})

    print("Check on details")
    total_interest_paid = 5.50 * 10**6  # 5.50 USDT
    expected_end_balance = USDT_AMOUNT * 2 + total_interest_paid * 0.7
    usdt_witheld = total_interest_paid * 0.3

    assert (
        node.getTotalAssetValue() >= expected_end_balance * 0.99
        and node.getTotalAssetValue() <= expected_end_balance * 1.01
    )
    assert node.accountsReceiveable() < USDT_AMOUNT * 0.00001
    assert (
        usdt.balanceOf(node_address) >= usdt_witheld * 0.99
        and usdt.balanceOf(node_address) <= usdt_witheld * 1.01
    )

    # Deploy liquidity on Uniswap for BNPL/ETH
    add_lp(BNPL)

    print("Test collecting fees")
    initial_operator_bnpl = node.getBNPLBalance(account)
    initial_operator_usdt = usdt.balanceOf(account)

    tx = node.collectFees(
        {"from": account, "gas_limit": 300000}
    )  # Manual gas limit as it fails often from out of gas
    tx.wait(1)

    print("Check rewards were distributed")
    assert node.getBNPLBalance(account) > initial_operator_bnpl
    assert usdt.balanceOf(account) > initial_operator_usdt
    assert usdt.balanceOf(node_address) == 0
