#!/bin/bash
exec sudo ${DOCKER} compose -f ${SANDCASTLE_HOME}/docker-compose.yml --env-file ${SANDCASTLE_HOME}/.env logs -f "$@"
