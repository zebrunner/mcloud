#!/bin/bash
# The entrypoint of the service wireguard (README.md#wireguard-tunnel-of-the-nodes), the WireGuard tunnel of the nodes
# with NODES_WIREGUARD=true: it creates the interface mcloud in the network of the host with the key of the server
# (configuration/wireguard/private-key) and its address, the first host of NODES_WG_NETWORK, and makes its peers the
# active nodes of STF with a WireGuard key every NODES_WG_SYNC_SECONDS: the registry of STF (GET /api/v1/nodes) is the
# only source of the peers, so a revoked node is cut at once and an enrolled one is let in without a restart.
# tests/wireguard_test.sh sources it: keep the functions compatible with the macOS system bash 3.2, mawk and BSD awk.

# the folder of this script, its awk program and the files ./zebrunner.sh start writes (mode 600): the private key of
# the server (NODES_WG_PRIVATE_KEY of variables.env, never in the environment or the arguments of a process) and
# STF_TOKEN of variables.env, read on every sync
WG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${KEY_FILE:-${WG_DIR}/private-key}"
TOKEN_FILE="${TOKEN_FILE:-${WG_DIR}/stf-token}"
# the interface of the tunnel on the server and on the nodes
INTERFACE="${INTERFACE:-mcloud}"
# the registry of the nodes of STF: the WireGuard key, the address and the status of every node
NODES_PATH="/api/v1/nodes"

# the addresses of the tunnel and WG_KEY_REGEX, shared with zebrunner.sh
# shellcheck source=network.sh
source "${WG_DIR}/network.sh"

#### Helpers

# log <level> <message>: a line of the log of the container
log() {
  echo "[$(date '+%d/%m/%Y %H:%M:%S')] [$1] $2"
}

# stf_token: the access token of STF of the file of ./zebrunner.sh, STF_TOKEN of variables.env
stf_token() {
  head -1 "$TOKEN_FILE" 2> /dev/null | tr -d ' \r'
}

# short_key <key>: the first characters of a public key of a node, for the log
short_key() {
  echo "${1:0:8}..."
}

# nodes_of_json: the nodes of a JSON answer of GET /api/v1/nodes of STF (stdin), a line per node:
# <label>|<status>|<address>|<wgPublicKey>; fails when the answer has no nodes
nodes_of_json() {
  awk -f "${WG_DIR}/nodes.awk"
}

# wanted_peers <network>: the peers of the node lines of nodes_of_json (stdin): `peer|<key>|<address>|<label>` for an
# active node with a WireGuard key and an address of the network, `skip|<label>|<reason>` for an active node that is
# no peer; a revoked node is no peer and no line. A key or an address of two nodes is the peer of none of them: the
# tunnel cannot tell which one is meant (STF refuses them anyway)
wanted_peers() {
  local network="$1"
  local label status address key
  local candidates=""
  while IFS='|' read -r label status address key; do
    if [[ -z "$label" || "$status" != "active" ]]; then
      continue
    fi
    if [[ -z "$key" ]]; then
      echo "skip|${label}|enrolled without a WireGuard key: invite it again (./zebrunner.sh node-invite ${label}) and join with an mcloud-agent that has the tunnel"
    elif [[ ! "$key" =~ $WG_KEY_REGEX ]]; then
      echo "skip|${label}|its WireGuard key is not a key"
    elif ! wg_node_address "$network" "$address"; then
      echo "skip|${label}|its address ${address} is not an address of a node in NODES_WG_NETWORK ${network}"
    else
      candidates+="${key}|${address}|${label}"$'\n'
    fi
  done
  printf '%s' "$candidates" | awk -F '|' '
    NF { lines[++count] = $0; keys[$1]++; addresses[$2]++ }
    END {
      for (k = 1; k <= count; k++) {
        split(lines[k], f, "|")
        if (keys[f[1]] > 1) print "skip|" f[3] "|its WireGuard key is the one of another node"
        else if (addresses[f[2]] > 1) print "skip|" f[3] "|its address " f[2] " is the one of another node"
        else print "peer|" lines[k]
      }
    }
  '
}

