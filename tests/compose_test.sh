#!/bin/bash
# Tests of the services: a copy of the repository is set up and started by zebrunner.sh with the images of
# .env.original (TAG_STF and TAG_SELENIUM_HUB of the environment override them), its endpoints are checked through
# stf-proxy, then it is shut down. The containers have fixed names and ports: no other MCloud may run on this machine.
source "$(dirname "$0")/lib.sh"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker"
docker compose version > /dev/null 2>&1 || skip "requires docker compose"
if [[ -n "$(docker ps -aq --filter name='^/(stf-proxy|mcloud-grid|rethinkdb|stf-app|adb-relay)$')" ]]; then
  skip "the containers of MCloud exist on this machine"
fi

MCLOUD="${WORK}/mcloud"
PORT="${PORT:-8082}"
URL="http://localhost:${PORT}"
copy_repo "$MCLOUD"
network_created=""
docker network inspect infra > /dev/null 2>&1 || network_created=1

# cleanup: removes the containers, the volumes and the network of the test
# the EXIT trap of tests/lib.sh runs it
# shellcheck disable=SC2329
cleanup() {
  if [[ -f "${MCLOUD}/.env" ]]; then
    (cd "$MCLOUD" && docker compose --profile adb-relay down -v > /dev/null 2>&1)
  fi
  if [[ -n "$network_created" ]]; then
    docker network rm infra > /dev/null 2>&1
  fi
}

# zbr <stdin text> <zebrunner.sh arguments...>: zebrunner.sh of the copy
zbr() {
  local input="$1"
  shift
  printf '%b' "$input" | /bin/bash "${MCLOUD}/zebrunner.sh" "$@" 2>&1
}

# http_code <path> [curl arguments...]: the HTTP status of a request to stf-proxy
http_code() {
  local path="$1"
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "${URL}${path}"
}

# wait_for <seconds> <command...>: runs the command every 2 seconds until it succeeds, fails after the timeout
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
    sleep 2
  done
}

# pull <image>: docker pull, tried 3 times with a pause against the rate limits of the registries
# run_check runs it
# shellcheck disable=SC2329
pull() {
  local attempt
  for attempt in 1 2 3; do
    docker pull --quiet "$1" && return 0
    [[ "$attempt" -lt 3 ]] && sleep $((attempt * 15))
  done
  return 1
}

# answers: protocol, host, port, the admin and the sign-in (mock) of the interactive setup
answers="http\nlocalhost\n${PORT}\ny\n\n\ny\n\nn\n"

section "setup and start"
run_check "setup" zbr "$answers" setup
# the units reach the storage by STF_URL, localhost is the container itself there: stf-proxy of the network instead
sed -i.orig "s|^STF_URL=.*|STF_URL=http://stf-proxy|" "${MCLOUD}/.env"
storage_token="$(sed -n 's/^STF_STORAGE_TOKEN=//p' "${MCLOUD}/variables.env")"
# the shared user and password of the mock sign-in, quoted in variables.env
sign_in_user="$(sed -n "s/^STF_AUTH_MOCK_BASIC_AUTH_USERNAME='\(.*\)'$/\1/p" "${MCLOUD}/variables.env")"
sign_in_password="$(sed -n "s/^STF_AUTH_MOCK_BASIC_AUTH_PASSWORD='\(.*\)'$/\1/p" "${MCLOUD}/variables.env")"
sign_in="${sign_in_user}:${sign_in_password}"
# every image once and one after another: the parallel pulls of the services of one image exceed the rate limit of
# public.ecr.aws for anonymous pulls; an image of this machine is not pulled
while read -r image; do
  if docker image inspect "$image" > /dev/null 2>&1; then
    pass "${image} is on this machine"
  else
    run_check "pull ${image}" pull "$image"
  fi
done < <(cd "$MCLOUD" && docker compose config --images | sort -u)
# without an image the services do not start, the checks below would only wait for them
[[ "$FAILED" -eq 0 ]] || finish
run_check "start" zbr "" start
run_check "the database migration succeeds" \
  bash -c "test \"\$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' stf-migrate)\" == 'exited 0'"
