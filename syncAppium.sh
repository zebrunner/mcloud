#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo “Script started”
date +“%T”
while read -r line
do
 	udid=`echo $line | cut -d '|' -f ${udid_position}`
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
        if [[ -n "$device" &&  -z "$appium" ]]; then
		echo "Starting node: ${udid}"
                ${selenium_home}/startNodeAppium.sh $udid
        elif [[ -z "$device" &&  -n "$appium" ]]; then
		echo "The node will be stopped: ${udid}"
                ${selenium_home}/stopNodeAppium.sh $udid
        else
        	echo "Nothing to do for ${udid}"
        fi
done < ${devices}
echo “Script finished”
date +“%T”
