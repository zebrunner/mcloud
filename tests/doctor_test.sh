#!/bin/bash
# Tests of ./zebrunner.sh doctor (patch/doctor.sh) on a copy of the repository: docker, curl, df and ip are stubs, the
# certificates and the CURVE keys are real ones (openssl, patch/curve_keygen.py). The real services are checked by
# tests/compose_test.sh.
source "$(dirname "$0")/lib.sh"

require_cmd openssl
require_cmd python3

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"

# the stubs read their answers from ${STUB_DIR}: docker-down (no daemon), compose-version, disk (percent),
# no-network, project-dir (the folder of the compose project), services (config --services), ps (compose ps lines),
# restarts (the restart count of every container), handshakes (docker exec: wg show of the service wireguard),
# mdm-logs and mdm-logs-recent (docker logs of mcloud-mdm, with --since); ip:
# ip-wireguard (the interface of the tunnel); curl: user.json and user.status (GET /api/v1/user), nodes.json and
# nodes.status, devices.json, grid.status (the grid on 4446), url.status (STF_URL), closed-ports (one per line: a port
# closed on every address or <address>:<port>)
# shellcheck disable=SC2016 # the stub bodies are expanded when the stubs run
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ -f "${STUB_DIR}/docker-down" ]] && exit 1
case "$1 $2" in
  "version --format") echo 29.1.0 ;;
  "compose version") cat "${STUB_DIR}/compose-version" ;;
  "info --format") echo /var/lib/docker ;;
  "network inspect") [[ -f "${STUB_DIR}/no-network" ]] && exit 1 ;;
  "ps -a") cat "${STUB_DIR}/project-dir" 2> /dev/null ;;
  "inspect --format")
    if [[ "$3" == *Running* ]]; then echo true; else cat "${STUB_DIR}/restarts" 2> /dev/null || echo 0; fi ;;
esac
if [[ "$1" == compose ]]; then
  [[ "$*" == *" config --services"* ]] && cat "${STUB_DIR}/services"
  [[ "$*" == *" ps -a "* ]] && cat "${STUB_DIR}/ps"
fi
[[ "$1 $2" == "exec wireguard" ]] && cat "${STUB_DIR}/handshakes" 2> /dev/null
if [[ "$1" == logs ]]; then
  if [[ "$2" == --since ]]; then cat "${STUB_DIR}/mdm-logs-recent" 2> /dev/null; else cat "${STUB_DIR}/mdm-logs" 2> /dev/null; fi
fi
exit 0'
# shellcheck disable=SC2016
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 100 50 50 $(cat "${STUB_DIR}/disk")% /"'
# shellcheck disable=SC2016
stub ip 'echo "1: lo    inet 127.0.0.1/8 scope host lo"
echo "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0"
cat "${STUB_DIR}/ip-wireguard" 2> /dev/null'
# shellcheck disable=SC2016
stub curl 'url="${*: -1}"
cat > /dev/null
case "$url" in
  */api/v1/user) cat "${STUB_DIR}/user.json" 2> /dev/null; printf "\n%s" "$(cat "${STUB_DIR}/user.status")" ;;
  */api/v1/nodes) cat "${STUB_DIR}/nodes.json" 2> /dev/null; printf "\n%s" "$(cat "${STUB_DIR}/nodes.status")" ;;
  */api/v1/devices*) cat "${STUB_DIR}/devices.json" 2> /dev/null; printf "\n200" ;;
  *:4446/grid/api/proxy*) cat "${STUB_DIR}/grid.status" ;;
  telnet://*)
    port="${url##*:}"
    if grep -qx -e "$port" -e "${url#telnet://}" "${STUB_DIR}/closed-ports" 2> /dev/null; then echo 0.000000; else echo 0.000120; fi ;;
  *) cat "${STUB_DIR}/url.status" ;;
esac'

# zbr <arguments...>: zebrunner.sh of the copy without the environment of the user; output in $OUT, status in $STATUS
# (the openssl and the python3 of the tests first: the openssl of macOS is LibreSSL)
zbr() {
  env -i HOME="$WORK" PATH="${WORK}/bin:$(dirname "$(command -v openssl)"):$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    TERM=dumb COLUMNS=80 STUB_DIR="$WORK" /bin/bash "${MCLOUD}/zebrunner.sh" "$@" < /dev/null > "${WORK}/output" 2>&1
  STATUS=$?
  OUT="$(unwrap < "${WORK}/output")"
}

