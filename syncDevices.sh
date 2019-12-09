#!/bin/bash

# 07-DEC-2019
# To setup analogue of the udev rules for MAC OS we are going to use ios-deploy utility and LaunchScripts agents
# Every 5-10 sec script is looking for the connected devices and regenerated devices list into the file
# Generated metafile could be used by other sync scripts to start/stop services for each iOS device

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo `date +"%T"` Sync connected physical iOS devices script started

devicesFile=${metaDataFolder}/connectedDevices.txt
/usr/local/bin/ios-deploy -c -t 5 > ${devicesFile}

#TODO: compare previous and actual files to generate list of connected and disconnected devices
#      device udid which present only in previous analysis - disconnected
#      device udid which present only in actual analysis - connected
#      device udid which present in both - still connected

echo `date +"%T"` Script finished
