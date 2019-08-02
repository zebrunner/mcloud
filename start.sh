#!/bin/bash


# to cauto clean selenoid/appium video crontab is configured to remove mp4 older than 24hrs
#0 * * * * find $HOME/tools/stage-infra/selenoid/video -mindepth 1 -maxdepth 1 -mmin +1440 -name '*.mp4' | xargs rm -rf

#TODO: add configuration step to share  selenoid/video correctly when cm is used
#ln -s /home/build/.aerokube/selenoid/video /home/build/tools/stage-infra/selenoid/
docker network create mcloud

#-------------- START EVERYTHING ------------------------------
docker-compose up -d
