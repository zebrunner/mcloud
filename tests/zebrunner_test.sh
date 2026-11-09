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
# docker inspect of stf-proxy: running unless ${STUB_DIR}/proxy-down; docker exec: the ports of ${STUB_DIR}/unreachable fail
[[ "$1" == "inspect" ]] && { [[ -f "${STUB_DIR}/proxy-down" ]] && echo false || echo true; }
[[ "$1" == "exec" ]] && grep -qx "${*: -1}" "${STUB_DIR}/unreachable" 2> /dev/null && exit 1
exit 0'
# curl: the address of ifconfig.me; the STF API answers ${STUB_DIR}/answer with the status ${STUB_DIR}/status, the
# configuration of stdin goes to ${STUB_DIR}/curl.stdin
# shellcheck disable=SC2016
stub curl '[[ "$*" == *ifconfig.me* ]] && echo 203.0.113.10 && exit 0
(IFS="|"; echo "curl|$*") >> "${STUB_DIR}/calls.log"
cat > "${STUB_DIR}/curl.stdin"
answer="${STUB_DIR}/answer"
[[ "${*: -1}" == */api/v1/devices* && -f "${STUB_DIR}/answer.devices" ]] && answer="${STUB_DIR}/answer.devices"
cat "$answer" 2> /dev/null
printf "\n%s" "$(cat "${STUB_DIR}/status" 2> /dev/null || echo 000)"'

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
# the sign-in of the previous setup, no start of the services
answers() {
  printf '%s\n' "$1" "$2" "$3" y "$4" "$5" y "" n
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
for command in setup start stop restart down shutdown backup restore version node-invite nodes; do
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
check_contains "the enrollment of the nodes is explained" "./zebrunner.sh node-invite <label> <address>" "$output"
check "the mock sign-in by default" "auth-mock:auth/mock/" "$(value .env AUTH_SYSTEM):$(value .env AUTH_URL)"
check_not_contains "no device host is asked" "Device hosts" "$output"
for name in AGENT_HOSTS ADB_RELAY_HOSTS; do
  check "no ${name} in .env" "" "$(grep "^${name}=" "${MCLOUD}/.env")"
done
for name in NODE_REGISTRATION_TOKEN STF_ZMQ_CURVE_CLIENT_KEYS; do
  check "no ${name} in variables.env" "" "$(grep "^${name}=" "${MCLOUD}/variables.env")"
done
check_contains "AGENTS_ADDRESS 0.0.0.0 is reported" \
  "AGENTS_ADDRESS of .env is 0.0.0.0: the nodes reach MCloud at mcloud.example.com (the host of STF_URL" "$output"
check "no access token for adb-relay without its auto mode" "" "$(cat "${MCLOUD}/configuration/adb-relay/stf-token")"
check "the token file of adb-relay is readable for its owner only" "-rw-------" "$(mode configuration/adb-relay/stf-token)"
check_not_contains "no warning of the optional adb relay" "ADB_RELAY" "$output"
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
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated" "48" "${#password}"
check "variables.env is readable for its owner only" "-rw-------" "$(mode variables.env)"
check "backup/settings.env is readable for its owner only" "-rw-------" "$(mode backup/settings.env)"
check_contains ".env is readable" "-rw-r" "$(mode .env)"
check "the ports of the device hosts are published on every address" "0.0.0.0" "$(value .env AGENTS_ADDRESS)"
check "the nodes reach the host of STF_URL" "mcloud.example.com" "$(value .env NODES_HOST)"
check "the triproxies and the storage read the nodes from stf-api" "http://stf-api:3000" \
  "$(value variables.env STF_NODES_API_URL)"
check_contains "the start is suggested" "need to be started after setup" "$output"

section "setup again"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
printf '%s\n' "STF_SESSION_TTL_SECONDS=3600" "STF_CUSTOM_KEY=${keys//0/a}" >> "${MCLOUD}/variables.env"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.5"
replace "${MCLOUD}/.env" "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=200m"
reset_calls
output="$(zbr "$(answers "" "" 8082 "" ops@example.com)" setup)"
check "the setup again calls no docker" "" "$(calls docker)"
check "the password of RethinkDB is kept" "$password" "$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the CURVE keys are kept" "$server_secret" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "a variable added to variables.env is kept" "3600" "$(value variables.env STF_SESSION_TTL_SECONDS)"
check "another variable added to variables.env is kept" "${keys//0/a}" "$(value variables.env STF_CUSTOM_KEY)"
check "the address of the ports of the device hosts is kept" "10.0.0.5" "$(value .env AGENTS_ADDRESS)"
check "the nodes reach AGENTS_ADDRESS" "10.0.0.5" "$(value .env NODES_HOST)"
check_not_contains "no warning with the LAN address in AGENTS_ADDRESS" "AGENTS_ADDRESS of .env is 0.0.0.0" "$output"
check "the size of the log files is kept" "200m" "$(value .env LOG_MAX_SIZE)"
check "the default number of the log files" "5" "$(value .env LOG_MAX_FILE)"
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
check "the added variables are added once" "1" "$(grep -c '^STF_CUSTOM_KEY=' "${MCLOUD}/variables.env")"

section "setup without the secrets"
for name in RETHINKDB_ENV_AUTHKEY STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY; do
  sed -i.orig "/^${name}=/d" "${MCLOUD}/variables.env"
done
output="$(zbr "$(answers "" "" "" "" "")" setup)"
authkey="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the missing password of RethinkDB is generated" "48" "${#authkey}"
check "the missing CURVE keys are made" "ok" "$(curve_keys)"

section "setup questions"
SSL="${MCLOUD}/configuration/stf-proxy/ssl"
cp "${MCLOUD}/.env" "${WORK}/env.saved"
output="$(zbr "\n\n\nn\nhttps\n\n\ny\n\n\ny\n\nn\n" setup)"
check "https without a certificate fails" "1" "$?"
check_contains "the certificate is asked for" "put it into configuration/stf-proxy/ssl/ssl.crt" "$output"
check "nothing is written without a certificate" "same" "$(cmp -s "${MCLOUD}/.env" "${WORK}/env.saved" && echo same)"
certificate "$SSL" mcloud.example.com
cp "${SSL}/ssl.crt" "${WORK}/ssl.crt"
output="$(zbr "\n\n\nn\nhttps\n\n\ny\n\n\ny\n\nn\n" setup)"
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
output="$(zbr "ftp\nhttp\nmcloud.example.com:80\nhttp://mcloud.example.com\nmcloud.example.com\nabc\n70000\n8080\ny\n\n\ny\n\nn\n" setup)"
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

section "the host of the nodes"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=10.0.0.5" "AGENTS_ADDRESS=10.0.0.6"
zbr "" start > /dev/null
check "start writes NODES_HOST of a new AGENTS_ADDRESS" "10.0.0.6" "$(value .env NODES_HOST)"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=10.0.0.6" "AGENTS_ADDRESS=0.0.0.0"
sed -i.orig '/^NODES_HOST=/d' "${MCLOUD}/.env"
output="$(zbr "" start)"
check "start adds a missing NODES_HOST" "mcloud.example.com" "$(value .env NODES_HOST)"
check_contains "start reports AGENTS_ADDRESS 0.0.0.0 with a hint for the nodes on the server" \
  "set AGENTS_ADDRESS to the LAN address of the server and run ./zebrunner.sh restart (README.md#devices-on-the-mcloud-server)" \
  "$output"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.5"
output="$(zbr "" start)"
check_not_contains "start does not report a LAN address in AGENTS_ADDRESS" "AGENTS_ADDRESS" "$output"
if docker compose version > /dev/null 2>&1; then
  check "stf-api gives the nodes the ZeroMQ endpoints at NODES_HOST" \
    "--nodes-connect-sub tcp://10.0.0.5:7250 --nodes-connect-push tcp://10.0.0.5:7270 --nodes-connect-app-dealer tcp://10.0.0.5:7160 --nodes-connect-dev-dealer tcp://10.0.0.5:7260" \
    "$(cd "$MCLOUD" && docker compose config --format json 2> /dev/null |
      python3 -c 'import json, sys; c = json.load(sys.stdin)["services"]["stf-api"]["command"]; print(" ".join(c[c.index("--nodes-connect-sub"):]))')"
  check "the triproxies, the storage and stf-api get STF_NODES_API_URL" "http://stf-api:3000 http://stf-api:3000 http://stf-api:3000 http://stf-api:3000" \
    "$(cd "$MCLOUD" && docker compose config --format json 2> /dev/null | python3 -c 'import json, sys
s = json.load(sys.stdin)["services"]
print(" ".join(s[n]["environment"]["STF_NODES_API_URL"] for n in ("stf-triproxy-app", "stf-triproxy-dev", "stf-storage-temp", "stf-api")))')"
fi
if docker compose version > /dev/null 2>&1; then
  check "stf-api gets no AGENT_HOSTS" "" "$(cd "$MCLOUD" && docker compose config 2> /dev/null | grep AGENT_HOSTS)"
fi

section "adb relay"
# relay_setting <name> <value>: a setting of the auto mode of adb-relay in .env
relay_setting() {
  sed -i.orig "s|^$1=.*|$1=$2|" "${MCLOUD}/.env"
}
check "the auto mode is off by default" "false:300:" \
  "$(sed -n 's/^ADB_RELAY=//p' "${REPO}/.env.original"):$(value .env ADB_RELAY_SYNC_SECONDS):$(value .env ADB_RELAY_PORTS)"
reset_calls
zbr "" start > /dev/null
check "start without ADB_RELAY starts no adb-relay" "network|inspect|infra
compose|up|-d" "$(calls docker)"
relay_setting ADB_RELAY true
reset_calls
output="$(zbr "" start)"
check "ADB_RELAY=true starts adb-relay" "network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
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
output="$(zbr "" start)"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
check_contains "the auto mode without STF_TOKEN is reported" \
  "STF_TOKEN of variables.env is empty: adb-relay (ADB_RELAY=true) relays no device of STF." "$output"
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
ADB_RELAY_SYNC_SECONDS: \"30\"" \
    "$(cd "$MCLOUD" && docker compose --profile adb-relay config 2> /dev/null |
      sed -n '/^  adb-relay:/,/^  [a-z]/p' | grep -E '^      ADB_RELAY' | sed 's/^ *//')"
  relay_setting ADB_RELAY false
  relay_setting ADB_RELAY_PORTS ""
