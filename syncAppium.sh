#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo "Script started"
date +"%T"
while read -r line
do
 	udid=`echo $line | cut -d '|' -f ${udid_position}`
	. ${selenium_home}/getDeviceArgs.sh $udid
        #to trim spaces around. Do not remove!
	udid=$(echo $udid)
	if [ "$udid" = "UDID" ]; then
            continue
        fi

        appium=`ps -ef | grep $appium_home/build/lib/main.js  | grep $udid`
	simulator=`echo $line | grep simul`
	if [[ -n "$simulator" && -n "$appium" ]]; then
		echo "Appium is running for simulator : ${udid}"
		continue
	elif [[ -n "$simulator" ]]; then
		echo "Will check if appium needed for simulator : ${simulator}"
		device=`instruments -s devices | grep $udid`
	fi
	if [[ -n "$simulator" && -z "$device" ]]; then
		echo "Simulator is populated in ${devices} but not started in OS"
		continue
	elif [[ -n "$simulator" && -z "$appium" ]]; then
		echo "Starting simulator: ${udid}"
		${selenium_home}/startNodeAppium.sh $udid
		continue
	fi

	device=`/usr/local/bin/ios-deploy -c -t 1 | grep $udid`
	#wda check is only for approach with syncWda.sh and usePrebuildWda=true
	wda=`/usr/bin/curl http://${device_ip}:${wda_port}/status --connect-timeout 2 | grep success`
        if [[ -n "$device" && -z "$wda" && -n "$appium" ]]; then
           	echo "WDA is not started or possible crashed for device udid : ${udid} - device name : ${name} . Appium will be stopped till WDA is down."
		${selenium_home}/stopNodeAppium.sh $udid
        elif [[ -n "$device" && -n "$wda" && -z "$appium" ]]; then
		echo "WDA has been started. Starting appium node: ${udid} - device name : ${name}"
                ${selenium_home}/startNodeAppium.sh $udid
	elif [[ -n "$device" && -z "$wda" ]]; then
                echo "WDA is not running. Waiting WDA for : ${udid} - device name : ${name}"
        elif [[ -z "$device" &&  -n "$appium" ]]; then
		echo "The node will be stopped: ${udid} - device name : ${name}"
                ${selenium_home}/stopNodeAppium.sh $udid
        else
        	echo "Nothing to do for ${udid} - device name : ${name}"
        fi
done < ${devices}
echo "Script finished"
date +"%T"
