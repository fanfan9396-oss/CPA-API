---
name: relay-operations
description: Operate and release a CPA + New API relay safely: synchronize upstream changes into maintained forks, review customization conflicts, build immutable component packages, deploy to staging or production, verify health, and roll back with evidence. Use for upstream updates, release preparation, deployments, incident recovery, and handoff; never mutate production without explicit authorization.
---

# Relay Operations

Use this skill as the operational contract for the relay project. The repository is an integration root, not a copy of either upstream application:

- `CPA-API` owns integration files, Compose/Mock verification, release manifests, and deployment tooling.
- `new-api-main` is the maintained New API fork. Its `origin` is the project fork and its `upstream` is `QuantumNous/new-api`.
- `CLIProxyAPI-main` is the CPA component. Its upstream is `router-for-me/CLIProxyAPI`; the management panel is selected separately for CPA releases.
- Production runs fixed binaries under native systemd. Production does not build code and does not pull a branch. Deploy an immutable package built from recorded SHAs.

## Non-Negotiable Rules

1. Never deploy `main`, `latest`, a moving tag, or an uncommitted worktree. Record root SHA, component SHAs, panel ref when applicable, package SHA-256, migration status, and rollback location.
2. Never run `git pull` in production. Fetch and build in a controlled workspace, verify the package, upload it, and run the repository installer.
3. Keep New API and CPA releases independent unless a compatibility change requires a reviewed `full` package. A New API-only change must not restart or replace CPA.
4. Do not copy `.env`, OAuth/auth files, provider credentials, database dumps, Redis snapshots, browser profiles, logs, or `dev-docs/` into Git or a release artifact.
5. Do not resolve an upstream conflict by accepting “theirs” or “ours” globally. Review each conflict at the owner boundary, especially auth, wallet/billing, relay conversion, request policy, abuse review, migrations, and provider routing.
6. No completion claim without fresh evidence from the target environment. Separate local tests, Mock tests, Staging tests, browser tests, and production health checks.

## State Machine

Every update moves through these states and records the current state:

`DISCOVER -> CANDIDATE -> REVIEW -> VERIFY -> PACKAGE -> STAGING -> PROMOTE -> PRODUCTION -> OBSERVE -> CLOSED`

Any failed gate moves to `BLOCKED` or `ROLLBACK`; it never silently advances.

## Upstream Synchronization

1. Read the current integration root, submodule SHAs, branch, worktree status, active production version, and latest release manifest.
2. Fetch the selected upstream ref by SHA or reviewed tag. Do not update a submodule by checking out a moving default branch.
3. Create a dated `update/upstream-YYYYMMDD` branch from the maintained fork branch. Keep product changes in separate commits or branches; do not mix the sync commit with new feature work.
4. Merge the upstream ref with `--no-ff`. Resolve conflicts manually and record the conflict files and decisions. If New API audit/content-policy protected paths are touched, stop for explicit review before continuing.
5. Calculate divergence before and after the merge:

   `git rev-list --left-right --count upstream/main...<candidate>`

   Inspect `git diff --name-status <last-approved-sha>..<candidate>` and search for migrations, auth, wallet, billing, provider, relay conversion, streaming, and frontend changes.
6. Run the smallest sufficient test matrix. Expand it when the diff crosses an owner boundary; do not use a green unrelated test as a release decision.
7. Merge the reviewed candidate into the project release branch only after all gates pass. Push the fork branch and integration root separately, then verify remote SHAs.

## Merge Decision

Direct merge is acceptable only when all of these are true:

- the fork candidate contains the current approved project commits;
- no unresolved conflict or protected-path change lacks an owner decision;
- database migration and rollback implications are understood;
- the focused tests, Web typecheck/build, and local integration tests pass;
- Staging behavior is compatible with current CPA channels, New API keys, wallet/usage rules, and public route settings;
- the release manifest can describe one exact reproducible package.

If any condition is false, keep the candidate branch and do not promote it. Rebase is not a substitute for understanding a semantic conflict.

## Verification Matrix

- Every change: `git diff --check`, package manifest/checksum validation, focused tests, and clean tracked worktree.
- Go/backend or security changes: focused Go tests plus relevant controller/service/model tests.
- Web/UI changes: `bun run typecheck` and `bun run build`; use browser verification for changed admin/member flows.
- Relay/provider/stream changes: local Mock normal/error/timeout/stream tests, then bounded Staging requests through New API -> CPA -> provider.
- Auth/wallet/billing/migration changes: positive and negative permission/quota/settlement tests, database migration review, backup/restore evidence, and staged rollback rehearsal.
- Production promotion: backup success, package SHA match on server, only intended systemd service restarted, local and public health endpoints, all dependent services active, recent logs free of fatal/panic, and a written rollback target.

## Package and Deployment

Prefer the manual `workflow_dispatch` release workflow. Select `component=new-api`, `cpa`, or `full`, and provide immutable refs. The build must produce `manifest.txt`, `SHA256SUMS.txt`, and a package whose manifest keeps `production_deploy=not-authorized` until the operator authorizes deployment.

### Component Scope Isolation

`component` describes the contents of the immutable package. `mode` describes the components authorized to change in this installation. They are separate values and must never be conflated.

For a `full` package:

- `--new-api-only` may copy and restart only New API.
- `--cpa-only` may copy CPA and `management.html`, and restart only CPA.
- `--all` is the only mode that may update and restart both components.

Before any target write or service restart, run the installer with `--plan`. The plan must verify the manifest and package checksums and emit `release`, `manifest_component`, `requested_mode`, `will_update`, and `will_not_update`. A plan is read-only. If the plan does not exactly match the authorization, stop as `BLOCKED`.

After a selective install, verify the unselected binary SHA-256, management panel SHA-256, mtime, and systemd `ActiveEnterTimestamp` are unchanged. Record the plan and the actual restart set in the release event. The installer must fail closed for incompatible `mode:component` combinations.

For installer changes, run `bash tools/test-install-release.sh` before any Staging deployment.
The deployment order is:

1. Freeze the candidate SHA and package SHA; review the file list for secrets.
2. On the target server, create a rollback directory and save the current binary, unit file, environment file, and required database/Redis backup evidence.
3. Upload the package and `tools/install-release.sh` to a temporary path.
4. Verify the manifest and checksums on the server before installation.
5. Run the matching installer mode (`--new-api-only`, `--cpa-only`, or `--all`).
6. Wait for readiness; an immediate connection refusal during restart is not a result.
7. Verify version, binary SHA, service status, local health, public HTTPS routes, Nginx syntax, and dependent services.
8. Remove temporary upload files but retain the release directory and rollback materials.
9. Observe errors, latency, 429s, streaming behavior, usage/wallet settlement, and provider health for the agreed window.

Never automatically roll back a database. First determine whether the new binary ran an irreversible migration; preserve current evidence, then switch the binary and service only when application rollback is sufficient.

## Reporting and Handoff

Every run writes a concise event to the project log or approved handoff record containing: date, root/component SHAs, upstream ref, package and binary hashes, environment, commands/tests, backup and rollback paths, fresh results, unverified planes, and the next decision. Never record credentials or raw tokens.

The final report must distinguish:

- pushed versus merely local;
- built versus installed;
- service healthy versus feature accepted;
- Staging evidence versus production evidence;
- verified behavior versus remaining risk.

When the same boundary fails three times, stop retrying local merges and reopen the owner, compatibility, and rollback diagnosis.
