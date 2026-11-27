#!/bin/bash
# Tests of the MDM of zebrunner.sh (patch/mdm.sh, README.md#mdm): MDM_* of .env, the secrets of mdm.env, the locations of
# stf-proxy, the MQTT proxy and the profile mdm of start, stop, down and shutdown; docker and curl are stubs (the
# locations themselves are checked in nginx by tests/mdm_proxy_docker_test.sh).
source "$(dirname "$0")/lib.sh"
# shellcheck source=../patch/utility.sh
source "${REPO}/patch/utility.sh"
# shellcheck source=../patch/ui.sh
source "${REPO}/patch/ui.sh"

MCLOUD="${WORK}/mcloud"
copy_repo "$MCLOUD"

# docker records its calls; curl answers the address of ifconfig.me
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == "inspect" ]] && echo true
exit 0'
# shellcheck disable=SC2016
stub curl '[[ "$*" == *ifconfig.me* ]] && echo 203.0.113.10 && exit 0
cat > /dev/null
printf "\n000"'

# zbr <stdin text> <zebrunner.sh arguments...>: zebrunner.sh of the copy without the user's environment
zbr() {
  local input="$1"
  shift
  printf '%b' "$input" | env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb COLUMNS=80 STUB_DIR="$WORK" \
    /bin/bash "${MCLOUD}/zebrunner.sh" "$@" 2>&1 | unwrap
  return "${PIPESTATUS[1]}"
}

# compose_calls: the calls of docker compose but the creation of STF_TOKEN (compose run of stf-migrate)
compose_calls() {
  calls docker | grep '^compose|' | grep -v '^compose|run|'
}

# setting <name> <value>: a setting of .env of the copy
setting() {
  set_line "${MCLOUD}/.env" "$1=$2"
}

# value <file> <name>: the value of a variable of an env file of the copy
value() {
  sed -n "s/^$2=//p" "${MCLOUD}/$1"
}

# mode <file>: the permissions of a file of the copy, as ls shows them (-rw-------)
mode() {
  # shellcheck disable=SC2012 # one known file, ls is the same on Linux and macOS
  ls -l "${MCLOUD}/$1" | cut -c1-10
}

# exists <file>: yes when the file of the copy exists
exists() {
  [[ -e "${MCLOUD}/$1" ]] && echo yes || echo no
}

PROXY="configuration/stf-proxy/mdm"

# the answers of the interactive setup: https on mcloud.example.com:443, the admin, the mock sign-in, no start
mkdir -p "${MCLOUD}/configuration/stf-proxy/ssl"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=mcloud.example.com" \
  -keyout "${MCLOUD}/configuration/stf-proxy/ssl/ssl.key" -out "${MCLOUD}/configuration/stf-proxy/ssl/ssl.crt" > /dev/null 2>&1
SETUP_ANSWERS="https\nmcloud.example.com\n443\ny\n\n\ny\n\nn\n"

section "the MDM is off by default"
zbr "$SETUP_ANSWERS" setup > /dev/null
check "MDM_ENABLED is false in .env.original" "false" "$(sed -n 's/^MDM_ENABLED=//p' "${REPO}/.env.original")"
check "MDM_ENFORCE_NODE_BINDING is false in .env.original" "false" \
  "$(sed -n 's/^MDM_ENFORCE_NODE_BINDING=//p' "${REPO}/.env.original")"
check_contains "mcloud-mdm gets MDM_ENFORCE_NODE_BINDING, false by default" \
  "- MDM_ENFORCE_NODE_BINDING=\${MDM_ENFORCE_NODE_BINDING:-false}" "$(cat "${REPO}/docker-compose.yml")"
check "the setup writes no mdm.env" "no" "$(exists mdm.env)"
check "the setup writes no location of the MDM" "" "$(ls "${MCLOUD}/${PROXY}"/*.conf 2> /dev/null)"
reset_calls
zbr "" start > /dev/null
check "start without the MDM starts no profile mdm" "compose|up|-d" "$(compose_calls)"

