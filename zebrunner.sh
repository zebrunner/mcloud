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
  local relay_settings=""
  local setting
  # the settings of the previous setup (the generated secrets, the tokens) are kept
  if [[ -f variables.env ]]; then
    is_new=0
  fi
  # the addresses of the published ports of the previous setup (README.md#firewall)
  if [[ -f .env ]]; then
    agents_address="$(sed -n 's/^AGENTS_ADDRESS=//p' .env)"
    log_max_size="$(sed -n 's/^LOG_MAX_SIZE=//p' .env)"
    log_max_file="$(sed -n 's/^LOG_MAX_FILE=//p' .env)"
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

  # https: the certificate is checked before anything is written (README.md#https); a missing one is only reported, the
  # services start once it is there
  if [[ "$ZBR_PROTOCOL" == "https" ]] && ! set_certificate; then
    abort_setup
  fi

  # the authentication of RethinkDB, of ZeroMQ and of the grid registration (README.md#authentication-of-the-nodes):
  # the secrets of the previous setup are kept, the missing ones are made
  if [[ -z "$RETHINKDB_ENV_AUTHKEY" ]]; then
    RETHINKDB_ENV_AUTHKEY="$(random_string 48)"
  fi
  if [[ -z "$STF_ZMQ_CURVE_SERVER_SECRET_KEY" ]] && ! set_curve_keys; then
    abort_setup
  fi

  cp .env.original .env
  replace .env "STF_URL=http://localhost:8082" "STF_URL=${url}"
  replace .env "STF_PORT=8082" "STF_PORT=${ZBR_MCLOUD_PORT}"
  replace .env "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=${agents_address:-0.0.0.0}"
  # the settings of the auto mode of adb-relay of the previous setup
  while read -r setting; do
    if [[ -n "$setting" ]]; then
      replace .env "$(grep "^${setting%%=*}=" .env)" "$setting"
    fi
  done <<< "$relay_settings"
  replace .env "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=${log_max_size:-50m}"
  replace .env "LOG_MAX_FILE=5" "LOG_MAX_FILE=${log_max_file:-5}"
  set_nodes_host

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

  # the variables added to variables.env (e.g. STF_SESSION_TTL_SECONDS) are added again
  local added=""
  if [[ "$is_new" -eq 0 ]]; then
    added="$(awk -F '=' 'NR == FNR { if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) known[$1] = 1; next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ && !($1 in known)' variables.env.original variables.env)"
  fi
  cp variables.env.original variables.env
  replace variables.env "http://localhost:8082" "${url}"
  replace variables.env "localhost" "${ZBR_HOSTNAME}"

  replace variables.env "STF_TOKEN=" "STF_TOKEN=${STF_TOKEN}"
  replace variables.env "SECRET=password" "SECRET=${SECRET}"
  replace variables.env "STF_STORAGE_TOKEN=" "STF_STORAGE_TOKEN=${STF_STORAGE_TOKEN}"
  replace variables.env "RETHINKDB_ENV_AUTHKEY=" "RETHINKDB_ENV_AUTHKEY=${RETHINKDB_ENV_AUTHKEY}"
  replace variables.env "STF_ZMQ_CURVE_SERVER_SECRET_KEY=" "STF_ZMQ_CURVE_SERVER_SECRET_KEY=${STF_ZMQ_CURVE_SERVER_SECRET_KEY}"
  replace variables.env "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=" "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY=${STF_ZMQ_CURVE_SERVER_PUBLIC_KEY}"
  replace variables.env "STF_ZMQ_CURVE_SECRET_KEY=" "STF_ZMQ_CURVE_SECRET_KEY=${STF_ZMQ_CURVE_SECRET_KEY}"
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
  # the option of the Playwright sessions of the previous setup, off for any other value than true
  if [[ "$PLAYWRIGHT_ENABLED" == "true" ]]; then
    replace variables.env "PLAYWRIGHT_ENABLED=false" "PLAYWRIGHT_ENABLED=true"
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

  # a changed configuration of the previous setup is kept aside: its changes are made again in the new one
  local previous_conf=""
  if [[ -f configuration/stf-proxy/nginx.conf ]]; then
    previous_conf="$(< configuration/stf-proxy/nginx.conf)"
  fi
  cp configuration/stf-proxy/nginx.conf.original configuration/stf-proxy/nginx.conf
  replace configuration/stf-proxy/nginx.conf "server_name localhost" "server_name '${ZBR_HOSTNAME}'"
  # the ssl protocol of the default NGiNX configuration with the certificate of set_certificate
  if [[ "$ZBR_PROTOCOL" == "https" ]]; then
    replace configuration/stf-proxy/nginx.conf "listen 80" "listen 80 ssl"

    # uncomment the default ssl settings
    replace configuration/stf-proxy/nginx.conf "#    ssl_" "    ssl_"
  fi
  set_grid_auth > /dev/null
  # the basic authentication of the grid is not a change by hand: set_grid_auth makes it again
  local new_conf
  new_conf="$(< configuration/stf-proxy/nginx.conf)"
  if [[ -n "$previous_conf" && "${previous_conf//#auth_basic/auth_basic}" != "${new_conf//#auth_basic/auth_basic}" ]]; then
    printf '%s\n' "$previous_conf" > configuration/stf-proxy/nginx.conf.previous
    echo_warning "The setup wrote a new configuration/stf-proxy/nginx.conf, the previous one is configuration/stf-proxy/nginx.conf.previous: make its own changes (e.g. frame-ancestors) again in the new one. The basic authentication of the grid follows configuration/stf-proxy/htpasswd/mcloud.htpasswd by itself."
  fi

  # the user input for the next setup
  export_settings
  write_stf_token
  protect_files

  echo "
      Enroll every node (a device host of mcloud-agent) once the services run with STF_TOKEN of variables.env:
      ./zebrunner.sh node-invite <label> <address> prints the join string for ./zebrunner.sh join of mcloud-agent on
      the node (README.md#nodes); https only."
  check_agents_address
  # a new SECRET with the database of an earlier deployment: its access tokens and sessions fail
  if [[ "$is_new" -eq 1 ]]; then
    check_old_database
  fi
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

  # the volumes of the project would be the ones of another folder of the same name
  if ! check_other_deployment shutdown; then
    exit 1
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
  rm -f configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.previous
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
  # nginx of stf-proxy does not start without the certificate of https; the containers of another folder are not
  # replaced
  if ! check_certificate || ! check_other_deployment start; then
    return 1
  fi
  # AGENTS_ADDRESS and the settings of adb-relay of .env may have changed since the setup
  set_nodes_host
  # the htpasswd file of the grid may have been created or removed since
  local reload_proxy=""
  if set_grid_auth; then
    reload_proxy=1
  fi
  check_agents_address
  check_adb_relay_auto
  write_stf_token
  # adb-relay runs with ADB_RELAY=true only (README.md#remote-debug-through-the-adb-relay)
  if [[ -n "$adb_relay" ]]; then
    docker compose --profile adb-relay up -d || return
  else
    docker compose up -d || return
  fi
  # a running stf-proxy reads the changed configuration again (the file is written in place, its bind mount sees it)
  if [[ -n "$reload_proxy" ]]; then
    docker exec stf-proxy nginx -s reload > /dev/null 2>&1 || true
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

  # with the profile: adb-relay stops also when ADB_RELAY was turned off after its start
  if ! check_other_deployment stop; then
    return 1
  fi
  docker compose --profile adb-relay stop
}

