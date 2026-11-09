#!/bin/bash
# Tests of zebrunner.sh: its commands on a copy of the repository; docker and curl are stubs, docker only records
# its calls (the services themselves are checked by tests/compose_test.sh).
source "$(dirname "$0")/lib.sh"
# shellcheck source=../patch/utility.sh
source "${REPO}/patch/utility.sh"

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"

# the stub body is expanded when the stub runs; NO_NETWORK=1: the infra network is missing; `compose ps` prints
# ${STUB_DIR}/running
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1 $2" == "network inspect" && "$NO_NETWORK" == "1" ]] && exit 1
[[ "$1 $2" == "compose ps" ]] && cat "${STUB_DIR}/running" 2> /dev/null
exit 0'
stub curl 'echo 203.0.113.10'

# zbr <stdin text> <zebrunner.sh arguments...>: runs zebrunner.sh of the copy without the user's environment,
# with the NAME=value items of the zbr_env array
zbr_env=()
zbr() {
  local input="$1"
  shift
  printf '%b' "$input" | env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" \
    "${zbr_env[@]}" /bin/bash "${MCLOUD}/zebrunner.sh" "$@" 2>&1
}

# mode <file>: the permissions of a file of the copy, as ls shows them (-rw-------)
mode() {
  # shellcheck disable=SC2012 # one known file, ls is the same on Linux and macOS
  ls -l "${MCLOUD}/$1" | cut -c1-10
}

# inode <file>: the inode of a file of the copy, the bind mount of a file sees a file written in place only
inode() {
  # shellcheck disable=SC2012 # one known file, ls is the same on Linux and macOS
  ls -i "${MCLOUD}/$1" | awk '{print $1}'
}

# value <file> <name>: the value of a variable of an env file of the copy
value() {
  sed -n "s/^$2=//p" "${MCLOUD}/$1"
}

# curve_keys: ok when variables.env has the CURVE keys of a new deployment, 64 hex characters, the public key of the
# triproxies the one of their secret key (X25519 of patch/curve_keygen.py, the check of the keys of openssl too)
curve_keys() {
  local public
  local secret
  local units
  public="$(value variables.env STF_ZMQ_CURVE_SERVER_PUBLIC_KEY)"
  secret="$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
  units="$(value variables.env STF_ZMQ_CURVE_SECRET_KEY)"
  if [[ "$secret" =~ ^[0-9a-f]{64}$ && "$units" =~ ^[0-9a-f]{64}$ && "$units" != "$secret" &&
    "public=${public}" == "$(python3 "${REPO}/patch/curve_keygen.py" "$secret" | head -1)" ]]; then
    echo ok
  fi
}

# the answers of the interactive setup: protocol, host, port, confirmation, admin name, admin email, confirmation,
# the sign-in and the device hosts of the previous setup, no start of the services
answers() {
  printf '%s\n' "$1" "$2" "$3" y "$4" "$5" y "" "" n
}

# certificate <directory> <host>: a self-signed certificate and its key as ssl.crt and ssl.key of the directory
certificate() {
  mkdir -p "$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$2" -keyout "$1/ssl.key" -out "$1/ssl.crt" > /dev/null 2>&1
}

section "help"
output="$(zbr "" --help)"
check "--help succeeds" "0" "$?"
check_contains "help shows the usage" "Usage: ./zebrunner.sh [option]" "$output"
for command in setup start stop restart down shutdown backup restore version; do
  check_contains "help lists ${command}" "          ${command} " "$output"
done
zbr "" unknown > /dev/null
check "an unknown command fails" "1" "$?"

section "setup"
output="$(zbr "$(answers "" mcloud.example.com "" "" "")" setup)"
check "the setup succeeds" "0" "$?"
check "STF_URL of .env" "http://mcloud.example.com:80" "$(value .env STF_URL)"
check "STF_PORT of .env" "80" "$(value .env STF_PORT)"
check "the mock sign-in" "auth-mock" "$(value .env AUTH_SYSTEM)"
check "the image tags of .env.original" "$(grep '^TAG_' "${REPO}/.env.original")" "$(grep '^TAG_' "${MCLOUD}/.env")"
check "STF_URL of variables.env" "http://mcloud.example.com:80" "$(value variables.env STF_URL)"
secret="$(value variables.env SECRET)"
storage_token="$(value variables.env STF_STORAGE_TOKEN)"
check "a new SECRET is generated" "48" "${#secret}"
check "STF_STORAGE_TOKEN is generated" "64" "${#storage_token}"
check "the admin name" "admin" "$(value variables.env STF_ADMIN_NAME)"
check "the admin email" "admin@zebrunner.com" "$(value variables.env STF_ADMIN_EMAIL)"
check "no Zebrunner sign-in" "" "$(value variables.env ZEBRUNNER_LOGIN_URL)"
check "variables.env ends with a newline" "" "$(tail -c 1 "${MCLOUD}/variables.env")"
check_contains "the token for mcloud-agent is explained" "STF_STORAGE_TOKEN of mcloud-agent" "$output"
check "the mock sign-in by default" "auth-mock:auth/mock/" "$(value .env AUTH_SYSTEM):$(value .env AUTH_URL)"
check "no device host by default" "" "$(value .env AGENT_HOSTS)"
check "stf-proxy serves no screen without the device hosts" "" "$(cat "${MCLOUD}/configuration/stf-proxy/agent-hosts.conf")"
check_contains "the missing device hosts are reported" "AGENT_HOSTS of .env is empty" "$output"
check "no adb relay by default" "" "$(value .env ADB_RELAY_HOSTS)"
check "adb-relay has no server without the relay hosts" "" "$(cat "${MCLOUD}/configuration/adb-relay/relay-hosts.conf")"
check "no access token for adb-relay without its auto mode" "" "$(cat "${MCLOUD}/configuration/adb-relay/stf-token")"
check "the token file of adb-relay is readable for its owner only" "-rw-------" "$(mode configuration/adb-relay/stf-token)"
check_not_contains "no warning of the optional adb relay" "ADB_RELAY_HOSTS" "$output"
check "the mock sign-in is behind the basic authentication" "true" "$(value variables.env STF_AUTH_MOCK_USE_BASIC_AUTH)"
check "the user of the basic authentication" "'mcloud'" "$(value variables.env STF_AUTH_MOCK_BASIC_AUTH_USERNAME)"
mock_password="$(value variables.env STF_AUTH_MOCK_BASIC_AUTH_PASSWORD)"
check "the password of the basic authentication is generated" "26" "${#mock_password}"
check_contains "the password of the sign-in is shown" "the password ${mock_password}" "$output"
check "the nginx configuration is the original one for http" "same" \
  "$(cmp -s "${MCLOUD}/configuration/stf-proxy/nginx.conf" "${REPO}/configuration/stf-proxy/nginx.conf.original" && echo same)"