section "MDM_ENABLED needs https and true or false"
setting MDM_ENABLED yes
output="$(zbr "" start)"
check_contains "an invalid MDM_ENABLED is reported" "MDM_ENABLED of .env is 'yes', not true or false: the MDM is off." "$output"
check "an invalid MDM_ENABLED starts no profile mdm" "no" "$(exists mdm.env)"
setting MDM_ENABLED true
setting STF_URL http://mcloud.example.com:8082
output="$(zbr "" start)"
check_contains "http is reported" "MDM_ENABLED=true needs https, STF_URL of .env is http://mcloud.example.com:8082" "$output"
check "http starts no MDM" "no" "$(exists mdm.env)"
setting STF_URL https://mcloud.example.com:443

section "the MDM on"
setting MDM_SITE_ADDRESSES "203.0.113.10, 198.51.100.0/24,2001:db8::/32,not-an-address"
reset_calls
output="$(zbr "" start)"
check "start with the MDM starts the profile mdm" "compose|--profile|mdm|up|-d" "$(compose_calls)"
check_contains "an invalid address is reported" "'not-an-address' of MDM_SITE_ADDRESSES of .env is not an address" "$output"
check_contains "the missing agent APK is reported" "configuration/mdm/android/mcloud-mdm-agent.apk is missing" "$output"
check_contains "start shows the ssh tunnel of the admin UI" "ssh -L 9101:127.0.0.1:9101 <server>" "$output"
check "mdm.env is readable for its owner only" "-rw-------" "$(mode mdm.env)"
token="$(value mdm.env MDM_ENROLL_TOKEN)"
check "the enrollment token is generated" "48" "${#token}"
admin_token="$(value mdm.env MDM_ADMIN_TOKEN)"
check "the admin token is generated" "48" "${#admin_token}"
check "NanoHUB posts its webhook with the admin token" "http://admin:${admin_token}@mcloud-mdm:8081/webhook" \
  "$(value mdm.env NANOHUB_WEBHOOK_URL)"
check_not_contains "the admin token is not in the compose file" "NANOHUB_WEBHOOK_URL" "$(cat "${MCLOUD}/docker-compose.yml")"
for name in NANOHUB_API_KEY MYSQL_PASSWORD HMDM_PASSWORD HMDM_SHARED_SECRET SQL_PASS HMDM_MQTT_ADMIN_PASSWORD; do
  check "${name} is generated" "yes" "$([[ -n "$(value mdm.env "$name")" ]] && echo yes)"
done
check "NanoHUB gets the password of MySQL" "nanohub:$(value mdm.env MYSQL_PASSWORD)@tcp(mcloud-mdm-mysql:3306)/nanohub?parseTime=true" \
  "$(value mdm.env NANOHUB_STORAGE_DSN)"
check "Headwind MDM gets the shared secret of the agents" "$(value mdm.env HMDM_SHARED_SECRET)" "$(value mdm.env SHARED_SECRET)"
check "PostgreSQL and Headwind MDM share its password" "$(value mdm.env SQL_PASS):$(value mdm.env SQL_PASS)" \
  "$(value mdm.env POSTGRES_PASSWORD):$(value mdm.env PGPASSWORD)"
# the env file of every MDM service: the names of its secrets only, the values of mdm.env
names() {
  sed -n 's/^\([A-Z_]*\)=.*/\1/p' "${MCLOUD}/configuration/mdm/env/$1.env" | tr '\n' ' '
}
check "mcloud-mdm gets its tokens" "MDM_ENROLL_TOKEN NANOHUB_API_KEY MDM_ADMIN_TOKEN HMDM_PASSWORD HMDM_SHARED_SECRET " \
  "$(names mcloud-mdm)"
check "NanoHUB gets its API key, its database and its webhook" "NANOHUB_API_KEY NANOHUB_STORAGE_DSN NANOHUB_WEBHOOK_URL " \
  "$(names mcloud-mdm-nanohub)"
check "MySQL gets its password only" "MYSQL_PASSWORD " "$(names mcloud-mdm-mysql)"
check "Headwind MDM gets its database, the secret of the agents and the admin password of its MQTT broker" \
  "SQL_PASS SHARED_SECRET HMDM_MQTT_ADMIN_PASSWORD " "$(names mcloud-mdm-hmdm)"
mqtt_admin_password="$(value mdm.env HMDM_MQTT_ADMIN_PASSWORD)"
check "the admin password of the MQTT broker: 32 letters and digits" "32" "$(tr -dc 'A-Za-z0-9' <<< "$mqtt_admin_password" | wc -c | tr -d ' ')"
check "the admin password of the MQTT broker goes to Headwind MDM only" "configuration/mdm/env/mcloud-mdm-hmdm.env" \
  "$(cd "$MCLOUD" && grep -l "$mqtt_admin_password" configuration/mdm/env/*.env)"