# current_peers: the peers of the interface, a line per peer: <key>|<address> (the address of its allowed IPs, empty
# for none)
current_peers() {
  wg show "$INTERFACE" allowed-ips 2> /dev/null | awk '{ address = ($2 == "(none)") ? "" : $2; sub("/32$", "", address); print $1 "|" address }'
}

# peer_changes <wanted peers> <current peers>: what makes the peers of the interface the wanted ones, a line per change:
# `add|<key>|<address>|<label>` (a new peer or a peer with another address) and `remove|<key>|<address>`
peer_changes() {
  printf '%s\n%s\n' "$1" "$2" | awk -F '|' -v wanted_lines="$(grep -c . <<< "$1")" '
    NR <= wanted_lines {
      if ($1 == "peer") { wanted[$2] = $3; order[++count] = $0 }
      next
    }
    NF { current[$1] = $2; current_order[++current_count] = $1 }
    END {
      for (k = 1; k <= count; k++) {
        split(order[k], f, "|")
        if (!(f[2] in current) || current[f[2]] != f[3]) print "add|" f[2] "|" f[3] "|" f[4]
      }
      for (k = 1; k <= current_count; k++) {
        key = current_order[k]
        if (!(key in wanted)) print "remove|" key "|" current[key]
      }
    }
  '
}

# apply_changes <changes>: the changes of peer_changes on the interface, every one logged; fails when one fails
apply_changes() {
  local kind key address label
  local status=0
  while IFS='|' read -r kind key address label; do
    case "$kind" in
    add)
      if wg set "$INTERFACE" peer "$key" allowed-ips "${address}/32"; then
        log "INFO" "The node ${label} at ${address} is a peer (key $(short_key "$key"))."
      else
        status=1
        log "ERROR" "The node ${label} at ${address} is not a peer: wg set failed."
      fi
      ;;
    remove)
      if wg set "$INTERFACE" peer "$key" remove; then
        log "INFO" "The peer $(short_key "$key") at ${address:-(none)} is removed: no active node of STF has its key and address."
      else
        status=1
        log "ERROR" "The peer $(short_key "$key") at ${address:-(none)} is not removed: wg set failed."
      fi
      ;;
    esac
  done <<< "$1"
  return "$status"
}

# report_error <message>: logs an error once, until the next one or a successful sync
report_error() {
  if [[ "$1" != "$last_error" ]]; then
    last_error="$1"
    log "ERROR" "$1"
  fi
}

#### Sync

# sync_peers: the active nodes of the STF API to the peers of the interface; a failed read keeps the peers
sync_peers() {
  local token answer nodes wanted changes skipped
  token="$(stf_token)"
  if [[ -z "$token" ]]; then
    report_error "The access token of STF (STF_TOKEN of variables.env) is empty: the peers are not read, set it and run ./zebrunner.sh start (README.md#wireguard-tunnel-of-the-nodes)."
    return
  fi
  # the certificate of stf-proxy is the one of the public name of MCloud, not of the loopback address; the token is in
  # the configuration of curl on its stdin: the arguments of a container are seen by every user of the host
  if ! answer="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS -k --max-time 20 -K - "${stf_api}${NODES_PATH}" 2>&1)"; then
    report_error "The STF API ${stf_api} failed, the tunnel keeps its peers: ${answer}"
    return
  fi
  if ! nodes="$(nodes_of_json <<< "$answer")"; then
    report_error "The STF API ${stf_api} answered without nodes, the tunnel keeps its peers: ${answer:0:200}"
    return
  fi
  if [[ -n "$last_error" ]]; then
    log "INFO" "The STF API ${stf_api} answers with the nodes again."
  fi
  last_error=""
  wanted="$(wanted_peers "$NODES_WG_NETWORK" <<< "$nodes")"
  changes="$(peer_changes "$wanted" "$(current_peers)")"
  if [[ -n "$changes" ]]; then
    apply_changes "$changes"
    log "INFO" "Peers of the tunnel: $(grep -c '^peer|' <<< "$wanted")."
  fi
  skipped="$(grep '^skip|' <<< "$wanted")"
  if [[ "$skipped" != "$last_skipped" ]]; then
    last_skipped="$skipped"
    while IFS='|' read -r _ label reason; do
      if [[ -n "$label" ]]; then
        log "WARN" "The node ${label} is no peer: ${reason}."
      fi
    done <<< "$skipped"
  fi
}