# down: stops and removes the containers, the data is kept
down() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # with the profile: adb-relay is removed also when ADB_RELAY was turned off after its start
  if ! check_other_deployment down; then
    return 1
  fi
  docker compose --profile adb-relay down
}

# backup: copies the settings to *.bak and the database into backup/rethinkdb.tar.gz
backup() {
  if [[ -f .disabled ]]; then
    exit 0
  fi
  if ! check_other_deployment backup; then
    return 1
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
  if ! check_other_deployment restore; then
    return 1
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
  case "$label" in
  enroll | invites | relay | verify)
    echo_warning "The label '${label}' is reserved by STF (enroll, invites, relay, verify): choose another one."
    return 1
    ;;
  esac
  if [[ -n "$minutes" ]] && { [[ ! "$minutes" =~ ^[0-9]{1,4}$ ]] || ((10#$minutes < 1 || 10#$minutes > 1440)); }; then
    echo_warning "The validity of the invite '${minutes}' is not a number of minutes from 1 to 1440 (60 by default)."
    return 1
  fi
  if [[ "$(sed -n 's/^STF_URL=//p' .env)" != https://* ]]; then
    echo_warning "The enrollment needs https of stf-proxy: the node trusts the pin of its certificate only. Set up MCloud with https (README.md#https)."
    return 1
  fi
  if [[ ! -f configuration/stf-proxy/ssl/ssl.crt ]]; then
    echo_warning "The enrollment needs the certificate of stf-proxy, configuration/stf-proxy/ssl/ssl.crt is missing: the node trusts the pin of that certificate only. Put the certificate into configuration/stf-proxy/ssl/ssl.crt and its key into configuration/stf-proxy/ssl/ssl.key, run ./zebrunner.sh restart and invite the node again (README.md#https)."
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

# nodes [list|check <label>|revoke <label>|delete <label>]: the registry of the nodes of STF (README.md#nodes)
nodes() {
  if ! require_setup; then
    return 1
  fi
  case "${1:-list}" in
  list)
    nodes_list
    ;;
  check)
    if [[ $# -ne 2 ]] || ! valid_label "$2"; then
      echo "Usage: ./zebrunner.sh nodes check <label>"
      return 1
    fi
    nodes_check "$2"
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
  *)
    echo "Usage: ./zebrunner.sh nodes [list|check <label>|revoke <label>|delete <label>]"
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

# nodes_check <label>: the diagnostics of a node (README.md#diagnostics): its record in the registry, the devices bound
# to it in STF and, for every present one, a connection of stf-proxy to <address>:<screen port>, the path of its screen
nodes_check() {
  local label="$1"
  local node address status seen devices line serial platform present screen connect result
  local problems=0
  local checked=0
  local unreachable=0
  local proxy=1
  if ! stf_api GET /api/v1/nodes; then
    api_error "The list of the nodes"
    return 1
  fi
  node="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep "\"label\"[[:space:]]*:[[:space:]]*\"${label}\"")"
  if [[ -z "$node" ]]; then
    echo_warning "There is no node ${label} in the registry of STF (./zebrunner.sh nodes): ./zebrunner.sh node-invite ${label} <address> enrolls it."
    return 1
  fi
  address="$(json_value address <<< "$node")"
  status="$(json_value status <<< "$node")"
  seen="$(json_time lastSeenAt <<< "$node")"
  echo "Node ${label}: ${status}, address ${address}, enrolled $(json_time createdAt <<< "$node"), last seen by the grid ${seen}"
  if [[ "$status" != "active" ]]; then
    echo_warning "The node ${label} is ${status}: STF and the grid refuse its key and token, no device is bound to it. A new invite enrolls it again: ./zebrunner.sh node-invite ${label} ${address}."
    return 1
  fi
  if [[ "$seen" == "-" ]]; then
    problems=1
    echo_warning "The grid has not seen the node yet: no Appium of the node registered with its token. On the node: ./zebrunner.sh doctor of mcloud-agent, zebrunner-farm status; the grid logs why it refuses a node (docker logs mcloud-grid)."
  fi
  if ! stf_api GET "/api/v1/devices?fields=serial,platform,present,node,screenPort,connectPort"; then
    api_error "The list of the devices"
    return 1
  fi
  devices="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep '"serial"' | grep "\"node\"[[:space:]]*:[[:space:]]*\"${label}\"")"
  if [[ -z "$devices" ]]; then
    echo_warning "No device of STF is bound to the node ${label}: the devices of a node register with its token from its address (${address}, STF_PROVIDER_HOST of the node). On the node: ./zebrunner.sh doctor of mcloud-agent; docker logs stf-processor001 names the refused registrations."
    return 1
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' stf-proxy 2> /dev/null)" != "true" ]]; then
    proxy=0
    problems=1
    echo_warning "stf-proxy is not running (./zebrunner.sh start): the screens are not checked."
  fi
  printf '%-28s %-9s %-8s %-7s %-13s %s\n' SERIAL PLATFORM PRESENT SCREEN "REMOTE DEBUG" "SCREEN FROM stf-proxy"
  while read -r line; do
    serial="$(json_value serial <<< "$line")"
    platform="$(json_value platform <<< "$line")"
    present="$(json_value present <<< "$line")"
    screen="$(json_value screenPort <<< "$line")"
    connect="$(json_value connectPort <<< "$line")"
    if [[ "$present" != "true" ]]; then
      result="not checked: absent"
    elif [[ ! "$screen" =~ ^[0-9]{1,5}$ ]] || ! valid_host "$address"; then
      result="not checked: no screen port"
      problems=1
    elif [[ "$proxy" -eq 0 ]]; then
      result="not checked"
    else
      checked=$((checked + 1))
      if screen_reachable "$address" "$screen"; then
        result="reachable"
      else
        result="NOT REACHABLE"
        unreachable=1
        problems=1
      fi
    fi
    printf '%-28s %-9s %-8s %-7s %-13s %s\n' "$serial" "${platform:--}" "$([[ "$present" == "true" ]] && echo yes || echo no)" \
      "${screen:--}" "${connect:--}" "$result"
  done <<< "$devices"
  if [[ "$unreachable" -eq 1 ]]; then
    echo_warning "stf-proxy does not reach the screen of a device at ${address}: the address of the invite must be the one the server reaches the node at (a node in the network of the server or on the server itself: its LAN address, a public address often fails there, NAT hairpin; a new invite of ${label} with another address enrolls it again), and the firewall of the node must let the server in on the ports of its devices (README.md#firewall)."
  fi
  if [[ "$checked" -eq 0 && "$proxy" -eq 1 ]]; then
    echo "No present device to check: an absent device is down on the node (zebrunner-farm status, ./zebrunner.sh doctor of mcloud-agent)."
  fi
  return "$problems"
}

# screen_reachable <address> <port>: stf-proxy connects to the port within 5 seconds, as it does for a screen
screen_reachable() {
  # $0 and $1 of the inner bash are the arguments after the script, not of this script
  # shellcheck disable=SC2016
  docker exec stf-proxy timeout 5 bash -c 'echo > "/dev/tcp/$0/$1"' "$1" "$2" > /dev/null 2>&1
}

# check_agents_address: warns when AGENTS_ADDRESS of .env is every address: the nodes reach MCloud at the host of
# STF_URL then, which a node in the network of the server or on the server itself may not reach (README.md#nodes)
check_agents_address() {
  case "$(sed -n 's/^AGENTS_ADDRESS=//p' .env)" in
  "" | 0.0.0.0)
    echo_warning "AGENTS_ADDRESS of .env is 0.0.0.0: the nodes reach MCloud at $(join_host) (the host of STF_URL, the join string of ./zebrunner.sh node-invite). A node in the network of the server or on the server itself often does not reach a public name or address (NAT hairpin): set AGENTS_ADDRESS to the LAN address of the server and run ./zebrunner.sh restart (README.md#devices-on-the-mcloud-server)."
    ;;
  esac
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
  if valid_host "$1" && [[ "$1" != localhost && "$1" != *.localhost ]]; then
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
  echo_warning "'${1}' is not the address of a node: an IPv4 address or a host name without the protocol and the port, not a loopback, link-local or multicast one. A node on the MCloud server itself is invited with the LAN address of the server (README.md#devices-on-the-mcloud-server)."
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

# set_nodes_host: NODES_HOST of .env, the host of join_host for the ZeroMQ endpoints stf-api gives the nodes
# (docker-compose.yml); the line is added to the .env of an earlier MCloud
set_nodes_host() {
  local host
  local current
  host="$(join_host)"
  if ! grep -q '^NODES_HOST=' .env; then
    echo "NODES_HOST=${host}" >> .env
    return
  fi
  current="$(sed -n 's/^NODES_HOST=//p' .env)"
  if [[ "$current" != "$host" ]]; then
    replace .env "NODES_HOST=${current}" "NODES_HOST=${host}"
  fi
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

# api_error <action>: why a request of stf_api failed; the API answers the details in the log of stf-api only. A 500 is
# asked again of /api/v1/user, which needs the access token only: STF answers 500 without a log line for a token made
# with another SECRET (it cannot read the JWT of the token) and for a token of a removed user
api_error() {
  local reason
  local status="$api_status"
  local port
  port="$(sed -n 's/^STF_PORT=//p' .env)"
  case "$status" in
  000) reason="stf-proxy does not answer on 127.0.0.1:${port}: the services do not run or still start (./zebrunner.sh start, docker ps), or stf-proxy does not serve the scheme of STF_URL of .env" ;;
  401) reason="STF_TOKEN of variables.env is not a valid access token of STF (unknown to its database): sign in to STF as an admin, generate an access token (Settings, Keys), set it as STF_TOKEN of variables.env and run ./zebrunner.sh restart" ;;
  403) reason="refused: STF_TOKEN is not of an admin of STF, or the request is not allowed, see docker logs stf-api" ;;
  404) reason="not found: an unknown node, or the STF of TAG_STF has no registry of the nodes" ;;
  400) reason="refused: an unknown node, a label or an address of another node, or a node that is not revoked; see docker logs stf-api" ;;
  502 | 503 | 504) reason="stf-proxy answered ${status}, stf-api does not answer it: stf-api is not running or still starts (docker ps, docker logs stf-api, ./zebrunner.sh start)" ;;
  500)
    if ! stf_api GET /api/v1/user && [[ "$api_status" == "500" ]]; then
      reason="the STF API answered 500 to STF_TOKEN of variables.env itself: the token was made with another SECRET (SECRET of variables.env changed, or the database is the one of another MCloud, e.g. of another folder named $(compose_project) such as mcloud of Zebrunner CE: they share the docker volume $(compose_project)_stf-db-volume) or its user is removed. Sign in to STF as an admin, generate an access token (Settings, Keys), set it as STF_TOKEN of variables.env and run ./zebrunner.sh restart (README.md#troubleshooting)"
    else
      reason="the STF API answered 500, see docker logs stf-api"
    fi
    ;;
  *) reason="the STF API answered ${status}, see docker logs stf-api" ;;
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
    configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.bak configuration/stf-proxy/nginx.conf.previous \
    configuration/adb-relay/stf-token configuration/stf-proxy/ssl/ssl.crt \
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
# gives its own (../nginx/ssl, its nginx is in front of this one); a missing one is reported, the setup goes on and
# start waits for it (check_certificate); fails for a key that is not the one of the certificate and, but for
# Zebrunner CE, for the self-signed pair of the repository of Zebrunner CE
set_certificate() {
  local dir="configuration/stf-proxy/ssl"
  local shared=0
  local missing
  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    if [[ ! -f "${BASEDIR}/../nginx/ssl/ssl.crt" || ! -f "${BASEDIR}/../nginx/ssl/ssl.key" ]]; then
      if [[ -n "$(certificate_missing)" ]]; then
        echo_warning "https needs the certificate of Zebrunner CE: ../nginx/ssl/ssl.crt and ../nginx/ssl/ssl.key are missing. The setup goes on, but stf-proxy does not start without a certificate: put the certificate of ${ZBR_HOSTNAME} and its key there and run the setup of Zebrunner CE again (README.md#https)."
        return 0
      fi
      echo_warning "https needs the certificate of Zebrunner CE: ../nginx/ssl/ssl.crt and ../nginx/ssl/ssl.key are missing. stf-proxy keeps the earlier copy of ${dir}, which may be old: put the certificate of ${ZBR_HOSTNAME} and its key there and run the setup of Zebrunner CE again (README.md#https)."
    # a key of root only (e.g. of certbot) is not readable for the user of the setup: the copy would be an old one
    elif ! cp "${BASEDIR}/../nginx/ssl/ssl.crt" "${dir}/ssl.crt" 2> /dev/null ||
      ! cp "${BASEDIR}/../nginx/ssl/ssl.key" "${dir}/ssl.key" 2> /dev/null; then
      echo_warning "The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied into ${dir}: make it readable for $(id -un) (README.md#troubleshooting)."
      return 1
    fi
  fi
  missing="$(certificate_missing)"
  if [[ -n "$missing" ]]; then
    echo_warning "https needs the certificate of ${ZBR_HOSTNAME}, missing: ${missing}. The setup goes on, but stf-proxy does not start without it: put the certificate (PEM) into ${dir}/ssl.crt and its key into ${dir}/ssl.key, then run ./zebrunner.sh start (README.md#https)."
    return 0
  fi
  if [[ "$(file_sha256 "${dir}/ssl.crt")" == "$SHARED_SSL_CRT_SHA256" || "$(file_sha256 "${dir}/ssl.key")" == "$SHARED_SSL_KEY_SHA256" ]]; then
    shared=1
  fi
  if [[ "$shared" -eq 1 && "$ZBR_INSTALLER" -eq 1 ]]; then
    echo_warning "The certificate of Zebrunner CE (nginx/ssl) is the self-signed one of its repository, its private key is public: anyone can read and change the traffic of MCloud. Replace it with the certificate of ${ZBR_HOSTNAME}."
  elif [[ "$shared" -eq 1 ]]; then
    echo_warning "${dir}/ssl.crt and ssl.key are the self-signed pair of the repository of Zebrunner CE, its private key is public: replace them with the certificate of ${ZBR_HOSTNAME} and its key, then run ./zebrunner.sh setup again (README.md#https)."
    return 1
  fi
  if certificate_mismatch; then
    echo_warning "${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM): put the key of that certificate there, then run ./zebrunner.sh setup again; the public keys of 'openssl x509 -noout -pubkey -in ${dir}/ssl.crt' and 'openssl pkey -pubout -in ${dir}/ssl.key' are the same for a pair (README.md#https)."
    return 1
  fi
}