check "PostgreSQL gets its password only" "POSTGRES_PASSWORD " "$(names mcloud-mdm-postgres)"
check "the init of Headwind MDM gets its database and the password of the admin" "PGPASSWORD HMDM_PASSWORD " \
  "$(names mcloud-mdm-hmdm-init)"
check "the values are the ones of mdm.env" "$(value mdm.env MYSQL_PASSWORD)" \
  "$(value configuration/mdm/env/mcloud-mdm-mysql.env MYSQL_PASSWORD)"
for service in mcloud-mdm mcloud-mdm-nanohub mcloud-mdm-mysql mcloud-mdm-hmdm mcloud-mdm-postgres mcloud-mdm-hmdm-init; do
  check "the env file of ${service} is readable for its owner only" "-rw-------" "$(mode "configuration/mdm/env/${service}.env")"
done
check "the sites of stf-proxy: the valid addresses" "  203.0.113.10 1;
  198.51.100.0/24 1;
  2001:db8::/32 1;" "$(grep ' 1;$' "${MCLOUD}/${PROXY}/http-mdm.conf")"
check "the locations of stf-proxy are readable for their owner only" "-rw-------" "$(mode "${PROXY}/server-mdm.conf")"
locations="$(cat "${MCLOUD}/${PROXY}/server-mdm.conf")"
check_contains "stf-proxy calls mcloud-mdm with the enrollment token" "proxy_set_header Authorization \"Bearer ${token}\";" "$locations"
check_contains "stf-proxy checks the node token" "proxy_pass http://\$upstream_node_auth/api/v1/nodes/self;" "$locations"
check_contains "stf-proxy takes the node of the token from stf-api" \
  "auth_request_set \$mdm_node \$upstream_http_x_mcloud_node;" "$locations"
check_contains "stf-proxy passes the node of the token to mcloud-mdm" "proxy_set_header X-MCloud-Node \$mdm_node;" "$locations"
# forwarded <text>: how many locations send the scheme, X-Forwarded-For and X-Real-IP of stf-proxy, <n>:<n>:<n>
forwarded() {
  printf '%s:%s:%s' "$(grep -cF "X-Forwarded-Proto \$forwarded_proto;" <<< "$1")" \
    "$(grep -cF "X-Forwarded-For \$remote_addr;" <<< "$1")" "$(grep -cF "X-Real-IP \$remote_addr;" <<< "$1")"
}
check "every location of the MDM sends the scheme and the address of stf-proxy" "5:5:5" "$(forwarded "$locations")"
check_not_contains "no forwarding header of a client reaches the MDM" "\$http_x_" "$locations"
check_not_contains "no forwarding header of a client is added to" "proxy_add_x_forwarded_for" "$locations"
check_not_contains "the admin UI is not published by default" "/mcloud/mdm/" "$locations"
check_not_contains "the admin token is not in the locations by default" "$admin_token" "$locations"
check "the MQTT proxy allows the valid addresses only" "    allow 203.0.113.10;
    allow 198.51.100.0/24;
    allow 2001:db8::/32;
    deny all;" "$(grep -E '^ +(allow|deny) ' "${MCLOUD}/configuration/mdm/mqtt.conf")"
check_contains "a running stf-proxy reads the new locations" "exec|stf-proxy|nginx|-s|reload" "$(calls docker)"

section "the access token of STF"
check "no STF_TOKEN: no API of STF" "" "$(value mdm.env MDM_STF_URL)"
check_not_contains "the node binding is off by default" "MDM_ENFORCE_NODE_BINDING" "$output"
setting MDM_ENFORCE_NODE_BINDING true
check_contains "MDM_ENFORCE_NODE_BINDING=true without STF_TOKEN is reported" \
  "MDM_ENFORCE_NODE_BINDING=true needs STF_TOKEN of variables.env" "$(zbr "" start)"
setting MDM_ENFORCE_NODE_BINDING yes
check_contains "an invalid MDM_ENFORCE_NODE_BINDING is reported" \
  "MDM_ENFORCE_NODE_BINDING of .env is 'yes', not true or false: mcloud-mdm does not start" "$(zbr "" start)"
