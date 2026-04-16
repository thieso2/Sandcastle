# Session Context

## User Prompts

### Prompt 1

debug and fix sandcastle on sandman:

thies@thies-loud-wolf:~$ docker run -ti alpine ashUnable to find image 'alpine:latest' locallylatest: Pulling from library/alpine6a0ac1617861: Pull completeDigest: sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11Status: Downloaded newer image for alpine:latestdocker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container...

### Prompt 2

Run 'docker run --help' for more informationthies@thies-wild-viper:~$ docker run -ti alpine ashdocker: Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: open sysctl net.ipv4.ip_unprivileged_port_start file: check "sys" component is on procfs: unsafe procfs detected: incorrect procfs root filesystem type 0x65735546Run 'docker run --help' for...

### Prompt 3

so - what exactly is the problem? we updated runc in teh base-image? should we add a check and warning to exxntrypoint? 
can we fix the problem in our sysbox fork?

### Prompt 4

commit all local work!

