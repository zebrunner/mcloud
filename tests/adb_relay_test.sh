#!/bin/bash
# Tests of configuration/adb-relay/adb-relay.sh, the entrypoint of adb-relay: the devices of answers of the STF API (an
# STF with and without screenPort and connectPort), what the relay does with them, its servers of nginx and the sync;
# curl and nginx are stubs (the container itself is checked by tests/adb_relay_docker_test.sh).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
# shellcheck source=../configuration/adb-relay/adb-relay.sh
source configuration/adb-relay/adb-relay.sh

# the answer of an STF without screenPort and connectPort (the port of the screen is in display.url), pretty-printed
OLD_STF='{
  "success": true,
  "description": "Devices Information",
  "devices": [
    {
      "serial": "emulator-5554",
      "present": true,
      "platform": "Android",
      "display": {
        "url": "wss://mcloud.example.com:443/d/192.168.30.2/emulator-5554/7404/"
      }
    },
    {
      "serial": "R58M\"x",
      "present": false,
      "platform": "Android",
      "display": {"url": "ws:\/\/mcloud.example.com:80\/d\/agent1.lan\/R58M\/7460\/"}
    }
  ]
}'
# the answer of an STF with screenPort and connectPort, on one line, a device without display
NEW_STF="$(printf '%s' '{"success":true,"description":"Devices Information","devices":[{"serial":"a","present":true,' \
  '"platform":"Android","display":{"url":"ws://m/d/192.168.30.2/a/7404/"},"screenPort":7404,"connectPort":7420},' \
  '{"serial":"b","present":true,"platform":"Android","display":null,"screenPort":7500,"connectPort":7501},' \
  '{"serial":"ipad","present":true,"platform":"iOS","display":{"url":"ws://m/d/192.168.30.2/ipad/7600/"},' \
  '"screenPort":7600,"connectPort":7601}]}')"

# device <serial> <platform> <display url> [<screenPort> <connectPort>]: a line of devices_of_json
device() {
  echo "$1|$2|$3|${4:-}|${5:-}"
}

section "devices of the STF API"
check "an STF without the ports: the device lines, the escapes of JSON" \
  "emulator-5554|Android|wss://mcloud.example.com:443/d/192.168.30.2/emulator-5554/7404/||
R58M_x|Android|ws://mcloud.example.com:80/d/agent1.lan/R58M/7460/||" "$(devices_of_json <<< "$OLD_STF")"
check "an STF with the ports" "a|Android|ws://m/d/192.168.30.2/a/7404/|7404|7420
b|Android||7500|7501
ipad|iOS|ws://m/d/192.168.30.2/ipad/7600/|7600|7601" "$(devices_of_json <<< "$NEW_STF")"
check "no device" "0:" "$(
  devices="$(devices_of_json <<< '{"success":true,"devices":[]}')"
  echo "$?:${devices}"
)"
check "an answer without devices fails" "1:" "$(
  devices="$(devices_of_json <<< '{"success":false,"description":"Bad Credentials"}')"
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
  "$(devices_of_json <<< '{"other":{"devices":[{"serial":"x","present":true}]},"devices":[]}')"

section "what the relay does"
hosts="192.168.30.2, agent1.lan,192.168.30.3"
check "an STF without connectPort: the screen port + 1" "relay|7405|192.168.30.2|emulator-5554
relay|7461|agent1.lan|R58M_x" "$(devices_of_json <<< "$OLD_STF" | relay_devices "$hosts" "" "" "")"
check "an STF with connectPort: connectPort, never the screen port" "relay|7420|192.168.30.2|a
skip|7501||b|no device host in its display URL" \
  "$(devices_of_json <<< "$NEW_STF" | relay_devices "$hosts" "" "" "")"
check "iOS devices are not relayed and not reported" "" \
  "$(device ipad iOS ws://m/d/192.168.30.2/ipad/7600/ 7600 7601 | relay_devices "$hosts" "" "" "")"
check "an absent device is relayed too (R58M of the answer): its device host refuses the port" "relay|7461|agent1.lan|R58M_x" \
  "$(devices_of_json <<< "$OLD_STF" | relay_devices "$hosts" "" "" "" | grep R58M)"
check "a device host out of AGENT_HOSTS is skipped" \
  "skip|7501|192.168.30.9|x|its device host 192.168.30.9 is not in AGENT_HOSTS" \
  "$(device x Android ws://m/d/192.168.30.9/x/7500/ | relay_devices "$hosts" "" "" "")"
check "AGENT_HOSTS match whole names only" \
  "skip|7501|192.168.30.20|x|its device host 192.168.30.20 is not in AGENT_HOSTS" \
  "$(device x Android ws://m/d/192.168.30.20/x/7500/ | relay_devices "$hosts" "" "" "")"
check "no device host without AGENT_HOSTS" "skip|7501|192.168.30.2|x|its device host 192.168.30.2 is not in AGENT_HOSTS" \
  "$(device x Android ws://m/d/192.168.30.2/x/7500/ | relay_devices "" "" "" "")"
