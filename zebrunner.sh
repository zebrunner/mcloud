#!/bin/bash
# The management of the MCloud services: ./zebrunner.sh <command>, see echo_help.
# Zebrunner CE runs it with ZBR_INSTALLER=1 and its ZBR_* settings, the shutdown with SHUTDOWN_CONFIRMED=1.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

#### Commands

# setup: writes .env, variables.env and the nginx configuration from their *.original files
setup() {
  local url
  local is_new=1
  local sign_in="zebrunner"
  local agents_address=""
  local log_max_size=""
  local log_max_file=""
  local adb_relay_hosts=""
  local relay_settings=""
  local setting
  local agent_hosts=""
  # the settings of the previous setup (the generated secrets, the tokens) are kept
  if [[ -f variables.env ]]; then
    is_new=0
  fi
  # the addresses of the published ports of the previous setup (README.md#firewall), the legacy nodes
  if [[ -f .env ]]; then
    agents_address="$(sed -n 's/^AGENTS_ADDRESS=//p' .env)"
    agent_hosts="$(sed -n 's/^AGENT_HOSTS=//p' .env)"
    log_max_size="$(sed -n 's/^LOG_MAX_SIZE=//p' .env)"
    log_max_file="$(sed -n 's/^LOG_MAX_FILE=//p' .env)"
    adb_relay_hosts="$(sed -n 's/^ADB_RELAY_HOSTS=//p' .env)"
    relay_settings="$(grep -E '^ADB_RELAY(_PORTS|_SYNC_SECONDS)?=' .env)"
  fi
  # the variables of variables.env.original, overridden by the current variables.env, even the manual changes
  # shellcheck source=variables.env.original
  source variables.env.original
  if [[ "$is_new" -eq 0 ]]; then
    # shellcheck source=/dev/null
    source variables.env
  fi

  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    # Zebrunner CE installer: the sign-in of the last setup of this MCloud, Zebrunner IAM by default
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_PORT}"
    ZBR_MCLOUD_PORT=8082
    ZBR_MCLOUD_SIGN_IN="$(sed -n 's/^declare -x ZBR_MCLOUD_SIGN_IN="\(.*\)"$/\1/p' backup/settings.env 2> /dev/null)"
    export ZBR_MCLOUD_SIGN_IN="${ZBR_MCLOUD_SIGN_IN:-zebrunner}"
    sign_in="$ZBR_MCLOUD_SIGN_IN"
  elif grep -q '^declare -x ZBR_INSTALLER="1"$' backup/settings.env 2> /dev/null; then
    # this MCloud of Zebrunner CE (README.md#zebrunner-ce): the URL, the port and the certificate of the last setup of
    # Zebrunner CE (its nginx is in front of stf-proxy), only the admin and the sign-in are asked
    # shellcheck source=backup/settings.env.original
    source backup/settings.env.original
    # shellcheck source=/dev/null
    source backup/settings.env
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_PORT}"
    ZBR_MCLOUD_PORT=8082
    echo "Zebrunner MCloud of Zebrunner CE: ${url} (the setup of Zebrunner CE changes it)"
    set_admin
    set_sign_in "$url" zebrunner
    sign_in="$ZBR_MCLOUD_SIGN_IN"
  else
    # the defaults of the interactive setup
    # shellcheck source=backup/settings.env.original
    source backup/settings.env.original

    # the ZBR* variables of the previous setup
    if [[ -f backup/settings.env ]]; then
      # shellcheck source=/dev/null
      source backup/settings.env
    fi

    set_mcloud_settings
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}"
    set_sign_in "$url"
    sign_in="$ZBR_MCLOUD_SIGN_IN"
  fi

  # https: the certificate is checked before anything is written (README.md#https)
  if [[ "$ZBR_PROTOCOL" == "https" ]] && ! set_certificate; then
    exit 1
  fi

  # the authentication of RethinkDB, of ZeroMQ and of the grid registration (README.md#authentication-of-the-device-hosts):
  # the secrets of the previous setup are kept, the missing ones are made
  if [[ -z "$RETHINKDB_ENV_AUTHKEY" ]]; then
    RETHINKDB_ENV_AUTHKEY="$(random_string 48)"
  fi
  if [[ -z "$STF_ZMQ_CURVE_SERVER_SECRET_KEY" ]] && ! set_curve_keys; then
    exit 1
  fi
  if [[ -z "$NODE_REGISTRATION_TOKEN" ]]; then
    NODE_REGISTRATION_TOKEN="$(random_string 48)"
  fi

  cp .env.original .env
  replace .env "STF_URL=http://localhost:8082" "STF_URL=${url}"
  replace .env "STF_PORT=8082" "STF_PORT=${ZBR_MCLOUD_PORT}"
  replace .env "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=${agents_address:-0.0.0.0}"
  replace .env "AGENT_HOSTS=" "AGENT_HOSTS=${agent_hosts}"
  replace .env "ADB_RELAY_HOSTS=" "ADB_RELAY_HOSTS=${adb_relay_hosts}"
  # the settings of the auto mode of adb-relay of the previous setup
  while read -r setting; do
    if [[ -n "$setting" ]]; then
      replace .env "$(grep "^${setting%%=*}=" .env)" "$setting"
    fi
  done <<< "$relay_settings"
  replace .env "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=${log_max_size:-50m}"
  replace .env "LOG_MAX_FILE=5" "LOG_MAX_FILE=${log_max_file:-5}"
  check_agent_hosts
  write_adb_relay_hosts

  # the sign-in unit of STF and its path: the choice of the interactive setup, Zebrunner IAM in Zebrunner CE by default
  case "$sign_in" in
  zebrunner)
    replace .env "AUTH_SYSTEM=auth-mock" "AUTH_SYSTEM=auth-zebrunner"
    replace .env "AUTH_URL=auth/mock/" "AUTH_URL=auth/zebrunner/"
    ;;
  oauth2)
    replace .env "AUTH_SYSTEM=auth-mock" "AUTH_SYSTEM=auth-oauth2"
    replace .env "AUTH_URL=auth/mock/" "AUTH_URL=auth/oauth/"
    ;;
  ldap)
    replace .env "AUTH_SYSTEM=auth-mock" "AUTH_SYSTEM=auth-ldap"
    replace .env "AUTH_URL=auth/mock/" "AUTH_URL=auth/ldap/"
    ;;
  esac
  # the shared password of the mock sign-in, which takes any name and email behind it
  if [[ "$sign_in" == "mock" && -z "$STF_AUTH_MOCK_BASIC_AUTH_PASSWORD" ]]; then
    STF_AUTH_MOCK_BASIC_AUTH_PASSWORD="$(random_string 24)"
  fi

  # the placeholder of variables.env.original; a change of the secret would end the sessions and invalidate the access
  # tokens (STF_TOKEN) of the deployment, so the one of the previous setup is kept
  if [[ -z "$SECRET" || "$SECRET" == "password" ]]; then
    SECRET="$(random_string 48)"
  fi
  if [[ -z "$STF_STORAGE_TOKEN" ]]; then
    STF_STORAGE_TOKEN="$(random_string 64)"
  fi

  # the variables added to variables.env (e.g. STF_ZMQ_CURVE_CLIENT_KEY_<HOST> of the device hosts) are added again
  local added=""
  if [[ "$is_new" -eq 0 ]]; then
    added="$(awk -F '=' 'NR == FNR { if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) known[$1] = 1; next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ && !($1 in known)' variables.env.original variables.env)"
  fi
  cp variables.env.original variables.env
  replace variables.env "http://localhost:8082" "${url}"
  replace variables.env "localhost" "${ZBR_HOSTNAME}"

  replace variables.env "STF_TOKEN=" "STF_TOKEN=${STF_TOKEN}"
  replace variables.env "NODE_REGISTRATION_TOKEN=" "NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}"
  replace variables.env "SECRET=password" "SECRET=${SECRET}"
  replace variables.env "STF_STORAGE_TOKEN=" "STF_STORAGE_TOKEN=${STF_STORAGE_TOKEN}"
  replace variables.env "RETHINKDB_ENV_AUTHKEY=" "RETHINKDB_ENV_AUTHKEY=${RETHINKDB_ENV_AUTHKEY}"
  replace variables.env "STF_ZMQ_CURVE_SERVER_SECRET_KEY=" "STF_ZMQ_CURVE_SERVER_SECRET_KEY=${STF_ZMQ_CURVE_SERVER_SECRET_KEY}"
  replace variables.env "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${STF_ZMQ_CURVE_SERVER_PUBLIC_KEY}"
  replace variables.env "STF_ZMQ_CURVE_SECRET_KEY=" "STF_ZMQ_CURVE_SECRET_KEY=${STF_ZMQ_CURVE_SECRET_KEY}"
  replace variables.env "STF_ZMQ_CURVE_CLIENT_KEYS=" "STF_ZMQ_CURVE_CLIENT_KEYS=${STF_ZMQ_CURVE_CLIENT_KEYS}"
  # the settings of the sign-in, quoted: the values the user typed are not read as a script by the next setup
  if [[ "$sign_in" == "oauth2" ]]; then
    # shellcheck disable=SC2034 # read by the loop below through ${!name}
    OAUTH_CALLBACK_URL="${url}/auth/oauth/callback"
  fi
  local name
  for name in STF_AUTH_MOCK_BASIC_AUTH_USERNAME STF_AUTH_MOCK_BASIC_AUTH_PASSWORD OAUTH_AUTHORIZATION_URL \
    OAUTH_TOKEN_URL OAUTH_USERINFO_URL OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET OAUTH_CALLBACK_URL OAUTH_SCOPE OAUTH_DOMAIN \
    LDAP_URL LDAP_BIND_DN LDAP_BIND_CREDENTIALS LDAP_SEARCH_DN LDAP_SEARCH_FIELD; do
    replace variables.env "${name}=''" "${name}='${!name}'"
  done
  if [[ -z "$ZBR_MCLOUD_ADMIN_NAME" && -n "$STF_ADMIN_NAME" ]]; then
    ZBR_MCLOUD_ADMIN_NAME="$STF_ADMIN_NAME"
  fi
  if [[ -z "$ZBR_MCLOUD_ADMIN_EMAIL" && -n "$STF_ADMIN_EMAIL" ]]; then
    ZBR_MCLOUD_ADMIN_EMAIL="$STF_ADMIN_EMAIL"
  fi
  replace variables.env "STF_ROOT_GROUP_NAME=MCloud" "STF_ROOT_GROUP_NAME=${STF_ROOT_GROUP_NAME}"
  replace variables.env "STF_ADMIN_NAME=admin" "STF_ADMIN_NAME=${ZBR_MCLOUD_ADMIN_NAME}"
  replace variables.env "STF_ADMIN_EMAIL=admin@zebrunner.com" "STF_ADMIN_EMAIL=${ZBR_MCLOUD_ADMIN_EMAIL}"

  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    # auth-zebrunner of STF signs in through Zebrunner IAM
    replace variables.env "ZEBRUNNER_LOGIN_URL=" "ZEBRUNNER_LOGIN_URL=${url}/api/iam/v1/auth/login"
    replace variables.env "ZEBRUNNER_USERINFO_URL=" "ZEBRUNNER_USERINFO_URL=${url}/api/iam/v1/users"
  fi
  if [[ -n "$added" ]]; then
    printf '%s\n' "$added" >> variables.env
  fi

  cp configuration/stf-proxy/nginx.conf.original configuration/stf-proxy/nginx.conf
  replace configuration/stf-proxy/nginx.conf "server_name localhost" "server_name '${ZBR_HOSTNAME}'"
  # the ssl protocol of the default NGiNX configuration with the certificate of set_certificate
  if [[ "$ZBR_PROTOCOL" == "https" ]]; then
    replace configuration/stf-proxy/nginx.conf "listen 80" "listen 80 ssl"

    # uncomment the default ssl settings
    replace configuration/stf-proxy/nginx.conf "#    ssl_" "    ssl_"
  fi

  # the user input for the next setup
  export_settings
  write_stf_token
  protect_files

  echo "
      Enroll every node (a device host of mcloud-agent) once the services run with STF_TOKEN of variables.env:
      ./zebrunner.sh node-invite <label> <address> prints the join string for ./zebrunner.sh join of mcloud-agent on
      the node (README.md#nodes); https only."
  if [[ "$sign_in" == "mock" ]]; then
    echo "
      The sign-in of STF asks the user '${STF_AUTH_MOCK_BASIC_AUTH_USERNAME}' and the password '${STF_AUTH_MOCK_BASIC_AUTH_PASSWORD}' (STF_AUTH_MOCK_BASIC_AUTH_* of
      variables.env), then any name and email: share them with the users of STF only."
  fi
}