# set_value <file> <name> <value>: the line of a variable of a settings file of the copy
set_value() {
  local file="${MCLOUD}/$1"
  grep -v "^$2=" "$file" > "${file}.tmp"
  echo "$2=$3" >> "${file}.tmp"
  mv "${file}.tmp" "$file"
}

SERVICES="rethinkdb stf-migrate stf-app stf-api stf-proxy mcloud-grid"
TOKEN="$(printf 'a%.0s' $(seq 64))"

# healthy: a healthy server: the settings of a setup with https on mcloud.example.com, its certificate, the services
# running, the admin token and one node with a reachable device
healthy() {
  local secret public
  rm -f "${WORK}"/docker-down "${WORK}"/no-network "${WORK}"/project-dir "${WORK}"/restarts "${WORK}"/closed-ports \
    "${WORK}"/mdm-logs "${WORK}"/mdm-logs-recent "${MCLOUD}/configuration/stf-proxy/mdm/server-mdm.conf"
  echo 2.29.7 > "${WORK}/compose-version"
  echo 40 > "${WORK}/disk"
  echo "$SERVICES" | tr ' ' '\n' > "${WORK}/services"
  {
    for service in $SERVICES; do
      if [[ "$service" == stf-migrate ]]; then
        echo "stf-migrate|exited||0|stf-migrate"
      elif [[ "$service" == rethinkdb ]]; then
        echo "rethinkdb|running|healthy|0|rethinkdb"
      else
        echo "${service}|running||0|${service}"
      fi
    done
  } > "${WORK}/ps"
  echo '{"success":true,"user":{"email":"admin@zebrunner.com","name":"admin","privilege":"admin"}}' > "${WORK}/user.json"
  echo 200 > "${WORK}/user.status"
  echo '{"success":true,"nodes":[{"label":"lab-1","address":"10.0.0.7","status":"active","lastSeenAt":"2026-11-24T10:00:00.000Z","createdAt":"2026-11-20T10:00:00.000Z","publicKey":"abcdef0123456789abcdef"}]}' > "${WORK}/nodes.json"
  echo 200 > "${WORK}/nodes.status"
  echo '{"success":true,"devices":[{"serial":"R1","platform":"Android","present":false,"node":"lab-1","screenPort":7400,"connectPort":7401}]}' > "${WORK}/devices.json"
  echo 200 > "${WORK}/grid.status"
  echo 302 > "${WORK}/url.status"
  cp "${REPO}/.env.original" "${MCLOUD}/.env"
  cp "${REPO}/variables.env.original" "${MCLOUD}/variables.env"
  set_value .env STF_URL https://mcloud.example.com
  set_value .env STF_PORT 443
  set_value .env AGENTS_ADDRESS 10.0.0.5
  set_value variables.env STF_URL https://mcloud.example.com
  set_value variables.env SECRET "$(printf 's%.0s' $(seq 32))"
  set_value variables.env STF_STORAGE_TOKEN storage-token
  set_value variables.env RETHINKDB_ENV_AUTHKEY db-password
  set_value variables.env GRID_AUTH_SECRET grid-secret
  set_value variables.env STF_TOKEN "$TOKEN"
  set_value variables.env STF_AUTH_MOCK_BASIC_AUTH_PASSWORD "'sign-in-password'"
  set_value variables.env STF_AUTH_MOCK_ADMIN_BASIC_AUTH_PASSWORD "'admin-password'"
  secret="$(python3 "${REPO}/patch/curve_keygen.py" | sed -n 's/^secret=//p')"
  public="$(printf '%s' "$secret" | python3 "${REPO}/patch/curve_keygen.py" - | sed -n 's/^public=//p')"
  set_value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY "$secret"
  set_value variables.env STF_ZMQ_CURVE_SERVER_PUBLIC_KEY "$public"
  set_value variables.env STF_ZMQ_CURVE_SECRET_KEY "$(python3 "${REPO}/patch/curve_keygen.py" | sed -n 's/^secret=//p')"
  printf 'STF_TOKEN=%s\nGRID_AUTH_SECRET=grid-secret\n' "$TOKEN" > "${MCLOUD}/grid.env"
  chmod 600 "${MCLOUD}/variables.env" "${MCLOUD}/grid.env"
  sed -e 's/listen 80/listen 80 ssl/' -e 's/#    ssl_/    ssl_/' "${MCLOUD}/configuration/stf-proxy/nginx.conf.original" \
    > "${MCLOUD}/configuration/stf-proxy/nginx.conf"
  certificate mcloud.example.com 365
}

