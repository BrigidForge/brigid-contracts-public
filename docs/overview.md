# Overview

This repository contains the public contract layer for Brigid Forge.

## Contracts

- `BrigidVault.sol`
  - immutable vesting and treasury vault with delayed, permissionless execution
- `BrigidVaultFactory.sol`
  - canonical permissioned deployment factory for official Brigid vaults
- `BrigidLaunchRegistry.sol`
  - immutable structural registry linking deployer, token, and vault set
- `BrigidLPLock.sol`
  - single-deposit LP token lock contract
- `BrigidLaunchToken.sol`
  - fixed-supply ERC-20 used for launchpad-driven token deployments
- `imports/BrigidLaunchOrchestrator.sol`
  - launch workflow coordination contract for launch creation and activation
- `imports/BrigidManagedLPLock.sol`
  - orchestrator-managed LP lock for the canonical activation path

This repo is intentionally narrow: only production-facing contract code and minimal public documentation are included.