# shutdown: removes the services, their data and the settings
shutdown() {
  if [[ -f .disabled ]]; then
    rm -f .disabled
    exit 0 # no need to proceed as nothing was configured
  fi

  if [[ ! -f .env ]]; then
    echo_warning "Unable to erase as nothing is configured!"
    exit 0 # no need to proceed as nothing was configured
  fi

  if [[ "$SHUTDOWN_CONFIRMED" -ne 1 ]]; then
    # ask about confirmation if it is not confirmed in scope of CE
    echo_warning "Shutdown will erase all settings and data for \"${BASEDIR}\"!"
    if ! confirm "" "      Do you want to continue?" "n"; then
      exit
    fi
  fi

  docker compose --profile adb-relay down -v

  rm -f backup/settings.env
  rm -f .env
  rm -f variables.env
  rm -f configuration/stf-proxy/nginx.conf
  rm -f configuration/stf-proxy/agent-hosts.conf
  rm -f configuration/adb-relay/relay-hosts.conf
  rm -f configuration/adb-relay/stf-token
  rm -f configuration/stf-proxy/htpasswd/mcloud.htpasswd
  # the certificate of https is the one of the user (README.md#https), it is kept
}

# start: starts the services, the first start runs the setup instead
start() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # the infra network is shared with the other Zebrunner components
  docker network inspect infra > /dev/null 2>&1 || docker network create infra

  if [[ ! -f .env ]]; then
    # need proceed with setup steps in advance!
    setup
    exit 1
  fi

  protect_files
  # AGENT_HOSTS and ADB_RELAY_HOSTS of .env may have changed since the setup
  check_agent_hosts
  write_adb_relay_hosts
  check_adb_relay_auto
  write_stf_token
  # adb-relay runs with relay hosts or in the auto mode only (README.md#remote-debug-through-the-adb-relay)
  if [[ -n "$adb_relay" ]]; then
    docker compose --profile adb-relay up -d || return
  else
    docker compose up -d || return
  fi

  # the next steps of a deployment without Zebrunner CE (README.md#run)
  if [[ "$ZBR_INSTALLER" -ne 1 ]]; then
    local url
    url="$(sed -n 's/^STF_URL=//p' .env)"
    echo "
      MCloud: ${url}/stf, the Selenium/Appium hub: ${url}/mcloud/wd/hub, the devices: ${url}/mcloud/grid/console"
    if [[ -z "$(sed -n 's/^STF_TOKEN=//p' variables.env 2> /dev/null)" ]]; then
      echo_warning "STF_TOKEN of variables.env is empty: the grid reserves no device. Sign in to ${url}/stf, generate an access token (Settings, Keys), set it as STF_TOKEN of variables.env and run ./zebrunner.sh restart."
    fi
  fi
}

