# Public Development Log

This document summarizes major public-facing milestones for the Brigid Forge contract system.

It is intentionally narrower than the full internal development log and focuses on contract evolution, hardening, testing, launch infrastructure, public release readiness, and source transparency.

## 2026-07-01

### Production public-surface redesign and live data wiring

- Promoted the redesigned public website routes into the canonical production surface.
- Wired the redesigned launch record views to live Beacon data instead of static preview content.
- Re-themed Launchpad, Beacon, and Staking UI surfaces around one consistent Brigid Forge visual system.
- Self-hosted production fonts across the website, Launchpad, Beacon, and Staking tools so the public app surfaces no longer depend on third-party font delivery at runtime.
- Preserved core buy/swap behavior while restyling the public BRIGID buy surface to match the production redesign.

## 2026-06-30

### Custom vault limits and legacy evidence compatibility

- Added caps for fast-access custom vault configurations so public launch flows stay inside the intended trust and timing model.
- Extended Beacon/operator handling for legacy LP lock snapshots so older production launch evidence can still be displayed and reviewed.
- Fixed legacy launch profile evidence display and allocation presentation so historical public launch records remain understandable after the newer launch-profile model.
- Recorded the BRIGID legacy LP lock evidence fix in the release evidence record.

## 2026-06-29

### External LP locker integration and mainnet meme launch cutover

- Added an external UNCX V1 LP locker adapter and wired the launch orchestrators to support external LP-lock provider references.
- Added deployment, wiring, and finalization scripts for the external LP locker cutover.
- Expanded contract tests and mainnet-fork tests around the external locker adapter, orchestrator state machine behavior, and refund handling.
- Updated Beacon schema, API, worker, confidence evaluation, and operator UI surfaces to store and present external LP lock evidence.
- Updated Launchpad config, helper logic, tests, and environment templates for the external LP locker flow.
- Prepared and recorded the mainnet meme orchestrator cutover, including launchpad UI changes, executor integration, smoke probes, BscScan verification evidence, and public proof packet updates.
- Clarified public meme launch fee disclosure after the cutover and recorded the production deploy evidence.

## 2026-06-28

### Public launch gate removal, buy/sell flow hardening, and local admin isolation

- Removed legacy public launch gates and obsolete WalletConnect/probe-only routes after production launch controls moved into their final posture.
- Added sell mode to the BRIGID swap tool and hardened buy/sell wallet approval behavior so MetaMask approvals remain user initiated.
- Improved buy widget readiness, balance gating, wallet disconnect behavior, status spacing, and success presentation.
- Hardened launch support notifications so operational support messages do not create misleading launch-completion signals.
- Untracked the admin panel from the production monorepo surface and moved it toward a local-only desktop operator tool.
- Added and refined local desktop launch scripts for the admin panel, including headless lifecycle cleanup and Finder-safe path handling.

## 2026-06-27

### Production launch proof, certification freshness, and mobile buy flow stabilization

- Added a public launch proof page for production BRIGID launch evidence.
- Fixed stale Beacon certification badge caching and aligned showcase trust labels with issued certification state.
- Hardened launch profile image freshness, token image revalidation, founder profile token image persistence, and duplicate-description prevention.
- Preserved executor launch profile state across resume paths.
- Improved custom token image uploads and launch showcase token-logo alignment.
- Blocked meme launches when required BNB liquidity is short.
- Added and refined BRIGID buy-page WalletConnect support, including mobile connect recovery, network switching, QR pairing, direct WalletConnect swap submission, approval state persistence, and successful-swap highlighting.
- Added the founding holder giveaway rules page and tightened the public rules, timing language, and official links.
- Recorded weekend promotion fee-gate evidence.

## 2026-06-26

### Weekend fee promotion and launch-gate transition

- Enabled the weekend no-launch-fee promotion and recorded the production deployment.
- Polished the production launch-gate transition as the public site moved from prelaunch posture into live production operation.
- Updated BRIGID ecosystem token and market presentation panels around the live token state.

