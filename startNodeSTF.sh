#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

export PATH=/Users/build/.nvm/versions/node/v8.17.0/bin:$PATH

#TODO: parametrize hardcoded path to stf cli
nohup node /Users/build/tools/stf/lib/cli ios-device --serial ${udid} \
	--device-name ${name} \
        --provider ${PROVIDER_NAME} --screen-port ${stf_screen_port} --connect-port ${mjpeg_port} --public-ip ${STF_PUBLIC_HOST} --group-timeout 3600 \
        --storage-url ${WEB_PROTOCOL}://${STF_PUBLIC_HOST}/ --screen-jpeg-quality 40 --screen-ping-interval 30000 \
	--screen-ws-url-pattern ${WEBSOCKET_PROTOCOL}://${STF_PUBLIC_HOST}/d/${STF_PRIVATE_NODE_HOST}/${udid}/${stf_screen_port}/ \
        --boot-complete-timeout 60000 --mute-master never \
        --connect-app-dealer tcp://${STF_PRIVATE_HOST}:7160 --connect-dev-dealer tcp://${STF_PRIVATE_HOST}:7260 \
        --wda-host ${device_ip} \
        --wda-port ${wda_port} \
        --appium-port ${appium_port} \
        --stf-appium-port ${stf_appium_port} \
        --public-node-ip ${STF_PUBLIC_NODE_HOST} \
	--connect-sub tcp://${STF_PRIVATE_HOST}:7250 --connect-push tcp://${STF_PRIVATE_HOST}:7270 --no-cleanup >> "${BASEDIR}/logs/${name}_stf.log" 2>&1 &
