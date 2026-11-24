#!/bin/bash
# The management of the MCloud services: ./zebrunner.sh <command>, see echo_help.
# Zebrunner CE runs it with ZBR_INSTALLER=1 and its ZBR_* settings, the shutdown with SHUTDOWN_CONFIRMED=1.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

#### Completion

# The commands of echo_help, of the completion and of the hint of an unknown command
COMMANDS="setup start stop restart down shutdown backup restore version doctor node-invite nodes help completion"

# complete_words <index> <words...>: the candidates of the word <index> of the command line, one per line
# (CONVENTIONS.md#completion); the labels of the nodes are not offered, only the STF API knows them
complete_words() {
  local index="$1"
  shift
  [[ "$index" =~ ^[1-9][0-9]{0,2}$ ]] || return 0
  local words=("$@")
  local current="${words[$((index - 1))]:-}"
  if [[ "$index" -eq 1 ]]; then
    # split into the words of the list
    # shellcheck disable=SC2086
    printf '%s\n' $COMMANDS --help -h
    return 0
  fi
  # an option after a command: its help
  if [[ "$current" == -* ]]; then
    printf '%s\n' --help -h
    return 0
  fi
  [[ "$index" -eq 2 ]] || return 0
  case "${words[0]}" in
  nodes) printf '%s\n' list check revoke delete ;;
  help)
    # split into the words of the list
    # shellcheck disable=SC2086
    printf '%s\n' $COMMANDS
    ;;
  completion) printf '%s\n' bash zsh ;;
  esac
}

# the completion answers before anything else runs: no cd, no file, no docker, no network, nothing on stderr
if [[ "${1:-}" == "__complete" ]]; then
  complete_words "${@:2}" 2> /dev/null
  exit 0
fi

#### Commands

# setup: writes .env, variables.env and the nginx configuration from their *.original files
setup() {
  local url
  local is_new=1
  local sign_in="zebrunner"
  local previous_env=""
  # the settings of the previous setup (the generated secrets, the tokens) are kept
  if [[ -f variables.env ]]; then
    is_new=0
  fi
  # the values of the previous .env (e.g. AGENTS_ADDRESS, COMPOSE_PROJECT_NAME), see keep_env
  if [[ -f .env ]]; then
    previous_env="$(< .env)"
  fi
  # the variables of variables.env.original, overridden by the current variables.env, even the manual changes
  # shellcheck source=variables.env.original
  source variables.env.original
  if [[ "$is_new" -eq 0 ]]; then
    # shellcheck source=/dev/null
    source variables.env
  fi

  ui_banner "MCloud" "$(mcloud_tag)"
  ui_section "Settings" "1/3"
  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    # Zebrunner CE installer: the sign-in of the last setup of this MCloud, Zebrunner IAM by default
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_PORT}"
    ZBR_MCLOUD_PORT=8082
    ZBR_MCLOUD_SIGN_IN="$(sed -n 's/^declare -x ZBR_MCLOUD_SIGN_IN="\(.*\)"$/\1/p' backup/settings.env 2> /dev/null)"
    export ZBR_MCLOUD_SIGN_IN="${ZBR_MCLOUD_SIGN_IN:-zebrunner}"
    sign_in="$ZBR_MCLOUD_SIGN_IN"
    ui_info "Zebrunner MCloud of Zebrunner CE: ${url}"
  elif grep -q '^declare -x ZBR_INSTALLER="1"$' backup/settings.env 2> /dev/null; then
    # this MCloud of Zebrunner CE (README.md#zebrunner-ce): the URL, the port and the certificate of the last setup of
    # Zebrunner CE (its nginx is in front of stf-proxy), only the admin and the sign-in are asked
    # shellcheck source=backup/settings.env.original
    source backup/settings.env.original
    # shellcheck source=/dev/null
    source backup/settings.env
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_PORT}"
    ZBR_MCLOUD_PORT=8082
    ui_info "Zebrunner MCloud of Zebrunner CE: ${url} (the setup of Zebrunner CE changes it)"
    previous_admin "$is_new"
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

    previous_admin "$is_new"
    set_mcloud_settings
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}"
    set_sign_in "$url"
    sign_in="$ZBR_MCLOUD_SIGN_IN"
  fi

  ui_section "Files" "2/3"
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
  keep_env "$previous_env"
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
  # the secret stf-proxy gives the grid with the users of STF (README.md#access-to-the-grid)
  if [[ -z "$GRID_AUTH_SECRET" ]]; then
    GRID_AUTH_SECRET="$(random_string 48)"
  fi

  # the variables added to variables.env (e.g. STF_SESSION_TTL_SECONDS) are added again
  local added=""
  if [[ "$is_new" -eq 0 ]]; then
    added="$(awk -F '=' 'NR == FNR { if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) known[$1] = 1; next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ && !($1 in known)' variables.env.original variables.env)"
  fi
  # the values of the setup, the other variables keep the values of the previous variables.env (write_variables)
  # shellcheck disable=SC2034 # read by write_variables through ${!name}
  STF_URL="$url"
  # read by write_variables through ${!name}
  # shellcheck disable=SC2034
  if [[ "$sign_in" == "oauth2" ]]; then
    OAUTH_CALLBACK_URL="${url}/auth/oauth/callback"
  fi
  STF_ADMIN_NAME="${ZBR_MCLOUD_ADMIN_NAME:-$STF_ADMIN_NAME}"
  STF_ADMIN_EMAIL="${ZBR_MCLOUD_ADMIN_EMAIL:-$STF_ADMIN_EMAIL}"
  ZBR_MCLOUD_ADMIN_NAME="$STF_ADMIN_NAME"
  ZBR_MCLOUD_ADMIN_EMAIL="$STF_ADMIN_EMAIL"
  # auth-zebrunner of STF signs in through Zebrunner IAM; read by write_variables through ${!name}
  # shellcheck disable=SC2034
  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    ZEBRUNNER_LOGIN_URL="${url}/api/iam/v1/auth/login"
    ZEBRUNNER_USERINFO_URL="${url}/api/iam/v1/users"
  fi
  write_variables
  if [[ -n "$added" ]]; then
    printf '%s\n' "$added" >> variables.env
  fi
  ui_ok ".env and variables.env are written"

  # a configuration of the previous setup changed by hand is kept aside: its changes are made again in the new one; the
  # differences the setup made itself (the protocol, a new nginx.conf.original) are not changes by hand
  local previous_conf=""
  if [[ -f configuration/stf-proxy/nginx.conf ]] && ! nginx_conf_generated; then
    previous_conf="$(< configuration/stf-proxy/nginx.conf)"
  fi
  nginx_conf "$ZBR_PROTOCOL" > configuration/stf-proxy/nginx.conf
  file_sha256 configuration/stf-proxy/nginx.conf > configuration/stf-proxy/nginx.conf.sha256
  ui_ok "configuration/stf-proxy/nginx.conf is written"
  if [[ -n "$previous_conf" && "$previous_conf" != "$(< configuration/stf-proxy/nginx.conf)" ]]; then
    printf '%s\n' "$previous_conf" > configuration/stf-proxy/nginx.conf.previous
    echo_warning "The setup wrote a new configuration/stf-proxy/nginx.conf, the previous one is configuration/stf-proxy/nginx.conf.previous: make its own changes (e.g. frame-ancestors) again in the new one."
  fi

  # the MDM of MDM_ENABLED of .env (README.md#mdm): its secrets and the locations of stf-proxy
  write_mdm || abort_setup

  # the user input for the next setup
  export_settings
  write_stf_token
  write_grid_env
  protect_files

  ui_section "Next steps" "3/3"
  ui_callout note "Enroll every node (a device host of mcloud-agent) once the services run with STF_TOKEN of variables.env: ./zebrunner.sh node-invite <label> <address> prints the join string for ./zebrunner.sh join of mcloud-agent on the node (README.md#nodes); https only." "NODES"
  check_agents_address
  # a new SECRET with the database of an earlier deployment: its access tokens and sessions fail
  if [[ "$is_new" -eq 1 ]]; then
    check_old_database
  fi
  if [[ "$sign_in" == "mock" ]]; then
    ui_callout note "The sign-in of STF asks the user '${STF_AUTH_MOCK_BASIC_AUTH_USERNAME}' and the password '${STF_AUTH_MOCK_BASIC_AUTH_PASSWORD}' (STF_AUTH_MOCK_BASIC_AUTH_* of variables.env), then any name and email: share them with the users of STF only." "SIGN-IN"
  fi
}

