#!/bin/bash
# Tests of the service wireguard in docker (README.md#wireguard-tunnel-of-the-nodes): the tunnel with stand-ins of
# stf-proxy (a fake STF API, the registry of the nodes, and the port 4446) and of stf-triproxy-dev (7250, 7270) with the
# ports of docker-compose.yml, and a stand-in node in a docker network that dials it with its own WireGuard interface:
# the peers of the registry, a handshake, the relay of the ports of the nodes from the WireGuard address of the server to
# the loopback address, the restarts of the services in any order (as docker restarts them at the boot), nothing on the
# WireGuard address without the service, the removal of a revoked node and of the interface. It needs the wireguard
# module of the kernel of docker (Linux 5.6+; skipped without it). The containers have fixed names, the interface mcloud
# is the one of the server and the test uses the network 10.239.0.0/24, the UDP port 51899, the port 18083 of the host
# and the ports of the nodes 4446, 7250 and 7270 of its loopback address.
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd python3
docker info > /dev/null 2>&1 || skip "requires a running docker"
docker compose version > /dev/null 2>&1 || skip "requires docker compose"
if [[ -n "$(docker ps -aq --filter name='^/(wireguard|stf-proxy|stf-triproxy-dev|wireguard-test-node)$')" ]]; then
  skip "the containers of wireguard or MCloud exist on this machine"
fi

MCLOUD="${WORK}/mcloud"
API="${WORK}/api"
TAG_ALPINE="$(sed -n 's/^TAG_ALPINE=//p' "${REPO}/.env.original")"
ALPINE="alpine:${TAG_ALPINE}"
TAG_NGINX="$(sed -n 's/^TAG_NGINX=//p' "${REPO}/.env.original")"
NGINX="nginx:${TAG_NGINX}"
NETWORK="10.239.0.0/24"
PORT=51899
copy_repo "$MCLOUD"
mkdir -p "$API"
network_created=""
if ! docker network inspect infra > /dev/null 2>&1; then
  docker network create infra > /dev/null
  network_created=1
fi

# host <command...>: a command in the network of the host of docker, with the tools of the tunnel
host() {
  docker run --rm --network host --cap-add NET_ADMIN "$ALPINE" sh -c \
    "apk add --no-cache --quiet iproute2 wireguard-tools-wg > /dev/null 2>&1 && $*"
}

if [[ -n "$(host 'ip link show dev mcloud 2> /dev/null')" ]]; then
  skip "the interface mcloud exists in the network of the host of docker (an MCloud with the tunnel runs here)"
fi
if ! host 'ip link add dev wgprobe type wireguard && ip link del dev wgprobe' > /dev/null 2>&1; then
  skip "the kernel of docker has no wireguard module (Linux 5.6+)"
fi