check_contains "the settings are saved" 'ZBR_HOSTNAME="mcloud.example.com"' "$(cat "${MCLOUD}/backup/settings.env")"
check_not_contains "the CURVE keys need no docker" "run|" "$(calls docker)"
keys="$(printf '%064d' 0)"
check "the CURVE keys of the triproxies and of the STF units" "ok" "$(curve_keys)"
server_secret="$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "no device host yet" "" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
check "no key of a device host yet" "" "$(grep '^STF_ZMQ_CURVE_CLIENT_KEY_' "${MCLOUD}/variables.env")"
check_contains "the key of a device host is one line per host" "STF_ZMQ_CURVE_CLIENT_KEY_<HOST>=<key>" "$output"
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated" "48" "${#password}"
check "variables.env is readable for its owner only" "-rw-------" "$(mode variables.env)"
check "backup/settings.env is readable for its owner only" "-rw-------" "$(mode backup/settings.env)"
check_contains ".env is readable" "-rw-r" "$(mode .env)"
check "the ports of the device hosts are published on every address" "0.0.0.0" "$(value .env AGENTS_ADDRESS)"
check_contains "the key for mcloud-agent is explained" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of mcloud-agent" "$output"
grid_token="$(value variables.env NODE_REGISTRATION_TOKEN)"
check "the registration token of the grid is generated" "48" "${#grid_token}"
check_contains "the registration token for mcloud-agent is explained" "NODE_REGISTRATION_TOKEN of mcloud-agent" "$output"
check_contains "the start is suggested" "need to be started after setup" "$output"

section "setup again"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
replace "${MCLOUD}/variables.env" "STF_ZMQ_CURVE_CLIENT_KEYS=" "STF_ZMQ_CURVE_CLIENT_KEYS=${keys//0/e},${keys//0/f}"
printf '%s\n' "STF_ZMQ_CURVE_CLIENT_KEY_ANDROID_01=${keys//0/a}" "STF_SESSION_TTL_SECONDS=3600" >> "${MCLOUD}/variables.env"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.5"
replace "${MCLOUD}/.env" "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=200m"
replace "${MCLOUD}/.env" "ADB_RELAY_HOSTS=" "ADB_RELAY_HOSTS=192.168.30.2:7404,192.168.30.2:7464"
reset_calls
output="$(zbr "$(answers "" "" 8082 "" ops@example.com)" setup)"
check "the setup again calls no docker" "" "$(calls docker)"
check "the password of RethinkDB is kept" "$password" "$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the CURVE keys are kept" "$server_secret" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "the registration token of the grid is kept" "$grid_token" "$(value variables.env NODE_REGISTRATION_TOKEN)"
check "the keys of the device hosts are kept" "${keys//0/e},${keys//0/f}" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
check "the key of a device host of its own variable is kept" "${keys//0/a}" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEY_ANDROID_01)"
check "a variable added to variables.env is kept" "3600" "$(value variables.env STF_SESSION_TTL_SECONDS)"
check "the address of the ports of the device hosts is kept" "10.0.0.5" "$(value .env AGENTS_ADDRESS)"
check "the size of the log files is kept" "200m" "$(value .env LOG_MAX_SIZE)"
check "the default number of the log files" "5" "$(value .env LOG_MAX_FILE)"
check "the relay hosts are kept" "192.168.30.2:7404,192.168.30.2:7464" "$(value .env ADB_RELAY_HOSTS)"
check_contains "the setup writes the relay of the relay hosts" "proxy_pass 192.168.30.2:" \
  "$(cat "${MCLOUD}/configuration/adb-relay/relay-hosts.conf")"
replace "${MCLOUD}/.env" "ADB_RELAY_HOSTS=192.168.30.2:7404,192.168.30.2:7464" "ADB_RELAY_HOSTS="
check "the previous host is the default" "http://mcloud.example.com:8082" "$(value .env STF_URL)"
check "the new port" "8082" "$(value .env STF_PORT)"
check "SECRET is kept" "$secret" "$(value variables.env SECRET)"
check "STF_STORAGE_TOKEN is kept" "$storage_token" "$(value variables.env STF_STORAGE_TOKEN)"
check "STF_TOKEN is kept" "api-token" "$(value variables.env STF_TOKEN)"
check "the new admin email" "ops@example.com" "$(value variables.env STF_ADMIN_EMAIL)"

check "the password of the sign-in is kept" "$mock_password" "$(value variables.env STF_AUTH_MOCK_BASIC_AUTH_PASSWORD)"

replace "${MCLOUD}/variables.env" "SECRET=${secret}" "SECRET=password"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
secret="$(value variables.env SECRET)"
check "the placeholder SECRET is generated" "48" "${#secret}"
replace "${MCLOUD}/variables.env" "SECRET=${secret}" "SECRET="
zbr "$(answers "" "" "" "" "")" setup > /dev/null
secret="$(value variables.env SECRET)"
check "an empty SECRET is generated" "48" "${#secret}"
check "the added variables are added once" "1" "$(grep -c '^STF_ZMQ_CURVE_CLIENT_KEY_ANDROID_01=' "${MCLOUD}/variables.env")"

section "setup without the secrets"
for name in RETHINKDB_ENV_AUTHKEY STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY \
  NODE_REGISTRATION_TOKEN; do
  sed -i.orig "/^${name}=/d" "${MCLOUD}/variables.env"
done
output="$(zbr "$(answers "" "" "" "" "")" setup)"
authkey="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the missing password of RethinkDB is generated" "48" "${#authkey}"
check "the missing CURVE keys are made" "ok" "$(curve_keys)"
grid_token="$(value variables.env NODE_REGISTRATION_TOKEN)"
check "the missing registration token of the grid is generated" "48" "${#grid_token}"
check "the keys of the device hosts are kept" "${keys//0/e},${keys//0/f}" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
check_contains "the registration token for mcloud-agent is explained" "NODE_REGISTRATION_TOKEN of mcloud-agent" "$output"