else
  skip_check "docker compose passes the settings of the auto mode to adb-relay" "requires docker compose"
fi

section "sign-in"
# the answers: the sign-in, its settings with a secret, a scope, a domain of the users, no start; the secret is literal
# shellcheck disable=SC2016
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y oauth2 https://idp.example.com/authorize https://idp.example.com/token \
  https://idp.example.com/userinfo mcloud-client "it's" 'a$b&c d' "" example.com n)" setup)"
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
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y "" "" "" "" "" "" "" "" n)" setup)"
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
zbr "$(printf '%s\n' "" "" "" y "" "" y ldap ldap://ldap.example.com:389 "" "ou=people,dc=example,dc=com" "" n)" \
  setup > /dev/null
check "the LDAP sign-in" "auth-ldap:auth/ldap/" "$(value .env AUTH_SYSTEM):$(value .env AUTH_URL)"
check "the LDAP URL" "'ldap://ldap.example.com:389'" "$(value variables.env LDAP_URL)"
check "the attribute of the user name by default" "'uid'" "$(value variables.env LDAP_SEARCH_FIELD)"
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y oracle mock n)" setup)"
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
check_contains "root gives stf-token back to the owner of the folder" \
  "${owner}|configuration/adb-relay/stf-token" "$(calls chown)"