# cleanup: removes the containers, the networks and the interface of the test
# the EXIT trap of tests/lib.sh runs it
# shellcheck disable=SC2329
cleanup() {
  docker rm -f wireguard-test-node > /dev/null 2>&1
  if [[ -f "${MCLOUD}/.env" ]]; then
    (cd "$MCLOUD" && docker compose --profile wireguard down > /dev/null 2>&1)
  fi
  docker run --rm --network host --cap-add NET_ADMIN "$ALPINE" ip link del dev mcloud > /dev/null 2>&1
  docker network rm wireguard-test > /dev/null 2>&1
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

# log_has <text>: the log of wireguard has the text
# shellcheck disable=SC2329 # called through wait_for
log_has() {
  docker logs wireguard 2>&1 | grep -qF "$1"
}

# peers: the peers of the interface of the server, `<key> <allowed ips>` per line, sorted
peers() {
  docker exec wireguard wg show mcloud allowed-ips | tr '\t' ' ' | sort
}

# peers_are <peers>: the peers of the interface are these
# shellcheck disable=SC2329 # called through wait_for
peers_are() {
  [[ "$(peers)" == "$1" ]]
}

# node_reaches_ports: the stand-in node reaches every port of the nodes on the WireGuard address of the server, each one
# answers with its number (the stand-ins of stf-proxy and stf-triproxy-dev behind the relay), the grid of the nodes with
# the address of the node of the PROXY protocol of the relay
# shellcheck disable=SC2329 # called through wait_for
node_reaches_ports() {
  local port expected
  for port in 4446 7250 7270; do
    expected="$port"
    [[ "$port" != 4446 ]] || expected="4446 from 10.239.0.2"
    [[ "$(docker exec wireguard-test-node wget -q -O - -T 3 "http://10.239.0.1:${port}/" 2> /dev/null)" == "$expected" ]] || return 1
  done
}

# listeners <address>: the listening TCP sockets of the host on the address, `<address>:<port>` per line, sorted
listeners() {
  host "ss -Hltn | awk '{ print \$4 }'" | grep -F "${1}:" | sort
}

# running <container...>: the containers run
# shellcheck disable=SC2329 # called through wait_for
running() {
  local container
  for container in "$@"; do
    [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2> /dev/null)" == true ]] || return 1
  done
}

# restart_in_order <container...>: docker restart of the containers one after another
# shellcheck disable=SC2329 # called through run_check
restart_in_order() {
  local container
  for container in "$@"; do
    docker restart "$container" > /dev/null || return 1
  done
}

# shuffled <word...>: the words in a random order, one line
shuffled() {
  local words=("$@")
  local count="${#words[@]}"
  local index swap
  while ((count > 1)); do
    index=$((RANDOM % count))
    count=$((count - 1))
    swap="${words[count]}"
    words[count]="${words[index]}"
    words[index]="$swap"
  done
  echo "${words[*]}"
}

# key_pair: `<private> <public>` of a new WireGuard key pair, base64 (patch/curve_keygen.py)
key_pair() {
  python3 -c 'import base64, subprocess, sys
out = dict(l.split("=") for l in subprocess.run([sys.executable, sys.argv[1]], capture_output=True, text=True).stdout.split())
print(base64.b64encode(bytes.fromhex(out["secret"])).decode(), base64.b64encode(bytes.fromhex(out["public"])).decode())' \
    "${REPO}/patch/curve_keygen.py"
}

# nodes <node...>: the answer of the fake STF API (GET /api/v1/nodes), a node is <label>:<address>:<status>:<wg key>
nodes() {
  local node label address status key sep=""
  {
    printf '{"success":true,"nodes":['
    for node in "$@"; do
      IFS=':' read -r label address status key <<< "$node"
      printf '%s{"label":"%s","address":"%s","status":"%s","publicKey":"x","wgPublicKey":%s}' "$sep" "$label" "$address" \
        "$status" "$([[ -n "$key" ]] && echo "\"${key}\"" || echo null)"
      sep=","
    done
    printf ']}\n'
  } > "${API}/nodes.json.new"
  # in place: the bind mount of the fake API keeps the file
  cat "${API}/nodes.json.new" > "${API}/nodes.json"
}

section "the stand-ins"
for image in "$ALPINE" "$NGINX"; do
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    run_check "pull ${image}" docker pull --quiet "$image"
  fi
done
read -r server_private server_public <<< "$(key_pair)"
read -r node_private node_public <<< "$(key_pair)"
read -r _ other_public <<< "$(key_pair)"
check "the keys of the test" "yes" "$([[ "$server_public" =~ ^[A-Za-z0-9+/]{43}=$ && "$node_public" != "$server_public" ]] && echo yes)"
# the stand-ins of stf-proxy and stf-triproxy-dev: the fake STF API on the HTTP port of stf-proxy (published on STF_PORT),
# with the access token test-token only; every port of the nodes answers with its number
cat > "${API}/nginx.conf" << 'EOF'
events {}
http {
  server { listen 4446; return 200 "4446"; }
  server { listen 4447 proxy_protocol; return 200 "4446 from $proxy_protocol_addr"; }
  server { listen 7250; return 200 "7250"; }
  server { listen 7270; return 200 "7270"; }
  server {
    listen 80;
    location = /api/v1/nodes {
      if ($http_authorization != "Bearer test-token") {
        return 401 '{"success":false,"description":"Bad Credentials"}';
      }
      default_type application/json;
      alias /data/nodes.json;
    }
  }
}
EOF
# lab-1 the stand-in node, lab-2 revoked, legacy without a WireGuard key
nodes "lab-1:10.239.0.2:active:${node_public}" "lab-2:10.239.0.3:revoked:${other_public}" "legacy:192.168.1.5:active:"
# the stand-ins in place of the images and the commands of stf-proxy and stf-triproxy-dev; their ports are the ones of
# docker-compose.yml
cat > "${MCLOUD}/docker-compose.override.yml" << EOF
---
services:
  stf-proxy:
    image: "${NGINX}"
    volumes:
      - ${API}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${API}:/data:ro
    healthcheck:
      disable: true
  stf-triproxy-dev:
    image: "${NGINX}"
    command: ["nginx", "-g", "daemon off;"]
    volumes:
      - ${API}/nginx.conf:/etc/nginx/nginx.conf:ro
    healthcheck:
      disable: true
EOF

section "the tunnel"
cp "${REPO}/.env.original" "${MCLOUD}/.env"
cp "${REPO}/variables.env.original" "${MCLOUD}/variables.env"
# the values of ./zebrunner.sh start with the tunnel: the ports of the nodes on the loopback address (NODES_ADDRESS)
sed -i.orig -e "s|^STF_PORT=.*|STF_PORT=18083|" -e "s|^STF_URL=.*|STF_URL=http://localhost:18083|" \
  -e "s|^NODES_WIREGUARD=.*|NODES_WIREGUARD=true|" -e "s|^NODES_WG_NETWORK=.*|NODES_WG_NETWORK=${NETWORK}|" \
  -e "s|^NODES_WG_PORT=.*|NODES_WG_PORT=${PORT}|" -e "s|^NODES_WG_SYNC_SECONDS=.*|NODES_WG_SYNC_SECONDS=1|" \
  -e "s|^NODES_ADDRESS=.*|NODES_ADDRESS=127.0.0.1|" -e "s|^NODES_GRID_PORT=.*|NODES_GRID_PORT=4447|" "${MCLOUD}/.env"
# the files of ./zebrunner.sh start: the private key of the server, STF_TOKEN
(umask 077 && echo "$server_private" > "${MCLOUD}/configuration/wireguard/private-key" &&
  echo test-token > "${MCLOUD}/configuration/wireguard/stf-token")
# as at the boot: the services of the ports of the nodes start before the interface of the tunnel exists
run_check "stf-proxy and stf-triproxy-dev start without the tunnel" \
  bash -c "cd '${MCLOUD}' && docker compose --profile wireguard up -d --no-deps stf-proxy stf-triproxy-dev"
run_check "stf-proxy and stf-triproxy-dev run" wait_for 30 running stf-proxy stf-triproxy-dev
check "the ports of the nodes are published on the loopback address" "127.0.0.1:4446 127.0.0.1:7250 127.0.0.1:7270" \
  "$({
    docker port stf-proxy 4447/tcp
    docker port stf-triproxy-dev 7250/tcp
    docker port stf-triproxy-dev 7270/tcp
  } | paste -sd ' ' -)"
