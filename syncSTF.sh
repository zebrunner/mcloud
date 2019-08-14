#!/bin/bash
BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
. ${BASEDIR}/set_selenium_properties.sh

echo "Script started"
date +"%T"
while read -r line
do
 	udid=`echo $line | cut -d '|' -f ${udid_position}`
        #to trim spaces around. Do not remove!
	udid=$(echo $udid)
	if [ "$udid" = "UDID" ]; then
            continue
        fi

        stf=`ps -eaf | grep ${udid} | grep 'stf' | grep 'ios-device' | grep -v grep`
	device=`/usr/local/bin/ios-deploy -c -t 1 | grep $udid`
        if [[ -n "$device" &&  -z "$stf" ]]; then
		echo "Starting iSTF ios-device: ${udid}"
                ${selenium_home}/startNodeSTF.sh $udid
        elif [[ -z "$device" &&  -n "$stf" ]]; then
		echo "The iSTF ios-device will be stopped: ${udid}"
                ${selenium_home}/stopNodeSTF.sh $udid
        else
        	echo "Nothing to do for ${udid}"
        fi
done < ${devices}
echo "Script finished"
date +"%T"