# certificate <host> <days>: a self-signed certificate of the host valid for the days, and its key
certificate() {
  openssl req -x509 -newkey rsa:2048 -nodes -days "$2" -subj "/CN=$1" -addext "subjectAltName=DNS:$1" \
    -keyout "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key" -out "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" > /dev/null 2>&1
  chmod 600 "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key"
}

section "a healthy server"
healthy
zbr doctor
check "a healthy server passes" "0" "$STATUS"
check_contains "the summary" "0 fail" "$OUT"
for line in "Docker 29.1.0" "docker compose 2.29.7" "The disk of docker (/var/lib/docker): 40% used" \
  "The docker network infra exists" "STF_URL https://mcloud.example.com" "AGENTS_ADDRESS 10.0.0.5 is an address of this server" \
  "The secrets of variables.env are set" "The files with secrets are readable for their owner only" \
  "The certificate is valid until" "The certificate is self-signed" "The 6 services run" \
  "STF_TOKEN is an access token of the admin admin@zebrunner.com" "The grid answers on 10.0.0.5:4446" \
  "STF_URL https://mcloud.example.com answers from this server (HTTP 302)" \
  "The ports of the nodes listen on 10.0.0.5: 4446, 7250, 7270" \
  "Node lab-1 (10.0.0.7, last seen 2026-11-24T10:00:00): ./zebrunner.sh nodes check lab-1 passes"; do
  check_contains "ok: ${line}" "$line" "$OUT"
done
if openssl x509 -help 2>&1 | grep -q checkhost; then
  check_contains "the certificate is of the host of STF_URL" "The certificate is of mcloud.example.com" "$OUT"
fi
check "doctor changes nothing" "" "$(calls docker | grep -vE '^(version|compose|info|network\|inspect|ps|inspect)\|')"
check_not_contains "nothing of the WireGuard tunnel without it" "WireGuard" "$OUT"

section "the host"
healthy
touch "${WORK}/docker-down"
zbr doctor
check "no docker fails" "1" "$STATUS"
check_contains "no docker is reported" "Docker does not answer" "$OUT"
check_contains "without docker the services are not checked" "The services, the STF API, the ports and the nodes are not checked" "$OUT"
check_contains "without docker the settings are checked" "The secrets of variables.env are set" "$OUT"
healthy
echo 2.20.3 > "${WORK}/compose-version"
zbr doctor
check_contains "an old docker compose fails" "docker compose 2.20.3: docker-compose.yml needs 2.24.0 or newer" "$OUT"
check "an old docker compose: the status" "1" "$STATUS"
healthy
: > "${WORK}/compose-version"
zbr doctor
check_contains "no docker compose fails" "docker compose (the plugin of Docker, v2) is missing" "$OUT"
healthy
echo 90 > "${WORK}/disk"
zbr doctor
check_contains "a disk 90% full is a warning" "The disk of docker (/var/lib/docker) is 90% full." "$OUT"
check "a warning does not fail" "0" "$STATUS"
echo 97 > "${WORK}/disk"
zbr doctor
check_contains "a disk 97% full fails" "is 97% full: the database of STF and the logs stop" "$OUT"
check "a full disk: the status" "1" "$STATUS"
healthy
touch "${WORK}/no-network"
zbr doctor
check_contains "a missing infra network is a warning" "The docker network infra is missing" "$OUT"