run_check "STF answers through stf-proxy" wait_for 180 curl -sf --max-time 5 -u "$sign_in" "${URL}/auth/mock/"
run_check "the grid answers" wait_for 120 curl -sf --max-time 5 "http://127.0.0.1:4446/grid/api/proxy?id=none"
running="$(cd "$MCLOUD" && docker compose ps --services --status running | sort | tr '\n' ' ')"
expected="$(cd "$MCLOUD" && docker compose config --services | grep -vx stf-migrate | sort | tr '\n' ' ')"
check "every service but stf-migrate runs" "$expected" "$running"

section "doctor"
# the healthy services of the test: warnings only (http, STF_URL of .env changed above, AGENTS_ADDRESS 0.0.0.0, no
# node), no failure; the healthchecks of the services may still be starting right after the start
# shellcheck disable=SC2329 # called through wait_for
doctor_settled() {
  zbr "" doctor > "${WORK}/doctor.txt"
  grep -q "services run" "${WORK}/doctor.txt"
}
run_check "doctor sees every service running" wait_for 120 doctor_settled
zbr "" doctor > "${WORK}/doctor.txt"
check "doctor of the started services passes" "0" "$?"
output="$(unwrap < "${WORK}/doctor.txt")"
check_contains "doctor sees the admin token" "STF_TOKEN is an access token of the admin" "$output"
check_contains "doctor sees the grid" "The grid answers on 127.0.0.1:4446" "$output"
check_contains "doctor sees the ports of the nodes" "The ports of the nodes listen on 127.0.0.1: 4446, 7160, 7250, 7260, 7270" "$output"
check_contains "doctor finds no failure" "0 fail" "$output"

section "STF"
check "the app redirects to the sign-in" "302" "$(http_code /)"
check "/stf is the app" "302" "$(http_code /stf)"
check "the mock sign-in needs its password" "401" "$(http_code /auth/mock/)"
check "the mock sign-in page with the password of variables.env" "200" "$(http_code /auth/mock/ -u "$sign_in")"
check "the API needs an access token" "401" "$(http_code /api/v1/user)"
# start makes STF_TOKEN with stf token-add of the STF image (README.md#stf_token); an older TAG_STF has no such command
admin_token="$(sed -n 's/^STF_TOKEN=//p' "${MCLOUD}/variables.env")"
if [[ -z "$admin_token" ]]; then
  skip_check "the access token of the admin made by start" "the STF of TAG_STF has no stf token-add"
else
  check "start makes STF_TOKEN: a valid access token of STF" "200" \
    "$(http_code /api/v1/user -H "Authorization: Bearer ${admin_token}")"
  check_contains "STF_TOKEN is a token of the admin" '"privilege":"admin"' \
    "$(curl -s --max-time 10 -H "Authorization: Bearer ${admin_token}" "${URL}/api/v1/user")"
  check_contains "the grid gets the STF_TOKEN made by start" "STF_TOKEN=${admin_token}" \
    "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' mcloud-grid)"
fi
check "the storage refuses a request without the token" "401" "$(http_code /s/blob/none/none)"
check "the storage accepts the token of variables.env" "404" \
  "$(http_code /s/blob/none/none -H "x-stf-internal-token: ${storage_token}")"
check "the apk plugin forwards the credentials" "401" "$(http_code /s/apk/none/none)"
check_contains "the storage sandboxes blobs (no inline script on the origin)" "sandbox" \
  "$(curl -s -o /dev/null -D - --max-time 10 "${URL}/s/blob/none/none" | tr -d '\r' | grep -i '^content-security-policy:')"
headers="$(curl -s -o /dev/null -D - --max-time 10 -u "$sign_in" "${URL}/auth/mock/" | tr -d '\r')"
check "stf-proxy hides the nginx version" "Server: nginx" "$(grep -i '^server:' <<< "$headers")"
check "no X-Powered-By" "" "$(grep -i '^x-powered-by:' <<< "$headers")"
for header in "Referrer-Policy: no-referrer" "X-Content-Type-Options: nosniff" "X-Frame-Options: SAMEORIGIN" \
  "Content-Security-Policy: frame-ancestors 'self'"; do
  check_contains "STF: ${header}" "$header" "$headers"
done

section "screens of the devices"
# stf-api decides (/api/v1/zebrunner/screen-auth); an STF without it (an older TAG_STF) answers 404
screen_auth="$(http_code /api/v1/zebrunner/screen-auth)"
if [[ "$screen_auth" != "404" ]]; then
  check "the screen needs a signed-in user" "401" "$(http_code /d/stf-app/serial/3000/)"
