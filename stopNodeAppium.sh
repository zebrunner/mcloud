#!/bin/bash
devicePattern=$1
#echo devicePattern: $devicePattern

kill_processes()
{
  processes_pids=$1
  if [ "${processes_pids}" != "" ]; then
	echo processes_pids: $processes_pids
	kill -9 $processes_pids
  fi
}

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

deviceName=${name}
deviceUdid=${udid}
port=${appium_port}

echo Killing appium process for ${deviceName}
if [ "${deviceUdid}" != "" ]; then
	if ps -eaf | grep ${deviceUdid} | grep 'appium' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | grep -v 'team-city' | grep -v 'WebDriverAgent'; then
		export pids=`ps -eaf | grep ${deviceUdid} | grep 'appium' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | grep -v 'team-city' | grep -v 'WebDriverAgent' | awk '{ print $2 }'`
		kill_processes $pids
	fi
	if ps -eaf | grep ${deviceUdid} | grep 'adb' | grep -v grep | grep -v '/stf' | grep -v 'WebDriverAgent'; then
		export pids=`ps -eaf | grep ${deviceUdid} | grep 'adb' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | grep -v 'WebDriverAgent' | awk '{ print $2 }'`
		kill_processes $pids
	fi
elif [ "${port}" != "" ]; then
	export pids=`ps -eaf | grep ${port} | grep 'appium' | grep -v grep | grep -v '/usr/share/maven' | awk '{ print $2 }'`
	kill_processes $pids
else
	echo "Skipping device kill as device doesn't exist"
fi