section "the settings"
healthy
set_value .env AGENTS_ADDRESS 0.0.0.0
zbr doctor
check_contains "AGENTS_ADDRESS 0.0.0.0 is a warning" "AGENTS_ADDRESS of .env is 0.0.0.0" "$OUT"
check_contains "the ports of the nodes on the loopback address for 0.0.0.0" "The grid answers on 127.0.0.1:4446" "$OUT"
check "AGENTS_ADDRESS 0.0.0.0 does not fail" "0" "$STATUS"
set_value .env AGENTS_ADDRESS 192.0.2.9
zbr doctor
check_contains "an AGENTS_ADDRESS of another host fails" "AGENTS_ADDRESS 192.0.2.9 of .env is not an address of this server" "$OUT"
healthy
set_value .env STF_URL http://mcloud.example.com
set_value variables.env STF_URL http://mcloud.example.com
zbr doctor
check_contains "http of a public host is a warning" "STF_URL http://mcloud.example.com is http" "$OUT"
set_value .env STF_URL mcloud.example.com
zbr doctor
check_contains "an STF_URL without the protocol fails" "STF_URL of .env 'mcloud.example.com' is not" "$OUT"
healthy
set_value variables.env STF_URL https://other.example.com
zbr doctor
check_contains "another STF_URL in variables.env is a warning" "STF_URL of variables.env is not the one of .env" "$OUT"
healthy
set_value variables.env SECRET password
set_value variables.env GRID_AUTH_SECRET ""
set_value variables.env STF_AUTH_MOCK_BASIC_AUTH_PASSWORD "''"
set_value variables.env STF_AUTH_MOCK_ADMIN_BASIC_AUTH_PASSWORD "''"
zbr doctor
check_contains "the default SECRET fails" "SECRET of variables.env is empty or the default one" "$OUT"
check_contains "an empty secret fails" "Empty secrets of variables.env: GRID_AUTH_SECRET." "$OUT"
check_contains "a mock sign-in without a password fails" "The mock sign-in has no password" "$OUT"
check_contains "a mock sign-in without a password of the admins fails" \
  "The mock sign-in has no password of the admins" "$OUT"
check_not_contains "the secrets are not reported as set" "The secrets of variables.env are set" "$OUT"
healthy
zbr doctor
check_contains "the mock sign-in at a public address is a warning" "The mock sign-in is on at a public address" "$OUT"
for url in https://10.0.0.5 http://192.168.1.20:8082 https://172.20.1.1 https://farm.lan https://LOCALHOST:8443; do
  healthy
  set_value .env STF_URL "$url"
  zbr doctor
  check_not_contains "the mock sign-in at ${url} is no warning" "The mock sign-in is on at a public address" "$OUT"
done
healthy
set_value .env AUTH_SYSTEM auth-oauth2
zbr doctor
check_not_contains "another sign-in at a public address is no warning" "The mock sign-in is on at a public address" "$OUT"
healthy
set_value variables.env STF_ZMQ_CURVE_SERVER_PUBLIC_KEY "$(printf 'b%.0s' $(seq 64))"
zbr doctor
check_contains "a public CURVE key of another secret key fails" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of variables.env is not the public key" "$OUT"
set_value variables.env STF_ZMQ_CURVE_SECRET_KEY short
zbr doctor
check_contains "a CURVE key that is not 64 hex characters fails" "are not 64 hex characters: STF_ZMQ_CURVE_SECRET_KEY" "$OUT"
healthy
chmod 644 "${MCLOUD}/variables.env"
zbr doctor
check_contains "a secret file readable by others is a warning" "readable by other users of this server: variables.env (644)" "$OUT"

section "TLS"
healthy
certificate mcloud.example.com 10
zbr doctor
check_contains "a certificate expiring within 30 days is a warning" "within 30 days" "$OUT"
healthy
if openssl x509 -help 2>&1 | grep -q checkhost; then
  certificate other.example.com 365
  zbr doctor
  check_contains "a certificate of another host fails" "The certificate is not of mcloud.example.com" "$OUT"
fi
healthy
mv "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key" "${WORK}/ssl.key"
certificate mcloud.example.com 365
mv "${WORK}/ssl.key" "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key"
zbr doctor
check_contains "a key of another certificate fails" "ssl.key is not the key of" "$OUT"
rm -f "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt"
zbr doctor
check_contains "a missing certificate fails" "its certificate is missing: configuration/stf-proxy/ssl/ssl.crt" "$OUT"
healthy
cp "${MCLOUD}/configuration/stf-proxy/nginx.conf.original" "${MCLOUD}/configuration/stf-proxy/nginx.conf"
set_value .env STF_URL http://localhost:8082
set_value variables.env STF_URL http://localhost:8082
zbr doctor
check_contains "http has no certificate" "stf-proxy serves http: no certificate." "$OUT"
check_not_contains "http of localhost is not a warning" "is http:" "$OUT"

