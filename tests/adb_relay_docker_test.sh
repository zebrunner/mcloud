#!/bin/bash
# Tests of adb-relay in docker: the auto mode (ADB_RELAY=true) with a fake STF API (the devices of the enrolled nodes) on
# the port of stf-proxy of the host, a stand-in node in a docker network and a manual entry of ADB_RELAY_HOSTS; the sessions through the relay, the
# reload when the devices change (an open session goes on) and the functions of adb-relay.sh with the bash and the mawk of
# the nginx image. The containers have fixed names and use the ports 17400-17499 and 18082 of the host.
source "$(dirname "$0")/lib.sh"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker"
docker compose version > /dev/null 2>&1 || skip "requires docker compose"
if [[ -n "$(docker ps -aq --filter name='^/(adb-relay|adb-relay-test-api|adb-relay-test-host)$')" ]]; then
  skip "the containers of adb-relay exist on this machine"
fi

MCLOUD="${WORK}/mcloud"
API="${WORK}/api"
TAG_NGINX="$(sed -n 's/^TAG_NGINX=//p' "${REPO}/.env.original")"
NGINX="nginx:${TAG_NGINX}"
copy_repo "$MCLOUD"
mkdir -p "$API"
network_created=""
docker network inspect infra > /dev/null 2>&1 || network_created=1

# cleanup: removes the containers and the networks of the test
# the EXIT trap of tests/lib.sh runs it
# shellcheck disable=SC2329
cleanup() {
  docker rm -f adb-relay-test-api adb-relay-test-host adb-relay-test-client > /dev/null 2>&1
  if [[ -f "${MCLOUD}/.env" ]]; then
    (cd "$MCLOUD" && docker compose --profile adb-relay down > /dev/null 2>&1)
  fi
  docker network rm adb-relay-test > /dev/null 2>&1
  if [[ -n "$network_created" ]]; then
    docker network rm infra > /dev/null 2>&1
  fi
}

# wait_for <seconds> <command...>: runs the command every second until it succeeds, fails after the timeout
# run_check runs it
# shellcheck disable=SC2329
wait_for() {
  local timeout="$1"
  local start="$SECONDS"
  shift
  until "$@" > /dev/null 2>&1; do
    if [[ $((SECONDS - start)) -ge "$timeout" ]]; then
      return 1
    fi
    sleep 1
  done
}

# relay_log_has <text>: the log of adb-relay has the text
# shellcheck disable=SC2329 # called through wait_for
relay_log_has() {
  docker logs adb-relay 2>&1 | grep -qF "$1"
}

# talk <port> <text>: sends a line to a port of the host through the relay, prints the answer of the node
talk() {
  docker run --rm --network host "$NGINX" bash -c \
    "exec 3<> /dev/tcp/127.0.0.1/$1 && echo '$2' >&3 && timeout 5 head -1 <&3" 2>&1
}

# devices <device...>: the answer of the fake STF API (GET /api/v1/nodes/relay), a device is
# <serial>:<address of its node>:<connect port>, of the node lab-1
devices() {
  local device serial address connect sep=""
  {
    printf '{"success":true,"devices":['
    for device in "$@"; do
      IFS=':' read -r serial address connect <<< "$device"
      printf '%s{"serial":"%s","label":"lab-1","address":"%s","connectPort":%s}' "$sep" "$serial" "$address" "$connect"
      sep=","
    done
    printf ']}\n'
  } > "${API}/devices.json.new"
  # in place: the bind mount of the fake API keeps the file
  cat "${API}/devices.json.new" > "${API}/devices.json"
}

section "the stand-ins"
if ! docker image inspect "$NGINX" > /dev/null 2>&1; then
  run_check "pull ${NGINX}" docker pull --quiet "$NGINX"
