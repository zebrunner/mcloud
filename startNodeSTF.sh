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
#192.168.88.95


#iPhone_7         | phone     | 12.3.1 | 4828ca6492816ddd4996fea31c175f7ab97cbc19 | 4841 | 20001 | 20002 | 20003 |  7701   |  7710   | 192.168.88.14
echo Starting iSTF provider for device for $name:$udid
#TODO: parametrize stf cli path

nohup node /Users/build/tools/stf/lib/cli ios-device --serial ${udid} \
        --provider iMac-Developer.local --screen-port ${stf_min_port} --connect-port ${mjpeg_port} --vnc-port 7732 --public-ip ${STF_PUBLIC_HOST} --group-timeout 3600 \
        --storage-url https://${STF_PUBLIC_HOST}/ --adb-host 127.0.0.1 --adb-port 5037 --screen-jpeg-quality 40 --screen-ping-interval 30000 \
        --screen-ws-url-pattern wss://${STF_PUBLIC_HOST}/d/${nodeHost}/${udid}/${stf_min_port}/ \
	--connect-url-pattern ${publicIp}:${publicPort} --heartbeat-interval 10000 \
        --boot-complete-timeout 60000 --vnc-initial-size 600x800 --mute-master never \
        --connect-app-dealer tcp://${STF_PRIVATE_HOST}:7160 --connect-dev-dealer tcp://${STF_PRIVATE_HOST}:7260 \
        --wda-host ${device_ip} \
        --wda-port ${wda_port} \
	--udid-storage false --iproxy false --connect-sub tcp://${STF_PRIVATE_HOST}:7250 --connect-push tcp://${STF_PRIVATE_HOST}:7270 --no-cleanup > "${BASEDIR}/logs/${name}_stf.log" 2>&1 &


