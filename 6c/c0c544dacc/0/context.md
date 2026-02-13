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

### Prompt 4

there's no sub-van on the admin page.

### Prompt 5

sendig a test email does nothing (save the page?)

### Prompt 6

i get no mail - can i see a log of the delivery?

### Prompt 7

i have a read smtp server setup in settings. maybe it's not being used?

### Prompt 8

but will the smtp server be configured when i hit save in the admin?

### Prompt 9

no mail - add detailled logging

### Prompt 10

do a full click thru of the app

### Prompt 11

[Request interrupted by user]

### Prompt 12

use thieso@gmail.com:hamburg as credentials

### Prompt 13

[Request interrupted by user]

### Prompt 14

add butlerx/wetty i want to have a little terminal icon netxt to my sandcastle that opens wetty. in a prfect world we would create a new ssh-key inject the pub into the sandcasle (we ca see it's filesystem) and the private key into the wetty session somehow. for the websocket com add a new container to the compose if needed. explore and research

### Prompt 15

[Request interrupted by user]

