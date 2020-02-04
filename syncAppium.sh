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

	appium=`ps -ef | grep $appium_home/build/lib/main.js  | grep $udid`

	if [[ -n "$simulator" ]]; then
		device=${name}
	else
	        device=`cat ${logFile} | grep $udid`
	fi

	wda=`ps -ef | grep xcodebuild | grep $udid | grep WebDriverAgent`
        if [[ -n "$appium" && -z "$wda" ]]; then
                sleep 10
		wda_status=`/usr/bin/curl http://${device_ip}:${wda_port}/status --connect-timeout 5 | grep success`
                if [[ -z "${wda_status}" ]]; then
			echo "Stopping Appium process. Wda is crashed or not started but Appium process exists. ${udid} device name : ${name}"
                	${selenium_home}/stopNodeAppium.sh $udid
                	continue
                fi
        fi

        if [[ -n "$device" && -n "$wda" && -z "$appium" ]]; then
		echo "Starting appium node: ${udid} - device name : ${name}"
                ${selenium_home}/startNodeAppium.sh $udid
        elif [[ -z "$device" &&  -n "$appium" ]]; then
 		#double check if device really empty
                device=`/usr/local/bin/ios-deploy -c -t 5 | grep ${udid}`
                if [[ -z "${device}" ]]; then
                        echo "Appium will be stopped: ${udid} - device name : ${name}"
                        echo device: $device
                        echo appium: $appium
                        ${selenium_home}/stopNodeAppium.sh $udid
                fi
        else
        	echo "Nothing to do for ${udid} - device name : ${name}"
        fi
done < ${devices}
echo `date +"%T"` Script finished
