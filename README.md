MCloud iOS-slave instance
==================

MCloud is dockerized QA infrastructure for remote web access to physical devices (Android and iOS). Is is fully integrated into the [qps-infra](http://www.qps-infra.io) ecosystem and can be used for manual so automation usage.

* It is built on the top of [OpenSTF](https://github.com/openstf) with supporting iOS devices remote control.

## Contents
* [Software prerequisites](#software-prerequisites)
* [iSTF components setup](#istf-components-setup)
* [iOS-slave mcloud setup](#ios-slave-mcloud-setup)
* [Setup sync scripts via Launch Agents for Appium, WDA and STF services](#setup-sync-scripts-via-launch-agents-for-appium-wda-and-stf-services)
* [License](#license)

## Software prerequisites
* Install node 8.16.0.
  Note: that's still a requirement of open stf
* Install XCode 11.2
* Install Appium 1.15.1
* brew install rethinkdb graphicsmagick zeromq protobuf yasm pkg-config
* Install extra modules
```
  npm install promise
  npm install request-promise
  npm install websocket-stream
  npm install mjpeg-consumer
  npm install udid
  
```

## iSTF components setup
* Clone and build iSTF from sources
```
git clone https://github.com/qaprosoft/stf
cd stf
npm install
npm link
```
* 

## iOS-slave mcloud setup
* Clone mcloud and switch to ios-slave
```
git clone https://github.com/qaprosoft/mcloud
git checkout ios-slave

```
* Update devices.txt registering all whitelisted devices in it
```
# DEVICE NAME    | TYPE      | VERSION| UDID                                     |APPIUM|  WDA  | MJPEG | IWDP  | STF_MIN | STF_MAX | DEVICE IP
iPhone_7         | phone     | 12.3.1 | 48ert45492kjdfhgj896fea31c175f7ab97cbc19 | 4841 | 20001 | 20002 | 20003 |  7701   |  7710   | 192.168.88.250
Phone_X1         | simulator | 12.3.1 | 7643aa9bd1638255f48ca6beac4285cae4f6454g | 4842 | 20011 | 20022 | 20023 |  7711   |  7720   | 192.168.88.251
```
Note: For simulators DEVICE_IP is actual host ip address. Also we suggest

* Update set_selenium_properties.sh. Specify actual values for hubHost, hubPort and nodeHost values

* Sign WebDriverAgent using your Dev Apple certificate and install WDA on each device manually
  * Open in XCode /usr/loca/lib/node_modules/appium/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj
  * Choose WebDriverAgentRunner and your device(s) 
  * Choose your dev certificate
  * Product -> Test. When WDA installed and started successfully Product -> Stop

* Verify that Appium/WDA and STF services can be launched successfully
```
cd mcloud

./startNodeWDA.sh <udid>
tail -f ./logs/<deviceName>_wda.log

./startNodeAppium.sh <udid>
tail -f ./logs/<deviceName>_appium.log

./startNodeSTF.sh <udid>
tail -f ./logs/<deviceName>_stf.log
```  

Note: we temporary hardcoded in startNodeSTF.sh extra items like STF_HOST, path to STF cli, current host ip. Before startup update onto the valid values

### Setup sync scripts via Launch Agents for Devices, Appium, WDA and STF services
  * Devices agent setup
  * Appium agent setup
  * WDA agent setup
  * STF agent setup
  
Note: you can use [launchd](https://www.launchd.info/) functionality. Examples and README.txt with details can be found in MCLOUD_HOME/LauncgAgents folder

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
