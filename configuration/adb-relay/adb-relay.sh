#!/bin/bash
# The entrypoint of adb-relay (README.md#remote-debug-through-the-adb-relay), it runs in the nginx image: nginx relays the
# remote debug ports of the Android devices of the nodes in a private network. With ADB_RELAY=true this script reads the
# devices of the enrolled nodes from the STF API (GET /api/v1/nodes/relay: the registered address of the node, never an address the node reports) every
# ADB_RELAY_SYNC_SECONDS and reloads nginx when their servers change (gracefully: the open sessions go on): the devices of
# STF, present or not, so only a new, a removed or a moved device changes them.
# tests/adb_relay_test.sh sources it: keep the functions compatible with the macOS system bash 3.2, mawk and BSD awk.

# the configuration of nginx (configuration/adb-relay/nginx.conf includes stream-conf.d), the file of ./zebrunner.sh
AUTO_CONF="${AUTO_CONF:-/etc/nginx/stream-conf.d/adb-relay-auto.conf}"
# STF_TOKEN of variables.env, the only secret of MCloud the relay gets: ./zebrunner.sh start writes it (mode 600), it is
# read on every sync
TOKEN_FILE="${TOKEN_FILE:-/opt/adb-relay/stf-token}"
# the awk programs next to this script
AWK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the Android devices bound to an active node with the address of the node (README.md#nodes)
RELAY_PATH="/api/v1/nodes/relay"
# the sockets of the server (the network of the host) and the descriptors of nginx: the ports other programs listen on
# and the ones nginx took after a reload
PROC="${PROC:-/proc}"
# a reload is checked so many times, half a second apart, before it counts as failed
RELOAD_CHECKS="${RELOAD_CHECKS:-10}"

#### Helpers

# log <level> <message>: a line of the log of the container
log() {
  echo "[$(date '+%d/%m/%Y %H:%M:%S')] [$1] $2"
}

# port_range <first>-<last>: prints `<first> <last>` of a range of the ports 1024-65535, fails for another value
port_range() {
  local first last
  if [[ ! "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    return 1
  fi
  first=$((10#${BASH_REMATCH[1]}))
  last=$((10#${BASH_REMATCH[2]}))
  if ((first < 1024 || last > 65535 || first > last)); then
    return 1
  fi
  echo "$first $last"
}

# devices_of_json: the devices of a JSON answer of GET /api/v1/nodes/relay of STF (stdin), a line per device:
# <serial>|<label of the node>|<address of the node>|<connectPort>; fails when the answer has no devices
devices_of_json() {
  awk -f "${AWK_DIR}/devices.awk"
}

# relay_devices <first port> <last port> <ports not to relay> [<ports in use>] [<relayed devices>]: the device lines of
# devices_of_json (stdin) with what the relay does with them, a line per Android device, present or not:
# `relay|<port>|<address>|<serial>|<label>` or `skip|<port>|<address>|<serial>|<label>|<reason>`. The port is
# connectPort, the address the one of the node; an empty first port relays no port (ADB_RELAY_PORTS is mandatory); the
# ports not to relay (of MCloud) are separated by spaces, a range as <first>-<last>; the ports in use are the ones other
# programs of the server listen on; a port of two devices is relayed for one of them: the one of the relayed devices
# (`<port>/<serial>/<label>`, separated by spaces), else the first by the label of its node and its serial
relay_devices() {
  awk -v first="$1" -v last="$2" -v reserved="$3" -v busy="${4:-}" -v current="${5:-}" -f "${AWK_DIR}/relay.awk"
}

# relayed_of <servers>: the relayed devices of the servers of servers_of (stdin), `<port>/<serial>/<label>` separated by
# spaces
relayed_of() {
  awk '
    $1 == "#" && $3 == "of" { serial = $2; label = $4 }
    $1 == "listen" { port = $2; printf "%s%s/%s/%s", sep, port, serial, label; sep = " " }
  '
}

# listening_sockets: the TCP sockets of the server that listen, a line per socket: `<port> <inode>`; nothing without
# ${PROC}/net/tcp (not Linux)
listening_sockets() {
  cat "${PROC}/net/tcp" "${PROC}/net/tcp6" 2> /dev/null | awk -f "${AWK_DIR}/sockets.awk"
}

# nginx_inodes: the inodes of the sockets of nginx (its master process holds the listening ones)
nginx_inodes() {
  local fd target
  for fd in "${PROC}/${nginx_pid}/fd/"*; do
    target="$(readlink "$fd" 2> /dev/null)"
    if [[ "$target" =~ ^socket:\[([0-9]+)\]$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done
}

# ports_of <owner>: the listening ports of nginx (owner nginx) or of the other programs of the server (owner other),
# separated by spaces; without the descriptors of nginx every port is one of nginx (no port is taken for one of
# another program, a reload is checked by the ports only)
ports_of() {
  local inodes
  inodes="$(nginx_inodes | tr '\n' ' ')"
  listening_sockets | awk -v owner="$1" -v inodes=" ${inodes}" '
    { mine = inodes == " " || index(inodes, " " $2 " ") > 0 }
    (owner == "nginx" && mine) || (owner == "other" && !mine) { if (!seen[$1]++) { printf "%s%s", sep, $1; sep = " " } }
  '
}

# missing_ports <servers>: the ports of the servers of servers_of (stdin) nginx does not listen on, separated by spaces;
# nothing when the sockets of the server can't be read
missing_ports() {
  local listening
  [[ -r "${PROC}/net/tcp" ]] || return 0
  listening=" $(ports_of nginx) "
  awk '$1 == "listen" { print $2 }' | while read -r port; do
    [[ "$listening" == *" ${port} "* ]] || printf '%s ' "$port"
  done
}

# reload_nginx <servers>: reloads nginx with the servers of AUTO_CONF and waits until it listens on every port of them;
# fails with the ports it does not listen on (e.g. a port another program took: nginx keeps its servers then)
reload_nginx() {
  local missing check
  kill -HUP "$nginx_pid"
  for ((check = 1; check <= RELOAD_CHECKS; check++)); do
    missing="$(missing_ports <<< "$1")"
    [[ -z "$missing" ]] && return 0
    ((check < RELOAD_CHECKS)) && sleep 0.5
  done
  echo "${missing% }"
  return 1
}

# servers_of <resolvers>: the servers of nginx of the relay lines of relay_devices (stdin), the resolvers (of
# /etc/resolv.conf) for the nodes given by name
servers_of() {
  awk -v resolvers="$1" '
    BEGIN { FS = "|" }
    $1 == "relay" {
      print "# " $4 " of " $5
      print "server {"
      print "  listen " $2 " so_keepalive=on;"
      if ($3 !~ /^[0-9.]+$/ && resolvers != "") print "  resolver " resolvers " valid=30s ipv6=off;"
      print "  proxy_pass " $3 ":$server_port;"
      print "}"
    }
  '
}

# reserved_of: the ports of MCloud on the server, never relayed (also before their service listens): stf-proxy
# (STF_PORT, the grid of the nodes 4446 and its listener 4447), the ZeroMQ ports of the triproxies, MQTT and the admin UI
# of the MDM (MDM_MQTT_PORT, MDM_ADMIN_PORT), the WireGuard tunnel (NODES_WG_PORT)
reserved_of() {
  echo "${STF_PORT:-80} 4446 4447 ${NODES_GRID_PORT:-4446} 7150 7160 7170 7250 7260 7270 ${MDM_MQTT_PORT:-31443}" \
    "${MDM_ADMIN_PORT:-9101} ${NODES_WG_PORT:-51820}"
}

# stf_token: the access token of STF of the file of ./zebrunner.sh, STF_TOKEN of variables.env
stf_token() {
  head -1 "$TOKEN_FILE" 2> /dev/null | tr -d ' \r'
}

#### Sync

# sync_devices: the devices of the STF API to the servers of AUTO_CONF; nginx reloads when they change; a failure keeps
# the servers the relay has
sync_devices() {
  local token answer devices report conf previous missing
  token="$(stf_token)"
  if [[ -z "$token" ]]; then
    report_error "The access token of STF (STF_TOKEN of variables.env) is empty: no device is relayed, set it and run ./zebrunner.sh start (README.md#remote-debug-through-the-adb-relay)."
    return
  fi
  # the certificate of stf-proxy is the one of the public name of MCloud, not of the loopback address; the token is in
  # the configuration of curl on its stdin: the arguments of a container are seen by every user of the host
  if ! answer="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS -k --max-time 20 -K - "${stf_api}${RELAY_PATH}" 2>&1)"; then
    report_error "The STF API ${stf_api} failed, the relay keeps its devices: ${answer}"
    return
  fi
  if ! devices="$(devices_of_json <<< "$answer")"; then
    report_error "The STF API ${stf_api} answered without devices, the relay keeps its devices: ${answer:0:200}"
    return
  fi
  if [[ -n "$last_error" ]]; then
    log "INFO" "The STF API ${stf_api} answers with the devices again."
  fi
  last_error=""
  previous="$(cat "$AUTO_CONF" 2> /dev/null)"
  # AUTO_CONF has the servers nginx runs: its devices keep their ports, the ports of other programs are not taken
  report="$(relay_devices "$relay_first" "$relay_last" "$reserved_ports" "$(ports_of other 2> /dev/null)" \
    "$(relayed_of <<< "$previous")" <<< "$devices")"
  conf="$(servers_of "$resolvers" <<< "$report")"
  if [[ "$conf" != "$previous" ]]; then
    printf '%s\n' "$conf" > "$AUTO_CONF"
    if ! nginx -t -q 2> /dev/null; then
      log "ERROR" "nginx refuses the servers of the devices, the relay keeps its devices: $(nginx -t 2>&1 | tr '\n' ' ')"
      printf '%s\n' "$previous" > "$AUTO_CONF"
      return
    fi
    # nginx -t does not bind the ports: a reload that fails keeps the servers nginx has, AUTO_CONF gets them back, so the
    # next sync tries again
    if ! missing="$(reload_nginx "$conf")"; then
      report_error "nginx did not take the servers of the devices (it does not listen on ${missing}; docker logs adb-relay shows why), the relay keeps its devices and tries again on the next sync."
      printf '%s\n' "$previous" > "$AUTO_CONF"
      kill -HUP "$nginx_pid"
      return
    fi
  fi
  if [[ "$report" != "$last_report" ]]; then
    last_report="$report"
    log_report "$report"
  fi
}

# report_error <message>: logs an error once, until the next one or a successful sync
report_error() {
  if [[ "$1" != "$last_error" ]]; then
    last_error="$1"
    log "ERROR" "$1"
  fi
}

# log_report <relay lines>: the devices the relay forwards and the ones it skips
log_report() {
  local kind port address serial label reason relayed=0
  while IFS='|' read -r kind port address serial label reason; do
    if [[ "$kind" == "relay" ]]; then
      relayed=$((relayed + 1))
      log "INFO" "Relays the remote debug port ${port} of the device ${serial} of the node ${label} to ${address}:${port}."
    elif [[ "$kind" == "skip" ]]; then
      log "WARN" "Skips the remote debug port ${port:-(none)} of the device ${serial} of the node ${label} (${address}): ${reason}."
    fi
  done <<< "$1"
  log "INFO" "Android devices of the nodes relayed: ${relayed}."
}

#### Main

# main: nginx and the sync of the devices of STF; ./zebrunner.sh starts adb-relay with ADB_RELAY=true only
main() {
  if [[ "$ADB_RELAY" != "true" ]]; then
    log "WARN" "ADB_RELAY is '${ADB_RELAY}', not true: no device is relayed."
    exec /docker-entrypoint.sh nginx -g 'daemon off;'
  fi
  local interval="$ADB_RELAY_SYNC_SECONDS"
  local range
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ ]]; then
    log "WARN" "ADB_RELAY_SYNC_SECONDS '${interval}' is not a number of seconds, the devices are read every 300 seconds."
    interval=300
  fi
  # the range of the relayed ports is mandatory: a node chooses the connect port of its devices
  relay_first=""
  relay_last=""
  if range="$(port_range "$ADB_RELAY_PORTS")"; then
    relay_first="${range% *}"
    relay_last="${range#* }"
  else
    log "ERROR" "ADB_RELAY_PORTS '${ADB_RELAY_PORTS}' is not <first>-<last> of the ports 1024-65535 (e.g. 7400-7999, the range opened in the firewall): no device of STF is relayed (README.md#remote-debug-through-the-adb-relay)."
  fi
  # stf-proxy on the published port of the host: the scheme of STF_URL is the one of stf-proxy (README.md#https)
  stf_api="${STF_URL%%://*}://127.0.0.1:${STF_PORT}"
  reserved_ports="$(reserved_of)"
  resolvers="$(awk '$1 == "nameserver" { printf "%s%s", sep, ($2 ~ /:/ ? "[" $2 "]" : $2); sep = " " }' /etc/resolv.conf)"
  last_error=""
  last_report="none"
  log "INFO" "Relays the remote debug ports of the Android devices of the nodes of STF (${stf_api}) in ADB_RELAY_PORTS '${ADB_RELAY_PORTS:-any}', read every ${interval} seconds."

  mkdir -p "$(dirname "$AUTO_CONF")"
  : > "$AUTO_CONF"
  # the pid file of an earlier run of the container: nginx is ready once it writes its own
  rm -f /run/nginx.pid
  /docker-entrypoint.sh nginx -g 'daemon off;' &
  nginx_pid=$!
  # docker stop: nginx stops at once, an adb session cannot be waited for
  trap 'kill -TERM "$nginx_pid" 2> /dev/null; wait "$nginx_pid"; exit 0' TERM INT
  until [[ -s /run/nginx.pid ]]; do
    if ! kill -0 "$nginx_pid" 2> /dev/null; then
      exit 1
    fi
    sleep 1
  done
  while kill -0 "$nginx_pid" 2> /dev/null; do
    sync_devices
    sleep "$interval" &
    wait $!
  done
  log "ERROR" "nginx stopped."
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
