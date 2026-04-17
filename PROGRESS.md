# Sandcastle Improvement Plan - Implementation Progress

## Phase 1: Configuration Fixes ✅
- [x] Add BUILD_* environment variables to docker-compose.dev.yml
- [x] Fix Traefik HostRegexp warnings in docker-compose files

## Phase 2: Separate Worker Container ✅
- [x] Add worker service to docker-compose.local.yml
- [x] Add worker service to docker-compose.dev.yml
- [x] Remove SOLID_QUEUE_IN_PUMA from web services
- [ ] Verify worker container runs independently (requires local deploy)

## Phase 3: Job Monitoring Dashboard ✅
- [x] Mount MissionControl::Jobs in routes.rb
- [x] Add Jobs link to admin navbar
- [ ] Verify dashboard access (requires local deploy)

## Phase 4: Fix Stats Endpoint Bug ✅
- [x] Add RecordNotFound rescue to dashboard_controller.rb stats action
- [x] Add RecordNotFound rescue to admin/sandboxes_controller.rb stats action
- [ ] Test with destroyed sandbox (requires local deploy)

## Phase 5: Flash Notifications & Turbo Broadcasts ✅
- [x] Create flash Stimulus controller
- [x] Update flash HTML in application layout
- [x] Create toast partial
- [x] Add turbo-stream source to layout
- [x] Add toast container to layout
- [x] Add broadcasts to SandboxProvisionJob
- [x] Add broadcasts to SandboxDestroyJob
- [x] Add broadcasts to SandboxStartJob
- [x] Add broadcasts to SandboxStopJob

## Phase 6: Testing Infrastructure ✅ (Foundation)
- [x] Create docker_mock.rb support file
- [x] Enable Docker mock in test_helper.rb
- [x] Create SandboxManager tests (core functionality)
- [ ] Create TerminalManager tests (deferred)
- [ ] Create TailscaleManager tests (deferred)
- [x] Create SandboxProvisionJob tests
- [x] Create SandboxDestroyJob tests
- [ ] Create ContainerSyncJob tests (deferred)
- [x] Create sandbox_lifecycle system test
- [ ] Create terminal system test (deferred)
- [ ] Create tailscale system test (deferred)
- [ ] Create flash_notifications system test (deferred)
- [ ] Verify all tests pass (pending)

