#!/bin/bash
# Tests of the nginx configuration of stf-proxy in docker, the one ./zebrunner.sh setup writes, with a fake stf-api, a
# fake node and a fake grid (nginx too): the screens of the devices allowed by stf-api (/api/v1/zebrunner/screen-auth) with
# the headers each side gets, the access to the grid (/api/v1/zebrunner/hub-auth) with the headers the grid gets, the
# internal routes, and the limits of the enrollment and of the record of a node. The containers have fixed names and use
# the port 18083 of the host.
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
# shellcheck disable=SC2012 # one known file, ls is the same on Linux and macOS
check "the setup writes the secret of the grid for stf-proxy" "-rw-------" \
  "$(ls -l "${MCLOUD}/configuration/stf-proxy/grid-auth.conf" | cut -c1-10)"
GRID_SECRET="$(sed -n 's/^GRID_AUTH_SECRET=//p' "${MCLOUD}/variables.env")"
check "the secret of the grid is generated" "48" "${#GRID_SECRET}"
check_contains "stf-proxy gets the secret of variables.env" "default \"${GRID_SECRET}\";" \
  "$(cat "${MCLOUD}/configuration/stf-proxy/grid-auth.conf")"
proxy_volumes=(-v "${MCLOUD}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro"
  -v "${MCLOUD}/configuration/stf-proxy/grid-auth.conf:/etc/nginx/grid-auth.conf:ro")
run_check "nginx -t of the configuration of http" docker run --rm "${proxy_volumes[@]}" "$NGINX" nginx -t

section "the stand-ins"
# stf-api (and stf-app): the screen of serial1 at node1:7400 for the session ssid=good or the token good-token, with the
# screen ticket v1.1.ticket; a header
# of the user other than the cookie and the token fails the decision (418, a 500 of stf-proxy); the other paths answer
# their request. hub-auth: john@example.com with the token john-token in Basic (or the session ssid=good for the console
# and the admin routes), admin@example.com with Bearer admin-token; a header X-MCloud-* of the client fails it (418).
# node1 and the grid: the headers they get
# shellcheck disable=SC2016 # the variables of nginx
printf '%s\n' 'events {}' 'http {' '  server {' '    listen 3000;' \
  '    location = /api/v1/zebrunner/screen-auth {' \
  '      set $allowed "";' \
  '      if ($http_cookie ~ "(^|; )ssid=good(;|$)") { set $allowed 1; }' \
  '      if ($http_authorization = "Bearer good-token") { set $allowed 1; }' \
  '      if ($allowed = "") { return 401; }' \
  '      if ($http_x_stf_secret != "") { return 418; }' \
  '      if ($http_x_original_uri != "/d/node1/serial1/7400/") { return 403; }' \
  '      add_header X-MCloud-Screen-Ticket v1.1.ticket;' \
  '      return 204;' \
  '    }' \
  '    location = /api/v1/zebrunner/hub-auth {' \
  '      set $user ""; set $admin false; set $token "";' \
  '      if ($http_authorization = "Basic am9obkBleGFtcGxlLmNvbTpqb2huLXRva2Vu") { set $user john@example.com; set $token john-token; }' \
  '      if ($http_authorization = "Bearer admin-token") { set $user admin@example.com; set $admin true; set $token admin-token; }' \
  '      set $by_cookie "$arg_scope:$user";' \
  '      if ($http_cookie !~ "(^|; )ssid=good(;|$)") { set $by_cookie ""; }' \
  '      if ($by_cookie ~ "^(console|admin):$") { set $user john@example.com; }' \
  '      if ($http_x_mcloud_user != "") { return 418; }' \
  '      if ($user = "") { return 401; }' \
  '      set $admin_route "$arg_scope:$admin";' \
  '      if ($admin_route = "admin:false") { return 403; }' \
  '      add_header X-MCloud-User $user;' \
  '      add_header X-MCloud-Admin $admin;' \
  '      add_header X-MCloud-Token $token;' \
  '      return 204;' \
  '    }' \
  '    location / { default_type text/plain; return 200 "upstream $request_method $request_uri\n"; }' \
  '  }' '  server {' '    listen 7400;' \
  '    location / {' \
  '      default_type text/plain;' \
  '      return 200 "node cookie=[$http_cookie] authorization=[$http_authorization] stf=[$http_x_stf_secret] internal=[$http_x_stf_internal_token] ticket=[$http_x_mcloud_screen_ticket] upgrade=[$http_upgrade] connection=[$http_connection] key=[$http_sec_websocket_key] version=[$http_sec_websocket_version]\n";' \
  '    }' '  }' '  server {' '    listen 4444;' \
  '    location / {' \
  '      default_type text/plain;' \
  '      return 200 "grid $request_method $request_uri upgrade=[$http_upgrade] connection=[$http_connection] agent=[$http_user_agent] auth=[$http_x_mcloud_auth] user=[$http_x_mcloud_user] admin=[$http_x_mcloud_admin] token=[$http_x_mcloud_token] authorization=[$http_authorization] cookie=[$http_cookie]\n";' \
  '    }' '  }' '}' > "${FAKE}/nginx.conf"