# shutdown: removes the services, their data and the settings
shutdown() {
  if [[ -f .disabled ]]; then
    rm -f .disabled
    exit 0 # no need to proceed as nothing was configured
  fi

  ui_banner "MCloud" "$(mcloud_tag)"
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
    if ! confirm "" "Do you want to continue?" "n"; then
      exit
    fi
  fi

  docker compose --profile adb-relay --profile mdm down -v

  rm -f backup/settings.env
  rm -f .env
  rm -f variables.env
  rm -f configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.previous configuration/stf-proxy/nginx.conf.sha256
  rm -f configuration/adb-relay/stf-token
  rm -f grid.env configuration/stf-proxy/grid-auth.conf
  # the secrets of the MDM go with its volumes; the agent APK of configuration/mdm/android is kept
  rm -f "$MDM_ENV" "${MDM_ENV}.bak" "${MDM_PROXY_DIR}"/*.conf "$MDM_MQTT_CONF"
  rm -rf "$MDM_ENV_DIR"
  # the copies of backup: the secrets of the settings (SECRET, the tokens, the keys of RethinkDB and of ZeroMQ)
  rm -f variables.env.bak .env.bak backup/settings.env.bak configuration/stf-proxy/nginx.conf.bak \
    configuration/stf-proxy/nginx.conf.sha256.bak
  # the certificate of https is the one of the user (README.md#https), it is kept with its copies; the archive of the
  # database (backup/rethinkdb.tar.gz) too, the user removes it
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

  # STF_TOKEN of variables.env may have changed since the setup; before protect_files, which gives it to the owner
  local grid_auth
  grid_auth="$(cat configuration/stf-proxy/grid-auth.conf 2> /dev/null)"
  if ! write_grid_env; then
    return 1
  fi
  protect_files
  # nginx of stf-proxy does not start without the certificate of https; the containers of another folder are not
  # replaced
  if ! check_certificate || ! check_other_deployment start; then
    return 1
  fi
  # an empty STF_TOKEN gets an access token of the admin of STF: the grid gets it in grid.env
  if ensure_stf_token && ! write_grid_env; then
    return 1
  fi
  # AGENTS_ADDRESS and the settings of adb-relay of .env may have changed since the setup
  set_nodes_host
  # GRID_AUTH_SECRET of variables.env may have changed since the setup: a running stf-proxy reads it again
  local reload_proxy=""
  if [[ "$grid_auth" != "$(cat configuration/stf-proxy/grid-auth.conf 2> /dev/null)" ]]; then
    reload_proxy=1
  fi
  check_htpasswd
  check_agents_address
  check_adb_relay_auto
  write_stf_token
  # the MDM of MDM_ENABLED of .env (README.md#mdm): its secrets and the locations of stf-proxy, changed ones are read
  # again by a running stf-proxy
  write_mdm || return 1
  if [[ -n "$MDM_PROXY_CHANGED" ]]; then
    reload_proxy=1
  fi
  # the configuration of stf-proxy of a setup before the MDM has no includes of its locations
  if [[ -n "$MDM_ON" ]] && ! grep -q 'include /etc/nginx/mdm/' configuration/stf-proxy/nginx.conf 2> /dev/null; then
    if nginx_conf_generated; then
      local protocol=http
      if grep -q '^STF_URL=https://' .env; then
        protocol=https
      fi
      nginx_conf "$protocol" > configuration/stf-proxy/nginx.conf
      file_sha256 configuration/stf-proxy/nginx.conf > configuration/stf-proxy/nginx.conf.sha256
      reload_proxy=1
    else
      echo_warning "configuration/stf-proxy/nginx.conf was changed by hand and has no includes of the MDM: no device reaches it. Add the include lines of /etc/nginx/mdm of configuration/stf-proxy/nginx.conf.original to it or run ./zebrunner.sh setup (README.md#mdm)."
    fi
  fi
  protect_files
  # adb-relay runs with ADB_RELAY=true only (README.md#remote-debug-through-the-adb-relay), the MDM with MDM_ENABLED=true
  local profiles=()
  if [[ -n "$adb_relay" ]]; then
    profiles+=(--profile adb-relay)
  fi
  if [[ -n "$MDM_ON" ]]; then
    profiles+=(--profile mdm)
  fi
  docker compose "${profiles[@]+"${profiles[@]}"}" up -d || return
  # a running stf-proxy reads the changed configuration again (the file is written in place, its bind mount sees it)
  if [[ -n "$reload_proxy" ]]; then
    docker exec stf-proxy nginx -s reload > /dev/null 2>&1 || true
  fi

  # the next steps of a deployment without Zebrunner CE (README.md#run)
  if [[ "$ZBR_INSTALLER" -ne 1 ]]; then
    local url
    url="$(sed -n 's/^STF_URL=//p' .env)"
    ui_callout note "MCloud: ${url}/stf, the Selenium/Appium hub: ${url/:\/\//://<user>:<token>@}/mcloud/wd/hub (an access token of STF, Settings, Keys), the devices: ${url}/mcloud/grid/console"
    if [[ -z "$(sed -n 's/^STF_TOKEN=//p' variables.env 2> /dev/null)" ]]; then
      echo_warning "STF_TOKEN of variables.env is empty: the grid reserves no device. Sign in to ${url}/stf, generate an access token (Settings, Keys), set it as STF_TOKEN of variables.env and run ./zebrunner.sh restart."
    fi
    if [[ -n "$MDM_ON" ]]; then
      ui_callout note "MDM: the admin UI on 127.0.0.1:$(mdm_setting MDM_ADMIN_PORT) of this server (ssh -L $(mdm_setting MDM_ADMIN_PORT):127.0.0.1:$(mdm_setting MDM_ADMIN_PORT) <server>, http://127.0.0.1:$(mdm_setting MDM_ADMIN_PORT))$([[ "$(mdm_setting MDM_ADMIN_PUBLIC)" == "true" ]] && echo ", ${url}/mcloud/mdm/ for the admins of STF"); MQTT over TLS of the Android agents on the port $(mdm_setting MDM_MQTT_PORT) (README.md#mdm)"
    fi
  fi
}

# stop: stops the services, the containers are kept
stop() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # with the profiles: adb-relay and the MDM stop also when they were turned off after their start
  if ! check_other_deployment stop; then
    return 1
  fi
  docker compose --profile adb-relay --profile mdm stop
}

# down: stops and removes the containers, the data is kept
down() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  # with the profiles: adb-relay and the MDM are removed also when they were turned off after their start
  if ! check_other_deployment down; then
    return 1
  fi
  docker compose --profile adb-relay --profile mdm down
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
  # the secrets of the MDM (README.md#mdm); its databases are its volumes
  if [[ -f "$MDM_ENV" ]]; then
    cp "$MDM_ENV" "${MDM_ENV}.bak"
  fi
  # the checksum of the configuration the setup wrote goes with it (nginx_conf_generated)
  if [[ -f configuration/stf-proxy/nginx.conf.sha256 ]]; then
    cp configuration/stf-proxy/nginx.conf.sha256 configuration/stf-proxy/nginx.conf.sha256.bak
  else
    rm -f configuration/stf-proxy/nginx.conf.sha256.bak
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
    ui_callout error "The database was not archived into backup/rethinkdb.tar.gz."
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
  if [[ -f "${MDM_ENV}.bak" ]]; then
    cp "${MDM_ENV}.bak" "$MDM_ENV"
  fi
  if [[ -f configuration/stf-proxy/nginx.conf.sha256.bak ]]; then
    cp configuration/stf-proxy/nginx.conf.sha256.bak configuration/stf-proxy/nginx.conf.sha256
  else
    rm -f configuration/stf-proxy/nginx.conf.sha256
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

  echo "mcloud: $(mcloud_tag)"
}

# mcloud_tag: the version of MCloud, TAG_STF of .env (read, not sourced); before the setup the one of this folder
mcloud_tag() {
  local tag
  tag="$(sed -n 's/^TAG_STF=//p' .env 2> /dev/null | tail -1)"
  echo "${tag:-$(sed -n 's/^TAG_STF=//p' .env.original)}"
}

#### Nodes

# The port of the grid the nodes register on (docker-compose.yml: ${AGENTS_ADDRESS}:4446)
GRID_PORT=4446

# node_invite <label> <address> [<minutes>]: an invite of a node (README.md#nodes): prints the join string for
# ./zebrunner.sh join of mcloud-agent on the node once, with the pin of the certificate of stf-proxy; the join string is
# alone on stdout, the lines around it go to stderr
node_invite() {
  local label="$1"
  local address
  local minutes="$3"
  local pin host port invite expires body
  if ! require_setup; then
    return 1
  fi
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    ui_warn "Usage: ./zebrunner.sh node-invite <label> <address> [<minutes>]"
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
    ui_callout error "The pin of configuration/stf-proxy/ssl/ssl.crt cannot be made: it needs openssl or python3 and a PEM certificate."
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
    ui_callout error "The STF API answered the invite without one (docker logs stf-api)."
    return 1
  fi
  host="$(join_host)"
  port="$(sed -n 's/^STF_PORT=//p' .env)"
  {
    ui_ok "The invite of the node ${label} at ${address}, valid ${minutes:-60} minutes (until ${expires:-?}), for one join:"
    echo
  } >&2
  echo "mcloud-join://${host}:${port}?label=${label}&grid=${host}:${GRID_PORT}&pin=$(url_encode "$pin")&token=${invite}"
  {
    ui_callout note "It is a secret, shown once: paste it into ./zebrunner.sh join of mcloud-agent on the node ${label} (it reads it from stdin, never put it into the arguments), valid ${minutes:-60} minutes. A new invite of ${label} replaces it." "SECRET"
    ui_info "The node checks the certificate of stf-proxy by its pin (SHA-256 of its public key): ${pin}"
  } >&2
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
      ui_warn "Usage: ./zebrunner.sh nodes check <label>"
      return 1
    fi
    nodes_check "$2"
    ;;
  revoke)
    if [[ $# -ne 2 ]] || ! valid_label "$2"; then
      ui_warn "Usage: ./zebrunner.sh nodes revoke <label>"
      return 1
    fi
    if ! stf_api POST "/api/v1/nodes/${2}/revoke" '{}'; then
      api_error "The revocation of the node ${2}"
      return 1
    fi
    ui_ok "The node ${2} is revoked: its token and its key are refused, its devices are not bound to it any more."
    # the open ZeroMQ sessions of the node end with its triproxy connections, a new one is refused
    if ! ui_spin "The restart of stf-triproxy-app and stf-triproxy-dev" docker restart stf-triproxy-app stf-triproxy-dev; then
      ui_callout error "stf-triproxy-app and stf-triproxy-dev did not restart: the open ZeroMQ sessions of ${2} go on until ./zebrunner.sh restart."
      return 1
    fi
    ui_ok "The triproxies restarted: the open ZeroMQ sessions of ${2} ended. A new invite enrolls the node again."
    ;;
  delete)
    if [[ $# -ne 2 ]] || ! valid_label "$2"; then
      ui_warn "Usage: ./zebrunner.sh nodes delete <label>"
      return 1
    fi
    if ! stf_api DELETE "/api/v1/nodes/${2}"; then
      api_error "The removal of the node ${2} (a revoked one only: ./zebrunner.sh nodes revoke ${2})"
      return 1
    fi
    ui_ok "The node ${2} is removed from the registry: its label and its address are free again."
    ;;
  *)
    ui_warn "Usage: ./zebrunner.sh nodes [list|check <label>|revoke <label>|delete <label>]"
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
    ui_info "No node is enrolled: ./zebrunner.sh node-invite <label> <address> (README.md#nodes)."
    return 0
  fi
  ui_table_head "$(printf '%-20s %-24s %-8s %-20s %-20s %s' LABEL ADDRESS STATUS "LAST SEEN" ENROLLED KEY)"
  while read -r line; do
    printf '%-20s %-24s %-8s %-20s %-20s %s\n' "$(json_value label <<< "$line")" "$(json_value address <<< "$line")" \
      "$(json_value status <<< "$line")" "$(json_time lastSeenAt <<< "$line")" "$(json_time createdAt <<< "$line")" \
      "$(json_value publicKey <<< "$line" | cut -c 1-16)..."
  done <<< "$nodes"
}

# nodes_check <label>: the diagnostics of a node (README.md#diagnostics): its record in the registry, the devices bound
# to it in STF and, for every present one, a connection of stf-proxy to <address>:<screen port>, the path of its screen;
# a status per check, the table of the devices and the summary; fails when a check fails
nodes_check() {
  local label="$1"
  local node address status seen devices line serial platform present screen connect result
  local passed=0
  local warnings=0
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
    ui_fail "There is no node ${label} in the registry of STF (./zebrunner.sh nodes)." "./zebrunner.sh node-invite ${label} <address>"
    return 1
  fi
  address="$(json_value address <<< "$node")"
  status="$(json_value status <<< "$node")"
  seen="$(json_time lastSeenAt <<< "$node")"
  line="Node ${label}: ${status}, address ${address}, enrolled $(json_time createdAt <<< "$node"), last seen by the grid ${seen}"
  if [[ "$status" != "active" ]]; then
    ui_info "$line"
    ui_fail "The node ${label} is ${status}: STF and the grid refuse its key and token, no device is bound to it." \
      "a new invite enrolls it again: ./zebrunner.sh node-invite ${label} ${address}"
    ui_summary 0 0 1
    return 1
  fi
  ui_ok "$line"
  passed=$((passed + 1))
  if [[ "$seen" == "-" ]]; then
    problems=$((problems + 1))
    ui_fail "The grid has not seen the node yet: no Appium of the node registered with its token." \
      "on the node: ./zebrunner.sh doctor of mcloud-agent, zebrunner-farm status; the grid logs why it refuses a node (docker logs mcloud-grid)"
  fi
  if ! stf_api GET "/api/v1/devices?fields=serial,platform,present,node,screenPort,connectPort"; then
    api_error "The list of the devices"
    return 1
  fi
  devices="$(tr -d '\n' <<< "$api_body" | tr '{}' '\n' | grep '"serial"' | grep "\"node\"[[:space:]]*:[[:space:]]*\"${label}\"")"
  if [[ -z "$devices" ]]; then
    ui_fail "No device of STF is bound to the node ${label}: the devices of a node register with its token from its address (${address}, STF_PROVIDER_HOST of the node)." \
      "on the node: ./zebrunner.sh doctor of mcloud-agent; docker logs stf-processor001 names the refused registrations"
    ui_summary "$passed" "$warnings" $((problems + 1))
    return 1
  fi
  ui_ok "Devices of STF bound to the node ${label}: $(grep -c . <<< "$devices")"
  passed=$((passed + 1))
  if [[ "$(docker inspect --format '{{.State.Running}}' stf-proxy 2> /dev/null)" != "true" ]]; then
    proxy=0
    problems=$((problems + 1))
    ui_fail "stf-proxy is not running (./zebrunner.sh start): the screens are not checked."
  fi
  echo
  ui_table_head "$(printf '%-28s %-9s %-8s %-7s %-13s %s' SERIAL PLATFORM PRESENT SCREEN "REMOTE DEBUG" "SCREEN FROM stf-proxy")"
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
      problems=$((problems + 1))
    elif [[ "$proxy" -eq 0 ]]; then
      result="not checked"
    else
      checked=$((checked + 1))
      if screen_reachable "$address" "$screen"; then
        result="reachable"
      else
        result="NOT REACHABLE"
        unreachable=$((unreachable + 1))
      fi
    fi
    printf '%-28s %-9s %-8s %-7s %-13s %s\n' "$serial" "${platform:--}" "$([[ "$present" == "true" ]] && echo yes || echo no)" \
      "${screen:--}" "${connect:--}" "$result"
  done <<< "$devices"
  echo
  if [[ "$unreachable" -gt 0 ]]; then
    problems=$((problems + 1))
    ui_fail "stf-proxy does not reach the screen of a device at ${address}"
    echo_warning "The address of the invite must be the one the server reaches the node at (a node in the network of the server or on the server itself: its LAN address, a public address often fails there, NAT hairpin; a new invite of ${label} with another address enrolls it again), and the firewall of the node must let the server in on the ports of its devices (README.md#firewall)."
  elif [[ "$checked" -gt 0 ]]; then
    passed=$((passed + 1))
    ui_ok "stf-proxy reaches the screens of the present devices: ${checked}"
  fi
  if [[ "$checked" -eq 0 && "$proxy" -eq 1 ]]; then
    warnings=$((warnings + 1))
    ui_warn "No present device to check: an absent device is down on the node (zebrunner-farm status, ./zebrunner.sh doctor of mcloud-agent)."
  fi
  ui_summary "$passed" "$warnings" "$problems"
  [[ "$problems" -eq 0 ]]
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

# api_error <action>: why a request of stf_api failed (api_reason), as an error callout
api_error() {
  ui_callout error "${1} failed: $(api_reason)."
}

# api_reason: why the last request of stf_api failed; the API answers the details in the log of stf-api only. A 500 is
# asked again of /api/v1/user, which needs the access token only: STF answers 500 without a log line for a token made
# with another SECRET (it cannot read the JWT of the token) and for a token of a removed user
api_reason() {
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
  echo "$reason"
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
    configuration/stf-proxy/nginx.conf.sha256 configuration/stf-proxy/nginx.conf.sha256.bak \
    configuration/adb-relay/stf-token configuration/stf-proxy/ssl/ssl.crt \
    configuration/stf-proxy/ssl/ssl.crt.bak grid.env configuration/stf-proxy/grid-auth.conf \
    configuration/stf-proxy/ssl/ssl.key configuration/stf-proxy/ssl/ssl.key.bak backup/rethinkdb.tar.gz \
    "$MDM_ENV" "${MDM_ENV}.bak" "${MDM_PROXY_DIR}/server-mdm.conf" "${MDM_ENV_DIR}"/*.env; do
    if [[ ! -f "$file" ]]; then
      continue
    fi
    if [[ -n "$owner" ]]; then
      chown "$owner" "$file"
    fi
    case "$file" in
    variables.env* | grid.env | */grid-auth.conf | backup/settings.env* | */ssl.key* | */stf-token | backup/rethinkdb.tar.gz | \
      mdm.env* | */server-mdm.conf | "${MDM_ENV_DIR}"/*.env)
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
      ui_callout error "The certificate of Zebrunner CE (../nginx/ssl/ssl.crt and ssl.key) cannot be copied into ${dir}: make it readable for $(id -un) (README.md#troubleshooting)."
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
    ui_callout error "${dir}/ssl.crt and ssl.key are the self-signed pair of the repository of Zebrunner CE, its private key is public: replace them with the certificate of ${ZBR_HOSTNAME} and its key, then run ./zebrunner.sh setup again (README.md#https)."
    return 1
  fi
  if certificate_mismatch; then
    ui_callout error "${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM): put the key of that certificate there, then run ./zebrunner.sh setup again; the public keys of 'openssl x509 -noout -pubkey -in ${dir}/ssl.crt' and 'openssl pkey -pubout -in ${dir}/ssl.key' are the same for a pair (README.md#https)."
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

# nginx_conf <protocol>: the configuration of stf-proxy the setup writes, from nginx.conf.original
nginx_conf() {
  local conf
  conf="$(< configuration/stf-proxy/nginx.conf.original)"
  # the ssl protocol of the default NGiNX configuration with the certificate of set_certificate
  if [[ "$1" == "https" ]]; then
    conf=${conf//"listen 80"/"listen 80 ssl"}
    # uncomment the default ssl settings
    conf=${conf//"#    ssl_"/"    ssl_"}
  fi
  printf '%s\n' "$conf"
}

# nginx_conf_generated: configuration/stf-proxy/nginx.conf is the one a setup wrote, its checksum is the one the setup
# stored; without the checksum (a setup of an earlier MCloud) it is the one of the current nginx.conf.original
nginx_conf_generated() {
  local conf
  if [[ -f configuration/stf-proxy/nginx.conf.sha256 ]]; then
    [[ "$(file_sha256 configuration/stf-proxy/nginx.conf)" == "$(< configuration/stf-proxy/nginx.conf.sha256)" ]]
    return
  fi
  conf="$(< configuration/stf-proxy/nginx.conf)"
  [[ "$conf" == "$(nginx_conf http)" || "$conf" == "$(nginx_conf https)" ]]
}

# check_htpasswd: warns about the htpasswd file of the basic authentication of the grid of an earlier MCloud: the access
# tokens of STF replaced it (README.md#access-to-the-grid)
check_htpasswd() {
  if [[ -f configuration/stf-proxy/htpasswd/mcloud.htpasswd ]]; then
    echo_warning "configuration/stf-proxy/htpasswd/mcloud.htpasswd is not used any more: the users of the grid give their access tokens of STF, https://<user>:<token>@<host>/mcloud/wd/hub (README.md#access-to-the-grid). Remove the file."
  fi
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
    ui_callout error "The services are not started: stf-proxy serves https and needs its certificate, missing: ${missing}. Put the certificate (PEM) of the host of STF_URL into ${dir}/ssl.crt and its key into ${dir}/ssl.key, then run ./zebrunner.sh start (README.md#https)."
    return 1
  fi
  if certificate_mismatch; then
    ui_callout error "The services are not started: ${dir}/ssl.key is not the key of ${dir}/ssl.crt (or one of them is not PEM), nginx of stf-proxy does not start with them. Put the key of that certificate there, then run ./zebrunner.sh start (README.md#https)."
    return 1
  fi
}

# abort_setup: ends a setup that cannot write its files; the answers are saved as the defaults of the next setup
abort_setup() {
  export_settings
  protect_files
  ui_callout error "The setup is not finished, nothing but your answers is written: fix the problem above and run ./zebrunner.sh setup again, your answers are its defaults."
  exit 1
}

# previous_admin <is_new>: the admin of the previous variables.env is the default of the question of the setup, also
# when it was changed there by hand
previous_admin() {
  if [[ "$1" -eq 0 ]]; then
    ZBR_MCLOUD_ADMIN_NAME="${STF_ADMIN_NAME:-$ZBR_MCLOUD_ADMIN_NAME}"
    ZBR_MCLOUD_ADMIN_EMAIL="${STF_ADMIN_EMAIL:-$ZBR_MCLOUD_ADMIN_EMAIL}"
  fi
}

# keep_env <previous .env>: the variables of .env (a copy of .env.original) get their values of the previous .env, the
# ones that are not in .env.original (e.g. COMPOSE_PROJECT_NAME, it names the volume of the database) are added; but
# the ones of the setup (STF_URL, STF_PORT, NODES_HOST, the sign-in AUTH_*), the images of this MCloud (TAG_*) and the
# ones of earlier MCloud releases
keep_env() {
  local line
  while IFS= read -r line; do
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      continue
    fi
    case "${line%%=*}" in
    STF_URL | STF_PORT | NODES_HOST | AUTH_SYSTEM | AUTH_URL | TAG_* | AGENT_HOSTS | ADB_RELAY_HOSTS | STF_HOST | RETHINKDB_ADDRESS) ;;
    *)
      set_line .env "$line"
      ;;
    esac
  done <<< "$1"
}

# write_variables: variables.env from variables.env.original, every variable with the value of the shell variable of
# its name: the value of the previous variables.env (sourced by the setup) or of the setup. In single quotes when it is
# quoted in variables.env.original (the values the user typed are not read as a script by the next setup) or has other
# characters than these, which a shell or docker compose reads otherwise; a value with a single quote as it is
write_variables() {
  local line name value
  local content=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      value="${!name}"
      if [[ "${BASH_REMATCH[2]}" == "''" || ! "$value" =~ ^[A-Za-z0-9_./:@%+,=-]*$ ]] && [[ "$value" != *"'"* ]]; then
        value="'${value}'"
      fi
      line="${name}=${value}"
    fi
    content+="${line}"$'\n'
  done < variables.env.original
  printf '%s' "$content" > variables.env
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
  ui_callout error "./zebrunner.sh ${1} did nothing: the docker compose project ${project} is the MCloud of ${dir} (docker compose names the projects and their volumes by the folder), ${1} here would act on its containers and its database (the volume ${project}_stf-db-volume; with the SECRET of this folder its access tokens fail). One MCloud runs on a server: use that folder, or remove that MCloud first (./zebrunner.sh down in ${dir}; its shutdown removes its database too), then ./zebrunner.sh start here (README.md#troubleshooting)."
  return 1
}

# ask <variable> <question> [optional]: reads a value of the interactive setup, the current one by default; a value
# with a quote or a backslash is asked again (variables.env keeps it in quotes), an empty one too unless optional; the
# end of the input with such a value ends the setup
ask() {
  local name="$1"
  local question="$2"
  local optional="$3"
  local answer
  local ended
  local problem
  while true; do
    ended=0
    read -r -p "$(ui_prompt "$question" "[${!name}]")" answer || ended=1
    answer="${answer:-${!name}}"
    problem="$(answer_problem "$answer" "$optional")"
    if [[ -z "$problem" ]]; then
      break
    fi
    end_of_input "$ended" "$question" "$problem"
    ui_warn "$problem"
  done
  printf -v "$name" '%s' "$answer"
}

# ask_secret <variable> <question>: ask without echo, the current value is kept on an empty answer; the end of the
# input without a value ends the setup
ask_secret() {
  local name="$1"
  local question="$2"
  local answer
  local ended
  local problem
  while true; do
    ended=0
    read -r -s -p "$(ui_prompt "$question" "$([[ -n "${!name}" ]] && echo "[keep]")")" answer || ended=1
    echo
    answer="${answer:-${!name}}"
    problem="$(answer_problem "$answer")"
    if [[ -z "$problem" ]]; then
      break
    fi
    end_of_input "$ended" "$question" "$problem"
    ui_warn "$problem"
  done
  printf -v "$name" '%s' "$answer"
}

# answer_problem <answer> [optional]: the reason ask and ask_secret refuse an answer, empty for a valid one
answer_problem() {
  if [[ "$1" == *"'"* || "$1" == *"\\"* ]]; then
    echo "Quotes and backslashes are not supported."
  elif [[ -z "$1" && -z "$2" ]]; then
    echo "A value is needed."
  fi
}

# end_of_input <ended 0|1> <question> <problem>: ends the setup with exit 1 when the input ended (read failed) with an
# answer that is not taken, a question would be asked again forever
end_of_input() {
  if [[ "$1" -eq 1 ]]; then
    echo
    ui_callout error "The input ended at the question '${2}': ${3} Run ./zebrunner.sh setup again with an answer."
    exit 1
  fi
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

# ensure_stf_token: an empty STF_TOKEN of variables.env gets an access token of the admin of STF (STF_ADMIN_EMAIL),
# made in the database by `stf token-add` of the STF image after `stf migrate` (which creates the admin), so no sign-in
# is needed, also with the OAuth2 and LDAP sign-ins (README.md#stf_token). Succeeds when it set STF_TOKEN; without it
# (an STF image without token-add, a database that does not start) start goes on and asks for the token as before
ensure_stf_token() {
  local output
  local token
  [[ -z "$(stf_token)" ]] || return 1
  ui_info "STF_TOKEN of variables.env is empty: creating an access token of the admin of STF"
  # the migration with the database it waits for, then the token on the same database
  if ! output="$(docker compose run --rm -T stf-migrate 2>&1)"; then
    echo_warning "The database of STF is not migrated, STF_TOKEN is not created: $(tail -n 3 <<< "$output" | tr '\n' ' ')"
    return 1
  fi
  output="$(docker compose run --rm -T --no-deps stf-migrate stf token-add --title mcloud 2>&1)"
  token="$(sed -n 's/^token=\([0-9a-f]\{64\}\)$/\1/p' <<< "$output" | tail -n 1)"
  if [[ -z "$token" ]]; then
    echo_warning "STF_TOKEN is not created (an STF image without stf token-add?): $(tail -n 3 <<< "$output" | tr '\n' ' ')"
    return 1
  fi
  set_line variables.env "STF_TOKEN=${token}"
  ui_ok "STF_TOKEN of variables.env is a new access token of the admin of STF (Settings, Keys: mcloud)"
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
    ui_callout error "${file} is not writable for $(id -un): remove it (rm -f ${file}) and run ./zebrunner.sh restart (README.md#troubleshooting)."
    return
  fi
  chmod 600 "$file"
}

# write_grid_env: grid.env, the env file of mcloud-grid (docker-compose.yml): the lines of STF_TOKEN and
# PLAYWRIGHT_ENABLED of variables.env, the only variables of it the grid reads, so the grid gets none of the other
# secrets, and GRID_AUTH_SECRET (README.md#access-to-the-grid), which configuration/stf-proxy/grid-auth.conf gives
# stf-proxy; both readable for their owner only. A variables.env of an earlier MCloud gets a new GRID_AUTH_SECRET. Fails
# when they cannot be written (the grid would start with an old token) and for a nginx.conf of an earlier MCloud, which
# does not send the users to the grid: the grid does not run open until ./zebrunner.sh setup writes the new one
write_grid_env() {
  local secret
  secret="$(sed -n "s/^GRID_AUTH_SECRET=//p" variables.env 2> /dev/null)"
  secret="${secret//\'/}"
  if [[ -z "$secret" && -f variables.env ]]; then
    secret="$(random_string 48)"
    set_line variables.env "GRID_AUTH_SECRET=${secret}"
  fi
  if [[ -f configuration/stf-proxy/nginx.conf ]] && ! grep -q '/_hub_auth/' configuration/stf-proxy/nginx.conf; then
    ui_callout error "configuration/stf-proxy/nginx.conf is the one of an earlier MCloud, without the access to the grid with the access tokens of STF: the services are not started, the grid would be open to anyone. Run ./zebrunner.sh setup, it writes the new configuration (README.md#access-to-the-grid), then ./zebrunner.sh start."
    return 1
  fi
  if ! (umask 077 && {
    echo "# written by ./zebrunner.sh setup and start from variables.env: change variables.env, then ./zebrunner.sh restart"
    grep -E '^(STF_TOKEN|PLAYWRIGHT_ENABLED)=' variables.env || true
    echo "GRID_AUTH_SECRET=${secret}"
  } 2> /dev/null > grid.env); then
    ui_callout error "grid.env is not writable for $(id -un): remove it (rm -f grid.env) and run ./zebrunner.sh start (README.md#troubleshooting)."
    return 1
  fi
  chmod 600 grid.env
  local conf="configuration/stf-proxy/grid-auth.conf"
  if ! (umask 077 && {
    echo "# written by ./zebrunner.sh setup and start from GRID_AUTH_SECRET of variables.env: the secret the grid takes the users"
    echo "# of stf-proxy with (README.md#access-to-the-grid)"
    # the variable of nginx
    # shellcheck disable=SC2016
    printf 'map "" $grid_auth_secret {\n  default "%s";\n}\n' "$secret"
  } 2> /dev/null > "$conf"); then
    ui_callout error "${conf} is not writable for $(id -un): remove it (rm -f ${conf}) and run ./zebrunner.sh start (README.md#troubleshooting)."
    return 1
  fi
  chmod 600 "$conf"
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
  local ended
  while true; do
    ended=0
    read -r -p "$(ui_prompt "Sign-in of STF: ${question}" "[${ZBR_MCLOUD_SIGN_IN}]")" answer || ended=1
    answer="${answer:-$ZBR_MCLOUD_SIGN_IN}"
    if [[ "$answer" =~ ^(${choices})$ ]]; then
      ZBR_MCLOUD_SIGN_IN="$answer"
      break
    fi
    answer="${choices%|*}"
    end_of_input "$ended" "Sign-in of STF" "Please answer ${answer//|/, } or ${choices##*|}."
    ui_warn "Please answer ${answer//|/, } or ${choices##*|}."
  done
  export ZBR_MCLOUD_SIGN_IN

  case "$ZBR_MCLOUD_SIGN_IN" in
  mock)
    STF_AUTH_MOCK_BASIC_AUTH_USERNAME="${STF_AUTH_MOCK_BASIC_AUTH_USERNAME:-mcloud}"
    ;;
  oauth2)
    ui_info "OAuth2 / OpenID Connect: the application of MCloud at the provider redirects to ${1}/auth/oauth/callback"
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
      ui_callout error "The setup makes the CURVE keys with openssl (X25519, OpenSSL 1.1.1+) or python3, neither works here: install one of them (README.md#system-requirements)."
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
    if ! read -r -p "$(ui_prompt "$2" "[${!name}]")" answer && [[ -z "$answer" && ! "${!name}" =~ $3 ]]; then
      echo
      ui_callout error "${4}"
      exit 1
    fi
    answer="${answer:-${!name}}"
    if [[ "$answer" =~ $3 ]]; then
      break
    fi
    ui_warn "$4"
  done
  printf -v "$name" '%s' "$answer"
}

# set_mcloud_settings: asks the protocol, host, port and the admin of the interactive setup
set_mcloud_settings() {
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
    read -r -p "$(ui_prompt "Admin username" "[${ZBR_MCLOUD_ADMIN_NAME}]")" local_admin_name
    if [[ -n "$local_admin_name" ]]; then
      ZBR_MCLOUD_ADMIN_NAME="$local_admin_name"
    fi

    read -r -p "$(ui_prompt "Admin user email" "[${ZBR_MCLOUD_ADMIN_EMAIL}]")" local_admin_mail
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

#### Help

# echo_help: the usage, the commands by group
echo_help() {
  ui_banner "MCloud" "$(mcloud_tag)"
  ui_usage "./zebrunner.sh <command> [options]"
  ui_help_group "Set up"
  ui_help_cmd setup "" "Setup the services"
  ui_help_group "Run"
  ui_help_cmd start "" "Start container"
  ui_help_cmd stop "" "Stop and keep container"
  ui_help_cmd restart "" "Restart container"
  ui_help_cmd down "" "Stop and remove container"
  ui_help_group "Maintain"
  ui_help_cmd backup "" "Backup container"
  ui_help_cmd restore "" "Restore container"
  ui_help_cmd shutdown "" "Stop and remove container, clear volumes"
  ui_help_cmd version "" "Version of container"
  ui_help_cmd doctor "" "The diagnostics of the server (README.md#doctor)"
  ui_help_group "Nodes"
  ui_help_cmd node-invite "<label> <address> [<minutes>]" "The join string of a new node, a secret shown once"
  ui_help_cmd nodes "[list]" "The enrolled nodes"
  ui_help_cmd nodes "check <label>" "The diagnostics of a node"
  ui_help_cmd nodes "revoke <label>" "The revocation of a node"
  ui_help_cmd nodes "delete <label>" "The removal of a revoked node (README.md#nodes)"
  ui_help_group "Help"
  ui_help_cmd help "[<command>]" "The help of a command, nothing of it runs"
  ui_help_cmd completion "bash|zsh" "The completion of the commands (README.md#completion)"
  ui_help_group "Options"
  ui_help_cmd "--help, -h" "" "Print help"
  echo_telegram
}

# is_command <word>: succeeds for a command of COMMANDS
is_command() {
  local command
  for command in $COMMANDS; do
    if [[ "$1" == "$command" ]]; then
      return 0
    fi
  done
  return 1
}

# command_help <command>: the usage, the description and the arguments of a command, nothing of the command runs;
# fails for an unknown command
command_help() {
  case "$1" in
  setup)
    ui_usage "./zebrunner.sh setup"
    echo
    ui_paragraph "Writes .env, variables.env and configuration/stf-proxy/nginx.conf from their *.original files, then offers to start the services. It asks the protocol, the host, the port and the sign-in; the next setups offer the answers of the previous one and keep its values and secrets. ZBR_HOSTNAME=<host> offers that host instead of the public address of ifconfig.me."
    ;;
  start)
    ui_usage "./zebrunner.sh start"
    echo
    ui_paragraph "Starts the services and shows their URLs. The first start (no .env yet) runs the setup instead and exits with 1: run ./zebrunner.sh start again."
    ;;
  stop)
    ui_usage "./zebrunner.sh stop"
    echo
    ui_paragraph "Stops the services, the containers are kept."
    ;;
  restart)
    ui_usage "./zebrunner.sh restart"
    echo
    ui_paragraph "Stops and removes the containers (down), then starts the services (start); the data is kept."
    ;;
  down)
    ui_usage "./zebrunner.sh down"
    echo
    ui_paragraph "Stops and removes the containers, the data is kept."
    ;;
  shutdown)
    ui_usage "./zebrunner.sh shutdown"
    echo
    ui_paragraph "Removes the containers, the data and the settings with their backup copies (*.bak) after a confirmation; it cannot be undone. The certificate of configuration/stf-proxy/ssl and the archive backup/rethinkdb.tar.gz stay."
    ;;
  backup)
    ui_usage "./zebrunner.sh backup"
    echo
    ui_paragraph "Copies the settings to *.bak and the database to backup/rethinkdb.tar.gz. The database and the STF units are stopped for the copy (the UI and the devices are unavailable meanwhile) and started again."
    ;;
  restore)
    ui_usage "./zebrunner.sh restore"
    echo
    ui_paragraph "Stops the services, puts the settings of *.bak back and extracts backup/rethinkdb.tar.gz over the volume of the database, then removes the containers: ./zebrunner.sh start runs the services again."
    ;;
  version)
    ui_usage "./zebrunner.sh version"
    echo
    ui_paragraph "Prints the version of MCloud, the tag of the STF image: mcloud: <tag>."
    ;;
  doctor)
    ui_usage "./zebrunner.sh doctor"
    echo
    ui_paragraph "Checks the server and prints ok, warn or FAIL with the fix of every check: docker and docker compose, the disk of docker, STF_URL and AGENTS_ADDRESS, the secrets of variables.env, the certificate of https, the services, STF_TOKEN and the grid, the ports of the nodes and ./zebrunner.sh nodes check of every node. It changes nothing and exits with 1 when a check fails (README.md#doctor)."
    ;;
  node-invite)
    ui_usage "./zebrunner.sh node-invite <label> <address> [<minutes>]"
    echo
    ui_paragraph "Prints the join string of a new node once, for ./zebrunner.sh join of mcloud-agent on the node: a secret, valid for one join. It needs https, the certificate of stf-proxy and STF_TOKEN (README.md#nodes)."
    ui_help_cmd "<label>" "" "The name of the node: 1-40 lower case letters, digits and -, not - first"
    ui_help_cmd "<address>" "" "The IPv4 address or the host name the server reaches the node at"
    ui_help_cmd "<minutes>" "" "The validity of the invite, 1-1440 minutes, 60 by default"
    ;;
  nodes)
    ui_usage "./zebrunner.sh nodes [list|check <label>|revoke <label>|delete <label>]"
    echo
    ui_paragraph "The registry of the nodes of STF, read with STF_TOKEN of variables.env (README.md#nodes)."
    ui_help_cmd list "" "The enrolled nodes, the default"
    ui_help_cmd check "<label>" "The diagnostics of a node: its record, its devices and their screens"
    ui_help_cmd revoke "<label>" "The revocation of a node: its token and its key are refused"
    ui_help_cmd delete "<label>" "The removal of a revoked node from the registry"
    ;;
  help)
    ui_usage "./zebrunner.sh help [<command>]"
    echo
    ui_paragraph "Prints the help of MCloud, or the one of a command without running it, as ./zebrunner.sh <command> --help does."
    ui_help_cmd "<command>" "" "A command of ./zebrunner.sh help"
    ;;
  completion)
    ui_usage "./zebrunner.sh completion bash|zsh"
    echo
    ui_paragraph "Prints the completion of the commands for the eval of the shell, on a terminal also the eval line of the rc file of the shell (README.md#completion). It runs only a zebrunner.sh of the user or of root that the others cannot write."
    ui_help_cmd bash "" "The completion of bash, its eval line goes to ~/.bashrc"
    ui_help_cmd zsh "" "The completion of zsh, its eval line goes to ~/.zshrc"
    ;;
  *)
    return 1
    ;;
  esac
  echo_telegram
}

# edit_distance <a> <b>: the Levenshtein distance of two words
edit_distance() {
  local a="$1"
  local b="$2"
  local i j cost best
  local previous=()
  local current=()
  for ((j = 0; j <= ${#b}; j++)); do
    previous[j]=$j
  done
  for ((i = 1; i <= ${#a}; i++)); do
    current=("$i")
    for ((j = 1; j <= ${#b}; j++)); do
      cost=1
      if [[ "${a:i-1:1}" == "${b:j-1:1}" ]]; then
        cost=0
      fi
      best=$((previous[j - 1] + cost))
      if [[ $((previous[j] + 1)) -lt "$best" ]]; then
        best=$((previous[j] + 1))
      fi
      if [[ $((current[j - 1] + 1)) -lt "$best" ]]; then
        best=$((current[j - 1] + 1))
      fi
      current[j]=$best
    done
    previous=("${current[@]}")
  done
  echo "${previous[${#b}]}"
}

# closest_commands <word>: the commands of a common prefix of 2 characters at least with the word and the closest ones
# within 2 edits, one per line
closest_commands() {
  local word command distance
  local best=3
  local closest=""
  word="$(tr '[:upper:]' '[:lower:]' <<< "$1")"
  [[ ${#word} -le 32 ]] || return 0
  for command in $COMMANDS --help; do
    distance="$(edit_distance "$word" "$command")"
    if [[ "$distance" -lt "$best" ]]; then
      best="$distance"
    fi
    closest+="${distance} ${command}"$'\n'
  done
  for command in $COMMANDS --help; do
    if { [[ "$best" -le 2 ]] && [[ $'\n'"$closest" == *$'\n'"${best} ${command}"$'\n'* ]]; } ||
      { [[ ${#word} -ge 2 ]] && [[ "$command" == "$word"* || "$word" == "$command"* ]]; }; then
      echo "$command"
    fi
  done
}

# unknown_command <word>: the error of an unknown command with the closest commands and the usage, on stderr
unknown_command() {
  local shown closest command
  local hint=""
  local count=0
  # printable ASCII only (no escape sequences of the terminal) and short: a pasted secret is not shown whole
  shown="$(printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]')"
  if [[ ${#shown} -gt 32 ]]; then
    shown="${shown:0:32}..."
  else
    closest="$(closest_commands "$shown")"
  fi
  for command in $closest; do
    count=$((count + 1))
  done
  for command in $closest; do
    if [[ -n "$hint" ]]; then
      if [[ "$count" -eq 1 ]]; then
        hint+=" or "
      else
        hint+=", "
      fi
    fi
    hint+="'${command}'"
    count=$((count - 1))
  done
  {
    if [[ -n "$hint" ]]; then
      ui_callout error "Unknown command '${shown}'. Did you mean ${hint}?"
    else
      ui_callout error "Unknown command '${shown}'."
    fi
    ui_usage "./zebrunner.sh <command> [options]"
    ui_muted "The commands: ./zebrunner.sh help, one of them: ./zebrunner.sh help <command>"
  } >&2
}

# print_completion <bash|zsh>: patch/completion.sh for the eval of the shell, the line of its rc file on stderr when
# stdout is a terminal; 2 for another shell
print_completion() {
  local rc
  case "${1:-}" in
  bash) rc=".bashrc" ;;
  zsh) rc=".zshrc" ;;
  *)
    {
      ui_callout error "The completion is for bash or zsh."
      ui_usage "./zebrunner.sh completion bash|zsh"
    } >&2
    return 2
    ;;
  esac
  cat patch/completion.sh
  if [[ -t 1 ]]; then
    ui_info "The completion of the current shell: add this line to ~/${rc}" >&2
    # the line for the rc file, expanded there
    # shellcheck disable=SC2016
    printf '\n  eval "$(%q completion %s)"\n\n' "${BASEDIR}/zebrunner.sh" "$1" >&2
  fi
}

#### Main

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASEDIR" || exit

# shellcheck source=patch/utility.sh
source patch/utility.sh
# shellcheck source=patch/ui.sh
source patch/ui.sh
# shellcheck source=patch/mdm.sh
source patch/mdm.sh
# shellcheck source=patch/doctor.sh
source patch/doctor.sh

# Zebrunner CE runs the setup with ZBR_INSTALLER=1, the setup of its MCloud reads ZBR_INSTALLER of its settings too
installer="${ZBR_INSTALLER:-0}"

# <command> --help|-h: the help of the command, nothing of the command runs (e.g. shutdown --help)
if is_command "${1:-}"; then
  for arg in "${@:2}"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      command_help "$1"
      exit 0
    fi
  done
fi

case "$1" in
setup)
  setup
  # Zebrunner CE starts the services itself
  if [[ "$installer" -ne 1 ]]; then
    echo_warning "Your services need to be started after setup."
    if confirm "" "Start now?" "y"; then
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
doctor)
  if [[ -f .disabled ]]; then
    exit 0
  fi
  doctor
  exit
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
help)
  if [[ $# -lt 2 ]]; then
    echo_help
  elif ! command_help "$2"; then
    unknown_command "$2"
    exit 2
  fi
  ;;
completion)
  print_completion "${@:2}"
  exit
  ;;
--help | -h)
  echo_help
  ;;
"")
  echo_help
  exit 1
  ;;
*)
  unknown_command "$1"
  exit 2
  ;;
esac
