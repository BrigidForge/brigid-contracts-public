# Security Model

This repository is intended to expose the public contract surface and the core security expectations around it.

## High-Level Principles

- immutable contract-first enforcement
- no hidden operator override path in the core vault contracts
- delayed withdrawals with public observability
- permissionless execution after the enforced delay window
- explicit structural linkage between launch components where applicable

## Important Notes

- production behavior should always be verified against deployed source and official explorer verification
- the published bundle focuses on contract source and public reference material rather than operational tooling
- official deployment records and explorer verification should be treated as the final reference for live addresses
