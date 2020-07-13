## FUNCTION:     start_component
## DESCRITION:   starts EPM System components
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
  sleep 10
  if [[ -r ${STARTUP_LOG} ]]
  then
    grep "${STARTUP_INDICATOR}" ${STARTUP_LOG}
    if [[ $? = 0 ]]
    then
      echo Device was connected successfully in ${COUNTER}0 seconds...
      COUNTER=${STARTUP_COUNTER}
    else
      echo Device wasn\'t connected yet. waiting 10 sec...
    fi
  else
    echo Cannot read from ${STARTUP_LOG}. File hasn\'t appeared yet.
  fi
  let COUNTER=COUNTER+1
done

if [[ $COUNTER = ${STARTUP_COUNTER} ]]
then
  echo DEVICE WAS NOT CONNECTED IN ${STARTUP_COUNTER}0 SECONDS...
  return 2
fi
return 0