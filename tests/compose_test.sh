#!/bin/bash
# Tests of the services: a copy of the repository is set up and started by zebrunner.sh with the images of
# .env.original (TAG_STF and TAG_SELENIUM_HUB of the environment override them), its endpoints are checked through
# stf-proxy, then it is shut down. The containers have fixed names and ports: no other MCloud may run on this machine.
source "$(dirname "$0")/lib.sh"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker"
docker compose version > /dev/null 2>&1 || skip "requires docker compose"
if [[ -n "$(docker ps -aq --filter name='^/(stf-proxy|mcloud-grid|rethinkdb|stf-app)$')" ]]; then
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
    (cd "$MCLOUD" && docker compose down -v > /dev/null 2>&1)
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

# answers: protocol, host, port, the admin, the sign-in (mock) and the device hosts of the interactive setup: stf-app
# stands for a device host, its screen would be its root page
answers="http\nlocalhost\n${PORT}\ny\n\n\ny\n\nstf-app\nn\n"

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
run_check "the grid answers through stf-proxy" wait_for 120 curl -sf --max-time 5 "${URL}/mcloud/wd/hub/status"
running="$(cd "$MCLOUD" && docker compose ps --services --status running | sort | tr '\n' ' ')"
expected="$(cd "$MCLOUD" && docker compose config --services | grep -vx stf-migrate | sort | tr '\n' ' ')"
check "every service but stf-migrate runs" "$expected" "$running"

section "STF"
check "the app redirects to the sign-in" "302" "$(http_code /)"
check "/stf is the app" "302" "$(http_code /stf)"
check "the mock sign-in needs its password" "401" "$(http_code /auth/mock/)"
check "the mock sign-in page with the password of variables.env" "200" "$(http_code /auth/mock/ -u "$sign_in")"
check "the API needs an access token" "401" "$(http_code /api/v1/user)"
check "the storage refuses a request without the token" "401" "$(http_code /s/blob/none/none)"
check "the storage accepts the token of variables.env" "404" \
  "$(http_code /s/blob/none/none -H "x-stf-internal-token: ${storage_token}")"
check "the apk plugin forwards the credentials" "401" "$(http_code /s/apk/none/none)"
headers="$(curl -s -o /dev/null -D - --max-time 10 -u "$sign_in" "${URL}/auth/mock/" | tr -d '\r')"
check "stf-proxy hides the nginx version" "Server: nginx" "$(grep -i '^server:' <<< "$headers")"
check "no X-Powered-By" "" "$(grep -i '^x-powered-by:' <<< "$headers")"
for header in "Referrer-Policy: no-referrer" "X-Content-Type-Options: nosniff" "X-Frame-Options: SAMEORIGIN" \
  "Content-Security-Policy: frame-ancestors 'self'"; do
  check_contains "STF: ${header}" "$header" "$headers"
done

