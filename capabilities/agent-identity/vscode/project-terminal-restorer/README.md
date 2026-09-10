# Two-Headed-Wu Project Terminals

This local-only VS Code connector restores explicitly managed Codex terminals. It calls the
`agent-identity project-terminal` interface with argv arrays and never reads Codex credentials or
conversation content.

Configure each workspace folder with an enabled project ID and an absolute adapter path. The
connector reconciles only entries marked `auto_restore`, identifies existing terminals through the
opaque recovery UUID in `TerminalOptions.env`, and treats `TerminalExitReason.User` or `Extension`
as an intentional close. VS Code `Shutdown` leaves the recovery entry intact.

Use the command palette actions:

- `Two-Headed-Wu: Restore Project Codex Terminals`
- `Two-Headed-Wu: Open Managed Codex Terminal`
