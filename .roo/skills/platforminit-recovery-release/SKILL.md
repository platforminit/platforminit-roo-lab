---
name: platforminit-recovery-release
description: Use when preparing known-good checkpoints, tags, release artifacts, recovery docs, or broken-dev recovery.
---


# PlatformInit Recovery and Release Skill

## Recovery source

`platforminit-platform` is the stable recovery source.
`platforminit-roo-lab` may break dev.

## Minimum recovery chain

1. CH01 Create/Rebuild Host
2. CH02 Apply Host Baseline
3. CH03 Install k3s
4. CH04 Enable Platform
5. CH04.5 Deploy Identity Foundation
6. CH05 Deploy/Validate Operations Stack

## Known-good checkpoint requirements

- commit SHA
- branch
- workflow run IDs
- validated chapters
- warnings
- artifacts
- recovery instructions
- rollback/rebuild note

## Release artifact policy

- GitHub Releases: deployable bundles.
- GitHub Actions artifacts: logs, smoke outputs, reports, diagnostics.