section "the services"
healthy
sed -i.bak -e 's/^stf-api|running||0/stf-api|running|unhealthy|0/' -e 's/^stf-app|running||0/stf-app|running|starting|0/' \
  -e 's/^stf-migrate|exited||0/stf-migrate|exited||1/' -e '/^mcloud-grid|/d' "${WORK}/ps"
sed -i.bak 's/^stf-proxy|running||0|stf-proxy$/stf-proxy|restarting||1|stf-proxy/' "${WORK}/ps"
zbr doctor
check "broken services fail" "1" "$STATUS"
check_contains "an unhealthy service fails" "stf-api is unhealthy." "$OUT"
check_contains "a starting service is a warning" "stf-app is starting." "$OUT"
check_contains "a failed migration fails" "stf-migrate, the migration of the database of STF, failed (exit 1)" "$OUT"
check_contains "a missing service fails" "mcloud-grid is not created." "$OUT"
check_contains "a restarting service fails" "stf-proxy is restarting." "$OUT"
check_not_contains "broken services: not all run" "services run" "$OUT"
healthy
echo "mcloud-mdm-hmdm-init" >> "${WORK}/services"
echo "mcloud-mdm-hmdm-init|exited||0|mcloud-mdm-hmdm-init" >> "${WORK}/ps"
zbr doctor
check_not_contains "the one-shot setup of Headwind MDM done is no failure" "mcloud-mdm-hmdm-init" "$OUT"
check_contains "the one-shot setup of Headwind MDM done counts as running" "The 7 services run" "$OUT"
sed -i.bak 's/^mcloud-mdm-hmdm-init|exited||0/mcloud-mdm-hmdm-init|running||0/' "${WORK}/ps"
zbr doctor
check_not_contains "the one-shot setup of Headwind MDM at work is no failure" "mcloud-mdm-hmdm-init" "$OUT"
sed -i.bak 's/^mcloud-mdm-hmdm-init|running||0/mcloud-mdm-hmdm-init|exited||1/' "${WORK}/ps"
zbr doctor
check_contains "a failed setup of Headwind MDM fails" \
  "mcloud-mdm-hmdm-init, the setup of the admin of Headwind MDM, failed (exit 1)" "$OUT"
healthy
echo 7 > "${WORK}/restarts"
zbr doctor
check_contains "restarts are a warning" "stf-app restarted 7 times." "$OUT"
healthy
echo "${WORK}/other/mcloud" > "${WORK}/project-dir"
mkdir -p "${WORK}/other/mcloud"
zbr doctor
check_contains "the services of another folder fail" "are the MCloud of ${WORK}/other/mcloud, not of this folder" "$OUT"
check_not_contains "the services of another folder: the API is not checked" "STF_TOKEN is an access token" "$OUT"
healthy
set_value .env ADB_RELAY true
set_value .env MDM_ENABLED true
zbr doctor
check_contains "the profiles of ADB_RELAY and MDM_ENABLED" "compose|--profile|adb-relay|--profile|mdm|ps|-a" "$(calls docker)"
check_contains "the MQTT port of the MDM is a port of the nodes" "4446, 7250, 7270, 31443" "$OUT"

section "the STF API and the grid"
healthy
set_value variables.env STF_TOKEN ""
zbr doctor
check_contains "an empty STF_TOKEN fails" "STF_TOKEN of variables.env is empty" "$OUT"
check_contains "an empty STF_TOKEN: the nodes are not checked" "The nodes are not checked: STF_TOKEN is empty." "$OUT"
healthy
echo '{"success":true,"user":{"email":"user@example.com","name":"user","privilege":"user"}}' > "${WORK}/user.json"
zbr doctor
check_contains "a token of a user fails" "STF_TOKEN is an access token of user@example.com, not of an admin" "$OUT"
healthy
echo 401 > "${WORK}/user.status"
: > "${WORK}/user.json"
zbr doctor
check_contains "an unknown token fails with the reason" "The STF API with STF_TOKEN failed: STF_TOKEN of variables.env is not a valid access token of STF" "$OUT"
healthy
printf 'STF_TOKEN=old\n' > "${MCLOUD}/grid.env"
zbr doctor
check_contains "another token of the grid is a warning" "The grid has another STF_TOKEN than variables.env" "$OUT"
healthy
echo 000 > "${WORK}/grid.status"
zbr doctor
check_contains "a grid that does not answer fails" "The grid does not answer on 10.0.0.5:4446 (HTTP 000)" "$OUT"

