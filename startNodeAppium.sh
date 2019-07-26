#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

${selenium_home}/configgen.sh $udid > configs/$udid.json


newWDA=false
#echo type: $type
if [ "$type" == "simulator" ]; then
        newWDA=true
fi

echo Starting appium: ${name} device...
nohup node ${appium_home}/build/lib/main.js -p ${appium_port} --log-timestamp \
  --default-capabilities \
  '{"mjpegServerPort": '${mjpeg_port}', "webkitDebugProxyPort": '${iwdp_port}', "clearSystemFiles": "false", "preventWDAAttachments": "true", "simpleIsVisibleCheck": "true", "wdaLocalPort": "'$wda_port'", "usePrebuiltWDA": "true", "useNewWDA": "'$newWDA'", "platformVersion": "'$os_version'", "automationName":"'${automation_name}'", "deviceName":"'$name'" }' \
   --nodeconfig ./configs/$udid.json > "./logs/${name}_${appium_port}.log" 2>&1 &

