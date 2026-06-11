#!/bin/bash
# Check preconditions
# Is IP set
if [[ $1 ]]; then
	MESH_IP=$1
else
	echo "No mesh-ip provided as first argument."
	exit 1
fi
if [[ $2 ]]; then
	DEFAULT_GATEWAY=$2
else
	echo "No default gateway provided :'("
	exit 1
fi
# Stop network stuff
sudo systemctl stop wpa_supplicant
sudo systemctl stop NetworkManager
sudo rfkill unblock wifi
sudo ip link set wlan0 down

# Configure interface
sudo iwconfig wlan0 mode ad-hoc
sudo iwconfig wlan0 essid "meshnet"
sudo iwconfig wlan0 channel 1 # or 6 or 11
sudo ip link set wlan0 up

# Load kernel module
sudo modprobe batman-adv

# Activate interfaces
sudo batctl if add wlan0
sudo ifconfig bat0 up

sudo ip addr flush dev bat0
sudo ip addr add $MESH_IP/24 dev bat0
sudo ip link set bat0 up

sudo ip route add default via $DEFAULT_GATEWAY

sudo batctl n