fi
docker network create adb-relay-test > /dev/null
# the node: every port answers the lines it gets with the port in front
# shellcheck disable=SC2016 # a perl program
run_check "a node" docker run -d --name adb-relay-test-host --network adb-relay-test "$NGINX" perl -MIO::Socket::INET -e '
  for my $port (17401, 17411, 17421, 17450) {
    next if fork;
    my $server = IO::Socket::INET->new(LocalPort => $port, Listen => 5, ReuseAddr => 1) or die $!;
    while (my $client = $server->accept) {
      next if fork;
      $client->autoflush(1);
      print $client "$port $_" while <$client>;
      exit;
    }
  }
  sleep;'
host="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' adb-relay-test-host)"
check_contains "the node has an address" "." "$host"
# the fake STF API on the port of stf-proxy (STF_PORT), with the access token test-token only
cat > "${API}/nginx.conf" << 'EOF'
events {}
http {
  server {
    listen 18082;
    location = /api/v1/nodes/relay {
      if ($http_authorization != "Bearer test-token") {
        return 401 '{"success":false,"description":"Bad Credentials"}';
      }
      default_type application/json;
      alias /data/devices.json;
    }
  }
}
EOF
# absent: a device of STF that is not connected, its node refuses the port
devices "old:${host}:17401" "new:${host}:17411" "absent:${host}:17431" "manual:${host}:17450" "loop:127.0.0.1:17440" \
  "out:${host}:17600"
# published like stf-proxy: adb-relay reads it on 127.0.0.1 of the network of the host
run_check "the fake STF API" docker run -d --name adb-relay-test-api --network adb-relay-test -p 18082:18082 -v "${API}:/data:ro" \
  -v "${API}/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"

section "the auto mode"
cp "${REPO}/.env.original" "${MCLOUD}/.env"
cp "${REPO}/variables.env.original" "${MCLOUD}/variables.env"
sed -i.orig -e "s|^STF_PORT=.*|STF_PORT=18082|" -e "s|^STF_URL=.*|STF_URL=http://localhost:18082|" \
  -e "s|^ADB_RELAY=.*|ADB_RELAY=true|" \
  -e "s|^ADB_RELAY_PORTS=.*|ADB_RELAY_PORTS=17400-17499|" -e "s|^ADB_RELAY_SYNC_SECONDS=.*|ADB_RELAY_SYNC_SECONDS=2|" \
  "${MCLOUD}/.env"
# the token file of ./zebrunner.sh start, STF_TOKEN of variables.env
(umask 077 && echo test-token > "${MCLOUD}/configuration/adb-relay/stf-token")
# the manual entry of ADB_RELAY_HOSTS, as ./zebrunner.sh writes it
# shellcheck disable=SC2016 # $server_port of nginx
printf 'server {\n  listen 17450 so_keepalive=on;\n  proxy_pass %s:$server_port;\n}\n' "$host" \
  > "${MCLOUD}/configuration/adb-relay/relay-hosts.conf"
run_check "adb-relay starts" bash -c "cd '${MCLOUD}' && docker compose --profile adb-relay up -d adb-relay"
run_check "adb-relay reads the devices of the nodes" wait_for 60 relay_log_has "Android devices of the nodes relayed: 3."
log="$(docker logs adb-relay 2>&1)"
check_contains "a device: connectPort at the address of its node" \
  "Relays the remote debug port 17401 of the device old of the node lab-1 to ${host}:17401." "$log"
check_contains "another device" "Relays the remote debug port 17411 of the device new of the node lab-1 to ${host}:17411." "$log"
check_contains "a port of ADB_RELAY_HOSTS is skipped" \
  "Skips the remote debug port 17450 of the device manual of the node lab-1 (${host}): the port is one of MCloud or of ADB_RELAY_HOSTS." "$log"
