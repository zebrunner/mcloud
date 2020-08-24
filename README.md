MCloud (Zebrunner Device Farm)
==================

MCloud is dockerized QA infrastructure for remote web access to physical devices (Android and iOS) including phones, tablets and TV. Is is fully integrated into the [Zebrunner (Community Edition)](https://zebrunner.github.io/zebrunner) ecosystem and can be used as for manual so for automation.

* It is built on the top of [OpenSTF](https://github.com/openstf) with supporting iOS devices remote control.

## Usage
* Follow [installation guide](https://zebrunner.github.io/zebrunner/install-guide/) to setup the Zebrunner Community Edition
  > make sure to provide valid protocol, hostname, port and enable MCloud sub-component
* Start everything using _./zebrunner.sh start_
* SmartTestFarm Url: http://hostname/stf
* Selenium Hub Url: http://demo:demo@hostname/mcloud/grid/console
   > WebServer port (80) should be accessible from user's browsers. Also to be able to connect to devices remotely such range of ports should be opened (7400-7700).
* Setup Android provider using steps from [android-slave](https://github.com/qaprosoft/mcloud/tree/android-slave) branch
* Setup iOS provider using steps from [ios-slave](https://github.com/qaprosoft/mcloud/tree/ios-slave) branch

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