setting MDM_ENFORCE_NODE_BINDING true
set_line "${MCLOUD}/variables.env" "STF_TOKEN=stf-token-123"
check_not_contains "MDM_ENFORCE_NODE_BINDING=true with STF_TOKEN is no problem" "MDM_ENFORCE_NODE_BINDING" "$(zbr "" start)"
setting MDM_ENFORCE_NODE_BINDING false
check "STF_TOKEN of variables.env goes to mcloud-mdm" "http://stf-api:3000|stf-token-123" "$(value mdm.env MDM_STF_URL)|$(value mdm.env MDM_STF_TOKEN)"
check "the token of STF goes to mcloud-mdm only" "configuration/mdm/env/mcloud-mdm.env" \
  "$(cd "$MCLOUD" && grep -l stf-token-123 configuration/mdm/env/*.env)"
set_line "${MCLOUD}/variables.env" "STF_TOKEN=stf-token-456"
zbr "" start > /dev/null
check "a new STF_TOKEN replaces it at the next start" "stf-token-456" "$(value mdm.env MDM_STF_TOKEN)"
set_line "${MCLOUD}/variables.env" "STF_TOKEN="

section "the next start keeps the secrets"
reset_calls
output="$(zbr "" start)"
check "the enrollment token is kept" "$token" "$(value mdm.env MDM_ENROLL_TOKEN)"
check "the admin token is kept" "$admin_token" "$(value mdm.env MDM_ADMIN_TOKEN)"
check "the admin password of the MQTT broker is kept" "$mqtt_admin_password" "$(value mdm.env HMDM_MQTT_ADMIN_PASSWORD)"
grep -v '^HMDM_MQTT_ADMIN_PASSWORD=' "${MCLOUD}/mdm.env" > "${WORK}/mdm.env.old" && cp "${WORK}/mdm.env.old" "${MCLOUD}/mdm.env"
zbr "" start > /dev/null
check "the mdm.env of an earlier MCloud gets an admin password of the MQTT broker, the other secrets are kept" "32:${token}" \
  "$(value mdm.env HMDM_MQTT_ADMIN_PASSWORD | tr -d '\n' | wc -c | tr -d ' '):$(value mdm.env MDM_ENROLL_TOKEN)"
check "Headwind MDM gets the new one" "$(value mdm.env HMDM_MQTT_ADMIN_PASSWORD)" \
  "$(value configuration/mdm/env/mcloud-mdm-hmdm.env HMDM_MQTT_ADMIN_PASSWORD)"
check_not_contains "unchanged locations are not read again" "exec|stf-proxy|nginx|-s|reload" "$(calls docker)"
zbr "$SETUP_ANSWERS" setup > /dev/null
check "the setup keeps the enrollment token" "$token" "$(value mdm.env MDM_ENROLL_TOKEN)"
check "the setup keeps the MDM settings of .env" "true" "$(value .env MDM_ENABLED)"
touch "${MCLOUD}/configuration/mdm/android/mcloud-mdm-agent.apk"
check_not_contains "the agent APK is there" "mcloud-mdm-agent.apk is missing" "$(zbr "" start)"

section "a configuration of stf-proxy of a setup before the MDM"
cp "${MCLOUD}/.env" "${WORK}/env.current"
grep -vE '^(MDM_|TAG_MDM|TAG_NANOHUB|TAG_HMDM)' "${WORK}/env.current" > "${MCLOUD}/.env"
# no final newline
printf 'MDM_ENABLED=true\nMDM_SITE_ADDRESSES=203.0.113.10' >> "${MCLOUD}/.env"
zbr "" start > /dev/null
check "start adds the tags of the images of the MDM to the .env of an earlier MCloud" "0.1-develop-latest:0.2.0:9101" \
  "$(value .env TAG_MDM):$(value .env TAG_NANOHUB):$(value .env MDM_ADMIN_PORT)"
check "start keeps the settings of .env" "true:203.0.113.10" "$(value .env MDM_ENABLED):$(value .env MDM_SITE_ADDRESSES)"
check "start adds MDM_ENFORCE_NODE_BINDING=false to the .env of an earlier MCloud" "false" \
  "$(value .env MDM_ENFORCE_NODE_BINDING)"
