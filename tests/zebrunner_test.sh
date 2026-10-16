#!/bin/bash
# Tests of zebrunner.sh: its commands on a copy of the repository; docker and curl are stubs, docker only records
# its calls (the services themselves are checked by tests/compose_test.sh).
source "$(dirname "$0")/lib.sh"
# shellcheck source=../patch/utility.sh
source "${REPO}/patch/utility.sh"

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"

# the stub body is expanded when the stub runs; NO_NETWORK=1: the infra network is missing
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1 $2" == "network inspect" && "$NO_NETWORK" == "1" ]] && exit 1
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
check "the setup calls no docker" "" "$(calls docker)"
check_contains "the start is suggested" "need to be started after setup" "$output"

section "setup again"
replace "${MCLOUD}/variables.env" "STF_TOKEN=" "STF_TOKEN=api-token"
output="$(zbr "$(answers "" "" 8082 "" ops@example.com)" setup)"
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
zbr_env=()

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
