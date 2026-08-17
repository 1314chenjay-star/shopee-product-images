# TinySnow Project Constitution

This file is the highest engineering operating rule for TinySnow workers. It governs execution behavior; it does not override sealed stage locks or authoritative source records.

## Core rules

### AUTOMATION_FIRST
If the system can safely perform the work with existing repository state, workflows, connectors, checkpoints, or deterministic tooling, do not make the user orchestrate it manually.

### FASTEST_SAFE_PATH
Prefer the shortest deterministic safe path. Do not rerun a full pipeline merely for reassurance.

### DELTA_ONLY
Reuse completed results and modify only new or affected scope.

### SEALED_IS_FROZEN
PASS/SEALED stages are immutable unless all three are present: `regression_evidence`, `affected_scope`, and `rerun_reason`. Otherwise: `BLOCK_RERUN_NO_EVIDENCE`.

### CHECKPOINT_RESUME
Long-running work must checkpoint at natural durable boundaries. A worker restart must resume from durable state rather than rediscovering completed work.

### TARGETED_REPAIR
For a failure, read the terminal job/logs, identify the failure signature and affected path, patch only that path, then resume. Do not restart unrelated successful stages.

### PRE_MORTEM_REQUIRED
Before execution, check for repeat work, race conditions, missing checkpoints, stable mutation, paid/API cost, irreversible effects, privacy exposure, cross-product leakage, cross-variant leakage, and avoidable user operation.

### CONVERSATION_INDEPENDENT
Chat is an execution interface, not the sole database. Important technical state belongs in repository locks/checkpoints/handoff; private user context belongs in private storage, never public GitHub.

### NO_UNVERIFIED_FACT
UNKNOWN / CONFLICT / unproven variant mapping / model guesses are never promoted into authoritative product facts.

### SOURCE_TRUTH_SEPARATE_FROM_MEMORY
Authoritative source truth and learned/approved Memory remain separate stores with separate provenance and semantics.

### USER_IS_NOT_THE_ORCHESTRATOR
Do not require the user to shuttle instructions between workers, manage Git, workflow retries, tokens, patches, or checkpoints when automation can do it.

### STATELESS_REPLACEABLE_WORKER
Every worker must assume it can disappear. Read current HEAD, locks, checkpoints and recent terminal workflows before writing. Persist important deltas promptly.

### CONCURRENT_WORKER_SAFE
Before each write, re-read branch HEAD. If HEAD advanced, inspect the new commits and continue from the latest compatible state. Never force-push or erase another worker's delta.

### ZERO_PAID_AUTO_CONTINUE
Zero-paid, deterministic, reversible, non-stable, non-generation work may continue automatically. Stop for paid API, real image generation/editing, stable merge/release, irreconcilable authoritative source conflict, permission failure, or irreversible high-risk action.

### BUSINESS_VALUE_GATE
Before a new stage, major feature, architecture expansion, or long-running task, state the real downstream outcome it unlocks, why it is needed now, and the smallest validation that can prove it. Do not build merely because a technically cleaner design is possible.

### DEFINITION_OF_DONE
Every stage must have explicit exit criteria before it expands. When the criteria are met, close the stage and move on unless new regression evidence or a real downstream blocker appears. Avoid engineering perfectionism.

### SINGLE_NEXT_BEST_ACTION
Maintain one primary next action for the current dependency chain. Parallel work is allowed only when independent, race-safe, and not distracting from the main blocker. Prefer the smallest reversible action that unlocks the most downstream work.

### REAL_WORLD_VALIDATION
A technical PASS is not automatically a product/business PASS. After an important infrastructure capability is ready, validate it at the appropriate boundary with representative real products, real exports, or real platform flows before scaling broadly.

### FRESHNESS_GUARD
Treat HEADs, workflow state, platform/API behavior, policy, external rules, and other time-varying state as stale until rechecked at the point of use. Historical values remain history, not current truth.

### NO_BUSYWORK
Do not create commits, workflows, reruns, diagnostics, or tests merely to show activity. Every action must remove a real blocker, validate a necessary assumption, reduce a material risk, or satisfy an explicit Definition of Done.

### RUNAWAY_PROTECTION
The same failure signature may receive at most three evidence-based distinct repair attempts. Without new evidence, do not retry. After the third failure, perform an architecture/assumption review instead of a fourth blind repair. Autonomous work must have scope limits, checkpoints, and stop conditions.

### ROLLBACK_FIRST
Before any change that could damage completed work, identify the last-good checkpoint and deterministic rollback path. No autonomous high-risk mutation without a recovery route.

### RULE_HYGIENE
Do not grow prompts indefinitely. Consolidate equivalent rules, mark obsolete rules superseded, and move durable behavior into this Constitution, machine gates, locks, tests, and handoff state.

### STAGE_CLOSURE
When a stage closes, persist the Definition-of-Done result, key evidence, remaining risk, permanent lessons, current state, and the single next best action. Do not leave completion truth only in chat.

## Permanent product safety
- TinySnow is all-category, not sports-only.
- Do not invent brand, material, size, dimension, feature, accessory, certification, warranty, gift, model, product text, pocket, performance, or variant mapping.
- Exact identity and provenance gates take precedence over convenience.
- Locked/approved outputs are not regenerated without explicit evidence and scope.

## Failure handling
Incident → Root Cause → Permanent Rule → Machine Enforcement → Regression Test.
Maintain `_system/governance/failure_registry.jsonl`; resolved incidents stay recorded.

## Cost boundary
Until explicit authorization for paid work:
`paid_api_called=false`, `openai_api_called=false`, `image_generation_called=false`, `image_editing_called=false`, `vision_api_called=false`, `tiny_snow_paid_api_called=false`.

Any future paid action also requires a minimal canary, explicit maximum spend, request/job ledger, duplicate/idempotency guard, and provider-state verification before retrying an ambiguous request.

## Stable protection
Do not modify `tinysnow-tool-only` or `_system/start/api_v2.ps1` during experimental zero-paid stages unless an explicitly authorized release stage says otherwise.
