#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

echo Starting WDA: ${name}, udid: ${udid}, wda_port: ${wda_port}, mjpeg_port: ${mjpeg_port}
nohup /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ${appium_home}/node_modules/appium-xcuitest-driver/WebDriverAgent/WebDriverAgent.xcodeproj \
      -scheme WebDriverAgentRunner -destination id=$udid USE_PORT=$wda_port MJPEG_SERVER_PORT=$mjpeg_port test 2>&1 &

