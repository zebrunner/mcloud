#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo `date +"%T"` Sync wda script started

logFile=${metaDataFolder}/connectedDevices.txt

while read -r line
do
        udid=`echo $line | cut -d '|' -f ${udid_position}`
        #to trim spaces around. Do not remove!
        udid=$(echo $udid)
        if [ "$udid" = "UDID" ]; then
            continue
        fi
        simulator=`echo $line | grep simul`
       . ${selenium_home}/getDeviceArgs.sh $udid

        #wda check is only for approach with syncWda.sh and usePrebuildWda=true
        wda=`ps -ef | grep xcodebuild | grep $udid | grep WebDriverAgent`

        if [[ -n "$simulator" ]]; then
                device=${name}
        else
                device=`cat ${logFile} | grep $udid`
        fi

        if [[ -n "$device" &&  -z "$wda" ]]; then
		echo "Starting wda: ${udid}"
                ${selenium_home}/startNodeWDA.sh $udid
		# added pause to avoid startup by next sync
		sleep 20
        elif [[ -z "$device" &&  -n "$wda" ]]; then
		echo "WDA  will be stopped: ${udid}"
		echo device: $device
	        echo wda: $wda
        else
                echo "Nothing to do for ${udid} - device name : ${name}"
        fi

done < ${devices}
echo `date +"%T"` Script finished
