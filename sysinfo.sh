#!/bin/bash

echo "Hostname: "
hostname
echo

echo "Ip Address: "
hostname -I
echo

echo "Gateway IP :"
ip route | grep default
