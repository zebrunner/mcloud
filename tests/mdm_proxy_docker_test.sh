#!/bin/bash
# Tests of the MDM in nginx (README.md#mdm): the locations patch/mdm.sh writes for stf-proxy in the configuration
# ./zebrunner.sh setup writes, and the MQTT proxy, with stand-ins of stf-api, mcloud-mdm, NanoHUB and Headwind MDM (nginx
# too): the paths of the devices and of the nodes, the node token checked by stf-api and the enrollment token sent to
# mcloud-mdm, the paths of Headwind MDM, the admin UI and the addresses of the sites. The containers have fixed names and
# use the ports 18093 and 18443 of the host.
source "$(dirname "$0")/lib.sh"

require_cmd docker
require_cmd openssl
docker info > /dev/null 2>&1 || skip "requires a running docker"
if [[ -n "$(docker ps -aq --filter name='^/mdm-proxy-test')" ]]; then
  skip "the containers of the test exist on this machine"
fi

MCLOUD="${WORK}/mcloud"
FAKE="${WORK}/fake"
URL="http://127.0.0.1:18093"
NGINX="nginx:$(sed -n 's/^TAG_NGINX=//p' "${REPO}/.env.original")"
copy_repo "$MCLOUD"
mkdir -p "$FAKE"

# cleanup: removes the containers and the network of the test
# the EXIT trap of tests/lib.sh runs it
# shellcheck disable=SC2329
cleanup() {
  docker rm -f mdm-proxy-test mdm-proxy-test-mqtt mdm-proxy-test-fake mdm-proxy-test-hmdm > /dev/null 2>&1
  docker network rm mdm-proxy-test > /dev/null 2>&1
}

# http_code <path> [curl arguments...]: the HTTP status of a request to stf-proxy
http_code() {
  local path="$1"
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "${URL}${path}"
}

# body <path> [curl arguments...]: the answer of a request to stf-proxy
body() {
  local path="$1"
  shift
  curl -s --max-time 10 "$@" "${URL}${path}"
}

