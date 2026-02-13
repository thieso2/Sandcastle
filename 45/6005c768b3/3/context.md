# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Add full_name to User and configure git identity in sandboxes

## Context
Sandbox users currently have no git identity configured, so `git commit` prompts for name/email. Adding a `full_name` field to User and passing it + email as env vars to sandbox containers lets the entrypoint auto-configure `/etc/gitconfig` with `[user]` name and email.

## Changes

### 1. Migration — add `full_name` to users
- `bin/rails generate migration AddFullNameToUsers full_n...

### Prompt 2

commit this and push

