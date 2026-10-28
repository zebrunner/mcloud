#!/bin/bash
# Tests of zebrunner.sh: its commands on a copy of the repository; docker and curl are stubs, docker only records
# its calls (the services themselves are checked by tests/compose_test.sh).
source "$(dirname "$0")/lib.sh"
# shellcheck source=../patch/utility.sh
source "${REPO}/patch/utility.sh"

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"

# the stub body is expanded when the stub runs; NO_NETWORK=1: the infra network is missing; `stf curve-keygen` of the
# STF image prints two key pairs, none with NO_KEYGEN=1
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1 $2" == "network inspect" && "$NO_NETWORK" == "1" ]] && exit 1
if [[ "$1" == "run" && "$*" == *curve-keygen* ]]; then
  [[ "$NO_KEYGEN" == "1" ]] && exit 1
  for key in a b c d; do
    printf "%s=%s\n" "$([[ "$key" =~ [ac] ]] && echo public || echo secret)" "$(printf "%064d" 0 | tr 0 "$key")"
  done
fi
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

# the answers of the interactive setup: protocol, host, port, confirmation, admin name, admin email, confirmation,
# no start of the services
answers() {
  printf '%s\n' "$1" "$2" "$3" y "$4" "$5" y n
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
check "the nginx configuration is the original one for http" "same" \
  "$(cmp -s "${MCLOUD}/configuration/stf-proxy/nginx.conf" "${REPO}/configuration/stf-proxy/nginx.conf.original" && echo same)"
check_contains "the settings are saved" 'ZBR_HOSTNAME="mcloud.example.com"' "$(cat "${MCLOUD}/backup/settings.env")"
check "the setup makes the CURVE keys with the STF image" \
  "run|--rm|public.ecr.aws/zebrunner/stf:$(sed -n 's/^TAG_STF=//p' "${REPO}/.env.original")|sh|-c|stf curve-keygen && stf curve-keygen" \
  "$(calls docker)"
keys="$(printf '%064d' 0)"
check "the public key of the triproxies" "${keys//0/a}" "$(value variables.env STF_ZMQ_CURVE_SERVER_PUBLIC_KEY)"
check "the secret key of the triproxies" "${keys//0/b}" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "the secret key of the STF units" "${keys//0/d}" "$(value variables.env STF_ZMQ_CURVE_SECRET_KEY)"
check "no device host yet" "" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated" "48" "${#password}"
check "RethinkDB is not published for the device hosts" "127.0.0.1" "$(value .env RETHINKDB_ADDRESS)"
check "the ports of the device hosts are published on every address" "0.0.0.0" "$(value .env AGENTS_ADDRESS)"
check_contains "the key for mcloud-agent is explained" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of mcloud-agent" "$output"
check_not_contains "no warning about the authentication" "have no authentication" "$output"
check_contains "the start is suggested" "need to be started after setup" "$output"

section "setup again"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
replace "${MCLOUD}/variables.env" "STF_ZMQ_CURVE_CLIENT_KEYS=" "STF_ZMQ_CURVE_CLIENT_KEYS=${keys//0/e},${keys//0/f}"
replace "${MCLOUD}/.env" "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=10.0.0.5"
reset_calls
output="$(zbr "$(answers "" "" 8082 "" ops@example.com)" setup)"
check "the setup again calls no docker" "" "$(calls docker)"
check "the password of RethinkDB is kept" "$password" "$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the CURVE keys are kept" "${keys//0/b}" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "the keys of the device hosts are kept" "${keys//0/e},${keys//0/f}" "$(value variables.env STF_ZMQ_CURVE_CLIENT_KEYS)"
check "the address of the ports of the device hosts is kept" "10.0.0.5" "$(value .env AGENTS_ADDRESS)"
check "the previous host is the default" "http://mcloud.example.com:8082" "$(value .env STF_URL)"
check "the new port" "8082" "$(value .env STF_PORT)"
check "SECRET is kept" "$secret" "$(value variables.env SECRET)"
check "STF_STORAGE_TOKEN is kept" "$storage_token" "$(value variables.env STF_STORAGE_TOKEN)"
check "STF_TOKEN is kept" "api-token" "$(value variables.env STF_TOKEN)"
check "the new admin email" "ops@example.com" "$(value variables.env STF_ADMIN_EMAIL)"
check_not_contains "no warning about SECRET" "SECRET of variables.env" "$output"

replace "${MCLOUD}/variables.env" "SECRET=${secret}" "SECRET=password"
output="$(zbr "$(answers "" "" "" "" "")" setup)"
check "the default SECRET of a deployment is kept" "password" "$(value variables.env SECRET)"
check_contains "the default SECRET is reported" "SECRET of variables.env is the default one" "$output"
replace "${MCLOUD}/variables.env" "SECRET=password" "SECRET="
zbr "$(answers "" "" "" "" "")" setup > /dev/null
secret="$(value variables.env SECRET)"
check "an empty SECRET is generated" "48" "${#secret}"

section "setup of an earlier deployment"
for name in RETHINKDB_ENV_AUTHKEY STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SERVER_PUBLIC_KEY STF_ZMQ_CURVE_SECRET_KEY \
  STF_ZMQ_CURVE_CLIENT_KEYS; do
  sed -i.orig "/^${name}=/d" "${MCLOUD}/variables.env"
done
sed -i.orig "/^RETHINKDB_ADDRESS=/d" "${MCLOUD}/.env"
reset_calls
# the answers: the protocol, host and port with their confirmation, the admin with its confirmation, no authentication,
# no start of the services
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y n n)" setup)"
check_contains "the authentication is offered" "RethinkDB and ZeroMQ of STF accept anyone" "$output"
check_contains "its absence is reported" "RethinkDB and ZeroMQ of STF have no authentication" "$output"
check "no password of RethinkDB" "" "$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "no CURVE keys" "" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "RethinkDB stays published for the device hosts" "0.0.0.0" "$(value .env RETHINKDB_ADDRESS)"
check "no docker without the authentication" "" "$(calls docker)"
zbr "$(printf '%s\n' "" "" "" y "" "" y n n)" setup > /dev/null
check "RethinkDB stays published on the next setup" "0.0.0.0" "$(value .env RETHINKDB_ADDRESS)"
output="$(zbr "$(printf '%s\n' "" "" "" y "" "" y y n)" setup)"
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated when the authentication is turned on" "48" "${#password}"
check "the CURVE keys are made when the authentication is turned on" "${keys//0/b}" \
  "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
check "RethinkDB is not published once the authentication is on" "127.0.0.1" "$(value .env RETHINKDB_ADDRESS)"
output="$(zbr "$(answers "" "" "" "" "")" setup)"
check_not_contains "the authentication is not offered again" "RethinkDB and ZeroMQ of STF accept anyone" "$output"

section "setup questions"
output="$(zbr "\n\n\nn\nhttps\n\n\ny\n\n\ny\nn\n" setup)"
check "a declined address is asked again" "https://mcloud.example.com:8082" "$(value .env STF_URL)"
check_contains "https listens with ssl" "listen 80 ssl;" "$(cat "${MCLOUD}/configuration/stf-proxy/nginx.conf")"
check_contains "the ssl settings are uncommented" $'\n    ssl_certificate /etc/nginx/ssl/ssl.crt;' \
  "$(cat "${MCLOUD}/configuration/stf-proxy/nginx.conf")"
check "the self-signed certificate is used" "same" \
  "$(cmp -s "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt.original" && echo same)"
check "the self-signed key is used" "same" \
  "$(cmp -s "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key" "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key.original" && echo same)"
echo "custom" > "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "a custom certificate is kept" "custom" "$(cat "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt")"

section "setup of Zebrunner CE"
rm -f "${MCLOUD}/variables.env" "${MCLOUD}/backup/settings.env"
zbr_env=(ZBR_INSTALLER=1 ZBR_PROTOCOL=https ZBR_HOSTNAME=ce.example.com ZBR_PORT=443)
output="$(zbr "" setup)"
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
check "the CURVE keys of a new deployment of Zebrunner CE" "${keys//0/b}" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
sed -i.orig -e "/^STF_ZMQ_CURVE_SERVER_SECRET_KEY=/d" -e "/^RETHINKDB_ENV_AUTHKEY=/d" "${MCLOUD}/variables.env"
output="$(zbr "" setup)"
check_not_contains "Zebrunner CE does not offer the authentication" "RethinkDB and ZeroMQ of STF accept anyone" "$output"
check_contains "Zebrunner CE reports its absence" "have no authentication" "$output"
zbr_env=()

section "setup without the CURVE keys of the STF image"
rm -f "${MCLOUD}/variables.env"
zbr_env=(NO_KEYGEN=1)
output="$(zbr "$(answers "" "" "" "" "")" setup)"
zbr_env=()
check_contains "the missing keys are reported" "made no CURVE keys" "$output"
check "no CURVE keys" "" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"
password="$(value variables.env RETHINKDB_ENV_AUTHKEY)"
check "the password of RethinkDB is generated anyway" "48" "${#password}"
zbr "$(answers "" "" "" "" "")" setup > /dev/null
check "the keys are made by the next setup" "${keys//0/b}" "$(value variables.env STF_ZMQ_CURVE_SERVER_SECRET_KEY)"

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
zbr "" start > /dev/null
check "start starts the services in the infra network" "network|inspect|infra
compose|up|-d" "$(calls docker)"
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
echo "changed" > "${MCLOUD}/variables.env"
reset_calls
zbr "" restore > /dev/null
check "restore brings variables.env back" "same" "$(cmp -s "${MCLOUD}/variables.env" "${MCLOUD}/variables.env.bak" && echo same)"
check_contains "restore stops the services first" "compose|stop" "$(calls docker | head -1)"
check_contains "restore extracts the database" "tar -xzvf /var/backup/rethinkdb.tar.gz" "$(calls docker)"
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
for file in .env variables.env backup/settings.env configuration/stf-proxy/nginx.conf configuration/stf-proxy/ssl/ssl.crt \
  configuration/stf-proxy/ssl/ssl.key; do
  check "shutdown removes ${file}" "no" "$([[ -e "${MCLOUD}/${file}" ]] && echo yes || echo no)"
done
check "the originals stay" "yes" "$([[ -f "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt.original" ]] && echo yes)"
check_contains "shutdown without settings" "Unable to erase as nothing is configured!" "$(zbr "" shutdown)"

finish
