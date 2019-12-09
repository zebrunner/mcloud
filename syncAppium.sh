#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo `date +"%T"` Sync Appium script started

logFile=${metaDataFolder}/connectedDevices.txt

while read -r line
do
 	udid=`echo $line | cut -d '|' -f ${udid_position}`
        #to trim spaces around. Do not remove!
	udid=$(echo $udid)
	if [[ "$udid" = "UDID" ]]; then
            continue
        fi
        simulator=`echo $line | grep simul`
        . ${selenium_home}/getDeviceArgs.sh $udid

        appium=`/usr/bin/curl -s --max-time 30 --connect-timeout 30 http://localhost:${appium_port}/wd/hub/status | grep version`
#	appium=`ps -ef | grep $appium_home/build/lib/main.js  | grep $udid`
#	echo appium: $appium

	if [[ -n "$simulator" ]]; then
		device=${name}
	else
	        device=`cat ${logFile} | grep $udid`
	fi
#	echo device: $device

        if [[ -n "$device" && -z "$appium" ]]; then
		echo "Starting appium node: ${udid} - device name : ${name}"
                ${selenium_home}/startNodeAppium.sh $udid
        elif [[ -z "$device" &&  -n "$appium" ]]; then
		echo "Appium will be stopped: ${udid} - device name : ${name}"
		echo device: $device
		echo appium: $appium
#                ${selenium_home}/stopNodeAppium.sh $udid
        else
        	echo "Nothing to do for ${udid} - device name : ${name}"
        fi
done < ${devices}
echo `date +"%T"` Script finished
