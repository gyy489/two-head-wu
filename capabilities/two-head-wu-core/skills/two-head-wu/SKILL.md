---
name: two-head-wu
description: Use the deterministic Two-Headed-Wu capability interface to resolve allowed Skills, tools, workflows, project bindings, managed resources, and the owner's private small notebook. MUST use when the user explicitly says 两头乌/two-head-wu, says “记下来…”, “写到小本本上…”, or “记到小本本上…”, asks to recall/correct/forget the small notebook, asks a project Agent to obtain capabilities from 两头乌, or needs registered knowledge, server, deployment, backup, Siri, or cross-runtime resources managed by 两头乌. Do not use for ordinary project work that needs no Two-Headed-Wu-managed capability.
---

# Two-Headed-Wu Interface

Treat Two-Headed-Wu as deterministic infrastructure, not as another reasoning
Agent. Keep reasoning and implementation in the current Codex or Claude Code
session.

## Resolve Before Use

1. Run `wu resolve --agent two-head-wu --runtime <runtime> --project <id>` when
   the project is registered. Omit `--project` only for global maintenance.
2. Add `--intent <short-query>` to obtain deterministic catalog matches. No
   match grants no additional permission.
3. Use only the returned Skill sets, packages, MCP servers, resources, and
   approval profile.
4. Keep formal deliverables in the current project. Two-Headed-Wu stores only
   its own state and audit records.

Use `--json` when another tool or Agent needs machine-readable output.

## Owner Small Notebook

The notebook is a central Two-Headed-Wu resource even when the current Agent is
working in another project. Do not copy it or create a per-project binding.

- Treat “记下来…”, “写到小本本上…”, and “记到小本本上…” as writes only when
  they are an instruction to this Agent and contain a fact to store. Quoted
  examples, negations, and discussion of these trigger phrases do not write.
- Strip the leading trigger and punctuation. Resolve `personal-memory` for
  project `two-head-wu`, then invoke `personal-memory.remember.v1` through `wu`.
  Pass the memory body as data, preferably on stdin; never evaluate it as shell.
- Use one category: `identity`, `preference`, `project`, `decision`, or `fact`.
  For project memory, include only a registered project ID and short routing
  context—never an absolute path or copied implementation details.
- Confirm only after the invocation returns `stored: true`; include its `pm-...`
  ID. On failure, say that the notebook was not changed. Ordinary conversation
  and OpenClaw automatic capture never justify an “已写到小本本” confirmation.
- For a notebook recall request, invoke `personal-memory.recall.v1` with
  `recall --scope notebook --max-results 3`. Do not load the whole notebook.
- Correct and forget by record ID. Without an ID, search the notebook first and
  proceed only when one result is unambiguous; otherwise ask which record.

Canonical invocation shape:

```text
wu invoke personal-memory --project two-head-wu --runtime <runtime> \
  --interface personal-memory.remember.v1 -- remember [options]
```

## Query And Run

- When the user asks what Two-Headed-Wu can do, run `wu 能做什么 --json` immediately. On Mini this reads
  the generated local catalog; on an enrolled Air it delegates to the signed dynamic directory. Present the
  named `execution_entries`/remote capabilities separately from the complete inventory: discovery never means
  that an adapter exists or permission was granted. Use `wu 功能清单 --json` when the local tracked source is
  explicitly required.
- Use `wu search <query>` to find registered Skills, capability packages,
  projects, and MCP servers.
- Use `wu skills search <query> --project <id> --runtime <runtime>` to search
  the approved cold Skill Catalog for the current Binding. Then use
  `wu skills load <skill-id> ...` to read its entrypoint and `wu skills read
  <skill-id> <resource> ...` for a referenced supporting file. These commands
  are read-only: loading instructions never authorizes a bundled script,
  network call, secret access, or other mutation.
- Use `wu run <workflow-id>` only for a workflow already present in
  `catalog/workflows_registry.yaml`.
- Supply `--approve` only after the user has authorized a workflow whose
  registry entry requires explicit approval.
- Use `wu doctor` when paths, runtime surfaces, or package manifests appear
  stale.
- After changing Two-Headed-Wu itself, run `wu 更新说明` before staging files
  and `wu 验收修改` before declaring completion. Repository `pre-commit` and
  `pre-push` hooks repeat the read-only verification automatically when
  installed; they never refresh or stage documentation.

## Boundaries

- Never read or export raw passwords, tokens, private keys, browser stores, or
  unrelated personal data. Catalog entries may contain secret references only.
- Do not infer access from an installed Skill. Runtime exposure, Agent
  allowlists, project policy, and action approval all remain required.
- Do not bypass `wu` by treating documentation or a Skill prompt as an
  authorization system.
- If `wu` reports an unknown project or capability, stop that integration step
  and register or review it first.
