# Session Context

## User Prompts

### Prompt 1

plain whe /usr/local/bin/ssh-agent-switcher does not work when doing "sc c sysbox"

### Prompt 2

commit push and release!

### Prompt 3

also add  -- [options to pass to ssh] 
to connet and ssh

### Prompt 4

commit and push

### Prompt 5

still does not work - 
see 
sc c  sysbox -- -v -A
debug 
sc c  sysbox

### Prompt 6

commit and push

### Prompt 7

Last login: Sat Mar  7 21:02:43 on ttys024
~/Projects/GitHub/Sandcastle [main] %
~/Projects/GitHub/Sandcastle [main] %
~/Projects/GitHub/Sandcastle [main] %
~/Projects/GitHub/Sandcastle [main] % cd vendor/sandcastle-cli
~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % mise build
mise ERROR no task build found
mise ERROR Run with --verbose or MISE_VERBOSE=1 for more information
~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % make

mosh-server: execvp: if: No such file or di...

### Prompt 8

still teh problem!
dO ~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % ./sandcastle c sysbox
[mosh is exiting.]
~/Projects/GitHub/Sandcastle/vendor/sandcastle-cli [main] % ./sandcastle c sysbox
sthies@thies-sysbox:~$ ssh-add -l
error fetching identities: communication with agent failed
thies@thies-sysbox:~$

### Prompt 9

still not fixed - debug really this time  make it it work before you commit - live oatch!
~/Projects/GitHub/Sandcastle [main] % sc c sysbox
Server: 100.106.185.92 (https://100.106.185.92)

thies@thies-sysbox:~$ ssh-add -l
error fetching identities: communication with agent failed
thies@thies-sysbox:~$

### Prompt 10

still broken - create a sandboc and connect .- fix it!

### Prompt 11

why nt mosh? whats th eproblem?

### Prompt 12

updtae docs and also echo a warning that this is the case when using mosg!

