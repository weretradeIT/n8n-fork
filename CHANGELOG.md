# Changelog

All notable changes to the `n8n-fork` project will be documented in this file.

## [Unreleased] - 2026-03-05

### Added
- Created `n8n-fork` repository structure to isolate n8n from the main monorepo (`weretradeInfantrie_1.0`).
- Added `Dockerfile.oidc-unlocked` to properly build the patched n8n image instead of relying on runtime volume mounts.
- Added separate `deploy/lair404/docker-compose.yml` and `deploy/n1njanode/docker-compose.yml` to support multi-server deployments.
- Included `llm-shared-net` configuration in `docker-compose.yml` to allow direct communication with the LiteLLM gateway.

### Changed
- Moved `.js` patches for OIDC, Insights, and module-registry from `weretradeInfantrie_1.0/tools/n8n/` to `n8n-fork/patches/`.
- Moved `weretradeInfantrie_1.0/docs/n8n-*` files to `n8n-fork/docs/`.
- Updated `CLAUDE.md` to reference the new `n8n-fork` directory.

### Removed
- Removed the deprecated `weretradeInfantrie_1.0/tools/n8n/` directory.
- Removed volume mounts for patch files from `docker-compose.yml` as they are now compiled into the Docker image.