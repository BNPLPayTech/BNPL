from scripts.helper import get_account, approve_erc20, get_weth
from decimal import Decimal
from brownie import (
    config,
    network,
    interface,
)
import datetime

current_time = datetime.datetime.now(datetime.timezone.utc)
MINUTES = 60
SLIPPAGE = 0.10

WETH_AMOUNT = 1
USD_AMOUNT = 1900
MAX_ALLOWANCE = 2**256-1

def main():
    account = get_account()
    get_weth(account, 100)

    # WETH = interface.IERC20(config["networks"][network.show_active()]["weth"])
    # BUSD = interface.IERC20(config["networks"][network.show_active()]["busd"])
    # USDT = interface.IERC20(config["networks"][network.show_active()]["usdt"])

    swap_to_stablecoins(account)

def swap_to_stablecoins(account):
    """

    # To get BUSD on ETH we need to take a few extra steps. 
    # This function swaps wETH for BUSD and USDT. 

    1. WETH -> USDT
    2. WETH -> USDC
    # 3. USDC -> BUSD
    """
    IROUTER_02 = interface.IUniswapV2Router02(config["networks"][network.show_active()]["router"])
    WETH = interface.IERC20(config["networks"][network.show_active()]["weth"])
    USDC = interface.IERC20(config["networks"][network.show_active()]["usdc"])
    USDT = interface.IERC20(config["networks"][network.show_active()]["usdt"])
    DAI = interface.IERC20(config["networks"][network.show_active()]["dai"])

    assert(WETH.balanceOf(account) > 0)
    approve_erc20(MAX_ALLOWANCE, IROUTER_02, WETH, account)

    weth_decimals = 18
    usdt_decimals = 6
    usdc_decimals = 6
    dai_decimals = 18
    
    tx = token_swap(
        WETH_AMOUNT,
        WETH,
        weth_decimals,
        USD_AMOUNT,
        USDT,
        usdt_decimals,
        IROUTER_02,
        account,
    )
    tx.wait(1)
    print("1/3: completed WETH -> USDT")

    tx = token_swap(
        WETH_AMOUNT,
        WETH,
        weth_decimals,
        USD_AMOUNT,
        USDC,
        usdc_decimals,
        IROUTER_02,
        account,
    )
    tx.wait(1)
    print("2/3: completed WETH -> USDC")

    tx = token_swap(
        WETH_AMOUNT,
        WETH,
        weth_decimals,
        USD_AMOUNT,
        DAI,
        dai_decimals,
        IROUTER_02,
        account,
    )
    tx.wait(1)
    print("3/3: completed WETH -> DAI")

def token_swap(
    token_in_quantity: float,
    token_in: str,
    token_in_decimals: int,
    token_out_quantity: float,
    token_out: str,
    token_out_decimals: int,
    router: object,
    user: object,
):
    """
    Swaps an exact amount of input tokens for as many output tokens as possible,
    along the route determined by the path. The first element of path is the
    input token, the last is the output token, and any intermediate elements
    represent intermediate pairs to trade through (if, for example, a direct
    pair does not exist).

    Ref: https://docs.uniswap.org/protocol/V2/reference/smart-contracts/router-02#swapexacttokensfortokens
    """
    token_in_quantity_wei = token_in_quantity * (10**token_in_decimals)
    token_out_quantity_wei = token_out_quantity * (10**token_out_decimals)

    assert(token_in.allowance(user, router) >= token_in_quantity_wei)
    # if token_in.allowance(router, user) >= token_in_quantity_wei:
    #     print('!allowance:', token_in.allowance(router, user))


    tx = router.swapExactTokensForTokens(
        token_in_quantity_wei,
        int(token_out_quantity_wei * (1 - Decimal(SLIPPAGE))),
        [token_in.address, token_out.address],
        user.address,
        current_time.timestamp() + (5 * MINUTES),
        {"from": user},
    )
    return tx