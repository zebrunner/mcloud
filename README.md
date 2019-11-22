MCloud iOS instance
==================

MCloud iOS is a list of scripts which are using to start iOS appium nodes for both real devices and simulators. 

## Initial setup
* Add your devices to devices.txt file. Use ```type = phone``` for real devices and ```type = simulator``` for iOS simulators. Also, we suggest to use static IPs for your real devices.

* Update set_selenium_propertise.sh. In general you have to update only the next variables : hubHost (host where hub is running), hubPort (hub port) and nodeHost(your mac IP).

## Nodes start/stop
* If you'd like to start a single appium node:
 1. Start WDA for the node using: ```startNodeWDA.sh $UDID```.
 2. Start appium using: ```startNodeAppium.sh $UDID```.
 3. Check that appium is running: ```ps -ef | grep appium/build```. <B>Note</B>: the appium node will be started only in case if WDA is started for the node.

* If you'd like to start all nodes listed in devices.txt:
 1. Start WDA for all nodes using: ```syncWDA.sh```.
 2. Start appium for all nodes using: ```syncAppiumDevices.sh``` and ```syncAppiumSimulators.sh```.

* If you'd like to stop a single appium node:
 1. Stop all processes for desired node using: ```stopNodeAppium.sh $UDID``` , ```stopNodeWDA.sh $UDID```.

* If you'd like to stop all nodes:
 1. Stop all processes for all nodes using: ```killAllAppium.sh``` , ```killAllWDA.sh```.

<B>Note</B>: To perform automatic synchronization (disconnect/connect of a device, WDA crash etc) use [launchd](https://www.launchd.info/) functionality.  