section "stop, down, restart"
# with the profile of adb-relay: it stops and goes also when ADB_RELAY was turned off after its start
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
sed -i.orig "s/^ADB_RELAY=.*/ADB_RELAY=true/" "${MCLOUD}/.env"
reset_calls
zbr "" restart > /dev/null
check "restart with adb-relay" "compose|--profile|adb-relay|down
network|inspect|infra
compose|--profile|adb-relay|up|-d" "$(calls docker)"
sed -i.orig "s/^ADB_RELAY=.*/ADB_RELAY=false/" "${MCLOUD}/.env"

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

section "nodes"
# a deployment of https on a copy of its own; curl answers the STF API with ${WORK}/answer and ${WORK}/status
ZBR_REPO="$MCLOUD"
MCLOUD="${WORK}/nodes"
copy_repo "$MCLOUD"
certificate "${MCLOUD}/configuration/stf-proxy/ssl" mcloud.example.com
zbr "$(answers https mcloud.example.com 443 "" "")" setup > /dev/null
pin="$(openssl x509 -in "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" -noout -pubkey | openssl pkey -pubin -outform DER |
  openssl dgst -sha256 -binary | openssl base64 -A)"
pin_url="$(printf '%s' "$pin" | sed -e 's/+/%2B/g' -e 's|/|%2F|g' -e 's/=/%3D/g')"
invite="mci1.$(printf 'A%.0s' {1..42})_"
admin_token="admin-token-0123456789"
# api <status> [<body>]: the next answers of the STF API
api() {
  printf '%s' "$1" > "${WORK}/status"
  printf '%s' "${2:-}" > "${WORK}/answer"
}
# no_curl <description> <zebrunner.sh arguments...>: the command fails without a request to the STF API
no_curl() {
  local description="$1"
  shift
  reset_calls
  output="$(zbr "" "$@")"
  check "${description}: fails" "1" "$?"
  check "${description}: no request" "" "$(calls curl)"
}
output="$(zbr "" node-invite lab-1 10.0.0.5)"
check "an invite needs STF_TOKEN" "1" "$?"
check_contains "the empty STF_TOKEN is reported" "STF_TOKEN of variables.env is empty" "$output"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=${admin_token}"
no_curl "the usage of node-invite" node-invite lab-1
check_contains "the usage of node-invite is shown" "Usage: ./zebrunner.sh node-invite <label> <address> [<minutes>]" "$output"
for label in Lab-1 -lab lab_1 "" "$(printf 'a%.0s' {1..41})"; do
  no_curl "the label '${label}'" node-invite "$label" 10.0.0.5
  check_contains "the label '${label}' is reported" "is not a label of a node" "$output"
