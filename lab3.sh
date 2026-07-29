#!/bin/bash

# lab3.sh

# Script: Runs configure-host.sh on both servers
# Author: Joshua Naccarato (9030)
# Description: Assignment 3 for COMP2137 (Linux Automation)
# Deploys configure-host.sh to server 1 and server 2, applies configuration,
# and updates the local VM /etc/hosts.

VERBOSE=""
if [ "$1" = "-verbose" ] || [ "$1" = "-v" ]; then
	VERBOSE="-verbose"
		echo "Verbose mode is enabled."
fi

###
# cleaning old ssh keys
###

echo "Cleaning up old keys"
ssh-keygen -R server1-mgmt &>/dev/null
ssh-keygen -R server2-mgmt &>/dev/null

###
# server 1
###

scp -o StrictHostKeyChecking=accept-new configure-host.sh remoteadmin@server1-mgmt:/root
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to copy configure-host.sh to server1" >&2
	exit 1
fi

ssh -o StrictHostKeyChecking=accept-new remoteadmin@server1-mgmt -- /root/configure-host.sh $VERBOSE -name loghost -ip 192.168.16.3 -hostentry webhost 192.168.16.4
if [ $? -ne 0 ]; then
	echo "ERROR: configure-host.sh failed on server1" >&2
	exit 1
fi

###
# server 2
###

scp -o StrictHostKeyChecking=accept-new configure-host.sh remoteadmin@server2-mgmt:/root
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to copy configure-host.sh to server2" >&2
	exit 1
fi

ssh -o StrictHostKeyChecking=accept-new remoteadmin@server2-mgmt -- /root/configure-host.sh $VERBOSE -name webhost -ip 192.168.16.4 -hostentry loghost 192.168.16.3
if [ $? -ne 0 ]; then
	echo "ERROR: configure-host.sh failed on server2" >&2
	exit 1
fi

###
# hostentry
###

sudo ./configure-host.sh $VERBOSE -hostentry loghost 192.168.16.3
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to update local /etc/hosts for loghost" >&2
	exit 1
fi

sudo ./configure-host.sh $VERBOSE -hostentry webhost 192.168.16.4
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to update local /etc/hosts for webhost" >&2
	exit 1
fi

exit 0