section "the ports"
healthy
echo 000 > "${WORK}/url.status"
zbr doctor
check_contains "STF_URL that does not answer from the server is a warning" "STF_URL https://mcloud.example.com does not answer from this server" "$OUT"
check "STF_URL from the server does not fail" "0" "$STATUS"
healthy
printf '7250\n7270\n' > "${WORK}/closed-ports"
zbr doctor
check_contains "closed ports of the nodes fail" "Ports of the nodes do not listen on 10.0.0.5: 7250, 7270." "$OUT"

section "the nodes"
healthy
echo '{"success":true,"nodes":[]}' > "${WORK}/nodes.json"
zbr doctor
check_contains "no node is a warning" "No node is enrolled: MCloud has no device." "$OUT"
healthy
echo '{"success":true,"nodes":[{"label":"lab-1","address":"10.0.0.7","status":"active","lastSeenAt":null,"createdAt":"2026-11-20T10:00:00.000Z","publicKey":"abc"},{"label":"old","address":"10.0.0.8","status":"revoked","lastSeenAt":null,"createdAt":"2026-11-01T10:00:00.000Z","publicKey":"def"}]}' > "${WORK}/nodes.json"
zbr doctor
check_contains "a node that fails its check fails" "Node lab-1 (10.0.0.7, last seen -): a check of the node fails." "$OUT"
check_contains "the fix of a node is its check" "./zebrunner.sh nodes check lab-1" "$OUT"
check_contains "a revoked node is a fact" "Node old (10.0.0.8) is revoked." "$OUT"
healthy
echo 404 > "${WORK}/nodes.status"
zbr doctor
check_contains "an STF without the registry of the nodes" "The STF of TAG_STF has no registry of the nodes." "$OUT"

section "the node binding of the MDM"
healthy
zbr doctor
check_not_contains "no MDM: no group MDM" "MDM_ENFORCE_NODE_BINDING" "$OUT"
set_value .env MDM_ENABLED true
zbr doctor
check_contains "the binding off is a fact" "MDM_ENFORCE_NODE_BINDING is off: every node acts on the MDM of every device" "$OUT"
set_value .env MDM_ENFORCE_NODE_BINDING yes
zbr doctor
check_contains "an invalid value fails" "MDM_ENFORCE_NODE_BINDING of .env is 'yes', not true or false" "$OUT"
set_value .env MDM_ENFORCE_NODE_BINDING true
set_value variables.env STF_TOKEN ""
zbr doctor
check_contains "the binding without STF_TOKEN fails" "MDM_ENFORCE_NODE_BINDING=true needs STF_TOKEN of variables.env" "$OUT"
set_value variables.env STF_TOKEN "$TOKEN"
mkdir -p "${MCLOUD}/configuration/stf-proxy/mdm"
echo "proxy_set_header Authorization x;" > "${MCLOUD}/configuration/stf-proxy/mdm/server-mdm.conf"
zbr doctor
check_contains "locations without the header fail" "The locations of stf-proxy do not pass the node of the token" "$OUT"
echo "proxy_set_header X-MCloud-Node \$mdm_node;" > "${MCLOUD}/configuration/stf-proxy/mdm/server-mdm.conf"
printf '%s\n' 'msg="mcloud-mdm started"' 'msg="node call refused: no node"' > "${WORK}/mdm-logs"
zbr doctor
check_contains "an mcloud-mdm without the setting is a warning" "mcloud-mdm did not confirm MDM_ENFORCE_NODE_BINDING at its start" "$OUT"
printf '%s\n' 'msg="MDM_ENFORCE_NODE_BINDING: the nodes act on the MDM of their own devices only"' 'msg="mcloud-mdm started"' \
  > "${WORK}/mdm-logs"