# stop: stops the services, the containers are kept
stop() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # with the profile: adb-relay stops also when ADB_RELAY_HOSTS was cleared after its start
  docker compose --profile adb-relay stop
}

# down: stops and removes the containers, the data is kept
down() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # with the profile: adb-relay is removed also when ADB_RELAY_HOSTS was cleared after its start
  docker compose --profile adb-relay down
}

# backup: copies the settings to *.bak and the database into backup/rethinkdb.tar.gz
backup() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  cp variables.env variables.env.bak
  cp .env .env.bak
  cp backup/settings.env backup/settings.env.bak
  cp configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.bak
  if [[ -f configuration/stf-proxy/htpasswd/mcloud.htpasswd ]]; then
    cp configuration/stf-proxy/htpasswd/mcloud.htpasswd configuration/stf-proxy/htpasswd/mcloud.htpasswd.bak
  fi

  if [[ -f configuration/stf-proxy/ssl/ssl.crt ]]; then
    cp configuration/stf-proxy/ssl/ssl.crt configuration/stf-proxy/ssl/ssl.crt.bak
  fi
  if [[ -f configuration/stf-proxy/ssl/ssl.key ]]; then
    cp configuration/stf-proxy/ssl/ssl.key configuration/stf-proxy/ssl/ssl.key.bak
  fi

  # RethinkDB writes its files while it runs: the database and the STF units are stopped for the copy, the ones that
  # ran start again
  local running
  local status=0
  running="$(docker compose ps --services --status running 2> /dev/null | grep -E '^(rethinkdb|stf-)' | grep -vx 'stf-proxy')"
  if [[ -n "$running" ]]; then
    # shellcheck disable=SC2086 # the services, one per line
    docker compose stop $running
  fi
  # the archive of the container is of root: it gets the user and the mode of protect_files there
  docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "rethinkdb:$(rethinkdb_tag)" sh -c \
    "tar -czf /var/backup/rethinkdb.tar.gz /data && chown $(id -u):$(id -g) /var/backup/rethinkdb.tar.gz && chmod 600 /var/backup/rethinkdb.tar.gz" ||
    status=$?
  if [[ -n "$running" ]]; then
    # shellcheck disable=SC2086
    docker compose start $running
  fi
  protect_files
  if [[ "$status" -ne 0 ]]; then
    echo_warning "The database was not archived into backup/rethinkdb.tar.gz."
  fi
  return "$status"
}

# rethinkdb_tag: the tag of the image of RethinkDB (TAG_RETHINKDB of .env), it archives and extracts the database
rethinkdb_tag() {
  local tag
  tag="$(sed -n 's/^TAG_RETHINKDB=//p' .env 2> /dev/null)"
  echo "${tag:-$(sed -n 's/^TAG_RETHINKDB=//p' .env.original)}"
}

# restore: the settings and the database of the backup, the services are stopped
restore() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  stop
  cp variables.env.bak variables.env
  cp .env.bak .env
  cp backup/settings.env.bak backup/settings.env
  cp configuration/stf-proxy/nginx.conf.bak configuration/stf-proxy/nginx.conf
  if [[ -f configuration/stf-proxy/htpasswd/mcloud.htpasswd.bak ]]; then
    cp configuration/stf-proxy/htpasswd/mcloud.htpasswd.bak configuration/stf-proxy/htpasswd/mcloud.htpasswd
  fi

  if [[ -f configuration/stf-proxy/ssl/ssl.crt.bak ]]; then
    cp configuration/stf-proxy/ssl/ssl.crt.bak configuration/stf-proxy/ssl/ssl.crt
  fi
  if [[ -f configuration/stf-proxy/ssl/ssl.key.bak ]]; then
    cp configuration/stf-proxy/ssl/ssl.key.bak configuration/stf-proxy/ssl/ssl.key
  fi

  protect_files
  docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "rethinkdb:$(rethinkdb_tag)" bash -c "cd / && tar -xzvf /var/backup/rethinkdb.tar.gz"
  down
}

# version: the version of MCloud, the tag of the STF image
version() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # shellcheck source=.env.original
  source .env
  echo "mcloud: ${TAG_STF}"
}

#### Nodes

# The port of the grid the nodes register on (docker-compose.yml: ${AGENTS_ADDRESS}:4446)
GRID_PORT=4446

