# Brigid Forge Public Contracts

This repository contains the curated public contract source bundle for Brigid Forge.

It includes the production-facing contract files Brigid Forge has intentionally approved for public source review. Internal tests, mocks, deployment scripts, operational runbooks, generated artifacts, environment files, and archived material are excluded.

## Current Public Scope

This is the clean public source surface for Brigid Forge contracts. The broader Brigid Forge product workspace includes private launch, indexing, deployment, admin, and operations code that is intentionally not published here.

Public visitors should use this repository for:

- contract source review
- public development history
- high-level understanding of the Brigid Vault, launch, LP-lock, meme launch, and staking/revenue contract set

Private environment repos and operational repos remain internal source-of-truth repositories for deployment and infrastructure.

## Official Brigid Forge Links

- [Brigid Forge website](https://brigidforge.com/)
- [Token launch guide library](https://brigidforge.com/guides/)
- [BNB token launch technical checklist](https://brigidforge.com/token-launch-technical-checklist/)
- [Brigid Launch Standard](https://brigidforge.com/brigid-launch-standard/)
- [Brigid Transparency System](https://brigidforge.com/transparency/)
- [BRIGID token overview](https://brigidforge.com/token/)
- [Disclosures and risk notice](https://brigidforge.com/disclosures-risk-notice/)

## Included

- [Contract source index](contracts/README.md)
- [BrigidVault](contracts/BrigidVault.sol)
- [BrigidVaultFactory](contracts/BrigidVaultFactory.sol)
- [BrigidLaunchRegistry](contracts/BrigidLaunchRegistry.sol)
- [BrigidLPLock](contracts/BrigidLPLock.sol)
- [BrigidLaunchToken](contracts/BrigidLaunchToken.sol)
- [BrigidTokenRegistry](contracts/BrigidTokenRegistry.sol)
- [BrigidUncxV1LPLockerAdapter](contracts/BrigidUncxV1LPLockerAdapter.sol)
- [BrigidLaunchOrchestrator](contracts/imports/BrigidLaunchOrchestrator.sol)
- [BrigidManagedLPLock](contracts/imports/BrigidManagedLPLock.sol)
- [BrigidMemeLaunchOrchestrator](contracts/imports/BrigidMemeLaunchOrchestrator.sol)
- [BrigidMemeLaunchRegistry](contracts/imports/BrigidMemeLaunchRegistry.sol)
- [BrigidStaking](contracts/staking/BrigidStaking.sol)
- [BrigidRevenueRouter](contracts/staking/BrigidRevenueRouter.sol)
- [BrigidSubscription](contracts/staking/BrigidSubscription.sol)

## Intentionally Excluded

- test suites
- mocks
- adversarial harnesses
- deployment scripts
- operational runbooks
- environment files and secrets
- generated artifacts and caches
- archived and legacy material
- local admin/operator tooling
- hosted backend services
- private deployment and verification notes

## Publication Scope

This repository is published intentionally as a focused public contract bundle. Public releases may be updated over time as Brigid Forge publishes new verified contract sets.

All rights are reserved unless and until a final public license is selected.

## Public Docs

- [Public Development Log](docs/development-log-public.md)
- [Security Policy](SECURITY.md)
