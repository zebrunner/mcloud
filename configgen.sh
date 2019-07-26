#!/bin/bash

udid=$1

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh
. ${BASEDIR}/getDeviceArgs.sh $udid


DEVICENAME=${name}
DEVICETYPE=${type}
DEVICEVERSION=${os_version}
DEVICEPLATFORM=MAC
DEVICEOS=iOS
DEVICEUDID=${udid}

AUTOMATION_NAME=${automation_name}
HUB_PORT=${hubPort}
HUB_HOST=${hubHost}

# current host
HOST=${nodeHost}
PORT=${appium_port}

WDA_PORT=${wda_port}

cat << EndOfMessage
{
  "capabilities":
      [
        {
          "browserName": "${DEVICENAME}",
          "version":"${DEVICEVERSION}",
          "maxInstances": 1,
          "platform":"${DEVICEPLATFORM}",
	  "deviceName": "${DEVICENAME}",
          "deviceType": "${DEVICETYPE}",
          "platformName":"${DEVICEOS}",
          "platformVersion":"${DEVICEVERSION}",
	  "udid": "${DEVICEUDID}"
        }
      ],
  "configuration":
  {
    "proxy": "com.qaprosoft.carina.grid.MobileRemoteProxy",
    "url":"http://${HUB_HOST}:${HUB_PORT}/wd/hub",
    "port": ${PORT},
    "host": "${HOST}",
    "hubPort": ${HUB_PORT},
    "hubHost": "${HUB_HOST}",
    "timeout": 180,
    "maxSession": 1,
    "register": true,
    "registerCycle": 5000,
    "automationName": "${AUTOMATION_NAME}"
  }
}
EndOfMessage
