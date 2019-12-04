#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo "Script started"
date +"%T"

logFile=${metaDataFolder}/connectedDevices4STF.txt
/usr/local/bin/ios-deploy -c -t 10 > ${logFile}

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
                device=${name}
        else
                device=`cat ${logFile} | grep $udid`
        fi

	wda=`/usr/bin/curl http://${device_ip}:${wda_port}/status --connect-timeout 2 | grep success`
	#TODO: [Optional] think about verification by http call
        stf=`ps -eaf | grep ${udid} | grep 'stf' | grep 'ios-device' | grep -v grep`

        if [[ -n "$device" && -n "$wda" && -z "$stf" ]]; then
		echo "Starting iSTF ios-device: ${udid} device name : ${name}"
                ${selenium_home}/startNodeSTF.sh $udid
        elif [[ -z "$device" &&  -n "$stf" ]]; then
		echo "The iSTF ios-device will be stopped: ${udid} device name : ${name}"
                ${selenium_home}/stopNodeSTF.sh $udid
        elif [[ -n "$device" &&  -n "$stf" && -z "$wda" ]]; then
                echo "WDA is not available! The iSTF ios-device will be stopped: ${udid} device name : ${name}"
                ${selenium_home}/stopNodeSTF.sh $udid
        else
        	echo "Nothing to do for ${udid} device name ${name}"
        fi
done < ${devices}
echo "Script finished"
date +"%T"
