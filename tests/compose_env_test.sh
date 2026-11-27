#!/bin/bash
# Tests of the secrets of every service of docker-compose.yml: the variables of variables.env each service gets from
# `docker compose config` (every profile), with a value in every secret of variables.env. A service gets the secrets
# it uses only (README.md#files-and-secrets); docker compose reads the files only, no daemon is needed.
source "$(dirname "$0")/lib.sh"

require_cmd python3
docker compose version > /dev/null 2>&1 || skip "requires docker compose"

# the secrets of variables.env
SECRETS="SECRET STF_STORAGE_TOKEN RETHINKDB_ENV_AUTHKEY STF_ZMQ_CURVE_SERVER_SECRET_KEY STF_ZMQ_CURVE_SECRET_KEY
NODES_WG_PRIVATE_KEY STF_TOKEN GRID_AUTH_SECRET STF_AUTH_MOCK_BASIC_AUTH_PASSWORD STF_AUTH_MOCK_ADMIN_BASIC_AUTH_PASSWORD
OAUTH_CLIENT_SECRET LDAP_BIND_CREDENTIALS"

DIR="${WORK}/compose"
mkdir -p "$DIR"
cp "${REPO}/docker-compose.yml" "$DIR/"
cp "${REPO}/.env.original" "${DIR}/.env"
# every secret has a value, and the public CURVE key of the server
for name in $SECRETS; do
  grep -q "^${name}=" "${REPO}/variables.env.original" || fail "${name} is a variable of variables.env.original" "missing"
done
awk -v secrets=" $(tr '\n' ' ' <<< "$SECRETS") STF_ZMQ_CURVE_SERVER_PUBLIC_KEY " '
  { split($0, kv, "="); if (index(secrets, " " kv[1] " ")) print kv[1] "=value-of-" kv[1]; else print }
' "${REPO}/variables.env.original" > "${DIR}/variables.env"

# secrets_of_services: a line per service, `<service>: <the secrets it gets with a value, sorted>`
secrets_of_services() {
  (cd "$DIR" && docker compose --profile adb-relay --profile mdm --profile wireguard config --format json) |
    python3 -c '
import json, sys
secrets = sys.argv[1].split()
for name, service in sorted(json.load(sys.stdin)["services"].items()):
    env = service.get("environment") or {}
    got = sorted(key for key in secrets if env.get(key))
    print(name + ": " + " ".join(got))
' "$SECRETS"
}

section "the secrets of the services"
output="$(secrets_of_services)"
check "docker compose reads docker-compose.yml" "yes" "$([[ -n "$output" ]] && echo yes)"
DB=RETHINKDB_ENV_AUTHKEY
CURVE=STF_ZMQ_CURVE_SECRET_KEY
SIGN_IN="LDAP_BIND_CREDENTIALS OAUTH_CLIENT_SECRET $DB SECRET STF_AUTH_MOCK_ADMIN_BASIC_AUTH_PASSWORD \
STF_AUTH_MOCK_BASIC_AUTH_PASSWORD"
checked=" "
while read -r service expected; do
  checked="${checked}${service} "
  check "${service} gets ${expected:-no secret}" "${service}: ${expected}" "$(grep "^${service}: \?" <<< "$output")"
done << EOF2
adb-relay
mcloud-grid
mcloud-mdm
mcloud-mdm-ca
mcloud-mdm-hmdm
mcloud-mdm-hmdm-init
mcloud-mdm-mqtt
mcloud-mdm-mysql
mcloud-mdm-nanohub
mcloud-mdm-postgres
rethinkdb
stf-api $DB SECRET STF_STORAGE_TOKEN $CURVE
stf-api-groups-engine $DB $CURVE
stf-app $DB SECRET
stf-auth $SIGN_IN
stf-migrate $DB SECRET
stf-processor001 $DB $CURVE
stf-proxy
stf-reaper $DB $CURVE
stf-storage-plugin-apk
stf-storage-plugin-image
stf-storage-temp SECRET STF_STORAGE_TOKEN
stf-triproxy-app STF_STORAGE_TOKEN $CURVE STF_ZMQ_CURVE_SERVER_SECRET_KEY
stf-triproxy-dev STF_STORAGE_TOKEN $CURVE STF_ZMQ_CURVE_SERVER_SECRET_KEY
stf-websocket $DB SECRET $CURVE
wireguard
EOF2
# a new service gets its line above
check "every service is checked" "" "$(awk -F ':' -v checked="$checked" '!index(checked, " " $1 " ") { print $1 }' <<< "$output")"
# the units that connect to the triproxies need their public key with their own key
public="$(cd "$DIR" && docker compose config --format json | python3 -c '
import json, sys
for name, service in sorted(json.load(sys.stdin)["services"].items()):
    env = service.get("environment") or {}
    if env.get("STF_ZMQ_CURVE_SECRET_KEY") and not env.get("STF_ZMQ_CURVE_SERVER_PUBLIC_KEY"):
        print(name)
')"
check "the units with a CURVE key have the public key of the server" "" "$public"
check "the settings of variables.env reach the units" "MCloud" \
  "$(cd "$DIR" && docker compose config --format json | python3 -c '
import json, sys
print(json.load(sys.stdin)["services"]["stf-migrate"]["environment"]["STF_ROOT_GROUP_NAME"])')"

finish
