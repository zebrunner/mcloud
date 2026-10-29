#!/bin/bash
# The farm end to end (the e2e job of CI, README.md#development): MCloud of this repository and a device host of
# mcloud-agent (E2E_AGENT_DIR, a checkout) on this machine with an Android emulator, the images of
# tests/e2e/build-images.sh. E2E_ADB_ADDRESS is the adb address of the emulator reachable from the containers
# (host:port), E2E_ADB_KEYS the adb keys it trusts (~/.android), E2E_LOGS the directory of the logs.
# It changes the machine: ports 80 and 7401-7410, the udev rules, zebrunner-farm and the shell profiles of mcloud-agent
# (sudo without a password), the docker volume mcloud-key-volume; for CI and disposable machines only.
source "$(dirname "$0")/../lib.sh"

require_cmd docker
require_cmd ansible-playbook
require_cmd python3

HOST_IP="${E2E_HOST_IP:-$(hostname -I | awk '{print $1}')}"
URL="http://${HOST_IP}"
ADB_ADDRESS="${E2E_ADB_ADDRESS:?the adb address of the emulator, host:port}"
ADB_KEYS="${E2E_ADB_KEYS:-${HOME}/.android}"
AGENT="${E2E_AGENT_DIR:?a checkout of mcloud-agent}"
LOGS="${E2E_LOGS:-${WORK}/logs}"
MCLOUD="${WORK}/mcloud"
APP="https://github.com/appium/android-apidemos/releases/download/v6.0.2/ApiDemos-debug.apk"
MINIO="e2e-minio"
S3_USER="e2e-user"
S3_PASSWORD="e2e-password"
BUCKET="e2e"
mkdir -p "$LOGS"
copy_repo "$MCLOUD"
export ZEBRUNNER_MCLOUD_AGENT_DIR="$AGENT"

# cleanup: the logs of every container, then the device host, MCloud and MinIO are removed
# called by the EXIT trap of lib.sh
# shellcheck disable=SC2329
cleanup() {
  local container
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "${LOGS}/containers.txt" 2>&1
  for container in $(docker ps -a --format '{{.Names}}'); do
    docker logs "$container" > "${LOGS}/${container}.log" 2>&1
  done
  zebrunner-farm down > "${LOGS}/zebrunner-farm-down.log" 2>&1
  (cd "$MCLOUD" && docker compose down -v) > /dev/null 2>&1
  docker rm -f "$MINIO" > /dev/null 2>&1
}

# wait_for <seconds> <command...>: runs the command every 3 seconds until it succeeds, fails after the timeout
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
    sleep 3
  done
}

# value <file> <name>: the value of a variable of an env file (without its quotes)
value() {
  sed -n "s/^$2='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$1"
}

# mcloud <command>: zebrunner.sh of MCloud, its output in the logs
mcloud() {
  bash "${MCLOUD}/zebrunner.sh" "$@" >> "${LOGS}/mcloud.log" 2>&1
}

# stf_up: STF answers through stf-proxy
# shellcheck disable=SC2329
stf_up() {
  curl -sf --max-time 5 -u "$SIGN_IN" "${URL}/auth/mock/"
}

# sign_in: a session of a user of the mock sign-in in the cookie jar ${WORK}/cookies
sign_in() {
  local jar="${WORK}/cookies"
  local xsrf
  local redirect
  rm -f "$jar"
  curl -s -o /dev/null -c "$jar" -u "$SIGN_IN" --max-time 10 "${URL}/auth/mock/"
  xsrf="$(awk '$6 == "XSRF-TOKEN" {print $7}' "$jar")"
  redirect="$(curl -s -b "$jar" -c "$jar" -u "$SIGN_IN" --max-time 10 -H "Content-Type: application/json" \
    -H "X-XSRF-TOKEN: ${xsrf}" -d '{"name":"admin","email":"admin@zebrunner.com"}' "${URL}/auth/api/v1/mock" |
    sed -n 's/.*"redirect":"\([^"]*\)".*/\1/p')"
  curl -s -o /dev/null -b "$jar" -c "$jar" --max-time 10 "$redirect"
}

