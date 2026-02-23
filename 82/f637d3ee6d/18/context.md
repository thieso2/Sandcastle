# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Scope Sandboxes Strictly by Owner

## Context

Currently, admin users see **all** sandboxes (from every user) on the main dashboard because `SandboxPolicy::Scope#resolve` returns `scope.active` for admins. Additionally, admins can open terminals and VNC sessions into any user's sandbox, which is a serious privilege escalation risk.

**Desired behaviour:**
- Main dashboard and API: show/operate only **your own** sandboxes, even for admins
- Admin panel: see ...

### Prompt 2

run the tests

### Prompt 3

just commit and push