# node_invite <label> <address> [<minutes>]: an invite of a node (README.md#nodes): prints the join string for
# ./zebrunner.sh join of mcloud-agent on the node once, with the pin of the certificate of stf-proxy
node_invite() {
  local label="$1"
  local address
  local minutes="$3"
  local pin host port invite expires body
  if ! require_setup; then
    return 1
  fi
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: ./zebrunner.sh node-invite <label> <address> [<minutes>]"
    return 1
  fi
  address="$(tr '[:upper:]' '[:lower:]' <<< "$2")"
  if ! valid_label "$label" || ! node_address "$address"; then
    return 1
  fi
  if [[ -n "$minutes" ]] && { [[ ! "$minutes" =~ ^[0-9]{1,4}$ ]] || ((10#$minutes < 1 || 10#$minutes > 1440)); }; then
    echo_warning "The validity of the invite '${minutes}' is not a number of minutes from 1 to 1440 (60 by default)."
    return 1
  fi
  if [[ "$(sed -n 's/^STF_URL=//p' .env)" != https://* || ! -f configuration/stf-proxy/ssl/ssl.crt ]]; then
    echo_warning "The enrollment needs https of stf-proxy: the node trusts the pin of its certificate only. Set up MCloud with https (README.md#https)."
    return 1
  fi
  if ! pin="$(certificate_pin)"; then
    echo_warning "The pin of configuration/stf-proxy/ssl/ssl.crt cannot be made: it needs openssl or python3 and a PEM certificate."
    return 1
  fi
  body="{\"label\":\"${label}\",\"address\":\"${address}\"${minutes:+,\"ttlMinutes\":$((10#$minutes))}}"
  if ! stf_api POST /api/v1/nodes/invites "$body"; then
    api_error "The invite of the node ${label}"
    return 1
  fi
  invite="$(json_value invite <<< "$api_body")"
  expires="$(json_value expiresAt <<< "$api_body")"
  if [[ ! "$invite" =~ ^mci1\.[A-Za-z0-9_-]+$ ]]; then
    echo_warning "The STF API answered the invite without one (docker logs stf-api)."
    return 1
  fi
  host="$(join_host)"
  port="$(sed -n 's/^STF_PORT=//p' .env)"
  echo "
      The invite of the node ${label} at ${address}, valid ${minutes:-60} minutes (until ${expires:-?}), for one join:

mcloud-join://${host}:${port}?label=${label}&grid=${host}:${GRID_PORT}&pin=$(url_encode "$pin")&token=${invite}

      It is a secret, shown once: paste it into ./zebrunner.sh join of mcloud-agent on the node ${label} (it reads it
      from stdin, never put it into the arguments), valid ${minutes:-60} minutes. A new invite of ${label} replaces it.
      The node checks the certificate of stf-proxy by its pin (SHA-256 of its public key): ${pin}"
}

# nodes [list|revoke <label>|delete <label>|legacy-off]: the registry of the nodes of STF (README.md#nodes)
nodes() {
  if ! require_setup; then
    return 1
  fi
  case "${1:-list}" in
  list)
    nodes_list
    ;;
  revoke)
    if [[ $# -ne 2 ]] || ! valid_label "$2"; then
      echo "Usage: ./zebrunner.sh nodes revoke <label>"
      return 1
    fi
    if ! stf_api POST "/api/v1/nodes/${2}/revoke" '{}'; then
      api_error "The revocation of the node ${2}"
      return 1
    fi
    echo "The node ${2} is revoked: its token and its key are refused, its devices are not bound to it any more."
    # the open ZeroMQ sessions of the node end with its triproxy connections, a new one is refused
    if ! docker restart stf-triproxy-app stf-triproxy-dev > /dev/null; then
      echo_warning "stf-triproxy-app and stf-triproxy-dev did not restart: the open ZeroMQ sessions of ${2} go on until ./zebrunner.sh restart."
      return 1
    fi
    echo "The triproxies restarted: the open ZeroMQ sessions of ${2} ended. A new invite enrolls the node again."
    ;;
  delete)
    if [[ $# -ne 2 ]] || ! valid_label "$2"; then
      echo "Usage: ./zebrunner.sh nodes delete <label>"
      return 1
    fi
    if ! stf_api DELETE "/api/v1/nodes/${2}"; then
      api_error "The removal of the node ${2} (a revoked one only: ./zebrunner.sh nodes revoke ${2})"
      return 1
    fi
    echo "The node ${2} is removed from the registry: its label and its address are free again."
    ;;
  legacy-off)
    nodes_legacy_off
    ;;
  *)
    echo "Usage: ./zebrunner.sh nodes [list|revoke <label>|delete <label>|legacy-off]"
    return 1
    ;;
  esac
}

# nodes_list: the nodes of the registry of STF, a line per node
nodes_list() {
  local nodes line
  if ! stf_api GET /api/v1/nodes; then
    api_error "The list of the nodes"
    return 1
  fi
  # a line per object of a node: they have no nested objects
  nodes="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep '"label"')"
  if [[ -z "$nodes" ]]; then
    echo "No node is enrolled: ./zebrunner.sh node-invite <label> <address> (README.md#nodes)."
    return 0
  fi
  printf '%-20s %-24s %-8s %-20s %-20s %s\n' LABEL ADDRESS STATUS "LAST SEEN" ENROLLED KEY
  while read -r line; do
    printf '%-20s %-24s %-8s %-20s %-20s %s\n' "$(json_value label <<< "$line")" "$(json_value address <<< "$line")" \
      "$(json_value status <<< "$line")" "$(json_time lastSeenAt <<< "$line")" "$(json_time createdAt <<< "$line")" \
      "$(json_value publicKey <<< "$line" | cut -c 1-16)..."
  done <<< "$nodes"
}

# nodes_legacy_off: the end of the migration to the enrollment (README.md#migration-from-the-manual-settings): empties the
# keys of the legacy nodes and AGENT_HOSTS, makes new NODE_REGISTRATION_TOKEN and STF_STORAGE_TOKEN, restarts
nodes_legacy_off() {
  local keys
  keys="$(sed -n 's/^\(STF_ZMQ_CURVE_CLIENT_KEYS\{0,1\}[A-Za-z0-9_]*\)=..*/\1/p' variables.env | tr '\n' ' ')"
  echo_warning "legacy-off turns the manual settings of the nodes off: it empties STF_ZMQ_CURVE_CLIENT_KEYS and every
      STF_ZMQ_CURVE_CLIENT_KEY_<HOST> of variables.env (set: ${keys:-none}) and AGENT_HOSTS of .env, makes new
      NODE_REGISTRATION_TOKEN and STF_STORAGE_TOKEN of variables.env and restarts the services. Every node that is not
      enrolled stops working: STF refuses its key, the grid its registration and the storage its uploads. The enrolled
      nodes go on with their own key and token:"
  nodes_list
  if ! confirm "" "      Turn the legacy settings off and restart?" "n"; then
    echo "Nothing is changed."
    return 0
  fi
  local content
  content="$(LEGACY_GRID_TOKEN="$(random_string 48)" LEGACY_STORAGE_TOKEN="$(random_string 64)" awk '
    /^STF_ZMQ_CURVE_CLIENT_KEYS=/ || /^STF_ZMQ_CURVE_CLIENT_KEY_[A-Za-z0-9_]*=/ { sub(/=.*/, "="); print; next }
    /^NODE_REGISTRATION_TOKEN=/ { print "NODE_REGISTRATION_TOKEN=" ENVIRON["LEGACY_GRID_TOKEN"]; next }
    /^STF_STORAGE_TOKEN=/ { print "STF_STORAGE_TOKEN=" ENVIRON["LEGACY_STORAGE_TOKEN"]; next }
    { print }' variables.env)"
  if [[ "$content" != *"NODE_REGISTRATION_TOKEN="?* || "$content" != *"STF_STORAGE_TOKEN="?* ]]; then
    echo_warning "variables.env has no NODE_REGISTRATION_TOKEN or STF_STORAGE_TOKEN: run ./zebrunner.sh setup first, nothing is changed."
    return 1
  fi
  # in place: variables.env keeps its mode
  printf '%s\n' "$content" > variables.env
  sed -i.orig 's/^AGENT_HOSTS=.*/AGENT_HOSTS=/' .env && rm -f .env.orig
  protect_files
  echo "The legacy settings are off: NODE_REGISTRATION_TOKEN and STF_STORAGE_TOKEN of variables.env are new, the keys of
      the legacy nodes and AGENT_HOSTS are empty. The services restart."
  down
  start
}

# require_setup: succeeds when MCloud is set up, warns otherwise
require_setup() {
  if [[ -f .env && -f variables.env ]]; then
    return 0
  fi
  echo_warning "MCloud is not set up: run ./zebrunner.sh setup first."
  return 1
}

# valid_label <label>: succeeds for a label of a node, warns otherwise
valid_label() {
  if [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    return 0
  fi
  echo_warning "'${1}' is not a label of a node: 1-40 lower case letters, digits and -, not - first."
  return 1
}

# node_address <address>: succeeds for the address of a node, an IPv4 address or a host name the server connects to
# (STF_PROVIDER_HOST of the node), not of the server itself or of the link; warns otherwise
node_address() {
  local octets=()
  if relay_host "$1" && [[ "$1" != localhost && "$1" != *.localhost ]]; then
    if [[ ! "$1" =~ ^[0-9.]+$ ]]; then
      return 0
    fi
    IFS='.' read -r -a octets <<< "$1"
    # 0/8, loopback, link-local (the metadata of the clouds), multicast and the broadcast
    if ((10#${octets[0]} != 0 && 10#${octets[0]} != 127 && 10#${octets[0]} < 224)) &&
      ! ((10#${octets[0]} == 169 && 10#${octets[1]} == 254)); then
      return 0
    fi
  fi
  echo_warning "'${1}' is not the address of a node: an IPv4 address or a host name without the protocol and the port, not a loopback, link-local or multicast one."
  return 1
}

# certificate_pin: base64 of the SHA-256 of the public key (DER SPKI) of configuration/stf-proxy/ssl/ssl.crt, the pin of
# curl --pinnedpubkey of the node: by openssl, by patch/spki_pin.py without it
certificate_pin() {
  local crt="configuration/stf-proxy/ssl/ssl.crt"
  local pin=""
  pin="$(openssl x509 -in "$crt" -noout -pubkey 2> /dev/null | openssl pkey -pubin -outform DER 2> /dev/null |
    openssl dgst -sha256 -binary 2> /dev/null | openssl base64 -A 2> /dev/null)"
  if [[ ! "$pin" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    pin="$(python3 "${BASEDIR}/patch/spki_pin.py" "$crt" 2> /dev/null)"
  fi
  if [[ ! "$pin" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    return 1
  fi
  echo "$pin"
}

# url_encode <base64>: the characters of base64 that are not URL-safe, percent-encoded
url_encode() {
  local value="${1//+/%2B}"
  value="${value//\//%2F}"
  echo "${value//=/%3D}"
}

# join_host: the host the nodes reach stf-proxy, the grid and ZeroMQ at: AGENTS_ADDRESS of .env (their ports are
# published there), the host of STF_URL when it is every address of the server
join_host() {
  local address
  address="$(sed -n 's/^AGENTS_ADDRESS=//p' .env)"
  case "$address" in
  "" | 0.0.0.0 | "::" | "[::]")
    address="$(sed -n 's/^STF_URL=//p' .env)"
    address="${address#*://}"
    address="${address%%/*}"
    echo "${address%:*}"
    ;;
  *)
    echo "$address"
    ;;
  esac
}

# stf_api <method> <path> [<JSON body>]: a request to the STF API through stf-proxy on the loopback address of the
# server with STF_TOKEN of variables.env; sets api_status (the HTTP status, 000 without an answer) and api_body; fails
# unless the status is 2xx
stf_api() {
  local token url port answer
  local args=(-sS -k --max-time 30 -X "$1" -H "Accept: application/json" -w '\n%{http_code}' -K -)
  api_status="000"
  api_body=""
  token="$(stf_token)"
  if [[ -z "$token" ]]; then
    echo_warning "STF_TOKEN of variables.env is empty: set an access token of an admin of STF there (Settings, Keys) and run ./zebrunner.sh restart."
    return 1
  fi
  url="$(sed -n 's/^STF_URL=//p' .env)"
  port="$(sed -n 's/^STF_PORT=//p' .env)"
  if [[ -n "$3" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "$3")
  fi
  # the certificate of stf-proxy is the one of the public name, not of the loopback address; the token is in the
  # configuration of curl on its stdin, the arguments are seen by every user of the server
  answer="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl "${args[@]}" "${url%%://*}://127.0.0.1:${port}${2}")"
  api_status="${answer##*$'\n'}"
  api_body="${answer%$'\n'*}"
  [[ "$api_status" =~ ^2[0-9][0-9]$ ]]
}

# api_error <action>: why a request of stf_api failed; the API answers the details in the log of stf-api only
api_error() {
  local reason
  case "$api_status" in
  000) reason="stf-proxy does not answer on 127.0.0.1:$(sed -n 's/^STF_PORT=//p' .env) (./zebrunner.sh start)" ;;
  401) reason="STF_TOKEN of variables.env is not a valid access token of STF" ;;
  403) reason="refused: STF_TOKEN is not of an admin of STF, or the request is not allowed, see docker logs stf-api" ;;
  404) reason="not found: an unknown node, or the STF of TAG_STF has no registry of the nodes" ;;
  400) reason="refused as invalid (a label or an address of another node?), see docker logs stf-api" ;;
  *) reason="the STF API answered ${api_status}, see docker logs stf-api" ;;
  esac
  echo_warning "${1} failed: ${reason}."
}

# json_value <name>: the value of a field of a flat JSON object (stdin), a string without its quotes; empty for null
json_value() {
  sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*(\"([^\"]*)\"|([^,}\"]*)).*/\2\3/p" | head -1 | sed 's/^null$//'
}

# json_time <name>: a time of a flat JSON object (stdin) to the second, - for none
json_time() {
  local time
  time="$(json_value "$1")"
  time="${time%%.*}"
  echo "${time:--}"
}

#### Helpers

# protect_files: the files the commands write belong to the owner of this folder, also after a sudo ./zebrunner.sh, and
# the ones with secrets are readable for it only: variables.env, backup/settings.env, the key of the certificate, the
# archive of the database and their backups (README.md#files-and-secrets)
protect_files() {
  local owner=""
  local file
  if [[ "$(id -u)" -eq 0 ]]; then
    owner="$(stat -c '%u:%g' . 2> /dev/null || stat -f '%u:%g' .)"
  fi
  for file in .env .env.bak variables.env variables.env.bak backup/settings.env backup/settings.env.bak \
    configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.bak \
    configuration/adb-relay/relay-hosts.conf configuration/adb-relay/stf-token configuration/stf-proxy/ssl/ssl.crt \
    configuration/stf-proxy/ssl/ssl.crt.bak \
    configuration/stf-proxy/ssl/ssl.key configuration/stf-proxy/ssl/ssl.key.bak backup/rethinkdb.tar.gz; do
    if [[ ! -f "$file" ]]; then
      continue
    fi
    if [[ -n "$owner" ]]; then
      chown "$owner" "$file"
    fi
    case "$file" in
    variables.env* | backup/settings.env* | */ssl.key* | */stf-token | backup/rethinkdb.tar.gz)
      chmod 600 "$file" 2> /dev/null
      ;;
    esac
  done
}

# The SHA-256 of the self-signed certificate and key the repositories of MCloud and Zebrunner CE had: the key is public
SHARED_SSL_CRT_SHA256="1fee845f65d86677768e4b49a67edfa7ebbe56bd37cb7ca1b393a8577040580d"
SHARED_SSL_KEY_SHA256="219bcec4e1f8bced27b4a335ab9cec720cd1f8bd452ce38cf7121ddbd523aebe"

# file_sha256 <file>: the SHA-256 of a file
file_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# set_certificate: configuration/stf-proxy/ssl/ssl.crt and ssl.key of https: the user puts them there, Zebrunner CE
# gives its own (../nginx/ssl, its nginx is in front of this one); fails without them, for a key that is not the one of
# the certificate and, but for Zebrunner CE, for the self-signed pair of the repository of Zebrunner CE
set_certificate() {
  local dir="configuration/stf-proxy/ssl"
  local shared=0
  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    if [[ ! -f "${BASEDIR}/../nginx/ssl/ssl.crt" || ! -f "${BASEDIR}/../nginx/ssl/ssl.key" ]]; then
      echo_warning "https needs the certificate of Zebrunner CE: ../nginx/ssl/ssl.crt and ../nginx/ssl/ssl.key are missing."
      return 1
    fi
    # a key of root only (e.g. of certbot) is not readable for the user of the setup: the copy would be an old one
    if ! cp "${BASEDIR}/../nginx/ssl/ssl.crt" "${dir}/ssl.crt" 2> /dev/null ||
      ! cp "${BASEDIR}/../nginx/ssl/ssl.key" "${dir}/ssl.key" 2> /dev/null; then
      echo_warning "The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied into ${dir}: make it readable for $(id -un) (README.md#troubleshooting)."
      return 1
    fi
  fi
  if [[ ! -f "${dir}/ssl.crt" || ! -f "${dir}/ssl.key" ]]; then
    echo_warning "https needs the certificate of ${ZBR_HOSTNAME}: put it into ${dir}/ssl.crt and its key into ${dir}/ssl.key (README.md#https)."
    return 1
  fi
  if [[ "$(file_sha256 "${dir}/ssl.crt")" == "$SHARED_SSL_CRT_SHA256" || "$(file_sha256 "${dir}/ssl.key")" == "$SHARED_SSL_KEY_SHA256" ]]; then
    shared=1
  fi
  if [[ "$shared" -eq 1 && "$ZBR_INSTALLER" -eq 1 ]]; then
    echo_warning "The certificate of Zebrunner CE (nginx/ssl) is the self-signed one of its repository, its private key is public: anyone can read and change the traffic of MCloud. Replace it with the certificate of ${ZBR_HOSTNAME}."
  elif [[ "$shared" -eq 1 ]]; then
    echo_warning "${dir}/ssl.crt and ssl.key are the self-signed pair of the repository of Zebrunner CE, its private key is public: replace them with the certificate of ${ZBR_HOSTNAME} (README.md#https)."
    return 1
  fi
  if command -v openssl > /dev/null 2>&1 &&
    [[ "$(openssl x509 -noout -pubkey -in "${dir}/ssl.crt" 2> /dev/null)" != "$(openssl pkey -pubout -in "${dir}/ssl.key" 2> /dev/null)" ]]; then
    echo_warning "${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM)."
    return 1
  fi
}

# ask <variable> <question> [optional]: reads a value of the interactive setup, the current one by default; a value
# with a quote or a backslash is asked again (variables.env keeps it in quotes), an empty one too unless optional
ask() {
  local name="$1"
  local question="$2"
  local optional="$3"
  local answer
  while true; do
    read -r -p "${question} [${!name}]: " answer
    answer="${answer:-${!name}}"
    if [[ "$answer" == *"'"* || "$answer" == *"\\"* ]]; then
      echo "Quotes and backslashes are not supported."
    elif [[ -n "$answer" || -n "$optional" ]]; then
      break
    else
      echo "A value is needed."
    fi
  done
  printf -v "$name" '%s' "$answer"
}

# ask_secret <variable> <question>: ask without echo, the current value is kept on an empty answer
ask_secret() {
  local name="$1"
  local question="$2"
  local answer
  while true; do
    read -r -s -p "${question} [$([[ -n "${!name}" ]] && echo keep)]: " answer
    echo
    answer="${answer:-${!name}}"
    if [[ "$answer" == *"'"* || "$answer" == *"\\"* ]]; then
      echo "Quotes and backslashes are not supported."
    elif [[ -n "$answer" ]]; then
      break
    else
      echo "A value is needed."
    fi
  done
  printf -v "$name" '%s' "$answer"
}

# check_agent_hosts: warns about the entries of AGENT_HOSTS of .env, the legacy nodes without enrollment whose screens
# stf-api allows (README.md#nodes), that are not a host name or an address; removes agent-hosts.conf, the list of
# stf-proxy of an earlier MCloud
check_agent_hosts() {
  local hosts=()
  local host
  rm -f configuration/stf-proxy/agent-hosts.conf 2> /dev/null
  IFS=',' read -r -a hosts <<< "$(sed -n 's/^AGENT_HOSTS=//p' .env)"
  for host in "${hosts[@]}"; do
    host="${host// /}"
    if [[ -n "$host" && ! "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
      echo_warning "'${host}' of AGENT_HOSTS of .env is not a host name or address: stf-api ignores it."
    fi
  done
}

# relay_host <host>: succeeds for a host name or an IPv4 address the relay connects to
relay_host() {
  local octets=()
  local octet
  if [[ "$1" =~ ^[0-9.]+$ ]]; then
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      return 1
    fi
    IFS='.' read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
      if ((10#$octet > 255)); then
        return 1
      fi
    done
    return 0
  fi
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# write_adb_relay_hosts: configuration/adb-relay/relay-hosts.conf of nginx from ADB_RELAY_HOSTS of .env: a server of
# adb-relay for every entry, a port or a port range of a device host (README.md#remote-debug-through-the-adb-relay); an
# invalid entry, one with a port of an earlier entry or of MCloud is skipped, a range is relayed with a warning (it
# also relays the screens); sets adb_relay to 1 when adb-relay has servers
write_adb_relay_hosts() {
  local file="configuration/adb-relay/relay-hosts.conf"
  local relay_hosts
  local entries=()
  local relays=()
  local firsts=()
  local lasts=()
  local entry host first last port i conflict
  local resolver=""
  local servers=""
  relay_hosts="$(sed -n 's/^ADB_RELAY_HOSTS=//p' .env)"
  relay_hosts="${relay_hosts// /}"
  # the ports MCloud publishes on the host (docker-compose.yml): nginx would not start with one of them
  local mcloud_ports=("$(sed -n 's/^STF_PORT=//p' .env)" 4446 7160 7250 7260 7270)
  adb_relay=""
  # a file of root (e.g. of `sudo ./zebrunner.sh`) cannot be written, adb-relay keeps the servers it has
  if ! : 2> /dev/null > "$file"; then
    echo_warning "${file} is not writable for $(id -un): remove it (rm -f ${file}) and run ./zebrunner.sh restart (README.md#troubleshooting)."
    if [[ -n "$relay_hosts" && -s "$file" ]]; then
      adb_relay=1
    fi
    return
  fi
  IFS=',' read -r -a entries <<< "$relay_hosts"
  for entry in "${entries[@]}"; do
    if [[ -z "$entry" ]]; then
      continue
    fi
    # <host>:<port> or <host>:<first>-<last>
    if [[ "$entry" =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
      host="${BASH_REMATCH[1]}"
      first=$((10#${BASH_REMATCH[2]}))
      last=$((10#${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}))
    else
      host=""
    fi
    if [[ -z "$host" ]] || ! relay_host "$host"; then
      echo_warning "'${entry}' of ADB_RELAY_HOSTS of .env is not <host>:<port> or <host>:<first port>-<last port> with a host name or an IPv4 address, it is skipped."
      continue
    fi
    if ((first < 1024 || last > 65535 || first > last)); then
      echo_warning "'${entry}' of ADB_RELAY_HOSTS of .env: the ports are 1024-65535 and the first one is not greater than the last one, it is skipped."
      continue
    fi
    conflict=""
    i=0
    while [[ "$i" -lt "${#firsts[@]}" ]]; do
      if ((first <= lasts[i] && last >= firsts[i])); then
        conflict="${relays[i]}"
        break
      fi
      i=$((i + 1))
    done
    if [[ -n "$conflict" ]]; then
      echo_warning "'${entry}' of ADB_RELAY_HOSTS of .env has a port of '${conflict}': a port is relayed to one device host only, it is skipped."
      continue
    fi
    for port in "${mcloud_ports[@]}"; do
      if [[ "$port" =~ ^[0-9]+$ ]] && ((port >= first && port <= last)); then
        conflict="$port"
        break
      fi
    done
    if [[ -n "$conflict" ]]; then
      echo_warning "'${entry}' of ADB_RELAY_HOSTS of .env holds the port ${conflict} of MCloud, it is skipped."
      continue
    fi
    relays+=("$entry")
    firsts+=("$first")
    lasts+=("$last")
    # a host name is resolved by nginx on every connection: the resolvers of the host, the image fills them in
    if [[ ! "$host" =~ ^[0-9.]+$ ]]; then
      # shellcheck disable=SC2016 # the variable of the template of the nginx image, not of this script
      resolver='resolver ${NGINX_LOCAL_RESOLVERS} valid=30s ipv6=off;'
    fi
    if [[ "$first" -eq "$last" ]]; then
      port="$first"
    else
      port="${first}-${last}"
      echo_warning "'${entry}' of ADB_RELAY_HOSTS of .env is a range: it also makes the screens of the devices public (their min_port), which have no sign-in of their own. Relay only the remote debug ports, min_port + 1 of every Android device: ./zebrunner.sh doctor of mcloud-agent prints them (README.md#remote-debug-through-the-adb-relay)."
    fi
    # shellcheck disable=SC2016 # $server_port is the variable of nginx: the port the user connected to
    servers+="$(printf 'server {\n  listen %s so_keepalive=on;\n  proxy_pass %s:$server_port;\n}' "$port" "$host")"$'\n'
  done
  if [[ -n "$servers" ]]; then
    if [[ -n "$resolver" ]]; then
      echo "$resolver" >> "$file"
    fi
    printf '%s' "$servers" >> "$file"
    adb_relay=1
  elif [[ -n "$relay_hosts" ]]; then
    echo_warning "ADB_RELAY_HOSTS of .env has no valid entry: adb-relay does not run (README.md#remote-debug-through-the-adb-relay)."
  fi
}

# check_adb_relay_auto: the auto mode of adb-relay, ADB_RELAY=true of .env (README.md#remote-debug-through-the-adb-relay):
# sets adb_relay to 1 and warns about the settings it needs
check_adb_relay_auto() {
  local auto
  local ports
  local seconds
  auto="$(sed -n 's/^ADB_RELAY=//p' .env)"
  case "$auto" in
  true) ;;
  "" | false)
    return
    ;;
  *)
    echo_warning "ADB_RELAY of .env is '${auto}', not true or false: the auto mode of adb-relay is off."
    return
    ;;
  esac
  adb_relay=1
  ports="$(sed -n 's/^ADB_RELAY_PORTS=//p' .env)"
  if [[ -n "$ports" ]] && ! valid_port_range "$ports"; then
    echo_warning "ADB_RELAY_PORTS of .env '${ports}' is not <first>-<last> of the ports 1024-65535: adb-relay relays no device of STF."
  fi
  seconds="$(sed -n 's/^ADB_RELAY_SYNC_SECONDS=//p' .env)"
  if [[ -n "$seconds" && ! "$seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo_warning "ADB_RELAY_SYNC_SECONDS of .env '${seconds}' is not a number of seconds: adb-relay reads the devices every 300 seconds."
  fi
  if [[ -z "$(stf_token)" ]]; then
    echo_warning "STF_TOKEN of variables.env is empty: adb-relay (ADB_RELAY=true) relays no device of STF. Set an access token of STF there (Settings, Keys) and run ./zebrunner.sh start: adb-relay reads it on its next sync."
  fi
}

# stf_token: STF_TOKEN of variables.env, without the quotes
stf_token() {
  sed -n "s/^STF_TOKEN=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" variables.env 2> /dev/null | tail -1
}

# write_stf_token: configuration/adb-relay/stf-token, STF_TOKEN of variables.env for the auto mode of adb-relay
# (ADB_RELAY=true of .env), empty otherwise: the only secret the relay on the network of the host gets, readable for
# its owner only and written in place (the relay reads it on every sync through its bind mount)
write_stf_token() {
  local file="configuration/adb-relay/stf-token"
  local token=""
  if [[ "$(sed -n 's/^ADB_RELAY=//p' .env)" == "true" ]]; then
    token="$(stf_token)"
  fi
  # a new file is made for the owner only, an existing one keeps its inode
  if ! (umask 077 && printf '%s\n' "$token" 2> /dev/null > "$file"); then
    echo_warning "${file} is not writable for $(id -un): remove it (rm -f ${file}) and run ./zebrunner.sh restart (README.md#troubleshooting)."
    return
  fi
  chmod 600 "$file"
}

# valid_port_range <first>-<last>: succeeds for a range of the ports 1024-65535
valid_port_range() {
  local first
  local last
  if [[ ! "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    return 1
  fi
  first=$((10#${BASH_REMATCH[1]}))
  last=$((10#${BASH_REMATCH[2]}))
  ((first >= 1024 && last <= 65535 && first <= last))
}

# set_sign_in <url> [zebrunner]: asks the sign-in of STF of the interactive setup and its settings (README.md#sign-in),
# zebrunner (Zebrunner IAM) is a choice and the default in Zebrunner CE
set_sign_in() {
  local answer
  local choices="mock|oauth2|ldap"
  local question="mock (any name and email behind a shared password), oauth2 (OpenID Connect) or ldap"
  if [[ "$2" == "zebrunner" ]]; then
    choices="zebrunner|${choices}"
    question="zebrunner (Zebrunner IAM of Zebrunner CE), ${question}"
  fi
  ZBR_MCLOUD_SIGN_IN="${ZBR_MCLOUD_SIGN_IN:-${2:-mock}}"
  while true; do
    read -r -p "Sign-in of STF: ${question} [${ZBR_MCLOUD_SIGN_IN}]: " answer
    answer="${answer:-$ZBR_MCLOUD_SIGN_IN}"
    if [[ "$answer" =~ ^(${choices})$ ]]; then
      ZBR_MCLOUD_SIGN_IN="$answer"
      break
    fi
    answer="${choices%|*}"
    echo "Please answer ${answer//|/, } or ${choices##*|}."
  done
  export ZBR_MCLOUD_SIGN_IN

  case "$ZBR_MCLOUD_SIGN_IN" in
  mock)
    STF_AUTH_MOCK_BASIC_AUTH_USERNAME="${STF_AUTH_MOCK_BASIC_AUTH_USERNAME:-mcloud}"
    ;;
  oauth2)
    echo "OAuth2 / OpenID Connect: the application of MCloud at the provider redirects to ${1}/auth/oauth/callback"
    ask OAUTH_AUTHORIZATION_URL "Authorization URL"
    ask OAUTH_TOKEN_URL "Token URL"
    ask OAUTH_USERINFO_URL "User info URL"
    ask OAUTH_CLIENT_ID "Client ID"
    ask_secret OAUTH_CLIENT_SECRET "Client secret"
    OAUTH_SCOPE="${OAUTH_SCOPE:-openid email}"
    ask OAUTH_SCOPE "Scope"
    ask OAUTH_DOMAIN "Email domain of the users, empty for any" optional
    ;;
  ldap)
    ask LDAP_URL "LDAP URL (ldap://host:389)"
    ask LDAP_BIND_DN "Bind DN, empty for an anonymous search" optional
    if [[ -n "$LDAP_BIND_DN" ]]; then
      ask_secret LDAP_BIND_CREDENTIALS "Bind password"
    fi
    ask LDAP_SEARCH_DN "Search DN of the users"
    LDAP_SEARCH_FIELD="${LDAP_SEARCH_FIELD:-uid}"
    ask LDAP_SEARCH_FIELD "Attribute of the user name"
    ;;
  esac
}

# curve_pair: `public=<key>` and `secret=<key>` of a new CURVE key pair of ZeroMQ, 64 hex characters as of
# `stf curve-keygen` (X25519): by openssl, by patch/curve_keygen.py where openssl has no X25519 (the LibreSSL of macOS)
curve_pair() {
  local pem
  local secret=""
  local public=""
  if pem="$(openssl genpkey -algorithm X25519 2> /dev/null)" && [[ -n "$pem" ]]; then
    # the DER of the keys ends with the 32 bytes of the key: PKCS#8 of the secret one (48 bytes), SPKI of the public one
    secret="$(printf '%s\n' "$pem" | openssl pkey -outform DER 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
    public="$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER 2> /dev/null | od -An -v -tx1 | tr -d ' \n')"
    if [[ ${#secret} -eq 96 && ${#public} -eq 88 ]]; then
      echo "public=${public:24}"
      echo "secret=${secret:32}"
      return
    fi
  fi
  python3 "${BASEDIR}/patch/curve_keygen.py" 2> /dev/null
}

# set_curve_keys: the CURVE keys of ZeroMQ of a new deployment (README.md#authentication-of-the-device-hosts): the pair of
# the triproxies and the secret key of the STF units; fails without openssl with X25519 and without python3
set_curve_keys() {
  local server
  local units
  server="$(curve_pair)"
  units="$(curve_pair)"
  STF_ZMQ_CURVE_SERVER_PUBLIC_KEY="$(sed -n 's/^public=//p' <<< "$server")"
  STF_ZMQ_CURVE_SERVER_SECRET_KEY="$(sed -n 's/^secret=//p' <<< "$server")"
  STF_ZMQ_CURVE_SECRET_KEY="$(sed -n 's/^secret=//p' <<< "$units")"
  local key
  for key in "$STF_ZMQ_CURVE_SERVER_PUBLIC_KEY" "$STF_ZMQ_CURVE_SERVER_SECRET_KEY" "$STF_ZMQ_CURVE_SECRET_KEY"; do
    if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then
      echo_warning "The setup makes the CURVE keys with openssl (X25519, OpenSSL 1.1.1+) or python3, neither works here: install one of them (README.md#system-requirements); nothing is written."
      return 1
    fi
  done
}

# ask_valid <variable> <question> <regex> <message>: reads a value of the interactive setup, the current one by default,
# until it matches the regex (the message tells why not); fails when the input ends with an invalid value
ask_valid() {
  local name="$1"
  local answer
  while true; do
    if ! read -r -p "${2} [${!name}]: " answer && [[ -z "$answer" && ! "${!name}" =~ $3 ]]; then
      echo
      echo_warning "${4}"
      exit 1
    fi
    answer="${answer:-${!name}}"
    if [[ "$answer" =~ $3 ]]; then
      break
    fi
    echo "$4"
  done
  printf -v "$name" '%s' "$answer"
}

# set_mcloud_settings: asks the protocol, host, port and the admin of the interactive setup
set_mcloud_settings() {
  echo "Zebrunner MCloud Settings"
  if [[ -z "$ZBR_HOSTNAME" ]]; then
    ZBR_HOSTNAME="$(curl -s ifconfig.me)"
  fi

  while true; do
    ask_valid ZBR_PROTOCOL "Protocol" '^https?$' "Please answer http or https."
    ask_valid ZBR_HOSTNAME "Fully qualified domain name (ip)" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
      "A host name or an IP address only, without the protocol, the port or a path."
    ask_valid ZBR_MCLOUD_PORT "Port" '^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$' \
      "A port number from 1 to 65535."

    if confirm "Zebrunner MCloud STF URL: ${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}/stf" "Continue?" "y"; then
      break
    fi
  done

  export ZBR_PROTOCOL
  export ZBR_HOSTNAME
  export ZBR_MCLOUD_PORT

  set_admin
}

# set_admin: asks the admin of STF of the interactive setup
set_admin() {
  local local_admin_name
  local local_admin_mail

  while true; do
    read -r -p "Admin username [${ZBR_MCLOUD_ADMIN_NAME}]: " local_admin_name
    if [[ -n "$local_admin_name" ]]; then
      ZBR_MCLOUD_ADMIN_NAME="$local_admin_name"
    fi

    read -r -p "Admin user email [${ZBR_MCLOUD_ADMIN_EMAIL}]: " local_admin_mail
    if [[ -n "$local_admin_mail" ]]; then
      ZBR_MCLOUD_ADMIN_EMAIL="$local_admin_mail"
    fi

    if confirm "Zebrunner MCloud admin username: ${ZBR_MCLOUD_ADMIN_NAME}; email: ${ZBR_MCLOUD_ADMIN_EMAIL}" "Continue?" "y"; then
      break
    fi
  done

  export ZBR_MCLOUD_ADMIN_NAME
  export ZBR_MCLOUD_ADMIN_EMAIL
}

# echo_help: the usage
echo_help() {
  echo "
      Usage: ./zebrunner.sh [option]
      Flags:
          --help | -h    Print help
      Arguments:
          setup          Setup the services
          start          Start container
          stop           Stop and keep container
          restart        Restart container
          down           Stop and remove container
          shutdown       Stop and remove container, clear volumes
          backup         Backup container
          restore        Restore container
          version        Version of container
          node-invite    <label> <address> [<minutes>]: the join string of a new node, a secret shown once
          nodes          [list]: the enrolled nodes; revoke <label>, delete <label>; legacy-off: the end of the manual
                         keys and tokens of the nodes (README.md#nodes)"
  echo_telegram
}

#### Main

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASEDIR" || exit

# shellcheck source=patch/utility.sh
source patch/utility.sh

# Zebrunner CE runs the setup with ZBR_INSTALLER=1, the setup of its MCloud reads ZBR_INSTALLER of its settings too
installer="${ZBR_INSTALLER:-0}"

case "$1" in
setup)
  setup
  # Zebrunner CE starts the services itself
  if [[ "$installer" -ne 1 ]]; then
    echo_warning "Your services need to be started after setup."
    if confirm "" "      Start now?" "y"; then
      start
    fi
  fi
  ;;
start)
  start
  ;;
stop)
  stop
  ;;
restart)
  down
  start
  ;;
down)
  down
  ;;
shutdown)
  shutdown
  ;;
backup)
  backup
  ;;
restore)
  restore
  ;;
version)
  version
  ;;
node-invite)
  if [[ -f .disabled ]]; then
    exit 0
  fi
  node_invite "${@:2}"
  exit
  ;;
nodes)
  if [[ -f .disabled ]]; then
    exit 0
  fi
  nodes "${@:2}"
  exit
  ;;
--help | -h)
  echo_help
  ;;
*)
  echo_help
  exit 1
  ;;
esac