docker network create stf-proxy-test > /dev/null
run_check "the fake stf-api and node" docker run -d --name stf-proxy-test-fake --network stf-proxy-test \
  --network-alias stf-api --network-alias stf-app --network-alias node1 --network-alias mcloud-grid --network-alias stf-websocket -v "${FAKE}/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX"
run_check "stf-proxy" docker run -d --name stf-proxy-test --network stf-proxy-test -p 127.0.0.1:18083:80 -p 127.0.0.1:18446:4446 \
  "${proxy_volumes[@]}" "$NGINX"
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
  "node cookie=[] authorization=[] stf=[] internal=[] ticket=[v1.1.ticket] upgrade=[websocket] connection=[upgrade] key=[dGhlIHNhbXBsZSBub25jZQ==] version=[13]" \
  "$(body "$screen" -H "Cookie: other=1; ssid=good" -H "X-Stf-Secret: leak" -H "X-Stf-Internal-Token: leak" -H "X-MCloud-Screen-Ticket: forged" "${websocket[@]}")"
check "an access token: the node does not get it" \
  "node cookie=[] authorization=[] stf=[] internal=[] ticket=[v1.1.ticket] upgrade=[websocket] connection=[upgrade] key=[dGhlIHNhbXBsZSBub25jZQ==] version=[13]" \
  "$(body "$screen" -H "Authorization: Bearer good-token" "${websocket[@]}")"
check "a port below 1024 is not a screen: the app gets it" "upstream GET /d/node1/serial1/80/" \
  "$(body /d/node1/serial1/80/ -H "Cookie: ssid=good")"

section "the WebSocket of STF"
check "the pages of MCloud open the WebSocket" "upstream GET /socket.io/?EIO=4" \
  "$(body '/socket.io/?EIO=4' -H "Origin: http://127.0.0.1:18083" -H "Host: 127.0.0.1:18083")"
check "a client without Origin opens it" "upstream GET /socket.io/?EIO=4" "$(body '/socket.io/?EIO=4')"
check "a page of another site does not (cross-site WebSocket hijacking)" "403" \
  "$(http_code '/socket.io/?EIO=4' -H "Origin: https://evil.example.com" -H "Cookie: ssid=good")"
check "another scheme is another site" "403" "$(http_code '/socket.io/?EIO=4' -H "Origin: https://127.0.0.1:18083")"

section "HSTS"
check "no HSTS over http" "" "$(curl -s -o /dev/null -D - --max-time 10 "${URL}/" | grep -i '^strict-transport-security')"
check "HSTS over https" "Strict-Transport-Security: max-age=31536000" \
  "$(curl -s -o /dev/null -D - --max-time 10 -H "X-Forwarded-Proto: https" "${URL}/" | grep -i '^strict-transport-security' | tr -d '\r')"

section "the access to the grid"
john=(-u "john@example.com:john-token")
# the user stf-api let in, as the grid gets it
as_john="auth=[${GRID_SECRET}] user=[john@example.com] admin=[false] token=[john-token] authorization=[] cookie=[]"
as_admin="auth=[${GRID_SECRET}] user=[admin@example.com] admin=[true] token=[admin-token] authorization=[] cookie=[]"
as_cookie="auth=[${GRID_SECRET}] user=[john@example.com] admin=[false] token=[] authorization=[] cookie=[]"
session=(-X POST -H "Content-Type: application/json" -d '{"capabilities":{}}')
check "a session without an access token is refused" "401" "$(http_code /mcloud/wd/hub/session "${session[@]}")"
check_contains "the client gets an error of WebDriver" "MCloud takes the requests of its users" \
  "$(body /mcloud/wd/hub/session "${session[@]}")"
