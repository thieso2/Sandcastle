# Session Context

## User Prompts

### Prompt 1

freshly build sandbox is missing node. nose is installed via mise and should be in /usr/local

### Prompt 2

cant we have mise use a global dir for installs?

### Prompt 3

make sure they are know to the env for each user on a sandbox!

### Prompt 4

commit and push

### Prompt 5

trigger the "Rebuild Sandbox Base Image"

### Prompt 6

remove DinD ready message

### Prompt 7

also add setting to the UI and to cli to choose which options are avalable in a sandbox (and also add defaults to the settings) and have entrypoint honor them:
VNC
HOME mounted
DATA mountd (with subpath)
Docker Daemin started.

### Prompt 8

commit and push and release!

### Prompt 9

update the claude install to
  RUN VERSION=$(curl -fsSL https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest) \
      && ARCH=$(uname -m) \
      && if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then PLATFORM="linux-arm64"; else PLATFORM="linux-x64"; fi \
      && curl -fsSL "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/$VERSION/$PLATFORM/claude" \
         -o /usr/loca...

### Prompt 10

[Request interrupted by user]

### Prompt 11

in the sandbox image:
update the claude install to
  RUN VERSION=$(curl -fsSL https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest) \
      && ARCH=$(uname -m) \
      && if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then PLATFORM="linux-arm64"; else PLATFORM="linux-x64"; fi \
      && curl -fsSL "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/$VERSION/$PLATFORM/claude" \...

