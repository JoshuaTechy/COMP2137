#!/bin/bash

# configure-host.sh

# Script: Automated System Configuration
# Author: Joshua Naccarato (9030)
# Description: Assignment 3 for COMP2137 (Linux Automation)

# Configures hostname, IP address, and /etc/hosts entries on Linux host
# Only makes changes if current settings dont match request

###
# VARIABLES
###

# ignores signals TERM, HUP, and INT
trap '' TERM HUP INT

verbose=""
netplan_file="" 
lan_interface=""
programname="$(basename $0)"
script_dir="$(cd "$(dirname "$0")" && pwd)"
logfile="$script_dir/configure-host.log"

###
# FUNCTIONS
###

function error_msg {
	if [ "$verbose" = "yes" ]; then
		echo "$(date +%H:%M:%S) $programname : ***** WARNING ***** $1"
	else
		echo "$(date +%H:%M:%S) $programname : ***** WARNING ***** $1" >> "$logfile"
	fi
}

function fatal_error {
	error_msg "$1"
	exit 1
}

function log_msg {
	echo "$(date +%H:%M:%S) $programname : $1" >> "$logfile"
}

function displayhelp() {
	cat <<EOF
Usage: $programname [-verbose] [-name (desiredName)] [-ip (desiredIPAddress)] [-hostentry (desiredName) (desiredIPAddress)]
  This command confirms and applies basic host configuration settings.
  Any setting already matching the requested value is left unchanged.
  -verbose					show what changes are made, or confirm none are needed
  -name desiredName                 		confirm/set the hostname
  -ip desiredIPAddress              		confirm/set interface IP address
  -hostentry desiredName desiredIPAddress   	confirm/set an /etc/hosts entry
 
EOF
}

function configure_name {
	# confirms/sets hostname
	desired_name="$1"
	current_name=$(hostname)
	changed=no

	# check hostname
	if [ "$current_name" != "$desired_name" ]; then
		[ "$verbose" = "yes" ] && echo "Changing live hostname from $current_name to $desired_name"
		hostnamectl set-hostname "$desired_name" 2>/dev/null || hostname "$desired_name"
		changed=yes
	fi

	# check /etc/hostname
	if [ "$(cat /etc/hostname 2>/dev/null)" != "$desired_name" ]; then
		[ "$verbose" = "yes" ] && echo "Updating /etc/hostname to $desired_name"
		echo "$desired_name" > /etc/hostname
		changed=yes
	fi

	# check /etc/hosts
	if ! grep -q "^127\.0\.1\.1[[:space:]].*\b$desired_name\b" /etc/hosts; then
		[ "$verbose" = "yes" ] && echo "Updating /etc/hosts for $desired_name"
		if grep -q "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
			sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$desired_name/" /etc/hosts
		else
			echo "127.0.1.1	$desired_name" >> /etc/hosts
		fi
		changed=yes
	fi

	if [ "$changed" = "no" ]; then
		[ "$verbose" = "yes" ] && echo "Hostname is already set..."
		return 0
	fi

	log_msg "hostname changed to $desired_name"
	logger "$programname: hostname changed to $desired_name"
}
 
function configure_ip {
	desired_ip="$1"

	netplan_file=""
	lan_interface=""
	known_keys="network|ethernets|wifis|bonds|vlans|bridges|tunnels|version|renderer"

	# derive the /24 prefix of the desired IP (e.g. "192.168.16" from "192.168.16.3")
	desired_prefix=$(echo "$desired_ip" | cut -d. -f1-3)

	for f in /etc/netplan/*.yaml; do
		for iface in $(grep -E '^\s+[a-zA-Z0-9_.-]+:\s*$' "$f" 2>/dev/null | sed 's/[: ]//g' | grep -Ev "^($known_keys)\$"); do
			iface_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
			iface_prefix=$(echo "$iface_ip" | cut -d. -f1-3)
			if [ "$iface_prefix" = "$desired_prefix" ]; then
				netplan_file="$f"
				lan_interface="$iface"
				break 2
			fi
		done
	done

	if [ -z "$netplan_file" ]; then
		fatal_error "No netplan interface found in the $desired_prefix.0/24 subnet"
	fi

	current_ip=$(ip -4 addr show "$lan_interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

	if [ "$current_ip" = "$desired_ip" ]; then
		[ "$verbose" = "yes" ] && echo "IP address already $desired_ip"
		return 0
	fi

	[ "$verbose" = "yes" ] && echo "Changing IP address from $current_ip to $desired_ip"

	if grep -q "addresses:" "$netplan_file"; then
		sed -i "s/$current_ip\(\/[0-9]\+\)\?/$desired_ip\1/" "$netplan_file"
	else
		sed -i "/dhcp4: true/d" "$netplan_file"
		sed -i "/^\s*$lan_interface:\s*\$/a\\      dhcp4: false\n      addresses: [$desired_ip/24]" "$netplan_file"
	fi

	my_name=$(hostname)
	if grep -q "^$current_ip[[:space:]]" /etc/hosts; then
		sed -i "s/^$current_ip\([[:space:]]\)/$desired_ip\1/" /etc/hosts
	else
		echo "$desired_ip	$my_name" >> /etc/hosts
	fi

	netplan apply

	log_msg "IP address changed from $current_ip to $desired_ip"
	logger "$programname: IP address changed from $current_ip to $desired_ip"
}
 
function configure_hostentry {
	# confirm/set an /etc/hosts entry
	entry_name="$1"
	entry_ip="$2"
 
 	# checks if name and ip exists
	if grep -qE "^$entry_ip[[:space:]]+$entry_name([[:space:]]|\$)" /etc/hosts; then
		[ "$verbose" = "yes" ] && echo "/etc/hosts already has $entry_name > $entry_ip."
		return 0
	fi
 
	[ "$verbose" = "yes" ] && echo "Updating /etc/hosts $entry_name > $entry_ip"
 
 	# handles wrong ip, prevents two conflicting entries
	if grep -qE "[[:space:]]$entry_name([[:space:]]|\$)" /etc/hosts; then
		sed -i "/[[:space:]]$entry_name\(\$\|[[:space:]]\)/d" /etc/hosts
	fi
	echo "$entry_ip	$entry_name" >> /etc/hosts
 
	log_msg "/etc/hosts updated with $entry_name -> $entry_ip"
	logger "$programname: /etc/hosts updated with $entry_name -> $entry_ip"
}

###
# RUN SCRIPT
###

while [ $# -gt 0 ]; do
	# process $1
	case "$1" in
		-verbose )
			verbose=yes
			;;
		-name )
			shift
			if [ -z "$1" ]; then
				displayhelp
				fatal_error "$USER gave -name with no hostname"
			fi
			configure_name "$1"
			;;
		-ip )
			shift
			if [ -z "$1" ]; then
				displayhelp
				fatal_error "$USER gave -ip with no address"
			fi
			configure_ip "$1"
			;;
		-hostentry )
			shift
			entryname="$1"
			shift
			entryip="$1"
			if [ -z "$entryname" ] || [ -z "$entryip" ]; then
				displayhelp
				fatal_error "$USER gave -hostentry without both a name and an IP"
			fi
			configure_hostentry "$entryname" "$entryip"
			;;
		-h | --help )
			displayhelp
			exit
			;;
		* )
			displayhelp
			fatal_error "$USER gave unknown command line data '$1'"
			;;
	esac
	# get rid of $1 and move all the other variables down one
	shift
done
 
log_msg "Started"
[ "$verbose" = "yes" ] && echo "configure-host.sh finished applying requested settings"
log_msg "Ended"
 
exit 0