# xsrf: the XSRF token of the signed-in session
xsrf() {
  awk '$6 == "XSRF-TOKEN" {print $7}' "${WORK}/cookies"
}

# device <python expression of d, the STF device>: the value for the device of the emulator of /api/v1/devices
device() {
  curl -s --max-time 10 -H "Authorization: Bearer ${STF_TOKEN}" "${URL}/api/v1/devices" |
    python3 -c "import json, sys
for d in json.load(sys.stdin)['devices']:
    if d['serial'] == sys.argv[1]:
        print($1)" "$ADB_ADDRESS" 2> /dev/null
}

# stf_ready: the device of the emulator is present and ready in STF
# shellcheck disable=SC2329
stf_ready() {
  [[ "$(device "d.get('present') and d.get('ready')")" == "True" ]]
}

# grid_free: the device of the emulator is registered and free in the grid
# shellcheck disable=SC2329
grid_free() {
  curl -s --max-time 10 "${URL}/mcloud/grid/admin/DevicesServlet" | python3 -c "import json, sys
sys.exit(0 if any(d['udid'] == sys.argv[1] and d['status'] == 'free' for d in json.load(sys.stdin)['value']) else 1)" \
    "$ADB_ADDRESS"
}

# healthy <container suffix...>: the containers of the device are healthy
# shellcheck disable=SC2329
healthy() {
  local suffix
  local container
  for suffix in "$@"; do
    container="$(docker ps --format '{{.Names}}' | grep -E "^device-Emulator-.*-${suffix}$")"
    [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container" 2> /dev/null)" == "healthy" ]] || return 1
  done
}

# s3 <aws arguments...>: the AWS CLI of the uploader image against MinIO
# shellcheck disable=SC2329
s3() {
  docker run --rm --network infra --entrypoint aws -e AWS_ACCESS_KEY_ID="$S3_USER" \
    -e AWS_SECRET_ACCESS_KEY="$S3_PASSWORD" -e AWS_DEFAULT_REGION=us-east-1 "$UPLOADER_IMAGE" \
    --endpoint-url "http://${MINIO}:9000" "$@"
}

# artifacts_uploaded: the artifacts of the session SESSION_ID are in the bucket
# shellcheck disable=SC2329
artifacts_uploaded() {
  s3 s3 ls --recursive "s3://${BUCKET}/artifacts/test-sessions/${SESSION_ID}/" > "${WORK}/artifacts.txt" 2>&1 &&
    [[ -s "${WORK}/artifacts.txt" ]]
}

UPLOADER_IMAGE="public.ecr.aws/zebrunner/uploader:$(sed -n 's/^UPLOADER_VERSION: *//p' "${AGENT}/defaults/main.yml")"

section "MCloud"
# the answers: protocol, host, port, confirmation, admin name and email, confirmation, sign-in, device hosts, no start
printf 'http\n%s\n80\ny\nadmin\nadmin@zebrunner.com\ny\nmock\n%s\nn\n' "$HOST_IP" "$HOST_IP" | mcloud setup
check "setup" "0" "$?"
run_check "start" mcloud start
SIGN_IN="$(value "${MCLOUD}/variables.env" STF_AUTH_MOCK_BASIC_AUTH_USERNAME):$(value "${MCLOUD}/variables.env" STF_AUTH_MOCK_BASIC_AUTH_PASSWORD)"
run_check "STF answers through stf-proxy" wait_for 300 stf_up
sign_in
STF_TOKEN="$(curl -s -b "${WORK}/cookies" --max-time 10 -H "X-XSRF-TOKEN: $(xsrf)" -X POST \
  "${URL}/api/v1/user/accessTokens?title=grid" | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"]["id"])')"
check "an access token of STF for the grid" "true" "$([[ ${#STF_TOKEN} -ge 32 ]] && echo true || echo false)"
sed -i.bak "s/^STF_TOKEN=.*/STF_TOKEN=${STF_TOKEN}/" "${MCLOUD}/variables.env"
[[ "$FAILED" -eq 0 ]] || finish

