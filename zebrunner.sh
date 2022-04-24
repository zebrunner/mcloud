#!/bin/bash

  setup() {
    if [[ $ZBR_INSTALLER -eq 1 ]]; then
      # Zebrunner CE installer
      url="$ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_PORT"
      ZBR_MCLOUD_PORT=8082
    else
      # load default interactive installer settings
      source backup/settings.env.original

      # load ./backup/settings.env if exist to declare ZBR* vars from previous run!
      if [[ -f backup/settings.env ]]; then
        source backup/settings.env
      fi

      # load current variables.env if exist to read actual vars even manually updated!
      if [[ -f variables.env ]]; then
        source variables.env
      fi

      set_mcloud_settings
      url="$ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_MCLOUD_PORT"
    fi

    cp .env.original .env
    replace .env "STF_URL=http://localhost:8082" "STF_URL=${url}"
    replace .env "STF_PORT=8082" "STF_PORT=$ZBR_MCLOUD_PORT"

    cp variables.env.original variables.env
    replace variables.env "http://localhost:8082" "${url}"
    replace variables.env "localhost" "${ZBR_HOSTNAME}"

    replace variables.env "STF_TOKEN=" "STF_TOKEN=${STF_TOKEN}"
    replace variables.env "STF_ADMIN_NAME=admin" "STF_ADMIN_NAME=${ZBR_MCLOUD_ADMIN_NAME}"
    replace variables.env "STF_ADMIN_EMAIL=admin@zebrunner.com" "STF_ADMIN_EMAIL=${ZBR_MCLOUD_ADMIN_EMAIL}"

    cp configuration/stf-proxy/nginx.conf.original configuration/stf-proxy/nginx.conf
    replace configuration/stf-proxy/nginx.conf "server_name localhost" "server_name '$ZBR_HOSTNAME'"
    # declare ssl protocol for NGiNX default config
    if [[ "$ZBR_PROTOCOL" == "https" ]]; then
      replace configuration/stf-proxy/nginx.conf "listen 80" "listen 80 ssl"

      # uncomment default ssl settings
      replace configuration/stf-proxy/nginx.conf "#    ssl_" "    ssl_"
    fi


    # export all ZBR* variables to save user input
    export_settings
  }

  shutdown() {
    if [[ -f .disabled ]]; then
      rm -f .disabled
      exit 0 #no need to proceed as nothing was configured
    fi

    docker-compose --env-file .env -f docker-compose.yml down -v

    rm -f backup/settings.env
    rm -f .env
    rm -f variables.env
    rm -f configuration/stf-proxy/nginx.conf
    rm -f configuration/stf-proxy/htpasswd/mcloud.htpasswd
  }


  start() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    # create infra network only if not exist
    docker network inspect infra >/dev/null 2>&1 || docker network create infra

    if [[ ! -f .env ]]; then
      # need proceed with setup steps in advance!
      setup
      exit -1
    fi

    docker-compose --env-file .env -f docker-compose.yml up -d
  }

  stop() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    docker-compose --env-file .env -f docker-compose.yml stop
  }

  down() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    docker-compose --env-file .env -f docker-compose.yml down
  }

  backup() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    cp variables.env variables.env.bak
    cp .env .env.bak
    cp backup/settings.env backup/settings.env.bak
    cp configuration/stf-proxy/nginx.conf configuration/stf-proxy/nginx.conf.bak
    cp configuration/stf-proxy/htpasswd/mcloud.htpasswd configuration/stf-proxy/htpasswd/mcloud.htpasswd.bak

    docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "ubuntu" tar -czvf /var/backup/rethinkdb.tar.gz /data
  }

  restore() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    stop
    cp variables.env.bak variables.env
    cp .env.bak .env
    cp backup/settings.env.bak backup/settings.env
    cp configuration/stf-proxy/nginx.conf.bak configuration/stf-proxy/nginx.conf
    cp configuration/stf-proxy/htpasswd/mcloud.htpasswd.bak configuration/stf-proxy/htpasswd/mcloud.htpasswd

    docker run --rm --volumes-from rethinkdb -v "$(pwd)"/backup:/var/backup "ubuntu" bash -c "cd / && tar -xzvf /var/backup/rethinkdb.tar.gz"
    down
  }

  version() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    source .env
    echo "mcloud: ${TAG_STF}"
  }

  set_mcloud_settings() {
    echo "Zebrunner MCloud Settings"
    local is_confirmed=0
    if [[ -z $ZBR_HOSTNAME ]]; then
      ZBR_HOSTNAME=`curl -s ifconfig.me`
    fi

    while [[ $is_confirmed -eq 0 ]]; do
      read -r -p "Protocol [$ZBR_PROTOCOL]: " local_protocol
      if [[ ! -z $local_protocol ]]; then
        ZBR_PROTOCOL=$local_protocol
      fi

      read -r -p "Fully qualified domain name (ip) [$ZBR_HOSTNAME]: " local_hostname
      if [[ ! -z $local_hostname ]]; then
        ZBR_HOSTNAME=$local_hostname
      fi

      read -r -p "Port [$ZBR_MCLOUD_PORT]: " local_port
      if [[ ! -z $local_port ]]; then
        ZBR_MCLOUD_PORT=$local_port
      fi

      confirm "Zebrunner MCloud STF URL: $ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_MCLOUD_PORT/stf" "Continue?" "y"
      is_confirmed=$?
    done

    export ZBR_PROTOCOL=$ZBR_PROTOCOL
    export ZBR_HOSTNAME=$ZBR_HOSTNAME
    export ZBR_MCLOUD_PORT=$ZBR_MCLOUD_PORT

    is_confirmed=0
    while [[ $is_confirmed -eq 0 ]]; do
      read -r -p "Admin username [$ZBR_MCLOUD_ADMIN_NAME]: " local_admin_name
      if [[ ! -z $local_admin_name ]]; then
        ZBR_MCLOUD_ADMIN_NAME=$local_admin_name
      fi

      read -r -p "Admin user email [$ZBR_MCLOUD_ADMIN_EMAIL]: " local_admin_mail
      if [[ ! -z $local_admin_mail ]]; then
        ZBR_MCLOUD_ADMIN_EMAIL=$local_admin_mail
      fi
      confirm "Zebrunner MCloud admin username: $ZBR_MCLOUD_ADMIN_NAME; email: $ZBR_MCLOUD_ADMIN_EMAIL" "Continue?" "y"
      is_confirmed=$?
    done

    export ZBR_MCLOUD_ADMIN_NAME=$ZBR_MCLOUD_ADMIN_NAME
    export ZBR_MCLOUD_ADMIN_EMAIL=$ZBR_MCLOUD_ADMIN_EMAIL
  }

  echo_warning() {
    echo "
      WARNING! $1"
  }

  echo_telegram() {
    echo "
      For more help join telegram channel: https://t.me/zebrunner
      "
  }

  echo_help() {
    echo "
      Usage: ./zebrunner.sh [option]
      Flags:
          --help | -h    Print help
      Arguments:
      	  start          Start container
      	  stop           Stop and keep container
      	  restart        Restart container
      	  down           Stop and remove container
      	  shutdown       Stop and remove container, clear volumes
      	  backup         Backup container
      	  restore        Restore container
      	  version        Version of container"
      echo_telegram
      exit 0
  }

  replace() {
    #TODO: https://github.com/zebrunner/zebrunner/issues/328 organize debug logging for setup/replace
    file=$1
    #echo "file: $file"
    content=$(<"$file") # read the file's content into
    #echo "content: $content"

    old=$2
    #echo "old: $old"

    new=$3
    #echo "new: $new"
    content=${content//"$old"/$new}

    #echo "content: $content"
    printf '%s' "$content" >"$file"    # write new content to disk
  }


BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASEDIR}" || exit

# shellcheck disable=SC1091
source patch/utility.sh

case "$1" in
    setup)
        setup
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

