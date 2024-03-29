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
    BNPLFactory,
    BNPLToken,
    BankingNode,
    Contract,
    config,
    network,
    interface,
)
from web3 import Web3

COLLAT_AMOUNT = 100 * 10**18  # 100 BUSD
BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6  # 100 USDT


def test_banking_node_collateral_loan():

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

    # usdt_address = config["networks"][network.show_active()]["usdt"]
    USDT = interface.IERC20(config["networks"][network.show_active()]["usdt"])
    # Deploy node
    approve_erc20(BOND_AMOUNT, FACTORY, BNPL, account)
    create_node(FACTORY, account, USDT.address)

    # Check that node was created
    node_address = FACTORY.operatorToNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)

    # Check that 2M BNPL was bonded
    assert node.getBNPLBalance(account) == BOND_AMOUNT

    # Unbond and redeposit for future unbonding checks
    node.initiateUnstake(BOND_AMOUNT / 2, {"from": account})
    approve_erc20(BOND_AMOUNT / 2, node_address, BNPL, account)
    node.stake(BOND_AMOUNT / 2, {"from": account})

    # Test on a slashing loan + collateral loan at same time
    # 1 second interval to allow slashing
    payment_interval = 1

    # check that collateral loan fails if collateral can not be deposited into aave
    approve_erc20(COLLAT_AMOUNT, node_address, BNPL, account2)

    with pytest.raises(Exception):
        tx = node.requestLoan(
            USDT_AMOUNT,
            payment_interval,
            12,
            83,
            False,
            BNPL,
            COLLAT_AMOUNT,
            account,
            "collateral loan",
            {"from": account2},
        )

    # Collateral Loan with BUSD as collateral


    DAI = interface.IERC20(config["networks"][network.show_active()]["dai"])
    initial_dai_balance = DAI.balanceOf(account2)

    approve_erc20(COLLAT_AMOUNT, node_address, DAI.address, account2)

    tx = node.requestLoan(
        USDT_AMOUNT / 2,
        payment_interval,
        12,
        1000,
        False,
        DAI.address,
        COLLAT_AMOUNT,
        account,
        "collateral loan",
        {"from": account2},
    )
    tx.wait(1)

    # Check loan was approved and collateral posted
    assert node.getPendingRequestCount() == 1
    assert DAI.balanceOf(account2) < initial_dai_balance
    assert node.collateralOwed(DAI.address) == COLLAT_AMOUNT

    loan_id_collateral = node.pendingRequests(0)

    # Request a second loan with no collateral

    tx = node.requestLoan(
        USDT_AMOUNT / 2,
        payment_interval,
        12,
        83,
        False,
        "0x0000000000000000000000000000000000000000",
        0,
        account,
        "slashing loan",
        {"from": account2},
    )
    tx.wait(1)

    assert node.getPendingRequestCount() == 2

    # Test Clear pending loans
    tx = node.clearPendingLoans({"from": account})
    tx.wait(1)
    assert node.getPendingRequestCount() == 0

    # Check collateral can be withdrawn
    tx = node.withdrawCollateral(loan_id_collateral, {"from": account2})
    tx.wait(1)

    assert DAI.balanceOf(account2) == initial_dai_balance
    assert node.collateralOwed(DAI.address) < COLLAT_AMOUNT * 0.01

    # Reapply for the loans

    approve_erc20(COLLAT_AMOUNT, node_address, DAI.address, account2)

    tx = node.requestLoan(
        USDT_AMOUNT / 2,
        payment_interval,
        12,
        83,
        False,
        DAI.address,
        COLLAT_AMOUNT,
        account,
        "collateral loan",
        {"from": account2},
    )
    tx.wait(1)
    tx = node.requestLoan(
        USDT_AMOUNT / 2,
        payment_interval,
        12,
        83,
        False,
        "0x0000000000000000000000000000000000000000",
        0,
        account,
        "slashing loan",
        {"from": account2},
    )
    tx.wait(1)

    loan_id_collateral = node.pendingRequests(0)
    loan_id_slashing = node.pendingRequests(1)
    assert node.getPendingRequestCount() == 2

    # Check that the loan can not be approved as there is not enough liquidity
    with pytest.raises(Exception):
        tx = node.approveLoan(loan_id_collateral, 0, {"from": account})

    # Deposit liquidity to allow for loan approval
    approve_erc20(
        USDT_AMOUNT * 2,
        node_address,
        config["networks"][network.show_active()]["usdt"],
        account,
    )
    tx = node.deposit(USDT_AMOUNT * 2, {"from": account})
    tx.wait(1)

    # Double check we can not slash an unapproved loan
    with pytest.raises(Exception):
        tx = node.slashLoan(loan_id_collateral, 0, {"from": account})

    print(node.idToLoan(loan_id_collateral))

    # Approve collateral loan
    tx = node.approveLoan(
        loan_id_collateral,
        0,
        {"from": account, "gas_limit": 800000, "allow_revert": True},
    )
    tx.wait(1)

    # Collateral should not be withdrawable anymore
    with pytest.raises(Exception):
        node.withdrawCollateral(loan_id_collateral, {"from": account2})

    # Check pending loan is correct
    assert node.getPendingRequestCount() == 1
    assert node.getCurrentLoansCount() == 1
    assert loan_id_slashing == node.pendingRequests(0)

    # Ensure we can not approve same loan again
    with pytest.raises(Exception):
        tx = node.approveLoan(loan_id_collateral, 0, {"from": account})

    tx = node.approveLoan(loan_id_slashing, 0, {"from": account})
    tx.wait(1)

    # Check pending loan is correct
    assert node.getPendingRequestCount() == 0
    assert node.getCurrentLoansCount() == 2

    # Check of assets in pool
    expected_accounts_receiveable = USDT_AMOUNT
    expected_total_asset_value = USDT_AMOUNT * 2
    assert (
        node.accountsReceiveable() >= expected_accounts_receiveable * 0.99
        and node.accountsReceiveable() <= expected_accounts_receiveable
    )
    assert (
        node.getTotalAssetValue() >= expected_total_asset_value * 0.99
        and node.getTotalAssetValue() <= expected_total_asset_value * 1.01
    )

    # Ensure we can not unbond as 7 days has not passed
    with pytest.raises(Exception):
        node.unstake({"from": account})

    # Deploy liquidity on Uniswap for BNPL/ETH
    add_lp(BNPL)

    # Check the loan time has expired and is ready to be slashed
    assert node.getNextDueDate(loan_id_slashing) < time.time()
    assert node.gracePeriod() == 0

    # Slash the collateral now that >1 s passed, and no grace period
    tx = node.slashLoan(loan_id_slashing, 0, {"from": account})
    tx.wait(1)

    # Check we can not slash again
    with pytest.raises(Exception):
        tx = node.slashLoan(loan_id_slashing, 0, {"from": account})

    # Check on pools in assets,
    expected_accounts_receiveable = USDT_AMOUNT / 2
    expected_asset_value = USDT_AMOUNT * 1.5
    assert (
        node.accountsReceiveable() >= expected_accounts_receiveable * 0.99
        and node.accountsReceiveable() <= expected_accounts_receiveable
    )
    assert (
        node.getTotalAssetValue() >= expected_asset_value * 0.99
        and node.getTotalAssetValue() <= expected_asset_value * 1.01
    )

    # $50 slashed of $200 total, should be 25% of staked balance slashed
    expected_staking_balance = BOND_AMOUNT * 0.75
    expected_slashing_balance = BOND_AMOUNT * 1.5 * 0.25
    expected_unbonding_amount = BOND_AMOUNT / 2 * 0.75
    assert (
        node.getBNPLBalance(account) >= expected_staking_balance * 0.99
        and node.getBNPLBalance(account) <= expected_staking_balance * 1.01
    )
    assert (
        node.slashingBalance() >= expected_slashing_balance * 0.99
        and node.slashingBalance() <= expected_slashing_balance * 1.01
    )
    assert (
        node.unbondingAmount() >= expected_unbonding_amount * 0.99
        and node.unbondingAmount() <= expected_unbonding_amount * 1.01
    )

    # Sell the slashed balance
    initial_usd_balance = node.getTotalAssetValue()

    tx = node.sellSlashed(0, {"from": account})
    tx.wait(1)

    # Check on balances change

    assert node.slashingBalance() == 0
    assert node.getTotalAssetValue() > initial_usd_balance
    assert (
        node.getBNPLBalance(account) >= expected_staking_balance * 0.99
        and node.getBNPLBalance(account) <= expected_staking_balance * 1.01
    )

    initial_usd_balance = node.getTotalAssetValue()

    # Ensure loan is slashable
    assert node.getNextDueDate(loan_id_collateral) < time.time()

    # Slash loan with collateral
    tx = node.slashLoan(loan_id_collateral, 0, {"from": account})
    tx.wait(1)

    # Check can not slash again
    with pytest.raises(Exception):
        tx = node.slashLoan(loan_id_collateral, 0, {"from": account})

    # Check the collateral was sold for usdt and other balances
    accounts_receiveable_lost = USDT_AMOUNT / 2

    assert node.getTotalAssetValue() > initial_usd_balance - accounts_receiveable_lost
    assert node.collateralOwed(DAI.address) == 0
    if node.getTotalAssetValue() < initial_usd_balance:
        assert node.slashingBalance() > 0

    # Ensure collateral can no longer be withdrawn
    with pytest.raises(Exception):
        node.withdrawCollateral(loan_id_collateral, {"from": account2})

    # Check that there was a small amount of interest earnt on the collateral
    initial_staked_bnpl = node.getBNPLBalance(account)
    tx = node.collectCollateralFees(DAI.address, {"from": account})
    tx.wait(1)
    assert node.getBNPLBalance(account) > initial_staked_bnpl
    assert node.defaultedLoanCount() == 2
    assert node.getCurrentLoansCount() == 0
    assert node.getPendingRequestCount() == 0