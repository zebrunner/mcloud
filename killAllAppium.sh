#!/bin/bash

ps -ef | grep appium

echo Kill appium processes
if ps -eaf | grep 'appium' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | grep -v 'WebDriverAgent' ; then
	kill -9 `ps -eaf | grep 'appium' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | grep -v 'WebDriverAgent' | awk '{ print $2 }'`
fi

ps -ef | grep appium


