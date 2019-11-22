#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo "Script started"
date +"%T"
logFile=${tmpFolder}/connectedSimulators.txt 
instruments -s devices > ${logFile}
while read -r line
do
 	udid=`echo $line | cut -d '|' -f ${udid_position}`
	. ${selenium_home}/getDeviceArgs.sh $udid
        #to trim spaces around. Do not remove!
	udid=$(echo $udid)
	simulator=`echo $line | grep simul`
	if [ "$udid" = "UDID" ] || [[ -z "$simulator" ]]; then
            continue
        fi

        appium=`ps -ef | grep $appium_home/build/lib/main.js | grep $udid`
	if [[ -n "$simulator" && -n "$appium" ]]; then
		echo "Appium is running for simulator : ${udid}"
		continue
	elif [[ -n "$simulator" ]]; then
		echo "Will check if appium needed for simulator : ${simulator}"
		device=`cat ${logFile} | grep $udid`
	fi
	if [[ -n "$simulator" && -z "$device" ]]; then
		echo "Simulator is populated in ${devices} but not started in OS"
		continue
	elif [[ -n "$simulator" && -z "$appium" ]]; then
		echo "Starting simulator: ${udid}"
		${selenium_home}/startNodeAppium.sh $udid
		continue
	fi
done < ${devices}
echo "Script finished"
date +"%T"
