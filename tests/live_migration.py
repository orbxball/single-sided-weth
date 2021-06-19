from brownie import accounts, config, reverts, Wei, Contract
from useful_methods import state_of_vault, state_of_strategy
import brownie


def test_live_migration(web3, chain, vault, strategy, token, whale, gov, strategist, rewards, amount):

    live_strat = Contract("0x37770F958447fFa1571fc9624BFB3d673161f37F", owner=gov)
    new_strat = Contract("0xCdC3d3A18c9d83Ee6E10E91B48b1fcb5268C97B5", owner=gov)
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
