from brownie import accounts, config, reverts, Wei, Contract
from useful_methods import state_of_vault, state_of_strategy, harvest_live_vault
import brownie


def test_operation(web3, chain, vault, strategy, token, amount, whale, gov, guardian, strategist, rewards, seth_vault):
    scale = 10 ** token.decimals()
    # Deposit to the vault
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    print(f"shares amount: {vault.balanceOf(whale)/scale}")
    vault.deposit(amount, {"from": whale})
    print(f"deposit amount: {amount/scale}")
    print(f"shares amount: {vault.balanceOf(whale)/scale}")
    # assert token.balanceOf(vault.address) == amount
    print(f"token on strategy: {token.balanceOf(strategy)/scale}")

    print(f"\n****** Initial Status ******")
    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> call harvest")
    strategy.harvest()

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> harvest underlying live vaults & wait 1 day")
    harvest_live_vault(seth_vault)
    chain.sleep(86400)
    chain.mine(1)
    state_of_vault(vault, token)

    print(f"\n >>> harvest to realized profit")
    strategy.harvest()

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> harvest underlying live vaults & wait 1 day")
    harvest_live_vault(seth_vault)
    chain.sleep(86400)
    chain.mine(1)
    state_of_vault(vault, token)

    print(f"\n >>> harvest to realized profit")
    strategy.harvest()

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> wait 1 day to get the share price back")
    chain.sleep(86400)
    chain.mine(1)
    state_of_vault(vault, token)

    # withdraw
    print(f"\n****** withdraw {token.name()} ******")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")
    vault.withdraw(amount / 2, {"from": whale})
    print(f"withdraw {amount/2/scale} {token.name()} done")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    # withdraw all
    print(f"\n****** withdraw all {token.name()} ******")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")
    vault.withdraw(vault.balanceOf(whale), whale, 10_000, {"from": whale})
    print(f"withdraw all {token.name()}")
    print(f"whale's {token.name()} vault share: {vault.balanceOf(whale)/scale}")

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    # # all withdraw
    # print()
    # print(f"rewards+strategist withdraw")
    # vault.withdraw(vault.balanceOf(rewards), rewards, 10_000, {"from": rewards})
    # vault.transfer(strategist, vault.balanceOf(strategy), {"from": strategy})
    # vault.withdraw(vault.balanceOf(strategist), strategist, 10_000, {"from": strategist})

    print(f"\n****** State ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> call tend")
    strategy.tend()