# certificate_missing: the missing files of the certificate of stf-proxy, separated by ' and ', empty for none
certificate_missing() {
  local dir="configuration/stf-proxy/ssl"
  local file
  local missing=""
  for file in ssl.crt ssl.key; do
    if [[ ! -f "${dir}/${file}" ]]; then
      missing="${missing:+${missing} and }${dir}/${file}"
    fi
  done
  echo "$missing"
}

# certificate_mismatch: succeeds when openssl tells that ssl.key of stf-proxy is not the key of its ssl.crt (or one of
# them is not PEM); without openssl the pair is not checked
certificate_mismatch() {
  local dir="configuration/stf-proxy/ssl"
  command -v openssl > /dev/null 2>&1 &&
    [[ "$(openssl x509 -noout -pubkey -in "${dir}/ssl.crt" 2> /dev/null)" != "$(openssl pkey -pubout -in "${dir}/ssl.key" 2> /dev/null)" ]]
}

# set_grid_auth: the basic authentication of the /mcloud locations of stf-proxy (the grid) on when
# configuration/stf-proxy/htpasswd/mcloud.htpasswd exists, off otherwise; 0 when it changed the configuration
set_grid_auth() {
  local conf=configuration/stf-proxy/nginx.conf
  local before
  if [[ ! -f "$conf" ]]; then
    return 1
  fi
  before="$(< "$conf")"
  local realm='auth_basic "Private MCloud Selenium Hub";'
  local file='auth_basic_user_file /etc/nginx/htpasswd/mcloud.htpasswd;'
  if [[ -s configuration/stf-proxy/htpasswd/mcloud.htpasswd ]]; then
    replace "$conf" "#${realm}" "$realm"
    replace "$conf" "#${file}" "$file"
  else
    replace "$conf" "      ${realm}" "      #${realm}"
    replace "$conf" "      ${file}" "      #${file}"
  fi
  [[ "$before" != "$(< "$conf")" ]]
}