run_check "wireguard starts" bash -c "cd '${MCLOUD}' && docker compose --profile wireguard up -d wireguard"
run_check "wireguard is healthy" wait_for 180 \
  bash -c "test \"\$(docker inspect --format '{{.State.Health.Status}}' wireguard)\" == healthy"
check_contains "the address of the server on the interface mcloud" "inet 10.239.0.1/24" \
  "$(docker exec wireguard ip -o -4 address show dev mcloud)"
check "the UDP port of the tunnel" "$PORT" "$(docker exec wireguard wg show mcloud listen-port)"
check "the key of the server" "$server_public" "$(docker exec wireguard wg show mcloud public-key)"
check "the private key is no setting of the container" "" \
  "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' wireguard | grep -F "$server_private")"
run_check "the active node with a key is the peer" wait_for 30 peers_are "${node_public} 10.239.0.2/32"
log="$(docker logs wireguard 2>&1)"
check_contains "the tunnel is up" "The tunnel mcloud is up: 10.239.0.1/24, UDP port ${PORT}" "$log"
check_contains "the peer is logged" "The node lab-1 at 10.239.0.2 is a peer" "$log"
check_contains "a node without a key is logged" "The node legacy is no peer: enrolled without a WireGuard key" "$log"
check_not_contains "the private key is not logged" "$server_private" "$log"
check_contains "the relay is logged" \
  "The ports of the nodes on 10.239.0.1 are relayed to the ones of stf-proxy and stf-triproxy-dev on 127.0.0.1: 4446, 7250, 7270 (the PROXY protocol to 4446)." "$log"
