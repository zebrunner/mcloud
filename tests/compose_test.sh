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

# answers: protocol, host, port and the admin of the interactive setup
answers="http\nlocalhost\n${PORT}\ny\n\n\ny\n"

section "setup and start"
run_check "setup" zbr "$answers" setup
# the units reach the storage by STF_URL, localhost is the container itself there: stf-proxy of the network instead
sed -i.orig "s|^STF_URL=.*|STF_URL=http://stf-proxy|" "${MCLOUD}/.env"
storage_token="$(sed -n 's/^STF_STORAGE_TOKEN=//p' "${MCLOUD}/variables.env")"
run_check "start" zbr "" start
run_check "the database migration succeeds" \
  bash -c "test \"\$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' stf-migrate)\" == 'exited 0'"
run_check "STF answers through stf-proxy" wait_for 180 curl -sf --max-time 5 "${URL}/auth/mock/"
run_check "the grid answers through stf-proxy" wait_for 120 curl -sf --max-time 5 "${URL}/mcloud/wd/hub/status"
running="$(cd "$MCLOUD" && docker compose ps --services --status running | sort | tr '\n' ' ')"
expected="$(cd "$MCLOUD" && docker compose config --services | grep -vx stf-migrate | sort | tr '\n' ' ')"
check "every service but stf-migrate runs" "$expected" "$running"

section "STF"
check "the app redirects to the sign-in" "302" "$(http_code /)"
check "/stf is the app" "302" "$(http_code /stf)"
check "the mock sign-in page" "200" "$(http_code /auth/mock/)"
check "the API needs an access token" "401" "$(http_code /api/v1/user)"
check "the storage refuses a request without the token" "401" "$(http_code /s/blob/none/none)"
check "the storage accepts the token of variables.env" "404" \
  "$(http_code /s/blob/none/none -H "x-stf-internal-token: ${storage_token}")"
check "the apk plugin forwards the credentials" "401" "$(http_code /s/apk/none/none)"
check "stf-proxy hides the nginx version" "Server: nginx" \
  "$(curl -s -o /dev/null -D - --max-time 10 "${URL}/auth/mock/" | tr -d '\r' | grep -i '^server:')"

section "grid"
check_contains "the hub is ready" '"ready"' "$(curl -s --max-time 10 "${URL}/mcloud/wd/hub/status")"
check "the grid console" "200" "$(http_code /mcloud/grid/console)"
check "the static files of the grid console" "200" "$(http_code /grid/resources/org/openqa/grid/images/consoleservlet.css)"
check "the devices of the grid" "200" "$(http_code /mcloud/grid/admin/DevicesServlet)"
check_contains "the metrics of the grid" "mcloud_grid_sessions" "$(curl -s --max-time 10 "${URL}/mcloud/grid/admin/MetricsServlet")"

section "shutdown"
SHUTDOWN_CONFIRMED=1 zbr "" shutdown > /dev/null
check "shutdown removes the containers" "" "$(docker ps -aq --filter name='^/(stf-proxy|mcloud-grid|rethinkdb|stf-app)$')"
check "shutdown removes the settings" "no" "$([[ -f "${MCLOUD}/.env" ]] && echo yes || echo no)"

finish
