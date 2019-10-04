#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

export PROVIDER_NAME=iMac-Developer.local
export STF_HOST=stage.qaprosoft.com
#TODO: move rethink db declaration to set_common...
export RETHINKDB_PORT_28015_TCP="tcp://${STF_HOST}:28015"
#192.168.88.95


#iPhone_7         | phone     | 12.3.1 | 4828ca6492816ddd4996fea31c175f7ab97cbc19 | 4841 | 20001 | 20002 | 20003 |  7701   |  7710   | 192.168.88.14
echo Starting iSTF provider for device for $name:$udid
#TODO: parametrize stf cli path

nohup node /Users/build/tools/stf/lib/cli ios-device --serial ${udid} \
        --provider iMac-Developer.local --screen-port ${stf_min_port} --connect-port ${mjpeg_port} --vnc-port 7732 --public-ip ${STF_HOST} --group-timeout 3600 \
        --storage-url https://${STF_HOST}/ --adb-host 127.0.0.1 --adb-port 5037 --screen-jpeg-quality 40 --screen-ping-interval 30000 \
        --screen-ws-url-pattern ws://${publicIp}:${publicPort} --connect-url-pattern ${publicIp}:${publicPort} --heartbeat-interval 10000 \
        --boot-complete-timeout 60000 --vnc-initial-size 600x800 --mute-master never \
        --connect-app-dealer tcp://192.168.88.95:7160 --connect-dev-dealer tcp://192.168.88.95:7260 \
        --wda-host ${device_ip} \
        --wda-port ${wda_port} \
	--udid-storage false --iproxy false --connect-sub tcp://192.168.88.95:7250 --connect-push tcp://192.168.88.95:7270 --no-cleanup > "${BASEDIR}/logs/${name}_stf.log" 2>&1 &

#--screen-ws-url-pattern "wss://${STF_HOST}/d/192.168.88.91/b3c999df4a0de71be4fb5878f0df20c25442b883/7702/" &
#--screen-ws-url-pattern "wss://istf.qaprosoft.com/d/192.168.88.91/<%= serial %>/<%= publicPort %>/" &


