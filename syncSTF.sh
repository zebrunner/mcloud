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

	wda=`/usr/bin/curl http://${device_ip}:${wda_port}/status --connect-timeout 2 | grep success`
        stf=`ps -eaf | grep ${udid} | grep 'stf' | grep 'ios-device' | grep -v grep`
	device=`/usr/local/bin/ios-deploy -c -t 1 | grep $udid`
        if [[ -n "$device" && -n "$wda" && -z "$stf" ]]; then
		echo "WDA is running. Starting iSTF ios-device: ${udid} device name : ${name}"
                ${selenium_home}/startNodeSTF.sh $udid
        elif [[ -z "$device" &&  -n "$stf" ]]; then
		echo "The iSTF ios-device will be stopped: ${udid} device name : ${name}"
                ${selenium_home}/stopNodeSTF.sh $udid
	elif [[ -z "$wda" && -n "$device" ]]; then
                echo "WDA is not started for : ${udid} device name ${name}"
        else
        	echo "Nothing to do for ${udid} device name ${name}"
        fi
done < ${devices}
echo "Script finished"
date +"%T"
