# 远程任务状态与恢复

Normal progression:

```text
queued -> leased -> running -> uploading -> succeeded
```

`waiting_user` means the Mac mini needs a permission decision, answer, or other explicit input. Model and
reasoning effort are selected at submission from `wu 查看模型`. `failed`, `cancelled`, and `expired` are
terminal. Never interpret silence or an offline Air as approval.

For `waiting_user`, show the interaction title and sanitized details, then use `wu 回复任务` for an approval
or `wu 回答任务` for ordinary text/options. Never ask the user to send a password, token, Keychain value,
or other secret through this relay.

When presenting a task, include job ID, state, bound identity alias, last event, and whether a result is
available. On reconnection, fetch events after the stored cursor; duplicate event IDs are harmless and
must not be shown twice.

Fetched output belongs in the client's review directory. Present `final.md`, tests, and the patch summary
before offering to apply anything to the user's working tree.

An Air file uploaded with `wu 上传附件` receives an `art-...` reference. Only jobs that explicitly include
that ID can fetch it, and the worker materializes it under `.two-head-wu-inputs/<artifact-id>/`. The result
may contain `changed-files.json` and `changed-files.tar.gz` for direct file review; these do not authorize
automatic extraction into the Air project. Relay artifacts expire after 14 days and may be explicitly removed
after all referencing jobs are terminal.

Each worker lease has a unique token, so a stale process cannot upload into a newer attempt. Heartbeat
expiry automatically requeues an isolated job up to three attempts. If an earlier attempt received command
or extra-permission approval, automatic replay stops and reports `manual_retry_required`; summarize that
risk and obtain explicit user confirmation before retrying. Pending interactions from an expired
attempt are marked expired and cannot be answered later.

## Active project lease

A submitted Air project receives a task-scoped project lease. The initial capsule is immutable evidence of
the submission point; while the job is active, `wu remote projects sync <job-id>` computes a safe manifest,
uploads changed regular files, and records deletions without granting Mini general filesystem access. The Air
companion performs the same sync periodically for active bindings.

Mini applies a delta only inside that job's isolated workspace and only when the expected base hash matches.
A mismatch becomes a visible conflict event; it is never resolved by silently overwriting Mini output. Project
deltas exclude `.git`, credentials, symlinks, caches, dependencies, oversized files, and paths outside the
selected project root. The task lease ends with the job.

Result transfer is still review-first: project synchronization does not authorize Mini to write directly into
the Air working tree. Fetch and inspect `final.md`, tests, provenance, patch, and changed-file archive before
offering any local application.

## Invocation provenance

For a generic Tool/MCP/Agent/database/workflow invocation, present `requested_executor`, `actual_executor`,
`capability_id`, `remote_call_succeeded`, state, job ID when any, and runtime compatibility. If the call was
queued or could not reach a compatible Mini, say exactly: “本轮未能成功调用两头乌 Mini”.
