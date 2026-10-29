#!/bin/bash
# The management of the MCloud services: ./zebrunner.sh <command>, see echo_help.
# Zebrunner CE runs it with ZBR_INSTALLER=1 and its ZBR_* settings, the shutdown with SHUTDOWN_CONFIRMED=1.
# Keep it compatible with the macOS system bash 3.2 (CONVENTIONS.md).

#### Commands

# setup: writes .env, variables.env and the nginx configuration from their *.original files
setup() {
  local url
  local is_new=1
  local secure=0
  local secret_rotated=0
  local sign_in="zebrunner"
  local agents_address=""
  local log_max_size=""
  local log_max_file=""
  local rethinkdb_address=""
  AGENT_HOSTS=""
  # the settings of the previous setup (the generated secrets, the tokens) are kept
  if [[ -f variables.env ]]; then
    is_new=0
  fi
  # the addresses of the published ports of the previous setup (README.md#firewall)
  if [[ -f .env ]]; then
    agents_address="$(sed -n 's/^AGENTS_ADDRESS=//p' .env)"
    rethinkdb_address="$(sed -n 's/^RETHINKDB_ADDRESS=//p' .env)"
    AGENT_HOSTS="$(sed -n 's/^AGENT_HOSTS=//p' .env)"
    log_max_size="$(sed -n 's/^LOG_MAX_SIZE=//p' .env)"
    log_max_file="$(sed -n 's/^LOG_MAX_FILE=//p' .env)"
  fi
  # the variables of variables.env.original, overridden by the current variables.env, even the manual changes
  # shellcheck source=variables.env.original
  source variables.env.original
  if [[ "$is_new" -eq 0 ]]; then
    # shellcheck source=/dev/null
    source variables.env
  fi

  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    # Zebrunner CE installer
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_PORT}"
    ZBR_MCLOUD_PORT=8082
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
    set_sign_in
    sign_in="$ZBR_MCLOUD_SIGN_IN"
    set_agent_hosts
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}"
  fi

  # https: the certificate is checked before anything is written (README.md#https)
  if [[ "$ZBR_PROTOCOL" == "https" ]] && ! set_certificate; then
    exit 1
  fi

  # the authentication of RethinkDB, of ZeroMQ and of the grid registration: on for a new deployment (its password of
  # RethinkDB tells it later, the missing keys and token are made again), a deployment of an earlier MCloud turns it on
  # when its device hosts run the mcloud-device and appium of the current MCloud (README.md#authentication-of-the-device-hosts)
  if [[ "$is_new" -eq 1 || -n "$RETHINKDB_ENV_AUTHKEY" ]]; then
    secure=1
  else
    if [[ "$ZBR_INSTALLER" -ne 1 ]] && confirm "
      RethinkDB and ZeroMQ of STF accept anyone who reaches their ports, the grid registers any Appium node. The
      authentication needs mcloud-agent with the mcloud-device and appium images of the current MCloud, the keys of
      the device hosts in STF_ZMQ_CURVE_CLIENT_KEYS and NODE_REGISTRATION_TOKEN, the other device hosts cannot connect." "      Turn the authentication on?" "n"; then
      secure=1
    else
      echo_warning "RethinkDB and ZeroMQ of STF have no authentication, the grid registers any Appium node, see README.md#authentication-of-the-device-hosts."
    fi
  fi
  if [[ "$secure" -eq 1 ]]; then
    if [[ -z "$RETHINKDB_ENV_AUTHKEY" ]]; then
      RETHINKDB_ENV_AUTHKEY="$(random_string 48)"
    fi
    if [[ -z "$STF_ZMQ_CURVE_SERVER_SECRET_KEY" ]]; then
      set_curve_keys
    fi
    if [[ -z "$NODE_REGISTRATION_TOKEN" ]]; then
      NODE_REGISTRATION_TOKEN="$(random_string 48)"
    fi
    # the device units of the current STF have no database
    rethinkdb_address="127.0.0.1"
  elif [[ -z "$rethinkdb_address" ]]; then
    # the device hosts of an earlier MCloud connect to RethinkDB
    rethinkdb_address="0.0.0.0"
  fi

  cp .env.original .env
  replace .env "STF_URL=http://localhost:8082" "STF_URL=${url}"
  replace .env "STF_PORT=8082" "STF_PORT=${ZBR_MCLOUD_PORT}"
  replace .env "AGENTS_ADDRESS=0.0.0.0" "AGENTS_ADDRESS=${agents_address:-0.0.0.0}"
  replace .env "RETHINKDB_ADDRESS=127.0.0.1" "RETHINKDB_ADDRESS=${rethinkdb_address}"
  replace .env "AGENT_HOSTS=" "AGENT_HOSTS=${AGENT_HOSTS}"
  replace .env "LOG_MAX_SIZE=50m" "LOG_MAX_SIZE=${log_max_size:-50m}"
  replace .env "LOG_MAX_FILE=5" "LOG_MAX_FILE=${log_max_file:-5}"
  write_agent_hosts

  # the sign-in unit of STF and its path: Zebrunner IAM in Zebrunner CE, the choice of the interactive setup otherwise
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

  if [[ -z "$SECRET" || ("$SECRET" == "password" && "$is_new" -eq 1) ]]; then
    # a new secret would end the sessions and invalidate the access tokens (STF_TOKEN) of an existing deployment
    SECRET="$(random_string 48)"
  elif [[ "$SECRET" == "password" ]]; then
    if [[ "$ZBR_INSTALLER" -ne 1 ]] && confirm "
      SECRET of variables.env is the default one: anyone can sign the sessions and the access tokens of STF. A new one
      ends the sessions (the users sign in again) and invalidates the access tokens." "      Generate a new SECRET?" "y"; then
      SECRET="$(random_string 48)"
      secret_rotated=1
    else
      echo_warning "SECRET of variables.env is the default one, replace it to protect the sessions and access tokens of STF (the users sign in again, the access tokens are generated again)."
    fi
  fi
  if [[ -z "$STF_STORAGE_TOKEN" ]]; then
    STF_STORAGE_TOKEN="$(random_string 64)"
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

  echo "
      Set STF_STORAGE_TOKEN of variables.env as STF_STORAGE_TOKEN of mcloud-agent: the STF storage accepts the devices with this token only."
  if [[ -n "$STF_ZMQ_CURVE_SERVER_PUBLIC_KEY" ]]; then
    echo "
      Set STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of variables.env as STF_ZMQ_CURVE_SERVER_PUBLIC_KEY of mcloud-agent and add the
      public key mcloud-agent prints to STF_ZMQ_CURVE_CLIENT_KEYS of variables.env (separated by commas), then restart:
      STF accepts the device hosts with these keys only."
  fi
  if [[ -n "$NODE_REGISTRATION_TOKEN" ]]; then
    echo "
      Set NODE_REGISTRATION_TOKEN of variables.env as NODE_REGISTRATION_TOKEN of mcloud-agent: the grid registers the
      Appium nodes with this token only."
  fi
  if [[ "$sign_in" == "mock" ]]; then
    echo "
      The sign-in of STF asks the user '${STF_AUTH_MOCK_BASIC_AUTH_USERNAME}' and the password '${STF_AUTH_MOCK_BASIC_AUTH_PASSWORD}' (STF_AUTH_MOCK_BASIC_AUTH_* of
      variables.env), then any name and email: share them with the users of STF only."
  fi
  if [[ "$secret_rotated" -eq 1 ]]; then
    echo_warning "SECRET is new: the users sign in again; generate STF_TOKEN of the grid again (Settings, Keys of STF) and set it in variables.env, the grid reserves no device until then."
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

  docker compose down -v

  rm -f backup/settings.env
  rm -f .env
  rm -f variables.env
  rm -f configuration/stf-proxy/nginx.conf
  rm -f configuration/stf-proxy/agent-hosts.conf
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

  # AGENT_HOSTS of .env may have changed since the setup
  write_agent_hosts
  docker compose up -d || return

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

  docker compose stop
}

