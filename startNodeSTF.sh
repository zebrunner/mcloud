#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

export PROVIDER_NAME=iMac-Developer.local
export STF_PUBLIC_HOST=stage.qaprosoft.com
export STF_PRIVATE_HOST=192.168.88.95
#TODO: move rethink db declaration to set_common...
export RETHINKDB_PORT_28015_TCP="tcp://${STF_PUBLIC_HOST}:28015"


#TODO: switch to http and ws if no secure protocol configured
export WEBSOCKET_PROTOCOL=wss
export WEB_PROTOCOL=https
export PROVIDER_NAME=iMac-Developer.local

#iPhone_7         | phone     | 12.3.1 | 4828ca6492816ddd4996fea31c175f7ab97cbc19 | 4841 | 20001 | 20002 | 20003 |  7701   |  7710   | 192.168.88.14
echo Starting iSTF provider for device for $name:$udid
#TODO: parametrize hardcoded path to stf cli
nohup node /Users/build/tools/stf/lib/cli ios-device --serial ${udid} \
        --provider ${PROVIDER_NAME} --screen-port ${stf_min_port} --connect-port ${mjpeg_port} --public-ip ${STF_PUBLIC_HOST} --group-timeout 3600 \
        --storage-url ${WEB_PROTOCOL}://${STF_PUBLIC_HOST}/ --screen-jpeg-quality 40 --screen-ping-interval 30000 \
	--screen-ws-url-pattern ${WEBSOCKET_PROTOCOL}://${STF_PUBLIC_HOST}/d/${nodeHost}/${udid}/${stf_min_port}/ \
        --boot-complete-timeout 60000 --mute-master never \
        --connect-app-dealer tcp://${STF_PRIVATE_HOST}:7160 --connect-dev-dealer tcp://${STF_PRIVATE_HOST}:7260 \
        --wda-host ${device_ip} \
        --wda-port ${wda_port} \
	--vnc-port 7732 \
	--connect-sub tcp://${STF_PRIVATE_HOST}:7250 --connect-push tcp://${STF_PRIVATE_HOST}:7270 --no-cleanup > "${BASEDIR}/logs/${name}_stf.log" 2>&1 &


