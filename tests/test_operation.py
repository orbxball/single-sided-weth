from brownie import Wei, reverts
from useful_methods import state_of_vault, state_of_strategy
import brownie

def test_operation(web3, chain, vault, strategy, token, amount, whale, gov, guardian, strategist):

    # whale approve weth vault to use weth
    token.approve(vault, 2 ** 256 - 1, {"from": whale})

    # start deposit
    vault.deposit(amount, {"from": whale})
    print(f'whale deposit done with {amount/1e18} weth\n')


    print(f"\n****** Initial Status ******")
    print(f"\n****** {token.name()} ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n****** Harvest {token.name()} ******")
    strategy.harvest({'from': strategist})

    print(f"\n****** {token.name()} ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    # sleep & realize profit
    print(f"\n****** sleep + realize profit ******")
    chain.sleep(86400)
    print()

    # withdraw
    scale = 10 ** token.decimals()
    print(f"\n****** withdraw {token.name()} ******")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")
    vault.withdraw(amount / 2, {"from": whale})
    print(f"withdraw {amount/2/scale} {token.name()} done")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")

    print(f"\n****** {token.name()} ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    # withdraw all
    print(f"\n****** withdraw all {token.name()} ******")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")
    vault.withdraw({"from": whale})
    print(f"withdraw all {token.name()}")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")

    # try call tend
    print(f"\ncall tend")
    strategy.tend()
    print(f"tend done")