check "the ports of ADB_RELAY_PORTS only" "relay|7400|192.168.30.2|first
relay|7499|192.168.30.2|last
skip|7500|192.168.30.2|out|the port is not in ADB_RELAY_PORTS 7400-7499
skip|7399|192.168.30.2|below|the port is not in ADB_RELAY_PORTS 7400-7499" "$(
  {
    device first Android ws://m/d/192.168.30.2/first/7399/
    device last Android ws://m/d/192.168.30.2/last/7498/
    device out Android ws://m/d/192.168.30.2/out/7499/
    device below Android ws://m/d/192.168.30.2/below/7400/ 7400 7399
  } | relay_devices "$hosts" 7400 7499 ""
)"
check "the ports of MCloud and of ADB_RELAY_HOSTS are skipped" \
  "skip|8082|192.168.30.2|stf|the port is one of MCloud or of ADB_RELAY_HOSTS
skip|7404|192.168.30.2|single|the port is one of MCloud or of ADB_RELAY_HOSTS
skip|7465|192.168.30.3|range|the port is one of MCloud or of ADB_RELAY_HOSTS
relay|7471|192.168.30.3|free" "$(
    {
      device stf Android ws://m/d/192.168.30.2/stf/8081/
      device single Android ws://m/d/192.168.30.2/single/7403/
      device range Android ws://m/d/192.168.30.3/range/7464/
      device free Android ws://m/d/192.168.30.3/free/7470/
    } | relay_devices "$hosts" "" "" "8082 4446 7404 7460-7469"
  )"
conflict="the port is the one of the devices a, c of STF, none of them is relayed: remove the gone one in STF (Settings,\
 Devices) or change connect_port of mcloud-agent"
check "a port of two devices is skipped for both" "skip|7405|192.168.30.2|a|${conflict}
relay|7411|192.168.30.2|b
skip|7405|192.168.30.3|c|${conflict}" "$(
  {
    device a Android ws://m/d/192.168.30.2/a/7404/
    device b Android ws://m/d/192.168.30.2/b/7410/
    device c Android ws://m/d/192.168.30.3/c/7400/ 7400 7405
  } | relay_devices "$hosts" "" "" ""
)"
check_contains "a stale registration with the port of a new device is a conflict too" \
  "skip|7405|192.168.30.3|stale|the port is the one of the devices new, stale of STF" "$(
    {
      device new Android ws://m/d/192.168.30.2/new/7404/
      device stale Android ws://m/d/192.168.30.3/stale/7404/
    } | relay_devices "$hosts" "" "" ""
  )"
check "a port below 1024 is skipped" "skip|81|192.168.30.2|low|the port is not 1024-65535" \
  "$(device low Android ws://m/d/192.168.30.2/low/80/ | relay_devices "$hosts" "" "" "")"

section "servers of nginx"
# shellcheck disable=SC2016 # $server_port of nginx
check "a server per device, the resolvers for a host name" '# emulator-5554
server {
  listen 7405 so_keepalive=on;
  proxy_pass 192.168.30.2:$server_port;
}
# R58M_x
server {
  listen 7461 so_keepalive=on;
  resolver 10.0.0.53 [fd00::53] valid=30s ipv6=off;
  proxy_pass agent1.lan:$server_port;
}' "$(devices_of_json <<< "$OLD_STF" | relay_devices "$hosts" "" "" "" | servers_of "10.0.0.53 [fd00::53]")"
check "no server of a skipped device" "" \
  "$(device x Android ws://m/d/192.168.30.9/x/7500/ | relay_devices "$hosts" "" "" "" | servers_of "")"

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
AGENT_HOSTS="192.168.30.2,agent1.lan"
relay_first=""
relay_last=""
reserved_ports="8082"
resolvers="10.0.0.53"
stf_api="https://127.0.0.1:8082"
nginx_pid=4242
last_error=""
last_report="none"
printf 'token1\n' > "$TOKEN_FILE"
echo "$OLD_STF" > "${WORK}/answer.json"
# curl prints ${WORK}/answer.json, fails with CURL_FAIL; nginx -t fails with NGINX_FAIL; kill (of the reload) records
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs
stub curl '(IFS="|"; echo "curl|$*") >> "'"${WORK}"'/calls.log"
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
check "the STF API through stf-proxy with STF_TOKEN" \
  "-fsS|-k|--max-time|20|-H|Authorization: Bearer token1|https://127.0.0.1:8082/api/v1/devices?fields=serial,platform,display.url,screenPort,connectPort" \
  "$(calls curl | head -1)"
check_contains "the servers of the devices" "listen 7461 so_keepalive=on;" "$(cat "$AUTO_CONF")"
check "nginx checks and reloads" "-HUP|4242" "$(calls kill)"
check_contains "the relayed devices are logged" "Relays the remote debug port 7405 of the device emulator-5554 to 192.168.30.2:7405." "$output"
check_contains "the number of the relayed devices" "Android devices of STF relayed: 2." "$output"
reset_calls
output="$(sync_devices)"
check "no reload without a change" "" "$(calls kill)"
check "no log without a change" "" "$output"
echo "$NEW_STF" > "${WORK}/answer.json"
reset_calls
output="$(sync_devices)"
check "a change reloads nginx" "-HUP|4242" "$(calls kill)"
check_contains "a change is logged" "Relays the remote debug port 7420 of the device a" "$output"
check_contains "a skipped device is logged" "Skips the remote debug port 7501 of the device b" "$output"
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
check_contains "no device is logged" "Android devices of STF relayed: 0." "$output"
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
