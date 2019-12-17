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

	#TODO: [Optional] think about verification by http call
        stf=`ps -eaf | grep ${udid} | grep 'ios-device' | grep -v grep`

        if [[ -n "$device" && -z "$stf" ]]; then
		echo "Starting iSTF ios-device: ${udid} device name : ${name}"
                ${selenium_home}/startNodeSTF.sh $udid
        elif [[ -z "$device" &&  -n "$stf" ]]; then
		echo "The iSTF ios-device will be stopped: ${udid} device name : ${name}"
		echo device: $device
		echo stf: $stf
#                ${selenium_home}/stopNodeSTF.sh $udid
        else
        	echo "Nothing to do for ${udid} device name ${name}"
        fi
done < ${devices}
echo `date +"%T"` Script finished
