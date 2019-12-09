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
        /usr/bin/curl --max-time 60 --connect-timeout 60 http://${device_ip}:${wda_port}/status > ${metaDataFolder}/${udid}_wda_status.txt 2>&1
        wda=`cat ${metaDataFolder}/${udid}_wda_status.txt | grep success`
#        wda_zombie=`cat ${metaDataFolder}/${udid}_wda_status.txt | grep 'Operation timed out'`
##        echo "wda: $wda"

#        if [[ -n "$wda_zombie" ]]; then
#                echo "WDA process is zombie for simulator udid : ${udid} - device name : ${name}. WDA will be killed and statred."
#                ${selenium_home}/stopNodeWDA.sh $udid
#                continue
#        fi

        if [[ -n "$simulator" ]]; then
                device=${name}
        else
                device=`cat ${logFile} | grep $udid`
        fi
#        echo device: $device

        if [[ -n "$device" &&  -z "$wda" ]]; then
		echo "Starting wda: ${udid}"
                ${selenium_home}/startNodeWDA.sh $udid
		# added pause to avoid startup by next sync
		sleep 10
        elif [[ -z "$device" &&  -n "$wda" ]]; then
		echo "WDA  will be stopped: ${udid}"
		echo device: $device
	        echo wda: $wda
#                ${selenium_home}/stopNodeWDA.sh $udid
        else
                echo "Nothing to do for ${udid} - device name : ${name}"
        fi

done < ${devices}
echo `date +"%T"` Script finished
