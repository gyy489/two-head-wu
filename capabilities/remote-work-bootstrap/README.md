# Remote Work Bootstrap

This capability prepares the fixed Aliyun edge resource for future Two-Headed-Wu component roaming,
job relay, offline results, and event synchronization. It is not a generic SSH shell.

## Fixed scope

- Resource: `edge-server` only.
- Remote root: `/srv/two-head-wu` only.
- Remote system identity: `twoheadwu`, shared by approved Two-Headed-Wu runtime services.
- Existing sites: `private-site` and `public-site` are HTTPS-checked before and after bootstrap and
  remain owned by their existing publication capability.
- SSH target: `secret://remote-work-bootstrap/edge-server/ssh-target`. First installation supplies it to one
  process as `TWO_HEAD_WU_ALIYUN_SSH_TARGET`, verifies it resolves to the registered edge, then stores only the
  fixed target reference in macOS Keychain. No target, username, key path, token, or private key is stored in Git.

The `twoheadwu` identity has no interactive login and no sudo. It owns only the fixed runtime root. It
may later run the component registry, task mailbox, result mailbox, and control-plane services, but it
does not own website roots, web deployment credentials, Nginx configuration, or other users' data.

## Commands

```bash
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap health
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap probe --project two-head-wu
TWO_HEAD_WU_ALIYUN_SSH_TARGET='user@registered-edge' capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap install-target --project two-head-wu --approve
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap target-status
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap auth-check --project two-head-wu
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap inspect --project two-head-wu
capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap bootstrap --project two-head-wu --approve
```

`probe` needs no credential. The other network commands use the installed Keychain reference, with a
process-scoped target accepted for first installation or explicit recovery, and use non-interactive public-key
authentication with strict existing host-key verification. `bootstrap` sends
one fixed script; it does not accept a host, command, path, username, key, or configuration argument.

## Stop conditions

Bootstrap stops without mutation when the SSH target is unavailable, the host key is not already
trusted, public-key authentication fails, passwordless privilege is unavailable, `/srv/two-head-wu` is
a symlink or conflicting non-empty directory, the `twoheadwu` identity conflicts with the required
non-login account, or a registered site fails its pre-change HTTPS guard.
