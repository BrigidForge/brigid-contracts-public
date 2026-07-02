# Security Policy

Brigid Forge welcomes responsible security review of the public contract bundle.

## Reporting A Security Issue

Please report suspected vulnerabilities privately by email:

`dev@brigidforge.com`

Include as much detail as you can safely share:

- affected contract file and function
- impact description
- exploit conditions or assumptions
- proof-of-concept steps or test case, if available
- suggested remediation, if known
- whether the issue has been shared with anyone else

We will acknowledge credible reports as quickly as practical and may follow up
for reproduction details.

## Public Scope

The public review scope is the contract bundle in this repository:

- `contracts/`
- `contracts/imports/`
- `contracts/staking/`

This repository intentionally excludes private deployment scripts, environment
files, signer material, backend services, local admin tools, operational
runbooks, and generated artifacts.

## Safe Harbor Expectations

Do not test against live Brigid Forge systems, production contracts, user funds,
hosted services, private infrastructure, or third-party integrations without
explicit written authorization.

Do not:

- access or attempt to access private keys, seed phrases, env files, databases,
  logs, admin panels, or non-public systems
- perform denial-of-service testing
- exfiltrate data
- move, lock, burn, or otherwise interfere with assets
- publicly disclose a suspected vulnerability before Brigid Forge has had a
  reasonable opportunity to investigate and remediate

Good-faith review of the public source bundle, local reproduction, and private
reporting are welcome.

## External Review Proposals

If you are offering a paid or unpaid external review, please send:

- proposed scope
- timeline and availability
- quote or rate, if applicable
- public profile or prior validated findings
- sample report format
- disclosure or conflict notes

For now, use `dev@brigidforge.com` as the preferred technical/security contact.
