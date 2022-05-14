from brownie import (
    network,
    config,
    interface,
)
from scripts.deploy_helpers import (
    deploy_bnpl_factory,
    whitelist_token, 
    whitelist_usdt,
    deploy_rewards_controller
)
from scripts.helper import get_account


def main():
    account = get_account()

    BNPL = interface.ERC20(config["networks"][network.show_active()]["bnpl"])
    USDC = interface.ERC20(config["networks"][network.show_active()]["usdc"])
    FACTORY = deploy_bnpl_factory(BNPL, account)

    whitelist_usdt(FACTORY)
    whitelist_token(FACTORY, USDC)

    start_time = 1653303600.8887198 #  Monday, 23 May 2022 16:00:00 GMT+07:00
    deploy_rewards_controller(FACTORY, BNPL, start_time)
    