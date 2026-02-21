# Session Context

## User Prompts

### Prompt 1

why is https://hq.sandcastle.rocks/ SSL broken - fix!

### Prompt 2

[Request interrupted by user]

### Prompt 3

the .env says:
SANDCASTLE_HOST=hq.sandcastle.rocks
SANDCASTLE_TLS_MODE=letsencrypt
why didnt it work

### Prompt 4

we shoudl have teh cert in a volume that survives reinstalls!

### Prompt 5

commite and push it

### Prompt 6

tailscale has lost it's internet!

thies@sandman:~$ /sandcastle/docker-runtime/bin/docker exec -ti sc-ts-thies ash
/ # ping heise.de
PING heise.de (193.99.144.80) 56(84) bytes of data.
^C
--- heise.de ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2029ms

### Prompt 7

tailscale stil lhas no networking:
sandcastle@sandman:~$ docker exec -ti sc-ts-thies ash
/ # ping heise.de
PING heise.de (193.99.144.80) 56(84) bytes of data.
^C
--- heise.de ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1001ms

/ # netstat -rn
Kernel IP routing table
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
0.0.0.0         10.159.29.1     0.0.0.0         UG        0 0          0 eth0
10.159.29.0     0.0.0.0         255.255.25...

### Prompt 8

do i need new images or is reinstalling enogh?

### Prompt 9

add some info to CLAUDE.md how the networking should look like and what not to change without asking!

