# CLI Sandbox Addressing Decision Record

## Immediate Scope

Implement `[project:]name` sandbox addressing everywhere the CLI accepts a sandbox
argument, and update CLI/TUI sandbox tables to show primary short hostname plus
Tailscale IP instead of DNS aliases or FQDNs.

SSH host-key and agent-forwarding diagnostics are documented below as follow-up
work. They should not block the addressing/display change.

## Decisions

- Bare sandbox names remain valid only when they resolve uniquely among active
  sandboxes.
- Ambiguous bare names must fail. Example: `dev` should fail if both `pool:dev`
  and `sc:dev` exist.
- Project-scoped refs use `project:name`.
- Blank-project sandboxes keep the canonical address `name`.
- Blank projects render as `-` in table columns.
- Project matching uses project name only, not project path.
- Project matching follows existing lowercase model validation; do not add CLI
  case-folding.
- Do not accept `project/name` as an alias for `project:name`.
- Do not resolve sandbox commands through DNS aliases or FQDN aliases.
- Do not add numeric IDs as a general active-sandbox escape hatch.
- Keep `unarchive` ID-based for now.
- Keep `sandcastle use` server-only in this change; fix misleading help text if
  needed.
- Do not add remembered active-sandbox behavior in this change.

## Resolver Behavior

The resolver should live in a small shared CLI helper, for example
`vendor/sandcastle-cli/cmd/sandbox_ref.go`, with focused tests.

Expected behavior:

- `project:name`: match `ProjectName == project` and `Name == name`.
- `name`: match active sandboxes with `Name == name`.
- If the bare-name match count is one, return that sandbox.
- If the bare-name match count is greater than one, return an ambiguity error
  listing sorted candidates like `pool:dev (id 12), sc:dev (id 15)`.
- If no sandbox matches, return a not-found error using the original input.
- Malformed refs such as `:dev`, `sc:`, and `a:b:c` should fail outside `cp`.
- Resolver behavior must not depend on API/list order except for deterministic
  formatting of ambiguity errors.
- Ambiguity is determined only among active sandboxes returned by
  `/api/sandboxes`.

Commands that should use this resolver:

- `connect`, `ssh`
- `exec`
- `cp`
- `delete`, `start`, `stop`, `rebuild`, `set`, `rename`
- `route add/list/delete`
- `dns alias add/remove/list`
- `snapshot create/restore`
- `tailscale connect/disconnect`
- `gcp configure/setup`
- `docker start/stop`
- `vnc start/stop`

Command `Use` strings and examples should show `[project:]name` wherever a
sandbox argument is accepted.

## Create And Rename

Creation already accepts `[project:]name`; keep that behavior.

- `create project:name --project project` is allowed.
- `create project:name --project other` is an error.
- TUI create should also accept `project:name` in the Name field.
- TUI create should keep the separate Project field.
- If TUI Name prefix and Project field conflict, show a validation error.

Rename remains name-only:

- `rename sc:dev new-dev` renames the sandbox within its existing project.
- `rename sc:dev other:new-dev` should be rejected.
- Moving sandboxes between projects is out of scope.

## Copy Syntax

`sandcastle cp` should support both:

- `name:path`
- `project:name:path`

The parser must not treat local Windows paths such as `C:\path` as sandbox refs.

Current parsing splits at the first colon, which would misparse
`io26:cloud:~/file` as sandbox `io26` and path `cloud:~/file`. The new parser
must parse the sandbox address before the remote path.

## Display Rules

Action output, prompts, confirmations, feedback, and errors should use
`Sandbox.DisplayName()`.

Examples:

- `Sandbox "sc:dev" stopped.`
- `Route added for sandbox "pool:dev".`
- `GCP identity updated for sandbox "sc:dev".`

Destructive confirmations, including TUI delete confirmation, must show the
unambiguous display identity.

The TUI connect action must shell out with `connect sb.DisplayName()`, not
`connect sb.Name`, so selecting `sc:dev` cannot connect to the wrong `dev`.

## Table Display

Both plain `sandcastle list` and the TUI sandbox table should change.

Main table columns should be stable and always include:

```text
NAME  PROJECT  STATUS  CREATED  TAILSCALE DNS  TAILSCALE IP
```

Routes may still be shown when width allows, but route data is secondary. In the
TUI, route should be the first column hidden or elided on narrow terminals.

Rules:

- `NAME` shows local sandbox name only, for example `dev`.
- `PROJECT` shows project name or `-`.
- `TAILSCALE DNS` shows `primary_dns_name`, for example `dev.sc.sandman`.
- `TAILSCALE IP` shows `tailscale_ip` or `-`.
- Do not show DNS aliases or arbitrary FQDN aliases in the main table.
- Sort display by project, then name, with blank project as `-` last.
- Sorting is for display only and must not affect resolver behavior.