section "setup questions"
SSL="${MCLOUD}/configuration/stf-proxy/ssl"
cp "${MCLOUD}/.env" "${WORK}/env.saved"
output="$(zbr "\n\n\nn\nhttps\n\n\ny\n\n\ny\n\n\nn\n" setup)"
check "https without a certificate fails" "1" "$?"
check_contains "the certificate is asked for" "put it into configuration/stf-proxy/ssl/ssl.crt" "$output"
check "nothing is written without a certificate" "same" "$(cmp -s "${MCLOUD}/.env" "${WORK}/env.saved" && echo same)"
certificate "$SSL" mcloud.example.com
cp "${SSL}/ssl.crt" "${WORK}/ssl.crt"
output="$(zbr "\n\n\nn\nhttps\n\n\ny\n\n\ny\n\n\nn\n" setup)"
check "a declined address is asked again" "https://mcloud.example.com:8082" "$(value .env STF_URL)"
check "the key of the certificate is readable for its owner only" "-rw-------" "$(mode configuration/stf-proxy/ssl/ssl.key)"
check_contains "https listens with ssl" "listen 80 ssl;" "$(cat "${MCLOUD}/configuration/stf-proxy/nginx.conf")"
check_contains "the ssl settings are uncommented" $'\n    ssl_certificate /etc/nginx/ssl/ssl.crt;' \
  "$(cat "${MCLOUD}/configuration/stf-proxy/nginx.conf")"
check "the certificate of the user is kept" "same" "$(cmp -s "${SSL}/ssl.crt" "${WORK}/ssl.crt" && echo same)"
certificate "${WORK}/other" other.example.com
cp "${WORK}/other/ssl.key" "${SSL}/ssl.key"
output="$(zbr "$(answers "" "" "" "" "")" setup)"
check "a key of another certificate fails" "1" "$?"
check_contains "a key of another certificate is reported" "is not the key of" "$output"
cp "${REPO}/tests/fixtures/shared-ssl.crt" "${SSL}/ssl.crt"
output="$(zbr "$(answers "" "" "" "" "")" setup)"
check "the shared self-signed certificate fails" "1" "$?"
check_contains "the shared self-signed certificate is reported" "its private key is public" "$output"
rm -f "${SSL}/ssl.crt" "${SSL}/ssl.key"
zbr "$(answers http "" "" "" "")" setup > /dev/null
check "http needs no certificate" "http://mcloud.example.com:8082" "$(value .env STF_URL)"
# invalid answers are asked again: a protocol, a host with a port and a host with the protocol, a port of letters and
# one too big; the end of the input with an invalid value fails
output="$(zbr "ftp\nhttp\nmcloud.example.com:80\nhttp://mcloud.example.com\nmcloud.example.com\nabc\n70000\n8080\ny\n\n\ny\n\n\nn\n" setup)"
check "invalid answers are asked again" "http://mcloud.example.com:8080" "$(value .env STF_URL)"
check_contains "an invalid protocol is explained" "Please answer http or https." "$output"
check_contains "an invalid host is explained" "A host name or an IP address only" "$output"
check_contains "an invalid port is explained" "A port number from 1 to 65535." "$output"
check "the port is written" "8080" "$(value .env STF_PORT)"
zbr "$(answers "" "" 8082 "" "")" setup > /dev/null
# an invalid host of the previous setup (or none, when ifconfig.me does not answer) and no more input
cp "${MCLOUD}/backup/settings.env" "${WORK}/settings.saved"
echo 'declare -x ZBR_HOSTNAME="bad host"' >> "${MCLOUD}/backup/settings.env"
output="$(zbr "\n" setup)"
check "the end of the input with an invalid value fails" "1" "$?"
check_contains "the invalid host is reported" "A host name or an IP address only" "$output"
mv "${WORK}/settings.saved" "${MCLOUD}/backup/settings.env"

section "device hosts"
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y "" "bad/host" "agent1.example.com, 10.0.0.7" n)" setup)"
check_contains "a host with a slash is asked again" "Host names and addresses separated by commas only." "$output"
check "the device hosts" "agent1.example.com,10.0.0.7" "$(value .env AGENT_HOSTS)"
check "stf-proxy serves the screens of the device hosts" '"agent1.example.com" 1;
"10.0.0.7" 1;' "$(cat "${MCLOUD}/configuration/stf-proxy/agent-hosts.conf")"
check_not_contains "no warning with device hosts" "AGENT_HOSTS of .env is empty" "$output"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "the device hosts are kept by the next setup" "agent1.example.com,10.0.0.7" "$(value .env AGENT_HOSTS)"
replace "${MCLOUD}/.env" "AGENT_HOSTS=agent1.example.com,10.0.0.7" "AGENT_HOSTS=agent2.example.com,bad/host"
output="$(zbr "" start)"
check "start writes the device hosts of .env" '"agent2.example.com" 1;' \
  "$(cat "${MCLOUD}/configuration/stf-proxy/agent-hosts.conf")"
check_contains "start skips an invalid host" "'bad/host' of AGENT_HOSTS of .env is not a host name" "$output"
replace "${MCLOUD}/.env" "AGENT_HOSTS=agent2.example.com,bad/host" "AGENT_HOSTS=agent1.example.com"
zbr "" start > /dev/null
# a file of root (sudo ./zebrunner.sh): root writes any file, so the check runs for another user only
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 444 "${MCLOUD}/configuration/stf-proxy/agent-hosts.conf"
  output="$(zbr "" start)"
  chmod 644 "${MCLOUD}/configuration/stf-proxy/agent-hosts.conf"
  check_contains "a file of the device hosts that is not writable is reported" \
    "configuration/stf-proxy/agent-hosts.conf is not writable" "$output"
  check_not_contains "it is not reported as no device hosts" "AGENT_HOSTS of .env is empty" "$output"
  check_not_contains "no shell error" "Permission denied" "$output"
else
  skip_check "a file of the device hosts that is not writable" "root writes any file"
fi

