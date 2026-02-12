# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Admin Settings (OAuth + SMTP) & User Invites

## Context

The login page hides OAuth buttons when credentials aren't in ENV vars. Admins need a web UI to configure OAuth and SMTP without touching env files. Additionally, admins should be able to invite users via email link instead of manually setting passwords.

## 1. Settings Model (singleton, single table)

**Create `db/migrate/..._create_settings.rb`:**

```ruby
create_table :settings do |t|
  # OAuth
  ...

### Prompt 2

commit

### Prompt 3

create a sub-nav for admin (users/sandcasles/settings) make ot look good

