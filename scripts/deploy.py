from scripts.helper import get_account, approve_erc20
from brownie import (
    BNPLToken,
    BNPLFactory,
    BNPLRewardsController,
    network,
    config,
    Contract,
    BankingNode,
    interface,
)
from web3 import Web3
import time

GRACE_PERIOD = 0
BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10**6
LP_AMOUNT = 10 * 10**19
LP_ETH = 10**16
START_TIME = 0  # CHANGE FOR ACTUAL DEPLOY


def deploy_bnpl_token():
    account = get_account()
    bnpl = BNPLToken.deploy({"from": account})
    return bnpl


def deploy_bnpl_factory(bnpl, weth):
    account = get_account()
    print("Creating BNPL Factory..")
    bnpl_factory = BNPLFactory.deploy(
        bnpl,
        config["networks"][network.show_active()]["lendingPoolAddressesProvider"],
        weth,
        config["networks"][network.show_active()]["aaveDistributionController"],
        config["networks"][network.show_active()]["factory"],
        {"from": account},
        publish_source=config["networks"][network.show_active()].get("verify"),
    )
    return bnpl_factory


def whitelist_usdt(bnpl_factory):
    account = get_account()
    print("Whitelisting USDT..")
    bnpl_factory.whitelistToken(
        config["networks"][network.show_active()]["usdt"], {"from": account}
    )


def whitelist_token(bnpl_factory, token):
    account = get_account()
    print("Whitelisting USDT..")
    bnpl_factory.whitelistToken(token, {"from": account})


def create_node(bnpl_factory):
    account = get_account()
    tx = bnpl_factory.createNewNode(
        config["networks"][network.show_active()]["usdt"],
        False,
        GRACE_PERIOD,
        {"from": account},
    )
    tx.wait(1)


def add_lp(token):
    account = get_account()
    uniswap_router = interface.IUniswapV2Router02(
        config["networks"][network.show_active()].get("router")
    )
    approve_erc20(LP_AMOUNT, uniswap_router, token, account)
    tx = uniswap_router.addLiquidityETH(
        token,
        LP_AMOUNT,
        0,
        0,
        account,
        time.time() * 10,
        {"from": account, "value": LP_ETH},
    )
    tx.wait(1)
    print("Adding BNPL Liquidity to SushiSwap")


def deploy_rewards_controller(bnpl_factory, bnpl, start_time):
    account = get_account()
    rewards_controller = BNPLRewardsController.deploy(
        bnpl_factory, bnpl, account, start_time
    )
    return rewards_controller


def main():
    account = get_account()
    bnpl_factory = deploy_bnpl_factory(
        BNPLToken[-1], config["networks"][network.show_active()]["weth"]
    )
    whitelist_usdt(bnpl_factory)
    approve_erc20(BOND_AMOUNT, bnpl_factory, BNPLToken[-1], account)
    create_node(bnpl_factory)
    node_address = bnpl_factory.getNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)
    deploy_rewards_controller(bnpl_factory, BNPLToken[-1], START_TIME)