check "the relay listens on the WireGuard address of the server" "10.239.0.1:4446
10.239.0.1:7250
10.239.0.1:7270" "$(listeners 10.239.0.1)"
check "no port of the nodes listens on every address" "" \
  "$(host "ss -Hltn | awk '{ print \$4 }'" | grep -E '^(0[.]0[.]0[.]0|[*]|[[]::[]]):(4446|7250|7270)$')"

section "a node"
# the stand-in node: its own interface in a docker network, it dials the server at the gateway of the network as a node
# dials the public host of MCloud: the address of the node, the server as its only peer, a keepalive
docker network create wireguard-test > /dev/null
gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' wireguard-test)"
echo "$node_private" > "${API}/node.key"
run_check "the node" docker run -d --name wireguard-test-node --network wireguard-test --cap-add NET_ADMIN \
  -v "${API}/node.key:/node.key:ro" "$ALPINE" sh -c "apk add --no-cache --quiet iproute2 wireguard-tools-wg &&
    ip link add dev mcloud type wireguard &&
    wg set mcloud private-key /node.key peer '${server_public}' endpoint '${gateway}:${PORT}' allowed-ips 10.239.0.1/32 \
      persistent-keepalive 25 &&
    ip address add 10.239.0.2/32 dev mcloud && ip link set up dev mcloud && ip route add 10.239.0.1/32 dev mcloud &&
    touch /ready && sleep 600"
# before its tunnel is up the node would reach the server by its default route
run_check "the tunnel of the node is up" wait_for 60 docker exec wireguard-test-node test -f /ready
run_check "the node reaches the server through the tunnel" wait_for 30 docker exec wireguard-test-node ping -c 1 -W 2 10.239.0.1
check "a handshake of the node" "yes" \
  "$(docker exec wireguard wg show mcloud latest-handshakes | awk -v key="$node_public" '$1 == key && $2 > 0 { print "yes" }')"
run_check "the server reaches the node through the tunnel" docker exec wireguard ping -c 1 -W 2 10.239.0.2
run_check "a container of a docker network of the server reaches the node (stf-proxy, the grid)" \
  docker run --rm --network infra "$ALPINE" ping -c 1 -W 2 10.239.0.2
# the ports of the nodes through the relay to the published ports of the loopback address; Docker Desktop publishes the
# ports on its host, not in its VM, where the relay is
desktop=""
if [[ "$(docker info --format '{{.OperatingSystem}}' 2> /dev/null)" == *"Docker Desktop"* ]]; then
  desktop=1
  skip_check "the node reaches the ports of the nodes" "Docker Desktop publishes the ports on its host, not its VM"
else
  run_check "the node reaches the ports of the nodes on the WireGuard address of the server" wait_for 30 node_reaches_ports
fi

section "the restarts in any order"
# docker restarts the containers at the boot of the server in no order of docker-compose.yml: the ports of the nodes come
# back in any order, also when stf-proxy and stf-triproxy-dev start before the interface of the tunnel exists
if [[ -n "$desktop" ]]; then
  skip_check "the restarts in any order" "Docker Desktop publishes the ports on its host, not its VM"