#### Main

# interface_down: removes the interface, its peers and its address go with it
interface_down() {
  ip link del dev "$INTERFACE" 2> /dev/null
}

# main: the interface and the sync of the peers; ./zebrunner.sh starts the service with NODES_WIREGUARD=true only
main() {
  local network server prefix port interval
  if [[ "$NODES_WIREGUARD" != "true" ]]; then
    log "WARN" "NODES_WIREGUARD is '${NODES_WIREGUARD}', not true: no tunnel."
    trap 'exit 0' TERM INT
    while true; do
      sleep 3600 &
      wait $!
    done
  fi
  if ! network="$(wg_network "$NODES_WG_NETWORK")"; then
    log "ERROR" "NODES_WG_NETWORK '${NODES_WG_NETWORK}' is not a private network <address>/<16-30> without the host bits, out of ${WG_DEVICE_NETWORKS}: no tunnel."
    exit 1
  fi
  prefix="${network##* }"
  server="$(wg_server_address "$NODES_WG_NETWORK")"
  port="$NODES_WG_PORT"
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || ((port > 65535)); then
    log "ERROR" "NODES_WG_PORT '${port}' is not a port: no tunnel."
    exit 1
  fi
  if [[ ! "$(head -1 "$KEY_FILE" 2> /dev/null)" =~ $WG_KEY_REGEX ]]; then
    log "ERROR" "The private key of the server (${KEY_FILE}, NODES_WG_PRIVATE_KEY of variables.env) is missing or not a WireGuard key: run ./zebrunner.sh start, it makes it."
    exit 1
  fi
  interval="$NODES_WG_SYNC_SECONDS"
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ ]]; then
    log "WARN" "NODES_WG_SYNC_SECONDS '${interval}' is not a number of seconds, the nodes are read every 5 seconds."
    interval=5
  fi
  # stf-proxy on the published port of the host: the scheme of STF_URL is the one of stf-proxy (README.md#https)
  stf_api="${STF_URL%%://*}://127.0.0.1:${STF_PORT}"
  last_error=""
  last_skipped=""

  # the interface of an earlier run of the container that was killed
  interface_down
  # `dev`: ip takes a short name for a keyword otherwise (e.g. t for txqueuelen)
  if ! ip link add dev "$INTERFACE" type wireguard; then
    log "ERROR" "The interface ${INTERFACE} is not created: the server needs the wireguard module of its kernel (Linux 5.6+, modprobe wireguard) and the service NET_ADMIN."
    exit 1
  fi
  trap 'interface_down; exit 0' TERM INT
  if ! wg set "$INTERFACE" listen-port "$port" private-key "$KEY_FILE" ||
    ! ip address add "${server}/${prefix}" dev "$INTERFACE" || ! ip link set up dev "$INTERFACE"; then
    log "ERROR" "The interface ${INTERFACE} is not set up (the UDP port ${port} or the address ${server} may be taken on this server)."
    interface_down
    exit 1
  fi
  log "INFO" "The tunnel ${INTERFACE} is up: ${server}/${prefix}, UDP port ${port}; the peers are the active nodes of STF (${stf_api}), read every ${interval} seconds."
  while true; do
    sync_peers
    sleep "$interval" &
    wait $!
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