section "screens of the devices"
check "a host that is not a device host is refused" "403" "$(http_code /d/stf-api/serial/3000/)"
check "the screen needs a signed-in user" "401" "$(http_code /d/stf-app/serial/3000/)"
# the mock sign-in: its page gives the CSRF token, the app takes the token of the sign-in over (STF_URL is stf-proxy)
jar="${WORK}/cookies"
curl -s -o /dev/null -c "$jar" -u "$sign_in" --max-time 10 "${URL}/auth/mock/"
xsrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar")"
redirect="$(curl -s -b "$jar" -c "$jar" -u "$sign_in" --max-time 10 -H "Content-Type: application/json" \
  -H "Accept: application/json" -H "X-XSRF-TOKEN: ${xsrf}" -d '{"name":"tester","email":"tester@example.com"}' \
  "${URL}/auth/api/v1/mock" | sed -n 's/.*"redirect":"\([^"]*\)".*/\1/p')"
curl -s -o /dev/null -b "$jar" -c "$jar" --max-time 10 "${redirect/http:\/\/stf-proxy/$URL}"
check "the screen of a device host for a signed-in user" "200" "$(http_code /d/stf-app/serial/3000/ -b "$jar")"
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

section "authentication of the device hosts"
check "the password of RethinkDB is generated" "48" "$(sed -n 's/^RETHINKDB_ENV_AUTHKEY=//p' "${MCLOUD}/variables.env" | tr -d '\n' | wc -c | tr -d ' ')"
check "RethinkDB is not published on the host" "" "$(docker port rethinkdb)"
check "ZeroMQ of the STF units is published for the device hosts only" "7160/tcp -> 0.0.0.0:7160" \
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
  check_contains "a device host with an unknown key is refused" "Refused the ZeroMQ client" \
    "$(docker logs stf-triproxy-dev 2>&1)"
else
  skip_check "ZeroMQ with CURVE" "the STF image made no CURVE keys (stf curve-keygen)"
fi

section "grid"
check_contains "the hub is ready" '"ready"' "$(curl -s --max-time 10 "${URL}/mcloud/wd/hub/status")"
check "the grid console" "200" "$(http_code /mcloud/grid/console)"
check "the static files of the grid console" "200" "$(http_code /grid/resources/org/openqa/grid/images/consoleservlet.css)"
check "the content type of the static files" "text/css" \
  "$(curl -s -o /dev/null -w '%{content_type}' --max-time 10 "${URL}/grid/resources/org/openqa/grid/images/consoleservlet.css")"
headers="$(curl -s -o /dev/null -D - --max-time 10 "${URL}/mcloud/wd/hub/status" | tr -d '\r')"
for header in "Access-Control-Allow-Origin: *" "X-Content-Type-Options: nosniff" "X-Frame-Options: SAMEORIGIN"; do
  check_contains "the hub: ${header}" "$header" "$headers"
done
check "the devices of the grid" "200" "$(http_code /mcloud/grid/admin/DevicesServlet)"
check_contains "the metrics of the grid" "mcloud_grid_sessions" "$(curl -s --max-time 10 "${URL}/mcloud/grid/admin/MetricsServlet")"
grid_token="$(sed -n 's/^NODE_REGISTRATION_TOKEN=//p' "${MCLOUD}/variables.env")"
check "the grid gets the registration token" "$grid_token" "$(docker exec mcloud-grid printenv NODE_REGISTRATION_TOKEN)"
# a node without the token registers at the port of the device hosts (4446) as Appium does: the grid refuses it (500)
node='{"capabilities": [{"maxInstances": 1, "platformName": "ANDROID", "udid": "compose-test", "deviceName": "Pixel"}],
  "configuration": {"proxy": "com.zebrunner.mcloud.grid.MobileRemoteProxy", "url": "http://192.0.2.1:4723/wd/hub",
  "host": "192.0.2.1", "port": 4723, "id": "http://192.0.2.1:4723", "maxSession": 1, "register": true}}'
check "the grid refuses a node without the registration token" "500" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST --data-binary "$node" http://127.0.0.1:4446/grid/register)"
curl -s -o /dev/null --max-time 10 "${URL}/mcloud/lifecycle-manager?action=shutdown"
sleep 2
check "/lifecycle-manager does not shut the grid down" "200" "$(http_code /mcloud/wd/hub/status)"

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

section "https"
HTTPS="${WORK}/https"
copy_repo "$HTTPS"
# a certificate of the user: the repository has none
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -keyout "${HTTPS}/configuration/stf-proxy/ssl/ssl.key" \
  -out "${HTTPS}/configuration/stf-proxy/ssl/ssl.crt" > /dev/null 2>&1
printf 'https\nlocalhost\n443\ny\n\n\ny\n\n\nn\n' | /bin/bash "${HTTPS}/zebrunner.sh" setup > /dev/null 2>&1
run_check "the https configuration of nginx with the certificate of the user" \
  docker run --rm -v "${HTTPS}/configuration/stf-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${HTTPS}/configuration/stf-proxy/agent-hosts.conf:/etc/nginx/agent-hosts.conf:ro" \
  -v "${HTTPS}/configuration/stf-proxy/ssl:/etc/nginx/ssl:ro" "nginx:$(sed -n 's/^TAG_NGINX=//p' "${HTTPS}/.env")" nginx -t

section "shutdown"
SHUTDOWN_CONFIRMED=1 zbr "" shutdown > /dev/null
check "shutdown removes the containers" "" "$(docker ps -aq --filter name='^/(stf-proxy|mcloud-grid|rethinkdb|stf-app)$')"
check "shutdown removes the settings" "no" "$([[ -f "${MCLOUD}/.env" ]] && echo yes || echo no)"

finish
