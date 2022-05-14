from brownie import (
    BNPLToken,
    BNPLFactory,
    ProxyAdmin,
    TransparentUpgradeableProxy,
    BNPLRewardsController,
    network,
    config,
    Contract,
    BankingNode,
    interface,
)
from web3 import Web3
import time

from scripts.helper import (
    get_account, 
    approve_erc20, 
    encode_function_data, 
    upgrade
)

GRACE_PERIOD = 0
BOND_AMOUNT = Web3.toWei(2000000, "ether")
USDT_AMOUNT = 100 * 10 ** 6
LP_AMOUNT = 10 * 10 ** 19
LP_ETH = 10 ** 16
START_TIME = 0  # CHANGE FOR ACTUAL DEPLOY


def deploy_bnpl_token():
    account = get_account()
    bnpl = BNPLToken.deploy(
        {"from": account, "gas_price": "2.5 gwei"},
        publish_source=config["networks"][network.show_active()].get("verify"),
    )
    return bnpl


def deploy_bnpl_factory(BNPL, account):
    """
    This is the logical flow of the Upgradeable Proxy Pattern from OpenZeppelin:

    owner --> ProxyAdmin --> Proxy --> implementation_v0
                                   |
                                   --> implementation_v1
                                   |
                                   --> implementation_v2

    Reference:
    https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies
    """
    print("Deploying ProxyAdmin contract...")
    # Admin and upgrade interface. This contract will be the owner of the proxy contract.
    PROXY_ADMIN_FACTORY = ProxyAdmin.deploy(
        {"from": account},
    )
    print("Deployed!")

    print("Deploying BNPLFactory implementation contract...")
    # The implentation contract. All calls to the proxy will be delegated here
    BNPL_FACTORY = BNPLFactory.deploy(
        {"from": account},
        publish_source=config["networks"][network.show_active()]["verify"],
    )
    print("Deployed!")

    # Preparing the initialization of the contract
    box_encoded_initializer_function = encode_function_data(
        BNPL_FACTORY.initialize,
        BNPL.address,
        config["networks"][network.show_active()]["lendingPoolAddressesProvider"],
        config["networks"][network.show_active()]["weth"],
        config["networks"][network.show_active()]["aaveDistributionController"],
        config["networks"][network.show_active()]["factory"],
    )

    print("Deploying Factory Proxy contract...")
    # The Proxy contract. Will delegate all calls to the implementation contract.
    PROXY_BNPL_FACTORY = TransparentUpgradeableProxy.deploy(
        BNPL_FACTORY.address,
        PROXY_ADMIN_FACTORY.address,
        box_encoded_initializer_function,
        {"from": account, "gas_limit": 1000000},
    )
    print("Deployed!")

    PROXY = Contract.from_abi(
        "BNPLFactory_v0", PROXY_BNPL_FACTORY.address, BNPLFactory.abi
    )
    FACTORY = PROXY

    assert FACTORY.bankingNodeCount() == 0
    assert FACTORY.BNPL() == BNPL.address
    assert (
        FACTORY.lendingPoolAddressesProvider()
        == config["networks"][network.show_active()]["lendingPoolAddressesProvider"]
    )
    assert FACTORY.WETH() == config["networks"][network.show_active()]["weth"]
    assert (
        FACTORY.aaveDistributionController()
        == config["networks"][network.show_active()]["aaveDistributionController"]
    )
    assert (
        FACTORY.uniswapFactory() == config["networks"][network.show_active()]["factory"]
    )

    return PROXY

def upgrade_factory(new_implementation, account):
    """
    Upgrades BNPLFactory by deploying a new version of contract and 
    run the upgrade function of the proxy to point to the new implementation. 
    """
    print("Upgrading BNPLFactory...")
    factory_v2 = new_implementation.deploy(
        {"from": account},
        publish_source=config["networks"][network.show_active()]["verify"],
    )
    
    proxy = TransparentUpgradeableProxy[-1]
    proxy_admin = ProxyAdmin[-1]
    upgrade(account, proxy, factory_v2, proxy_admin_contract=proxy_admin)
    FACTORY_V2 = Contract.from_abi("BNPLFactoryV2", proxy.address, new_implementation.abi)
    print("Upgraded!")
    
    return FACTORY_V2

def whitelist_usdt(bnpl_factory):
    account = get_account()
    print("Whitelisting USDT..")
    bnpl_factory.whitelistToken(
        config["networks"][network.show_active()]["usdt"],
        True,
        {"from": account, "gas_price": "2.5 gwei"},
    )


def whitelist_token(bnpl_factory, token):
    account = get_account()
    print("Whitelisting USDT..")
    bnpl_factory.whitelistToken(token, True, {"from": account, "gas_price": "2.5 gwei"})


def create_node(bnpl_factory, account, token):
    tx = bnpl_factory.createNewNode(
        token,
        False,
        GRACE_PERIOD,
        {"from": account, "gas_price": "2.5 gwei"},
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
    print("deploying rewards controller...")
    rewards_controller = BNPLRewardsController.deploy(
        bnpl_factory,
        bnpl,
        account,
        start_time,
        {"from": account, "gas_price": "2.5 gwei"},
    )
    print("deployed!")
    return rewards_controller


def main():
    account = get_account()
    bnpl = deploy_bnpl_token()

    front_end_dev = "0x8bD243b54eB32dD8025c1f5534b194909caFea47"

    bnpl.transfer(
        front_end_dev, BOND_AMOUNT * 20, {"from": account, "gas_price": "2.5 gwei"}
    )

    bnpl_factory = deploy_bnpl_factory(
        BNPLToken[-1], config["networks"][network.show_active()]["weth"]
    )
    whitelist_usdt(bnpl_factory)
    approve_erc20(BOND_AMOUNT, bnpl_factory, BNPLToken[-1], account)
    create_node(
        bnpl_factory,
        account,
        config["networks"][network.show_active()]["usdt"],
    )
    node_address = bnpl_factory.operatorToNode(account)
    node = Contract.from_abi(BankingNode._name, node_address, BankingNode.abi)
    deploy_rewards_controller(BNPLFactory[-1], BNPLToken[-1], START_TIME)