fi
# the mock sign-in: its page gives the CSRF token, the app takes the token of the sign-in over (STF_URL is stf-proxy)
jar="${WORK}/cookies"
curl -s -o /dev/null -c "$jar" -u "$sign_in" --max-time 10 "${URL}/auth/mock/"
xsrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar")"
redirect="$(curl -s -b "$jar" -c "$jar" -u "$sign_in" --max-time 10 -H "Content-Type: application/json" \
  -H "Accept: application/json" -H "X-XSRF-TOKEN: ${xsrf}" -d '{"name":"tester","email":"tester@example.com"}' \
  "${URL}/auth/api/v1/mock" | sed -n 's/.*"redirect":"\([^"]*\)".*/\1/p')"
curl -s -o /dev/null -b "$jar" -c "$jar" --max-time 10 "${redirect/http:\/\/stf-proxy/$URL}"
if [[ "$screen_auth" != "404" ]]; then
  check "the screen of a device that is not in STF is refused" "403" "$(http_code /d/stf-app/serial/3000/ -b "$jar")"
else
  skip_check "the screens allowed by stf-api" "the STF of TAG_STF has no /api/v1/zebrunner/screen-auth"
fi
check "a port below 1024 is not proxied" "302" "$(http_code /d/stf-app/serial/80/)"
check "/appium/ is not proxied" "302" "$(http_code /appium/mcloud-grid/4444/)"

section "storage"
# an image of the user is stored by stf-storage-temp (its volume) and resized by stf-storage-plugin-image (gm): a PNG of
# 200x100 red pixels
python3 -c '
import struct, sys, zlib
row = b"\x00" + b"\xff\x00\x00" * 200
chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 200, 100, 8, 2, 0, 0, 0))
  + chunk(b"IDAT", zlib.compress(row * 100)) + chunk(b"IEND", b""))' > "${WORK}/image.png"
xsrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar")"
upload="$(curl -s -b "$jar" --max-time 30 -H "X-XSRF-TOKEN: ${xsrf}" -F "file=@${WORK}/image.png;type=image/png" \
  "${URL}/s/upload/image")"
check_contains "an image is uploaded" '"success":true' "$upload"
href="$(sed -n 's/.*"href":"\([^"]*\)".*/\1/p' <<< "$upload")"
curl -s -b "$jar" --max-time 30 -o "${WORK}/resized.png" "${URL}${href}?crop=50x"
check "the image is resized" "50x25" \
  "$(python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' \
    "${WORK}/resized.png" 2> /dev/null)"

section "authentication of the nodes"
check "the password of RethinkDB is generated" "48" "$(sed -n 's/^RETHINKDB_ENV_AUTHKEY=//p' "${MCLOUD}/variables.env" | tr -d '\n' | wc -c | tr -d ' ')"
check "RethinkDB is not published on the host" "" "$(docker port rethinkdb)"
check "ZeroMQ of the STF units is published for the nodes only" "7160/tcp -> 0.0.0.0:7160" \
  "$(docker port stf-triproxy-app | grep -v '::')"
stf_image="$(docker inspect --format '{{.Config.Image}}' stf-app)"
run_check "RethinkDB refuses a connection without its password" docker run --rm --network infra "$stf_image" \
  node -e "require('rethinkdb').connect({host: 'rethinkdb'}).then(() => process.exit(1), () => process.exit(0))"
if [[ -n "$(sed -n 's/^STF_ZMQ_CURVE_SERVER_SECRET_KEY=//p' "${MCLOUD}/variables.env")" ]]; then
  check_contains "the triproxies are CURVE servers" "CURVE server" "$(docker logs stf-triproxy-dev 2>&1)"
  check_contains "the STF units are CURVE clients" "CURVE client" "$(docker logs stf-processor001 2>&1)"
  # a client with an unknown key sends a message to the triproxy of the devices, which refuses it
  server_key="$(sed -n 's/^STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=//p' "${MCLOUD}/variables.env")"
  docker run --rm --network infra -e STF_ZMQ_CURVE_SERVER_PUBLIC_KEY="$server_key" \
    -e STF_ZMQ_CURVE_SECRET_KEY="$(docker run --rm "$stf_image" stf curve-keygen | sed -n 's/^secret=//p')" "$stf_image" \
    node -e "import('/app/lib/util/zmqutil.js').then(({default: zmqutil}) => {
      const push = zmqutil.socket('push'); push.connect('tcp://stf-triproxy-dev:7270'); push.send('x')
      setTimeout(() => process.exit(0), 3000) })" > /dev/null 2>&1
  check_contains "a node with an unknown key is refused" "Refused the ZeroMQ client" \
    "$(docker logs stf-triproxy-dev 2>&1)"