section "adb relay"
relay="${MCLOUD}/configuration/adb-relay/relay-hosts.conf"
# relay_hosts <value>: ADB_RELAY_HOSTS of .env
relay_hosts() {
  sed -i.orig "s|^ADB_RELAY_HOSTS=.*|ADB_RELAY_HOSTS=$1|" "${MCLOUD}/.env"
}
reset_calls
zbr "" start > /dev/null
check "start without the relay hosts starts no adb-relay" "network|inspect|infra
compose|up|-d" "$(calls docker)"
# the remote debug ports of the devices: a single port per entry, a device host in several entries
relay_hosts "192.168.30.2:7404, 192.168.30.2:7464,192.168.30.3:7704"
reset_calls
output="$(zbr "" start)"
check "start with the relay hosts starts adb-relay too" "network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
# shellcheck disable=SC2016 # $server_port of nginx
check "a server of adb-relay for every port" 'server {
  listen 7404 so_keepalive=on;
  proxy_pass 192.168.30.2:$server_port;
}
server {
  listen 7464 so_keepalive=on;
  proxy_pass 192.168.30.2:$server_port;
}
server {
  listen 7704 so_keepalive=on;
  proxy_pass 192.168.30.3:$server_port;
}' "$(cat "$relay")"
check_not_contains "no warning with the remote debug ports" "ADB_RELAY_HOSTS" "$output"
relay_hosts "192.168.30.2:7400-7699,192.168.30.3:7700-7700"
output="$(zbr "" start)"
# shellcheck disable=SC2016 # $server_port of nginx
check "a range and a range of one port" 'server {
  listen 7400-7699 so_keepalive=on;
  proxy_pass 192.168.30.2:$server_port;
}
server {
  listen 7700 so_keepalive=on;
  proxy_pass 192.168.30.3:$server_port;
}' "$(cat "$relay")"
check_contains "a range is relayed with a warning about the screens" \
  "'192.168.30.2:7400-7699' of ADB_RELAY_HOSTS of .env is a range: it also makes the screens of the devices public" "$output"
check_contains "the warning suggests the remote debug ports" "Relay only the remote debug ports, min_port + 1 of every Android device" "$output"
check_not_contains "no warning for a range of one port" "'192.168.30.3:7700-7700' of ADB_RELAY_HOSTS" "$output"
relay_hosts "agent1.lan:9000"
zbr "" start > /dev/null
# shellcheck disable=SC2016 # the variables of nginx and of the template of its image
check "a host name with the resolvers of the host" 'resolver ${NGINX_LOCAL_RESOLVERS} valid=30s ipv6=off;
server {
  listen 9000 so_keepalive=on;
  proxy_pass agent1.lan:$server_port;
}' "$(cat "$relay")"
relay_hosts "192.168.30.2:7404,192.168.30.3:7404,192.168.30.2:7404,192.168.30.3:7405"
output="$(zbr "" start)"
check_contains "the same port of another device host is skipped" \
  "'192.168.30.3:7404' of ADB_RELAY_HOSTS of .env has a port of '192.168.30.2:7404'" "$output"
check_contains "the same entry twice is skipped" \
  "'192.168.30.2:7404' of ADB_RELAY_HOSTS of .env has a port of '192.168.30.2:7404'" "$output"
check "a port is relayed once" "7404 so_keepalive=on;
7405 so_keepalive=on;" "$(sed -n 's/^  listen //p' "$relay")"
stf_port="$(value .env STF_PORT)"
stf_ports="$((stf_port - 1))-$((stf_port + 1))"
relay_hosts "192.168.30.2:7400-7799,bad,10.0.0.1:,10.0.0.1:7400-,host/x:9000-9001,999.1.1.1:9000-9001,1.2.3:9000,\
10.0.0.1:80-90,10.0.0.1:80,10.0.0.1:7500-7400,10.0.0.1:65000-70000,10.0.0.1:70000,10.0.0.9:7700-7900,10.0.0.9:7790,\
10.0.0.9:7100-7200,10.0.0.9:7160,10.0.0.9:${stf_ports},10.0.0.9:4440-4450,10.0.0.10:9000"
reset_calls
output="$(zbr "" start)"
for entry in bad 10.0.0.1: 10.0.0.1:7400- host/x:9000-9001 999.1.1.1:9000-9001 1.2.3:9000; do
  check_contains "${entry} is not a relay host" \
    "'${entry}' of ADB_RELAY_HOSTS of .env is not <host>:<port> or <host>:<first port>-<last port>" "$output"
done
for entry in 10.0.0.1:80-90 10.0.0.1:80 10.0.0.1:7500-7400 10.0.0.1:65000-70000 10.0.0.1:70000; do
  check_contains "the ports of ${entry} are invalid" "'${entry}' of ADB_RELAY_HOSTS of .env: the ports are 1024-65535" "$output"
done
check_contains "an overlapping range is skipped" \
  "'10.0.0.9:7700-7900' of ADB_RELAY_HOSTS of .env has a port of '192.168.30.2:7400-7799'" "$output"
check_contains "a port in an earlier range is skipped" \
  "'10.0.0.9:7790' of ADB_RELAY_HOSTS of .env has a port of '192.168.30.2:7400-7799'" "$output"
check_contains "a range with a port of ZeroMQ of STF is skipped" "'10.0.0.9:7100-7200' of ADB_RELAY_HOSTS of .env holds the port 7160 of MCloud" "$output"
check_contains "a port of ZeroMQ of STF is skipped" "'10.0.0.9:7160' of ADB_RELAY_HOSTS of .env holds the port 7160 of MCloud" "$output"
check_contains "a range with STF_PORT is skipped" \
  "'10.0.0.9:${stf_ports}' of ADB_RELAY_HOSTS of .env holds the port ${stf_port} of MCloud" "$output"
check_contains "a range with the port of the grid is skipped" "'10.0.0.9:4440-4450' of ADB_RELAY_HOSTS of .env holds the port 4446 of MCloud" "$output"
check "only the valid relay hosts are written" "192.168.30.2:\$server_port;
10.0.0.10:\$server_port;" "$(sed -n 's/^  proxy_pass //p' "$relay")"
check "adb-relay starts with the valid relay hosts" "network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
relay_hosts "bad,10.0.0.1:80-90"
reset_calls
output="$(zbr "" start)"
check "no valid relay host: no server" "" "$(cat "$relay")"
check_contains "no valid relay host is reported" "ADB_RELAY_HOSTS of .env has no valid entry: adb-relay does not run" "$output"
check "no valid relay host: no adb-relay" "network|inspect|infra
compose|up|-d" "$(calls docker)"
relay_hosts ""
zbr "" start > /dev/null
check "cleared relay hosts: no server" "" "$(cat "$relay")"
relay_hosts "192.168.30.2:7404,192.168.30.2:7464"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "the setup keeps the relay hosts" "192.168.30.2:7404,192.168.30.2:7464" "$(value .env ADB_RELAY_HOSTS)"
check_contains "the setup writes the servers of adb-relay" "listen 7464 so_keepalive=on;" "$(cat "$relay")"
# a file of root (sudo ./zebrunner.sh): root writes any file, so the check runs for another user only
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 444 "$relay"
  reset_calls
  output="$(zbr "" start)"
  chmod 644 "$relay"
  check_contains "a file of adb-relay that is not writable is reported" \
    "configuration/adb-relay/relay-hosts.conf is not writable" "$output"
  check_not_contains "no shell error for adb-relay" "Permission denied" "$output"
  check "adb-relay keeps the servers it has" "network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