## 2026-06-25

### Fee quote gates, profile/logo sync, WalletConnect expansion, and environment isolation

- Wired mainnet launch fees to the revenue router and recorded USD launch fee quote gate evidence.
- Synced meme token logos and launch-profile logo updates into Beacon vault records and recent-launch displays.
- Fixed Beacon meme launch routing, launch success links, pending badge wrapping, and project trust labels.
- Added WalletConnect support to the buy page and Beacon operator surface, including target-chain pinning and hosted build environment tracking.
- Updated the standalone-repo environment isolation checker after the production/test/preview/staging repo split.
- Published updated whitepaper assets and recorded BRIGID logo production verification.
- Recorded launch-readiness evidence needed for production activation tracking.

## 2026-06-24

### Beacon discovery, project identity, and production sync

- Improved Beacon launch discovery, exact project ID lookup, project ID prefix search, and meme project ID derivation.
- Added fallbacks for empty Beacon lookup results so public launch records can still be found through alternate identifiers.
- Clarified Beacon LP lock withdrawal state and compacted showcase feed payloads.
- Refined vault/project chooser layout and certification badge placement in the Beacon operator surface.
- Applied the Forge website theme across application surfaces and fixed launchpad prelaunch buy-gate/operator copy.
- Synced production `main` with staging updates and launch gates before the production launch window.

## 2026-06-23

### Standalone production environment repo and deploy dependency fixes

- Created the flattened standalone production/mainnet environment repo snapshot so one commit represents the whole production system state.
- Documented the environment-repo topology and pruned environment templates that no longer belong in production.
- Fixed Beacon UI build/deploy dependency resolution around Vite client types, package-path lookup, and hosted deploy dependency refreshes.
- Retried production Beacon deployment and bumped Beacon/Staking metadata where needed for hosted deploy refreshes.
- Kept the public contract log as part of the production snapshot while preserving the public mirror as the publication target.

## 2026-06-20 to 2026-06-22

### Meme launch fee quotes, reviewer flows, wallet guidance, and public SEO links

- Added signed meme launch fee quote support across contracts, executor, and Launchpad.
- Wired meme launches to one-year Beacon access and clarified meme vesting/fee preview behavior.
- Added preview quick-launch, reviewer onboarding, testnet faucet, and environment-banner flows for review and testing surfaces.
- Added wallet compatibility advisories across Launchpad, Beacon, Staking, and website surfaces, then refined their placement and wording.
- Added MetaMask browser and WalletConnect guidance improvements for mobile users.
- Added Brigid Forge SEO links and static route updates across public surfaces, including the public contract mirror README.

## 2026-06-18

### Public contract mirror refresh

- Synchronized the public contract bundle to the latest approved private contract sources.
- Added the current Meme Launch registry/orchestrator source files to the public bundle.
- Added the active staking, revenue router, and subscription contract sources to the public bundle.
- Removed public-facing support docs other than this development log so the repository exposes only approved contract source, the README, and the public development log.

### Public transparency documentation and Beacon PWA presentation pass

- Updated the public website's Brigid Transparency System explanation so the Beacon notification layer is described as part of the system rather than as a generic dashboard feature.
- Added public-facing Beacon Web App / PWA notification presentation using the actual Brigid Beacon app artwork and notification imagery. The presentation now shows holder-facing vault activity notifications inside a phone-style frame.
- Consolidated the Brigid Beacon section to reduce repeated alert/channel language. The app notification panel now carries the primary explanation of how Beacon reaches holders.
- Removed obsolete simulated operator-panel and withdrawal-interface mockups from the website and static launch-guide pages. The public vault lifecycle explanation now focuses on the contract path: request, notify, wait, execute, archive.
- Updated the Brigid Vault section to emphasize user-selected deployment parameters instead of fixed example values. The public page now calls out configurable choices such as developer allocation, treasury allocation, beneficiary address, withdrawal delay, vesting schedule, and tier-dependent custom vaults.
- Tightened BRIGID token utility language so it no longer implies unsupported dashboard functionality. The utility list now keeps hard requirements where they apply (launch/BLS path and Beacon monitoring access) and uses future ecosystem development language for future tools.
- Updated optimized asset generation to stop producing the removed vault-withdrawal mockup, preventing future builds from recreating deleted public assets.
- Verified the website build after the documentation and asset updates.