check "every setting once" "1" "$(grep -c '^MDM_ENABLED=' "${MCLOUD}/.env")"
cp "${WORK}/env.current" "${MCLOUD}/.env"
conf="${MCLOUD}/configuration/stf-proxy/nginx.conf"
generated="$(cat "$conf")"
grep -v 'include /etc/nginx/mdm/' "$conf" > "${WORK}/nginx.conf.old"
cp "${WORK}/nginx.conf.old" "$conf"
shasum -a 256 "$conf" 2> /dev/null | cut -d ' ' -f 1 > "${conf}.sha256" || sha256sum "$conf" | cut -d ' ' -f 1 > "${conf}.sha256"
reset_calls
zbr "" start > /dev/null
check "start writes the includes of the MDM into a generated configuration" "$generated" "$(cat "$conf")"
check_contains "a running stf-proxy reads it again" "exec|stf-proxy|nginx|-s|reload" "$(calls docker)"
check_not_contains "the configuration is still the generated one" "changed by hand" "$(zbr "" start)"
cp "${WORK}/nginx.conf.old" "$conf"
echo "# a change by hand" >> "$conf"
output="$(zbr "" start)"
check_contains "a configuration changed by hand is reported" "was changed by hand and has no includes of the MDM" "$output"
check_contains "a configuration changed by hand is kept" "# a change by hand" "$(cat "$conf")"
printf '%s\n' "$generated" > "$conf"
shasum -a 256 "$conf" 2> /dev/null | cut -d ' ' -f 1 > "${conf}.sha256" || sha256sum "$conf" | cut -d ' ' -f 1 > "${conf}.sha256"

section "the options"
setting MDM_ADMIN_PUBLIC true
zbr "" start > /dev/null
check_contains "MDM_ADMIN_PUBLIC=true publishes the admin UI for the admins of STF" "auth_request /_hub_auth/admin;" \
  "$(cat "${MCLOUD}/${PROXY}/server-mdm.conf")"
check_contains "stf-proxy calls the admin UI with the admin token" \
  "proxy_set_header Authorization \"Bearer ${admin_token}\";" "$(cat "${MCLOUD}/${PROXY}/server-mdm.conf")"
check "the admin UI gets the scheme and the address of stf-proxy too" "6:6:6" \
  "$(forwarded "$(cat "${MCLOUD}/${PROXY}/server-mdm.conf")")"
setting MDM_SITE_ADDRESSES ""
check_contains "no address is reported" "MDM_SITE_ADDRESSES of .env has no address" "$(zbr "" start)"
check "no address: nobody reaches the MDM" "" "$(grep ' 1;$' "${MCLOUD}/${PROXY}/http-mdm.conf")"
setting ADB_RELAY true
reset_calls
zbr "" start > /dev/null
check "adb-relay and the MDM" "compose|--profile|adb-relay|--profile|mdm|up|-d" "$(compose_calls)"
setting ADB_RELAY false

section "stop, down, the MDM off, shutdown"
reset_calls
zbr "" stop > /dev/null
check "stop stops the MDM too" "compose|--profile|adb-relay|--profile|mdm|--profile|wireguard|stop" "$(compose_calls)"
reset_calls
zbr "" down > /dev/null
check "down removes the MDM too" "compose|--profile|adb-relay|--profile|mdm|--profile|wireguard|down" "$(compose_calls)"
setting MDM_ENABLED false
reset_calls
zbr "" start > /dev/null
check "MDM_ENABLED=false starts no profile mdm" "compose|up|-d" "$(compose_calls)"
check "MDM_ENABLED=false removes the locations" "" "$(ls "${MCLOUD}/${PROXY}"/*.conf 2> /dev/null)"
check "MDM_ENABLED=false keeps mdm.env (the passwords of the databases)" "yes" "$(exists mdm.env)"
zbr "" backup > /dev/null
check "backup copies mdm.env" "$token" "$(value mdm.env.bak MDM_ENROLL_TOKEN)"
reset_calls
printf 'y\n' | env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb COLUMNS=80 STUB_DIR="$WORK" \
  /bin/bash "${MCLOUD}/zebrunner.sh" shutdown > /dev/null 2>&1
check "shutdown removes the MDM with its volumes" "compose|--profile|adb-relay|--profile|mdm|--profile|wireguard|down|-v" "$(compose_calls | tail -n 1)"
check "shutdown removes mdm.env and its backup" "no:no" "$(exists mdm.env):$(exists mdm.env.bak)"
check "shutdown keeps the agent APK" "yes" "$(exists configuration/mdm/android/mcloud-mdm-agent.apk)"

finish