else
  for round in 1 2 3; do
    order="$(shuffled wireguard stf-proxy stf-triproxy-dev)"
    # shellcheck disable=SC2086 # the containers of the order are words
    run_check "round ${round}: docker restart ${order// /, }" restart_in_order $order
    run_check "round ${round}: the node reaches the ports of the nodes again" wait_for 90 node_reaches_ports
  done
  run_check "the boot: every service stops" docker stop wireguard stf-proxy stf-triproxy-dev
  run_check "the boot: stf-proxy and stf-triproxy-dev start before the tunnel" docker start stf-triproxy-dev stf-proxy
  check "the boot: no interface of the tunnel yet" "" "$(host 'ip link show dev mcloud 2> /dev/null')"
  run_check "the boot: stf-proxy and stf-triproxy-dev run without the tunnel" wait_for 10 running stf-proxy stf-triproxy-dev
  run_check "the boot: the tunnel starts after them" docker start wireguard
  run_check "the boot: the node reaches the ports of the nodes" wait_for 90 node_reaches_ports
fi

section "without the service wireguard"
run_check "docker stop wireguard" docker stop wireguard
check "the interface goes with it" "" "$(host 'ip link show dev mcloud 2> /dev/null')"
check "nothing listens on the WireGuard address" "" "$(listeners 10.239.0.1)"
# the loop runs in the shell of the container
# shellcheck disable=SC2016
check "the ZeroMQ ports of the nodes stay published on the loopback address" "7250 7270" \
  "$(host 'for port in 7250 7270; do wget -q -O - -T 3 http://127.0.0.1:${port}/; echo; done' | paste -sd ' ' -)"
check "the grid of the nodes stays published on the loopback address, with the PROXY protocol only" "4446 from 127.0.0.1:000" \
  "$(curl -s --max-time 5 --haproxy-protocol http://127.0.0.1:4446/):$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:4446/)"
run_check "docker start wireguard" docker start wireguard
run_check "wireguard is healthy again" wait_for 60 \
  bash -c "test \"\$(docker inspect --format '{{.State.Health.Status}}' wireguard)\" == healthy"
if [[ -z "$desktop" ]]; then
  run_check "the node reaches the ports of the nodes again" wait_for 90 node_reaches_ports
fi

section "a change of the nodes"
nodes "lab-1:10.239.0.2:revoked:${node_public}" "lab-3:10.239.0.4:active:${other_public}"
run_check "a revoked node is cut at once, a new one is a peer" wait_for 30 peers_are "${other_public} 10.239.0.4/32"
check_contains "the removed peer is logged" "is removed: no active node of STF has its key and address" "$(docker logs wireguard 2>&1)"
check "the revoked node does not reach the server any more" "1" "$(
  docker exec wireguard-test-node ping -c 1 -W 2 10.239.0.1 > /dev/null 2>&1
  echo "$?"
)"

section "errors of the STF API"
echo wrong > "${MCLOUD}/configuration/wireguard/stf-token"
run_check "a refused token is logged" wait_for 30 log_has "The STF API http://127.0.0.1:18083 failed, the tunnel keeps its peers"
check "the tunnel keeps its peers" "${other_public} 10.239.0.4/32" "$(peers)"
echo test-token > "${MCLOUD}/configuration/wireguard/stf-token"
run_check "a new token is read on the next sync" wait_for 30 log_has "The STF API http://127.0.0.1:18083 answers with the nodes again."

section "wireguard.sh in the image"
run_check "the tests of wireguard.sh with the bash and the busybox awk of alpine" \
  docker run --rm -v "${REPO}:/repo:ro" "$ALPINE" sh -c 'apk add --no-cache --quiet bash python3 openssl && bash /repo/tests/wireguard_test.sh'

section "the end"
(cd "$MCLOUD" && docker compose --profile wireguard down > /dev/null 2>&1)
check "wireguard and the stand-ins are removed" "" "$(docker ps -aq --filter name='^/(wireguard|stf-proxy|stf-triproxy-dev)$')"
check "the interface mcloud goes with it" "" "$(host 'ip link show dev mcloud 2> /dev/null')"

finish
