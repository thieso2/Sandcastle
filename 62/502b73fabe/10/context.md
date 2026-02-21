# Session Context

## User Prompts

### Prompt 1

add solid error to admin interface (like jobs)

### Prompt 2

commit this

### Prompt 3

https://dev.sand:8443/admin/errors 
500

### Prompt 4

the error was on my local system - https://dev.sand:8443/admin/errors

BTW: deploy:local shoudl run in dev mode by default so that i see erors in cleartext and not generic 5xx pages.

### Prompt 5

deploy:local 
PG::UndefinedTable: ERROR: relation "solid_errors" does not exist LINE 10: WHERE a.attrelid = '"solid_errors"'::regclass ^
Rails.root: /rails

Application Trace | Framework Trace | Full Trace
Request
Parameters:

None
Toggle session dump

### Prompt 6

what happend?

### Prompt 7

mise run deploy:local

### Prompt 8

sandcastle-worker  | [ActiveJob] [SandboxProvisionJob] [e2e0d189-c0d0-4601-b08b-bf6539a80104] Error performing SandboxProvisionJob (Job ID: e2e0d189-c0d0-4601-b08b-bf6539a80104) from SolidQueue(default) in 304.45ms: SandboxManager::Error (Container failed to start: failed to set up container networking: driver failed programming external connectivity on endpoint thies-wild-puma (8882a08bfebe04ee7dbc12e597ca329ed2c44e7a17953c893e77766dee8f8df3): Bind for 0.0.0.0:2201 failed: port is already alloc...