# check_certificate: the certificate of stf-proxy is there when its nginx configuration has the ssl settings of https
# (README.md#https), nginx does not start without it or with a key of another certificate; warns and fails otherwise
check_certificate() {
  local dir="configuration/stf-proxy/ssl"
  local missing
  if ! grep -q '^[[:space:]]*ssl_certificate[[:space:]]' configuration/stf-proxy/nginx.conf 2> /dev/null; then
    return 0
  fi
  missing="$(certificate_missing)"
  if [[ -n "$missing" ]]; then
    echo_warning "The services are not started: stf-proxy serves https and needs its certificate, missing: ${missing}. Put the certificate (PEM) of the host of STF_URL into ${dir}/ssl.crt and its key into ${dir}/ssl.key, then run ./zebrunner.sh start (README.md#https)."
    return 1
  fi
  if certificate_mismatch; then
    echo_warning "The services are not started: ${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM), nginx of stf-proxy does not start with them. Put the key of that certificate there, then run ./zebrunner.sh start (README.md#https)."
    return 1
  fi
}

# abort_setup: ends a setup that cannot write its files; the answers are saved as the defaults of the next setup
abort_setup() {
  export_settings
  protect_files
  echo "
      The setup is not finished, nothing but your answers is written: fix the problem above and run ./zebrunner.sh setup
      again, your answers are its defaults."
  exit 1
}