else
  skip_check "ZeroMQ with CURVE" "the STF image made no CURVE keys (stf curve-keygen)"
fi

section "grid"
# the status of the hub is for the users of STF (/api/v1/zebrunner/hub-auth): an older TAG_STF without it answers 500
if [[ "$(http_code /mcloud/grid/admin/DevicesServlet -b "$jar")" == "500" ]]; then
  skip_check "the status of the hub" "the STF of TAG_STF has no /api/v1/zebrunner/hub-auth"
else
  check "the status of the hub needs a user of STF" "401" "$(http_code /mcloud/wd/hub/status)"
  check_contains "the hub is ready" '"ready"' "$(curl -s -b "$jar" --max-time 10 "${URL}/mcloud/wd/hub/status")"
fi
check "the static files of the grid console" "200" "$(http_code /grid/resources/org/openqa/grid/images/consoleservlet.css)"
check "the content type of the static files" "text/css" \
  "$(curl -s -o /dev/null -w '%{content_type}' --max-time 10 "${URL}/grid/resources/org/openqa/grid/images/consoleservlet.css")"
headers="$(curl -s -o /dev/null -D - --max-time 10 "${URL}/mcloud/wd/hub/status" | tr -d '\r')"
for header in "X-Content-Type-Options: nosniff" "X-Frame-Options: SAMEORIGIN"; do
  check_contains "the hub: ${header}" "$header" "$headers"
done
grid_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' mcloud-grid)"
check_contains "the grid gets STF_TOKEN of variables.env" "STF_TOKEN=" "$grid_env"
for name in SECRET STF_STORAGE_TOKEN RETHINKDB_ENV_AUTHKEY STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SECRET_KEY \
  STF_AUTH_MOCK_BASIC_AUTH_PASSWORD; do
  check "the grid does not get ${name}" "" "$(grep "^${name}=" <<< "$grid_env")"
done
check_contains "the grid gets GRID_AUTH_SECRET of variables.env" \
  "GRID_AUTH_SECRET=$(sed -n 's/^GRID_AUTH_SECRET=//p' "${MCLOUD}/variables.env")" "$grid_env"

section "access to the grid"
# stf-api decides (/api/v1/zebrunner/hub-auth); stf-proxy answers 500 for an STF without it (an older TAG_STF)
if [[ "$(http_code /mcloud/grid/admin/DevicesServlet -b "$jar")" == "500" ]]; then
  skip_check "the access to the grid" "the STF of TAG_STF has no /api/v1/zebrunner/hub-auth"