## Phase 7: Chrome Testing & Bug Fixes ⏳
- [x] Deploy locally (DEPLOYED - https://sandcastle.local:8443)
- [x] Fix syntax error in SandboxProvisionJob (extra 'end')
- [x] Verify web container running (✅ Puma on port 80)
- [x] Verify worker container running (✅ Solid Queue processing)
- [x] Verify site accessible (✅ HTTP/2 302 to /session/new)
- [x] Replace turbo_confirm with custom HTML modal (commit c11f800)
- [ ] Manual browser testing required:
  - [x] Login and navigation (✅ All pages load correctly)
  - [x] Custom confirm modal (✅ Working perfectly, no native dialogs)
  - [ ] Flash auto-dismiss behavior
  - [ ] Sandbox lifecycle + toast notifications
  - [ ] Stats endpoint (no 500 errors on destroyed sandboxes)
  - [ ] Job monitoring dashboard at /admin/jobs
  - [ ] Tailscale integration
  - [ ] Snapshots
  - [ ] CLI commands

## Bugs Found & Fixed

### Fixed
- ✅ **Syntax error in SandboxProvisionJob** - Extra 'end' statement caused web container crash (commit 4b7efd0)
- ✅ **MissionControl::Jobs authentication** - Fixed HTTP Basic auth conflict and method name issues (commits 2d63c17, 296373d, 4627b7c, b3cb39e, af91e16, 1518f14, 779b243)
- ✅ **Stats endpoint partial path** - Fixed missing partial error by using full path admin/dashboard/sandbox_stats (commit 7b4efa9)
- ✅ **Custom confirm modals** - Replaced native browser dialogs with HTML modals for automation compatibility (commit c11f800)
- ✅ **Toast positioning** - Fixed duplicate fixed positioning causing stacked toasts (commit 0da6851)

### Critical
(breaks core features)
- None found

### High Priority
(UX issues)
- ⚠️ **BUILD_* variable warnings** - docker-compose shows warnings for unset BUILD_VERSION, BUILD_GIT_SHA, BUILD_GIT_DIRTY, BUILD_DATE variables (cosmetic, not breaking)
- ✅ ~~Jobs page completely blank~~ - FIXED with skip_before_action and correct method names (commits af91e16, 1518f14, 779b243)
- ✅ ~~Admin sandbox stats shows "Content missing"~~ - FIXED with correct partial path (commit 7b4efa9)
- ✅ ~~Stats endpoint 500 error for destroyed sandboxes~~ - FIXED by skipping before_action and using direct find (commit 7edefce)
- ⚠️ **Toast notifications not appearing** - PARTIALLY FIXED. Infrastructure works (Turbo Stream subscription, container, broadcasts) but toasts don't appear for start/stop/destroy actions because controllers redirect immediately after enqueueing jobs, disconnecting websocket before broadcast arrives. Need to either: (1) use Turbo responses instead of redirects, or (2) use flash messages for user-initiated actions and reserve toasts for truly async events
- ❌ **Flash messages not appearing** - Tailscale settings update doesn't show flash (Turbo frame issue? - needs testing)
- ✅ ~~Confirm dialogs block browser automation~~ - FIXED with custom HTML modals (commit c11f800)

### Low Priority
(minor issues)
- None found

## Notes

- Started: [timestamp will be added]
- Completed:
- Total time:

---

# 2026-04-17 Full-App Audit (Opus)

Systematic walk-through of every web-UI flow, looking for bugs and fixing them.
Environment: dev stack on http://10.206.10.5:8080/ (logged in as admin `thies`).

## Legend
- [ ] not yet examined
- [~] in progress / partially tested
- [x] examined, no issue found
- [!] bug found — see "Findings"
- [F] bug found AND fixed

## Auth / Registration
- [x] Login (session#create) — works, redirected to dashboard as thies
- [ ] Logout
- [ ] Invite-based registration (/invites/:token)
- [ ] Password reset (/passwords)
- [ ] Change password (/change_password)
- [ ] Device auth (CLI login) — /auth/device
- [ ] OAuth callbacks — skip (external provider)

## Dashboard (sandbox list & actions)
- [ ] List sandboxes (empty state)
- [ ] Create sandbox (/sandboxes/new)
- [ ] Show sandbox details
- [ ] Start / Stop
- [ ] Rebuild
- [ ] Retry
- [ ] Archive (destroy with archive)
- [ ] Archive restore
- [F] Purge ("Really delete") — fixed UI live-update bug (Findings F1)
- [ ] Logs
- [ ] Stats (Turbo Frame)
- [ ] Metrics
- [ ] Card partial
- [ ] Terminal open / close
- [ ] VNC open / close
- [ ] Snapshot create
- [ ] Discover files / promote file
- [ ] Routes create / destroy

## Snapshots
- [ ] Index
- [ ] Clone (to new sandbox)
- [ ] Destroy

## Tailscale (user UI)
- [ ] Show page
- [ ] Interactive login (start + poll)
- [ ] Update settings (auto_connect)
- [ ] Disable

## Settings
- [ ] Profile update
- [ ] Password update
- [ ] Tailscale toggle
- [ ] SMB password update
- [ ] Custom links
- [ ] SSH keys
- [ ] Persisted paths
- [ ] Injected files (upload/delete)
- [ ] Generate API token
- [ ] Revoke API token

## Admin
- [ ] Admin dashboard
- [ ] System status
- [ ] Update status / check / pull / restart
- [ ] Admin settings
- [ ] Users CRUD
- [ ] Invites index / create / destroy
- [ ] Sandboxes (all users) — destroy / start / stop / rebuild / stats / archive_restore / purge
- [ ] Docker index / logs
- [ ] Mission Control Jobs
- [ ] Solid Errors

## Pages
- [ ] Guide (/guide)

## Findings

### [F1] Turbo Stream remove target mismatch on archived-sandbox purge ✅ FIXED
**Discovered:** 2026-04-17 during validation of "Really delete" on `/`.
**Symptom:** After purging an archived sandbox, the worker completes the destroy
job, but the archived row stays on screen until the user reloads.
**Root cause:** `Sandbox#broadcast_replace_to_dashboard` uses `dom_id(self)` as the
Turbo Stream target (e.g. `sandbox_7`), but `app/views/dashboard/_archived_sandbox.html.erb`
wraps the row in `id="<%= dom_id(sandbox) %>-archived"` (e.g. `sandbox_7-archived`).
The `remove` action can't find the element, so the UI doesn't refresh.
**Fix:** broadcast removal against both ids (`sandbox_N` and `sandbox_N-archived`)
when the sandbox transitions to destroyed/archived. Also targets both ids in
`broadcast_remove_from_dashboard` for consistency.
**Validated:** live purge of archived sandbox now removes the row immediately.

### [F2] Empty-state box missing after archiving the last active sandbox
**Symptom:** When a user's only active sandbox is destroyed/archived, the row is
removed via Turbo Stream but the "No sandcastles yet" placeholder never appears.
Appears only after a full page reload. Visible gap in the UI instead.
**Root cause:** `app/views/dashboard/index.html.erb` renders the empty state
inside an `{% if @sandboxes.any? %} … {% else %}` branch; once the Turbo Stream
removes the single row, the else-branch content doesn't exist anywhere in the DOM.
**Severity:** cosmetic — state eventually correct after reload.
**Suggested fix (not applied — out of scope for this pass):** restructure the
dashboard so the empty state sits in its own sibling container, always in the
DOM, toggled by CSS `#sandboxes:has(> *) ~ #sandboxes-empty { display: none }`
or a Stimulus observer.

### [F3] Archived section doesn't appear live when first sandbox is archived
**Symptom:** If the user loaded the dashboard with zero archived sandboxes,
archiving a sandbox never renders the "Archived (N)" details block — only appears
after reload.
**Root cause:** the `<details>` archived block is wrapped in
`<% if archived_sandboxes.any? %>` so it isn't in the DOM on initial render.
`Sandbox#broadcast_replace_to_dashboard` only does a `remove`; it doesn't insert
anything into a non-existent archive container.
**Severity:** cosmetic. Related to F2.
**Suggested fix (not applied):** always render the archived block, hide it via
CSS when the inner list is empty. Separately broadcast an append to an
archived-list target on archive transition.

### [F4] Archived-section count in summary is stale after live purge
**Symptom:** After a live purge, "Archived (1)" still shows even though the row
was removed (count is baked into the static `<summary>` text on initial render).
**Severity:** cosmetic.
**Suggested fix:** put the count span in its own target id and either broadcast a
`replace` on the count on purge, or compute it client-side from child count.

### [F5] Stale error in SolidErrors — not a real app bug
**Observed at** `/admin/errors`: `NoMethodError undefined method 'current_job'
for an instance of Sandbox`, backtrace rooted in `application.runner.railties`.
No matches in repo for `current_job`. Origin: a `rails runner` one-off command,
not app code. **Resolution: left for user to mark resolved.**

### [F6] Snap-modal div duplicates in DOM on every Turbo Stream replace ✅ FIXED
**Discovered** while investigating why the empty state failed to appear after
F2 fix — `#sandboxes` reported 7 children though no sandbox card was visible.
All 7 were stale `<div id="snap-modal-4">` from the snapshot-create modal.
**Root cause:** `app/views/dashboard/_sandbox.html.erb` is a multi-root partial
— the card wrapper (with `id=sandbox_N`) followed by the modal as a sibling.
Turbo Stream `replace target="sandbox_N"` swaps the wrapper but dumps the
modal into the parent container again; the old modal stays. Stats polling
triggers this refresh every few seconds, so modals accumulate indefinitely.
**Fix:** move the modal INSIDE the `sandbox_N` wrapper so the whole partial
is one dom_id'd node and Turbo swaps it atomically. ✅ verified via browser.

### [F7] Turbo broadcasts fail to render `_archived_sandbox` from a job ✅ FIXED
**Symptom** (worker log): `Sandbox#broadcast_replace: undefined method
'effective_archive_retention_days' for nil` — the partial calls
`Current.user.effective_archive_retention_days`, but broadcasts run in job
context where `Current.user` is unset. The archive-transition Turbo Stream
never fires; the user sees no archived section appear until reload.
**Fix:** fall back to `sandbox.user` inside the partial. ✅ verified.

### [F8] Restore from archive fails with "Name must be lowercase alphanumeric" ✅ FIXED
**Symptom:** clicking Restore in the archived section → the worker job crashes
with `ActiveRecord::RecordInvalid: Validation failed: Name must be lowercase
alphanumeric`. Sandbox stays archived, job_status stuck. User sees "Operation
already in progress" forever.
**Root cause:** `SandboxManager#restore_from_archive` (sandbox_manager.rb:212)
did the work in this order:
  1. `create_container_and_start(...)` — this flips `status` from `archived` to
     a running state.
  2. `sandbox.update!(name: original_name)` — strips the `YYYYMMDDHHMMSS-`
     prefix.
The name format validator `/\A[a-z][a-z0-9_-]{0,62}\z/` is skipped while
archived but enforced once status transitions back. At step 1 the prefixed
name is still set, which is now invalid; the rescue tries to call
`fail_job` which also runs `update!` and hits the same validation, compounding
the failure and leaving `job_status` stuck.
**Fix:** rename **before** transitioning status. Rename runs under the
archived-status exemption; after that, `create_container_and_start` flips
status with a valid name. ✅ verified via admin Restore — `wild-falcon`
restored, running cleanly.

### [F9] `Sandbox#fail_job` can itself raise, leaving job_status stuck ✅ FIXED
**Symptom:** when a job's root error was a validation failure (see F8), the
rescue calls `fail_job`, which uses `update!` and hits the same validators,
re-raising. `job_status` never clears; the sandbox is permanently "Operation
already in progress".
**Fix:** `fail_job` now uses `update_columns` (bypasses validations and
callbacks), then manually broadcasts. This preserves the intent — "record the
failure and get out" — without being vulnerable to the very failure we're
trying to record.

## Audit Progress (pages visited)

- **Guide** (`/guide`): renders cleanly.
- **Settings** (`/settings`): all sections visible (Profile, Tailscale, VNC,
  Terminal, SMB, Persisted Directories, Injected Files, SSH Keys, Custom Links,
  API Tokens). No obvious bugs — not yet interacted with.
- **Admin overview** (`/admin`): loads, shows System Update / System Status.
- **Admin → Errors** (`/admin/errors`): 1 error present (F5 above).
- **Admin → Jobs** (`/admin/jobs`): Mission Control loads, queue visible.
- **Admin → Users** (`/admin/users`): lists users, edit/delete actions wired.
- **Admin → Docker** (`/admin/docker`): container logs live-streaming works.
- **Dashboard new** (`/sandboxes/new`): form renders; create succeeds.
- **Dashboard list** (`/`): create → running → archive → restore → purge all
  work end-to-end with live Turbo updates, after F1/F6/F7/F8/F9 fixes.

## Summary

Fixes delivered this pass:
- **F1** Turbo stream target mismatch for archived-sandbox purge — fixed in
  `app/models/sandbox.rb`.
- **F2/F3/F4** Dashboard empty state and archived-section live-update — fixed
  via layout refactor in `app/views/dashboard/index.html.erb` (always-in-DOM
  containers toggled by CSS `:has()`) and broadcast changes in `sandbox.rb`.
- **F6** Duplicate `snap-modal` divs — modal now nested inside the dom_id'd
  wrapper in `app/views/dashboard/_sandbox.html.erb`.
- **F7** Archived partial `Current.user` crash in job context — fallback in
  `app/views/dashboard/_archived_sandbox.html.erb`.
- **F8** Restore-from-archive name validation failure — rename-before-status
  in `app/services/sandbox_manager.rb`.
- **F9** `fail_job` vulnerable to validation failures — `update_columns` in
  `app/models/sandbox.rb`.

Not fixed (out of scope or pre-existing, not triggered during audit):
- Several security/robustness concerns surfaced by code-review subagents —
  BTRFS helper shell-string interpolation, `SandboxManager#rebuild` stale
  container_id on create-failure, `ContainerSyncJob` treating "Restarting"
  containers as "stopped" (tears down Terminal/VNC prematurely), orphaned
  `Invite` records when an inviter is destroyed. These warrant their own
  tickets.
- Pages not interactively exercised: password reset, invite registration,
  device auth, admin update flow, snapshot clone, Tailscale interactive login,
  settings sub-form submissions. The rendering pass for each looked clean.