zbr doctor
check_contains "the confirmation of an earlier start does not count" "mcloud-mdm did not confirm" "$OUT"
printf '%s\n' 'msg="mcloud-mdm started"' 'msg="MDM_ENFORCE_NODE_BINDING: the nodes act on the MDM of their own devices only"' \
  > "${WORK}/mdm-logs"
echo 'msg="node call refused: the proxy names no node (X-MCloud-Node)"' > "${WORK}/mdm-logs-recent"
zbr doctor
check_contains "refusals for a missing header fail" "stf-api sends no X-MCloud-Node (a TAG_STF before it)" "$OUT"
rm -f "${WORK}/mdm-logs-recent"
zbr doctor
check_contains "the binding on" "MDM_ENFORCE_NODE_BINDING: the nodes act on the MDM of their own devices only" "$OUT"
check_contains "the logs of mcloud-mdm are read" "logs|--since|1h|mcloud-mdm" "$(calls docker)"
check "doctor with the binding changes nothing" "" \
  "$(calls docker | grep -vE '^(version|compose|info|network\|inspect|ps|inspect|logs)\|')"
reset_calls

section "the WireGuard tunnel"
WG_PRIVATE="dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo="
WG_PUBLIC="hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo="
NODE_KEY="$(printf 'A%.0s' {1..43})="
# wireguard: a healthy server with the tunnel on: the service, its interface, a node with a recent handshake
wireguard() {
  healthy
  set_value .env NODES_WIREGUARD true
  set_value .env NODES_WG_ENDPOINT mcloud.example.com:51820
  set_value .env NODES_WG_PUBLIC_KEY "$WG_PUBLIC"
  set_value variables.env NODES_WG_PRIVATE_KEY "$WG_PRIVATE"
  chmod 600 "${MCLOUD}/variables.env"
  echo "wireguard" >> "${WORK}/services"
  echo "wireguard|running|healthy|0|wireguard" >> "${WORK}/ps"
  echo "5: mcloud    inet 10.234.0.1/24 scope global mcloud" > "${WORK}/ip-wireguard"
  echo "{\"success\":true,\"nodes\":[{\"label\":\"lab-1\",\"address\":\"10.234.0.2\",\"status\":\"active\",\"lastSeenAt\":\"2026-11-24T10:00:00.000Z\",\"createdAt\":\"2026-11-20T10:00:00.000Z\",\"publicKey\":\"abcdef0123456789abcdef\",\"wgPublicKey\":\"${NODE_KEY}\",\"wireguard\":true}]}" > "${WORK}/nodes.json"
  printf '%s\t%s\n' "$NODE_KEY" "$(($(date +%s) - 30))" > "${WORK}/handshakes"
}
wireguard
zbr doctor
check "a healthy server with the tunnel passes" "0" "$STATUS"
for line in "NODES_WG_NETWORK 10.234.0.0/24, the server is 10.234.0.1, its UDP endpoint mcloud.example.com:51820" \
  "The interface mcloud of the server has 10.234.0.1" "The 7 services run" "The grid answers on 10.234.0.1:4446" \
  "The ports of the nodes listen on 10.234.0.1: 4446, 7250, 7270" "The ports of the nodes are published on 127.0.0.1: 4446, 7250, 7270" \
  "The secrets of variables.env are set" \
  "Node lab-1 (10.234.0.2): the latest handshake of the tunnel"; do
  check_contains "ok with the tunnel: ${line}" "   ok   ${line}" "$OUT"
done
check_contains "AGENTS_ADDRESS is not used with the tunnel" "AGENTS_ADDRESS is not used: the ports of the nodes are on the WireGuard address" "$OUT"
check_contains "the firewall: the UDP port of the tunnel" "let the nodes in on the UDP port 51820 (WireGuard) and on STF_PORT" "$OUT"
check_contains "the profile wireguard" "compose|--profile|wireguard|ps|-a" "$(calls docker)"
check_contains "the handshakes are read from the service" "exec|wireguard|wg|show|mcloud|latest-handshakes" "$(calls docker)"
check "doctor with the tunnel changes nothing" "" \
  "$(calls docker | grep -vE '^(version|compose|info|network\|inspect|ps|inspect|exec\|wireguard\|wg\|show)\|')"