### Risk notice and production launch verification refinements

- Added risk-notice footer links across public app surfaces.
- Fixed launchpad dependency audit warnings and reviewed mainnet launch resume verification behavior before reverting an unsafe resume-change attempt.
- Updated contract fork tests to use the configured BSC RPC.

## 2026-06-12

### Mainnet release guardrails and environment isolation

- Added environment isolation guardrails across hosted deployment tooling so genesis, testnet, staging, and mainnet profiles are handled explicitly rather than inferred from local state.
- Normalized deployment environment handling and branch routing so production deploys from `main` use the intended runtime configuration.
- Added mainnet staging/readiness tooling, runbook material, and pre-launch guardrails for the switch from testnet validation toward production launch.
- Expanded deploy checks and cleanup behavior to avoid stale generated paths, incorrect repository detection, or accidental cross-environment configuration drift.
- Recorded mainnet pre-LP readiness checks and clarified remaining launch gates so public launch readiness is easier to audit before activation.
- Added isolated launch stack deployment scripts, BRIGID genesis bootstrap deployment scripts, and mainnet/staging rehearsal material.

## 2026-06-08 to 2026-06-10

### Mainnet rehearsal scripts and deployment-path hardening

- Added mainnet launch rehearsal scripts and mainnet admin-control rehearsal scripts.
- Reduced Slither launch cleanup findings in preparation for public release.
- Hardened launchpad smoke flow and WalletConnect recovery behavior for hosted mainnet validation.
- Hardened Beacon mainnet launch indexing and production configuration.
- Added documentation for deployment separation, environment sync, deployment gates, and go-live dependencies.

## 2026-05-31

### Security audit remediation and public source synchronization

- Remediated the 2026-05-31 security audit findings in the active contract codebase and synchronized the remediated contract sources into the public repository.
- Updated public Slither cleanup sources and filtered non-production contracts from the Slither gate so public analysis focuses on deployable contract surfaces.
- Recorded residual-risk signoff for the Slither pass after cleanup, keeping the public audit posture aligned with the current release candidate.
- Expanded isolated deploy roots and related environment checks so the public contract release process matches the hardened deployment workflow.
- Hardened Launchpad, Beacon, Executor, Admin, and Staking surfaces around the same remediation cycle, including dependency audit cleanup and removal of stale validation shortcuts.
- Added Beacon meme launch evidence support and linked meme developer vaults to Beacon projects.

## 2026-05-27

### Meme launch path introduced

- Added the Meme Launch orchestrator to the contract system.
- Added guided meme launch UI and server-side testing preparation in Launchpad.
- Added executor support for meme launch workflow analysis and environment handling.
- Preserved the same public release principle as the standard launch path: launch state must be backed by contract and Beacon evidence rather than frontend-only status.

## 2026-05-17 to 2026-05-24

### Deployment automation, recovery, and public certificate UX

- Added and hardened testnet server deployment automation, including remote environment apply mode, generated-path cleanup, and environment-audit cleanup behavior.
- Guarded hosted executor Beacon API configuration so hosted execution surfaces cannot silently point at an unintended Beacon API endpoint.
- Synchronized launch fee recipient and staking revenue router environment variables through the root environment tooling.
- Added mainnet switch runbook material and server environment guardrails to document the remaining production activation path.
- Added adversarial test orchestration and Slither runner workflow support earlier in the cycle so security checks could be run consistently before release gates.
- Added public launch certificate access, client-side certificate PDF generation, certificate layout refinements, and ecosystem return links.
- Improved mobile WalletConnect launch approvals, launch records, launch resume reliability, and failed-launch alerting.
- Hardened Beacon vault owner claim and withdrawal checks.