done
for label in enroll invites relay verify; do
  no_curl "the reserved label '${label}'" node-invite "$label" 10.0.0.5
  check_contains "the reserved label '${label}' is reported" \
    "The label '${label}' is reserved by STF (enroll, invites, relay, verify): choose another one." "$output"
done
no_curl "an invite of the loopback address" node-invite lab-1 127.0.0.1
check_contains "a node on the server is invited with the LAN address" \
  "A node on the MCloud server itself is invited with the LAN address of the server (README.md#devices-on-the-mcloud-server)" "$output"
for address in 127.0.0.1 0.0.0.0 169.254.169.254 224.0.0.1 255.255.255.255 localhost a.localhost http://10.0.0.5 10.0.0.5:7000 \
  10.0.0.256 "a b" 10.0.0.5/x; do
  no_curl "the address '${address}'" node-invite lab-1 "$address"
  check_contains "the address '${address}' is reported" "is not the address of a node" "$output"
done
for minutes in 0 1441 abc 10000 -5; do
  no_curl "the validity '${minutes}'" node-invite lab-1 10.0.0.5 "$minutes"
  check_contains "the validity '${minutes}' is reported" "is not a number of minutes from 1 to 1440" "$output"
done
api 201 "{\"invite\":\"${invite}\",\"label\":\"lab-1\",\"address\":\"10.0.0.5\",\"expiresAt\":\"2026-11-09T18:30:00.000Z\"}"
reset_calls
output="$(zbr "" node-invite lab-1 10.0.0.5 30)"
check "an invite" "0" "$?"
check "the invite is asked from the STF API through stf-proxy on the loopback address" \
  "-sS|-k|--max-time|30|-X|POST|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|-H|Content-Type: application/json|--data-binary|\
{\"label\":\"lab-1\",\"address\":\"10.0.0.5\",\"ttlMinutes\":30}|https://127.0.0.1:443/api/v1/nodes/invites" "$(calls curl)"
check "STF_TOKEN goes in the configuration of curl on its stdin" "header = \"Authorization: Bearer ${admin_token}\"" \
  "$(cat "${WORK}/curl.stdin")"
