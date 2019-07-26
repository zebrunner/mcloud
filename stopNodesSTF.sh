#!/bin/bash

ps -ef | grep appium

echo Kill iSTF processes
if ps -eaf | grep 'ios-device' | grep 'stf' | grep -v grep; then
	kill -9 `ps -eaf | grep 'ios-device' | grep 'stf' | grep -v grep | awk '{ print $2 }'`
fi

ps -ef | grep appium