## 2026-05-11 to 2026-05-16

### Launch certificates, Beacon monitoring renewals, and public notifications

- Added AI-assisted launch certificate flow and public certificate access surfaces.
- Added launch-tier Beacon monitoring renewals.
- Stabilized Beacon viewer certification refresh and trusted LP lock observations in Beacon.
- Added project-level public notification setup and removed legacy advanced/email alert assumptions.
- Polished Beacon PWA install behavior, notification badge handling, and canonical Beacon host handling.

## 2026-05-03 to 2026-05-08

### Public testnet vault timing bounds and dynamic fee support

- Synchronized public testnet vault timing bounds in `BrigidVault` and `BrigidVaultFactory`, keeping the public contract sources aligned with the active testnet release posture.
- Kept public contract behavior focused on the hardened timing model that would later feed the security-audit remediation and release-candidate synchronization work.
- Added testnet launch timing and fee quote support.
- Added token adversarial tests and Beacon status adversarial coverage.
- Required fresher launch fee quotes, pinned launch fee quotes after swap, and tightened launch fee quote validity behavior.
- Added trust-view tests and same-day vault launch timing fixes in Launchpad.

## 2026-05-02

### Staking and revenue stack alignment

- Rotated the active BSC testnet staking and revenue stack to the BRIGIDPAY protocol token.
- Deployed and wired the testnet staking contract, revenue router, treasury destination, and burn destination for the updated protocol-token stack.
- Confirmed the router's hold-and-distribute model: product revenue accumulates in the router until owner-triggered distribution, then splits 50% treasury, 40% staking, and 10% burn.

## 2026-05-01

### Subscription lifecycle automation, tiered pricing, and infrastructure resilience

- Deployed production n8n workflow infrastructure for the Brigid ecosystem. Handles subscription lifecycle events (started, expiring, expired, renewed), beacon event monitoring, launch completion handling, and system health monitoring.
- Subscription events are authenticated via HMAC-signed webhooks with per-event IDs to prevent replay attacks.
- Hardened the launch completed handler to prevent false-success signals from incomplete launch states.
- Formalized server disaster recovery procedures and hardened backup capture for Forgejo and Postgres, fixing path issues that could produce empty or missing backup files under certain failure modes.
- Added tiered launch fees to the launch orchestrator and Launchpad pricing flow.
- Replaced early subscription assumptions in Beacon with launch-tier monitoring behavior.

## 2026-04-29

### Contract hardening suite - public repository synchronized to audit branch

- Synchronized the public contract repository to the canonical audit-branch versions. All seven contracts were byte-identical between the public and private repositories at that point, verified with `diff -q`.
- **BrigidVault**: Added dual balance-delta verification in `fund()` and `executeWithdrawal()`. Rejects fee-on-transfer tokens, silent-failure tokens, and balance-manipulating tokens by requiring that the pre/post balance delta equals the stated amount. Cleaned up expired-request handling.
- **BrigidVaultFactory**: Added `BrigidTokenRegistry` whitelist enforcement so only approved tokens can be used in vault creation and launch workflows. Added explicit bounds on `withdrawalDelay`, `executionWindow`, and `cancelWindow`. Added overflow protection on delay+window arithmetic. Replaced shared EIP-712 nonces with per-deployer single-use nonces. Added `MAX_START_OFFSET` (five years) and `MAX_CLIFF_DURATION` (ten years) caps. Decoupled ownership transfer so new owners are not automatically authorized.
- **BrigidLaunchOrchestrator**: Added an updateable `launchFee` with `onlyOwner` setter and `LaunchFeeUpdated` event. Replaced the inline-only native-refund path with a pull-pattern fallback (`pendingNativeRefunds` plus `claimNativeRefund`) to prevent launches from being bricked when deployers reject ETH.
- **BrigidTokenRegistry**: Previously internal-only; added to the public contract bundle as a required dependency for the factory.
- Updated Launchpad to fetch one EIP-712 permit per vault for the nonce-bound factory.