check_not_contains "STF_TOKEN is not an argument of curl" "$admin_token" "$(calls curl)"
check_not_contains "STF_TOKEN is not shown" "$admin_token" "$output"
check_contains "the join string: the host of STF_URL, STF_PORT, the label, the grid, the pin and the invite" \
  $'\n'"mcloud-join://mcloud.example.com:443?label=lab-1&grid=mcloud.example.com:4446&pin=${pin_url}&token=${invite}"$'\n' "$output"
check "the invite is shown once" "1" "$(grep -c "$invite" <<< "$output")"
check "the pin is base64 of SHA-256" "yes" "$([[ "$pin" =~ ^[A-Za-z0-9+/]{43}=$ ]] && echo yes)"
check "the pin is URL-safe in the join string" "" "$(grep -o 'pin=[^&]*' <<< "$output" | tr -d 'A-Za-z0-9%=' | sed 's/^pin//')"
check_contains "the pin is shown" "(SHA-256 of its public key): ${pin}" "$output"
check_contains "the invite is a secret for the join of the node" \
  "It is a secret, shown once: paste it into ./zebrunner.sh join of mcloud-agent on the node lab-1" "$output"
check_contains "the validity is shown" "valid 30 minutes (until 2026-11-09T18:30:00.000Z)" "$output"
reset_calls
output="$(zbr "" node-invite lab-2 NODE-2.Example.COM)"
check "the default validity is the one of STF, the address in lower case" \
  "{\"label\":\"lab-2\",\"address\":\"node-2.example.com\"}" "$(calls curl | awk -F '|' '{print $(NF - 1)}')"
check_contains "the default validity is shown" "valid 60 minutes" "$output"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.2"
check_contains "the host of the join string is AGENTS_ADDRESS when set" \
  "mcloud-join://10.0.0.2:443?label=lab-1&grid=10.0.0.2:4446&pin=" "$(zbr "" node-invite lab-1 10.0.0.5)"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=10.0.0.2" "AGENTS_ADDRESS=0.0.0.0"
# openssl without x509 (or none): patch/spki_pin.py makes the pin
stub openssl 'exit 1'
output="$(zbr "" node-invite lab-1 10.0.0.5)"
rm -f "${WORK}/bin/openssl"
check_contains "python3 makes the same pin without openssl" "&pin=${pin_url}&token=" "$output"
check "patch/spki_pin.py of an EC certificate is the pin of openssl" \
  "$(openssl x509 -in "${REPO}/tests/fixtures/shared-ssl.crt" -noout -pubkey | openssl pkey -pubin -outform DER |
    openssl dgst -sha256 -binary | openssl base64 -A)" "$(python3 "${REPO}/patch/spki_pin.py" "${REPO}/tests/fixtures/shared-ssl.crt")"
api 201 '{"label":"lab-1"}'
output="$(zbr "" node-invite lab-1 10.0.0.5)"
check "an answer without an invite fails" "1" "$?"
check_contains "an answer without an invite is reported" "answered the invite without one" "$output"
for answer in "000:stf-proxy does not answer on 127.0.0.1:443" "401:STF_TOKEN of variables.env is not a valid access token" \
  "403:refused: STF_TOKEN is not of an admin of STF" "400:refused: an unknown node" "404:not found: an unknown node" \
  "500:the STF API answered 500"; do
  api "${answer%%:*}" '{"success":false}'
  output="$(zbr "" node-invite lab-1 10.0.0.5)"
  check "the answer ${answer%%:*} fails" "1" "$?"
  check_contains "the answer ${answer%%:*} is explained" "The invite of the node lab-1 failed: ${answer#*:}" "$output"
  check_not_contains "the answer ${answer%%:*} shows no STF_TOKEN" "$admin_token" "$output"
done
replace "${MCLOUD}/.env" "STF_URL=https://" "STF_URL=http://"
no_curl "an invite of http" node-invite lab-1 10.0.0.5
check_contains "an invite needs https" "The enrollment needs https of stf-proxy" "$output"
replace "${MCLOUD}/.env" "STF_URL=http://" "STF_URL=https://"
mv "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" "${WORK}/nodes.crt"
no_curl "an invite without the certificate" node-invite lab-1 10.0.0.5
mv "${WORK}/nodes.crt" "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt"