check_not_contains "the private key of the tunnel is not shown" "$WG_PRIVATE" "$OUT"
printf '%s\t%s\n' "$NODE_KEY" "$(($(date +%s) - 600))" > "${WORK}/handshakes"
zbr doctor
check_contains "an old handshake is a warning" "Node lab-1 (10.234.0.2): the latest handshake of the tunnel was" "$OUT"
check "an old handshake does not fail" "0" "$STATUS"
printf '%s\t0\n' "$NODE_KEY" > "${WORK}/handshakes"
zbr doctor
check_contains "no handshake is a warning" "Node lab-1 (10.234.0.2): no handshake of the tunnel yet." "$OUT"
: > "${WORK}/handshakes"
zbr doctor
check_contains "a node that is no peer fails" "Node lab-1 (10.234.0.2) is no peer of the tunnel." "$OUT"
check "a node that is no peer: the status" "1" "$STATUS"
wireguard
printf '%s\n' 10.234.0.1:4446 10.234.0.1:7250 10.234.0.1:7270 > "${WORK}/closed-ports"
zbr doctor
check_contains "no relay on the WireGuard address fails" \
  "Ports of the nodes do not listen on 10.234.0.1: 4446, 7250, 7270; the relay of the service wireguard listens there." "$OUT"
check_contains "the fix of no relay: its log" "docker logs wireguard; ./zebrunner.sh start" "$OUT"
check_contains "the published ports are still seen" "   ok   The ports of the nodes are published on 127.0.0.1: 4446, 7250, 7270" "$OUT"
check "no relay: the status" "1" "$STATUS"
echo 127.0.0.1:7250 > "${WORK}/closed-ports"
zbr doctor
check_contains "a port of the nodes not published on the loopback address fails" \
  "Ports of the nodes are not published on 127.0.0.1 (stf-proxy 4446, stf-triproxy-dev 7250 and 7270): 7250." "$OUT"
check_contains "the relay is still seen" "   ok   The ports of the nodes listen on 10.234.0.1: 4446, 7250, 7270" "$OUT"
check "a port not published: the status" "1" "$STATUS"
rm -f "${WORK}/closed-ports"
wireguard
sed -i.bak 's/,"wgPublicKey":"[^"]*"//' "${WORK}/nodes.json"
zbr doctor
check_contains "a node without a WireGuard key is a warning" "Node lab-1 (10.234.0.2) enrolled without a WireGuard key" "$OUT"
check_contains "the fix of a node without a key is a new invite" "./zebrunner.sh node-invite lab-1" "$OUT"
wireguard
rm -f "${WORK}/ip-wireguard"
zbr doctor
check_contains "no interface of the tunnel fails" "10.234.0.1 is not an address of this server: the service wireguard does not run" "$OUT"
wireguard
set_value .env NODES_WG_NETWORK 10.233.0.0/24
zbr doctor
check_contains "an invalid network fails" "NODES_WG_NETWORK of .env '10.233.0.0/24' is not a private network" "$OUT"
wireguard
set_value variables.env NODES_WG_PRIVATE_KEY secret
zbr doctor
check_contains "a private key that is not a key fails" "NODES_WG_PRIVATE_KEY of variables.env is not a WireGuard key" "$OUT"
wireguard
set_value .env NODES_WG_PUBLIC_KEY "$NODE_KEY"
zbr doctor
check_contains "a public key of another private key fails" "NODES_WG_PUBLIC_KEY of .env is not the public key of NODES_WG_PRIVATE_KEY" "$OUT"
wireguard
chmod 644 "${MCLOUD}/configuration/wireguard/private-key" 2> /dev/null || {
  echo "$WG_PRIVATE" > "${MCLOUD}/configuration/wireguard/private-key"
  chmod 644 "${MCLOUD}/configuration/wireguard/private-key"
}
zbr doctor
check_contains "a key file of the tunnel readable by others is a warning" "configuration/wireguard/private-key (644)" "$OUT"
rm -f "${MCLOUD}/configuration/wireguard/private-key" "${WORK}/ip-wireguard" "${WORK}/handshakes"

section "before the setup"
rm -f "${MCLOUD}/.env"
zbr doctor
check "doctor before the setup fails" "1" "$STATUS"
check_contains "doctor before the setup asks for it" "MCloud is not set up: run ./zebrunner.sh setup first." "$OUT"

finish