# compose_project: the project name of docker compose for this folder, COMPOSE_PROJECT_NAME or the name of the folder
# in lower case without the characters docker compose drops; it names the volumes (<project>_stf-db-volume), so two
# folders of the same name share them
compose_project() {
  local name="$COMPOSE_PROJECT_NAME"
  if [[ -z "$name" ]]; then
    name="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env 2> /dev/null)"
  fi
  name="${name:-$(basename "$BASEDIR")}"
  tr '[:upper:]' '[:lower:]' <<< "$name" | tr -cd 'a-z0-9_-'
}

# check_old_database: warns when a new setup (a new SECRET) finds the database of STF of an earlier MCloud in the docker
# volume of this folder: of a folder removed without ./zebrunner.sh shutdown or of another folder of the same name
check_old_database() {
  local volume
  volume="$(compose_project)_stf-db-volume"
  if ! docker volume inspect "$volume" > /dev/null 2>&1; then
    return 0
  fi
  echo_warning "The docker volume ${volume} has the database of STF of an earlier MCloud: of a folder $(basename "$BASEDIR") removed without ./zebrunner.sh shutdown, or of another folder of this name on this server (e.g. mcloud of Zebrunner CE; docker compose names the volumes by the folder). This setup made a new SECRET: the access tokens of that database fail (the STF API answers 500 to them) and its users sign in again, so generate a new STF_TOKEN as an admin (Settings, Keys). An empty database instead: docker volume rm ${volume} before ./zebrunner.sh start. To keep the tokens of that MCloud: copy its SECRET into SECRET of variables.env, then ./zebrunner.sh restart (README.md#troubleshooting)."
}

