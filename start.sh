#!/bin/bash

docker network create mcloud

#-------------- START EVERYTHING ------------------------------
docker-compose up -d
