# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Plan: Replace WeTTY with ttyd (tmux + shell terminals)

## Context
WeTTY requires SSH keypair generation, key injection via `docker exec`, and a sidecar container per terminal session. Replacing it with ttyd running **inside** the sandbox container eliminates all of this complexity. Two ttyd instances run permanently on fixed ports inside each sandbox; Traefik routes directly to them. No sidecars, no keypairs, no background jobs.

## Key architectural facts
- San...

### Prompt 2

connetcing does not work:
sandcastle-web     | [748e8813-3881-4324-8b8f-919e292d497e] Started POST "/sandboxes/3/terminal?type=tmux" for 192.168.117.1 at 2026-02-21 15:10:31 +0000
sandcastle-web     | [748e8813-3881-4324-8b8f-919e292d497e] Processing by TerminalController#open as HTML
sandcastle-web     | [748e8813-3881-4324-8b8f-919e292d497e]   Parameters: {"authenticity_token" => "[FILTERED]", "type" => "tmux", "id" => "3"}
sandcastle-web     | [748e8813-3881-4324-8b8f-919e292d497e] Redirected...

### Prompt 3

[Request interrupted by user]

### Prompt 4

this is my local docker - not sandman!