section "S3"
docker run -d --name "$MINIO" --network infra -e MINIO_ROOT_USER="$S3_USER" -e MINIO_ROOT_PASSWORD="$S3_PASSWORD" \
  docker.io/pgsty/minio:latest server /data > /dev/null
run_check "MinIO answers" wait_for 60 s3 s3 ls
run_check "the bucket of the artifacts" s3 s3 mb "s3://${BUCKET}"

section "device host"
run_check "mcloud-agent setup" bash "${AGENT}/zebrunner.sh" setup
public_key="$(bash "${AGENT}/zebrunner.sh" curve-key 2>&1 | sed -n 's/.*The public key of this host: \([0-9a-f]\{64\}\).*/\1/p')"
check "the CURVE key of the device host" "64" "${#public_key}"
python3 - "${AGENT}/roles/devices/vars/main.yml" "${MCLOUD}/variables.env" "$HOST_IP" "$ADB_ADDRESS" \
  "$MINIO" "$BUCKET" "$S3_USER" "$S3_PASSWORD" << 'EOF'
import re, sys
vars_file, env_file, host, address, minio, bucket, user, password = sys.argv[1:]
env = dict(re.findall(r"^([A-Z_]+)='?([^'\n]*)'?$", open(env_file).read(), re.M))
settings = {
    "PUBLIC_IP": host, "PUBLIC_IP_PORT": "80", "PUBLIC_IP_PROTOCOL": "http", "STF_PROVIDER_HOST": host,
    "STF_STORAGE_TOKEN": '"%s"' % env["STF_STORAGE_TOKEN"],
    "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY": '"%s"' % env["STF_ZMQ_CURVE_SERVER_PUBLIC_KEY"],
    "NODE_REGISTRATION_TOKEN": '"%s"' % env["NODE_REGISTRATION_TOKEN"],
    "S3_BUCKET": bucket, "S3_ENDPOINT": "http://%s:9000" % minio, "S3_ACCESS_KEY_ID": user, "S3_SECRET": password,
    "S3_REGION": "us-east-1",
}
text = open(vars_file).read()
for name, value in settings.items():
    text, count = re.subn(r"^%s:.*$" % name, "%s: %s" % (name, value), text, flags=re.M)
    assert count == 1, name
text = text[:text.index("\ndevices:\n")] + """
devices:
  - id: emulator
    os: android
    name: Emulator
    connection: android-sim
    address: %s
    appium_port: 7401
    adb_port: 7402
    proxy_port: 7403
    server_proxy_port: 7404
    min_port: 7405
    max_port: 7410
""" % address
open(vars_file, "w").write(text)
EOF
check "the settings of MCloud in mcloud-agent" "0" "$?"
sed -i.bak "s/^STF_ZMQ_CURVE_CLIENT_KEYS=.*/STF_ZMQ_CURVE_CLIENT_KEYS=${public_key}/" "${MCLOUD}/variables.env"
run_check "MCloud restarts with the key of the device host and STF_TOKEN" mcloud restart
run_check "STF answers after the restart" wait_for 300 stf_up
# the connector authenticates to the emulator with its adb keys (mcloud-key-volume of the connectors)
docker volume create mcloud-key-volume > /dev/null
docker run --rm -v mcloud-key-volume:/keys -v "${ADB_KEYS}:/host:ro" --entrypoint sh \
  "public.ecr.aws/zebrunner/mcloud-android-connector:$(sed -n 's/^ANDROID_CONNECTOR_VERSION: *//p' "${AGENT}/defaults/main.yml")" \
  -c 'cp /host/adbkey /host/adbkey.pub /keys/'
# the become password of ansible: sudo needs none here
printf '\n' | bash "${AGENT}/zebrunner.sh" ansible > "${LOGS}/ansible.log" 2>&1
check "mcloud-agent ansible" "0" "$?"
zebrunner-farm start > "${LOGS}/zebrunner-farm-start.log" 2>&1
check "zebrunner-farm start" "0" "$?"
run_check "the containers of the device are healthy" wait_for 600 healthy connector stf appium
[[ "$FAILED" -eq 0 ]] || finish

