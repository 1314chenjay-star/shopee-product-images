# TinySnow Control Plane Contract

This file is public, sanitized engineering governance. Private Owner/Master Context must never be copied into this public repository.

## Canonical GitHub topology
- Repository: `1314chenjay-star/shopee-product-images`
- Default branch: `main`
- Experimental branch: `v4c-universal-product-engine`
- Stable branch: `tinysnow-tool-only`
- Locked stable HEAD: `5d49f061e140813b3d229520e9e530f86b27b640`
- A branch name is never a repository name. Always resolve repository first, then branch inside it.
- Scheduled GitHub Actions must be anchored on the default branch; feature-branch schedules are not a liveness guarantee.

## Roles
- OWNER: human approval only for paid/image/stable/irreversible/irreconcilable/permission/major-business boundaries.
- ORCHESTRATOR: decide, issue scoped commands, dispatch, monitor, validate, and issue targeted repair commands. No business implementation.
- WORKER: implementation, commits, workflows, tests, artifacts, checkpoint, heartbeat. Must stay inside command scope.
- MONITOR: read-only status/health reporting. No commits, dispatch, or implementation.
- SUPERVISOR: machine liveness/dispatch of already-approved zero-paid recovery only. No new business decisions.

## Command contract
Every new command must bind itself to live state with:
`issuer_role`, `repository_full_name`, `branch`, `task_id`, `expected_checkpoint`, `observed_head`, and `idempotency_key`.

A command is stale and must not execute if HEAD or checkpoint changed after it was issued. Duplicate idempotency keys must not execute twice.

## Concurrency and recovery
- One primary orchestrator.
- One active worker per task.
- Fresh active worker/workflow => replacement waits.
- Stalled worker => preserve checkpoint; never retry the old attempt; replacement resumes first pending delta only.
- Every write re-fetches/validates current HEAD; never force push.
- Completed/SEALED entries are fingerprint-only and never rerun.

## Data and safety
- Stable is immutable from the control plane.
- Paid API, real image generation/editing, stable merge/release, irreversible high-risk changes, irreconcilable authoritative conflicts, required permission failures, and major business-direction changes require Owner approval.
- Large authoritative artifacts are processed in an Actions/local workspace, not repeatedly streamed through connector text APIs.
- Source Truth and Memory remain separate.
- Private Master Context / Direction / Stage / Owner files are forbidden in this public repository.

## State precedence
1. Live GitHub repository/branch/workflow/checkpoint/heartbeat.
2. Durable project control files.
3. Private Owner Dashboard / Stage Ledger / Master Context.
4. Chat text.

When levels disagree, higher precedence wins and stale lower-level state is updated rather than treated as current.
