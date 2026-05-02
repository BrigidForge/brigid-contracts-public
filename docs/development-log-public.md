# Public Development Log

This document summarizes major public-facing milestones for the Brigid Forge contract system.

It is intentionally narrower than the full internal development log and focuses on contract evolution, hardening, testing, and release readiness.

## 2026-05-01

### Subscription lifecycle automation and infrastructure resilience

- Deployed production n8n workflow infrastructure for the Brigid ecosystem. Handles subscription lifecycle events (started, expiring, expired, renewed), beacon event monitoring, launch completion handling, and system health monitoring.
- Subscription events are authenticated via HMAC-signed webhooks with per-event IDs to prevent replay attacks.
- Hardened the launch completed handler to prevent false-success signals from incomplete launch states.
- Formalized server disaster recovery procedures and hardened backup capture for Forgejo and Postgres, fixing path issues that could produce empty or missing backup files under certain failure modes.

## 2026-04-29

### Contract hardening suite — public repository synchronized to audit branch

- Synchronized the public contract repository to the canonical audit-branch versions. All 7 contracts are now byte-identical between the public and private repositories, verified with `diff -q`.
- **BrigidVault**: Added dual balance-delta verification in `fund()` and `executeWithdrawal()`. Rejects fee-on-transfer tokens, silent-failure tokens, and balance-manipulating tokens by requiring that the pre/post balance delta equals the stated amount. Cleaned up expired-request handling.
- **BrigidVaultFactory**: Added `BrigidTokenRegistry` whitelist enforcement so only approved tokens can be used in vault creation and launch workflows. Added explicit bounds on `withdrawalDelay`, `executionWindow`, and `cancelWindow`. Added overflow protection on delay+window arithmetic. Replaced shared EIP-712 nonces with per-deployer single-use nonces. Added `MAX_START_OFFSET` (5 years) and `MAX_CLIFF_DURATION` (10 years) caps. Decoupled ownership transfer so new owners are not automatically authorized.
- **BrigidLaunchOrchestrator**: Added an updateable `launchFee` with `onlyOwner` setter and `LaunchFeeUpdated` event. Replaced the inline-only native-refund path with a pull-pattern fallback (`pendingNativeRefunds` + `claimNativeRefund`) to prevent launches from being bricked when deployers reject ETH.
- **BrigidTokenRegistry**: Previously internal-only; added to the public contract bundle as a required dependency for the factory.

## 2026-04-20

### Launch-session authorization hardening and live-RPC fork validation

- Strengthened authorization on the public launchpad's server-side launch-session surface. Each session interaction now requires a wallet-signed proof tied to the wallet that created the session, so unrelated callers cannot read, modify, or delete another wallet's launch record.
- Tightened the launchpad-to-service trust boundary so callers that omit an origin can no longer bypass the origin check.
- Validated the BSC testnet fork test against a live RPC for the first time, confirming the launch orchestrator's PancakeSwap integration behaves correctly against the real router and factory instead of only against a synthetic fork.
- Re-ran the full contract, service, launchpad, and browser-integration test tiers end-to-end with the hardened authorization model in place.

## 2026-04-11

### Launch workflow and verification alignment

- Advanced the public launch workflow and related contract-integration surfaces.
- Improved launch verification behavior and reliability around certification and status handling.
- Tightened launch support behavior so operational issues did not create misleading completion signals.

## 2026-04-09

### Beacon indexing and RPC efficiency improvements

- Reduced infrastructure load tied to contract-event indexing and read activity.
- Improved batching and polling behavior for contract-observation flows.
- Added better runtime instrumentation so contract-related infrastructure could be monitored more accurately.

## 2026-04-06

### Public launch safety hardening

- Completed an adversarial testing pass for the public launch flow.
- Strengthened chain-truth validation, wallet consistency checks, and protection against false-success states.
- Expanded automated coverage around launch execution and recovery behavior.

## 2026-04-05

### Full adversarial security analysis

- Performed a structured adversarial review of the live Brigid contract suite against the whitepaper and current deployed behavior.
- Produced a ranked set of findings covering configuration risk, permit replay risk, withdrawal-delay edge cases, observability limitations, and registry/factory design tradeoffs.
- Used those findings to drive follow-up hardening, documentation, and operational review.

## 2026-03-21

### Production freeze and release-readiness pass

- Completed a structured production-freeze review of the vault system.
- Verified contract/factory alignment, documentation coverage, and release readiness for the then-current version.

## 2026-03-18

### Factory and vault hardening pass

- Strengthened deployment-time validation and post-deploy verification behavior.
- Improved request lifecycle handling and related safety checks.
- Tightened deployer authorization and batch-operation safeguards.

## 2026-03-15

### Beacon deployment canonization

- Standardized the live Beacon-compatible contract deployment posture around the active vault/factory implementation.
- Brought public monitoring and deployment reference material into closer alignment with the active contract set.

## 2026-03-12

### Beacon-compatible factory validation

- Validated the Beacon-compatible contract deployment path on BSC testnet.
- Confirmed the active factory implementation and indexed validation-vault workflow.

## 2026-03-11

### Architecture stabilization

- Stabilized the BrigidVault architecture around immutable configuration and scheduled unlock behavior.
- Advanced the related public and operator-facing contract interaction surfaces.

## 2026-03-07

### First stable operator-console release

- Finalized the first stable UI release for BrigidVault interaction and monitoring.
- Confirmed the supporting contract interaction patterns for request, cancel, and execute flows.

## 2026-03-04

### Withdrawal workflow rehearsal

- Completed an early end-to-end rehearsal of the contract interaction workflow on BSC testnet.
- Validated core vault request and execution behavior against the live chain environment.

## 2026-03-03

### Documentation framework established

- Created the first structured documentation set covering standards, integration, deployment, parameters, security, and monitoring.
- Transitioned the project toward a publishable contract framework with clearer public-facing structure.

## 2026-03-01

### Internal hardening cycle completed

- Completed a major contract hardening cycle before the formal audit phase.
- Expanded testing coverage and clarified key invariants around withdrawals, scheduling, and token handling.

## Notes

- This log is intended as a public milestone summary, not a full operational record.
- For canonical published source, use the contracts in this repository together with the deployment and verification docs.
