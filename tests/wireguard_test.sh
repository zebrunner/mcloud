#!/bin/bash
# Tests of the WireGuard tunnel of the nodes without docker: the addresses of configuration/wireguard/network.sh, the
# keys of patch/wireguard.sh and the sync of the peers of configuration/wireguard/wireguard.sh (the nodes of answers of
# the STF API, the peers they make and the changes of the interface) and its relay of the ports of the nodes; wg, curl,
# socat, ss and ip are stubs (the service itself is checked by tests/wireguard_docker_test.sh).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
# shellcheck source=../configuration/wireguard/wireguard.sh
source configuration/wireguard/wireguard.sh
# shellcheck source=../patch/wireguard.sh
source patch/wireguard.sh
BASEDIR="$REPO"

# RFC 7748, 6.1: the private key of Alice and its public key, base64 as WireGuard writes them
PRIVATE="dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo="
PUBLIC="hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo="
# keys of nodes
KEY_A="$(printf 'A%.0s' {1..42})A="
KEY_B="$(printf 'B%.0s' {1..42})E="
KEY_C="$(printf 'C%.0s' {1..42})I="
KEY_D="$(printf 'D%.0s' {1..42})M="

section "the network of the tunnel"
check "the default network" "$(wg_ip_int 10.234.0.0) $(wg_ip_int 10.234.0.255) 24" "$(wg_network 10.234.0.0/24)"
check "the server is the first host" "10.234.0.1" "$(wg_server_address 10.234.0.0/24)"
check "the server of a /16" "172.30.0.1" "$(wg_server_address 172.30.0.0/16)"
check "an address of 100.64/10" "100.64.8.1" "$(wg_server_address 100.64.8.0/30)"
check "a network next to the networks of the devices" "10.232.0.1" "$(wg_server_address 10.232.0.0/16)"
check "a number and its address" "192.168.1.200" "$(wg_int_ip "$(wg_ip_int 192.168.1.200)")"
for network in 10.234.0.1/24 10.234.0.0 10.234.0.0/15 10.234.0.0/31 10.234.0.0/x 8.8.8.0/24 10.233.0.0/24 10.233.5.0/24 \
  10.232.0.0/14 10.234.0.256/24 "" "10.234.0.0/24 x"; do
  check "'${network}' is no network of the tunnel" "1:" "$(
    result="$(wg_network "$network")"
    echo "$?:${result}"
  )"
done
for address in 10.234.0.2 10.234.0.254; do
  check "${address} is an address of a node" "0" "$(
    wg_node_address 10.234.0.0/24 "$address"
    echo "$?"
  )"
done
for address in 10.234.0.0 10.234.0.1 10.234.0.255 10.234.1.2 node.lan "" 10.234.0.300; do
  check "'${address}' is not an address of a node" "1" "$(
    wg_node_address 10.234.0.0/24 "$address"
    echo "$?"
  )"
done
for key in "$PRIVATE" "$PUBLIC" "$KEY_A"; do
  check "${key} is a key" "yes" "$([[ "$key" =~ $WG_KEY_REGEX ]] && echo yes)"
done
for key in "${PRIVATE%=}" "${PRIVATE}=" "${PRIVATE/=/B}" "$(printf 'A%.0s' {1..42})B=" "a b"; do
  check "'${key}' is not a key" "no" "$([[ "$key" =~ $WG_KEY_REGEX ]] || echo no)"
done

