#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
IMAGE="${SANDCASTLE_IMAGE:-ghcr.io/thieso2/sandcastle:latest}"
SANDBOX_IMAGE="${SANDCASTLE_SANDBOX_IMAGE:-ghcr.io/thieso2/sandcastle-sandbox:latest}"
EXPECTED_UID="${SANDCASTLE_EXPECTED_UID:-220568}"
EXPECTED_GID="${SANDCASTLE_EXPECTED_GID:-220568}"
RUN_IMAGE_TEST="${SANDCASTLE_HARNESS_IMAGE_TEST:-1}"
RUN_REPAIR_TEST="${SANDCASTLE_HARNESS_REPAIR_TEST:-1}"
RUN_SANDBOX_CADDY_TEST="${SANDCASTLE_HARNESS_SANDBOX_CADDY_TEST:-0}"
EXISTING_CONTAINER="${SANDCASTLE_REPAIR_HARNESS_CONTAINER:-}"

TMP_DIRS=()
EXISTING_REPAIR_CONTAINERS=()
TEMP_CONTAINERS=()

log() {
  printf '[permission-harness] %s\n' "$*"
}

cleanup() {
  local dir container
  if ((${#EXISTING_REPAIR_CONTAINERS[@]})); then
    for container in "${EXISTING_REPAIR_CONTAINERS[@]}"; do
      "$DOCKER_BIN" exec -u root "$container" sh -lc 'rm -rf "${SANDCASTLE_DATA_DIR:-/data}/.permission-repair-harness"' >/dev/null 2>&1 || true
    done
  fi
  if ((${#TEMP_CONTAINERS[@]})); then
    for container in "${TEMP_CONTAINERS[@]}"; do
      "$DOCKER_BIN" rm -f "$container" >/dev/null 2>&1 || true
    done
  fi
  if ((${#TMP_DIRS[@]})); then
    for dir in "${TMP_DIRS[@]}"; do
      chmod -R u+rwx "$dir" >/dev/null 2>&1 || true
      rm -rf "$dir" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

docker_socket_gid() {
  stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || true
}

run_image_permission_test() {
  log "checking image permissions in ${IMAGE}"
  "$DOCKER_BIN" run --rm -i \
    -e EXPECTED_UID="$EXPECTED_UID" \
    -e EXPECTED_GID="$EXPECTED_GID" \
    --entrypoint sh \
    "$IMAGE" -s <<'SH'
set -eu

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

check_dir() {
  path="$1"
  expected_mode="$2"

  [ -d "$path" ] || fail "missing directory: $path"
  [ -w "$path" ] || fail "directory is not writable by the image user: $path"

  owner="$(stat -c '%u:%g' "$path")"
  [ "$owner" = "${EXPECTED_UID}:${EXPECTED_GID}" ] || fail "bad owner for $path: $owner"

  mode="$(stat -c '%a' "$path")"
  [ "$mode" = "$expected_mode" ] || fail "bad mode for $path: $mode"
}

[ "$(id -u)" = "$EXPECTED_UID" ] || fail "image runs as uid $(id -u), expected $EXPECTED_UID"
[ "$(id -g)" = "$EXPECTED_GID" ] || fail "image runs as gid $(id -g), expected $EXPECTED_GID"

check_dir /data 755
check_dir /sandcastle 755
check_dir /sandcastle/data 755

for base in /data /sandcastle/data; do
  check_dir "$base/users" 755
  check_dir "$base/sandboxes" 755
  check_dir "$base/snapshots" 755
  check_dir "$base/wetty" 755
  check_dir "$base/traefik" 755
  check_dir "$base/traefik/dynamic" 755
  check_dir "$base/certs" 700
  check_dir "$base/certs/caddy" 700
done
SH
}

run_temp_container_repair_test() {
  local host_dir container_name sock_gid
  host_dir="$(mktemp -d "${TMPDIR:-/tmp}/sandcastle-permission-repair.XXXXXX")"
  TMP_DIRS+=("$host_dir")
  chmod 000 "$host_dir"

  container_name="sandcastle-permission-repair-harness-$$-${RANDOM}"
  sock_gid="$(docker_socket_gid)"

  log "checking live repair through temporary container ${container_name}"
  if [ -n "$sock_gid" ]; then
    "$DOCKER_BIN" run --rm -i \
      --name "$container_name" \
      --group-add "$sock_gid" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$host_dir:/data/harness" \
      -e SANDCASTLE_PERMISSION_REPAIR_CONTAINER="$container_name" \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      --entrypoint sh \
      "$IMAGE" -s < <(repair_test_script)
  else
    "$DOCKER_BIN" run --rm -i \
      --name "$container_name" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$host_dir:/data/harness" \
      -e SANDCASTLE_PERMISSION_REPAIR_CONTAINER="$container_name" \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      --entrypoint sh \
      "$IMAGE" -s < <(repair_test_script)
  fi
}

run_existing_container_repair_test() {
  local container="$1"

  log "checking live repair through existing container ${container}"
  EXISTING_REPAIR_CONTAINERS+=("$container")
  "$DOCKER_BIN" exec -u root "$container" sh -lc '
    set -eu
    dir="${SANDCASTLE_DATA_DIR:-/data}/.permission-repair-harness"
    rm -rf "$dir"
    mkdir -p "$dir"
    chown 0:0 "$dir"
    chmod 000 "$dir"
  '

  "$DOCKER_BIN" exec -i "$container" sh -lc 'cd /rails && bundle exec ruby' <<'RUBY'
require "docker"
require_relative "./app/services/permission_repair"

path = File.join(ENV.fetch("SANDCASTLE_DATA_DIR", "/data"), ".permission-repair-harness")
PermissionRepair.chown_chmod(path, uid: Process.uid, gid: Process.gid, mode: 0o755)

stat = File.stat(path)
raise "bad owner after repair: #{stat.uid}:#{stat.gid}" unless stat.uid == Process.uid && stat.gid == Process.gid
raise "bad mode after repair: #{(stat.mode & 0o777).to_s(8)}" unless (stat.mode & 0o777) == 0o755

File.write(File.join(path, "write-check"), "ok\n")
RUBY
}

run_sandbox_caddy_test() {
  local ca_dir container_name
  ca_dir="$(mktemp -d "${TMPDIR:-/tmp}/sandcastle-caddy-ca.XXXXXX")"
  TMP_DIRS+=("$ca_dir")
  container_name="sandcastle-caddy-harness-$$-${RANDOM}"
  TEMP_CONTAINERS+=("$container_name")

  log "checking sandbox Caddy/mkcert startup in ${SANDBOX_IMAGE}"
  "$DOCKER_BIN" run --rm \
    --entrypoint sh \
    "$SANDBOX_IMAGE" -lc 'command -v caddy >/dev/null || { echo "caddy missing" >&2; exit 1; }; command -v mkcert >/dev/null || { echo "mkcert missing" >&2; exit 1; }'

  "$DOCKER_BIN" run --rm \
    -v "$ca_dir:/caroot" \
    --entrypoint sh \
    "$SANDBOX_IMAGE" -lc 'CAROOT=/caroot mkcert -cert-file /tmp/harness.pem -key-file /tmp/harness-key.pem harness.sand >/tmp/mkcert.out 2>/tmp/mkcert.err'

  chmod 755 "$ca_dir"
  chmod 644 "$ca_dir/rootCA.pem" "$ca_dir/rootCA-key.pem"

  "$DOCKER_BIN" run -d \
    --name "$container_name" \
    -e SANDCASTLE_USER=harness \
    -e SANDCASTLE_CADDY_ENABLED=1 \
    -e SANDCASTLE_DNS_NAME=harness.sand \
    -v "$ca_dir:/etc/sandcastle/caddy/mkcert:ro" \
    "$SANDBOX_IMAGE" >/dev/null

  for _ in $(seq 1 30); do
    if "$DOCKER_BIN" exec "$container_name" test -f /etc/sandcastle/caddy/certs/sandbox.pem &&
       "$DOCKER_BIN" exec "$container_name" test -f /etc/sandcastle/caddy/certs/sandbox-key.pem; then
      "$DOCKER_BIN" exec "$container_name" pgrep caddy >/dev/null
      return
    fi
    sleep 1
  done

  "$DOCKER_BIN" logs "$container_name" >&2 || true
  "$DOCKER_BIN" exec "$container_name" sh -lc 'cat /var/log/caddy/mkcert.log /var/log/caddy/caddy.log 2>/dev/null' >&2 || true
  return 1
}

repair_test_script() {
  cat <<'SH'
set -eu
cd /rails
bundle exec ruby <<'RUBY'
require "docker"
require_relative "./app/services/permission_repair"

path = "/data/harness"
PermissionRepair.chown_chmod(path, uid: Process.uid, gid: Process.gid, mode: 0o755)

stat = File.stat(path)
raise "bad owner after repair: #{stat.uid}:#{stat.gid}" unless stat.uid == Process.uid && stat.gid == Process.gid
raise "bad mode after repair: #{(stat.mode & 0o777).to_s(8)}" unless (stat.mode & 0o777) == 0o755

File.write(File.join(path, "write-check"), "ok\n")

host_uid = ENV.fetch("HOST_UID").to_i
host_gid = ENV.fetch("HOST_GID").to_i
PermissionRepair.chown_chmod(path, uid: host_uid, gid: host_gid, mode: 0o700) if host_uid.positive?
RUBY
SH
}

if [ "$RUN_IMAGE_TEST" = "1" ]; then
  run_image_permission_test
fi

if [ "$RUN_REPAIR_TEST" = "1" ]; then
  if [ -n "$EXISTING_CONTAINER" ]; then
    run_existing_container_repair_test "$EXISTING_CONTAINER"
  else
    run_temp_container_repair_test
  fi
fi

if [ "$RUN_SANDBOX_CADDY_TEST" = "1" ]; then
  run_sandbox_caddy_test
fi

log "ok"
