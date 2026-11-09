#!/bin/bash
# Tests of configuration/adb-relay/adb-relay.sh, the entrypoint of adb-relay: the devices of answers of the STF API
# (GET /api/v1/nodes/relay, the devices of the enrolled nodes), what the relay does with them, its servers of nginx and
# the sync; curl and nginx are stubs (the container itself is checked by tests/adb_relay_docker_test.sh).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
# shellcheck source=../configuration/adb-relay/adb-relay.sh
source configuration/adb-relay/adb-relay.sh

# an answer of the STF API, pretty-printed, with the escapes of JSON and a field more
PRETTY='{
  "success": true,
  "devices": [
    {
      "serial": "emulator-5554",
      "label": "lab-1",
      "address": "192.168.30.2",
      "connectPort": 7405,
      "present": true
    },
    {
      "serial": "R58M\"x",
      "label": "lab\/2",
      "address": "agent1.lan",
      "connectPort": 7461
    }
  ]
}'
# an answer on one line, a device without connectPort
COMPACT="$(printf '%s' '{"success":true,"devices":[{"serial":"a","label":"lab-1","address":"192.168.30.2",' \
  '"connectPort":7420},{"serial":"b","label":"lab-3","address":"192.168.30.3","connectPort":null}]}')"

# device <serial> <label> <address> <connectPort>: a line of devices_of_json
device() {
  echo "$1|$2|$3|$4"
}

section "devices of the STF API"
check "a pretty-printed answer: the device lines, the escapes of JSON" "emulator-5554|lab-1|192.168.30.2|7405
R58M_x|lab_2|agent1.lan|7461" "$(devices_of_json <<< "$PRETTY")"
check "an answer on one line" "a|lab-1|192.168.30.2|7420
b|lab-3|192.168.30.3|null" "$(devices_of_json <<< "$COMPACT")"
check "no device" "0:" "$(
  devices="$(devices_of_json <<< '{"success":true,"devices":[]}')"
  echo "$?:${devices}"
)"
check "an answer without devices fails" "1:" "$(
  devices="$(devices_of_json <<< '{"success":false}')"
  echo "$?:${devices}"
)"
check "an answer that is not JSON fails" "1" "$(
  devices_of_json <<< '<html>502 Bad Gateway</html>' > /dev/null
  echo "$?"
)"
check "a cut answer fails" "1" "$(
  devices_of_json <<< '{"devices":[{"serial":"a' > /dev/null
  echo "$?"
)"
check "the devices of another key are not the devices" "" \
  "$(devices_of_json <<< '{"other":{"devices":[{"serial":"x","address":"10.0.0.1"}]},"devices":[]}')"
check "a separator in the address is escaped" "x|n|10.0.0.1%7C7400|7401" \
  "$(devices_of_json <<< '{"devices":[{"serial":"x","label":"n","address":"10.0.0.1|7400","connectPort":7401}]}')"

section "what the relay does"
check "the registered address of the node and connectPort" "relay|7405|192.168.30.2|emulator-5554|lab-1
relay|7461|agent1.lan|R58M_x|lab_2" "$(devices_of_json <<< "$PRETTY" | relay_devices "" "" "")"
check "a device without connectPort is skipped" "relay|7420|192.168.30.2|a|lab-1
skip||192.168.30.3|b|lab-3|no remote debug port in STF" "$(devices_of_json <<< "$COMPACT" | relay_devices "" "" "")"
for address in 127.0.0.1 0.0.0.0 169.254.169.254 224.0.0.1 255.255.255.255 localhost a.localhost 10.0.0.256 1.2.3 \
  "a b" -x.lan 10.0.0.1%7C7400; do
  check "the address '${address}' is not relayed to" \
    "skip|7401|${address}|x|n|the address ${address} of its node is not one to relay to" \
    "$(device x n "$address" 7401 | relay_devices "" "" "")"
done
check "a host name of the node" "relay|7401|node-1.lan|x|n" "$(device x n node-1.lan 7401 | relay_devices "" "" "")"
check "the ports of ADB_RELAY_PORTS only" "relay|7400|192.168.30.2|first|n
relay|7499|192.168.30.2|last|n
skip|7500|192.168.30.2|out|n|the port is not in ADB_RELAY_PORTS 7400-7499
skip|7399|192.168.30.2|below|n|the port is not in ADB_RELAY_PORTS 7400-7499" "$(
  {
    device first n 192.168.30.2 7400
    device last n 192.168.30.2 7499
    device out n 192.168.30.2 7500
    device below n 192.168.30.2 7399
  } | relay_devices 7400 7499 ""
)"
check "the ports of MCloud and of ADB_RELAY_HOSTS are skipped" \
  "skip|8082|192.168.30.2|stf|n|the port is one of MCloud or of ADB_RELAY_HOSTS
