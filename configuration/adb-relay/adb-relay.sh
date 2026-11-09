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

# relay_devices <first port> <last port> <ports not to relay>: the device lines of devices_of_json (stdin) with what the
# relay does with them, a line per Android device, present or not: `relay|<port>|<address>|<serial>|<label>` or
# `skip|<port>|<address>|<serial>|<label>|<reason>`. The port is connectPort, the address the one of the node; an empty
# first port takes any port; the ports not to relay (of MCloud) are separated by spaces, a range as
# <first>-<last>; a port of two devices is not relayed
relay_devices() {
  awk -v first="$1" -v last="$2" -v reserved="$3" -f "${AWK_DIR}/relay.awk"
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

# stf_token: the access token of STF of the file of ./zebrunner.sh, STF_TOKEN of variables.env
stf_token() {
  head -1 "$TOKEN_FILE" 2> /dev/null | tr -d ' \r'
}

#### Sync

# sync_devices: the devices of the STF API to the servers of AUTO_CONF; nginx reloads when they change; a failure keeps
# the servers the relay has
sync_devices() {
  local token answer devices report conf previous
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
  report="$(relay_devices "$relay_first" "$relay_last" "$reserved_ports" <<< "$devices")"
  conf="$(servers_of "$resolvers" <<< "$report")"
  previous="$(cat "$AUTO_CONF" 2> /dev/null)"
  if [[ "$conf" != "$previous" ]]; then
    printf '%s\n' "$conf" > "$AUTO_CONF"
    if nginx -t -q 2> /dev/null; then
      kill -HUP "$nginx_pid"
    else
      log "ERROR" "nginx refuses the servers of the devices, the relay keeps its devices: $(nginx -t 2>&1 | tr '\n' ' ')"
      printf '%s\n' "$previous" > "$AUTO_CONF"
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
  relay_first=""
  relay_last=""
  if [[ -n "$ADB_RELAY_PORTS" ]]; then
    if range="$(port_range "$ADB_RELAY_PORTS")"; then
      relay_first="${range% *}"
      relay_last="${range#* }"
    else
      log "ERROR" "ADB_RELAY_PORTS '${ADB_RELAY_PORTS}' is not <first>-<last> of the ports 1024-65535: no device of STF is relayed."
      relay_first=1
      relay_last=0
    fi
  fi
  # stf-proxy on the published port of the host: the scheme of STF_URL is the one of stf-proxy (README.md#https)
  stf_api="${STF_URL%%://*}://127.0.0.1:${STF_PORT}"
  reserved_ports="${STF_PORT} 4446 7160 7250 7260 7270"
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
