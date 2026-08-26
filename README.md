# Brigid Forge Launch System — Public Contracts

Brigid Forge Launch System is a non-custodial token-launch dApp deployed on
**BNB Smart Chain Mainnet (chain ID 56)**. The browser application guides a
project through fixed-supply token creation, governed allocation vaults,
liquidity locking, public launch registration, and Brigid Beacon monitoring.

- dApp: [brigidforge.com/launch](https://brigidforge.com/launch/)
- Website: [brigidforge.com](https://brigidforge.com/)
- Primary network: BNB Smart Chain Mainnet (`56`)
- Test network: BNB Smart Chain Testnet (`97`)
- Primary DappBay category: DeFi / Launchpad

Production contracts are deployed and source-verified on BNB Smart Chain.
Public-launch approval is controlled separately from deployment; this
repository documents the public contract code and recorded deployment
addresses without making an investment or availability guarantee.

## What The dApp Does

The Launch System provides two guided BNB Chain launch paths:

- **Custom Launch** — creates a fixed-supply token, developer and treasury
  vaults, optional additional allocation vaults, liquidity, an LP lock, and a
  public launch record.
- **Meme Launch** — provides a streamlined launch path using the same core
  fixed-supply, vault, liquidity-lock, and public-record principles.

Brigid Beacon reads the resulting registries and vault events so users can
inspect launch evidence and monitor protected withdrawal activity. BRIGID
staking and the revenue router are separate connected components of the same
deployed BNB Chain system.

## Technology Stack

| Layer | Technology |
| --- | --- |
| Blockchain | BNB Smart Chain Mainnet and Testnet |
| Contracts | Solidity `0.8.33` and `0.8.24` |
| Contract toolchain | Foundry |
| Contract library | OpenZeppelin Contracts `5.5.0` |
| Browser dApp | React, TypeScript, Vite, ethers.js v6 |
| Liquidity integration | PancakeSwap V2 and the configured external LP-locker adapter |

The frontend, hosted APIs, indexer, and private operational tooling are not
published in this focused contract-review repository. See
[Publication Scope](#publication-scope) for the boundary.

## Supported Networks

| Network | Chain ID | Status | Explorer |
| --- | ---: | --- | --- |
| BNB Smart Chain Mainnet | `56` | Production deployment target | [BscScan](https://bscscan.com/) |
| BNB Smart Chain Testnet | `97` | Isolated testing environment | [BscScan Testnet](https://testnet.bscscan.com/) |

The machine-readable network configuration is in [`bnbconfig.json`](bnbconfig.json).
RPC endpoints are supplied through environment variables and no private RPC
credentials are committed.

## Active BNB Smart Chain Mainnet Contracts

The canonical machine-readable record is
[`deployments/bsc-mainnet.json`](deployments/bsc-mainnet.json).

| Component | Address | Verified source |
| --- | --- | --- |
| BRIGID token | [`0x85050F141a6006075161EB4c2EeEdE65089d54d0`](https://bscscan.com/address/0x85050F141a6006075161EB4c2EeEdE65089d54d0#code) | `BrigidLaunchToken.sol` |
| BrigidVaultFactory | [`0x22606599639c60383AE556391DCb7996A0382dfB`](https://bscscan.com/address/0x22606599639c60383AE556391DCb7996A0382dfB#code) | `BrigidVaultFactory.sol` |
| BrigidTokenRegistry | [`0x2a96f07049a467f9B3C27060AA40BD8C83C92Fd1`](https://bscscan.com/address/0x2a96f07049a467f9B3C27060AA40BD8C83C92Fd1#code) | `BrigidTokenRegistry.sol` |
| BrigidLaunchRegistry | [`0x85e20467ef72d6715f314dA29c322bb183B88598`](https://bscscan.com/address/0x85e20467ef72d6715f314dA29c322bb183B88598#code) | `BrigidLaunchRegistry.sol` |
| BrigidLaunchOrchestrator | [`0x45B55fd580bA221271b9F46eEEBca8F461749C60`](https://bscscan.com/address/0x45B55fd580bA221271b9F46eEEBca8F461749C60#code) | `BrigidLaunchOrchestrator.sol` |
| BrigidMemeLaunchRegistry | [`0x614bBAEBC7eb648CAAD2BA8992eF4bD62D82FDA2`](https://bscscan.com/address/0x614bBAEBC7eb648CAAD2BA8992eF4bD62D82FDA2#code) | `BrigidMemeLaunchRegistry.sol` |
| BrigidMemeLaunchOrchestrator | [`0x57899eB20fA65134FB680BA6d6Ee1693E7619366`](https://bscscan.com/address/0x57899eB20fA65134FB680BA6d6Ee1693E7619366#code) | `BrigidMemeLaunchOrchestrator.sol` |
| BrigidUncxV1LPLockerAdapter | [`0x7fd3BBada737dC9A90F23dDA30373fF163e2A29A`](https://bscscan.com/address/0x7fd3BBada737dC9A90F23dDA30373fF163e2A29A#code) | `BrigidUncxV1LPLockerAdapter.sol` |
| BrigidStaking | [`0xF5cbdf0E779B14fc0598166F75c87d08668b6D42`](https://bscscan.com/address/0xF5cbdf0E779B14fc0598166F75c87d08668b6D42#code) | `BrigidStaking.sol` |
| BrigidRevenueRouter | [`0x55A4D0f14dc69fEa578fA4865b7e7E3b5eB5Be00`](https://bscscan.com/address/0x55A4D0f14dc69fEa578fA4865b7e7E3b5eB5Be00#code) | `BrigidRevenueRouter.sol` |

Generated project tokens, vaults, liquidity locks, and PancakeSwap pairs have
per-launch addresses. The table above identifies the shared Brigid Forge
protocol contracts used by the dApp.

## Build From A Clean Clone

Prerequisites:

- Node.js 20 or newer
- Foundry (`forge`)

```bash
npm ci
npm run build
```

`npm ci` installs the pinned OpenZeppelin dependency. The build uses separate
Foundry profiles for the Solidity `0.8.33` launch contracts and Solidity
`0.8.24` staking/revenue contracts, matching the compiler families recorded in
the deployment manifest. A build does not require a wallet, private key, RPC
URL, or BscScan API key.

For optional read-only network work, copy [`.env.example`](.env.example) to a
local `.env` and provide your own public or private RPC endpoints. Never commit
the populated file.

## Source And Deployment Version Policy

- Files under [`contracts/`](contracts/) are the curated public contract bundle.
- [`deployments/bsc-mainnet.json`](deployments/bsc-mainnet.json) maps active
  mainnet addresses to their public source paths and compiler versions.
- A deployed address must be reviewed against its BscScan-verified source and
  the tagged public release identified by the deployment manifest.
- Development changes do not silently replace the source record for an already
  deployed address. A new deployment or source release receives an updated
  manifest entry and tag.

## Contract Source Index

- [Vault and launch core](contracts/README.md#vault-and-launch-core)
- [LP locking](contracts/README.md#lp-locking)
- [Launch orchestrators](contracts/README.md#launch-orchestrators)
- [Staking and revenue](contracts/README.md#staking-and-revenue)

## Security And Audit Disclosure

See [`SECURITY.md`](SECURITY.md) for responsible disclosure instructions.

Brigid Certified records completion of Brigid Forge structural launch
requirements. It is **not** a substitute for an independent third-party smart
contract audit, and this repository does not claim otherwise. No third-party
audit report is included unless one is explicitly named and linked in a future
release.

## Official Links

- [Launch System](https://brigidforge.com/launch/)
- [Public launch records](https://brigidforge.com/launches/)
- [Brigid Beacon](https://brigidforge.com/beacon/)
- [BRIGID token](https://brigidforge.com/token/)
- [Whitepaper](https://brigidforge.com/docs/brigid-forge-whitepaper.pdf)
- [Launch guide library](https://brigidforge.com/guides/)
- [Brigid Launch Standard](https://brigidforge.com/brigid-launch-standard/)
- [Disclosures and risk notice](https://brigidforge.com/disclosures-risk-notice/)

## Publication Scope

This repository intentionally publishes the production-facing Solidity review
surface, build configuration, BNB Chain deployment evidence, security policy,
and public development history. It intentionally excludes:

- private keys, secrets, populated environment files, and private RPC URLs
- hosted backend and indexer implementation
- deployment credentials and operational runbooks
- local administrator tooling
- internal adversarial harnesses and private infrastructure configuration

Those exclusions do not change the public source mapping for the deployed
contracts listed above.

All rights are reserved unless and until a final public license is selected.