skip|7404|192.168.30.2|single|n|the port is one of MCloud or of ADB_RELAY_HOSTS
skip|7465|192.168.30.3|range|n|the port is one of MCloud or of ADB_RELAY_HOSTS
relay|7471|192.168.30.3|free|n" "$(
    {
      device stf n 192.168.30.2 8082
      device single n 192.168.30.2 7404
      device range n 192.168.30.3 7465
      device free n 192.168.30.3 7471
    } | relay_devices "" "" "8082 4446 7404 7460-7469"
  )"
conflict="the port is the one of the devices a, c of STF, none of them is relayed: change connect_port of mcloud-agent of\
 one of them"
check "a port of two devices is skipped for both" "skip|7405|192.168.30.2|a|n1|${conflict}
relay|7411|192.168.30.2|b|n1
skip|7405|192.168.30.3|c|n2|${conflict}" "$(
  {
    device a n1 192.168.30.2 7405
    device b n1 192.168.30.2 7411
    device c n2 192.168.30.3 7405
  } | relay_devices "" "" ""
)"
check "a port below 1024 is skipped" "skip|81|192.168.30.2|low|n|the port is not 1024-65535" \
  "$(device low n 192.168.30.2 81 | relay_devices "" "" "")"

section "servers of nginx"
# shellcheck disable=SC2016 # $server_port of nginx
check "a server per device, the resolvers for a host name" '# emulator-5554 of lab-1
server {
  listen 7405 so_keepalive=on;
  proxy_pass 192.168.30.2:$server_port;
}
# R58M_x of lab_2
server {
  listen 7461 so_keepalive=on;
  resolver 10.0.0.53 [fd00::53] valid=30s ipv6=off;
  proxy_pass agent1.lan:$server_port;
}' "$(devices_of_json <<< "$PRETTY" | relay_devices "" "" "" | servers_of "10.0.0.53 [fd00::53]")"
check "no server of a skipped device" "" \
  "$(device x n 127.0.0.1 7500 | relay_devices "" "" "" | servers_of "")"

section "settings"
check "a port range" "7400 7499" "$(port_range 7400-7499)"
for value in 7400 7499-7400 80-90 7400-70000 x-y ""; do
  check "'${value}' is not a port range" "1" "$(
    port_range "$value" > /dev/null
    echo "$?"
  )"
done
MANUAL_TEMPLATE="${WORK}/relay-hosts.conf"
# shellcheck disable=SC2016 # $server_port of nginx
printf 'resolver ${NGINX_LOCAL_RESOLVERS} valid=30s ipv6=off;\nserver {\n  listen 7404 so_keepalive=on;\n  proxy_pass a:$server_port;\n}\nserver {\n  listen 7460-7469 so_keepalive=on;\n  proxy_pass b:$server_port;\n}\n' > "$MANUAL_TEMPLATE"
check "the ports of ADB_RELAY_HOSTS" "7404 7460-7469 " "$(manual_ports)"
TOKEN_FILE="${WORK}/stf-token"
printf 'abc123\n' > "$TOKEN_FILE"
check "the access token of the file of ./zebrunner.sh" "abc123" "$(stf_token)"
printf 'abc123 \r\nother\n' > "$TOKEN_FILE"
check "the first line of the token file, without spaces" "abc123" "$(stf_token)"
rm -f "$TOKEN_FILE"
check "no token file" "" "$(stf_token)"

