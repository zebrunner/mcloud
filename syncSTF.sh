#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo `date +"%T"` Script started

logFile=${metaDataFolder}/connectedDevices.txt

while read -r line
do
        udid=`echo $line | cut -d '|' -f ${udid_position}`
        #to trim spaces around. Do not remove!
        udid=$(echo $udid)
        if [ "$udid" = "UDID" ]; then
            continue
        fi
       . ${selenium_home}/getDeviceArgs.sh $udid

        simulator=`echo $line | grep simul`

        if [[ -n "$simulator" ]]; then
#                device=${name}
		# simulators temporary unavailable in iSTF
		continue
        else
                device=`cat ${logFile} | grep $udid`
        fi

        stf=`ps -eaf | grep ${udid} | grep 'ios-device' | grep -v grep`
	wda=`ps -ef | grep xcodebuild | grep $udid | grep WebDriverAgent`
        if [[ -n "$stf" && -z "$wda" ]]; then
                echo "Stopping STF process. Wda is crashed or not started but STF process exists. ${udid} device name : ${name}"
                ${selenium_home}/stopNodeSTF.sh $udid
                continue
        fi

        if [[ -n "$device" && -n "$wda" && -z "$stf" ]]; then
		echo "Starting iSTF ios-device: ${udid} device name : ${name}"
                ${selenium_home}/startNodeSTF.sh $udid
        elif [[ -z "$device" && -n "$stf" ]]; then
		device_status=`/usr/local/bin/ios-deploy -c -t 5 | grep ${udid}`
		if [[ -z "${device_status}" ]]; then
			echo "The iSTF ios-device will be stopped: ${udid} device name : ${name}"
                	echo device: $device
                	echo stf: $stf
            		${selenium_home}/stopNodeSTF.sh $udid
        	fi
        else
        	echo "Nothing to do for ${udid} device name ${name}"
        fi
done < ${devices}
echo `date +"%T"` Script finished