# down: stops and removes the containers, the data is kept
down() {
  if [[ -f .disabled ]]; then
    exit 0
  fi

  docker compose down
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
  docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "rethinkdb:$(rethinkdb_tag)" \
    tar -czf /var/backup/rethinkdb.tar.gz /data || status=$?
  if [[ -n "$running" ]]; then
    # shellcheck disable=SC2086
    docker compose start $running
  fi
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

#### Helpers

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
# the certificate and, but for Zebrunner CE, for the self-signed pair of the earlier versions
set_certificate() {
  local dir="configuration/stf-proxy/ssl"
  local shared=0
  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    if [[ ! -f "${BASEDIR}/../nginx/ssl/ssl.crt" || ! -f "${BASEDIR}/../nginx/ssl/ssl.key" ]]; then
      echo_warning "https needs the certificate of Zebrunner CE: ../nginx/ssl/ssl.crt and ../nginx/ssl/ssl.key are missing."
      return 1
    fi
    cp "${BASEDIR}/../nginx/ssl/ssl.crt" "${dir}/ssl.crt"
    cp "${BASEDIR}/../nginx/ssl/ssl.key" "${dir}/ssl.key"
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
    echo_warning "${dir}/ssl.crt and ssl.key are the self-signed pair of the earlier MCloud versions, its private key is public: replace them with the certificate of ${ZBR_HOSTNAME} (README.md#https)."
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

# set_agent_hosts: asks the device hosts of the interactive setup, AGENT_HOSTS of .env (README.md#screens-of-the-devices)
set_agent_hosts() {
  local answer
  while true; do
    read -r -p "Device hosts, STF_PROVIDER_HOST of mcloud-agent separated by commas (stf-proxy serves the screens of their devices) [${AGENT_HOSTS}]: " answer
    answer="${answer:-$AGENT_HOSTS}"
    answer="${answer// /}"
    if [[ "$answer" =~ ^[A-Za-z0-9.,-]*$ ]]; then
      AGENT_HOSTS="$answer"
      break
    fi
    echo "Host names and addresses separated by commas only."
  done
}

# write_agent_hosts: configuration/stf-proxy/agent-hosts.conf of nginx from AGENT_HOSTS of .env: the device hosts whose
# screens stf-proxy serves; warns when there is none
write_agent_hosts() {
  local hosts=()
  local host
  IFS=',' read -r -a hosts <<< "$(sed -n 's/^AGENT_HOSTS=//p' .env)"
  : > configuration/stf-proxy/agent-hosts.conf
  for host in "${hosts[@]}"; do
    host="${host// /}"
    if [[ -z "$host" ]]; then
      continue
    elif [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
      echo "\"${host}\" 1;" >> configuration/stf-proxy/agent-hosts.conf
    else
      echo_warning "'${host}' of AGENT_HOSTS of .env is not a host name or address, it is skipped."
    fi
  done
  if [[ ! -s configuration/stf-proxy/agent-hosts.conf ]]; then
    echo_warning "AGENT_HOSTS of .env is empty: stf-proxy serves no screen of a device, set the device hosts there (README.md#screens-of-the-devices)."
  fi
}

# set_sign_in: asks the sign-in of STF of the interactive setup and its settings (README.md#sign-in)
set_sign_in() {
  local answer
  ZBR_MCLOUD_SIGN_IN="${ZBR_MCLOUD_SIGN_IN:-mock}"
  while true; do
    read -r -p "Sign-in of STF: mock (any name and email behind a shared password), oauth2 (OpenID Connect) or ldap [${ZBR_MCLOUD_SIGN_IN}]: " answer
    answer="${answer:-$ZBR_MCLOUD_SIGN_IN}"
    if [[ "$answer" =~ ^(mock|oauth2|ldap)$ ]]; then
      ZBR_MCLOUD_SIGN_IN="$answer"
      break
    fi
    echo "Please answer mock, oauth2 or ldap."
  done
  export ZBR_MCLOUD_SIGN_IN

  case "$ZBR_MCLOUD_SIGN_IN" in
  mock)
    STF_AUTH_MOCK_BASIC_AUTH_USERNAME="${STF_AUTH_MOCK_BASIC_AUTH_USERNAME:-mcloud}"
    ;;
  oauth2)
    echo "OAuth2 / OpenID Connect: the application of MCloud at the provider redirects to ${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}/auth/oauth/callback"
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

# set_curve_keys: the CURVE keys of ZeroMQ of a new deployment by `stf curve-keygen` of the STF image (TAG_STF of the
# environment overrides the one of .env, as for docker compose): the pair of the triproxies and the one of the STF units;
# none when the image cannot make them
set_curve_keys() {
  local tag="$TAG_STF"
  local name
  local key
  local keys=()
  if [[ -z "$tag" ]]; then
    tag="$(sed -n 's/^TAG_STF=//p' .env.original)"
  fi
  while IFS='=' read -r name key; do
    if [[ "$name" =~ ^(public|secret)$ && "$key" =~ ^[0-9a-f]{64}$ ]]; then
      keys+=("$key")
    fi
  done < <(docker run --rm "public.ecr.aws/zebrunner/stf:${tag}" sh -c 'stf curve-keygen && stf curve-keygen' 2> /dev/null)
  if [[ "${#keys[@]}" -ne 4 ]]; then
    echo_warning "The STF image ${tag} made no CURVE keys (stf curve-keygen): ZeroMQ of STF has no authentication."
    return
  fi
  STF_ZMQ_CURVE_SERVER_PUBLIC_KEY="${keys[0]}"
  STF_ZMQ_CURVE_SERVER_SECRET_KEY="${keys[1]}"
  STF_ZMQ_CURVE_SECRET_KEY="${keys[3]}"
}

# set_mcloud_settings: asks the protocol, host, port and the admin of the interactive setup
set_mcloud_settings() {
  local local_protocol
  local local_hostname
  local local_port
  local local_admin_name
  local local_admin_mail

  echo "Zebrunner MCloud Settings"
  if [[ -z "$ZBR_HOSTNAME" ]]; then
    ZBR_HOSTNAME="$(curl -s ifconfig.me)"
  fi

  while true; do
    read -r -p "Protocol [${ZBR_PROTOCOL}]: " local_protocol
    if [[ -n "$local_protocol" ]]; then
      ZBR_PROTOCOL="$local_protocol"
    fi

    read -r -p "Fully qualified domain name (ip) [${ZBR_HOSTNAME}]: " local_hostname
    if [[ -n "$local_hostname" ]]; then
      ZBR_HOSTNAME="$local_hostname"
    fi

    read -r -p "Port [${ZBR_MCLOUD_PORT}]: " local_port
    if [[ -n "$local_port" ]]; then
      ZBR_MCLOUD_PORT="$local_port"
    fi

    if confirm "Zebrunner MCloud STF URL: ${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}/stf" "Continue?" "y"; then
      break
    fi
  done

  export ZBR_PROTOCOL
  export ZBR_HOSTNAME
  export ZBR_MCLOUD_PORT

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
          version        Version of container"
  echo_telegram
}

#### Main

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASEDIR" || exit

# shellcheck source=patch/utility.sh
source patch/utility.sh

case "$1" in
setup)
  setup
  # Zebrunner CE starts the services itself
  if [[ "$ZBR_INSTALLER" -ne 1 ]]; then
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
--help | -h)
  echo_help
  ;;
*)
  echo_help
  exit 1
  ;;
esac