section "the keys of the server"
check "base64 and hex" "$PRIVATE" "$(base64_hex <<< "$PRIVATE" | hex_base64)"
check "the public key of a private key: X25519 of RFC 7748" "$PUBLIC" "$(wg_public_key <<< "$PRIVATE")"
stub openssl 'exit 1'
check "the public key without openssl: patch/curve_keygen.py" "$PUBLIC" "$(PATH="${WORK}/bin:${PATH}" wg_public_key <<< "$PRIVATE")"
rm -f "${WORK}/bin/openssl"
check "no public key of a value that is not a key" "1:" "$(
  result="$(wg_public_key <<< "secret")"
  echo "$?:${result}"
)"
# the secret of curve_pair of zebrunner.sh: patch/curve_keygen.py
# shellcheck disable=SC2329 # called by wg_new_key
curve_pair() {
  python3 "${REPO}/patch/curve_keygen.py"
}
key="$(wg_new_key)"
check "a new key is a WireGuard key" "yes" "$([[ "$key" =~ $WG_KEY_REGEX ]] && echo yes)"
hex="$(base64_hex <<< "$key")"
check "a new key is clamped as wg genkey makes it" "0:64" "$((0x${hex:0:2} & 7)):$((0x${hex:62:2} & 192))"
check "the public key of a new key" "public=$(base64_hex <<< "$(wg_public_key <<< "$key")")" \
  "$(printf '%s\n' "$hex" | python3 patch/curve_keygen.py - | head -1)"
check "two new keys differ" "yes" "$([[ "$(wg_new_key)" != "$key" ]] && echo yes)"

section "the nodes of the STF API"
PRETTY='{
  "success": true,
  "nodes": [
    {
      "label": "lab-1",
      "address": "10.234.0.2",
      "status": "active",
      "publicKey": "abc",
      "wgPublicKey": "'"$KEY_A"'",
      "wireguard": true,
      "lastSeenAt": null
    },
    {"label": "lab\"2", "address": "10.234.0.3", "status": "revoked", "wgPublicKey": "'"$KEY_B"'"},
    {"label": "old", "address": "192.168.1.5", "status": "active", "wgPublicKey": null, "wireguard": false}
  ]
}'
check "a pretty-printed answer: a line per node" "lab-1|active|10.234.0.2|${KEY_A}
lab_2|revoked|10.234.0.3|${KEY_B}
old|active|192.168.1.5|" "$(nodes_of_json <<< "$PRETTY")"
check "no node" "0:" "$(
  nodes="$(nodes_of_json <<< '{"success":true,"nodes":[]}')"
  echo "$?:${nodes}"
)"
for answer in '{"success":false}' '<html>502 Bad Gateway</html>' '{"nodes":[{"label":"a'; do
  check "the answer '${answer}' has no nodes" "1" "$(
    nodes_of_json <<< "$answer" > /dev/null
    echo "$?"
  )"
done
check "a separator in a value is no field" "a_b|active|10.234.0.2_x|" \
  "$(nodes_of_json <<< '{"nodes":[{"label":"a|b","status":"active","address":"10.234.0.2|x"}]}')"

section "the peers"
check "the active nodes with a key and an address of the network" "skip|old|enrolled without a WireGuard key: invite it again (./zebrunner.sh node-invite old) and join with an mcloud-agent that has the tunnel
peer|${KEY_A}|10.234.0.2|lab-1" \
  "$(nodes_of_json <<< "$PRETTY" | wanted_peers 10.234.0.0/24)"
check "an address out of the network is no peer" \
  "skip|n|its address 10.0.0.5 is not an address of a node in NODES_WG_NETWORK 10.234.0.0/24" \
  "$(echo "n|active|10.0.0.5|${KEY_A}" | wanted_peers 10.234.0.0/24)"
check "the address of the server is no peer" \
  "skip|n|its address 10.234.0.1 is not an address of a node in NODES_WG_NETWORK 10.234.0.0/24" \
  "$(echo "n|active|10.234.0.1|${KEY_A}" | wanted_peers 10.234.0.0/24)"
check "a value that is not a key is no peer" "skip|n|its WireGuard key is not a key" \
  "$(echo "n|active|10.234.0.2|secret" | wanted_peers 10.234.0.0/24)"