key="$(printf 'ab%.0s' {1..32})"
api 200 "{\"nodes\":[{\"label\":\"lab-1\",\"address\":\"10.0.0.5\",\"publicKey\":\"${key}\",\"status\":\"active\",
  \"createdAt\":\"2026-11-09T17:00:00.000Z\",\"revokedAt\":null,\"lastSeenAt\":\"2026-11-09T17:30:00.123Z\"},
  {\"label\":\"lab-2\",\"address\":\"node-2.lan\",\"publicKey\":\"${key//a/c}\",\"status\":\"revoked\",
  \"createdAt\":\"2026-11-08T10:00:00.000Z\",\"revokedAt\":\"2026-11-09T09:00:00.000Z\",\"lastSeenAt\":null}]}"
reset_calls
output="$(zbr "" nodes)"
check "the list of the nodes" "0" "$?"
check "the list of the nodes is read from the STF API" \
  "-sS|-k|--max-time|30|-X|GET|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|https://127.0.0.1:443/api/v1/nodes" \
  "$(calls curl)"
check "a line per node" "LABEL ADDRESS STATUS LAST SEEN ENROLLED KEY
lab-1 10.0.0.5 active 2026-11-09T17:30:00 2026-11-09T17:00:00 abababababababab...
lab-2 node-2.lan revoked - 2026-11-08T10:00:00 cbcbcbcbcbcbcbcb..." "$(tr -s ' ' <<< "$output")"
check "nodes list is the list" "$output" "$(zbr "" nodes list)"
api 200 '{"nodes":[]}'
check_contains "no node" "No node is enrolled" "$(zbr "" nodes list)"
check "a list of nodes with an unknown subcommand" "1" "$(
  zbr "" nodes other > /dev/null
  echo "$?"
)"

api 200 '{"success":true}'
reset_calls
output="$(zbr "" nodes revoke lab-1)"
check "a revocation" "0" "$?"
check "the revocation is posted to the STF API" \
  "-sS|-k|--max-time|30|-X|POST|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|-H|Content-Type: application/json|\
--data-binary|{}|https://127.0.0.1:443/api/v1/nodes/lab-1/revoke" "$(calls curl)"
check "the revocation restarts the triproxies: the open ZeroMQ sessions end" "restart|stf-triproxy-app|stf-triproxy-dev" \
  "$(calls docker)"
check_contains "the revocation is reported" "The node lab-1 is revoked" "$output"
api 404 '{"success":false}'
reset_calls
output="$(zbr "" nodes revoke lab-9)"
check "the revocation of an unknown node fails" "1" "$?"
check "no restart without a revocation" "" "$(calls docker)"
no_curl "the revocation without a label" nodes revoke
no_curl "the revocation of an invalid label" nodes revoke ../x
api 204 ""
reset_calls
output="$(zbr "" nodes delete lab-2)"
check "a removal" "0" "$?"
check "the removal is a DELETE of the STF API" \
  "-sS|-k|--max-time|30|-X|DELETE|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|https://127.0.0.1:443/api/v1/nodes/lab-2" \
  "$(calls curl)"
check "the removal restarts nothing" "" "$(calls docker)"
api 400 '{"success":false}'
output="$(zbr "" nodes delete lab-1)"
check "the removal of an active node fails" "1" "$?"
check_contains "the removal needs a revocation" "a revoked one only: ./zebrunner.sh nodes revoke lab-1" "$output"