## 2026-04-24 to 2026-04-28

### Orchestrated launchpad token vaults and mobile approval hardening

- Added support for orchestrated Launchpad token vaults in the contract system.
- Added guarded fee collection, mutable orchestrator launch-fee controls, and RPC retry guardrails in Launchpad.
- Advanced the Meridian v4 Launchpad redesign, including segmented progress, phased vault creation, post-creation dashboard, activation flow, and landing polish.
- Hardened mobile WalletConnect and approval behavior through sequential approval cooldowns, iOS recovery fixes, route guards, and QR WalletConnect stabilization.
- Improved Beacon and Admin operator surfaces in parallel with launch workflow hardening.

## 2026-04-20

### Launch-session authorization hardening and live-RPC fork validation

- Strengthened authorization on the public launchpad's server-side launch-session surface. Each session interaction now requires a wallet-signed proof tied to the wallet that created the session, so unrelated callers cannot read, modify, or delete another wallet's launch record.
- Tightened the launchpad-to-service trust boundary so callers that omit an origin can no longer bypass the origin check.
- Validated the BSC testnet fork test against a live RPC for the first time, confirming the launch orchestrator's PancakeSwap integration behaves correctly against the real router and factory instead of only against a synthetic fork.
- Re-ran the full contract, service, launchpad, and browser-integration test tiers end-to-end with the hardened authorization model in place.
- Added signed launch-session API calls and per-session bearer tokens to Launchpad.
- Added API key support, stricter CORS handling, launch route hardening, and early adversarial API test coverage in Executor.

## 2026-04-13 to 2026-04-18

### Launch recovery, certification, and hosted deploy resilience

- Refined launch recovery and orchestrator-only wizard flows.
- Added orchestrator fee resolution and settled launch handling.
- Stabilized Beacon certification and indexing flows, including worker chunking behavior around indexing lag.
- Fixed managed LP lock Beacon handling.
- Hardened hosted artifact deploy recovery and mobile fee-token swap recovery.
- Polished wallet connection, launch activation, mobile review, and safe-area behavior across Launchpad.

## 2026-04-11 to 2026-04-12

### Workspace restructure and launch workflow alignment

- Established the post-restructure baselines for public contracts, Beacon, Launchpad, Executor, Staking, Testing, Docs, Archive, and Website workspaces.
- Advanced the public launch workflow and related contract-integration surfaces.
- Improved launch verification behavior and reliability around certification and status handling.
- Tightened launch support behavior so operational issues did not create misleading completion signals.
- Initialized the public contracts repository with the approved contract bundle and initial public development log.

## 2026-04-09

### Beacon indexing and RPC efficiency improvements

- Reduced infrastructure load tied to contract-event indexing and read activity.
- Improved batching and polling behavior for contract-observation flows.
- Added better runtime instrumentation so contract-related infrastructure could be monitored more accurately.

## 2026-04-05 to 2026-04-06

### Public launch safety hardening

- Completed an adversarial testing pass for the public launch flow.
- Strengthened chain-truth validation, wallet consistency checks, and protection against false-success states.
- Expanded automated coverage around launch execution and recovery behavior.
- Rebuilt the public Launchpad around componentized architecture, a dedicated RPC layer, and a formal test suite.
- Added hosted deployment docs, operator configs, and launch-status dependency fixes.

## 2026-04-01 to 2026-04-03

### Public launchpad release preparation

- Refreshed the public launch flow and related documentation after the `v0.9.0` public Launchpad cut.
- Applied audit fixes, wallet-prompt clarity improvements, metadata sync hardening, and public launch resume fixes.

## 2026-03-30

### Public Launchpad v0.9.0

- Cut the public Launchpad `v0.9.0` release.
- Established the first public launch wizard baseline that later carried the orchestrated token/vault launch flow.