headers="$(curl -s -o /dev/null -D - --max-time 10 "${session[@]}" "${URL}/mcloud/wd/hub/session" | tr -d '\r')"
check_contains "the refusal asks for a Bearer token, no password of the browser" 'WWW-Authenticate: Bearer realm="MCloud"' "$headers"
check "the hub takes no session cookie (a page of another site would use it)" "401" \
  "$(http_code /mcloud/wd/hub/session "${session[@]}" -H "Cookie: ssid=good")"
check "a wrong token is refused" "401" "$(http_code /mcloud/wd/hub/session "${session[@]}" -u "john@example.com:wrong")"
check "the grid gets the user of the token with the secret, not the Authorization and the Cookie of the client" \
  "grid POST /wd/hub/session upgrade=[] connection=[] agent=[curl] ${as_john}" \
  "$(body /mcloud/wd/hub/session "${session[@]}" "${john[@]}" -A curl -H "Cookie: ssid=good")"
check "the X-MCloud-* headers of the client reach neither stf-api nor the grid" "grid GET /wd/hub/session/s1/url upgrade=[] connection=[] agent=[curl] ${as_john}" \
  "$(body /mcloud/wd/hub/session/s1/url "${john[@]}" -A curl -H "X-MCloud-Admin: true" -H "X-MCloud-Auth: forged")"
check "the query of a command reaches the grid" "grid GET /wd/hub/session/s1/url?x=1 upgrade=[] connection=[] agent=[curl] ${as_john}" \
  "$(body '/mcloud/wd/hub/session/s1/url?x=1' "${john[@]}" -A curl)"
check "the status of the hub needs a user of STF" "401" "$(http_code /mcloud/wd/hub/status)"
check "the status of the hub for a signed-in user, without a header of the client" "grid GET /wd/hub/status upgrade=[] connection=[] agent=[] auth=[] user=[] admin=[] token=[] authorization=[] cookie=[]" \
  "$(body /mcloud/wd/hub/status -A curl -H "Cookie: ssid=good")"
check "the status of the hub for an access token" "200" "$(http_code /mcloud/wd/hub/status "${john[@]}")"
check "the preflight of a browser needs no user" "204" "$(http_code /mcloud/wd/hub/session -X OPTIONS -H "Origin: https://x.example.com")"
check "the WebSocket of a Playwright session goes to the servlet of the grid with its upgrade, User-Agent and user" \
  "grid GET /grid/admin/PlaywrightServlet/f09c14e2-7c54 upgrade=[websocket] connection=[upgrade] agent=[Playwright/1.65.0] ${as_john}" \
  "$(body /mcloud/playwright/f09c14e2-7c54 -A "Playwright/1.65.0" "${john[@]}" "${websocket[@]}")"
check "a Playwright session needs an access token" "401" "$(http_code /mcloud/playwright/f09c14e2-7c54 -H "Cookie: ssid=good" "${websocket[@]}")"
check "the termination of a session goes to the grid with the user" \
  "grid POST /grid/admin/TerminateSessionServlet?udid=x upgrade=[] connection=[] agent=[curl] ${as_john}" \
  "$(body '/mcloud/grid/admin/TerminateSessionServlet?udid=x' -X POST "${john[@]}" -A curl)"
check "the termination of a session needs an access token" "401" \
  "$(http_code '/mcloud/grid/admin/TerminateSessionServlet?udid=x' -X POST -H "Cookie: ssid=good")"
check "the console sends a user without a sign-in to the sign-in of STF" "302 http://127.0.0.1:18083/" \
  "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "${URL}/mcloud/grid/console")"
check "the console of a signed-in user" "grid GET /grid/console upgrade=[] connection=[] agent=[curl] ${as_cookie}" \
  "$(body /mcloud/grid/console -A curl -H "Cookie: ssid=good")"
check "the devices of the grid need a user" "401" "$(http_code /mcloud/grid/admin/DevicesServlet)"
check "the devices of the grid with an access token" "grid GET /grid/admin/DevicesServlet upgrade=[] connection=[] agent=[curl] ${as_john}" \
  "$(body /mcloud/grid/admin/DevicesServlet -A curl "${john[@]}")"
