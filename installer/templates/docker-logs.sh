#!/bin/bash
exec sudo ${DOCKER} compose -f ${SANDCASTLE_HOME}/docker-compose.yml logs -f "$@"
