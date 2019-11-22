#!/bin/bash

BASEDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )


export hubHost=stage.qaprosoft.com
export hubPort=4446

export nodeHost=192.168.88.91

export automation_name=XCUITest
export appium_home=/usr/local/lib/node_modules/appium

export selenium_home=${BASEDIR}
export devices=${selenium_home}/devices.txt
export configFolder=${selenium_home}/configs
export logFolder=${selenium_home}/logs
export tmpFolder=${selenium_home}/tmp

#general vars declaration to parse devices.txt correctly
export name_position=1
export type_position=2
export os_version_position=3
export udid_position=4
export appium_port_position=5
export wda_port_position=6
export mjpeg_port_position=7
export iwdp_port_position=8

export stf_min_port_position=9
export stf_max_port_position=10

export device_ip_position=11


if [ ! -d "${BASEDIR}/logs" ]; then
    mkdir "${BASEDIR}/logs"
fi

if [ ! -d "${tmpFolder}" ]; then
    mkdir "${tmpFolder}"
fi
