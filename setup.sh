#!/bin/bash

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

cd ${BASEDIR}

PUBLIC_IP=$1
PRIVATE_IP=$2

if [ $# -lt 1 ]; then
    printf 'Usage: %s PUBLIC_IP PRIVATE_IP\n' "$(basename "$0")" >&2
    printf 'Example: %s demo.qaprosoft.com 192.168.88.10\n' "$(basename "$0")" >&2
    exit -1
fi

echo generating docker-compose.yml...
sed 's/PUBLIC_IP/'$PUBLIC_IP'/g' docker-compose.yml.original > docker-compose.yml
sed -i 's/PRIVATE_IP/'$PRIVATE_IP'/g' docker-compose.yml

echo generating variables.env...
sed 's/PUBLIC_IP/'$PUBLIC_IP'/g' variables.env.original > variables.env
sed -i 's/PRIVATE_IP/'$PRIVATE_IP'/g' variables.env

echo generating ./nginx/conf.d/default.conf...
sed 's/PUBLIC_IP/'$PUBLIC_IP'/g' ./nginx/conf.d/default.conf.original > ./nginx/conf.d/default.conf
sed -i 's/PRIVATE_IP/'$PRIVATE_IP'/g' ./nginx/conf.d/default.conf


if [[ ! -d stf-storage-temp ]]; then
    echo creating stf-storage-temp folder...
    mkdir stf-storage-temp
fi

if [[ ! -d rethinkdb ]]; then
    echo creating rethinkdb folder...
    mkdir rethinkdb
fi

echo Setup finished successfully using $HOST_NAME hostname.
