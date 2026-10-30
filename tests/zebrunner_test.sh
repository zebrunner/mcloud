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
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated" "48" "${#password}"
check "the ports of the device hosts are published on every address" "0.0.0.0" "$(value .env AGENTS_ADDRESS)"
check_contains "the key for mcloud-agent is explained" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of mcloud-agent" "$output"
grid_token="$(value variables.env NODE_REGISTRATION_TOKEN)"
check "the registration token of the grid is generated" "48" "${#grid_token}"
check_contains "the registration token for mcloud-agent is explained" "NODE_REGISTRATION_TOKEN of mcloud-agent" "$output"
check_contains "the start is suggested" "need to be started after setup" "$output"

section "setup again"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
replace "${MCLOUD}/variables.env" "STF_ZMQ_CURVE_CLIENT_KEYS=" "STF_ZMQ_CURVE_CLIENT_KEYS=${keys//0/e},${keys//0/f}"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.5"
replace "${MCLOUD}/.env" "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=200m"
reset_calls
output="$(zbr "$(answers "" "" 8082 "" ops@example.com)" setup)"
check "the setup again calls no docker" "" "$(calls docker)"
check "the password of RethinkDB is kept" "$password" "$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the CURVE keys are kept" "$server_secret" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "the registration token of the grid is kept" "$grid_token" "$(value variables.env NODE_REGISTRATION_TOKEN)"
check "the keys of the device hosts are kept" "${keys//0/e},${keys//0/f}" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
check "the address of the ports of the device hosts is kept" "10.0.0.5" "$(value .env AGENTS_ADDRESS)"
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

section "stop, down, restart"
reset_calls
zbr "" stop > /dev/null
check "stop" "compose|stop" "$(calls docker)"
reset_calls
zbr "" down > /dev/null
check "down" "compose|down" "$(calls docker)"
reset_calls
zbr "" restart > /dev/null
check "restart" "compose|down
network|inspect|infra
compose|up|-d" "$(calls docker)"

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
check_contains "backup archives with the image of RethinkDB" "rethinkdb:${tag}|tar|-czf|/var/backup/rethinkdb.tar.gz|/data" "$(calls docker)"
check_not_contains "backup stops nothing when nothing runs" "compose|stop" "$(calls docker)"
printf '%s\n' stf-proxy mcloud-grid rethinkdb stf-app stf-websocket > "${WORK}/running"
reset_calls
zbr "" backup > /dev/null
check "backup stops the database and the STF units for the copy, then starts them again" "compose|ps|--services|--status|running
compose|stop|rethinkdb|stf-app|stf-websocket
run|--rm|--volumes-from|rethinkdb|-v|${MCLOUD}/backup:/var/backup|rethinkdb:${tag}|tar|-czf|/var/backup/rethinkdb.tar.gz|/data
compose|start|rethinkdb|stf-app|stf-websocket" "$(calls docker)"
rm -f "${WORK}/running"
echo "changed" > "${MCLOUD}/variables.env"
reset_calls
zbr "" restore > /dev/null
check "restore brings variables.env back" "same" "$(cmp -s "${MCLOUD}/variables.env" "${MCLOUD}/variables.env.bak" && echo same)"
check_contains "restore stops the services first" "compose|stop" "$(calls docker | head -1)"
check_contains "restore extracts the database" "tar -xzvf /var/backup/rethinkdb.tar.gz" "$(calls docker)"
check_contains "restore extracts with the image of RethinkDB" "rethinkdb:${tag}|bash" "$(calls docker)"
check "restore removes the containers at the end" "compose|down" "$(calls docker | tail -1)"

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
check "shutdown removes the services and their volumes" "compose|down|-v" "$(calls docker)"
for file in .env variables.env backup/settings.env configuration/stf-proxy/nginx.conf configuration/stf-proxy/agent-hosts.conf; do
  check "shutdown removes ${file}" "no" "$([[ -e "${MCLOUD}/${file}" ]] && echo yes || echo no)"
done
check "shutdown keeps the certificate of the user" "yes" "$([[ -f "${SSL}/ssl.crt" && -f "${SSL}/ssl.key" ]] && echo yes)"
check_contains "shutdown without settings" "Unable to erase as nothing is configured!" "$(zbr "" shutdown)"

finish
