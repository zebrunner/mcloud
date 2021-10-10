Zebrunner MCloud
==================

Zebrunner MCloud is a Device Farm for automated tests executions (Appium) and remote web access by humans to physical devices (Android and iOS) including phones, tablets and TV. It is fully integrated into the [Zebrunner (Community Edition)](https://zebrunner.github.io/community-edition) ecosystem and can be used both for manual and automation testing.

* It is built on top of [OpenSTF](https://github.com/openstf) and supports iOS devices remote control.

Feel free to support the development with a [**donation**](https://www.paypal.com/donate?hosted_button_id=JLQ4U468TWQPS) for the next improvements.
<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="./docs/img/zebrunner_intro.png"></a>
</p>

## Usage
1. Clone [mcloud](https://github.com/zebrunner/mcloud) and setup:
   ```
   git clone https://github.com/zebrunner/mcloud.git && cd mcloud && ./zebrunner.sh setup
   ```
> Provide valid protocol, hostname and port
2. Start services `./zebrunner.sh start`
3. Open `http://hostname:80/stf`
4. Login using any name/email values as auth-mock is configured by default
> Follow installation and configuration guide in [Zebrunner CE](https://zebrunner.github.io/community-edition) to reuse MCloud components effectively for Test Automation.


## Documentation and free support
* [Zebrunner CE](https://zebrunner.github.io/community-edition) 
* [Zebrunner Reporting](https://zebrunner.com/documentation) 
* [Telegram Channel](https://t.me/zebrunner)
 
## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
