#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

if [ "${device_ip}" == "" ]; then
  echo "Unable to detect ${name} device ip address! No sense to start Appium!" >> "${BASEDIR}/logs/${name}_appium.log"
  exit -1
fi

${selenium_home}/configgen.sh $udid > configs/$udid.json


newWDA=false
#TODO: investigate if tablet should be registered separately, what about tvOS

export PATH=/Users/build/.nvm/versions/node/v13.11.0/bin:$PATH

nohup node ${appium_home}/build/lib/main.js -p ${appium_port} --log-timestamp --device-name "${name}" --automation-name=XCUItest --udid $udid \
  --default-capabilities \
  '{"mjpegServerPort": '${mjpeg_port}', "webkitDebugProxyPort": '${iwdp_port}', "clearSystemFiles": "false", "webDriverAgentUrl":"'http://${device_ip}:${wda_port}'", "preventWDAAttachments": "true", "simpleIsVisibleCheck": "true", "wdaLocalPort": "'$wda_port'", "usePrebuiltWDA": "true", "useNewWDA": "'$newWDA'", "platformVersion": "'$os_version'", "automationName":"'${automation_name}'", "deviceName":"'$name'" }' \
   --nodeconfig ./configs/$udid.json >> "${BASEDIR}/logs/${name}_appium.log" 2>&1 &
