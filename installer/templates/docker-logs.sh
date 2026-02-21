#!/bin/bash
exec sudo DOCKER_HOST="unix://${DOCKER_SOCK}" ${DOCKER_COMPOSE} -f ${SANDCASTLE_HOME}/docker-compose.yml logs -f "$@"
