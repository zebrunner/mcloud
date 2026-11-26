#!/bin/bash
# Tests of the service wireguard in docker (README.md#wireguard-tunnel-of-the-nodes): the tunnel with a fake STF API (the
# registry of the nodes) on the port of stf-proxy of the host and a stand-in node in a docker network that dials it with
# its own WireGuard interface: the peers of the registry, a handshake, the port of a node published on the WireGuard
# address of the server, the removal of a revoked node and of the interface. It needs the wireguard module of the kernel
# of docker (Linux 5.6+; skipped without it). The containers have fixed names, the interface mcloud is the one of the
# server and the test uses the network 10.239.0.0/24, the UDP port 51899 and the ports 18083 and 18446 of the host.
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd python3
docker info > /dev/null 2>&1 || skip "requires a running docker"
docker compose version > /dev/null 2>&1 || skip "requires docker compose"
if [[ -n "$(docker ps -aq --filter name='^/(wireguard|wireguard-test-api|wireguard-test-node|wireguard-test-port)$')" ]]; then
  skip "the containers of wireguard exist on this machine"
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
  docker rm -f wireguard-test-api wireguard-test-node wireguard-test-port > /dev/null 2>&1
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
# the fake STF API on the port of stf-proxy (STF_PORT), with the access token test-token only
cat > "${API}/nginx.conf" << 'EOF'
events {}
http {
  server {
    listen 18083;
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
run_check "the fake STF API" docker run -d --name wireguard-test-api -p 18083:18083 -v "${API}:/data:ro" \
  -v "${API}/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"

section "the tunnel"
cp "${REPO}/.env.original" "${MCLOUD}/.env"
cp "${REPO}/variables.env.original" "${MCLOUD}/variables.env"
sed -i.orig -e "s|^STF_PORT=.*|STF_PORT=18083|" -e "s|^STF_URL=.*|STF_URL=http://localhost:18083|" \
  -e "s|^NODES_WIREGUARD=.*|NODES_WIREGUARD=true|" -e "s|^NODES_WG_NETWORK=.*|NODES_WG_NETWORK=${NETWORK}|" \
  -e "s|^NODES_WG_PORT=.*|NODES_WG_PORT=${PORT}|" -e "s|^NODES_WG_SYNC_SECONDS=.*|NODES_WG_SYNC_SECONDS=1|" "${MCLOUD}/.env"
# the files of ./zebrunner.sh start: the private key of the server, STF_TOKEN
(umask 077 && echo "$server_private" > "${MCLOUD}/configuration/wireguard/private-key" &&
  echo test-token > "${MCLOUD}/configuration/wireguard/stf-token")
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
# a port published on the WireGuard address of the server, as the ports of the nodes (4446, 7250, 7270); Docker
# Desktop publishes the ports on the addresses of its host, not of its VM, where the interface is
if [[ "$(docker info --format '{{.OperatingSystem}}' 2> /dev/null)" == *"Docker Desktop"* ]]; then
  skip_check "a port on the WireGuard address of the server" "Docker Desktop publishes the ports on its host, not its VM"
else
  run_check "a port on the WireGuard address of the server" docker run -d --name wireguard-test-port -p 10.239.0.1:18446:80 "$NGINX"
  run_check "the node reaches the port on the WireGuard address of the server" wait_for 30 \
    docker exec wireguard-test-node wget -q -O /dev/null -T 3 http://10.239.0.1:18446/
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
check "wireguard is removed" "" "$(docker ps -aq --filter name='^/wireguard$')"
check "the interface mcloud goes with it" "" "$(host 'ip link show dev mcloud 2> /dev/null')"

finish
