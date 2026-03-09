# Session Context

## User Prompts

### Prompt 1

sandcastle connect shows weir characters.

### Prompt 2

why do we need this at all?

### Prompt 3

commit

### Prompt 4

setting up a sandxcaste with name instead of an ip in SANDCASTLE_HOST= does not work. 
install sandcaste on dev.sand and use dev.sand as hostname - debug what's missing. also make sure that the TLS cert works!

### Prompt 5

test the install unsiatll on dev.sand!

### Prompt 6

curl %                                                                                                                                                                    ~/Projects/GitHub/Sandcastle [main] % curl https://dev.sand/
curl: (60) SSL certificate problem: self signed certificate
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how...

### Prompt 7

yes

### Prompt 8

commit and push

### Prompt 9

Data path should be "mount /persisted" and a toggle. If on, you can spwecify a subpath.
also make sure that smb exported /persisted if it is mouned
also when i connect to teh sandbox i want to be in ~/ initially

### Prompt 10

remove all ref to /workspace from the project. all code and docs!

### Prompt 11

This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.

Summary:
1. Primary Request and Intent:
   The user had four sequential requests:
   - **Fix garbled characters** in `sandcastle connect` terminal (OSC escape sequences leaking in prompt)
   - **Fix hostname support** in `SANDCASTLE_HOST` (was broken when using names like `dev.sand` instead of IPs), install on `dev.sand`, switch to mkcert TLS, e...

### Prompt 12

push and release a new version

### Prompt 13

update sandcaste to use the lastest dockyard v0.1.3

### Prompt 14

commit and push

### Prompt 15

"Check for update" is not working - see dev.sand !

### Prompt 16

how can i do the update from the UI?

### Prompt 17

no update now button.
I also want to be able to just update teh sandbox image and not the app.

### Prompt 18

explaij how the upgrade process works?
we should 1st pull the images and show some progress 
one teh images are loaded we need to start the "restart" container 
we should run a fullscreen page and a JS that checks if the app is "back" and if yes reload teh page...

### Prompt 19

commti and push and release

### Prompt 20

live patch dev.sand

### Prompt 21

teh Update butteon donÄt work:

controller.ts:28 Error invoking action "click->update-check#startPull"

Error: Action "click->update-check#startPull" references undefined method "startPull"
    at get method (controller.ts:28:39)
    at p.invokeWithEvent (controller.ts:28:39)
    at p.handleEvent (controller.ts:28:39)
    at e.handleEvent (controller.ts:28:39)

Object
handleError @ controller.ts:28
controller.ts:28 Error invoking action "click->update-check#startPull"

Error: Action "click->upd...

### Prompt 22

we need to update teh system update partial - when a pull finished.

### Prompt 23

als after the images are pulled we shoudl see a restart now that does the real restart.

### Prompt 24

detect when the pulled app image is newer that the running one and offer a restart option.

### Prompt 25

commti and push

### Prompt 26

we get logged out on restart. hot to fix that!

### Prompt 27

also on relase tag the docker imnages with the release version and surface that in the update page. show the installed and the newly availanble version.
  debug the flow and make sure all works!

### Prompt 28

So it’s all fixed now

### Prompt 29

Will we see the release tags in the zu now?

### Prompt 30

debug "Restart now" on dev.sand using chrome and the log files on the server https://dev.sand/admin

### Prompt 31

commit and üush and release.