# mqtt: what the MQTT proxy relays over TLS from the stand-in of Headwind MDM
mqtt() {
  openssl s_client -connect 127.0.0.1:18443 -quiet < /dev/null 2> /dev/null | head -n 1
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

# write_mdm_of <addresses> <admin public>: the files of the MDM in the copy for these settings, by patch/mdm.sh
write_mdm_of() {
  (
    cd "$MCLOUD" || exit 1
    # shellcheck source=../patch/utility.sh
    source patch/utility.sh
    # shellcheck source=../patch/ui.sh
    source patch/ui.sh
    # shellcheck source=../patch/mdm.sh
    source patch/mdm.sh
    set_line .env "STF_URL=https://mcloud.example.com:443"
    set_line .env "MDM_ENABLED=true"
    set_line .env "MDM_SITE_ADDRESSES=$1"
    set_line .env "MDM_ADMIN_PUBLIC=$2"
    write_mdm > /dev/null
  )
}

section "the configuration"
if ! docker image inspect "$NGINX" > /dev/null 2>&1; then
  run_check "pull ${NGINX}" docker pull --quiet "$NGINX"
fi
# the answers: protocol, host, port, the admin, the sign-in, no start
printf 'http\nlocalhost\n18093\ny\n\n\ny\n\nn\n' | /bin/bash "${MCLOUD}/zebrunner.sh" setup > /dev/null 2>&1
write_mdm_of "0.0.0.0/0,::/0" false
TOKEN="$(sed -n 's/^MDM_ENROLL_TOKEN=//p' "${MCLOUD}/mdm.env")"
ADMIN_TOKEN="$(sed -n 's/^MDM_ADMIN_TOKEN=//p' "${MCLOUD}/mdm.env")"
check "the enrollment token is generated" "48" "${#TOKEN}"
mkdir -p "${MCLOUD}/configuration/stf-proxy/ssl"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" -keyout "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key" \
  -out "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" > /dev/null 2>&1
proxy_volumes=(-v "${MCLOUD}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro"
  -v "${MCLOUD}/configuration/stf-proxy/grid-auth.conf:/etc/nginx/grid-auth.conf:ro"
  -v "${MCLOUD}/configuration/stf-proxy/mdm:/etc/nginx/mdm:ro")
mqtt_volumes=(-v "${MCLOUD}/configuration/mdm/mqtt.conf:/etc/nginx/nginx.conf:ro"
  -v "${MCLOUD}/configuration/stf-proxy/ssl:/etc/nginx/ssl:ro")

section "the stand-ins"
# stf-api: a node with the token good-node, an admin of STF with the token admin-token; mcloud-mdm, NanoHUB: what they get
# shellcheck disable=SC2016 # the variables of nginx
printf '%s\n' 'events {}' 'http {' \
  '  server {' '    listen 3000;' \
  '    location = /api/v1/nodes/self {' \
  '      if ($http_authorization != "Bearer good-node") { return 401; }' \
  '      return 200 "{}";' \
  '    }' \
  '    location = /api/v1/zebrunner/hub-auth {' \
  '      if ($http_authorization != "Bearer admin-token") { return 401; }' \
  '      if ($arg_scope != "admin") { return 403; }' \
  '      return 204;' \
  '    }' \
  '    location / { default_type text/plain; return 200 "stf $request_uri\n"; }' \
  '  }' \
  '  server { listen 8080; location / { default_type text/plain; return 200 "mdm $request_method $request_uri authorization=[$http_authorization]\n"; } }' \
  '  server { listen 8081; location / { default_type text/plain; return 200 "admin $request_uri host=[$http_host] authorization=[$http_authorization]\n"; } }' \
  '  server { listen 9004; location / { default_type text/plain; return 200 "nanohub $request_method $request_uri\n"; } }' \
  '}' > "${FAKE}/nginx.conf"
# Headwind MDM: its HTTP and its MQTT
# shellcheck disable=SC2016
printf '%s\n' 'events {}' \
  'http { server { listen 8080; location / { default_type text/plain; return 200 "hmdm $request_method $request_uri\n"; } } }' \
  'stream { server { listen 31000; return "mqtt of hmdm\n"; } }' > "${FAKE}/hmdm.conf"
docker network create mdm-proxy-test > /dev/null
run_check "the stand-ins of stf-api, mcloud-mdm and NanoHUB" docker run -d --name mdm-proxy-test-fake --network mdm-proxy-test \
  --network-alias stf-api --network-alias stf-app --network-alias mcloud-mdm --network-alias mcloud-mdm-nanohub \
  -v "${FAKE}/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"
run_check "the stand-in of Headwind MDM" docker run -d --name mdm-proxy-test-hmdm --network mdm-proxy-test \
  --network-alias mcloud-mdm-hmdm -v "${FAKE}/hmdm.conf:/etc/nginx/nginx.conf:ro" "$NGINX"
run_check "nginx -t of stf-proxy with the MDM" docker run --rm --network mdm-proxy-test "${proxy_volumes[@]}" "$NGINX" nginx -t
run_check "stf-proxy" docker run -d --name mdm-proxy-test --network mdm-proxy-test -p 127.0.0.1:18093:80 \
  "${proxy_volumes[@]}" "$NGINX"
run_check "the MQTT proxy" docker run -d --name mdm-proxy-test-mqtt --network mdm-proxy-test -p 127.0.0.1:18443:31443 \
  "${mqtt_volumes[@]}" "$NGINX"
run_check "stf-proxy answers" wait_for 30 curl -sf --max-time 2 "${URL}/scep"

section "the devices"
check "/mdm is NanoHUB" "nanohub PUT /mdm" "$(body /mdm -X PUT)"
check "/checkin is NanoHUB" "nanohub PUT /checkin" "$(body /checkin -X PUT)"
check "/mdm/ is not NanoHUB" "no" "$(body /mdm/x | grep -q nanohub && echo yes || echo no)"
check "/scep is mcloud-mdm, without a token" "mdm GET /scep?operation=GetCACert authorization=[]" \
  "$(body '/scep?operation=GetCACert' -H 'Authorization: Bearer good-node')"
check "the agent APK is mcloud-mdm" "mdm GET /android/agent.apk authorization=[]" "$(body /android/agent.apk)"

section "the nodes"
check "no node token: 401" "401" "$(http_code '/mdm/enroll?udid=u1')"
check "a wrong node token: 401" "401" "$(http_code '/mdm/enroll?udid=u1' -H 'Authorization: Bearer bad')"
check "a node: mcloud-mdm gets the enrollment token, not the node token" \
  "mdm GET /mdm/enroll?udid=u1 authorization=[Bearer ${TOKEN}]" "$(body '/mdm/enroll?udid=u1' -H 'Authorization: Bearer good-node')"
for path in '/mdm/status?udid=u1' '/android/enroll?serial=s1' '/android/status?serial=s1' '/android/release'; do
  check "${path%%\?*} for a node" "mdm GET ${path} authorization=[Bearer ${TOKEN}]" \
    "$(body "$path" -H 'Authorization: Bearer good-node')"
  check "${path%%\?*} without a node token: 401" "401" "$(http_code "$path")"
done
check "the release of an iOS device for a node" "mdm POST /mdm/release?udid=u1 authorization=[Bearer ${TOKEN}]" \
  "$(body '/mdm/release?udid=u1' -X POST -H 'Authorization: Bearer good-node')"

section "Headwind MDM"
check "the configuration of an agent, the prefix stripped" "hmdm POST /rest/public/sync/configuration/s1" \
  "$(body /hmdm/rest/public/sync/configuration/s1 -X POST)"
check "the device info" "hmdm POST /rest/public/sync/info" "$(body /hmdm/rest/public/sync/info -X POST)"
check "the log of an agent" "hmdm POST /rest/plugins/devicelog/log/list/s1" "$(body /hmdm/rest/plugins/devicelog/log/list/s1 -X POST)"
check "a file of a configuration" "hmdm GET /files/agent.apk" "$(body /hmdm/files/agent.apk)"
for path in /hmdm/ /hmdm/rest/public/jwt/login /hmdm/rest/private/devices/search /hmdm/files/a/b /hmdm/rest/public/sync/x/y; do
  check "${path} is not published" "404" "$(http_code "$path")"
done

section "the admin UI"
check "not published by default" "404" "$(http_code /mcloud/mdm/)"
write_mdm_of "0.0.0.0/0,::/0" true
run_check "stf-proxy reads the new locations" docker exec mdm-proxy-test nginx -s reload
sleep 1
check "MDM_ADMIN_PUBLIC=true: a user without a sign-in goes to the sign-in of STF" "302" "$(http_code /mcloud/mdm/)"
check "an admin of STF gets the UI, with the host of the browser" "admin /api/state host=[127.0.0.1:18093] authorization=[Bearer ${ADMIN_TOKEN}]" \
  "$(body /mcloud/mdm/api/state -H 'Authorization: Bearer admin-token')"
check "/mcloud/mdm goes to /mcloud/mdm/" "302" "$(http_code /mcloud/mdm)"

section "MQTT over TLS"
check "the MQTT proxy relays to Headwind MDM over TLS" "mqtt of hmdm" "$(mqtt)"

section "the addresses of the sites"
write_mdm_of "203.0.113.10" false
run_check "stf-proxy reads the new locations" docker exec mdm-proxy-test nginx -s reload
run_check "the MQTT proxy reads its new configuration" docker exec mdm-proxy-test-mqtt nginx -s reload
sleep 1
for path in /mdm /checkin /scep /android/agent.apk '/mdm/enroll?udid=u1' /hmdm/rest/public/sync/info; do
  check "${path%%\?*} is refused to another address" "403" "$(http_code "$path" -H 'Authorization: Bearer good-node')"
done
check "MQTT is refused to another address" "" "$(mqtt)"
check "STF is not changed" "stf /" "$(body /)"

finish
