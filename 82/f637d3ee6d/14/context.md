# Session Context

## User Prompts

### Prompt 1

docker in docker is broken on sandmann!
thies@thies-mydumper:~$ sudo docker ps
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
thies@thies-mydumper:~$

ssh sandman -l sandcastle # to debug the outer docker
ssh 10.206.72.4 # to see whats in a castle

### Prompt 2

~/Projects/SaaS-Bonn/cloud-main [fix/archived-metrics-partitions-833] %   ssh sandcastle@sandman "/sandcastle/docker-runtime/bin/docker inspect thies-mydumper | grep -A2 Runtime"
            "Runtime": "sysbox-runc",
            "Isolation": "",
            "CpuShares": 0,
--
            "CpuRealtimeRuntime": 0,
            "CpusetCpus": "",
            "CpusetMems": "",

### Prompt 3

login to sandman yourself! running outside docker is /sandcastle/docker-runtime/bin/docker

### Prompt 4

[Request interrupted by user for tool use]

### Prompt 5

sysbos is installed via dockyard and installed in /sandcastle

### Prompt 6

creaet a GH issue for this

### Prompt 7

commit and push the entrypoint fix