check_contains "a loopback address of a node is skipped" "the address 127.0.0.1 of its node is not one to relay to" "$log"
check_contains "a port out of ADB_RELAY_PORTS is skipped" "Skips the remote debug port 17600 of the device out" "$log"
check "the remote debug port of a device" "17401 hi" "$(talk 17401 hi)"
check "the remote debug port of another device" "17411 hi" "$(talk 17411 hi)"
check "the port of ADB_RELAY_HOSTS" "17450 hi" "$(talk 17450 hi)"
check_contains "an absent device is relayed too" "Relays the remote debug port 17431 of the device absent of the node lab-1 to ${host}:17431." "$log"
check_not_contains "the port of the absent device reaches no device" "17431 hi" "$(talk 17431 hi)"
check_contains "the node refuses the port of the absent device (502 of the relay)" "17431 -> ${host}:17431 502" \
  "$(docker logs adb-relay 2>&1)"
run_check "adb-relay is healthy" wait_for 60 \
  bash -c "test \"\$(docker inspect --format '{{.State.Health.Status}}' adb-relay)\" == healthy"

section "a change of the devices"
# an adb session: a line, a pause over the reload, another line
docker run -d --name adb-relay-test-client --network host "$NGINX" bash -c \
  'exec 3<> /dev/tcp/127.0.0.1/17401 && echo one >&3 && timeout 5 head -1 <&3 && sleep 8 && echo two >&3 && timeout 5 head -1 <&3' \
  > /dev/null
sleep 2
devices "old:${host}:17401" "added:${host}:17421"
run_check "adb-relay reloads with the devices of the nodes" wait_for 30 relay_log_has \
  "Relays the remote debug port 17421 of the device added of the node lab-1 to ${host}:17421."
check "the added device" "17421 hi" "$(talk 17421 hi)"
check_contains "a device removed from STF is not relayed" "Connection refused" "$(talk 17411 hi)"
docker wait adb-relay-test-client > /dev/null
check "an open session goes on over the reload" "17401 one
17401 two" "$(docker logs adb-relay-test-client 2>&1)"

section "errors of the STF API"
# in place, as ./zebrunner.sh start writes it
echo wrong > "${MCLOUD}/configuration/adb-relay/stf-token"
run_check "a refused token is logged" wait_for 30 relay_log_has "The STF API http://127.0.0.1:18082 failed, the relay keeps its devices"
check "the relay keeps its devices" "17421 hi" "$(talk 17421 hi)"
echo test-token > "${MCLOUD}/configuration/adb-relay/stf-token"
run_check "a new token is read on the next sync" wait_for 30 relay_log_has "The STF API http://127.0.0.1:18082 answers with the devices again."
check "the relay has no other secret of MCloud" "" \
  "$(docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' adb-relay | tr ' ' '\n' | grep variables.env)"

section "ADB_RELAY_HOSTS only"
sed -i.orig "s|^ADB_RELAY=.*|ADB_RELAY=false|" "${MCLOUD}/.env"
run_check "adb-relay starts again without the auto mode" \
  bash -c "cd '${MCLOUD}' && docker compose --profile adb-relay up -d adb-relay"
run_check "adb-relay is healthy without the auto mode" wait_for 60 \
  bash -c "test \"\$(docker inspect --format '{{.State.Health.Status}}' adb-relay)\" == healthy"
check "the port of ADB_RELAY_HOSTS without the auto mode" "17450 hi" "$(talk 17450 hi)"
check_contains "no device of STF without the auto mode" "Connection refused" "$(talk 17401 hi)"
check_not_contains "no sync without the auto mode" "Android devices of the nodes" "$(docker logs adb-relay 2>&1)"

section "adb-relay.sh in the image"
run_check "the tests of adb-relay.sh with the bash and the mawk of the image" \
  docker run --rm -v "${REPO}:/repo:ro" "$NGINX" bash /repo/tests/adb_relay_test.sh

section "the end"
(cd "$MCLOUD" && docker compose --profile adb-relay down > /dev/null 2>&1)
check "adb-relay is removed" "" "$(docker ps -aq --filter name='^/adb-relay$')"

finish