check "the sessions of the grid for a signed-in user" "grid GET /grid/admin/AllSessionsServlet upgrade=[] connection=[] agent=[curl] ${as_cookie}" \
  "$(body /mcloud/grid/admin/AllSessionsServlet -A curl -H "Cookie: ssid=good")"
check "the metrics are refused to a user" "403 403" \
  "$(http_code /mcloud/grid/admin/MetricsServlet "${john[@]}") $(http_code /mcloud/grid/admin/MetricsServlet -H "Cookie: ssid=good")"
check "the metrics for an admin" "grid GET /grid/admin/MetricsServlet upgrade=[] connection=[] agent=[curl] ${as_admin}" \
  "$(body /mcloud/grid/admin/MetricsServlet -A curl -H "Authorization: Bearer admin-token")"
for path in /mcloud /mcloud/ /mcloud/grid/api/hub /mcloud/grid/api/proxy /mcloud/grid/register /mcloud/lifecycle-manager \
  /mcloud/grid/console/../api/hub /mcloud/wd/../grid/api/hub /mcloud/playwright/a/b /mcloud/grid/admin/ProxyInfo \
  /mcloud/grid/admin/DevicesServletX; do
  check "${path} of the grid is not for the users" "404" "$(http_code "$path" --path-as-is -H "Authorization: Bearer admin-token")"
done
check "the decision about the grid is not a route of the users" "403" "$(http_code /api/v1/zebrunner/hub-auth "${john[@]}")"
check "another case of it neither" "403" "$(http_code /API/v1/Zebrunner/Hub-Auth "${john[@]}")"

section "the grid of the nodes"
# grid_code <method> <path>: the status of a request to the port of the nodes (4446)
grid_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --path-as-is -X "$1" "http://127.0.0.1:18446$2"
}
check "the registration of a node goes to the grid" \
  "grid POST /grid/register upgrade=[] connection=[] agent=[curl] auth=[] user=[] admin=[] token=[] authorization=[] cookie=[]" \
  "$(curl -s --max-time 10 -A curl -X POST --data '{}' http://127.0.0.1:18446/grid/register)"
check "the check of a registered node goes to the grid" \
  "grid GET /grid/api/proxy?id=http://192.0.2.1:4723 upgrade=[] connection=[] agent=[curl] auth=[] user=[] admin=[] token=[] authorization=[] cookie=[]" \
  "$(curl -s --max-time 10 -A curl 'http://127.0.0.1:18446/grid/api/proxy?id=http://192.0.2.1:4723')"
for request in "POST /grid/api/proxy" "GET /wd/hub/status" "POST /wd/hub/session" "GET /grid/console" \
  "GET /grid/admin/DevicesServlet" "GET /grid/admin/PlaywrightServlet/x" "GET /grid/registerx" "GET /lifecycle-manager" \
  "GET /grid/register/../admin/DevicesServlet" "GET /"; do
  # the method and the path of the request
  # shellcheck disable=SC2086
  check "${request} of the port of the nodes is refused" "403" "$(grid_code ${request})"
done

section "internal routes of the registry"
for path in /api/v1/zebrunner/nodes/keys /api/v1/zebrunner/nodes/token /API/V1/Zebrunner/Nodes/keys/ \
  //api//v1/zebrunner/nodes/keys /api/v1/zebrunner/%6Eodes/keys /api/v1/zebrunner/nodes; do
  check "${path} is refused" "403" "$(http_code "$path" -H "X-Stf-Internal-Token: guess")"
done
check "the screen decision of the API is not an internal route (401 of stf-api)" "401" \
  "$(http_code /api/v1/zebrunner/screen-auth)"

section "the hub"
headers="$(curl -s -o /dev/null -D - --max-time 10 "${john[@]}" "${URL}/mcloud/wd/hub/session/s1/url" | tr -d '\r')"
check_contains "the hub allows any origin" "Access-Control-Allow-Origin: *" "$headers"
check "the hub does not allow credentials with any origin (invalid CORS)" "" \
  "$(grep -i '^access-control-allow-credentials:' <<< "$headers")"
check "the buffers of an answer of the hub are bounded" "proxy_buffers           32 1m;" \
  "$(docker exec stf-proxy-test nginx -T 2> /dev/null | grep -o 'proxy_buffers .*;')"

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
