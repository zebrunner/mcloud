#!/bin/bash

# shellcheck disable=SC1091
source patch/utility.sh

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

      set_mcloud_settings
      url="$ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_MCLOUD_PORT"
    fi

    cp .env.original .env
    replace .env "STF_URL=http://localhost:8082" "STF_URL=${url}"
    replace .env "STF_PORT=8082" "STF_PORT=$ZBR_MCLOUD_PORT"

    cp variables.env.original variables.env
    replace variables.env "http://localhost:8082" "${url}"
    replace variables.env "localhost" "${ZBR_HOSTNAME}"

    if [[ $ZBR_MINIO_ENABLED -eq 0 ]]; then
      # use case with AWS S3
      replace variables.env "S3_REGION=us-east-1" "S3_REGION=${ZBR_STORAGE_REGION}"
      replace variables.env "S3_ENDPOINT=http://minio:9000" "S3_ENDPOINT=${ZBR_STORAGE_ENDPOINT_PROTOCOL}://${ZBR_STORAGE_ENDPOINT_HOST}"
      replace variables.env "S3_BUCKET=zebrunner" "S3_BUCKET=${ZBR_STORAGE_BUCKET}"
      replace variables.env "S3_ACCESS_KEY_ID=zebrunner" "S3_ACCESS_KEY_ID=${ZBR_STORAGE_ACCESS_KEY}"
      replace variables.env "S3_SECRET=J33dNyeTDj" "S3_SECRET=${ZBR_STORAGE_SECRET_KEY}"
      replace variables.env "S3_TENANT=" "S3_TENANT=${ZBR_STORAGE_TENANT}"
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
  }


  start() {
    if [[ -f .disabled ]]; then
      exit 0
    fi

    # create infra network only if not exist
    docker network inspect infra >/dev/null 2>&1 || docker network create infra

    if [[ ! -f variables.env ]]; then
      cp variables.env.original variables.env
    fi

    if [[ ! -f .env ]]; then
      cp .env.original .env
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
        echo "Invalid option detected: $1"
        echo_help
        exit 1
        ;;
esac

