#!/bin/bash
devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

if [ "${udid}" != "" ]; then
	kill -9 `ps -eaf | grep ${udid} | grep 'stf' | grep 'ios-device' | grep -v grep | awk '{ print $2 }'`
fi



