from brownie import (
    accounts,
    config,
    interface
)

def get_account(index=None, id=None):
    if index:
        return accounts[index]
    if id:
        return accounts.load(id)
    return accounts.add(config["wallets"]["key1"])

def get_account2(index=None, id=None):
    if index:
        return accounts[index]
    if id:
        return accounts.load(id)
    return accounts.add(config["wallets"]["key2"])

def approve_erc20(amount, spender, erc20_address, account):
    print("Approving ERC20 token...")
    erc20 = interface.IERC20(erc20_address)
    tx = erc20.approve(spender, amount, {"from": account})
    tx.wait(1)
    print("Approved!")
    return tx