else
  check "the grid console sends a user without a sign-in to the sign-in of STF" "302" "$(http_code /mcloud/grid/console)"
  check "the grid console of a signed-in user" "200" "$(http_code /mcloud/grid/console -b "$jar")"
  check "the devices of the grid need a user" "401" "$(http_code /mcloud/grid/admin/DevicesServlet)"
  check "the devices of the grid of a signed-in user" "200" "$(http_code /mcloud/grid/admin/DevicesServlet -b "$jar")"
  check "the metrics of the grid are refused to a user" "403" "$(http_code /mcloud/grid/admin/MetricsServlet -b "$jar")"
  session='{"capabilities":{"alwaysMatch":{"platformName":"Android"}}}'
  check "the hub needs an access token" "401" "$(http_code /mcloud/wd/hub/session -X POST -d "$session")"
  check "the hub takes no session cookie" "401" "$(http_code /mcloud/wd/hub/session -X POST -d "$session" -b "$jar")"
  # an access token of the signed-in user (Settings, Keys of STF)
  xsrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar")"
  token="$(curl -s -b "$jar" --max-time 10 -X POST -H "X-XSRF-TOKEN: ${xsrf}" "${URL}/api/v1/user/accessTokens?title=compose-test" |
    sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  check "an access token of the user" "yes" "$([[ -n "$token" ]] && echo yes)"
  # no node: the grid answers that no device matches, after stf-proxy let the request in
  check_contains "the hub takes the access token of the user in the URL" "Empty pool of VM for setup" \
    "$(curl -s --max-time 30 -X POST -H "Content-Type: application/json" -d "$session" \
      "${URL/:\/\//://tester:${token}@}/mcloud/wd/hub/session")"
  check "a wrong access token is refused" "401" \
    "$(http_code /mcloud/wd/hub/session -X POST -d "$session" -u "tester@example.com:wrong-token")"
  check "the devices of the grid with the access token" "200" \
    "$(http_code /mcloud/grid/admin/DevicesServlet -H "Authorization: Bearer ${token}")"
  check "the API of the hub is not for the users" "404" "$(http_code /mcloud/grid/api/hub -H "Authorization: Bearer ${token}")"
  check "the decision about the grid is not a route of the users" "403" \
    "$(http_code /api/v1/zebrunner/hub-auth -H "Authorization: Bearer ${token}")"
  # the grid takes the users of stf-proxy only, not a request of another container of the docker network (a grid of
  # an older TAG_SELENIUM_HUB has no authentication)
  if docker logs mcloud-grid 2>&1 | grep -q 'The hub lets in the users of stf-proxy only'; then
    check "the grid refuses a request without stf-proxy" "401" \
      "$(docker run --rm --network infra "$(docker inspect --format '{{.Config.Image}}' stf-proxy)" \
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-MCloud-User: admin@zebrunner.com" -H "X-MCloud-Admin: true" \
        http://mcloud-grid:4444/grid/admin/DevicesServlet)"
  else
    skip_check "the grid refuses a request without stf-proxy" "the grid of TAG_SELENIUM_HUB has no authentication of the users"
  fi
fi

section "the nodes and the grid"
# an Appium node without a node token registers at the port of the nodes (4446): the grid refuses it (500)
node='{"capabilities": [{"maxInstances": 1, "platformName": "ANDROID", "udid": "compose-test", "deviceName": "Pixel"}],
  "configuration": {"proxy": "com.zebrunner.mcloud.grid.MobileRemoteProxy", "url": "http://192.0.2.1:4723/wd/hub",
  "host": "192.0.2.1", "port": 4723, "id": "http://192.0.2.1:4723", "maxSession": 1, "register": true}}'
check "the grid refuses a node without a node token" "500" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --data-binary "$node" http://127.0.0.1:4446/grid/register)"
check "the hub is not open on the port of the nodes" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:4446/wd/hub/status)"
check "the console is not open on the port of the nodes" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:4446/grid/admin/DevicesServlet)"
check "the check of a node is open on the port of the nodes" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://127.0.0.1:4446/grid/api/proxy?id=http://192.0.2.1:4723')"
check "/lifecycle-manager is not for the users" "404" "$(http_code '/mcloud/lifecycle-manager?action=shutdown')"
sleep 2
check "/lifecycle-manager does not shut the grid down" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 'http://127.0.0.1:4446/grid/api/proxy?id=none')"

section "operations"
check_contains "the logs of the services are rotated" '"max-file":"5","max-size":"50m"' \
  "$(docker inspect --format '{{json .HostConfig.LogConfig.Config}}' stf-app)"
# healthy: every service with a healthcheck; mcloud-grid has the one of its image (called through wait_for)
# shellcheck disable=SC2329
healthy() {
  local service
  for service in stf-proxy stf-app stf-auth stf-api stf-websocket stf-storage-temp stf-storage-plugin-apk \
    stf-storage-plugin-image stf-triproxy-app stf-triproxy-dev stf-processor001 stf-reaper stf-api-groups-engine rethinkdb; do
    [[ "$(docker inspect --format '{{.State.Health.Status}}' "$service")" == "healthy" ]] || return 1
  done
}
run_check "the services with a healthcheck are healthy" wait_for 120 healthy
check "every running service but mcloud-grid has a healthcheck" "" \
  "$(cd "$MCLOUD" && for c in $(docker compose ps --quiet --status running); do
    docker inspect --format '{{.Name}} {{if .State.Health}}health{{end}}' "$c"
  done | grep -v ' health$' | grep -v '^/mcloud-grid ')"
