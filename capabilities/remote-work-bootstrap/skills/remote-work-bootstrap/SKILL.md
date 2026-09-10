---
name: remote-work-bootstrap
description: Bootstrap or inspect the operator's fixed Aliyun Two-Headed-Wu runtime area after an explicit owner request, including SSH reachability, protected authentication, the shared non-login system identity, and pre/post guards for the two registered sites. Never use for arbitrary SSH, commands, hosts, paths, website changes, or credential inspection.
---

# Remote Work Bootstrap

Resolve Two-Headed-Wu first for project `two-head-wu` and intent `remote-work-bootstrap`. Continue only
when the package, Skill, `edge-server`, `private-site`, and `public-site` are returned.

Use the fixed adapter commands in increasing order:

```bash
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap health
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap probe --project two-head-wu
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap target-status
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap auth-check --project two-head-wu
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap inspect --project two-head-wu
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap bootstrap --project two-head-wu --approve
```

`probe` is read-only and uses the public endpoint already mapped to `edge-server`. `auth-check` and
`inspect` require the fixed target reference in macOS Keychain or an explicit process-scoped recovery value.
Installing the target reference is an owner-approved local mutation and must verify the registered edge first.
Run `bootstrap --approve` only after
the owner directly authorizes the external change; never infer approval from installation or past use.

The adapter accepts no host, username, path, key, or remote command argument. Do not inspect SSH config,
private keys, Keychain values, the private resource package, or raw adapter environment. `target-status` may
report only ready/missing and source kind. Do not echo SSH stderr
when it may contain private connection facts.

The shared remote runtime identity is `twoheadwu`: non-interactive, no password, no sudo, and limited to
`/srv/two-head-wu`. Other approved Two-Headed-Wu services may reuse this system identity and directory,
but website publishing, privileged installation, and deployment credentials remain separate.

Before and after an approved bootstrap, require HTTPS guards for both registered sites. Never change
their roots, publisher, Nginx, HTTPS, DNS, FRP, firewall, databases, or content through this capability.

Stop on an unknown host key, failed public-key authentication, missing privilege, an existing conflicting
account/directory, or a failed site guard. Do not fall back to passwords, accept a new host key, try other
users, or broaden the command.
