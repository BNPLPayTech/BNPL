from scripts.helper import get_account, approve_erc20
from brownie import(
    BNPLToken,
    BNPLFactory,
    network,
    config,
    Contract,
    BankingNode,
    interface
)
from web3 import Web3
import time

GRACE_PERIOD = 0
BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = (100* 10**6)
LP_AMOUNT = (10 * 10**7)
LP_ETH = (10**17)
AGENT_FEE = 500

def deploy_bnpl_token():
    account = get_account()
    bnpl = BNPLToken.deploy(
    {"from": account})
    return bnpl

def deploy_bnpl_factory(bnpl, router):
    account = get_account()
    print("Creating BNPL Factory..")
    bnpl_factory = BNPLFactory.deploy(
        bnpl,
        config["networks"][network.show_active()]["lendingPoolAddressesProvider"],
        router,
        {"from": account}
    )
    return bnpl_factory

def whitelist_usdt(bnpl_factory):
    account = get_account()
    print("Whitelisting USDT..")
    bnpl_factory.whitelistToken(
        config["networks"][network.show_active()]["usdt"],
        {"from": account}
    )

def create_node(bnpl_factory):
    account = get_account()
    tx = bnpl_factory.createNewNode(
        config["networks"][network.show_active()]["usdt"],
        False,
        GRACE_PERIOD,
        AGENT_FEE,
        {"from": account}
    )
    tx.wait(1)

def add_lp(dojo_token):
    account = get_account()
    uniswap_router = interface.IUniswapV2Router02(
        config["networks"][network.show_active()].get("router")
    )
    approve_erc20(LP_AMOUNT, uniswap_router, dojo_token, account)
    tx = uniswap_router.addLiquidityETH(
        dojo_token,
        LP_AMOUNT,
        0,
        0,
        account,
        time.time() * 10,
        {"from": account, "value": LP_ETH},
    )
    print("Adding BNPL Liquidity to SushiSwap")

def main():
    account = get_account()
    bnpl_factory = deploy_bnpl_factory(BNPLToken[-1], config["networks"][network.show_active()]["sushiRouter"])
    whitelist_usdt(bnpl_factory)
    approve_erc20(BOND_AMOUNT, bnpl_factory , BNPLToken[-1] ,account)
    create_node(bnpl_factory)
    node_address = bnpl_factory.getNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)
    lending_pool = node.getLendingPool()
    approve_erc20(USDT_AMOUNT*2, node_address, config["networks"][network.show_active()]["usdt"] ,account)
    node.deposit(USDT_AMOUNT, {"from": account})
    node.deposit(USDT_AMOUNT, {"from": account})
    node.withdraw(USDT_AMOUNT*0.9, {"from": account})

