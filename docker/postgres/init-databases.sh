#!/bin/bash
set -e

# Create additional databases needed by Solid Cache, Queue, and Cable.
# The primary database (sandcastle_production) is created automatically
# by POSTGRES_DB, but the Solid* gems each need their own database.

for db in sandcastle_production_cache sandcastle_production_queue sandcastle_production_cable; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE $db OWNER $POSTGRES_USER'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
EOSQL
done