## 2026-03-21

### Production freeze and release-readiness pass

- Completed a structured production-freeze review of the vault system.
- Verified contract/factory alignment, documentation coverage, and release readiness for the then-current version.

## 2026-03-18 to 2026-03-20

### Factory and vault hardening pass

- Strengthened deployment-time validation and post-deploy verification behavior.
- Improved request lifecycle handling and related safety checks.
- Tightened deployer authorization and batch-operation safeguards.
- Merged the BrigidVault `v2.1.0` production-freeze work through the active development branch into `main`.

## 2026-03-15

### Beacon deployment canonization

- Standardized the live Beacon-compatible contract deployment posture around the active vault/factory implementation.
- Brought public monitoring and deployment reference material into closer alignment with the active contract set.
- Archived legacy contracts after canonizing the active vault path.

## 2026-03-12

### Beacon-compatible factory validation

- Validated the Beacon-compatible contract deployment path on BSC testnet.
- Confirmed the active factory implementation and indexed validation-vault workflow.
- Added adversarial tests and invariant fuzz testing, with the contract suite passing the expanded validation set.

## 2026-03-11

### Architecture stabilization

- Stabilized the BrigidVault architecture around immutable configuration and scheduled unlock behavior.
- Advanced the related public and operator-facing contract interaction surfaces.
- Added public vault viewer UI work and cleaned repository artifacts around the active contract/dashboard surfaces.

## 2026-03-07

### First stable operator-console release

- Finalized the first stable UI release for BrigidVault interaction and monitoring.
- Confirmed the supporting contract interaction patterns for request, cancel, and execute flows.
- Followed with operator console UI improvements as the monitoring workflow matured.

## 2026-03-04

### Withdrawal workflow rehearsal

- Completed an early end-to-end rehearsal of the contract interaction workflow on BSC testnet.
- Validated core vault request and execution behavior against the live chain environment.

## 2026-03-03

### Documentation framework and v2 freeze established

- Created the first structured documentation set covering standards, integration, deployment, parameters, security, and monitoring.
- Transitioned the project toward a publishable contract framework with clearer public-facing structure.
- Finalized BrigidVault prior to the `v2.0.0` freeze, then cut the `v2.0.0` and `v2.1.0` freeze milestones after adversarial and testnet validation.

## 2026-03-01 to 2026-03-02

### Internal hardening cycle completed

- Completed a major contract hardening cycle before the formal audit phase.
- Expanded testing coverage and clarified key invariants around withdrawals, scheduling, and token handling.
- Stopped tracking generated build artifacts and validated the full withdrawal lifecycle on BSC testnet.

## 2026-02-28

### Brigid Launch Standard v1.0.0 candidate freeze

- Expanded invariant, fuzz, boundary, and adversarial sequencing tests for the vault system.
- Finalized the hard-expiry model and documented expiry boundary behavior.
- Froze BrigidVault `v1.0.0` ABI and bytecode artifacts with Solidity `0.8.33`.
- Published Brigid Launch Standard `v1.0.0` documentation and integration material.
- Recorded the first formal development-log entries around the public-release candidate.

## 2026-02-17 to 2026-02-27

### Vault architecture foundation

- Began from the hardened `ShieldVestingVault` implementation.
- Added configurable delay vault behavior, helper views, metadata events, guardrails, and full test coverage.
- Added the Beacon factory and registry path with strict factory-only certification.
- Renamed the Beacon suite into the BrigidVault suite and added purpose-hash and reentrancy hardening.
- Completed early malicious fuzz, invariant, indexing, naming, and factory reentrancy cleanup work.

## Notes

- This log is intended as a public milestone summary, not a full operational record.
- For canonical published source, use the contracts in this repository together with the deployment and verification docs.
- This update was curated from the public contract mirror history, the original source-repository histories, the flattened production environment repo history, and archived audit/report locations only as historical evidence.
- Archived reports are not treated as current security conclusions unless a newer active source or test run confirms the same status.
