from brownie import accounts, config, reverts, Wei, Contract
from useful_methods import state_of_vault, state_of_strategy
import brownie


def test_live_migration(web3, chain, vault, strategy, token, whale, gov, strategist, rewards, amount):

    live_strat = Contract("0xC5e385f7Dad49F230AbD53e21b06aA0fE8dA782D", owner=gov)
    new_strat = Contract("0x8c44Cc5c0f5CD2f7f17B9Aca85d456df25a61Ae8", owner=gov)
    vault = Contract(new_strat.vault(), owner=gov)

    print(f"\n >>> before migration")
    state_of_strategy(live_strat, token, vault)
    state_of_strategy(new_strat, token, vault)
    state_of_vault(vault, token)
    print()
    vault.migrateStrategy(live_strat, new_strat)
    print()
    print(f"\n >>> after migration")
    state_of_strategy(live_strat, token, vault)
    state_of_strategy(new_strat, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> harvest")
    new_strat.harvest()
    state_of_strategy(live_strat, token, vault)
    state_of_strategy(new_strat, token, vault)
    state_of_vault(vault, token)

    print(f"\n >>> wait 1 day to get the share price back")
    chain.sleep(86400)
    chain.mine(1)
    state_of_strategy(live_strat, token, vault)
    state_of_strategy(new_strat, token, vault)
    state_of_vault(vault, token)
