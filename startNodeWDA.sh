#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

echo Starting WDA: ${name}, udid: ${udid}, wda_port: ${wda_port}, mjpeg_port: ${mjpeg_port}

. ${BASEDIR}/getDeviceIPfromLogs.sh "${BASEDIR}/logs/${name}_wda.log" "ServerURLHere->" 300
if [[ $? = 0 ]]
then
  echo "WDA was started for ${name}"
  nohup /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ${appium_home}/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj \
      -scheme WebDriverAgentRunner -destination id=$udid USE_PORT=$wda_port MJPEG_SERVER_PORT=$mjpeg_port test > "${BASEDIR}/logs/${name}_wda.log" 2>&1 &
else
  echo "WDA wasn't started for ${name}"
fi
