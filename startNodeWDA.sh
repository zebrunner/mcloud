#!/bin/bash

devicePattern=$1
#echo devicePattern: $devicePattern

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. ${BASEDIR}/set_selenium_properties.sh
. ${selenium_home}/getDeviceArgs.sh $devicePattern

verifyStartup() {

  ## FUNCTION:     verifyStartup
  ## DESCRITION:   verify if WDA component started per device/simolator
  ## PARAMETERS:
  ##         $1 - Path to log file for startup verification
  ##         $2 - String to find in startup log (startup indicator)
  ##         $3 - Counter. (Startup verification max duration) = (Counter) x (10 seconds)

  STARTUP_LOG=$1
  STARTUP_INDICATOR=$2
  STARTUP_COUNTER=$3

  COUNTER=0
  while [  $COUNTER -lt $STARTUP_COUNTER ];
  do
    sleep 1
    if [[ -r ${STARTUP_LOG} ]]
    then
      grep "${STARTUP_INDICATOR}" ${STARTUP_LOG} > /dev/null
      if [[ $? = 0 ]]
      then
        echo device ${name} was connected successfully in ${COUNTER} seconds...
        COUNTER=${STARTUP_COUNTER}
      else
        echo ${name} device wasn\'t connected yet. waiting 1 sec...
      fi
    else
      echo Cannot read from ${STARTUP_LOG}. File hasn\'t appeared yet.
    fi
    let COUNTER=COUNTER+1
  done

  if [[ $COUNTER = ${STARTUP_COUNTER} ]]
  then
    echo WDA was not started successfully for ${name} device after ${STARTUP_COUNTER} seconds!
    return 2
  fi
  return 0
}


echo Starting WDA: ${name}, udid: ${udid}, wda_port: ${wda_port}, mjpeg_port: ${mjpeg_port}
nohup /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ${appium_home}/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj \
      -scheme WebDriverAgentRunner -destination id=$udid USE_PORT=$wda_port MJPEG_SERVER_PORT=$mjpeg_port test > "${BASEDIR}/logs/${name}_wda.log" 2>&1 &

verifyStartup "${BASEDIR}/logs/${name}_wda.log" "ServerURLHere->" 120 >> "${BASEDIR}/logs/${name}_wda.log"

if [[ $? = 0 ]]; then
  # WDA was started successfully!
  # parse ip address from log file line:
  # 2020-07-13 17:15:15.295128+0300 WebDriverAgentRunner-Runner[5660:22940482] ServerURLHere->http://192.168.88.127:20001<-ServerURLHere

  ip=`grep "ServerURLHere->" "${BASEDIR}/logs/${name}_wda.log" | cut -d ':' -f 5`
  # remove forward slashes
  ip="${ip//\//}"
  # put IP address into the metadata file
  echo "${ip}" > ${metaDataFolder}/${udid}.txt
else 
  # WDA is not started successfully!
  rm ${metaDataFolder}/${udid}.ip
fi


