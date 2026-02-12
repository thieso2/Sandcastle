# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Pundit Authorization + Dashboard Restructure + UI Rename

## Context

Currently the dashboard shows everything (sandboxes, users, system status) on one page, with admin-only sections guarded by inline `Current.user.admin?` checks and `require_admin!` before_actions. This plan:

1. Splits the dashboard so regular users see only **their own sandcastles**, Tailscale link, and preferences
2. Moves admin content (all sandboxes, user list, system status) to a ded...

### Prompt 2

set a fixed width - don't want teh layout to wiggle when turbo data arrives. make tht toplevel navigation beautiful!

### Prompt 3

commit and push

