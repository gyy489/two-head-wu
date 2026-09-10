# Personal Memory

`personal-memory` gives the owner-facing Two-Headed-Wu Agent one durable memory
boundary while leaving OpenClaw independently upgradeable. It does not implement
a second memory engine: it configures and operates OpenClaw's native
`memory-core`, session store, Markdown, session-memory hook, FTS, and Dreaming.

## Mental model

```text
memory finds the project -> wu resolves its current binding -> Agent reads current docs/code
```

Memory stores who the owner is, useful conversation context, durable decisions,
and short project references. It does not copy project implementation details.
When an old implementation matters, resolve the registered project and inspect
its current documentation or source before answering.

The explicit small notebook is not another Skill or memory engine. The existing
global `two-head-wu` router recognizes an explicit write phrase, then demand-loads
this Capability. Notebook contents are never injected wholesale into every
prompt, and notebook recall defaults to three compact matches.

## Private data layout

| Data | Authority | Git status |
|---|---|---|
| `USER.md` | Stable owner context | ignored/private |
| `MEMORY.md` | OpenClaw-curated durable memory and Dreaming promotion | ignored/private |
| `memory/explicit.md` | ID-addressable explicit remember/correct/forget records | ignored/private |
| `memory/*.md` | Daily/session working memory and Dreaming state | ignored/private |
| `DREAMS.md` | Human-readable Dream Diary | ignored/private |
| OpenClaw session files/state | Raw conversation history and runtime continuity | external/private |
| Project registry | Current project paths, permissions, and capabilities | tracked declaration |
| Project repository | Current implementation truth | its own project |

The per-Agent `openclaw-agent.sqlite` contains more than a memory index. Never
delete the whole database to force a reindex; use `openclaw memory index --force`
through the adapter instead.

## Behavior contract

- OpenClaw silently captures the last 15 messages on `/new` or `/reset`, indexes
  same-Agent session history, flushes durable context before compaction, and runs
  the native Dreaming sweep at its default `03:00` cadence.
- Automatic capture does not warrant a visible “我记住了” response.
- An explicit “记下来…”, “写到小本本上…”, “记到小本本上…”, “更正…”,
  “忘记…”, or “你的小本本记得什么” request receives a concise confirmation or
  memory report. Quoted examples, negations, and trigger-phrase discussion do
  not write.
- The Agent confirms a write only after the stable invocation returns
  `stored: true`, and includes the returned `pm-...` record ID.
- Explicit managed facts use `memory/explicit.md`; Dreaming alone promotes
  qualified automatic candidates into `MEMORY.md`.
- Notebook categories are bounded to `identity`, `preference`, `project`,
  `decision`, and `fact`. A project record may store a registered `project_id`
  plus short routing context, but never an absolute path or copied source.
- Passwords, tokens, private keys, and unnecessary third-party personal data are
  not memory. Store a safe reference to an approved secret system instead.

## Stable adapter

Run through a resolved project binding or directly during maintenance:

```bash
capabilities/personal-memory/adapters/personal-memory status --json
capabilities/personal-memory/adapters/personal-memory configure
capabilities/personal-memory/adapters/personal-memory configure --apply
printf '%s' '需要长期保留的事实' | capabilities/personal-memory/adapters/personal-memory remember --category fact
capabilities/personal-memory/adapters/personal-memory recall --scope notebook --query '项目机制'
capabilities/personal-memory/adapters/personal-memory correct --id pm-... --text '更正后的事实'
capabilities/personal-memory/adapters/personal-memory forget --id pm-...
capabilities/personal-memory/adapters/personal-memory backup
```

Agents use the central owner binding even when working in another repository:

```bash
wu resolve --agent two-head-wu --runtime codex --project two-head-wu --intent personal-memory --json
wu invoke personal-memory --project two-head-wu --runtime codex \
  --interface personal-memory.remember.v1 -- remember --category fact --text '需要长期保留的事实'
```

`recall --scope notebook` reads only ID-addressable explicit records. It returns
three matches by default and accepts at most five. General `recall` still searches
OpenClaw Markdown and same-Agent sessions, with the same compact default limit.

`configure` is dry-run by default. `configure --apply` refuses to seed an unknown
workspace, creates and verifies an official OpenClaw backup first, initializes
missing Markdown without replacing `USER.md`, applies the validated patch, and
rebuilds only memory-owned indexes.

## Runtime boundary

OpenClaw conversations receive automatic capture. Direct Codex or Claude Code
sessions can use the same adapter for recall and explicit CRUD when the project
binding authorizes it. The global router always uses the central `two-head-wu`
binding for the owner's notebook; it does not duplicate bindings in business
projects. Raw Codex/Claude conversations are not automatically imported unless
they passed through OpenClaw. This boundary is intentional.

For upgrade, backup, rollback, configuration keys, and smoke tests, follow
[the OpenClaw upgrade runbook](docs/openclaw-upgrade.md).