# the diagnostics of a node: lab-1 at 10.0.0.5 with a reachable Android device, an iOS device stf-proxy does not reach
# (its port in ${WORK}/unreachable), an absent device; the devices of another node and an unbound one are not shown
api 200 "{\"nodes\":[{\"label\":\"lab-1\",\"address\":\"10.0.0.5\",\"publicKey\":\"${key}\",\"status\":\"active\",
  \"createdAt\":\"2026-11-09T17:00:00.000Z\",\"revokedAt\":null,\"lastSeenAt\":\"2026-11-09T17:30:00.123Z\"},
  {\"label\":\"lab-2\",\"address\":\"node-2.lan\",\"publicKey\":\"${key//a/c}\",\"status\":\"revoked\",
  \"createdAt\":\"2026-11-08T10:00:00.000Z\",\"revokedAt\":\"2026-11-09T09:00:00.000Z\",\"lastSeenAt\":null},
  {\"label\":\"lab-3\",\"address\":\"10.0.0.8\",\"publicKey\":\"${key}\",\"status\":\"active\",
  \"createdAt\":\"2026-11-08T10:00:00.000Z\",\"revokedAt\":null,\"lastSeenAt\":null}]}"
devices_answer='{"success":true,"description":"Devices Information","devices":[
  {"serial":"emulator-5554","platform":"Android","present":true,"node":"lab-1","screenPort":7405,"connectPort":7406},
  {"serial":"00008110-001","platform":"iOS","present":true,"node":"lab-1","screenPort":7600,"connectPort":null},
  {"serial":"R58M","platform":"Android","present":false,"node":"lab-1","screenPort":7410,"connectPort":7411},
  {"serial":"other","platform":"Android","present":true,"node":"lab-2","screenPort":7420,"connectPort":7421},
  {"serial":"unbound","platform":"Android","present":true,"node":null,"screenPort":7430,"connectPort":7431}]}'
printf '%s' "$devices_answer" > "${WORK}/answer.devices"
echo 7600 > "${WORK}/unreachable"
reset_calls
output="$(zbr "" nodes check lab-1)"
check "a node with an unreachable device fails the check" "1" "$?"
check "the check reads the node and the devices from the STF API" \
  "-sS|-k|--max-time|30|-X|GET|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|https://127.0.0.1:443/api/v1/nodes
-sS|-k|--max-time|30|-X|GET|-H|Accept: application/json|-w|\\n%{http_code}|-K|-|\
https://127.0.0.1:443/api/v1/devices?fields=serial,platform,present,node,screenPort,connectPort" "$(calls curl)"
check_not_contains "STF_TOKEN is not an argument of the check" "$admin_token" "$(calls curl)"
# shellcheck disable=SC2016 # the script of the inner bash
check "stf-proxy connects to the screens of the present devices of the node" \
  'inspect|--format|{{.State.Running}}|stf-proxy
exec|stf-proxy|timeout|5|bash|-c|echo > "/dev/tcp/$0/$1"|10.0.0.5|7405
exec|stf-proxy|timeout|5|bash|-c|echo > "/dev/tcp/$0/$1"|10.0.0.5|7600' "$(calls docker)"
check_contains "the record of the node" \
  "Node lab-1: active, address 10.0.0.5, enrolled 2026-11-09T17:00:00, last seen by the grid 2026-11-09T17:30:00" "$output"
check "the devices of the node with the result" "SERIAL PLATFORM PRESENT SCREEN REMOTE DEBUG SCREEN FROM stf-proxy
emulator-5554 Android yes 7405 7406 reachable
00008110-001 iOS yes 7600 - NOT REACHABLE
R58M Android no 7410 7411 not checked: absent" "$(grep -E '^(SERIAL|emulator|00008110|R58M|other|unbound)' <<< "$output" | tr -s ' ')"
check_contains "an unreachable screen is explained" "stf-proxy does not reach the screen of a device at 10.0.0.5: the address of the invite" "$output"
check_contains "the hint names the NAT hairpin" "NAT hairpin" "$output"
: > "${WORK}/unreachable"
output="$(zbr "" nodes check lab-1)"
check "a node with its screens reachable passes the check" "0" "$?"
check_not_contains "no hint when the screens are reachable" "does not reach" "$output"
touch "${WORK}/proxy-down"
reset_calls
output="$(zbr "" nodes check lab-1)"
check "the check without stf-proxy fails" "1" "$?"
rm -f "${WORK}/proxy-down"
check_contains "stf-proxy that is not running is reported" "stf-proxy is not running (./zebrunner.sh start)" "$output"
check "no connection without stf-proxy" "" "$(calls docker | grep '^exec')"
output="$(zbr "" nodes check lab-2)"
check "a revoked node fails the check" "1" "$?"
check_contains "a revoked node is explained" "The node lab-2 is revoked" "$output"
output="$(zbr "" nodes check lab-9)"
check "an unknown node fails the check" "1" "$?"
check_contains "an unknown node is explained" "There is no node lab-9 in the registry of STF" "$output"
output="$(zbr "" nodes check lab-3)"
check "a node without devices fails the check" "1" "$?"
check_contains "a node the grid has not seen is explained" "The grid has not seen the node yet" "$output"
check_contains "a node without devices is explained" "No device of STF is bound to the node lab-3" "$output"
no_curl "the check without a label" nodes check
no_curl "the check of an invalid label" nodes check ../x
rm -f "${WORK}/answer.devices"