# status <service>: the health status of a service
# shellcheck disable=SC2329
status() {
  docker inspect --format '{{.State.Health.Status}}' "$1"
}
# shellcheck disable=SC2329
unhealthy_processor() {
  [[ "$(status stf-processor001)" == "unhealthy" ]]
}
# shellcheck disable=SC2329
healthy_processor() {
  [[ "$(status stf-processor001)" == "healthy" ]]
}
docker stop stf-triproxy-dev > /dev/null
run_check "a unit cut off from its broker is unhealthy" wait_for 90 unhealthy_processor
docker start stf-triproxy-dev > /dev/null
run_check "a unit connected again is healthy" wait_for 90 healthy_processor
run_check "backup" zbr "" backup
check "backup archives the database" "yes" \
  "$(tar -tzf "${MCLOUD}/backup/rethinkdb.tar.gz" 2> /dev/null | grep -q '^data/' && echo yes || echo no)"
running="$(cd "$MCLOUD" && docker compose ps --services --status running | sort | tr '\n' ' ')"
check "the services run again after the backup" "$expected" "$running"
run_check "STF answers after the backup" wait_for 120 curl -sf --max-time 5 -u "$sign_in" "${URL}/auth/mock/"

section "adb relay"
# the auto mode with the access token of variables.env: adb-relay runs and reads the devices of the nodes with the
# token start made, or reports the empty token (an STF of TAG_STF without stf token-add)
sed -i.orig "s|^ADB_RELAY=.*|ADB_RELAY=true|" "${MCLOUD}/.env"
run_check "start with ADB_RELAY=true" zbr "" start
# shellcheck disable=SC2329 # called through wait_for
healthy_relay() {
  [[ "$(status adb-relay)" == "healthy" ]]
}
run_check "adb-relay is healthy" wait_for 60 healthy_relay
check "adb-relay is in the network of the host" "host" "$(docker inspect --format '{{.HostConfig.NetworkMode}}' adb-relay)"
if [[ -n "$admin_token" ]]; then
  # shellcheck disable=SC2329 # called through wait_for
  relay_read() {
    docker logs adb-relay 2>&1 | grep -q "Android devices of the nodes relayed:"
  }
  run_check "adb-relay reads the devices of the nodes with STF_TOKEN made by start" wait_for 30 relay_read
  check_not_contains "adb-relay has the access token" "STF_TOKEN of variables.env) is empty" "$(docker logs adb-relay 2>&1)"
else
  check_contains "adb-relay reports the empty access token" "The access token of STF (STF_TOKEN of variables.env) is empty" \
    "$(docker logs adb-relay 2>&1)"
fi
# adb-relay goes with the services also when ADB_RELAY is turned off (the shutdown below)
sed -i.orig "s|^ADB_RELAY=.*|ADB_RELAY=false|" "${MCLOUD}/.env"

section "https"
HTTPS="${WORK}/https"
copy_repo "$HTTPS"
# a certificate of the user: the repository has none
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -keyout "${HTTPS}/configuration/stf-proxy/ssl/ssl.key" \
  -out "${HTTPS}/configuration/stf-proxy/ssl/ssl.crt" > /dev/null 2>&1
printf 'https\nlocalhost\n443\ny\n\n\ny\n\nn\n' | /bin/bash "${HTTPS}/zebrunner.sh" setup > /dev/null 2>&1
run_check "the https configuration of nginx with the certificate of the user" \
  docker run --rm -v "${HTTPS}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${HTTPS}/configuration/stf-proxy/grid-auth.conf:/etc/nginx/grid-auth.conf:ro" \
  -v "${HTTPS}/configuration/stf-proxy/ssl:/etc/nginx/ssl:ro" "nginx:$(sed -n 's/^TAG_NGINX=//p' "${HTTPS}/.env")" nginx -t
run_check "the configuration of adb-relay" \
  docker run --rm -e NGINX_ENTRYPOINT_QUIET_LOGS=1 -v "${HTTPS}/configuration/adb-relay/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "nginx:$(sed -n 's/^TAG_NGINX=//p' "${HTTPS}/.env")" nginx -t

section "shutdown"
SHUTDOWN_CONFIRMED=1 zbr "" shutdown > /dev/null
check "shutdown removes the containers" "" "$(docker ps -aq --filter name='^/(stf-proxy|mcloud-grid|rethinkdb|stf-app|adb-relay)$')"
check "shutdown removes the settings" "no" "$([[ -f "${MCLOUD}/.env" ]] && echo yes || echo no)"

finish
