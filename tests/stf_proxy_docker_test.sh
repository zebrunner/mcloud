#!/bin/bash
# Tests of the nginx configuration of stf-proxy in docker, the one ./zebrunner.sh setup writes, with a fake stf-api and
# a fake node (nginx too): the screens of the devices allowed by stf-api (/api/v1/zebrunner/screen-auth) with the headers
# each side gets, the internal routes, and the limits of the enrollment and of the record of a node. The containers
# have fixed names and use the port 18083 of the host.
source "$(dirname "$0")/lib.sh"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker"
if [[ -n "$(docker ps -aq --filter name='^/(stf-proxy-test|stf-proxy-test-fake)$')" ]]; then
  skip "the containers of the test exist on this machine"
fi

MCLOUD="${WORK}/mcloud"
FAKE="${WORK}/fake"
URL="http://127.0.0.1:18083"
NGINX="nginx:$(sed -n 's/^TAG_NGINX=//p' "${REPO}/.env.original")"
copy_repo "$MCLOUD"
mkdir -p "$FAKE"

# cleanup: removes the containers and the network of the test
# the EXIT trap of tests/lib.sh runs it
# shellcheck disable=SC2329
cleanup() {
  docker rm -f stf-proxy-test stf-proxy-test-fake > /dev/null 2>&1
  docker network rm stf-proxy-test > /dev/null 2>&1
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

section "the configuration"
if ! docker image inspect "$NGINX" > /dev/null 2>&1; then
  run_check "pull ${NGINX}" docker pull --quiet "$NGINX"
fi
# the answers: protocol, host, port, the admin, the sign-in, no start
printf 'http\nlocalhost\n18083\ny\n\n\ny\n\nn\n' | /bin/bash "${MCLOUD}/zebrunner.sh" setup > /dev/null 2>&1
check "the setup writes the configuration of stf-proxy" "yes" \
  "$([[ -s "${MCLOUD}/configuration/stf-proxy/nginx.conf" ]] && echo yes)"
run_check "nginx -t of the configuration of http" docker run --rm \
  -v "${MCLOUD}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX" nginx -t

section "the stand-ins"
# stf-api (and stf-app): the screen of serial1 at node1:7400 for the session ssid=good or the token good-token; a header
# of the user other than the cookie and the token fails the decision (418, a 500 of stf-proxy); the other paths answer
# their request. node1: the headers it gets
# shellcheck disable=SC2016 # the variables of nginx
printf '%s\n' 'events {}' 'http {' '  server {' '    listen 3000;' \
  '    location = /api/v1/zebrunner/screen-auth {' \
  '      set $allowed "";' \
  '      if ($http_cookie ~ "(^|; )ssid=good(;|$)") { set $allowed 1; }' \
  '      if ($http_authorization = "Bearer good-token") { set $allowed 1; }' \
  '      if ($allowed = "") { return 401; }' \
  '      if ($http_x_stf_secret != "") { return 418; }' \
  '      if ($http_x_original_uri != "/d/node1/serial1/7400/") { return 403; }' \
  '      return 204;' \
  '    }' \
  '    location / { default_type text/plain; return 200 "upstream $request_method $request_uri\n"; }' \
  '  }' '  server {' '    listen 7400;' \
  '    location / {' \
  '      default_type text/plain;' \
  '      return 200 "node cookie=[$http_cookie] authorization=[$http_authorization] stf=[$http_x_stf_secret] internal=[$http_x_stf_internal_token] upgrade=[$http_upgrade] connection=[$http_connection] key=[$http_sec_websocket_key] version=[$http_sec_websocket_version]\n";' \
  '    }' '  }' '  server {' '    listen 4444;' \
  '    location / {' \
  '      default_type text/plain;' \
  '      return 200 "grid $request_uri upgrade=[$http_upgrade] connection=[$http_connection] agent=[$http_user_agent]\n";' \
  '    }' '  }' '}' > "${FAKE}/nginx.conf"
docker network create stf-proxy-test > /dev/null
run_check "the fake stf-api and node" docker run -d --name stf-proxy-test-fake --network stf-proxy-test \
  --network-alias stf-api --network-alias stf-app --network-alias node1 --network-alias mcloud-grid -v "${FAKE}/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"
run_check "stf-proxy" docker run -d --name stf-proxy-test --network stf-proxy-test -p 127.0.0.1:18083:80 \
  -v "${MCLOUD}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"
run_check "stf-proxy answers" wait_for 30 curl -sf --max-time 2 "${URL}/api/v1/user"

section "screens of the devices"
screen="/d/node1/serial1/7400/"
websocket=(-H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13"
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==")
check "the screen needs a signed-in user (401 of stf-api)" "401" "$(http_code "$screen")"
check "a wrong session is refused" "401" "$(http_code "$screen" -H "Cookie: ssid=bad")"
check "another port of the device is refused (403 of stf-api for the original URI)" "403" \
  "$(http_code /d/node1/serial1/7401/ -H "Cookie: ssid=good")"
check "the node gets the WebSocket without the cookie and the other headers of the user" \
  "node cookie=[] authorization=[] stf=[] internal=[] upgrade=[websocket] connection=[upgrade] key=[dGhlIHNhbXBsZSBub25jZQ==] version=[13]" \
  "$(body "$screen" -H "Cookie: other=1; ssid=good" -H "X-Stf-Secret: leak" -H "X-Stf-Internal-Token: leak" "${websocket[@]}")"
check "an access token: the node does not get it" \
  "node cookie=[] authorization=[] stf=[] internal=[] upgrade=[websocket] connection=[upgrade] key=[dGhlIHNhbXBsZSBub25jZQ==] version=[13]" \
  "$(body "$screen" -H "Authorization: Bearer good-token" "${websocket[@]}")"
check "a port below 1024 is not a screen: the app gets it" "upstream GET /d/node1/serial1/80/" \
  "$(body /d/node1/serial1/80/ -H "Cookie: ssid=good")"

section "playwright"
check "the WebSocket of a Playwright session goes to the servlet of the grid with its upgrade and User-Agent" \
  "grid /grid/admin/PlaywrightServlet/f09c14e2-7c54 upgrade=[websocket] connection=[upgrade] agent=[Playwright/1.65.0]" \
  "$(body /mcloud/playwright/f09c14e2-7c54 -A "Playwright/1.65.0" "${websocket[@]}")"
check "the other paths of the grid stay with the grid" "grid /grid/admin/DevicesServlet upgrade=[] connection=[] agent=[curl]" \
  "$(body /mcloud/grid/admin/DevicesServlet -A curl)"
check "a nested path is not a Playwright session" "grid /playwright/a/b upgrade=[] connection=[] agent=[curl]" \
  "$(body /mcloud/playwright/a/b -A curl)"

section "internal routes of the registry"
for path in /api/v1/zebrunner/nodes/keys /api/v1/zebrunner/nodes/token /API/V1/Zebrunner/Nodes/keys/ \
  //api//v1/zebrunner/nodes/keys /api/v1/zebrunner/%6Eodes/keys /api/v1/zebrunner/nodes; do
  check "${path} is refused" "403" "$(http_code "$path" -H "X-Stf-Internal-Token: guess")"
done
check "the screen decision of the API is not an internal route (401 of stf-api)" "401" \
  "$(http_code /api/v1/zebrunner/screen-auth)"

section "the record of a node for itself"
check "the record of a node goes to stf-api" "upstream GET /api/v1/nodes/self" \
  "$(body /api/v1/nodes/self -H "Authorization: Bearer node-token")"
codes=""
for _ in $(seq 11); do
  codes+="$(http_code /api/v1/nodes/self -H "Authorization: Bearer node-token") "
done
check "a burst of 10, then 429" "200 200 200 200 200 200 200 200 200 200 429 " "$codes"
check "another case is limited too" "429" "$(http_code /API/v1/Nodes/Self)"

section "enrollment of the nodes"
check "the enrollment goes to stf-api" "upstream POST /api/v1/nodes/enroll" "$(body /api/v1/nodes/enroll -X POST -d '{}')"
codes=""
for _ in 1 2 3 4; do
  codes+="$(http_code /api/v1/nodes/enroll -X POST -d '{}') "
done
check "a burst of 3, then 429" "200 200 200 429 " "$codes"
check "another case and a final slash are limited too" "429" "$(http_code /API/v1/Nodes/Enroll/ -X POST -d '{}')"
check "the other routes of the API are not limited" "200 200 200 200 200 " \
  "$(for _ in 1 2 3 4 5; do printf '%s ' "$(http_code /api/v1/nodes -H "Authorization: Bearer x")"; done)"
check_contains "stf-proxy logs the limit" "limiting requests" "$(docker logs stf-proxy-test 2>&1)"

finish
