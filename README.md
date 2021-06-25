Zebrunner Device Farm
==================

Zebrunner Device Farm is a dockerized QA infrastructure for remote web access to physical devices (Android and iOS) including phones, tablets and TV. It is fully integrated into the [Zebrunner (Community Edition)](https://zebrunner.github.io/zebrunner) ecosystem and can be used both for manual and automation testing.

* It is built on top of [OpenSTF](https://github.com/openstf) and supports iOS devices remote control.

Feel free to support the development with a [**donation**](https://www.paypal.com/donate?hosted_button_id=JLQ4U468TWQPS) for the next improvements.
<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="./docs/img/zebrunner_intro.png"></a>
</p>

## Usage
* Follow [installation guide](https://zebrunner.github.io/zebrunner/install-guide/) to set up the Zebrunner Community Edition
  > Make sure to provide the valid protocol, hostname, port, and enable MCloud sub-component
* Start everything using _./zebrunner.sh start_
* SmartTestFarm URL: http://hostname/stf
* Selenium Hub URL: http://demo:demo@hostname/mcloud/grid/console
   > WebServer port (80) should be accessible from users' browsers. Moreover, to be able to connect to the devices remotely, the following range of ports should be opened (7400-7700) for users' connect.
* Setup Android provider using the steps from [mcloud-android](https://github.com/zebrunner/mcloud-android/blob/master/README.md)
* Setup iOS provider using the steps from [mcloud-ios](https://github.com/zebrunner/mcloud-ios/blob/master/README.md)

## Documentation and free support
* [Zebrunner CE](https://zebrunner.github.io/zebrunner) 
* [Zebrunner Reporting](https://zebrunner.com/documentation) 
* [Telegram Channel](https://t.me/zebrunner)
 
## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