The API already returns `hostname` and `tailscale_ip` in sandbox JSON. The CLI
Go type already has those fields.

## Primary DNS Name

Add a server-owned field for the resolvable primary DNS name.

Recommended API field:

```text
primary_dns_name
```

Semantics:

- Keep existing `hostname` as the short display/container-oriented hostname.
- `primary_dns_name` is the resolvable DNS name, for example `dev.sc.sandman`.
- For blank-project sandboxes, use the existing DNS fallback project label:
  `dev.sandboxes.<suffix>`.
- Return `primary_dns_name` from `/api/sandboxes`.
- Return `primary_dns_name` from `/api/sandboxes/:id/connect`.
- Return it even if the sandbox is stopped or has no Tailscale IP.
- The CLI should consume this field from the API and should not reconstruct DNS
  names locally.

Connection behavior, when implemented:

- Prefer `primary_dns_name` if local resolution works.
- Fall back to Tailscale IP if DNS/hosts resolution does not work.
- Do not fall back to IP on host-key validation failure.
- Use `primary_dns_name` for host-key diagnostics because it is the exact host
  identity OpenSSH checks.

## Snapshot Display

Snapshot source identity should become project-aware where possible.

- New snapshots should store source sandbox identity as `project:name` when the
  source sandbox has a project.
- Blank-project sources remain `name`.
- Do not retroactively rewrite old snapshot metadata without a migration plan.
- `snapshot list` should display project-aware source identities when the API
  provides enough information.
- `snapshot restore <sandbox> <snapshot>` keeps the existing snapshot image-ref
  compatibility for the second argument. Only the first argument is a sandbox ref.

## Tests

Minimum test coverage:

- Resolver matches `project:name`.
- Resolver matches unique bare `name`.
- Resolver rejects ambiguous bare `name`.
- Ambiguity error includes sorted candidate addresses and IDs.
- Resolver treats blank-project sandbox address as bare `name`.
- Resolver rejects malformed refs like `:dev`, `sc:`, `a:b:c`.
- Resolver does not use aliases or FQDNs.
- `cp` parser accepts `name:path`.
- `cp` parser accepts `project:name:path`.
- `cp` parser does not treat `C:\path` as remote.
- TUI connect uses `DisplayName()`.
- Plain list formatting uses `Hostname` and `TailscaleIP`.
- TUI list formatting uses `Hostname` and `TailscaleIP`.
- Table formatting does not depend on DNS records.
- Rename rejects `new-project:new-name`.
- Create allows matching Name prefix and Project field.
- Create rejects conflicting Name prefix and Project field.

## Follow-Up: SSH Host-Key And Agent Diagnostics

A recent manual failure was caused by a stale OpenSSH host key for a sandbox
hostname. OpenSSH disabled agent forwarding to avoid a MITM risk. Removing the
stale host key and recording the current ED25519 key fixed:

```text
ssh tubu.sc.sandman "ssh-add -l"
```

Current CLI direct SSH uses:

```text
-o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null
```

and currently connects to the Tailscale IP returned by the server, so it bypasses
the user's global `~/.ssh/known_hosts`.

Follow-up decisions:

- Do not auto-edit `~/.ssh/known_hosts`.
- If hostname-based SSH is introduced, use a Sandcastle-specific known-hosts file,
  such as `~/.sandcastle/known_hosts`.
- Use normal host-key checking for hostname-based connections.
- Keep raw Tailscale IP fallback compatible with the current `/dev/null`
  known-host behavior.
- If a host key changes, stop and explain the mismatch.
- Print an explicit recovery command rather than prompting by default.
- Add an explicit command such as `sandcastle ssh trust [project:]name` or
  `sandcastle trust host [project:]name`.
- The trust command should show the current fingerprint and update only the
  Sandcastle known-hosts file.
- Agent-forwarding diagnostics should focus on `connect`, `ssh`, and `exec`.
- `cp` should not block on agent-forwarding diagnostics.
- For mosh, keep the existing warning that mosh does not support SSH agent
  forwarding.

Recommended diagnostic behavior:

- Verify local agent state with `ssh-add -l`.
- Probe remote forwarding with `ssh -A ... 'ssh-add -l'` when hostname-based
  connections are used or when diagnostics/verbose mode is requested.
- Capture stderr/stdout for the probe.
- Classify known OpenSSH messages about host-key mismatch or disabled forwarding.
- Print targeted recovery steps, including the exact host string.

This is intentionally follow-up work because it changes security behavior,
connection defaults, config, tests, and user workflow.