else
  skip_check "a file of adb-relay that is not writable" "root writes any file"
fi
relay_hosts ""
zbr "" start > /dev/null

section "adb relay of the devices of STF"
# relay_setting <name> <value>: a setting of the auto mode of adb-relay in .env
relay_setting() {
  sed -i.orig "s|^$1=.*|$1=$2|" "${MCLOUD}/.env"
}
check "the auto mode is off by default" "false:300:" \
  "$(sed -n 's/^ADB_RELAY=//p' "${REPO}/.env.original"):$(value .env ADB_RELAY_SYNC_SECONDS):$(value .env ADB_RELAY_PORTS)"
relay_setting ADB_RELAY true
reset_calls
output="$(zbr "" start)"
check "the auto mode starts adb-relay without relay hosts" "network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
check "no server of ADB_RELAY_HOSTS" "" "$(cat "$relay")"
token_file="${MCLOUD}/configuration/adb-relay/stf-token"
check "the auto mode gets STF_TOKEN of variables.env only" "api-token" "$(cat "$token_file")"
check "the token file is readable for its owner only" "-rw-------" "$(mode configuration/adb-relay/stf-token)"
token_inode="$(inode configuration/adb-relay/stf-token)"
replace "${MCLOUD}/variables.env" "STF_TOKEN=api-token" "STF_TOKEN='new-token'"
chmod 644 "$token_file"
zbr "" start > /dev/null
check "start writes a new STF_TOKEN without the quotes" "new-token" "$(cat "$token_file")"
check "the token file is written in place" "$token_inode" "$(inode configuration/adb-relay/stf-token)"
check "start makes the token file readable for its owner only again" "-rw-------" "$(mode configuration/adb-relay/stf-token)"
replace "${MCLOUD}/variables.env" "STF_TOKEN='new-token'" "STF_TOKEN=api-token"
rm -f "$token_file"
zbr "" restart > /dev/null
check "restart writes a missing token file for its owner only" "api-token:-rw-------" \
  "$(cat "$token_file"):$(mode configuration/adb-relay/stf-token)"
check_not_contains "no warning of the auto mode with its settings" "adb-relay" "$output"
relay_setting ADB_RELAY_PORTS 7400-7799
relay_setting ADB_RELAY_SYNC_SECONDS 10
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "the setup keeps the settings of the auto mode" "true:7400-7799:10" \
  "$(value .env ADB_RELAY):$(value .env ADB_RELAY_PORTS):$(value .env ADB_RELAY_SYNC_SECONDS)"
for value in 7400 80-90 7799-7400 x; do
  relay_setting ADB_RELAY_PORTS "$value"
  check_contains "ADB_RELAY_PORTS '${value}' is reported" \
    "ADB_RELAY_PORTS of .env '${value}' is not <first>-<last> of the ports 1024-65535: adb-relay relays no device of STF." \
    "$(zbr "" start)"
done
relay_setting ADB_RELAY_PORTS ""
relay_setting ADB_RELAY_SYNC_SECONDS 0
check_contains "an invalid ADB_RELAY_SYNC_SECONDS is reported" \
  "ADB_RELAY_SYNC_SECONDS of .env '0' is not a number of seconds: adb-relay reads the devices every 300 seconds." "$(zbr "" start)"
relay_setting ADB_RELAY_SYNC_SECONDS 30
replace "${MCLOUD}/variables.env" "STF_TOKEN=api-token" "STF_TOKEN="
replace "${MCLOUD}/.env" "AGENT_HOSTS=agent1.example.com" "AGENT_HOSTS="
output="$(zbr "" start)"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
replace "${MCLOUD}/.env" "AGENT_HOSTS=" "AGENT_HOSTS=agent1.example.com"
check_contains "the auto mode without STF_TOKEN is reported" \
  "STF_TOKEN of variables.env is empty: adb-relay (ADB_RELAY=true) relays no device of STF." "$output"
check_contains "the auto mode without AGENT_HOSTS is reported" \
  "AGENT_HOSTS of .env is empty: adb-relay (ADB_RELAY=true) relays no device of STF." "$output"
relay_setting ADB_RELAY yes
reset_calls
output="$(zbr "" start)"
check_contains "an invalid ADB_RELAY is reported" "ADB_RELAY of .env is 'yes', not true or false: the auto mode of adb-relay is off." "$output"
check "an invalid ADB_RELAY starts no adb-relay" "network|inspect|infra
compose|up|-d" "$(calls docker)"
relay_setting ADB_RELAY false
reset_calls
zbr "" start > /dev/null
check "ADB_RELAY=false starts no adb-relay" "network|inspect|infra
compose|up|-d" "$(calls docker)"
check "ADB_RELAY=false empties the token file" "" "$(cat "$token_file")"
if docker compose version > /dev/null 2>&1; then
  relay_setting ADB_RELAY true
  relay_setting ADB_RELAY_PORTS 7400-7799
  check "docker compose passes the settings of the auto mode to adb-relay" "ADB_RELAY: \"true\"
ADB_RELAY_PORTS: 7400-7799
ADB_RELAY_SYNC_SECONDS: \"30\"
AGENT_HOSTS: agent1.example.com" \
    "$(cd "$MCLOUD" && docker compose --profile adb-relay config 2> /dev/null |
      sed -n '/^  adb-relay:/,/^  [a-z]/p' | grep -E '^      (ADB_RELAY|AGENT_HOSTS)' | sed 's/^ *//')"
  relay_setting ADB_RELAY false
  relay_setting ADB_RELAY_PORTS ""
else
  skip_check "docker compose passes the settings of the auto mode to adb-relay" "requires docker compose"
fi

section "sign-in"
# the answers: the sign-in, its settings with a secret, a scope, a domain of the users, no start; the secret is literal
# shellcheck disable=SC2016
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y oauth2 https://idp.example.com/authorize https://idp.example.com/token \
  https://idp.example.com/userinfo mcloud-client "it's" 'a$b&c d' "" example.com "" n)" setup)"
