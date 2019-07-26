#!/bin/bash

ps -ef | grep appium

echo Kill appium processes
if ps -eaf | grep 'WebDriverAgent' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' ; then
	kill -9 `ps -eaf | grep 'WebDriverAgent' | grep -v grep | grep -v '/stf' | grep -v '/usr/share/maven' | awk '{ print $2 }'`
fi

ps -ef | grep appium


