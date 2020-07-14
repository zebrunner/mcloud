#!/bin/bash

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

cd ${BASEDIR}

PUBLIC_IP=$1

if [ $# -lt 1 ]; then
    printf 'Usage: %s PUBLIC_IP\n' "$(basename "$0")" >&2
    printf 'Example: %s demo.qaprosoft.com\n' "$(basename "$0")" >&2
    exit -1
fi

echo generating .env...
sed 's/PUBLIC_IP/'$PUBLIC_IP'/g' .env.original > .env

echo generating variables.env...
sed 's/PUBLIC_IP/'$PUBLIC_IP'/g' variables.env.original > variables.env

echo Setup finished successfully using $HOST_NAME hostname.