check "the OAuth2 sign-in" "auth-oauth2:auth/oauth/" "$(value .env AUTH_SYSTEM):$(value .env AUTH_URL)"
check_contains "the callback URL is shown" "redirects to http://mcloud.example.com:8082/auth/oauth/callback" "$output"
check_contains "a quote is asked again" "Quotes and backslashes are not supported." "$output"
check "the authorization URL" "'https://idp.example.com/authorize'" "$(value variables.env OAUTH_AUTHORIZATION_URL)"
check "the client secret is kept as typed" "'a\$b&c d'" "$(value variables.env OAUTH_CLIENT_SECRET)"
# shellcheck disable=SC2016
check_not_contains "the client secret is not shown" 'a$b&c d' "$output"
check "the scope of OpenID Connect by default" "'openid email'" "$(value variables.env OAUTH_SCOPE)"
check "the domain of the users" "'example.com'" "$(value variables.env OAUTH_DOMAIN)"
check "the callback URL" "'http://mcloud.example.com:8082/auth/oauth/callback'" "$(value variables.env OAUTH_CALLBACK_URL)"
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y "" "" "" "" "" "" "" "" "" n)" setup)"
check "the OAuth2 sign-in is the default of the next setup" "auth-oauth2" "$(value .env AUTH_SYSTEM)"
check "the client secret is kept by the next setup" "'a\$b&c d'" "$(value variables.env OAUTH_CLIENT_SECRET)"
check "the domain is kept by the next setup" "'example.com'" "$(value variables.env OAUTH_DOMAIN)"
if docker compose version > /dev/null 2>&1; then
  # shellcheck disable=SC2016
  check_contains "docker compose reads the quoted values" 'OAUTH_CLIENT_SECRET: a$$b&c d' \
    "$(cd "$MCLOUD" && docker compose config 2> /dev/null | grep OAUTH_CLIENT_SECRET | sed 's/^ *//')"
else
  skip_check "docker compose reads the quoted values" "requires docker compose"
fi
zbr "$(printf '%s\n' "" "" "" y "" "" y ldap ldap://ldap.example.com:389 "" "ou=people,dc=example,dc=com" "" "" n)" \
  setup > /dev/null
check "the LDAP sign-in" "auth-ldap:auth/ldap/" "$(value .env AUTH_SYSTEM):$(value .env AUTH_URL)"
check "the LDAP URL" "'ldap://ldap.example.com:389'" "$(value variables.env LDAP_URL)"
check "the attribute of the user name by default" "'uid'" "$(value variables.env LDAP_SEARCH_FIELD)"
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y oracle mock "" n)" setup)"
check_contains "an unknown sign-in is asked again" "Please answer mock, oauth2 or ldap." "$output"
check "the mock sign-in again" "auth-mock" "$(value .env AUTH_SYSTEM)"

section "setup of Zebrunner CE"
rm -f "${MCLOUD}/variables.env" "${MCLOUD}/backup/settings.env"
zbr_env=(ZBR_INSTALLER=1 ZBR_PROTOCOL=https ZBR_HOSTNAME=ce.example.com ZBR_PORT=443)
output="$(zbr "" setup)"
check "https of Zebrunner CE without its certificate fails" "1" "$?"
check_contains "the certificate of Zebrunner CE is asked for" "../nginx/ssl/ssl.crt and ../nginx/ssl/ssl.key are missing" "$output"
certificate "${WORK}/nginx/ssl" ce.example.com
# a key of root only (e.g. of certbot): root reads any file, so the check runs for another user only
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 000 "${WORK}/nginx/ssl/ssl.key"
  output="$(zbr "" setup)"
  check "https of Zebrunner CE with a key that is not readable fails" "1" "$?"
  chmod 600 "${WORK}/nginx/ssl/ssl.key"
  check_contains "the key that is not readable is reported" "The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied" "$output"
else
  skip_check "https of Zebrunner CE with a key that is not readable" "root reads any file"