section "sync"
PATH="${WORK}/bin:${PATH}"
AUTO_CONF="${WORK}/auto.conf"
relay_first=""
relay_last=""
reserved_ports="8082"
resolvers="10.0.0.53"
stf_api="https://127.0.0.1:8082"
nginx_pid=4242
last_error=""
last_report="none"
printf 'token1\n' > "$TOKEN_FILE"
echo "$PRETTY" > "${WORK}/answer.json"
# curl records its arguments and its configuration of stdin, prints ${WORK}/answer.json, fails with CURL_FAIL; nginx -t
# fails with NGINX_FAIL; kill (of the reload) records
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs
stub curl '(IFS="|"; echo "curl|$*") >> "'"${WORK}"'/calls.log"
cat > "'"${WORK}"'/curl.stdin"
[[ -n "$CURL_FAIL" ]] && echo "curl: (22) The requested URL returned error: 401" >&2 && exit 22
cat "'"${WORK}"'/answer.json"'
# shellcheck disable=SC2016
stub nginx '(IFS="|"; echo "nginx|$*") >> "'"${WORK}"'/calls.log"
[[ -z "$NGINX_FAIL" ]]'
# kill: the reload of nginx is recorded
# shellcheck disable=SC2317,SC2329 # called by sync_devices
kill() {
  (
    IFS='|'
    echo "kill|$*"
  ) >> "${WORK}/calls.log"
}
: > "$AUTO_CONF"
reset_calls
output="$(sync_devices)"
sync_devices > /dev/null
check "the STF API through stf-proxy: the devices of the nodes" \
  "-fsS|-k|--max-time|20|-K|-|https://127.0.0.1:8082/api/v1/nodes/relay" "$(calls curl | head -1)"
check "STF_TOKEN in the configuration of curl on its stdin" 'header = "Authorization: Bearer token1"' \
  "$(cat "${WORK}/curl.stdin")"
check_not_contains "STF_TOKEN is not an argument of curl" "token1" "$(calls curl)"
check_contains "the servers of the devices" "listen 7461 so_keepalive=on;" "$(cat "$AUTO_CONF")"
check "nginx checks and reloads" "-HUP|4242" "$(calls kill)"
check_contains "the relayed devices are logged" \
  "Relays the remote debug port 7405 of the device emulator-5554 of the node lab-1 to 192.168.30.2:7405." "$output"
check_contains "the number of the relayed devices" "Android devices of the nodes relayed: 2." "$output"
reset_calls
output="$(sync_devices)"
check "no reload without a change" "" "$(calls kill)"
check "no log without a change" "" "$output"
echo "$COMPACT" > "${WORK}/answer.json"
reset_calls
output="$(sync_devices)"
check "a change reloads nginx" "-HUP|4242" "$(calls kill)"
check_contains "a change is logged" "Relays the remote debug port 7420 of the device a" "$output"
check_contains "a skipped device is logged" \
  "Skips the remote debug port (none) of the device b of the node lab-3 (192.168.30.3): no remote debug port in STF." "$output"
check_not_contains "the old device is gone" "7461" "$(cat "$AUTO_CONF")"
cp "$AUTO_CONF" "${WORK}/auto.saved"
reset_calls
output="$(CURL_FAIL=1 sync_devices)"
check_contains "a failure of the STF API is logged" "The STF API https://127.0.0.1:8082 failed, the relay keeps its devices: curl: (22)" "$output"
check "a failure of the STF API keeps the servers" "same:" \
  "$(cmp -s "$AUTO_CONF" "${WORK}/auto.saved" && echo same):$(calls kill)"
echo '{"success":false,"description":"Bad Credentials"}' > "${WORK}/answer.json"
output="$(sync_devices)"
check_contains "an answer without devices is logged" "answered without devices, the relay keeps its devices: {\"success\":false" "$output"
check "an answer without devices keeps the servers" "same" "$(cmp -s "$AUTO_CONF" "${WORK}/auto.saved" && echo same)"
echo '{"success":true,"devices":[]}' > "${WORK}/answer.json"
reset_calls
output="$(NGINX_FAIL=1 sync_devices)"
check_contains "a configuration nginx refuses is logged" "nginx refuses the servers of the devices" "$output"
check "a configuration nginx refuses is not kept" "same:" \
  "$(cmp -s "$AUTO_CONF" "${WORK}/auto.saved" && echo same):$(calls kill)"
reset_calls
output="$(sync_devices)"
check "no device: no server" "" "$(cat "$AUTO_CONF")"
check_contains "no device is logged" "Android devices of the nodes relayed: 0." "$output"
: > "$TOKEN_FILE"
reset_calls
output="$(sync_devices)"
check_contains "an empty token is logged" "The access token of STF (STF_TOKEN of variables.env) is empty: no device is relayed" "$output"
check "no request without STF_TOKEN" "" "$(calls curl)"
last_error="The access token of STF (STF_TOKEN of variables.env) is empty: no device is relayed, set it and run ./zebrunner.sh start (README.md#remote-debug-through-the-adb-relay)."
check "an error is logged once" "" "$(sync_devices)"
printf 'token1\n' > "$TOKEN_FILE"
check_contains "the end of an error is logged" "The STF API https://127.0.0.1:8082 answers with the devices again." "$(sync_devices)"
unset -f kill

finish