check "a key or an address of two nodes is the peer of none of them" "skip|a|its WireGuard key is the one of another node
skip|b|its WireGuard key is the one of another node
skip|c|its address 10.234.0.9 is the one of another node
skip|d|its address 10.234.0.9 is the one of another node
peer|${KEY_C}|10.234.0.10|e" "$(printf '%s\n' "a|active|10.234.0.5|${KEY_A}" "b|active|10.234.0.6|${KEY_A}" \
  "c|active|10.234.0.9|${KEY_B}" "d|active|10.234.0.9|${KEY_D}" "e|active|10.234.0.10|${KEY_C}" | wanted_peers 10.234.0.0/24)"
check "no node, no peer" "" "$(printf '' | wanted_peers 10.234.0.0/24)"

section "the changes of the interface"
wanted="peer|${KEY_A}|10.234.0.2|lab-1
peer|${KEY_B}|10.234.0.3|lab-2"
check "new peers are added" "add|${KEY_A}|10.234.0.2|lab-1
add|${KEY_B}|10.234.0.3|lab-2" "$(peer_changes "$wanted" "")"
check "the peers of the nodes stay" "" "$(peer_changes "$wanted" "${KEY_A}|10.234.0.2
${KEY_B}|10.234.0.3")"
check "a peer of no node is removed (a revoked one), a moved one gets its new address" "add|${KEY_B}|10.234.0.3|lab-2
remove|${KEY_C}|10.234.0.4" "$(peer_changes "$wanted" "${KEY_A}|10.234.0.2
${KEY_B}|10.234.0.7
${KEY_C}|10.234.0.4")"
check "without nodes every peer is removed" "remove|${KEY_A}|10.234.0.2
remove|${KEY_C}|" "$(peer_changes "skip|old|no key" "${KEY_A}|10.234.0.2
${KEY_C}|")"
# wg: the peers of ${WORK}/peers (wg show), the calls in calls.log
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs
stub wg '(IFS="|"; echo "wg|$*") >> "'"${WORK}"'/calls.log"
[[ "$1" == show ]] && cat "'"${WORK}"'/peers" 2> /dev/null
exit 0'
PATH="${WORK}/bin:${PATH}"
printf '%s\t%s\n' "$KEY_A" 10.234.0.2/32 "$KEY_C" "(none)" > "${WORK}/peers"
check "the peers of the interface" "${KEY_A}|10.234.0.2
${KEY_C}|" "$(current_peers)"
reset_calls
output="$(apply_changes "add|${KEY_B}|10.234.0.3|lab-2
remove|${KEY_C}|")"
check "the changes are made with wg set" "set|mcloud|peer|${KEY_B}|allowed-ips|10.234.0.3/32
set|mcloud|peer|${KEY_C}|remove" "$(calls wg)"
check_contains "an added peer is logged with its node" "[INFO] The node lab-2 at 10.234.0.3 is a peer (key BBBBBBBB...)." "$output"
check_contains "a removed peer is logged" "[INFO] The peer CCCCCCCC... at (none) is removed" "$output"

section "the sync"
# curl: the answer of ${WORK}/answer, fails with ${WORK}/curl-fails; the configuration of stdin goes to curl.stdin
# shellcheck disable=SC2016
stub curl '(IFS="|"; echo "curl|$*") >> "'"${WORK}"'/calls.log"
cat > "'"${WORK}"'/curl.stdin"
[[ -f "'"${WORK}"'/curl-fails" ]] && echo "curl: (22) The requested URL returned error: 401" && exit 22
cat "'"${WORK}"'/answer"'
TOKEN_FILE="${WORK}/stf-token"
echo test-token > "$TOKEN_FILE"
NODES_WG_NETWORK=10.234.0.0/24
stf_api="https://127.0.0.1:8443"
last_error=""
last_skipped=""
printf '%s' "$PRETTY" > "${WORK}/answer"
: > "${WORK}/peers"
reset_calls
output="$(sync_peers)"
check "the nodes are read from stf-proxy on the loopback address" "-fsS|-k|--max-time|20|-K|-|https://127.0.0.1:8443/api/v1/nodes" \
  "$(calls curl)"
check "STF_TOKEN goes in the configuration of curl on its stdin" 'header = "Authorization: Bearer test-token"' \
  "$(cat "${WORK}/curl.stdin")"
check_not_contains "STF_TOKEN is not an argument of curl" "test-token" "$(calls curl)"
check "the active node with a key is added" "show|mcloud|allowed-ips
set|mcloud|peer|${KEY_A}|allowed-ips|10.234.0.2/32" "$(calls wg)"
check_contains "the peers are counted" "Peers of the tunnel: 1." "$output"
check_contains "an active node without a key is logged" "[WARN] The node old is no peer: enrolled without a WireGuard key" "$output"
printf '%s\t%s\n' "$KEY_A" 10.234.0.2/32 "$KEY_B" 10.234.0.3/32 > "${WORK}/peers"
reset_calls
output="$(sync_peers)"
check "a peer of a revoked node is removed at once" "show|mcloud|allowed-ips
set|mcloud|peer|${KEY_B}|remove" "$(calls wg)"
touch "${WORK}/curl-fails"
reset_calls
output="$(sync_peers)"
rm -f "${WORK}/curl-fails"
check "a failed read keeps the peers" "" "$(calls wg)"
check_contains "a failed read is logged" "The STF API https://127.0.0.1:8443 failed, the tunnel keeps its peers" "$output"
echo '<html>502</html>' > "${WORK}/answer"
reset_calls
output="$(sync_peers)"
check "an answer without nodes keeps the peers" "" "$(calls wg)"
check_contains "an answer without nodes is logged" "answered without nodes, the tunnel keeps its peers" "$output"
: > "$TOKEN_FILE"
reset_calls
output="$(sync_peers)"
check "no request without STF_TOKEN" "" "$(calls curl)$(calls wg)"
check_contains "an empty STF_TOKEN is logged" "STF_TOKEN of variables.env) is empty" "$output"

section "the relay of the ports of the nodes"
# poll <command...>: runs the command every 0.1 seconds until it succeeds, fails after 5 seconds
poll() {
  local _
  for _ in $(seq 50); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}
# relay_stopped <index>: the relay of the index of relay_pids does not run
# shellcheck disable=SC2329 # called through poll
relay_stopped() {
  ! kill -0 "${relay_pids[$1]}" 2> /dev/null
}
# socat_calls <count>: socat was called so often
# shellcheck disable=SC2329 # called through poll
socat_calls() {
  [[ "$(calls socat | grep -c .)" -eq "$1" ]]
}
check "the ports of stf-proxy and stf-triproxy-dev" "4446 7250 7270" "$RELAY_PORTS"
output="$(printf '%s\n' "2026/11/27 10:00:00 socat[10] E connect(5, AF=2 127.0.0.1:7250, 16): Connection refused" \
  "2026/11/27 10:00:00 socat[11] W exiting on signal 15" \
  "2026/11/27 10:00:01 socat[12] E connect(5, AF=2 127.0.0.1:7250, 16): Connection refused" \
  "2026/11/27 10:00:01 socat[13] N accepting connection" | relay_log 7250)"
check "a message of socat is logged once a minute, with its level" "[ERROR] The relay of the port 7250: connect(5, AF=2 127.0.0.1:7250, 16): Connection refused
[WARN] The relay of the port 7250: exiting on signal 15
[INFO] The relay of the port 7250: accepting connection" "$(sed 's/^\[[^]]*\] //' <<< "$output")"
# socat: the arguments in calls.log; it listens until ${WORK}/socat-stop-<port> exists, then it ends as with a taken port
# shellcheck disable=SC2016
stub socat '(IFS="|"; echo "socat|$*") >> "'"${WORK}"'/calls.log"
port="${1#TCP4-LISTEN:}"
port="${port%%,*}"
until [[ -f "'"${WORK}"'/socat-stop-${port}" ]]; do sleep 0.1; done
echo "2026/11/27 10:00:00 socat[20] E bind(5, {AF=2 10.234.0.1:${port}}, 16): Address in use" >&2
exit 1'
reset_calls
relay_pids=()
relay_started=()
RELAY_RETRY_SECONDS=30
# the relays run in the background, their log goes to relay.log
relays_check 10.234.0.1 >> "${WORK}/relay.log"
poll socat_calls 3
socket="keepalive,keepidle=60,keepintvl=20,keepcnt=3,nodelay"
check "a relay per port: the WireGuard address only, to the loopback address, keepalive and no idle timeout" \
  "TCP4-LISTEN:4446,bind=10.234.0.1,reuseaddr,fork,backlog=128,max-children=1024,${socket}|TCP4:127.0.0.1:4446,${socket}
TCP4-LISTEN:7250,bind=10.234.0.1,reuseaddr,fork,backlog=128,max-children=1024,${socket}|TCP4:127.0.0.1:7250,${socket}
TCP4-LISTEN:7270,bind=10.234.0.1,reuseaddr,fork,backlog=128,max-children=1024,${socket}|TCP4:127.0.0.1:7270,${socket}" \
  "$(calls socat | sort)"
reset_calls
relays_check 10.234.0.1 >> "${WORK}/relay.log"
check "a running relay is not started again" "" "$(calls socat)"
touch "${WORK}/socat-stop-4446"
run_check "the relay of 4446 stops" poll relay_stopped 0
relays_check 10.234.0.1 >> "${WORK}/relay.log"
check "a stopped relay is not started again before RELAY_RETRY_SECONDS" "" "$(calls socat)"
RELAY_RETRY_SECONDS=0
relays_check 10.234.0.1 >> "${WORK}/relay.log"
poll socat_calls 1
check "a stopped relay is started again after RELAY_RETRY_SECONDS" "TCP4-LISTEN:4446" "$(calls socat | cut -d , -f 1)"
poll relay_stopped 0
check_contains "the stop is logged" "[WARN] The relay of the port 4446 on 10.234.0.1 stopped (its messages are above), it is started again." \
  "$(cat "${WORK}/relay.log")"
check_contains "the message of socat is logged" "[ERROR] The relay of the port 4446: bind(5, {AF=2 10.234.0.1:4446}, 16): Address in use" \
  "$(cat "${WORK}/relay.log")"
touch "${WORK}/socat-stop-7250" "${WORK}/socat-stop-7270"
wait
# ss: the listening sockets of ${WORK}/listening for the address and port of `src <address>:<port>`
# shellcheck disable=SC2016
stub ss 'grep -F " $3 " "'"${WORK}"'/listening" 2> /dev/null; exit 0'
printf 'LISTEN 0 128 %s 0.0.0.0:*\n' 127.0.0.1:4446 10.234.0.1:4446 10.234.0.1:7250 10.234.0.1:7270 > "${WORK}/listening"
check "the relay listens on every port" "0" "$(
  relays_listen 10.234.0.1
  echo "$?"
)"
printf 'LISTEN 0 128 %s 0.0.0.0:*\n' 127.0.0.1:4446 10.234.0.1:7250 10.234.0.1:7270 > "${WORK}/listening"
check "a port published on the loopback address is no relay" "1" "$(
  relays_listen 10.234.0.1
  echo "$?"
)"
# ip: the interface of ${WORK}/interface
# shellcheck disable=SC2016
stub ip 'cat "'"${WORK}"'/interface" 2> /dev/null; exit 0'
echo "5: mcloud    inet 10.234.0.1/24 scope global mcloud" > "${WORK}/interface"
check "not healthy without the relay of a port" "1" "$(
  healthy
  echo "$?"
)"
printf 'LISTEN 0 128 %s 0.0.0.0:*\n' 10.234.0.1:4446 10.234.0.1:7250 10.234.0.1:7270 > "${WORK}/listening"
check "healthy: the interface with the address of the server and the relay" "0" "$(
  healthy
  echo "$?"
)"
rm -f "${WORK}/interface"
check "not healthy without the interface" "1" "$(
  healthy
  echo "$?"
)"

finish
