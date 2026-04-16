# Session Context

## User Prompts

### Prompt 1

in the image: claude want's to be installed in ~/.local - and we want to moiunt ~/ into the sandbox. how can bothe be true at the same tine

### Prompt 2

how can we no mount the $HOME and still not have to reauth claude and codex for every new sandbox?

### Prompt 3

yes - goal is to not moutn $HOME and still alow for certain files/dirs to be available in each sandbox.

### Prompt 4

so the reaon is that we want user settings to be available in each new sandbox but have the claude install locally (claude insists to be installed in ~/.local) - lets plan it the opposite way!

### Prompt 5

why not inject claude and codex auth like we do for ssh.key? - how could we add files to inject?

### Prompt 6

so cretae a list of what should be injected and what should be bound. also explain how i can add files to either (like io do the auth in claude and what the new files to be persisted.. - some gui that shows me new files crated?)

### Prompt 7

build the full set (1-4) with tests and also test them e2e

### Prompt 8

commit and push