section "device"
run_check "the device is ready in STF" wait_for 300 stf_ready
check "the device is provided by the device host" "mcloud-linux" "$(device "d.get('provider', {}).get('name')")"
run_check "the device is free in the grid" wait_for 300 grid_free
python3 - "${URL}/mcloud/wd/hub" "$ADB_ADDRESS" "$APP" > "${WORK}/session.txt" 2> "${LOGS}/session.err" << 'EOF'
import json, sys, time, urllib.request
hub, udid, app = sys.argv[1:]
def call(method, path, body=None):
    request = urllib.request.Request(hub + path, method=method, headers={"Content-Type": "application/json"},
                                     data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(request, timeout=900) as response:
        return json.load(response)["value"]
caps = {"platformName": "android", "appium:automationName": "UiAutomator2", "appium:udid": udid, "appium:app": app,
        "appium:newCommandTimeout": 120}
session = call("POST", "/session", {"capabilities": {"alwaysMatch": caps}})["sessionId"]
print("session=" + session)
print("source=%d" % ("API Demos" in call("GET", "/session/%s/source" % session)))
print("screenshot=%d" % len(call("GET", "/session/%s/screenshot" % session)))
# the screen changes: the frames of the video
for name in ["Views", "Text", "Graphics", "Animation", "App", "Views"]:
    element = call("POST", "/session/%s/element" % session, {"using": "xpath", "value": "//*[@text='%s']" % name})
    call("POST", "/session/%s/element/%s/click" % (session, list(element.values())[0]), {})
    time.sleep(1)
    call("POST", "/session/%s/back" % session, {})
    time.sleep(1)
print("navigated=1")
call("DELETE", "/session/%s" % session)
print("deleted=1")
EOF
check "an Appium session through the grid installs and starts an app" "0" "$?"
SESSION_ID="$(sed -n 's/^session=//p' "${WORK}/session.txt")"
check "the page source of the app" "1" "$(sed -n 's/^source=//p' "${WORK}/session.txt")"
check "a screenshot of the device" "true" "$([[ "$(sed -n 's/^screenshot=//p' "${WORK}/session.txt")" -gt 1000 ]] && echo true || echo false)"
check "the app is navigated" "1" "$(sed -n 's/^navigated=//p' "${WORK}/session.txt")"
check "the session ends" "1" "$(sed -n 's/^deleted=//p' "${WORK}/session.txt")"
run_check "the device is free again" wait_for 120 grid_free

section "STF"
sign_in
screen="$(device "d['display']['url']")"
check_contains "the screen of the device is served by stf-proxy" "${HOST_IP}" "$screen"
check "the screen WebSocket for a signed-in user" "101" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -b "${WORK}/cookies" -H "Connection: Upgrade" \
    -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "${screen/ws:\/\//http://}")"
python3 -c '
import struct, sys, zlib
row = b"\x00" + b"\xff\x00\x00" * 200
chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 200, 100, 8, 2, 0, 0, 0))
  + chunk(b"IDAT", zlib.compress(row * 100)) + chunk(b"IEND", b""))' > "${WORK}/image.png"
upload="$(curl -s -b "${WORK}/cookies" --max-time 30 -H "X-XSRF-TOKEN: $(xsrf)" \
  -F "file=@${WORK}/image.png;type=image/png" "${URL}/s/upload/image")"
check_contains "an image is uploaded" '"success":true' "$upload"
curl -s -b "${WORK}/cookies" --max-time 30 -o "${WORK}/resized.png" \
  "${URL}$(sed -n 's/.*"href":"\([^"]*\)".*/\1/p' <<< "$upload")?crop=50x"
check "the image is resized" "50x25" \
  "$(python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' \
    "${WORK}/resized.png" 2> /dev/null)"

section "artifacts"
run_check "the artifacts of the session are uploaded to S3" wait_for 300 artifacts_uploaded
check_contains "the video of the session" ".mp4" "$(cat "${WORK}/artifacts.txt" 2> /dev/null)"
cp "${WORK}/artifacts.txt" "${LOGS}/artifacts.txt" 2> /dev/null

finish