fi
output="$(zbr "" setup)"
check "the certificate of Zebrunner CE is used" "same" "$(cmp -s "${WORK}/nginx/ssl/ssl.crt" "${SSL}/ssl.crt" && echo same)"
check "the key of Zebrunner CE is used" "same" "$(cmp -s "${WORK}/nginx/ssl/ssl.key" "${SSL}/ssl.key" && echo same)"
check "the setup asks nothing" "" "$(grep 'Zebrunner MCloud Settings' <<< "$output")"
check "STF_URL is the one of Zebrunner CE" "https://ce.example.com:443" "$(value .env STF_URL)"
check "STF_PORT is the internal one" "8082" "$(value .env STF_PORT)"
check "the Zebrunner sign-in" "auth-zebrunner" "$(value .env AUTH_SYSTEM)"
check "the Zebrunner sign-in URL" "auth/zebrunner/" "$(value .env AUTH_URL)"
check "ZEBRUNNER_LOGIN_URL" "https://ce.example.com:443/api/iam/v1/auth/login" "$(value variables.env ZEBRUNNER_LOGIN_URL)"
check "ZEBRUNNER_USERINFO_URL" "https://ce.example.com:443/api/iam/v1/users" "$(value variables.env ZEBRUNNER_USERINFO_URL)"
secret="$(value variables.env SECRET)"
check "a new SECRET is generated" "48" "${#secret}"
check_not_contains "Zebrunner CE starts the services itself" "need to be started after setup" "$output"
check "the CURVE keys of a new deployment of Zebrunner CE" "ok" "$(curve_keys)"
sed -i.orig -e "/^STF_ZMQ_CURVE_SERVER_SECRET_KEY=/d" -e "/^RETHINKDB_ENV_AUTHKEY=/d" "${MCLOUD}/variables.env"
zbr "" setup > /dev/null
check "Zebrunner CE makes the missing CURVE keys" "ok" "$(curve_keys)"
authkey="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "Zebrunner CE generates the missing password of RethinkDB" "48" "${#authkey}"
cp "${REPO}/tests/fixtures/shared-ssl.crt" "${WORK}/nginx/ssl/ssl.crt"
# the key of the shared certificate is not in the repository: openssl takes the pair as a match
stub openssl 'echo same'
output="$(zbr "" setup)"
rm -f "${WORK}/bin/openssl"
check "the shared certificate of Zebrunner CE is used" "0" "$?"
check_contains "the shared certificate of Zebrunner CE is reported" "the self-signed one of its repository" "$output"
zbr_env=()

section "setup of the MCloud of Zebrunner CE"
certificate "${WORK}/nginx/ssl" ce.example.com
# the answers: the admin with its confirmation, the default sign-in, no start of the services
zbr "$(printf '%s\n' "" "" y "" n)" setup > /dev/null
check "Zebrunner IAM is the default sign-in" "auth-zebrunner" "$(value .env AUTH_SYSTEM)"
# the answers: the admin with its confirmation, the sign-in ldap with its URL, no bind DN, the search DN, the default
# attribute, no start of the services
output="$(zbr "$(printf '%s\n' "" "" y ldap ldap://ldap.example.com:389 "" ou=people,dc=example,dc=com "" n)" setup)"
check "the setup of the MCloud of Zebrunner CE succeeds" "0" "$?"
check "no protocol, host or port is asked" "" "$(grep 'Zebrunner MCloud Settings' <<< "$output")"
check_contains "the URL of Zebrunner CE is shown" "Zebrunner MCloud of Zebrunner CE: https://ce.example.com:443" "$output"
check "STF_URL stays the one of Zebrunner CE" "https://ce.example.com:443" "$(value .env STF_URL)"
check "STF_PORT stays the internal one" "8082" "$(value .env STF_PORT)"
check "the sign-in of the setup" "auth-ldap" "$(value .env AUTH_SYSTEM)"
check "the certificate of Zebrunner CE stays" "same" "$(cmp -s "${WORK}/nginx/ssl/ssl.crt" "${SSL}/ssl.crt" && echo same)"
check_contains "the start is offered" "need to be started after setup" "$output"
zbr_env=(ZBR_INSTALLER=1 ZBR_PROTOCOL=https ZBR_HOSTNAME=ce.example.com ZBR_PORT=443)
zbr "" setup > /dev/null
zbr_env=()
check "the setup of Zebrunner CE keeps the sign-in" "auth-ldap" "$(value .env AUTH_SYSTEM)"
check "the setup of Zebrunner CE keeps the LDAP settings" "'ldap://ldap.example.com:389'" "$(value variables.env LDAP_URL)"
check "the setup of Zebrunner CE keeps its port" "8082" "$(value .env STF_PORT)"

section "the CURVE keys without openssl"
check "patch/curve_keygen.py: the X25519 test vector of RFC 7748" \
  "public=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" \
  "$(python3 "${REPO}/patch/curve_keygen.py" 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a | head -1)"
rm -f "${MCLOUD}/variables.env" "${MCLOUD}/backup/settings.env"
# openssl without X25519 (the LibreSSL of macOS): patch/curve_keygen.py makes them
stub openssl 'exit 1'
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "python3 makes the CURVE keys" "ok" "$(curve_keys)"
rm -f "${MCLOUD}/variables.env"
cp "${MCLOUD}/.env" "${WORK}/env.saved"
stub python3 'exit 127'
output="$(zbr "$(answers "" "" "" "" "")" setup)"
check "the setup fails without the CURVE keys" "1" "$?"
rm -f "${WORK}/bin/openssl" "${WORK}/bin/python3"
check_contains "the missing tools of the CURVE keys are reported" "openssl (X25519, OpenSSL 1.1.1+) or python3" "$output"
check "nothing is written without the CURVE keys" "same" "$(cmp -s "${MCLOUD}/.env" "${WORK}/env.saved" && echo same)"
check "no variables.env without the CURVE keys" "no" "$([[ -f "${MCLOUD}/variables.env" ]] && echo yes || echo no)"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "the keys are made by the next setup" "ok" "$(curve_keys)"

section "compose"
if docker compose version > /dev/null 2>&1; then
  run_check "docker compose config of the settings of the setup" \
    bash -c "cd '${MCLOUD}' && test -z \"\$(docker compose config --quiet 2>&1)\""
  run_check "docker compose config with adb-relay" \
    bash -c "cd '${MCLOUD}' && test -z \"\$(docker compose --profile adb-relay config --quiet 2>&1)\""
  check "adb-relay runs with its profile only" "adb-relay" \
    "$(cd "$MCLOUD" && comm -13 <(docker compose config --services | sort) \
      <(docker compose --profile adb-relay config --services | sort))"
else
  skip_check "docker compose config of the settings of the setup" "requires docker compose"
fi

section "start"
reset_calls
zbr "$(answers "" "" "" "" "" | sed '$d')\ny\n" setup > /dev/null
check "the setup starts the services when confirmed" "network|inspect|infra
compose|up|-d" "$(calls docker)"
reset_calls
output="$(zbr "" start)"
check "start starts the services in the infra network" "network|inspect|infra
compose|up|-d" "$(calls docker)"
check_contains "start shows the URLs" "MCloud: http://203.0.113.10:80/stf, the Selenium/Appium hub: http://203.0.113.10:80/mcloud/wd/hub" "$output"
check_contains "start asks STF_TOKEN of the grid" "STF_TOKEN of variables.env is empty: the grid reserves no device" "$output"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=token"
check_not_contains "start with STF_TOKEN does not ask it" "STF_TOKEN of variables.env is empty" "$(zbr "" start)"
replace "${MCLOUD}/variables.env" "STF_TOKEN=token" "STF_TOKEN="
zbr_env=(ZBR_INSTALLER=1)
check_not_contains "Zebrunner CE shows no next steps" "MCloud: " "$(zbr "" start)"
zbr_env=()
reset_calls
zbr_env=(NO_NETWORK=1)
zbr "" start > /dev/null
zbr_env=()
check "start creates a missing infra network" "network|inspect|infra
network|create|infra
compose|up|-d" "$(calls docker)"
reset_calls
mv "${MCLOUD}/.env" "${MCLOUD}/.env.saved"
zbr "$(answers "" "" "" "" "")" start > /dev/null
check "the first start runs the setup and fails" "1" "$?"
check "the first start writes .env" "yes" "$([[ -f "${MCLOUD}/.env" ]] && echo yes)"
check "the first start does not start the services" "" "$(calls docker | grep compose)"
mv "${MCLOUD}/.env.saved" "${MCLOUD}/.env"

# the files of an earlier start: the secrets get the mode of their owner only
chmod 664 "${MCLOUD}/variables.env" "${MCLOUD}/backup/settings.env"
zbr "" start > /dev/null
check "start makes variables.env readable for its owner only" "-rw-------" "$(mode variables.env)"
check "start makes backup/settings.env readable for its owner only" "-rw-------" "$(mode backup/settings.env)"
# sudo ./zebrunner.sh: root gives the files back to the owner of the folder (id and chown are stubs)
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs
stub id '[[ "$1" == "-u" ]] && echo 0 && exit 0; /usr/bin/id "$@"'
record_stub chown
reset_calls
zbr "" start > /dev/null
rm -f "${WORK}/bin/id" "${WORK}/bin/chown"
owner="$(stat -c '%u:%g' "$MCLOUD" 2> /dev/null || stat -f '%u:%g' "$MCLOUD")"
check_contains "root gives variables.env back to the owner of the folder" "${owner}|variables.env" "$(calls chown)"
check_contains "root gives agent-hosts.conf back to the owner of the folder" \
  "${owner}|configuration/stf-proxy/agent-hosts.conf" "$(calls chown)"
check_contains "root gives relay-hosts.conf back to the owner of the folder" \
  "${owner}|configuration/adb-relay/relay-hosts.conf" "$(calls chown)"
check_contains "root gives stf-token back to the owner of the folder" \
  "${owner}|configuration/adb-relay/stf-token" "$(calls chown)"

section "stop, down, restart"
# with the profile of adb-relay: it stops and goes also when ADB_RELAY_HOSTS was cleared after its start
reset_calls
zbr "" stop > /dev/null
check "stop" "compose|--profile|adb-relay|stop" "$(calls docker)"
reset_calls
zbr "" down > /dev/null
check "down" "compose|--profile|adb-relay|down" "$(calls docker)"
reset_calls
zbr "" restart > /dev/null
check "restart" "compose|--profile|adb-relay|down
network|inspect|infra
compose|up|-d" "$(calls docker)"
sed -i.orig "s/^ADB_RELAY_HOSTS=.*/ADB_RELAY_HOSTS=192.168.30.2:7404,192.168.30.2:7464/" "${MCLOUD}/.env"
reset_calls
zbr "" restart > /dev/null
check "restart with the relay hosts" "compose|--profile|adb-relay|down
network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
sed -i.orig "s/^ADB_RELAY_HOSTS=.*/ADB_RELAY_HOSTS=/" "${MCLOUD}/.env"

section "version"
check "the version is the STF tag" "mcloud: $(sed -n 's/^TAG_STF=//p' "${REPO}/.env.original")" "$(zbr "" version)"

section "backup and restore"
reset_calls
zbr "" backup > /dev/null
for file in variables.env .env backup/settings.env configuration/stf-proxy/nginx.conf configuration/stf-proxy/ssl/ssl.crt; do
  check "backup copies ${file}" "same" "$(cmp -s "${MCLOUD}/${file}" "${MCLOUD}/${file}.bak" && echo same)"
done
check_contains "backup archives the database" "run|--rm|--volumes-from|rethinkdb" "$(calls docker)"
tag="$(sed -n 's/^TAG_RETHINKDB=//p' "${MCLOUD}/.env")"
check_contains "backup archives with the image of RethinkDB, for the user only" \
  "rethinkdb:${tag}|sh|-c|tar -czf /var/backup/rethinkdb.tar.gz /data && chown $(id -u):$(id -g) /var/backup/rethinkdb.tar.gz && chmod 600 /var/backup/rethinkdb.tar.gz" \
  "$(calls docker)"
for file in variables.env.bak backup/settings.env.bak configuration/stf-proxy/ssl/ssl.key.bak; do
  check "the backup ${file} is readable for its owner only" "-rw-------" "$(mode "$file")"
done
check_not_contains "backup stops nothing when nothing runs" "compose|stop" "$(calls docker)"
printf '%s\n' stf-proxy mcloud-grid rethinkdb stf-app stf-websocket > "${WORK}/running"
reset_calls
zbr "" backup > /dev/null
check "backup stops the database and the STF units for the copy, then starts them again" "compose|ps|--services|--status|running
compose|stop|rethinkdb|stf-app|stf-websocket
run|--rm|--volumes-from|rethinkdb|-v|${MCLOUD}/backup:/var/backup|rethinkdb:${tag}|sh|-c|tar -czf /var/backup/rethinkdb.tar.gz /data \
&& chown $(id -u):$(id -g) /var/backup/rethinkdb.tar.gz && chmod 600 /var/backup/rethinkdb.tar.gz
compose|start|rethinkdb|stf-app|stf-websocket" "$(calls docker)"
rm -f "${WORK}/running"
echo "changed" > "${MCLOUD}/variables.env"
reset_calls
zbr "" restore > /dev/null
check "restore brings variables.env back" "same" "$(cmp -s "${MCLOUD}/variables.env" "${MCLOUD}/variables.env.bak" && echo same)"
check_contains "restore stops the services first" "compose|--profile|adb-relay|stop" "$(calls docker | head -1)"
check_contains "restore extracts the database" "tar -xzvf /var/backup/rethinkdb.tar.gz" "$(calls docker)"
check_contains "restore extracts with the image of RethinkDB" "rethinkdb:${tag}|bash" "$(calls docker)"
check "restore removes the containers at the end" "compose|--profile|adb-relay|down" "$(calls docker | tail -1)"

section "disabled"
touch "${MCLOUD}/.disabled"
reset_calls
for command in start stop down backup restore version; do
  check "${command} does nothing when disabled" "0:" "$(
    zbr "" "$command" > /dev/null
    echo "$?:$(calls docker)"
  )"
done
zbr "" shutdown > /dev/null
check "shutdown of a disabled copy removes .disabled only" "no:yes" \
  "$([[ -f "${MCLOUD}/.disabled" ]] && echo yes || echo no):$([[ -f "${MCLOUD}/.env" ]] && echo yes)"

section "shutdown"
reset_calls
zbr "n\n" shutdown > /dev/null
check "a declined shutdown keeps the settings" "yes:" "$([[ -f "${MCLOUD}/.env" ]] && echo yes):$(calls docker)"
zbr_env=(SHUTDOWN_CONFIRMED=1)
zbr "" shutdown > /dev/null
zbr_env=()
check "shutdown removes the services and their volumes" "compose|--profile|adb-relay|down|-v" "$(calls docker)"
for file in .env variables.env backup/settings.env configuration/stf-proxy/nginx.conf configuration/stf-proxy/agent-hosts.conf \
  configuration/adb-relay/relay-hosts.conf configuration/adb-relay/stf-token; do
  check "shutdown removes ${file}" "no" "$([[ -e "${MCLOUD}/${file}" ]] && echo yes || echo no)"
done
check "shutdown keeps the certificate of the user" "yes" "$([[ -f "${SSL}/ssl.crt" && -f "${SSL}/ssl.key" ]] && echo yes)"
check_contains "shutdown without settings" "Unable to erase as nothing is configured!" "$(zbr "" shutdown)"

finish
