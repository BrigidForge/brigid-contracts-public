# Contract Source Index

This directory contains the public Brigid Forge production-facing contract
source bundle for BNB Smart Chain.

The active BSC mainnet address-to-source mapping is recorded in
[`../deployments/bsc-mainnet.json`](../deployments/bsc-mainnet.json). Build the
complete bundle from the repository root with `npm ci && npm run build`.

## Vault And Launch Core

- [BrigidVault.sol](BrigidVault.sol)
- [BrigidVaultFactory.sol](BrigidVaultFactory.sol)
- [BrigidLaunchRegistry.sol](BrigidLaunchRegistry.sol)
- [BrigidLPLock.sol](BrigidLPLock.sol)
- [BrigidLaunchToken.sol](BrigidLaunchToken.sol)
- [BrigidTokenRegistry.sol](BrigidTokenRegistry.sol)

## LP Locking

- [BrigidUncxV1LPLockerAdapter.sol](BrigidUncxV1LPLockerAdapter.sol)
- [BrigidManagedLPLock.sol](imports/BrigidManagedLPLock.sol)

## Launch Orchestrators

- [BrigidLaunchOrchestrator.sol](imports/BrigidLaunchOrchestrator.sol)
- [BrigidMemeLaunchOrchestrator.sol](imports/BrigidMemeLaunchOrchestrator.sol)
- [BrigidMemeLaunchRegistry.sol](imports/BrigidMemeLaunchRegistry.sol)

## Staking And Revenue

- [BrigidStaking.sol](staking/BrigidStaking.sol)
- [BrigidRevenueRouter.sol](staking/BrigidRevenueRouter.sol)
- [BrigidSubscription.sol](staking/BrigidSubscription.sol)

## Not Included

Test-only mocks, adversarial tokens, deployment helper tokens, scripts, runbooks, generated artifacts, environment files, and private operational material are intentionally excluded from the public contract bundle.