section "stf-proxy"
conf="$(cat "${MCLOUD}/configuration/stf-proxy/nginx.conf")"
# block <start>: the lines of a block of the nginx configuration from its first line to its end
block() {
  awk -v start="$1" 'index($0, start) { found = 1 } found { print } found && /^    }$/ { exit }' \
    "${MCLOUD}/configuration/stf-proxy/nginx.conf"
}
screen="$(block 'location ~ "^/d/')"
screen_auth="$(block "location = /_screen_auth")"
check_not_contains "no list of the device hosts" "agent-hosts" "$conf"
self="$(block "location ~* ^/api/v1/nodes/self")"
check_contains "the record of a node for itself goes to stf-api" "set \$upstream_node_self stf-api:3000;" "$self"
check_contains "the record of a node for itself is limited per address" \
  "limit_req_zone \$binary_remote_addr zone=node_self:1m rate=30r/m;" "$conf"
check_contains "too many requests of the record of a node are 429" "limit_req_status 429;" "$self"
check_contains "the screens are allowed by stf-api" "auth_request /_screen_auth;" "$screen"
check_contains "the node gets the headers of the WebSocket only" "proxy_pass_request_headers off;" "$screen"
check_contains "the node gets no session cookie" 'proxy_set_header Cookie "";' "$screen"
check_contains "the node gets no access token" 'proxy_set_header Authorization "";' "$screen"
check_contains "the node gets no internal token" 'proxy_set_header X-Stf-Internal-Token "";' "$screen"
check_contains "the internal routes of the registry are refused" "return 403;" \
  "$(block "location ~* ^/api/v1/zebrunner/nodes {")"
check "the node gets no X-Stf-* header" "" "$(grep -i 'proxy_set_header *X-Stf' <<< "$screen" | grep -v ' "";$')"
check_contains "the decision of stf-api" "proxy_pass http://\$upstream_screen_auth/api/v1/zebrunner/screen-auth;" "$screen_auth"
check_contains "stf-api gets the original URI" "proxy_set_header X-Original-URI \$request_uri;" "$screen_auth"
check_contains "stf-api gets the session cookie" "proxy_set_header Cookie \$http_cookie;" "$screen_auth"
check_contains "stf-api gets the access token" "proxy_set_header Authorization \$http_authorization;" "$screen_auth"
check_contains "stf-api gets no other header of the user" "proxy_pass_request_headers off;" "$screen_auth"
check_contains "the enrollment is limited per address" "limit_req_zone \$binary_remote_addr zone=node_enroll:1m rate=6r/m;" "$conf"
enroll="$(block "location ~* ^/api/v1/nodes/enroll")"
check_contains "the enrollment goes to stf-api" "set \$upstream_enroll stf-api:3000;" "$enroll"
check_contains "the burst of the enrollment" "limit_req zone=node_enroll burst=3 nodelay;" "$enroll"
check_contains "too many enrollments are 429" "limit_req_status 429;" "$enroll"
MCLOUD="$ZBR_REPO"

section "disabled"
touch "${MCLOUD}/.disabled"
reset_calls
for command in start stop down backup restore version node-invite nodes; do
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
for file in .env variables.env backup/settings.env configuration/stf-proxy/nginx.conf configuration/adb-relay/stf-token; do
  check "shutdown removes ${file}" "no" "$([[ -e "${MCLOUD}/${file}" ]] && echo yes || echo no)"
done
check "shutdown keeps the certificate of the user" "yes" "$([[ -f "${SSL}/ssl.crt" && -f "${SSL}/ssl.key" ]] && echo yes)"
check_contains "shutdown without settings" "Unable to erase as nothing is configured!" "$(zbr "" shutdown)"

finish