# check_other_deployment <command>: fails when the services of the docker compose project of this folder belong to
# another folder that still exists (two folders of the same name, e.g. mcloud of Zebrunner CE): the command would act on
# its containers and its database; the containers of a removed folder are the ones of this folder
check_other_deployment() {
  local project dir
  project="$(compose_project)"
  dir="$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=rethinkdb" --format '{{.Label "com.docker.compose.project.working_dir"}}' \
    2> /dev/null | head -1)"
  if [[ -z "$dir" || ! -d "$dir" || "$(cd "$dir" && pwd -P)" == "$(pwd -P)" ]]; then
    return 0
  fi
  echo_warning "./zebrunner.sh ${1} did nothing: the docker compose project ${project} is the MCloud of ${dir} (docker compose names the projects and their volumes by the folder), ${1} here would act on its containers and its database (the volume ${project}_stf-db-volume; with the SECRET of this folder its access tokens fail). One MCloud runs on a server: use that folder, or remove that MCloud first (./zebrunner.sh down in ${dir}; its shutdown removes its database too), then ./zebrunner.sh start here (README.md#troubleshooting)."
  return 1
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

# valid_host <host>: succeeds for a host name or an IPv4 address
valid_host() {
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

# check_adb_relay_auto: the auto mode of adb-relay, ADB_RELAY=true of .env (README.md#remote-debug-through-the-adb-relay):
# sets adb_relay to 1 and warns about the settings it needs
check_adb_relay_auto() {
  local auto
  local ports
  local seconds
  adb_relay=""
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

# set_curve_keys: the CURVE keys of ZeroMQ of a new deployment (README.md#authentication-of-the-nodes): the pair of
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
      echo_warning "The setup makes the CURVE keys with openssl (X25519, OpenSSL 1.1.1+) or python3, neither works here: install one of them (README.md#system-requirements)."
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
          nodes          [list]: the enrolled nodes; check <label>: the diagnostics of a node; revoke <label>;
                         delete <label> (README.md#nodes)"
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
  if [[ ! -f .disabled ]] && ! check_other_deployment restart; then
    exit 1
  fi
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
