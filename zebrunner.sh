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
  local agents_address=""
  local rethinkdb_address=""
  # the settings of the previous setup (the generated secrets, the tokens) are kept
  if [[ -f variables.env ]]; then
    is_new=0
  fi
  # the addresses of the published ports of the previous setup (README.md#firewall)
  if [[ -f .env ]]; then
    agents_address="$(sed -n 's/^AGENTS_ADDRESS=//p' .env)"
    rethinkdb_address="$(sed -n 's/^RETHINKDB_ADDRESS=//p' .env)"
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
    url="${ZBR_PROTOCOL}://${ZBR_HOSTNAME}:${ZBR_MCLOUD_PORT}"
  fi

  # the authentication of RethinkDB and of ZeroMQ: on for a new deployment (its password of RethinkDB tells it later, the
  # missing keys are made again), a deployment of an earlier MCloud turns it on when its device hosts run the
  # mcloud-device of the current STF (README.md#authentication-of-the-device-hosts)
  if [[ "$is_new" -eq 1 || -n "$RETHINKDB_ENV_AUTHKEY" ]]; then
    secure=1
  else
    if [[ "$ZBR_INSTALLER" -ne 1 ]] && confirm "
      RethinkDB and ZeroMQ of STF accept anyone who reaches their ports. The authentication needs mcloud-agent with
      the mcloud-device image of the current STF and the keys of the device hosts in STF_ZMQ_CURVE_CLIENT_KEYS,
      the other device hosts cannot connect." "      Turn the authentication on?" "n"; then
      secure=1
    else
      echo_warning "RethinkDB and ZeroMQ of STF have no authentication, see README.md#authentication-of-the-device-hosts."
    fi
  fi
  if [[ "$secure" -eq 1 ]]; then
    if [[ -z "$RETHINKDB_ENV_AUTHKEY" ]]; then
      RETHINKDB_ENV_AUTHKEY="$(random_string 48)"
    fi
    if [[ -z "$STF_ZMQ_CURVE_SERVER_SECRET_KEY" ]]; then
      set_curve_keys
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

  if [[ "$ZBR_INSTALLER" -eq 1 ]]; then
    replace .env "AUTH_SYSTEM=auth-mock" "AUTH_SYSTEM=auth-zebrunner"
    replace .env "AUTH_URL=auth/mock/" "AUTH_URL=auth/zebrunner/"
  fi

  if [[ -z "$SECRET" || ("$SECRET" == "password" && "$is_new" -eq 1) ]]; then
    # a new secret would end the sessions and invalidate the access tokens (STF_TOKEN) of an existing deployment
    SECRET="$(random_string 48)"
  elif [[ "$SECRET" == "password" ]]; then
    echo_warning "SECRET of variables.env is the default one, replace it to protect the sessions and access tokens of STF (the users sign in again, the access tokens are generated again)."
  fi
  if [[ -z "$STF_STORAGE_TOKEN" ]]; then
    STF_STORAGE_TOKEN="$(random_string 64)"
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
  replace variables.env "STF_ZMQ_CURVE_CLIENT_KEYS=" "STF_ZMQ_CURVE_CLIENT_KEYS=${STF_ZMQ_CURVE_CLIENT_KEYS}"
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
  # the ssl protocol of the default NGiNX configuration
  if [[ "$ZBR_PROTOCOL" == "https" ]]; then
    replace configuration/stf-proxy/nginx.conf "listen 80" "listen 80 ssl"

    # uncomment the default ssl settings
    replace configuration/stf-proxy/nginx.conf "#    ssl_" "    ssl_"

    # ssl.crt and ssl.key are not under source control (#136)
    if [[ ! -f configuration/stf-proxy/ssl/ssl.crt ]]; then
      echo "using self-signed certificate..."
      cp configuration/stf-proxy/ssl/ssl.crt.original configuration/stf-proxy/ssl/ssl.crt
    fi
    if [[ ! -f configuration/stf-proxy/ssl/ssl.key ]]; then
      echo "using self-signed key..."
      cp configuration/stf-proxy/ssl/ssl.key.original configuration/stf-proxy/ssl/ssl.key
    fi
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
  rm -f configuration/stf-proxy/htpasswd/mcloud.htpasswd
  rm -f configuration/stf-proxy/ssl/ssl.crt
  rm -f configuration/stf-proxy/ssl/ssl.key
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

  docker compose up -d
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

  docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "ubuntu" tar -czvf /var/backup/rethinkdb.tar.gz /data
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

  docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "ubuntu" bash -c "cd / && tar -xzvf /var/backup/rethinkdb.tar.gz"
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
