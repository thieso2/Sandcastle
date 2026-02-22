# Session Context

## User Prompts

### Prompt 1

add GH isse tailscale does not reconnect after unimstall/install - reason is that we get a new subnet to route

### Prompt 2

create GH isse that docker in docker does agai not work. look at the hostory and add teh explanation you found and how you fixed it last time!

### Prompt 3

lets work on https://github.com/thieso2/Sandcastle/issues/55 - this time do a real fix that surrvives reinstalls!

### Prompt 4

push it

### Prompt 5

lets add a gh action to just rebuild the sandbox image. how would that work?

### Prompt 6

commit and push

### Prompt 7

trigger it manually and check if it works

### Prompt 8

sandcastle@sandman:~$ docker pull ghcr.io/thieso2/sandcastle:latest
latest: Pulling from thieso2/sandcastle
Digest: sha256:ce96873596d2d5f0ca8dbfc00451cdf9175832c5034ddeeff188ca76e5be09ff
Status: Image is up to date for ghcr.io/thieso2/sandcastle:latest

shoun#t this fetch the updated images?

### Prompt 9

thies@thies-thies2:~$ /usr/local/bin/docker-restart
Stopping existing dockerd...
chown: changing ownership of '/var/lib/docker': Operation not permitted
thies@thies-thies2:~$ docker ps
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory

