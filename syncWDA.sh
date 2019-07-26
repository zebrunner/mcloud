#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo “Start wda script started”
date +“%T”
while read -r line
do
        udid=`echo $line | cut -d '|' -f ${udid_position}`
        #to trim spaces around. Do not remove!
        udid=$(echo $udid)
        if [ "$udid" = "UDID" ]; then
            continue
        fi

        wda=`ps -ef | grep xcodebuild | grep $udid | grep WebDriverAgent`

        simulator=`echo $line | grep simul`
        if [[ -n "$simulator" && -n "$wda" ]]; then
                echo "WDA is running for simulator : ${udid}"
                continue
        elif [[ -n "$simulator" ]]; then
                echo "Will check if WDA needed for simulator : ${simulator}"
                device=`instruments -s devices | grep $udid`
        fi
        if [[ -n "$simulator" && -z "$device" ]]; then
                echo "Simulator is populated in ${devices} but not started in OS"
                continue
        elif [[ -n "$simulator" && -z "$wda" ]]; then
                echo "Starting simulator WDA: ${udid}"
                ${selenium_home}/startNodeWDA.sh $udid
                continue
        fi


	device=`/usr/local/bin/ios-deploy -c -t 1 | grep $udid`
        if [[ -n "$device" &&  -z "$wda" ]]; then
		echo "Starting wda: ${udid}"
                ${selenium_home}/startNodeWDA.sh $udid
        elif [[ -z "$device" &&  -n "$wda" ]]; then
		echo "WDA  will be stopped: ${udid}"
        else
        	echo "Nothing to do for ${udid}"
        fi
done < ${devices}
echo “Script finished”
date +“%T”
