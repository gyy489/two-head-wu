# OpenClaw Memory Upgrade and Recovery Runbook

This is the canonical operator procedure for preserving Two-Headed-Wu personal
memory while upgrading or replacing OpenClaw. The currently verified release is
`2026.7.1-2`; the installed release's local docs and config schema always take
precedence over version-specific examples in this file.

## Current contract

The tracked patch enables:

- FTS-only recall (`provider: none`) with the `trigram` tokenizer;
- sources `memory` and `sessions`, with experimental same-Agent session indexing;
- `tools.sessions.visibility: agent` rather than cross-Agent visibility;
- the bundled session-memory hook with the OpenClaw default 15-message capture;
- compaction memory flush;
- native `memory-core` Dreaming at the default `0 3 * * *` cadence.

The patch is
`capabilities/personal-memory/config/openclaw-memory.patch.json`. It merges only
these keys and never replaces the complete OpenClaw config.

## Storage ownership

Do not collapse these into one “memory database”:

1. The ignored workspace Markdown is portable durable memory.
2. OpenClaw session files/state are the raw conversation archive.
3. Memory tables/indexes are derived and rebuilt by `openclaw memory index`.
4. The complete per-Agent SQLite also contains runtime/authentication state and
   must never be deleted merely to rebuild memory.
5. Registered project repositories remain authoritative for implementation.
6. The explicit notebook route belongs to the versioned Two-Headed-Wu Skill and
   this Capability; it is independent of OpenClaw source and is not copied into
   each project.

## Before every upgrade

From the Two-Headed-Wu Git root:

```bash
capabilities/personal-memory/adapters/personal-memory status --json
capabilities/personal-memory/adapters/personal-memory backup
```

Record the OpenClaw version and the non-secret status summary. Keep the returned
archive path private. The adapter uses `openclaw backup create --verify`, which
snapshots live SQLite safely and includes state, config, credentials, sessions,
and the configured workspace.

Also record the current repository commit/branch. Do not stage a backup, config,
session file, workspace memory, index, or Dreaming artifact.

## Validate the new release before changing config

Read these files from the newly installed OpenClaw package:

```text
docs/concepts/memory.md
docs/concepts/dreaming.md
docs/reference/memory-config.md
docs/automation/hooks.md
docs/cli/backup.md
```

Then dry-run the tracked patch:

```bash
capabilities/personal-memory/adapters/personal-memory configure
```

If validation rejects a key, stop. Update this Capability, its tests, and this
runbook from the new local docs before applying anything. Never solve schema
drift by copying the whole old config over a new release.

## Apply and rebuild

After the new OpenClaw CLI and Gateway report the same version:

```bash
capabilities/personal-memory/adapters/personal-memory configure --apply
capabilities/personal-memory/adapters/personal-memory status --json
```

`configure --apply` creates another verified backup, preserves `USER.md`, seeds
only missing memory files, applies the narrow patch, validates config, and runs
`openclaw memory index --force --agent main`.

For this external-volume installation, reinstall the canonical LaunchAgent with
`$OPENCLAW_HOME/bin/install-service` only when the program or
service layout changed. Ordinary config updates are reloaded by the existing
Gateway; do not let a generic restart rewrite the service definition.

## Post-upgrade smoke test

Use a unique, non-sensitive phrase and remove it in the same maintenance window:

```bash
memory_json=$(printf '%s' '长期记忆升级验收代号 WU-MEMORY-UPGRADE-SMOKE' | \
  capabilities/personal-memory/adapters/personal-memory remember --category fact)
memory_id=$(printf '%s' "$memory_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')
capabilities/personal-memory/adapters/personal-memory recall --scope notebook --query '升级验收代号'
capabilities/personal-memory/adapters/personal-memory forget --id "$memory_id"
capabilities/personal-memory/adapters/personal-memory recall --scope notebook --query '升级验收代号'
```

Acceptance requires the Chinese substring search to find the record before
deletion and return no matching record afterward. Also confirm:

- the memory directory has no missing-directory issue;
- provider is `none`, FTS is available, tokenizer is `trigram`;
- sources include `memory` and `sessions`;
- session-memory, memory flush, and Dreaming are enabled;
- session visibility is `agent`;
- Gateway and CLI versions match;
- no private workspace or OpenClaw state appears in Git status.

## Rollback

If the new release cannot satisfy the contract:

1. Stop further memory writes and retain the failed-version evidence.
2. Restore the last verified OpenClaw archive using the procedure supported by
   that OpenClaw release, or restore the prior program plus config snapshot.
3. Keep the private workspace Markdown and raw session archive.
4. Validate config and Gateway version alignment.
5. Rebuild only memory-owned indexes and rerun the smoke test.

Never delete the complete Agent SQLite, raw session directory, or only backup.
Rollback of the Capability means disabling its project binding and reverting the
tracked patch/adapter; it does not authorize deletion of personal data.
